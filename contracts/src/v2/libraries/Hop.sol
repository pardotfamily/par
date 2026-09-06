// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @notice One pool on a route between two assets. The quote pricer prices an
 * asset by walking a route of these from the asset to ETH; the router walks
 * the same route with real funds. Keeping one shape for both means a route
 * the pricer accepts is, hop for hop, a route the router can trade.
 * @param key For a Uniswap V4 hop, the pool key. For a Uniswap V3 hop,
 *        `currency0` and `currency1` are the pool's two tokens in address
 *        order, `fee` is the V3 fee tier, and `tickSpacing` and `hooks` are
 *        zero; the pool address is whatever the V3 factory returns for them.
 * @param v3 True for a Uniswap V3 pool, false for V4.
 */
struct Hop {
    PoolKey key;
    bool v3;
}
