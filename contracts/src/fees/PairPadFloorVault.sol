// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPairPadFeeEscrow, IPairPadLaunchFactory} from "../v2/interfaces/ILaunchpadV2.sol";
import {IPairPadMultiLaunchFactory} from "../v3/interfaces/ILaunchpadV3.sol";
import {PairPadPositionMath} from "../v2/libraries/PairPadPositionMath.sol";

/// @dev The single-market factory: its launch record plus the pool key lookup.
interface IFloorSingleFactory is IPairPadLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
}

/// @dev The multi-market factory, as the vault reads it.
interface IFloorMultiFactory is IPairPadMultiLaunchFactory {}

/// @dev The lockers' permissionless fee collection.
interface IFloorSingleLocker {
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
}

interface IFloorMultiLocker {
    function collectFees(address token) external returns (uint256[] memory collected);
}

/**
 * @title PairPadFloorVault
 * @notice The creator fee recipient of launches whose creator chose, at
 * creation, to turn the creator's share of trading fees into a price floor
 * for the token. The factories snapshot the recipient and only the recipient
 * itself may ever change it; this contract has no such function, so the
 * choice is permanent for the life of the token.
 *
 * How the floor works. The creator share paid in the token is burned. The
 * share paid in the quote asset is placed back into the token's own launch
 * pool as one single-tick, quote-only position (the "wall") at the highest
 * price at which that quote could buy every token in circulation:
 *
 *     floor price = quote in the wall / circulating tokens
 *
 * where circulating means the total supply less what the launch position
 * itself still holds in the pool (tokens it never sold, or has since bought
 * back). Every sale into the pool either hits the curve above the wall or
 * the wall itself, so the price can never trade below the wall. Sales also
 * burn tokens (fewer to absorb) and buys add quote (more to absorb with), so
 * the floor only ever moves up. The wall is rebuilt from scratch on every
 * `rebalance`, which anyone may call: new fees are pulled through the
 * locker, the old wall is withdrawn, tokens it absorbed are burned, and the
 * whole quote is re-placed at the new, higher tick.
 *
 * Attribution. The fee escrow keeps one balance per recipient, not per
 * launch, so the vault does the collection itself: `rebalance` calls the
 * locker's `collectFees` and books the escrow's balance change to that
 * launch. If someone collects a floor launch's fees directly, the quote lands
 * in the escrow unattributed; the operator can assign such a remainder to a
 * launch (`assignUnattributed`), and can never assign more than what is
 * actually unattributed nor move anything out of the vault.
 *
 * Nothing here can send value anywhere other than into the token's own
 * launch pool, to the fee escrow's owner (this contract), or to the zero
 * address via burn. The operator's only powers are attribution of stray
 * fees and nothing else.
 */
