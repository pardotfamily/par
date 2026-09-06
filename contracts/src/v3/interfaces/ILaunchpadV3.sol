// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @notice Records kept by PairPadMultiLaunchFactory: one launch, several
 * markets. Every market is a plain hookless Uniswap V4 pool between the launch
 * token and one quote asset, seeded with an equal slice of the supply in a
 * single locked position, all opened at the same ETH-denominated price. The
 * locker, the router and off-chain indexers read these.
 */
interface IPairPadMultiLaunchFactory {
    /// @notice One pool of a launch.
    struct Market {
        address pairToken;
        // Virtual quote reserve this pool's curve opened with, in quote
        // units, for this pool's slice of the supply.
        uint256 phantomQuote;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
    }

    struct LaunchedToken {
        address token;
        address deployer;
        address creatorFeeRecipient;
        // The pools' LP fee in hundredths of a bip; the same on every market.
        uint24 poolFee;
        int24 tickSpacing;
        // Fee terms frozen at launch, applied alike on every market.
        uint16 baseFeeBps;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        address protocolFeeRecipient;
        uint64 launchedAt;
        uint8 marketCount;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function getMarkets(address token) external view returns (Market[] memory);
    function getMarket(address token, uint256 index) external view returns (Market memory);
    function poolKeyFor(address token, uint256 index) external view returns (PoolKey memory);
    function poolKeysFor(address token) external view returns (PoolKey[] memory);
}
