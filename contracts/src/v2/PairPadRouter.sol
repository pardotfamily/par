// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PairPadLaunchFactory} from "./PairPadLaunchFactory.sol";

/// @dev The slice of Uniswap's SwapRouter02 the zap uses. `exactInput` wraps
/// attached native ETH itself when the path starts at WETH9.
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 is IERC20 {
    function withdraw(uint256 amount) external;
}

/**
 * @title PairPadRouter
 * @notice The PairPad frontend's router. Three jobs:
 *
 * - Exact-input swaps through a launch pool. The pools are plain hookless
 *   V4 pools, so any V4 router can trade them; this one exists so the
 *   frontend has one contract for every flow below.
 * - ETH in and out of pools quoted in an ERC-20. The ETH leg is described
 *   by an `EthLeg`: optional Uniswap V3 hops starting (or ending) at WETH,
 *   followed by optional Uniswap V4 hops ending at the quote asset. All V4
 *   hops and the launch pool run inside one PoolManager unlock, so a quote
 *   asset that only trades on V4 (every PONS graduate, every par token) is
 *   reachable from plain ETH without the buyer ever holding it.
 * - Atomic launch-and-buy, as the factory's trusted launch forwarder: the
 *   token is launched for the real caller and their opening buy lands in the
 *   same transaction, ahead of anyone else.
 *
 * The router holds no funds between transactions.
 */
