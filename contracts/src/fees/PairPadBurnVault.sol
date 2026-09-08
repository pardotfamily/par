// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";

/// @dev The one router function the vault uses: an exact-input swap through
/// a single hookless V4 pool, paid by msg.sender (native value or allowance).
interface IPairPadSwapRouter {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
}

/// @dev What the vault reads from the single-market factory.
interface ISingleLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/// @dev What the vault reads from the multi-market factory.
interface IMultiLaunchFactory {
    function poolKeysFor(address token) external view returns (PoolKey[] memory);
}

/**
 * @title PairPadBurnVault
 * @notice The creator fee recipient of launches whose creator chose, at
 * creation, to give the creator's share of trading fees back to the token:
 * the part paid in the token is burned, the part paid in the quote asset
 * buys the token in its own launch pool and that is burned too. The
 * factories snapshot the recipient and only the recipient itself may ever
 * change it; this contract has no such function, so the choice is permanent
 * for the life of the token.
 *
 * The lockers credit the creator share to the fee escrow under this
 * address. There is no owner and no function that moves value anywhere
 * other than into a par launch pool or to the zero address:
 *
 * - `burnToken` claims a token's share from the escrow and burns it. Anyone
 *   may call it.
 * - `buyback` claims the quote share, spends `amountIn` of `quote` buying
 *   `token` through the par router in the pool the factory recorded for
 *   that pair (never a pool named by the caller), and burns what it bought.
 *   Only the operator may call it, because it carries the swap's slippage
 *   floor; the operator can misprice or delay a round, not redirect it.
 *
 * One vault serves every opted-in launch, so the quote it holds is pooled
 * across them. Which launch each amount came from is exact from the
 * lockers' FeesCollected events, and every round emits the token and the
 * quote spent on it, so the attribution can be checked from the chain.
 */
contract PairPadBurnVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPairPadFeeEscrow public immutable escrow;
    IPairPadSwapRouter public immutable router;
    ISingleLaunchFactory public immutable factory;
    IMultiLaunchFactory public immutable multiFactory;
    address public immutable operator;

    /// @notice Tokens burned per launch token, from both sides of the fee.
    mapping(address token => uint256) public burned;
    /// @notice Quote spent buying back per launch token per quote asset (address zero for ETH).
    mapping(address token => mapping(address quote => uint256)) public spent;

    event Burned(address indexed token, uint256 amount);
    event BoughtBack(address indexed token, address indexed quote, uint256 quoteIn, uint256 tokensOut);

    error ZeroAddress();
    error ZeroAmount();
    error NotOperator();
    error NoMarket(address token, address quote);

    constructor(
        IPairPadFeeEscrow escrow_,
        IPairPadSwapRouter router_,
        ISingleLaunchFactory factory_,
        IMultiLaunchFactory multiFactory_,
        address operator_
    ) {
        if (
            address(escrow_) == address(0) || address(router_) == address(0) || address(factory_) == address(0)
                || address(multiFactory_) == address(0) || operator_ == address(0)
        ) revert ZeroAddress();
        escrow = escrow_;
        router = router_;
        factory = factory_;
        multiFactory = multiFactory_;
        operator = operator_;
    }

    /// @dev The escrow pays claimed ETH here.
    receive() external payable {}

    /**
     * @notice Claims `token`'s share held for this vault in the escrow and
     * burns this contract's whole balance of it. Anyone may call.
     */
    function burnToken(address token) external nonReentrant returns (uint256 amount) {
        if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;
        _burn(token, amount);
    }

    /**
     * @notice Spends `amountIn` of `quote` (address zero for ETH) buying
     * `token` in the launch pool the factory recorded for that pair, then
     * burns everything this contract holds of `token`, including any share
     * still waiting in the escrow.
     * @param minTokensOut Floor on the swap; the round reverts below it.
     */
    function buyback(address token, address quote, uint256 amountIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut, uint256 burnedNow)
    {
        if (msg.sender != operator) revert NotOperator();
        if (amountIn == 0) revert ZeroAmount();

        PoolKey memory key = _poolKey(token, quote);
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;

        if (quote == address(0)) {
            if (address(this).balance < amountIn && escrow.balanceOf(address(this)) > 0) escrow.claim();
            tokensOut = router.swapExactIn{value: amountIn}(key, zeroForOne, amountIn, minTokensOut, address(this));
        } else {
            if (IERC20(quote).balanceOf(address(this)) < amountIn && escrow.balanceOfToken(address(this), quote) > 0) {
                escrow.claimToken(quote);
            }
            IERC20(quote).forceApprove(address(router), amountIn);
            tokensOut = router.swapExactIn(key, zeroForOne, amountIn, minTokensOut, address(this));
            IERC20(quote).forceApprove(address(router), 0);
        }
        spent[token][quote] += amountIn;
        emit BoughtBack(token, quote, amountIn, tokensOut);

        if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
        burnedNow = IERC20(token).balanceOf(address(this));
        _burn(token, burnedNow);
    }

    /// @notice What the escrow holds for this vault in `asset` (address zero for ETH), not yet claimed.
    function pending(address asset) external view returns (uint256) {
        return asset == address(0) ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), asset);
    }

    /// @notice The pool `buyback` would trade for this pair. Reverts if the
    /// token was not launched on par with `quote` as one of its markets.
    function poolKeyFor(address token, address quote) external view returns (PoolKey memory) {
        return _poolKey(token, quote);
    }

    function _poolKey(address token, address quote) internal view returns (PoolKey memory key) {
        // Single-market factory first; its lookup reverts for unknown tokens.
        (bool ok, bytes memory data) =
            address(factory).staticcall(abi.encodeWithSelector(ISingleLaunchFactory.poolKeyFor.selector, token));
        if (ok && data.length >= 32 * 5) {
            key = abi.decode(data, (PoolKey));
            if (_other(key, token) == quote) return key;
        }
        (ok, data) =
            address(multiFactory).staticcall(abi.encodeWithSelector(IMultiLaunchFactory.poolKeysFor.selector, token));
        if (ok) {
            PoolKey[] memory keys = abi.decode(data, (PoolKey[]));
            for (uint256 i = 0; i < keys.length; i++) {
                if (_other(keys[i], token) == quote) return keys[i];
            }
        }
        revert NoMarket(token, quote);
    }

    /// @dev The currency of `key` that is not `token`.
    function _other(PoolKey memory key, address token) private pure returns (address) {
        address c0 = Currency.unwrap(key.currency0);
        return c0 == token ? Currency.unwrap(key.currency1) : c0;
    }

    /// @dev Every launch token is a PairPadLauncherToken, which is
    /// ERC20Burnable: the supply actually shrinks.
    function _burn(address token, uint256 amount) private {
        if (amount == 0) return;
        ERC20Burnable(token).burn(amount);
        burned[token] += amount;
        emit Burned(token, amount);
    }
}
