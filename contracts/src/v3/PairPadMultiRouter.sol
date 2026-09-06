// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PairPadMultiLaunchFactory} from "./PairPadMultiLaunchFactory.sol";
import {ISwapRouter02, IWETH9} from "../v2/PairPadRouter.sol";
import {Hop} from "../v2/libraries/Hop.sol";

/**
 * @title PairPadMultiRouter
 * @notice The frontend's router for multi-market launches. A trade is split
 * into one leg per market and every leg runs inside a single PoolManager
 * unlock, so a buyer pays plain ETH once and receives the token once, and a
 * seller hands over the token once and receives plain ETH once, whatever
 * quote assets the markets are in. The caller decides the split (the
 * interface sizes each leg by its market's depth); the router only enforces
 * the total floor.
 *
 * Each leg names the market it trades and the route between ETH and that
 * market's quote asset, as a list of Uniswap V3/V4 hops in the shape the quote
 * pricer produces. The launch pool itself is looked up from the factory, so a
 * leg can only ever trade a real market of the token.
 *
 * Also the factory's trusted launch forwarder for atomic launch-and-buy. The
 * router holds no funds between transactions.
 */
contract PairPadMultiRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    PairPadMultiLaunchFactory public immutable factory;
    ISwapRouter02 public immutable swapRouter;
    IWETH9 public immutable weth;

    error NotPoolManager();
    error ZeroAmount();
    error ZeroAddress();
    error NativeValueMismatch();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error EthTransferFailed();
    error InsufficientLaunchValue();
    error NoLegs();
    error LengthMismatch();
    /// @dev Hop `index` does not contain the asset the previous hop produced.
    error RouteBroken(uint256 index);
    /// @dev The route did not end where the caller said it would.
    error RouteEndMismatch(address expected, address actual);
    /// @dev A leg meant to end in a quote asset carried extra hops.
    error LegMustEndAtQuote();

    event MultiBuy(address indexed token, address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 legs);
    event MultiSell(address indexed token, address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 legs);
    event MultiSellToQuotes(address indexed token, address indexed seller, uint256 tokensIn, uint256 legs);

    /**
     * @notice One slice of a trade.
     * @param market Index of the launch market the slice trades.
     * @param hops   Route between ETH and the market's quote asset: for a buy
     *               ETH first and the quote last, for a sell the quote first
     *               and ETH last. Empty for a market quoted in ETH.
     * @param amountIn For a buy the ETH spent on this slice; for a sell the
     *               tokens sold through this market.
     */
    struct Leg {
        uint8 market;
        Hop[] hops;
        uint256 amountIn;
    }

    /// @dev Where the asset being routed currently sits.
    enum Where {
        Caller,
        Manager,
        Router
    }

    /// @dev One path through the pools: `amountIn` of `currencyIn` along `hops`.
    struct Route {
        Hop[] hops;
        Currency currencyIn;
        uint256 amountIn;
        uint256 minAmountOut;
        Currency currencyOut;
    }

    /// @dev One unlock: several routes funded by `payer`, delivered to `recipient`.
    struct Batch {
        Route[] routes;
        address payer;
        address recipient;
        /// @dev True: every route ends in the same asset and the floor is on
        /// the sum, delivered once. False: each route is delivered on its
        /// own against its own floor.
        bool aggregate;
        /// @dev Aggregate mode only: deliver native ETH, unwrapping WETH.
        bool ethOut;
        /// @dev Aggregate mode, token out: the asset every route must end in.
        Currency currencyOut;
        uint256 minAmountOut;
    }

    constructor(IPoolManager manager_, PairPadMultiLaunchFactory factory_, ISwapRouter02 swapRouter_, IWETH9 weth_) {
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
    // Buy and sell across markets
    // ---------------------------------------------------------------------

    /**
     * @notice Buys `token` with native ETH split over `legs`. The legs'
     * amounts must add up to msg.value. Tokens from every market are
     * delivered together to `recipient`; `minTokensOut` is on the total.
     */
    function buyWithEth(address token, Leg[] calldata legs, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        tokensOut = _buy(token, legs, msg.value, minTokensOut, recipient);
        emit MultiBuy(token, msg.sender, msg.value, tokensOut, legs.length);
    }

    /**
     * @notice Sells `token` through `legs` (each its slice of tokens, then
     * the route from that market's quote to ETH) and delivers native ETH to
     * `recipient`; `minEthOut` is on the total. Needs an allowance for the
     * sum of the slices.
     */
    function sellToEth(address token, Leg[] calldata legs, uint256 minEthOut, address recipient)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 n = legs.length;
        if (n == 0) revert NoLegs();
        PoolKey[] memory keys = factory.poolKeysFor(token);
        Currency tokenCurrency = Currency.wrap(token);

        Route[] memory routes = new Route[](n);
        uint256 tokensIn;
        for (uint256 i = 0; i < n; i++) {
            if (legs[i].amountIn == 0) revert ZeroAmount();
            tokensIn += legs[i].amountIn;
            Hop[] memory hops = new Hop[](1 + legs[i].hops.length);
            hops[0] = Hop({key: keys[legs[i].market], v3: false});
            for (uint256 j = 0; j < legs[i].hops.length; j++) {
                hops[j + 1] = legs[i].hops[j];
            }
            routes[i] = Route({
                hops: hops,
                currencyIn: tokenCurrency,
                amountIn: legs[i].amountIn,
                minAmountOut: 0,
                currencyOut: Currency.wrap(address(0))
            });
        }
        ethOut = _run(
            Batch({
                routes: routes,
                payer: msg.sender,
                recipient: recipient,
                aggregate: true,
                ethOut: true,
                currencyOut: Currency.wrap(address(0)),
                minAmountOut: minEthOut
            })
        );
        emit MultiSell(token, msg.sender, tokensIn, ethOut, n);
    }

    /**
     * @notice Sells `token` through `legs` and delivers each market's quote
     * asset as it is, one floor per leg. Legs carry no hops here.
     */
    function sellToQuotes(address token, Leg[] calldata legs, uint256[] calldata minOuts, address recipient)
        external
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 n = legs.length;
        if (n == 0) revert NoLegs();
        if (minOuts.length != n) revert LengthMismatch();
        PoolKey[] memory keys = factory.poolKeysFor(token);
        Currency tokenCurrency = Currency.wrap(token);

        Route[] memory routes = new Route[](n);
        uint256 tokensIn;
        for (uint256 i = 0; i < n; i++) {
            if (legs[i].amountIn == 0) revert ZeroAmount();
            if (legs[i].hops.length != 0) revert LegMustEndAtQuote();
            tokensIn += legs[i].amountIn;
            PoolKey memory key = keys[legs[i].market];
            Hop[] memory hops = new Hop[](1);
            hops[0] = Hop({key: key, v3: false});
            routes[i] = Route({
                hops: hops,
                currencyIn: tokenCurrency,
                amountIn: legs[i].amountIn,
                minAmountOut: minOuts[i],
                currencyOut: Currency.unwrap(key.currency0) == token ? key.currency1 : key.currency0
            });
        }
        _run(
            Batch({
                routes: routes,
                payer: msg.sender,
                recipient: recipient,
                aggregate: false,
                ethOut: false,
                currencyOut: Currency.wrap(address(0)),
                minAmountOut: 0
            })
        );
        emit MultiSellToQuotes(token, msg.sender, tokensIn, n);
    }

    /**
     * @notice Buys through one market, paying in that market's quote asset
     * directly (or ETH for an ETH market). Needs an allowance for an ERC-20
     * quote.
     */
    function buyWithQuote(address token, uint8 market, uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        PoolKey memory key = factory.poolKeyFor(token, market);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        Currency quote = tokenIs0 ? key.currency1 : key.currency0;
        if (quote.isAddressZero()) {
            if (msg.value != quoteIn) revert NativeValueMismatch();
        } else if (msg.value != 0) {
            revert NativeValueMismatch();
        }

        Route[] memory routes = new Route[](1);
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, v3: false});
        routes[0] = Route({
            hops: hops, currencyIn: quote, amountIn: quoteIn, minAmountOut: minTokensOut, currencyOut: Currency.wrap(token)
        });
        tokensOut = _run(
            Batch({
                routes: routes,
                payer: msg.sender,
                recipient: recipient,
                aggregate: true,
                ethOut: false,
                currencyOut: Currency.wrap(token),
                minAmountOut: minTokensOut
            })
        );
    }

    // ---------------------------------------------------------------------
    // Atomic launch-and-buy (factory launch forwarder)
    // ---------------------------------------------------------------------

    /**
     * @notice Launches a token on `pairTokens` and lands the caller's opening
     * buy across the new markets in the same transaction, all paid in native
     * ETH. msg.value is the launch fee plus the legs' amounts; with no legs
     * only the launch happens.
     */
    function launchAndBuyWithEth(
        PairPadMultiLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        Leg[] calldata legs,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, uint256 tokensOut) {
        uint256 launchFee = factory.launchFee();
        if (msg.value < launchFee) revert InsufficientLaunchValue();
        uint256 buyValue = msg.value - launchFee;

        token = factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairTokens, msg.sender);
        if (buyValue == 0 && legs.length == 0) return (token, 0);

        tokensOut = _buy(token, legs, buyValue, minTokensOut, msg.sender);
        emit MultiBuy(token, msg.sender, buyValue, tokensOut, legs.length);
    }

    // ---------------------------------------------------------------------
    // Leg assembly
    // ---------------------------------------------------------------------

    function _buy(address token, Leg[] calldata legs, uint256 ethIn, uint256 minTokensOut, address recipient)
        private
        returns (uint256 tokensOut)
    {
        uint256 n = legs.length;
        if (n == 0) revert NoLegs();
        PoolKey[] memory keys = factory.poolKeysFor(token);

        Route[] memory routes = new Route[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (legs[i].amountIn == 0) revert ZeroAmount();
            total += legs[i].amountIn;
            Hop[] memory hops = new Hop[](legs[i].hops.length + 1);
            for (uint256 j = 0; j < legs[i].hops.length; j++) {
                hops[j] = legs[i].hops[j];
            }
            hops[legs[i].hops.length] = Hop({key: keys[legs[i].market], v3: false});
            routes[i] = Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: legs[i].amountIn,
                minAmountOut: 0,
                currencyOut: Currency.wrap(token)
            });
        }
        if (total != ethIn) revert NativeValueMismatch();

        tokensOut = _run(
            Batch({
                routes: routes,
                payer: msg.sender,
                recipient: recipient,
                aggregate: true,
                ethOut: false,
                currencyOut: Currency.wrap(token),
                minAmountOut: minTokensOut
            })
        );
    }

    // ---------------------------------------------------------------------
    // Route engine
    // ---------------------------------------------------------------------

    function _run(Batch memory b) private returns (uint256 amountOut) {
        bytes memory result = manager.unlock(abi.encode(b));
        amountOut = abi.decode(result, (uint256));
    }

    /**
     * @dev Walks every route hop by hop, tracking where the asset sits (see
     * PairPadRouter for the single-route version this generalizes). In
     * aggregate mode each route's output is gathered in one place, the sum
     * checked against the floor and delivered once; otherwise each route is
     * checked and delivered on its own.
     */
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Batch memory b = abi.decode(raw, (Batch));

        uint256 total;
        for (uint256 r = 0; r < b.routes.length; r++) {
            Route memory route = b.routes[r];
            (Currency cur, uint256 amt, Where at) = _walk(route, b.payer);

            if (!b.aggregate) {
                if (amt < route.minAmountOut) revert SlippageExceeded(amt, route.minAmountOut);
                _deliver(cur, amt, at, route.currencyOut, b.recipient);
                total += amt;
                continue;
            }

            if (b.ethOut) {
                // Gather as native ETH in this contract.
                if (!_isEth(cur)) revert RouteEndMismatch(address(0), Currency.unwrap(cur));
                if (at == Where.Manager) {
                    manager.take(cur, address(this), amt);
                    at = Where.Router;
                }
                (cur, amt) = _toNative(cur, amt);
            } else {
                // Gather as a PoolManager credit: the launch pool is a V4
                // hop and always the last one, so the output is already there.
                if (!(cur == b.currencyOut)) revert RouteEndMismatch(Currency.unwrap(b.currencyOut), Currency.unwrap(cur));
                if (at != Where.Manager) {
                    _settleFromRouter(cur, amt);
                }
            }
            total += amt;
        }

        if (b.aggregate) {
            if (total < b.minAmountOut) revert SlippageExceeded(total, b.minAmountOut);
            if (total != 0) {
                if (b.ethOut) _sendEth(b.recipient, total);
                else manager.take(b.currencyOut, b.recipient, total);
            }
        }
        return abi.encode(total);
    }

    function _walk(Route memory r, address payer) private returns (Currency cur, uint256 amt, Where at) {
        cur = r.currencyIn;
        amt = r.amountIn;
        at = Where.Caller;
        uint256 n = r.hops.length;
        for (uint256 i = 0; i < n; i++) {
            Hop memory hop = r.hops[i];
            (Currency hopIn, Currency hopOut, bool ok) = _sides(hop, cur);
            if (!ok) revert RouteBroken(i);
            if (hop.v3) {
                (cur, amt, at) = _v3Hop(hop, cur, hopOut, amt, at, payer);
            } else {
                (cur, amt, at) = _v4Hop(hop, cur, hopIn, hopOut, amt, at, payer);
            }
        }
    }

    function _deliver(Currency cur, uint256 amt, Where at, Currency currencyOut, address recipient) private {
        if (!(cur == currencyOut)) revert RouteEndMismatch(Currency.unwrap(currencyOut), Currency.unwrap(cur));
        if (amt == 0) return;
        if (at == Where.Manager) manager.take(cur, recipient, amt);
        else if (cur.isAddressZero()) _sendEth(recipient, amt);
        else IERC20(Currency.unwrap(cur)).safeTransfer(recipient, amt);
    }

    /**
     * @dev One V4 swap. The input is settled according to where it sits;
     * the output stays as a credit in the PoolManager for the next hop.
     */
    function _v4Hop(
        Hop memory hop,
        Currency cur,
        Currency hopIn,
        Currency hopOut,
        uint256 amt,
        Where at,
        address payer
    ) private returns (Currency, uint256, Where) {
        if (!(cur == hopIn)) {
            (cur, amt, at) = _bring(cur, amt, at, payer);
            (cur, amt) = hopIn.isAddressZero() ? _toNative(cur, amt) : _toWeth(cur, amt);
        }

        bool zeroForOne = cur == hop.key.currency0;
        BalanceDelta delta = manager.swap(
            hop.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inSigned = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outSigned = zeroForOne ? delta.amount1() : delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 consumed = uint256(uint128(-inSigned));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(uint128(outSigned));
        uint256 leftover = amt - consumed;

        if (at == Where.Manager) {
            if (leftover != 0) manager.take(cur, payer, leftover);
        } else if (at == Where.Router) {
            _settleFromRouter(cur, consumed);
            if (leftover != 0) _payOut(cur, payer, leftover);
        } else {
            if (cur.isAddressZero()) {
                _settleFromRouter(cur, consumed);
                if (leftover != 0) _sendEth(payer, leftover);
            } else {
                manager.sync(cur);
                IERC20(Currency.unwrap(cur)).safeTransferFrom(payer, address(manager), consumed);
                manager.settle();
            }
        }
        return (hopOut, out, Where.Manager);
    }

    /// @dev One V3 swap through SwapRouter02; input and output in this contract.
    function _v3Hop(Hop memory hop, Currency cur, Currency hopOut, uint256 amt, Where at, address payer)
        private
        returns (Currency, uint256, Where)
    {
        (cur, amt, at) = _bring(cur, amt, at, payer);
        address tokenOut = Currency.unwrap(hopOut);
        uint256 value;
        if (cur.isAddressZero()) {
            value = amt;
        } else {
            IERC20(Currency.unwrap(cur)).forceApprove(address(swapRouter), amt);
        }
        uint256 out = swapRouter.exactInputSingle{value: value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: cur.isAddressZero() ? address(weth) : Currency.unwrap(cur),
                tokenOut: tokenOut,
                fee: hop.key.fee,
                recipient: address(this),
                amountIn: amt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        return (hopOut, out, Where.Router);
    }

    /// @dev Moves the asset into this contract from wherever it sits.
    function _bring(Currency cur, uint256 amt, Where at, address payer) private returns (Currency, uint256, Where) {
        if (at == Where.Manager) {
            manager.take(cur, address(this), amt);
        } else if (at == Where.Caller && !cur.isAddressZero()) {
            IERC20(Currency.unwrap(cur)).safeTransferFrom(payer, address(this), amt);
        }
        return (cur, amt, Where.Router);
    }

    /// @dev Pays `amt` of `cur` held by this contract into the PoolManager.
    function _settleFromRouter(Currency cur, uint256 amt) private {
        manager.sync(cur);
        if (cur.isAddressZero()) {
            manager.settle{value: amt}();
        } else {
            IERC20(Currency.unwrap(cur)).safeTransfer(address(manager), amt);
            manager.settle();
        }
    }

    function _payOut(Currency cur, address to, uint256 amt) private {
        if (cur.isAddressZero()) _sendEth(to, amt);
        else IERC20(Currency.unwrap(cur)).safeTransfer(to, amt);
    }

    function _toNative(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (cur.isAddressZero()) return (cur, amt);
        weth.withdraw(amt);
        return (Currency.wrap(address(0)), amt);
    }

    function _toWeth(Currency cur, uint256 amt) private returns (Currency, uint256) {
        if (!cur.isAddressZero()) return (cur, amt);
        weth.deposit{value: amt}();
        return (Currency.wrap(address(weth)), amt);
    }

    function _sides(Hop memory hop, Currency cur) private view returns (Currency hopIn, Currency hopOut, bool ok) {
        Currency c0 = hop.key.currency0;
        Currency c1 = hop.key.currency1;
        if (cur == c0) return (c0, c1, true);
        if (cur == c1) return (c1, c0, true);
        if (_isEth(cur)) {
            if (_isEth(c0)) return (c0, c1, true);
            if (_isEth(c1)) return (c1, c0, true);
        }
        return (hopIn, hopOut, false);
    }

    function _isEth(Currency c) private view returns (bool) {
        return c.isAddressZero() || Currency.unwrap(c) == address(weth);
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }

    /// @notice Accepts PoolManager settle flows and WETH withdrawals.
    receive() external payable {}
}