contract PairPadFloorVault is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Wall {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    IPoolManager public immutable poolManager;
    IPairPadFeeEscrow public immutable escrow;
    IFloorSingleFactory public immutable factory;
    IFloorSingleLocker public immutable locker;
    IFloorMultiFactory public immutable multiFactory;
    IFloorMultiLocker public immutable multiLocker;
    address public immutable operator;

    /// @notice Quote attributed to a launch and not yet placed in its wall (address zero for ETH).
    mapping(address token => mapping(address quote => uint256)) public idle;
    /// @notice Sum of `idle` over every launch, per quote; what is held above this is unattributed.
    mapping(address quote => uint256) public idleTotal;
    /// @notice The wall position per launch and quote.
    mapping(address token => mapping(address quote => Wall)) public walls;
    /// @notice Tokens burned per launch, from fees and from what the wall absorbed.
    mapping(address token => uint256) public burned;
    /// @notice Quote the wall has spent absorbing sales (tokens bought and burned), per launch and quote.
    mapping(address token => mapping(address quote => uint256)) public absorbed;

    event Collected(address indexed token, address indexed quote, uint256 quoteAmount, uint256 tokenBurned);
    event Burned(address indexed token, uint256 amount);
    event WallMoved(
        address indexed token,
        address indexed quote,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 quoteInWall,
        uint256 circulating
    );
    event Unattributed(address indexed token, address indexed quote, uint256 amount);

    error ZeroAddress();
    error NotOperator();
    error NotPoolManager();
    error NotFloorLaunch(address token);
    error NoMarket(address token, address quote);
    error NothingUnattributed(address quote, uint256 requested, uint256 available);
    error WallInRange();

    // Reentrancy-safe scratch for the unlock callback.
    struct Op {
        address token;
        address quote;
        PoolKey key;
        bool tokenIs0;
    }

    constructor(
        IPoolManager poolManager_,
        IPairPadFeeEscrow escrow_,
        IFloorSingleFactory factory_,
        IFloorSingleLocker locker_,
        IFloorMultiFactory multiFactory_,
        IFloorMultiLocker multiLocker_,
        address operator_
    ) {
        if (
            address(poolManager_) == address(0) || address(escrow_) == address(0) || address(factory_) == address(0)
                || address(locker_) == address(0) || address(multiFactory_) == address(0)
                || address(multiLocker_) == address(0) || operator_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        escrow = escrow_;
        factory = factory_;
        locker = locker_;
        multiFactory = multiFactory_;
        multiLocker = multiLocker_;
        operator = operator_;
    }

    /// @dev The escrow pays claimed ETH here; the PoolManager pays taken ETH here.
    receive() external payable {}

    // ------------------------------------------------------------ rebalance

    /**
     * @notice Collects the launch's new fees, burns the token side, withdraws
     * the wall(s), burns whatever they absorbed and re-places all the quote at
     * the new floor tick, one wall per market. Anyone may call.
     */
    function rebalance(address token) external nonReentrant {
        (address[] memory quotes, PoolKey[] memory keys) = _markets(token);
        _collect(token, quotes);
        for (uint256 i = 0; i < quotes.length; i++) {
            _rebuildWall(token, quotes[i], keys[i]);
        }
    }

    /**
     * @notice Books `amount` of unattributed `quote` (fees of a floor launch
     * someone collected directly) to `token`. Only the operator; bounded by
     * what is actually unattributed.
     */
    function assignUnattributed(address token, address quote, uint256 amount) external {
        if (msg.sender != operator) revert NotOperator();
        if (!_isFloorLaunch(token)) revert NotFloorLaunch(token);
        uint256 available = unattributed(quote);
        if (amount == 0 || amount > available) revert NothingUnattributed(quote, amount, available);
        idle[token][quote] += amount;
        idleTotal[quote] += amount;
        emit Unattributed(token, quote, amount);
    }

    // ---------------------------------------------------------------- views

    /**
     * @notice The floor of `token` in `quote`: the quote sitting in and
     * waiting for the wall, the circulating supply it stands under, and the
     * wall's range. `sqrtPriceX96` is the pool price at the wall's edge
     * nearest the market (the price a sale into the wall gets), zero when no
     * wall stands yet.
     */
    function floorOf(address token, address quote)
        external
        view
        returns (uint256 quoteInWall, uint256 idleQuote, uint256 circulating, Wall memory wall, uint160 sqrtPriceX96)
    {
        PoolKey memory key = _poolKey(token, quote);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        wall = walls[token][quote];
        idleQuote = idle[token][quote];
        if (wall.liquidity != 0) {
            uint160 lo = TickMath.getSqrtPriceAtTick(wall.tickLower);
            uint160 hi = TickMath.getSqrtPriceAtTick(wall.tickUpper);
            quoteInWall = tokenIs0
                ? SqrtPriceMath.getAmount1Delta(lo, hi, wall.liquidity, false)
                : SqrtPriceMath.getAmount0Delta(lo, hi, wall.liquidity, false);
            sqrtPriceX96 = tokenIs0 ? hi : lo;
        }
        circulating = _circulating(token);
    }

    /// @notice What the escrow still holds for this vault in `asset` (address zero for ETH).
    function pending(address asset) external view returns (uint256) {
        return asset == address(0) ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), asset);
    }

    /// @notice Quote held (here or in the escrow) that is not booked to any launch.
    function unattributed(address quote) public view returns (uint256) {
        uint256 held = quote == address(0)
            ? address(this).balance + escrow.balanceOf(address(this))
            : IERC20(quote).balanceOf(address(this)) + escrow.balanceOfToken(address(this), quote);
        uint256 booked = idleTotal[quote];
        return held > booked ? held - booked : 0;
    }

    /// @notice The pool the wall for this pair stands in. Reverts if `token`
    /// was not launched on par with `quote` as one of its markets.
    function poolKeyFor(address token, address quote) external view returns (PoolKey memory) {
        return _poolKey(token, quote);
    }

    /// @notice Total supply less what the launch position(s) hold in the pool(s).
    function circulatingOf(address token) external view returns (uint256) {
        return _circulating(token);
    }

    // ------------------------------------------------------------ internals

    /**
     * @dev Pulls the launch's fees through its locker and books the escrow's
     * balance change per quote to this launch. The token side is claimed and
     * burned right away.
     */
    function _collect(address token, address[] memory quotes) private {
        uint256 n = quotes.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            before[i] = _escrowBalance(quotes[i]);
        }

        if (_isSingle(token)) locker.collectFees(token);
        else multiLocker.collectFees(token);

        // The token side, whoever collected it, is burned whole.
        if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
        uint256 tokBurned = IERC20(token).balanceOf(address(this));
        _burn(token, tokBurned);

        for (uint256 i = 0; i < n; i++) {
            uint256 delta = _escrowBalance(quotes[i]) - before[i];
            if (delta != 0) {
                idle[token][quotes[i]] += delta;
                idleTotal[quotes[i]] += delta;
            }
            emit Collected(token, quotes[i], delta, i == 0 ? tokBurned : 0);
        }
    }

    /**
     * @dev Withdraws the current wall, burns the tokens it absorbed, and
     * places every quote this launch has in `quote` at the new floor tick.
     */
    function _rebuildWall(address token, address quote, PoolKey memory key) private {
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        poolManager.unlock(abi.encode(Op({token: token, quote: quote, key: key, tokenIs0: tokenIs0})));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Op memory op = abi.decode(data, (Op));
        Currency quoteC = op.tokenIs0 ? op.key.currency1 : op.key.currency0;
        bytes32 salt = _salt(op.token, op.quote);

        // 1. Withdraw the standing wall, principal and fees, in both currencies.
        Wall memory wall = walls[op.token][op.quote];
        uint256 quoteBack;
        uint256 tokensBack;
        if (wall.liquidity != 0) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                op.key,
                ModifyLiquidityParams({
                    tickLower: wall.tickLower,
                    tickUpper: wall.tickUpper,
                    liquidityDelta: -int256(uint256(wall.liquidity)),
                    salt: salt
                }),
                ""
            );
            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();
            if (d0 > 0) poolManager.take(op.key.currency0, address(this), uint128(d0));
            if (d1 > 0) poolManager.take(op.key.currency1, address(this), uint128(d1));
            quoteBack = uint256(uint128(op.tokenIs0 ? (d1 > 0 ? d1 : int128(0)) : (d0 > 0 ? d0 : int128(0))));
            tokensBack = uint256(uint128(op.tokenIs0 ? (d0 > 0 ? d0 : int128(0)) : (d1 > 0 ? d1 : int128(0))));
            delete walls[op.token][op.quote];
        }
        // Everything that came out in quote is this launch's again.
        if (quoteBack != 0) {
            idle[op.token][op.quote] += quoteBack;
            idleTotal[op.quote] += quoteBack;
        }
        // Tokens the wall bought are gone for good: fewer tokens to stand under.
        if (tokensBack != 0) _burn(op.token, tokensBack);

        // 2. Claim what the escrow holds for us in this quote, so it is here to settle with.
        _claimQuote(op.quote);

        // 3. Size and place the new wall.
        uint256 amount = idle[op.token][op.quote];
        uint256 circulating = _circulating(op.token);
        if (amount == 0 || circulating == 0) {
            emit WallMoved(op.token, op.quote, 0, 0, 0, 0, circulating);
            return "";
        }
        (int24 tickLower, int24 tickUpper) = _wallTicks(op.key, op.token, op.tokenIs0, amount, circulating);
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity;
        if (op.tokenIs0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(lo, hi, amount);
            while (liquidity != 0 && SqrtPriceMath.getAmount1Delta(lo, hi, liquidity, true) > amount) liquidity -= 1;
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(lo, hi, amount);
            while (liquidity != 0 && SqrtPriceMath.getAmount0Delta(lo, hi, liquidity, true) > amount) liquidity -= 1;
        }
        if (liquidity == 0) {
            emit WallMoved(op.token, op.quote, 0, 0, 0, 0, circulating);
            return "";
        }
        (BalanceDelta added,) = poolManager.modifyLiquidity(
            op.key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
            }),
            ""
        );
        // The position is entirely on the quote side: the token delta is zero by construction.
        int128 owedQ = op.tokenIs0 ? added.amount1() : added.amount0();
        uint256 owed = owedQ < 0 ? uint256(uint128(-owedQ)) : 0;
        int128 owedT = op.tokenIs0 ? added.amount0() : added.amount1();
        if (owedT != 0) revert WallInRange();
        if (owed != 0) {
            if (quoteC.isAddressZero()) {
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(quoteC);
                IERC20(Currency.unwrap(quoteC)).safeTransfer(address(poolManager), owed);
                poolManager.settle();
            }
            idle[op.token][op.quote] = amount - owed;
            idleTotal[op.quote] -= owed;
        }
        walls[op.token][op.quote] = Wall({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
        emit WallMoved(op.token, op.quote, tickLower, tickUpper, liquidity, owed, circulating);
        return "";
    }

    /**
     * @dev The one-spacing range the wall stands in.
     *
     * On the way down from the current price to the wall, the launch curve
     * itself buys tokens back (it holds the quote earlier buyers paid in), so
     * the wall only has to absorb what is left when the price reaches it.
     * With the curve's liquidity L and current sqrt price s, the tokens it
     * buys back down to sqrt price x are L (1/x - 1/s) when the token is
     * currency0, and L (x - s) when it is currency1 (pool price is
     * currency1 per currency0, so the token's price falls as the pool price
     * rises). The wall's quote W must cover the rest at the wall's price:
     *
     *   token is currency0:  W >= (C - L (1/x - 1/s)) x^2
     *   token is currency1:  W x^2 >= C - L (x - s)
     *
     * Both are quadratics in x with one positive root; that root, rounded
     * toward a lower token price and kept strictly on the quote side of the
     * current price (so the position holds no token when minted) and no
     * further than the curve's own opening tick (below which nothing can
     * trade anyway), is where the wall goes.
     */
    function _wallTicks(PoolKey memory key, address token, bool tokenIs0, uint256 quoteAmount, uint256 circulating)
        private
        view
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 spacing = key.tickSpacing;
        (uint160 sqrtNow, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        (int24 openLower, int24 openUpper, uint128 curveL) = _launchPosition(token, _other(key, token));
        uint160 target = _wallSqrtPrice(tokenIs0, sqrtNow, curveL, quoteAmount, circulating);
        int24 targetTick = TickMath.getTickAtSqrtPrice(target);
        int24 minTick = _ceilToSpacing(TickMath.MIN_TICK, spacing);
        int24 maxTick = _floorToSpacing(TickMath.MAX_TICK, spacing);

        // slot0.tick is the floor of the current price's tick, so the price
        // is at or above the tick's own sqrt price and strictly below the
        // next tick's: a range ending at or before `currentTick` holds only
        // currency1, one starting after it holds only currency0.
        if (tokenIs0) {
            // Lower token price = lower tick. The curve runs [openLower, max].
            tickUpper = _floorToSpacing(targetTick, spacing);
            int24 cap = _floorToSpacing(currentTick, spacing);
            if (tickUpper > cap) tickUpper = cap;
            if (tickUpper < openLower) tickUpper = openLower;
            if (tickUpper - spacing < minTick) tickUpper = minTick + spacing;
            tickLower = tickUpper - spacing;
        } else {
            // Quote is currency0: lower token price = higher pool price =
            // higher tick. The curve runs [min, openUpper].
            tickLower = _ceilToSpacing(targetTick, spacing);
            int24 cap = _ceilToSpacing(currentTick + 1, spacing);
            if (tickLower < cap) tickLower = cap;
            if (tickLower > openUpper) tickLower = openUpper;
            if (tickLower + spacing > maxTick) tickLower = maxTick - spacing;
            tickUpper = tickLower + spacing;
        }
    }

    /// @dev The positive root of the wall quadratic (see `_wallTicks`), as a
    /// sqrt price in Q96, clamped into the pool's usable range.
    function _wallSqrtPrice(bool tokenIs0, uint160 sqrtNow, uint128 curveL, uint256 w, uint256 c)
        private
        pure
        returns (uint160)
    {
        uint256 q96 = 1 << 96;
        uint256 l = curveL;
        uint256 root;
        if (tokenIs0) {
            // (C + L/s) x^2 - L x - W = 0, x = sqrt price as a plain number.
            uint256 a = c + FullMath.mulDiv(l, q96, sqrtNow);
            uint256 disc = l * l + 4 * FullMath.mulDiv(a, w, 1);
            uint256 num = l + Math.sqrt(disc);
            root = FullMath.mulDiv(num, q96, 2 * a);
        } else {
            // W x^2 + L x - (C + L s) = 0.
            uint256 b = c + FullMath.mulDiv(l, sqrtNow, q96);
            uint256 disc = l * l + 4 * FullMath.mulDiv(w, b, 1);
            uint256 num = Math.sqrt(disc) - l;
            root = FullMath.mulDiv(num, q96, 2 * w);
        }
        if (root <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (root >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(root);
    }

    /// @dev The launch position's range and liquidity in the market quoted in `quote`.
    function _launchPosition(address token, address quote)
        private
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        if (_isSingle(token)) {
            IPairPadLaunchFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
            return (l.tickLower, l.tickUpper, l.liquidity);
        }
        IPairPadMultiLaunchFactory.Market[] memory ms = multiFactory.getMarkets(token);
        for (uint256 i = 0; i < ms.length; i++) {
            if (ms[i].pairToken == quote) return (ms[i].tickLower, ms[i].tickUpper, ms[i].liquidity);
        }
        revert NoMarket(token, quote);
    }

    /// @dev Total supply less the tokens the launch position(s) hold at the current pool price(s).
    function _circulating(address token) private view returns (uint256) {
        uint256 supply = IERC20(token).totalSupply();
        uint256 inPools;
        if (_isSingle(token)) {
            IPairPadLaunchFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
            PoolKey memory key = factory.poolKeyFor(token);
            inPools = _positionTokens(key, token, l.tickLower, l.tickUpper, l.liquidity);
        } else {
            IPairPadMultiLaunchFactory.Market[] memory ms = multiFactory.getMarkets(token);
            PoolKey[] memory keys = multiFactory.poolKeysFor(token);
            for (uint256 i = 0; i < ms.length; i++) {
                inPools += _positionTokens(keys[i], token, ms[i].tickLower, ms[i].tickUpper, ms[i].liquidity);
            }
        }
        return supply > inPools ? supply - inPools : 0;
    }

    function _positionTokens(PoolKey memory key, address token, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (uint256 a0, uint256 a1) = PairPadPositionMath.amountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, liquidity);
        return Currency.unwrap(key.currency0) == token ? a0 : a1;
    }

    function _claimQuote(address quote) private {
        if (quote == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) escrow.claim();
        } else if (escrow.balanceOfToken(address(this), quote) > 0) {
            escrow.claimToken(quote);
        }
    }

    function _escrowBalance(address quote) private view returns (uint256) {
        return quote == address(0) ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), quote);
    }

    /// @dev Every launch token is a PairPadLauncherToken, which is ERC20Burnable.
    function _burn(address token, uint256 amount) private {
        if (amount == 0) return;
        ERC20Burnable(token).burn(amount);
        burned[token] += amount;
        emit Burned(token, amount);
    }

    function _salt(address token, address quote) private pure returns (bytes32) {
        return keccak256(abi.encode(token, quote));
    }

    /// @dev True when the single-market factory knows the token.
    function _isSingle(address token) private view returns (bool) {
        (bool ok, bytes memory data) =
            address(factory).staticcall(abi.encodeWithSelector(IPairPadLaunchFactory.getLaunchedToken.selector, token));
        if (!ok || data.length < 32) return false;
        IPairPadLaunchFactory.LaunchedToken memory l = abi.decode(data, (IPairPadLaunchFactory.LaunchedToken));
        return l.exists;
    }

    function _isFloorLaunch(address token) private view returns (bool) {
        if (_isSingle(token)) return factory.getLaunchedToken(token).creatorFeeRecipient == address(this);
        (bool ok, bytes memory data) =
            address(multiFactory).staticcall(abi.encodeWithSelector(IPairPadMultiLaunchFactory.getLaunchedToken.selector, token));
        if (!ok || data.length < 32) return false;
        IPairPadMultiLaunchFactory.LaunchedToken memory l = abi.decode(data, (IPairPadMultiLaunchFactory.LaunchedToken));
        return l.exists && l.creatorFeeRecipient == address(this);
    }

    /// @dev The launch's quote assets and pool keys, one per market. Reverts
    /// unless the launch named this vault as its creator fee recipient.
    function _markets(address token) private view returns (address[] memory quotes, PoolKey[] memory keys) {
        if (!_isFloorLaunch(token)) revert NotFloorLaunch(token);
        if (_isSingle(token)) {
            quotes = new address[](1);
            keys = new PoolKey[](1);
            keys[0] = factory.poolKeyFor(token);
            quotes[0] = _other(keys[0], token);
        } else {
            keys = multiFactory.poolKeysFor(token);
            quotes = new address[](keys.length);
            for (uint256 i = 0; i < keys.length; i++) {
                quotes[i] = _other(keys[i], token);
            }
        }
    }

    function _poolKey(address token, address quote) private view returns (PoolKey memory key) {
        (bool ok, bytes memory data) =
            address(factory).staticcall(abi.encodeWithSelector(IFloorSingleFactory.poolKeyFor.selector, token));
        if (ok && data.length >= 32 * 5) {
            key = abi.decode(data, (PoolKey));
            if (_other(key, token) == quote) return key;
        }
        (ok, data) =
            address(multiFactory).staticcall(abi.encodeWithSelector(IPairPadMultiLaunchFactory.poolKeysFor.selector, token));
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

    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick > 0 && tick % spacing != 0) q += 1;
        return q * spacing;
    }
}
