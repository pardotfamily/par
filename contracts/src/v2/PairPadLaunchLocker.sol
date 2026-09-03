// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IERC721ReceiverLike, IPairPadFeeEscrow, IPairPadLaunchFactory} from "./interfaces/ILaunchpadV2.sol";

/**
 * @notice The slice of the factory the locker reads: a launch's terms and
 * the key of its pool.
 */
interface IPairPadLaunchFactoryView is IPairPadLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/**
 * @title PairPadLaunchLocker
 * @notice Permanently holds the Uniswap V4 position NFT that is every PairPad
 * launch's market, and collects the LP fees that position earns.
 *
 * The pools carry a static LP fee and no hook, so the fee a trade pays lands
 * in the position like on any Uniswap pool: in the currency the trader sent
 * in. Buys pay it in the quote asset, sells in the launch token. Anyone may
 * call `collectFees` for a launch; the proceeds are split on the terms the
 * factory froze at launch. The creator's share is credited to
 * PairPadFeeEscrow, where the creator claims it; the protocol's share is paid
 * straight to the protocol fee recipient, so the keeper's routine collection
 * is also the protocol's payout. Should that payment fail (ETH to a contract
 * that rejects it), the amount is credited to the escrow instead and nothing
 * is lost.
 *
 * The only position action this contract ever encodes is a zero-liquidity
 * decrease, which is how V4 collects fees without touching the liquidity.
 * There is no withdrawal and no arbitrary-call function, so the liquidity
 * behind a launch can never be removed by anyone.
 */
contract PairPadLaunchLocker is Ownable2Step, ReentrancyGuard, IERC721ReceiverLike {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

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

    event FactorySet(address factory);
    event PositionLocked(address indexed token, uint256 indexed tokenId);
    event TokenSupplyLocked(address indexed token, uint256 amount);
    /**
     * @notice One per `collectFees` that found something to collect. Amounts
     * are in the pool's currency order; `protocol*` plus `creator*` is what
     * the position paid out in each currency.
     */
    event FeesCollected(
        address indexed token,
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
    IPairPadLaunchFactoryView public factory;

    mapping(address token => uint256 tokenId) public lockedPositions;
    mapping(address token => uint256 amount) public lockedTokenSupply;
    mapping(address token => bool locked) private _locked;

    /**
     * @param initialOwner Administrative owner; only used to wire the factory once.
     * @param positionManager_ The canonical Uniswap V4 PositionManager for this chain.
     * @param feeEscrow_ Ledger collected fees are credited to.
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
        factory = IPairPadLaunchFactoryView(factory_);
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
     * @dev Not part of the launch path: the launch names this locker as the
     * `MINT_POSITION` owner and the PositionManager mints with a plain
     * `_mint`, which fires no receiver callback. Custody is established by
     * the `ownerOf` check in `lockPosition`.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721ReceiverLike.onERC721Received.selector;
    }

    /**
     * @notice Registers and verifies permanent custody of a launch position.
     * Called once per launch by the factory, right after the position is
     * minted to this contract.
     */
    function lockPosition(address token, uint256 tokenId) external onlyFactory {
        if (_locked[token]) revert PositionAlreadyLocked();
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert PositionNotHeld();

        _locked[token] = true;
        lockedPositions[token] = tokenId;
        emit PositionLocked(token, tokenId);
    }

    /**
     * @notice Permanently locks launch tokens that did not fit into the
     * position. Rounding dust is normally transferred here directly; this
     * entry point exists for the factory to lock larger remainders explicitly.
     */
    function lockTokenSupply(address token, uint256 amount) external onlyFactory {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        lockedTokenSupply[token] += amount;
        emit TokenSupplyLocked(token, amount);
    }

    function isLocked(address token) external view returns (bool) {
        return _locked[token];
    }

    // ---------------------------------------------------------------------
    // Fee collection
    // ---------------------------------------------------------------------

    /**
     * @notice Fees the launch position has earned and not yet collected, in
     * the pool's currency order. Read from the pool's fee growth, so it is
     * exact to the wei the collection would pay out.
     */
    function pendingFees(address token) external view returns (uint256 amount0, uint256 amount1) {
        IPairPadLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolId poolId = factory.poolKeyFor(token).toId();
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, launch.tickLower, launch.tickUpper);
        // The PositionManager owns every position it manages and salts it
        // with the NFT id.
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(
            poolId, address(positionManager), launch.tickLower, launch.tickUpper, bytes32(launch.positionId)
        );
        unchecked {
            amount0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @notice Collects the launch position's accrued fees, pays the protocol
     * its share and credits the creator's share to the fee escrow. Open to
     * anyone: the recipients are fixed by the launch record, so a stranger
     * calling it only ever does the beneficiaries a favour.
     * @dev The split is by the fee terms frozen at launch. The pool's fee is
     * base + creator tax; the protocol receives its share of the base part
     * and the creator everything else, applied to each currency alike.
     */
    function collectFees(address token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        IPairPadLaunchFactory.LaunchedToken memory launch = _launch(token);
        PoolKey memory key = factory.poolKeyFor(token);
        uint256 tokenId = lockedPositions[token];

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

        _payProtocol(key.currency0, launch.protocolFeeRecipient, protocol0);
        _credit(key.currency0, launch.creatorFeeRecipient, amount0 - protocol0);
        _payProtocol(key.currency1, launch.protocolFeeRecipient, protocol1);
        _credit(key.currency1, launch.creatorFeeRecipient, amount1 - protocol1);

        emit FeesCollected(
            token,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            protocol0,
            protocol1,
            amount0 - protocol0,
            amount1 - protocol1
        );
    }

    function _launch(address token) private view returns (IPairPadLaunchFactory.LaunchedToken memory launch) {
        launch = factory.getLaunchedToken(token);
        if (!launch.exists || !_locked[token]) revert TokenNotLaunched();
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
