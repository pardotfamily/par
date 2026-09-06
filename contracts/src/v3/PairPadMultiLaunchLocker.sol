// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IERC721ReceiverLike, IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";
import {IPairPadMultiLaunchFactory} from "./interfaces/ILaunchpadV3.sol";

/**
 * @title PairPadMultiLaunchLocker
 * @notice Permanently holds the Uniswap V4 position NFTs that are a
 * multi-market launch's pools, and collects the LP fees they earn.
 *
 * Same contract as PairPadLaunchLocker, for launches with several markets:
 * one position per market, all locked here, all collected in one call and
 * split on the terms the factory froze at launch. The creator's share of
 * every currency is credited to the shared PairPadFeeEscrow; the protocol's
 * share of each quote is paid to the protocol fee recipient (or credited to
 * the escrow if that payment fails) and its share of the launch token is
 * burned.
 *
 * The only position action this contract ever encodes is a zero-liquidity
 * decrease, which is how V4 collects fees without touching the liquidity.
 * There is no withdrawal and no arbitrary-call function, so the liquidity
 * behind a launch can never be removed by anyone.
 */
contract PairPadMultiLaunchLocker is Ownable2Step, ReentrancyGuard, IERC721ReceiverLike {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant COLLECT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionAlreadyLocked();
    error PositionNotHeld();
    error NotPositionManager();
    error OwnershipCannotBeRenounced();
    error TokenNotLaunched();
    error InexactTransfer(address token, uint256 expected, uint256 received);
    error NoPositions();

    event FactorySet(address factory);
    event PositionLocked(address indexed token, uint256 indexed tokenId, uint256 marketIndex);
    /// @notice The protocol's share of fees paid in the launch token, burned.
    event ProtocolShareBurned(address indexed token, uint256 amount);
    /**
     * @notice One per market that had something to collect. Amounts are in
     * the pool's currency order; `protocol*` plus `creator*` is what the
     * position paid out in each currency.
     */
    event FeesCollected(
        address indexed token,
        uint256 indexed marketIndex,
        address currency0,
        address currency1,
        uint256 protocolAmount0,
        uint256 protocolAmount1,
        uint256 creatorAmount0,
        uint256 creatorAmount1
    );

    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IPairPadFeeEscrow public immutable feeEscrow;
    IPairPadMultiLaunchFactory public factory;

    mapping(address token => uint256[] tokenIds) private _lockedPositions;

    /**
     * @param initialOwner Administrative owner; only used to wire the factory once.
     * @param positionManager_ The canonical Uniswap V4 PositionManager for this chain.
     * @param feeEscrow_ Ledger collected fees are credited to (shared with v2).
     */
    constructor(address initialOwner, IPositionManager positionManager_, IPairPadFeeEscrow feeEscrow_)
        Ownable(initialOwner)
    {
        if (address(positionManager_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        feeEscrow = feeEscrow_;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert NotFactory();
        _;
    }

    /**
     * @notice One-time wiring of the factory, set after both are deployed.
     */
    function setFactory(address factory_) external onlyOwner {
        if (address(factory) != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = IPairPadMultiLaunchFactory(factory_);
        emit FactorySet(factory_);
    }

    /**
     * @notice Permanently disabled. Ownership here exists only to perform the
     * one-time factory wiring.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /**
     * @notice Rejects safe transfers of anything but a canonical position NFT.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Registers and verifies permanent custody of a launch's
     * positions, in market order. Called once per launch by the factory,
     * right after the positions are minted to this contract.
     */
    function lockPositions(address token, uint256[] calldata tokenIds) external onlyFactory {
        if (_lockedPositions[token].length != 0) revert PositionAlreadyLocked();
        if (tokenIds.length == 0) revert NoPositions();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (IERC721(address(positionManager)).ownerOf(tokenIds[i]) != address(this)) revert PositionNotHeld();
            _lockedPositions[token].push(tokenIds[i]);
            emit PositionLocked(token, tokenIds[i], i);
        }
    }

    function isLocked(address token) external view returns (bool) {
        return _lockedPositions[token].length != 0;
    }

    function lockedPositions(address token) external view returns (uint256[] memory) {
        return _lockedPositions[token];
    }

    // ---------------------------------------------------------------------
    // Fee collection
    // ---------------------------------------------------------------------

    /**
     * @notice Fees market `index` of `token` has earned and not yet collected,
     * in the pool's currency order. Exact to the wei the collection pays out.
     */
    function pendingFees(address token, uint256 index) public view returns (uint256 amount0, uint256 amount1) {
        _requireLaunched(token);
        IPairPadMultiLaunchFactory.Market memory m = factory.getMarket(token, index);
        PoolId poolId = factory.poolKeyFor(token, index).toId();
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, m.tickLower, m.tickUpper);
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(
            poolId, address(positionManager), m.tickLower, m.tickUpper, bytes32(m.positionId)
        );
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @notice Uncollected fees on every market of `token`, in market order and
     * each pool's currency order.
     */
    function pendingFeesAll(address token) external view returns (uint256[] memory amount0, uint256[] memory amount1) {
        uint256 n = _requireLaunched(token).marketCount;
        amount0 = new uint256[](n);
        amount1 = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (amount0[i], amount1[i]) = pendingFees(token, i);
        }
    }

    /**
     * @notice Collects every market's accrued fees, pays the protocol its
     * share of each quote, burns its share of the launch token and credits
     * the creator's share of everything to the fee escrow. Open to anyone:
     * the recipients are fixed by the launch record.
     * @return collected The total paid out per market, in each pool's
     * currency order, flattened as [m0.amount0, m0.amount1, m1.amount0, ...].
     */
    function collectFees(address token) external nonReentrant returns (uint256[] memory collected) {
        IPairPadMultiLaunchFactory.LaunchedToken memory launch = _requireLaunched(token);
        uint256[] storage ids = _lockedPositions[token];
        uint256 n = ids.length;
        collected = new uint256[](2 * n);
        for (uint256 i = 0; i < n; i++) {
            (collected[2 * i], collected[2 * i + 1]) = _collectMarket(token, i, ids[i], launch);
        }
    }

    /**
     * @notice Collects one market only. Useful when a single pool is busy and
     * the rest are idle.
     */
    function collectMarketFees(address token, uint256 index)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        IPairPadMultiLaunchFactory.LaunchedToken memory launch = _requireLaunched(token);
        return _collectMarket(token, index, _lockedPositions[token][index], launch);
    }

    function _collectMarket(
        address token,
        uint256 index,
        uint256 tokenId,
        IPairPadMultiLaunchFactory.LaunchedToken memory launch
    ) private returns (uint256 amount0, uint256 amount1) {
        PoolKey memory key = factory.poolKeyFor(token, index);

        uint256 before0 = _balance(key.currency0);
        uint256 before1 = _balance(key.currency1);

        // A zero-liquidity decrease moves the position's owed fees into this
        // call's deltas; TAKE_PAIR pays them out here.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + COLLECT_DEADLINE_WINDOW);

        amount0 = _balance(key.currency0) - before0;
        amount1 = _balance(key.currency1) - before1;
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        // protocol share of the whole fee = share of base * base / (base + tax)
        uint256 totalFeeBps = uint256(launch.baseFeeBps) + launch.creatorTaxBps;
        uint256 protocol0 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount0, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);
        uint256 protocol1 = totalFeeBps == 0
            ? 0
            : FullMath.mulDiv(amount1, uint256(launch.baseFeeBps) * launch.protocolFeeShareBps, totalFeeBps * BASIS_POINTS);

        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        if (tokenIs0) _burn(token, protocol0);
        else _payProtocol(key.currency0, launch.protocolFeeRecipient, protocol0);
        _credit(key.currency0, launch.creatorFeeRecipient, amount0 - protocol0);
        if (tokenIs0) _payProtocol(key.currency1, launch.protocolFeeRecipient, protocol1);
        else _burn(token, protocol1);
        _credit(key.currency1, launch.creatorFeeRecipient, amount1 - protocol1);

        emit FeesCollected(
            token,
            index,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            protocol0,
            protocol1,
            amount0 - protocol0,
            amount1 - protocol1
        );
    }

    function _requireLaunched(address token)
        private
        view
        returns (IPairPadMultiLaunchFactory.LaunchedToken memory launch)
    {
        launch = factory.getLaunchedToken(token);
        if (!launch.exists || _lockedPositions[token].length == 0) revert TokenNotLaunched();
    }

    function _balance(Currency currency) private view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /**
     * @dev The protocol's share goes straight to its wallet. ETH is sent with
     * a bounded gas stipend so a misbehaving recipient cannot hold the
     * collection hostage; if the send fails the amount is credited to the
     * escrow, from where the recipient can still claim it.
     */
    function _payProtocol(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool ok,) = recipient.call{value: amount, gas: 50_000}("");
            if (!ok) feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
    }

    /**
     * @dev Burns the protocol's share of fees paid in the launch token. Every
     * launch token is a PairPadLauncherToken, which is ERC20Burnable.
     */
    function _burn(address token, uint256 amount) private {
        if (amount == 0) return;
        ERC20Burnable(token).burn(amount);
        emit ProtocolShareBurned(token, amount);
    }

    function _credit(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            feeEscrow.credit{value: amount}(recipient);
            return;
        }
        address asset = Currency.unwrap(currency);
        uint256 escrowBefore = IERC20(asset).balanceOf(address(feeEscrow));
        IERC20(asset).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, asset, amount);
        uint256 received = IERC20(asset).balanceOf(address(feeEscrow)) - escrowBefore;
        if (received != amount) revert InexactTransfer(asset, amount, received);
    }

    /// @notice Accepts native ETH paid out of the pool manager.
    receive() external payable {}
}
