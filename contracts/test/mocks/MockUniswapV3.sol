// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @dev Just enough of a Uniswap V3 pool for PairPadQuotePricer: a fixed tick
 * served through observe()/slot0(), a configurable liquidity figure, and
 * whatever token balances the test mints onto the pool address.
 */
contract MockV3Pool {
    int24 public tick;
    uint128 private _liquidity;
    uint32 private immutable _createdAt;

    constructor(int24 tick_, uint128 liquidity_) {
        tick = tick_;
        _liquidity = liquidity_;
        _createdAt = uint32(block.timestamp);
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function liquidity() external view returns (uint128) {
        return _liquidity;
    }

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick_, uint16, uint16, uint16, uint8, bool)
    {
        return (TickMath.getSqrtPriceAtTick(tick), tick, 0, 1, 1, 0, true);
    }

    function observations(uint256)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, uint160, bool initialized)
    {
        return (_createdAt, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            // A constant tick since inception: cumulative = tick * age.
            uint256 age = block.timestamp - secondsAgos[i] - _createdAt;
            tickCumulatives[i] = int56(tick) * int56(uint56(age));
        }
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[tokenA][tokenB][fee] = pool;
        _pools[tokenB][tokenA][fee] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[tokenA][tokenB][fee];
    }
}
