// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadPositionMath} from "../v2/libraries/PairPadPositionMath.sol";

/**
 * @title PairPadMultiPositionMinter
 * @notice Lays out and mints the locked positions of a multi-market launch
 * on PairPadMultiLaunchFactory's behalf: one single-sided position per
 * market, each seeded with an equal slice of the supply. Split out of the
 * factory so its bytecode stays under EIP-170's size limit.
 *
 * The launch token mints its whole supply to this contract, the factory calls
 * `mintLaunchPositions` in the same transaction, and the PositionManager
 * pulls each slice from here into its pool. Whatever the pools' rounding
 * leaves behind is sent to the locker once, after the last mint, so supply
 * that did not reach a pool never circulates.
 */
contract PairPadMultiPositionMinter {
    using SafeERC20 for IERC20;

    uint256 private constant MINT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error ZeroAddress();
    error SupplyNotReceived(uint256 expected, uint256 held);
    error LengthMismatch();

    event LaunchDustLocked(address indexed launchToken, uint256 amount);

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable locker;
    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPositionManager positionManager_, IAllowanceTransfer permit2_, address locker_, address factory_) {
        if (address(positionManager_) == address(0) || address(permit2_) == address(0)) revert ZeroAddress();
        if (locker_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        factory = factory_;
    }

    /**
     * @notice The opening price, tick range and liquidity one market gets
     * for `supply` tokens against `phantomQuote`. Pure math, exposed so the
     * factory (and anyone previewing a launch) reads it from one place.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        external
        pure
        returns (PairPadPositionMath.Plan memory)
    {
        return PairPadPositionMath.plan(tokenIsCurrency0, supply, phantomQuote, tickSpacing);
    }

    /**
     * @notice Mints one position per market to the locker out of the token
     * supply this contract holds. Every pool must already be initialized at
     * its plan's sqrt price, so each position is one-sided and needs no quote.
     * @param supplyEach The slice of the supply each market receives.
     * @return positionIds PositionManager token ids, in market order.
     * @return tokenAmounts The supply actually placed in each pool.
     */
    function mintLaunchPositions(
        address launchToken,
        PoolKey[] calldata keys,
        PairPadPositionMath.Plan[] calldata plans,
        uint256 supplyEach
    ) external onlyFactory returns (uint256[] memory positionIds, uint256[] memory tokenAmounts) {
        uint256 n = keys.length;
        if (n == 0 || plans.length != n) revert LengthMismatch();
        uint256 held = IERC20(launchToken).balanceOf(address(this));
        if (held < supplyEach * n) revert SupplyNotReceived(supplyEach * n, held);

        _approvePermit2(launchToken, held);

        positionIds = new uint256[](n);
        tokenAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 before = IERC20(launchToken).balanceOf(address(this));
            positionIds[i] = positionManager.nextTokenId();
            _mint(launchToken, keys[i], plans[i], supplyEach);
            tokenAmounts[i] = before - IERC20(launchToken).balanceOf(address(this));
        }

        uint256 left = IERC20(launchToken).balanceOf(address(this));
        if (left != 0) {
            // The locker has no way to move tokens out, so a plain transfer
            // is as locked as the positions themselves.
            IERC20(launchToken).safeTransfer(locker, left);
            emit LaunchDustLocked(launchToken, left);
        }
    }

    function _mint(address launchToken, PoolKey calldata key, PairPadPositionMath.Plan calldata p, uint256 supply)
        private
    {
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == launchToken;
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            // The quote side must come out to exactly zero at the boundary
            // price; a nonzero quote requirement means the pool was not
            // initialized where the plan expects.
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(supply) : uint128(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(0) : uint128(supply),
            locker,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + MINT_DEADLINE_WINDOW);
    }

    function _approvePermit2(address token, uint256 amount) private {
        IERC20(token).forceApprove(address(permit2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp + MINT_DEADLINE_WINDOW));
    }
}
