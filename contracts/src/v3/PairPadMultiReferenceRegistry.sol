// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IQuoteReferenceRegistry} from "../v2/PairPadQuotePricer.sol";
import {IPairPadMultiLaunchFactory} from "./interfaces/ILaunchpadV3.sol";

/**
 * @notice Hands the quote pricer a pool key for any token launched through
 * the multi-market factory, so such a token can be the quote of a later
 * launch. Prefers the token's native-ETH market, since the pricer anchors in
 * ETH; otherwise the first market, which the pricer then prices through that
 * market's quote asset.
 */
contract PairPadMultiReferenceRegistry is IQuoteReferenceRegistry {
    IPairPadMultiLaunchFactory public immutable factory;

    constructor(IPairPadMultiLaunchFactory factory_) {
        factory = factory_;
    }

    function referencePool(address token) external view returns (bool found, PoolKey memory key) {
        IPairPadMultiLaunchFactory.LaunchedToken memory launch = factory.getLaunchedToken(token);
        if (!launch.exists) return (false, key);
        IPairPadMultiLaunchFactory.Market[] memory markets = factory.getMarkets(token);
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i].pairToken == address(0)) return (true, factory.poolKeyFor(token, i));
        }
        return (true, factory.poolKeyFor(token, 0));
    }
}