contract PairPadRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    PairPadLaunchFactory public immutable factory;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;

    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();
    error NativeValueMismatch();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error EthTransferFailed();
    error NativeQuoteNeedsNoZap();
    error InsufficientLaunchValue();
    error PathTooShort();
    error PathStartMismatch(address expected);
    error PathEndMismatch(address expected);
    /// @dev Hop `index` does not contain the currency the previous hop produced.
    error RouteBroken(uint256 index);
    /// @dev The route did not end where the caller said it would.
    error RouteEndMismatch(address expected, address actual);

    event ZapBuy(bytes32 indexed poolId, address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event ZapSell(bytes32 indexed poolId, address indexed seller, uint256 tokensIn, uint256 ethOut);

    /**
     * @notice How ETH reaches an ERC-20 quote asset, or the other way round.
     * @param v3Path Uniswap V3 hops on the ETH side, packed as
     *        token(20) . fee(3) . token(20) ... Starts at WETH on a buy and
     *        ends at WETH on a sell. Empty when the leg is entirely on V4.
     * @param v4Hops Uniswap V4 pools between the V3 leg's far end (or native
     *        ETH when `v3Path` is empty) and the quote asset, in trade order.
     *        Empty when the V3 leg already ends at the quote asset.
     */
    struct EthLeg {
        bytes v3Path;
        PoolKey[] v4Hops;
    }

    /// @dev One unlock: `amountIn` of `currencyIn` through `hops` in order.
    struct Route {
        PoolKey[] hops;
        Currency currencyIn;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev Who funds the input: the caller, or this router when the
        /// input was just bought on V3 and already sits here.
        address payer;
        /// @dev Where the final output is taken to.
        address recipient;
        /// @dev The wallet trading; paid any surplus a partially filled hop
        /// leaves behind.
        address swapper;
    }

    constructor(IPoolManager manager_, PairPadLaunchFactory factory_, ISwapRouter02 swapRouter_, IWETH9 weth_) {
        if (
            address(manager_) == address(0) || address(factory_) == address(0) || address(swapRouter_) == address(0)
                || address(weth_) == address(0)
        ) revert ZeroAddress();
        manager = manager_;
        factory = factory_;
        swapRouter = swapRouter_;
        weth = weth_;
    }

    // ---------------------------------------------------------------------
    // Single-pool swap
    // ---------------------------------------------------------------------

    /**
     * @param key        The launch pool's key.
     * @param zeroForOne Direction: true sells currency0 for currency1.
     * @param amountIn   Exact input amount. For a native-ETH input this must
     *                   equal msg.value; for ERC-20 input msg.value must be 0
     *                   and the router needs an allowance from the caller.
     */
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        if (currencyIn.isAddressZero()) {
            if (msg.value != amountIn) revert NativeValueMismatch();
        } else if (msg.value != 0) {
            revert NativeValueMismatch();
        }

        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = key;
        (amountOut,) = _route(
            Route({
                hops: hops,
                currencyIn: currencyIn,
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                payer: msg.sender,
                recipient: recipient,
                swapper: msg.sender
            })
        );
    }

    // ---------------------------------------------------------------------
    // ETH in / out of an ERC-20-quoted pool
    // ---------------------------------------------------------------------

    /**
     * @notice Buys the launch token of `key`, paying in native ETH. The
     * attached value travels along `leg` to the quote asset and straight on
     * through the launch pool to `recipient`. An empty leg on a pool quoted
     * in ETH is just a plain buy.
     */
    function buyWithEth(PoolKey calldata key, EthLeg calldata leg, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        tokensOut = _buyAlongLeg(key, leg, msg.value, minTokensOut, recipient);
        emit ZapBuy(_poolId(key), msg.sender, msg.value, tokensOut);
    }

    /**
     * @notice Sells the launch token of `key` and delivers native ETH to
     * `recipient`: the launch pool and the leg's V4 hops run in one unlock,
     * then the V3 hops (if any) finish at WETH, which is unwrapped. Needs an
     * allowance for the launch token.
     */
    function sellToEth(
        PoolKey calldata key,
        bool tokenIsCurrency0,
        uint256 tokensIn,
        EthLeg calldata leg,
        uint256 minEthOut,
        address recipient
    ) external nonReentrant returns (uint256 ethOut) {
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        bool v3Tail = leg.v3Path.length != 0;
        PoolKey[] memory hops = new PoolKey[](1 + leg.v4Hops.length);
        hops[0] = key;
        for (uint256 i = 0; i < leg.v4Hops.length; i++) {
            hops[i + 1] = leg.v4Hops[i];
        }

        (uint256 out, Currency outCurrency) = _route(
            Route({
                hops: hops,
                currencyIn: tokenIsCurrency0 ? key.currency0 : key.currency1,
                amountIn: tokensIn,
                // With a V3 tail the ETH floor is checked after it.
                minAmountOut: v3Tail ? 0 : minEthOut,
                payer: msg.sender,
                recipient: v3Tail ? address(this) : recipient,
                swapper: msg.sender
            })
        );

        if (!v3Tail) {
            if (!outCurrency.isAddressZero()) revert RouteEndMismatch(address(0), Currency.unwrap(outCurrency));
            ethOut = out;
        } else {
            address first = _requirePathEndpoints(leg.v3Path, address(0), address(weth));
            if (first != Currency.unwrap(outCurrency)) revert RouteEndMismatch(first, Currency.unwrap(outCurrency));
            IERC20(first).forceApprove(address(swapRouter), out);
            ethOut = _v3ExactInput(leg.v3Path, out, minEthOut, 0);
            weth.withdraw(ethOut);
            _sendEth(recipient, ethOut);
        }
        emit ZapSell(_poolId(key), msg.sender, tokensIn, ethOut);
    }

    // ---------------------------------------------------------------------
    // Atomic launch-and-buy (factory launch forwarder)
    // ---------------------------------------------------------------------

    /**
     * @notice Launches a token and lands the caller's opening buy in the same
     * transaction, paying for everything in native ETH. The value above the
     * launch fee travels along `leg` to the quote asset and into the new
     * pool; for a native-quote launch `leg` is ignored.
     * @param minTokensOut Floor on the opening buy.
     */
    function launchAndBuyWithEth(
        PairPadLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        EthLeg calldata leg,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        uint256 launchFee = factory.launchFee();
        if (msg.value < launchFee) revert InsufficientLaunchValue();
        uint256 buyValue = msg.value - launchFee;

        (token, poolId) = factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairToken, msg.sender);
        if (buyValue == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        if (pairToken == address(0)) {
            PoolKey[] memory hops = new PoolKey[](1);
            hops[0] = key;
            (tokensOut,) = _route(
                Route({
                    hops: hops,
                    currencyIn: key.currency0,
                    amountIn: buyValue,
                    minAmountOut: minTokensOut,
                    payer: msg.sender,
                    recipient: msg.sender,
                    swapper: msg.sender
                })
            );
        } else {
            tokensOut = _buyAlongLeg(key, leg, buyValue, minTokensOut, msg.sender);
            emit ZapBuy(PoolId.unwrap(poolId), msg.sender, buyValue, tokensOut);
        }
    }

    /**
     * @notice Launch-and-buy for a caller who already holds the quote asset:
     * the launch fee comes in as value, the opening buy is pulled from the
     * caller's quote balance directly, with no swap leg at all.
     */
    function launchAndBuyWithQuote(
        PairPadLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        if (pairToken == address(0)) revert NativeQuoteNeedsNoZap();
        if (msg.value != factory.launchFee()) revert InsufficientLaunchValue();

        (token, poolId) = factory.launchTokenFor{value: msg.value}(params, launchConfigId, pairToken, msg.sender);
        if (quoteIn == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = key;
        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(pairToken),
                amountIn: quoteIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: msg.sender,
                swapper: msg.sender
            })
        );
    }

    // ---------------------------------------------------------------------
    // Leg assembly
    // ---------------------------------------------------------------------

    /**
     * @dev Spends `ethIn` along `leg` and through the launch pool `key`.
     * With V3 hops the ETH is first swapped there and the proceeds fund the
     * V4 unlock from this contract; without them the unlock is funded with
     * native ETH from the caller and the first V4 hop must be an ETH pool.
     */
    function _buyAlongLeg(
        PoolKey memory key,
        EthLeg calldata leg,
        uint256 ethIn,
        uint256 minTokensOut,
        address recipient
    ) private returns (uint256 tokensOut) {
        PoolKey[] memory hops = new PoolKey[](leg.v4Hops.length + 1);
        for (uint256 i = 0; i < leg.v4Hops.length; i++) {
            hops[i] = leg.v4Hops[i];
        }
        hops[leg.v4Hops.length] = key;

        Currency currencyIn;
        uint256 amountIn;
        address payer;
        if (leg.v3Path.length != 0) {
            address last = _requirePathEndpoints(leg.v3Path, address(weth), address(0));
            currencyIn = Currency.wrap(last);
            amountIn = _v3ExactInput(leg.v3Path, ethIn, 0, ethIn);
            payer = address(this);
        } else {
            currencyIn = Currency.wrap(address(0));
            amountIn = ethIn;
            payer = msg.sender;
        }

        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: currencyIn,
                amountIn: amountIn,
                minAmountOut: minTokensOut,
                payer: payer,
                recipient: recipient,
                swapper: msg.sender
            })
        );
    }

    // ---------------------------------------------------------------------
    // V4 plumbing
    // ---------------------------------------------------------------------

    function _route(Route memory r) private returns (uint256 amountOut, Currency currencyOut) {
        bytes memory result = manager.unlock(abi.encode(r));
        (amountOut, currencyOut) = abi.decode(result, (uint256, Currency));
    }

    /**
     * @dev Runs every hop of the route as an exact-input swap, each fed by
     * the previous hop's output, then settles with the PoolManager. Between
     * hops nothing moves: the intermediate currencies net to zero inside the
     * unlock, unless a hop ran dry and left a surplus, which goes to the
     * swapper.
     */
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));

        Currency current = r.currencyIn;
        uint256 amount = r.amountIn;
        uint256 n = r.hops.length;
        for (uint256 i = 0; i < n; i++) {
            PoolKey memory key = r.hops[i];
            bool zeroForOne;
            if (current == key.currency0) zeroForOne = true;
            else if (current == key.currency1) zeroForOne = false;
            else revert RouteBroken(i);

            BalanceDelta delta = manager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 outSigned = zeroForOne ? delta.amount1() : delta.amount0();
            amount = uint256(uint128(outSigned));
            current = zeroForOne ? key.currency1 : key.currency0;
        }
        if (current == r.currencyIn) revert RouteBroken(n);
        if (amount < r.minAmountOut) revert SlippageExceeded(amount, r.minAmountOut);

        // Pay for the input. A hop that runs out of liquidity owes less than
        // amountIn; the rest goes back to whoever paid.
        uint256 owed = uint256(-_delta(r.currencyIn));
        if (r.currencyIn.isAddressZero()) {
            manager.sync(r.currencyIn);
            manager.settle{value: owed}();
            uint256 excess = r.amountIn - owed;
            if (excess != 0) _sendEth(r.payer == address(this) ? r.swapper : r.payer, excess);
        } else {
            manager.sync(r.currencyIn);
            IERC20 tokenIn = IERC20(Currency.unwrap(r.currencyIn));
            if (r.payer == address(this)) {
                tokenIn.safeTransfer(address(manager), owed);
                uint256 excess = r.amountIn - owed;
                if (excess != 0) tokenIn.safeTransfer(r.swapper, excess);
            } else {
                tokenIn.safeTransferFrom(r.payer, address(manager), owed);
            }
            manager.settle();
        }

        if (amount != 0) manager.take(current, r.recipient, amount);

        // Intermediate currencies only carry a balance when a later hop
        // could not absorb everything the earlier one produced.
        Currency mid = r.currencyIn;
        for (uint256 i = 0; i + 1 < n; i++) {
            PoolKey memory key = r.hops[i];
            mid = mid == key.currency0 ? key.currency1 : key.currency0;
            int256 left = _delta(mid);
            if (left > 0) manager.take(mid, r.swapper, uint256(left));
        }

        return abi.encode(amount, current);
    }

    /// @dev This contract's transient balance of `currency` in the PoolManager.
    function _delta(Currency currency) private view returns (int256) {
        bytes32 slot = keccak256(abi.encode(address(this), Currency.unwrap(currency)));
        return int256(uint256(manager.exttload(slot)));
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _v3ExactInput(bytes calldata path, uint256 amountIn, uint256 minOut, uint256 value)
        private
        returns (uint256)
    {
        return swapRouter.exactInput{value: value}(
            ISwapRouter02.ExactInputParams({
                path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: minOut
            })
        );
    }

    function _poolId(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /**
     * @dev Checks a V3 path's endpoints. A zero `first` or `last` means
     * "any"; the other end is returned so the caller can chain it into the
     * V4 route. Intermediate hops are the caller's choice; the slippage
     * floors are what actually protect the trade.
     */
    function _requirePathEndpoints(bytes calldata path, address first, address last)
        private
        pure
        returns (address other)
    {
        // A V3 path is token(20) . fee(3) . token(20) [. fee(3) . token(20)]...
        if (path.length < 43) revert PathTooShort();
        address start = address(bytes20(path[:20]));
        address end = address(bytes20(path[path.length - 20:]));
        if (first != address(0) && start != first) revert PathStartMismatch(first);
        if (last != address(0) && end != last) revert PathEndMismatch(last);
        other = first == address(0) ? start : end;
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }

    /// @notice Accepts PoolManager settle flows and WETH withdrawals.
    receive() external payable {}
}
