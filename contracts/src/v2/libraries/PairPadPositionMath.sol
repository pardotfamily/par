// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/**
 * @title PairPadPositionMath
 * @notice The math behind a PairPad launch pool.
 *
 * A constant-product bonding curve with a phantom quote reserve P and a token
 * supply S has the invariant (P + q) * t = P * S, where q is the real quote
 * deposited and t the tokens left. A Uniswap V3-style position with
 * liquidity L = sqrt(P * S) whose range starts at the opening price P / S
 * and runs to the top of the tick space has exactly the same invariant: its
 * virtual reserves at the opening price are S tokens and P quote, none of
 * the quote is real, and the quote it holds after trading is what buyers
 * paid in. So one single-sided position seeded with the whole supply *is*
 * the curve, with no separate contract and nothing to migrate later.
 *
 * `plan` turns launch terms into the pool's opening sqrt price, the
 * position's tick range and its liquidity. `amountsForLiquidity` reads a
 * position's holdings back at any price, which is how the hook measures the
 * quote raised for the graduation milestone.
 */
library PairPadPositionMath {
    error ZeroAmount();
    error UnsupportedPrice();
    error PositionTooSmall();
    error InvalidTickSpacing();

    // Widest ticks usable at any tick spacing, matching v4-core's own MIN/MAX_TICK.
    int24 private constant MIN_USABLE_TICK = -887272;
    int24 private constant MAX_USABLE_TICK = 887272;

    struct Plan {
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /**
     * @notice Lays out the launch position for `supply` tokens against a
     * phantom reserve of `phantomQuote`.
     * @dev The opening tick is rounded to the nearest multiple of the tick
     * spacing, so the realised opening price differs from P / S by at most
     * half a spacing. The pool must be initialized at exactly the returned
     * sqrt price: that puts the current tick on the position's boundary, so
     * minting needs only the token side and no quote at all.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        internal
        pure
        returns (Plan memory p)
    {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        if (supply == 0 || phantomQuote == 0) revert ZeroAmount();

        // Pool price is always currency1 per currency0.
        uint160 openingSqrtPrice = tokenIsCurrency0
            ? sqrtPriceX96FromAmounts(supply, phantomQuote)
            : sqrtPriceX96FromAmounts(phantomQuote, supply);
        if (openingSqrtPrice <= TickMath.MIN_SQRT_PRICE || openingSqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert UnsupportedPrice();
        }
        int24 openingTick = _nearestUsableTick(TickMath.getTickAtSqrtPrice(openingSqrtPrice), tickSpacing);

        if (tokenIsCurrency0) {
            // Buys push the price up: the position sits above the current tick.
            p.tickLower = openingTick;
            p.tickUpper = _floorToSpacing(MAX_USABLE_TICK, tickSpacing);
            if (p.tickLower >= p.tickUpper) revert UnsupportedPrice();
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(p.tickUpper);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount0(p.sqrtPriceX96, sqrtUpper, supply);
            // The pool charges a minter rounding up, and the liquidity above
            // was rounded down from a slightly different formula, so the
            // amount it asks for can land a wei or two over the supply.
            while (p.liquidity != 0 && SqrtPriceMath.getAmount0Delta(p.sqrtPriceX96, sqrtUpper, p.liquidity, true) > supply)
            {
                p.liquidity -= 1;
            }
        } else {
            // Buys (quote in as currency0) push the price down: the position
            // sits below the current tick.
            p.tickUpper = openingTick;
            p.tickLower = _ceilToSpacing(MIN_USABLE_TICK, tickSpacing);
            if (p.tickLower >= p.tickUpper) revert UnsupportedPrice();
            p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(p.tickUpper);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(p.tickLower);
            p.liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, p.sqrtPriceX96, supply);
            while (p.liquidity != 0 && SqrtPriceMath.getAmount1Delta(sqrtLower, p.sqrtPriceX96, p.liquidity, true) > supply)
            {
                p.liquidity -= 1;
            }
        }
        if (p.liquidity == 0) revert PositionTooSmall();
    }

    /**
     * @notice The token amount the pool will actually pull for `p`, rounded
     * up the way the PoolManager charges a minter. Always at most the supply
     * `plan` was given; whatever is left is dust.
     */
    function tokenAmountFor(bool tokenIsCurrency0, Plan memory p) internal pure returns (uint256) {
        return tokenIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(p.sqrtPriceX96, TickMath.getSqrtPriceAtTick(p.tickUpper), p.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(p.tickLower), p.sqrtPriceX96, p.liquidity, true);
    }

    /**
     * @notice The token0/token1 a position of `liquidity` over
     * [tickLower, tickUpper] holds at `sqrtPriceX96`, rounded down.
     */
    function amountsForLiquidity(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    /**
     * @notice Computes sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        if (_fitsQ192(amount0, amount1)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160(Math.sqrt(ratioX192));
        }

        if (!_fitsQ128(amount0, amount1)) revert UnsupportedPrice();
        uint256 ratioX128 = FullMath.mulDiv(amount1, 1 << 128, amount0);
        uint256 sqrtPriceX64 = Math.sqrt(ratioX128);
        if (sqrtPriceX64 > type(uint128).max) revert UnsupportedPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX64 << 32);
    }

    function _nearestUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 floored = _floorToSpacing(tick, tickSpacing);
        int24 rounded = tick - floored >= tickSpacing / 2 ? floored + tickSpacing : floored;
        int24 lo = _ceilToSpacing(MIN_USABLE_TICK, tickSpacing);
        int24 hi = _floorToSpacing(MAX_USABLE_TICK, tickSpacing);
        if (rounded < lo) return lo;
        if (rounded > hi) return hi;
        return rounded;
    }

    function _floorToSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 q = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) q -= 1;
        return q * tickSpacing;
    }

    function _ceilToSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 q = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) q += 1;
        return q * tickSpacing;
    }

    function _fitsQ192(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint192).max) return true;
        return amount1 < (amount0 << 64);
    }

    function _fitsQ128(uint256 amount0, uint256 amount1) private pure returns (bool) {
        if (amount0 > type(uint128).max) return true;
        return amount1 < (amount0 << 128);
    }
}
