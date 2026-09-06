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
import {Hop} from "./libraries/Hop.sol";

/// @dev The slice of Uniswap's SwapRouter02 the router uses. With native
/// value attached and WETH9 as `tokenIn`, SwapRouter02 wraps it itself.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title PairPadRouter
 * @notice The PairPad frontend's router. Three jobs:
 *
 * - Exact-input swaps through a launch pool. The pools are plain hookless
 *   V4 pools, so any V4 router can trade them; this one exists so the
 *   frontend has one contract for every flow below.
 * - ETH in and out of pools quoted in an ERC-20, along a route of Uniswap
 *   V3 and V4 pools in any order. The route is the list of hops the quote
 *   pricer prices the asset with, so however far from ETH a quote asset
 *   sits, a buyer pays plain ETH and a seller receives plain ETH. Everything
 *   runs inside one PoolManager unlock: V4 hops net against each other
 *   there, and a V3 hop in the middle is fed by taking the previous hop's
 *   output out and settling the next hop's input back in.
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
    /// @dev Hop `index` does not contain the asset the previous hop produced.
    error RouteBroken(uint256 index);
    /// @dev The route did not end where the caller said it would.
    error RouteEndMismatch(address expected, address actual);

    event ZapBuy(bytes32 indexed poolId, address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event ZapSell(bytes32 indexed poolId, address indexed seller, uint256 tokensIn, uint256 ethOut);

    /// @dev Where the asset being routed currently sits.
    enum Where {
        /// @dev Still with the caller: native value already attached, or an
        /// ERC-20 to be pulled under allowance.
        Caller,
        /// @dev A positive delta inside the PoolManager.
        Manager,
        /// @dev Held by this contract, native or ERC-20.
        Router
    }

    /// @dev One unlock: `amountIn` of `currencyIn` through `hops` in order.
    struct Route {
        Hop[] hops;
        Currency currencyIn;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev The wallet trading: funds the input and receives any part a
        /// hop could not absorb.
        address payer;
        /// @dev Where the final output goes.
        address recipient;
        /// @dev Deliver native ETH at the end, unwrapping WETH if that is
        /// what the last hop produced. Otherwise the output must be exactly
        /// `currencyOut`.
        bool ethOut;
        Currency currencyOut;
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

        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, v3: false});
        (amountOut,) = _route(
            Route({
                hops: hops,
                currencyIn: currencyIn,
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: zeroForOne ? key.currency1 : key.currency0
            })
        );
    }

    // ---------------------------------------------------------------------
    // ETH in / out of an ERC-20-quoted pool
    // ---------------------------------------------------------------------

    /**
     * @notice Buys the launch token of `key`, paying in native ETH. The
     * attached value travels along `leg` (ETH first, the quote asset last)
     * and straight on through the launch pool to `recipient`. An empty leg
     * on a pool quoted in ETH is just a plain buy.
     */
    function buyWithEth(PoolKey calldata key, Hop[] calldata leg, uint256 minTokensOut, address recipient)
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
     * `recipient`: the launch pool first, then `leg` (the quote asset first,
     * ETH last). Needs an allowance for the launch token.
     */
    function sellToEth(
        PoolKey calldata key,
        bool tokenIsCurrency0,
        uint256 tokensIn,
        Hop[] calldata leg,
        uint256 minEthOut,
        address recipient
    ) external nonReentrant returns (uint256 ethOut) {
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        Hop[] memory hops = new Hop[](1 + leg.length);
        hops[0] = Hop({key: key, v3: false});
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i + 1] = leg[i];
        }

        (ethOut,) = _route(
            Route({
                hops: hops,
                currencyIn: tokenIsCurrency0 ? key.currency0 : key.currency1,
                amountIn: tokensIn,
                minAmountOut: minEthOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: true,
                currencyOut: Currency.wrap(address(0))
            })
        );
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
        Hop[] calldata leg,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, PoolId poolId, uint256 tokensOut) {
        uint256 launchFee = factory.launchFee();
        if (msg.value < launchFee) revert InsufficientLaunchValue();
        uint256 buyValue = msg.value - launchFee;

        (token, poolId) = factory.launchTokenFor{value: launchFee}(params, launchConfigId, pairToken, msg.sender);
        if (buyValue == 0) return (token, poolId, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        if (pairToken == address(0)) {
            Hop[] memory none;
            tokensOut = _buyAlongLeg(key, none, buyValue, minTokensOut, msg.sender);
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
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({key: key, v3: false});
        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(pairToken),
                amountIn: quoteIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: msg.sender,
                ethOut: false,
                currencyOut: Currency.unwrap(key.currency0) == token ? key.currency0 : key.currency1
            })
        );
    }

    // ---------------------------------------------------------------------
    // Leg assembly
    // ---------------------------------------------------------------------

    /// @dev Spends `ethIn` along `leg` and through the launch pool `key`.
    function _buyAlongLeg(
        PoolKey memory key,
        Hop[] memory leg,
        uint256 ethIn,
        uint256 minTokensOut,
        address recipient
    ) private returns (uint256 tokensOut) {
        Hop[] memory hops = new Hop[](leg.length + 1);
        for (uint256 i = 0; i < leg.length; i++) {
            hops[i] = leg[i];
        }
        hops[leg.length] = Hop({key: key, v3: false});
        Currency tokenCurrency = _launchTokenOf(key, leg);

        (tokensOut,) = _route(
            Route({
                hops: hops,
                currencyIn: Currency.wrap(address(0)),
                amountIn: ethIn,
                minAmountOut: minTokensOut,
                payer: msg.sender,
                recipient: recipient,
                ethOut: false,
                currencyOut: tokenCurrency
            })
        );
    }

    /**
     * @dev The side of the launch pool the buy comes out of: the side the
     * leg does not arrive on. With no leg the buy arrives as ETH, so it is
     * the side that is not ETH.
     */
    function _launchTokenOf(PoolKey memory key, Hop[] memory leg) private view returns (Currency) {
        if (leg.length == 0) return _isEth(key.currency0) ? key.currency1 : key.currency0;
        PoolKey memory last = leg[leg.length - 1].key;
        bool quoteIs0 = key.currency0 == last.currency0 || key.currency0 == last.currency1;
        return quoteIs0 ? key.currency1 : key.currency0;
    }

    // ---------------------------------------------------------------------
    // Route engine
    // ---------------------------------------------------------------------

    function _route(Route memory r) private returns (uint256 amountOut, Currency currencyOut) {
        bytes memory result = manager.unlock(abi.encode(r));
        (amountOut, currencyOut) = abi.decode(result, (uint256, Currency));
    }

    /**
     * @dev Walks the route hop by hop, tracking where the asset sits. A V4
     * hop swaps inside the PoolManager and its input is settled from
     * wherever the asset is: netted against a credit already there, paid
     * from this contract, or pulled from the caller. A V3 hop needs the
     * asset in this contract, so a credit is taken out first, and leaves its
     * output here for the next hop to settle in. Native ETH and WETH are
     * treated as one asset and converted whenever a hop wants the other
     * form. A hop that runs out of liquidity takes less than offered; the
     * rest goes back to the payer at once.
     */
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));

        Currency cur = r.currencyIn;
        uint256 amt = r.amountIn;
        Where at = Where.Caller;
        uint256 n = r.hops.length;
        for (uint256 i = 0; i < n; i++) {
            Hop memory hop = r.hops[i];
            (Currency hopIn, Currency hopOut, bool ok) = _sides(hop, cur);
            if (!ok) revert RouteBroken(i);

            if (hop.v3) {
                (cur, amt, at) = _v3Hop(hop, cur, hopOut, amt, at, r.payer);
            } else {
                (cur, amt, at) = _v4Hop(hop, cur, hopIn, hopOut, amt, at, r.payer);
            }
        }
        if (amt < r.minAmountOut) revert SlippageExceeded(amt, r.minAmountOut);

        if (r.ethOut) {
            if (!_isEth(cur)) revert RouteEndMismatch(address(0), Currency.unwrap(cur));
            (cur, amt, at) = _asNative(cur, amt, at);
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else _sendEth(r.recipient, amt);
        } else {
            if (!(cur == r.currencyOut)) revert RouteEndMismatch(Currency.unwrap(r.currencyOut), Currency.unwrap(cur));
            if (at == Where.Manager) manager.take(cur, r.recipient, amt);
            else if (cur.isAddressZero()) _sendEth(r.recipient, amt);
            else IERC20(Currency.unwrap(cur)).safeTransfer(r.recipient, amt);
        }
        return abi.encode(amt, cur);
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
            // ETH in the wrong form for this pool: convert it here first.
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
            // The credit from the previous hop pays; whatever it did not
            // consume is still a credit and goes back to the payer.
            if (leftover != 0) manager.take(cur, payer, leftover);
        } else if (at == Where.Router) {
            _settleFromRouter(cur, consumed);
            if (leftover != 0) _payOut(cur, payer, leftover);
        } else {
            // From the caller: native value is already here, an ERC-20 is
            // pulled straight into the PoolManager.
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

    /**
     * @dev One V3 swap through SwapRouter02. The input has to be in this
     * contract; the output lands here too.
     */
    function _v3Hop(Hop memory hop, Currency cur, Currency hopOut, uint256 amt, Where at, address payer)
        private
        returns (Currency, uint256, Where)
    {
        (cur, amt, at) = _bring(cur, amt, at, payer);
        address tokenOut = Currency.unwrap(hopOut);
        uint256 value;
        if (cur.isAddressZero()) {
            // SwapRouter02 wraps attached value when tokenIn is WETH9.
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
        // Native value from the caller is already here.
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

    /// @dev ETH held here in either form, delivered as native.
    function _asNative(Currency cur, uint256 amt, Where at) private returns (Currency, uint256, Where) {
        if (cur.isAddressZero()) return (cur, amt, at);
        if (at == Where.Manager) {
            manager.take(cur, address(this), amt);
            at = Where.Router;
        }
        (cur, amt) = _toNative(cur, amt);
        return (cur, amt, at);
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

    /**
     * @dev Which side of `hop` the asset enters and which it leaves. Native
     * ETH and WETH match each other, so a route can move between V3 (WETH)
     * and native V4 pools; the caller converts.
     */
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

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _poolId(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _sendEth(address recipient, uint256 amount) private {
        (bool sent,) = payable(recipient).call{value: amount}("");
        if (!sent) revert EthTransferFailed();
    }

    /// @notice Accepts PoolManager settle flows and WETH withdrawals.
    receive() external payable {}
}
