// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice Shared PairPad interfaces: the fee escrow and the launch factory's
 * records. Uniswap V4 core and periphery types are imported directly from
 * the vendored packages by the contracts that need them.
 */

/**
 * @notice Claimable balance ledger the locker pays collected fees into.
 * Native ETH crediting is permissionless (callers attach the ETH they are
 * crediting). Token crediting pulls the tokens from the caller, so it is
 * equally safe to leave open.
 */
interface IPairPadFeeEscrow {
    function credit(address recipient) external payable;
    function creditToken(address recipient, address token, uint256 amount) external;
    function claim() external returns (uint256 amount);
    function claim(uint256 amount) external returns (uint256);
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/**
 * @notice Minimal ERC-721 receiver signature used by PairPadLaunchLocker to
 * accept the Uniswap V4 position NFT.
 */
interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/**
 * @notice Record kept by PairPadLaunchFactory for every launch, readable by
 * the locker, the router and off-chain indexers.
 *
 * A launch is one plain Uniswap V4 pool, no hook, from its first second. The
 * whole supply sits in a single position owned by the locker, ranged from
 * the opening price upward, so the pool trades like a constant-product curve
 * with a phantom quote reserve: no quote is needed to open it and the price
 * cannot fall below the opening price. The pool's static LP fee is the
 * launch's whole trading fee; since the locked position is the only
 * liquidity the launch put in, that fee accrues to the locker, which splits
 * it between the protocol and the creator.
 */
interface IPairPadLaunchFactory {
    struct LaunchedToken {
        address token;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        // Virtual quote reserve the curve opened with, in quote units.
        uint256 phantomQuote;
        // The pool's LP fee in hundredths of a bip (1% = 10_000). Equals
        // (baseFeeBps + creatorTaxBps) * 100.
        uint24 poolFee;
        int24 tickSpacing;
        // The locked position's range and size.
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionId;
        // Fee terms frozen at launch. The base fee is split between the
        // protocol and the creator by protocolFeeShareBps; the creator tax
        // goes to the creator whole.
        uint16 baseFeeBps;
        uint16 creatorTaxBps;
        uint16 protocolFeeShareBps;
        address protocolFeeRecipient;
        uint64 launchedAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}
