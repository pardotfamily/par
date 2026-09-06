// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hop} from "./libraries/Hop.sol";

/// @dev The slice of the Uniswap V3 pool surface the pricer consults.
interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @dev A source of Uniswap V4 pool keys for tokens that were launched by
 * some launchpad. The pricer asks each registered registry for `token` and
 * treats a returned pool like one registered by hand, so a token that only
 * trades in its launchpad's V4 pool can be used as a quote without anyone
 * doing anything first. One adapter per launchpad, see
 * PairPadReferenceRegistries.sol.
 */
interface IQuoteReferenceRegistry {
    function referencePool(address token) external view returns (bool found, PoolKey memory key);
}

/**
 * @title PairPadQuotePricer
 * @notice Converts the launch config's ETH-denominated terms (the opening
 * market cap) into an ERC-20 quote asset's own units at the current price
 * along a route of pools from that asset to ETH.
 *
 * A route is a list of hops, each a Uniswap V3 or V4 pool, that starts at
 * the asset and ends at ETH (native or WETH). Two routes are found without
 * anyone doing anything: a direct pool against ETH, and two hops through
 * USDG, each leg being the deepest pool for its pair. Anything longer is
 * registered by whoever wants to launch against the asset: the interface
 * searches the chain's pools for a route, and `registerPath` checks and
 * stores it. Once stored a route serves every later launch in that asset.
 * Routes have up to `MAX_HOPS` hops, which covers an asset paired to a
 * token paired to a stock paired to USDG paired to ETH.
 *
 * Every hop has to be deep. Walking from the ETH end, a hop qualifies when
 * the pool holds at least `minReferenceEth` worth of the side nearer ETH,
 * that floor converted along the hops already walked. For V3 that is the
 * balance the pool physically holds, for V4 the in-range virtual reserve
 * implied by the active liquidity at the current price. A route qualifies
 * when all its hops do; its strength is its weakest hop's depth over that
 * hop's floor. When both a registered route and an automatic one qualify,
 * the stronger prices the asset.
 *
 * V4 hops must carry a hook on the allow-list (no hook is allowed from
 * deployment). V4 pools for the automatic routes come from hand
 * registration and from launchpad registries; V3 pools from the V3 factory
 * at the standard fee tiers.
 *
 * The price is the spot price. There is no averaging and no waiting: an
 * asset becomes usable as a quote the moment a deep enough route exists.
 * The cost of that choice is spelled out in the docs: whoever launches can
 * push a route's price inside their own transaction and pull it back after,
 * paying only the pools' swap fees, and thereby open their own token at a
 * market cap other than the advertised one. That distorts nothing but that
 * one launch, the interface shows the live market cap anyway, and the depth
 * floor sets a minimum size for the trade it takes.
 */
contract PairPadQuotePricer is Ownable2Step {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error QuoteAssetNotPriceable(address quoteToken);
    error ZeroAddress();
    error ConversionOverflow();
    error HookNotAllowed(address hook);
    error NotAnAnchorPool();
    error PoolNotInitialized();
    error PoolAlreadyRegistered(bytes32 poolId);
    error TooManyPools(address token);
    error TooManyRegistries();
    error RegistryAlreadyAdded(address registry);
    error UnknownRegistry(address registry);
    error NotAContract(address registry);
    /// @dev The route is malformed; `hopIndex` is the hop at fault.
    error InvalidPath(PathFault fault, uint256 hopIndex);
    /// @dev Every hop is well formed but one is under its depth floor.
    error PathNotQualifying(uint256 hopIndex);
    /// @dev A qualifying route is already stored and is at least as strong.
    error PathNotStronger(uint256 storedStrengthX18, uint256 offeredStrengthX18);
    error NoPathStored(address token);

    event MinReferenceDepthUpdated(uint256 minReferenceEth);
    event V4HookAllowed(address indexed hook, bool allowed);
    event V4PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed anchor, PoolKey key);
    event RegistryAdded(address indexed registry);
    event RegistryRemoved(address indexed registry);
    event PathRegistered(address indexed token, address indexed by, Hop[] hops, uint256 strengthX18);
    event PathCleared(address indexed token);

    struct V4Pool {
        PoolKey key;
        /// @dev The asset being priced by this pool (the non-anchor side).
        address token;
        /// @dev Native ETH (address zero), WETH or USDG.
        address anchor;
        bool registered;
    }

    /// @notice Why a route is malformed.
    enum PathFault {
        None,
        Empty,
        TooLong,
        /// @dev The hop does not contain the asset the previous hop produced.
        Disconnected,
        /// @dev The route passes through the same asset twice.
        Revisits,
        /// @dev A V3 hop names native ETH; V3 pools hold WETH.
        NativeOnV3,
        /// @dev The V3 factory has no pool for the hop's pair and fee.
        NoV3Pool,
        /// @dev A V3 hop's tickSpacing or hooks are not zero.
        V3KeyNotBare,
        HookNotAllowed,
        NotInitialized,
        /// @dev The last hop does not reach ETH or WETH.
        NotToEth,
        /// @dev ETH or WETH appears before the last hop.
        EthMidRoute
    }

    /// @notice One hop of a route as the pricer sees it, for interfaces.
    struct HopReport {
        Hop hop;
        /// @dev The asset entering the hop, on the way from the quote to ETH.
        address tokenIn;
        /// @dev The asset leaving the hop, one step nearer ETH.
        address tokenOut;
        /// @dev How much of `tokenOut` the pool holds (V3) or has in range (V4).
        uint256 depth;
        /// @dev What `depth` has to reach: `minReferenceEth` in `tokenOut` units.
        uint256 floor;
        bool qualifies;
    }

    /// @notice A route and how it measures up, for interfaces.
    struct PathReport {
        HopReport[] hops;
        /// @dev All hops well formed and at or above their floor.
        bool qualifies;
        /// @dev Came from `registerPath` rather than the automatic search.
        bool registered;
        /// @dev Weakest hop's depth over its floor, scaled by 1e18.
        uint256 strengthX18;
        PathFault fault;
        uint256 faultHop;
    }

    /// @dev Standard Uniswap V3 fee tiers scanned for an automatic route.
    uint24 private constant FEE_LOW = 500;
    uint24 private constant FEE_MEDIUM = 3_000;
    uint24 private constant FEE_HIGH = 10_000;

    uint8 public constant MAX_HOPS = 4;
    uint8 public constant MAX_V4_POOLS_PER_TOKEN = 8;
    uint8 public constant MAX_REGISTRIES = 8;

    IUniswapV3FactoryMinimal public immutable v3Factory;
    IPoolManager public immutable poolManager;
    address public immutable weth;
    address public immutable usdg;

    /// @notice How much ETH worth of the side nearer ETH every hop of a
    /// route must hold (V3) or have in range (V4).
    uint256 public minReferenceEth = 5 ether;

    /// @notice Hooks a V4 hop may carry. Address zero (no hook) is allowed
    /// from deployment.
    mapping(address hook => bool) public allowedV4Hooks;
    mapping(bytes32 poolId => V4Pool) private _v4Pools;
    mapping(address token => bytes32[]) private _v4PoolsOf;
    /// @notice Every hand-registered V4 pool.
    bytes32[] public allV4Pools;
    /// @notice Launchpad registries consulted for V4 pool keys.
    IQuoteReferenceRegistry[] public registries;
    /// @dev Routes stored through `registerPath`, from the asset to ETH.
    mapping(address token => Hop[]) private _paths;

    constructor(
        address initialOwner,
        IUniswapV3FactoryMinimal v3Factory_,
        address weth_,
        address usdg_,
        IPoolManager poolManager_
    ) Ownable(initialOwner) {
        if (
            address(v3Factory_) == address(0) || weth_ == address(0) || usdg_ == address(0)
                || address(poolManager_) == address(0)
        ) revert ZeroAddress();
        v3Factory = v3Factory_;
        weth = weth_;
        usdg = usdg_;
        poolManager = poolManager_;
        allowedV4Hooks[address(0)] = true;
        emit V4HookAllowed(address(0), true);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @notice Sets the ETH depth every hop of a route must have.
    function setMinReferenceEth(uint256 minEth) external onlyOwner {
        minReferenceEth = minEth;
        emit MinReferenceDepthUpdated(minEth);
    }

    /**
     * @notice Allows or forbids a hook for V4 hops. Forbidding a hook does
     * not unregister its pools or routes but stops them from being priced,
     * including pools a registry hands back.
     */
    function setV4HookAllowed(address hook, bool allowed) external onlyOwner {
        allowedV4Hooks[hook] = allowed;
        emit V4HookAllowed(hook, allowed);
    }

    /// @notice Adds a launchpad registry.
    function addRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        if (address(registry) == address(0)) revert ZeroAddress();
        if (address(registry).code.length == 0) revert NotAContract(address(registry));
        if (registries.length >= MAX_REGISTRIES) revert TooManyRegistries();
        for (uint256 i = 0; i < registries.length; ++i) {
            if (registries[i] == registry) revert RegistryAlreadyAdded(address(registry));
        }
        registries.push(registry);
        emit RegistryAdded(address(registry));
    }

    /// @notice Removes a launchpad registry.
    function removeRegistry(IQuoteReferenceRegistry registry) external onlyOwner {
        uint256 n = registries.length;
        for (uint256 i = 0; i < n; ++i) {
            if (registries[i] != registry) continue;
            registries[i] = registries[n - 1];
            registries.pop();
            emit RegistryRemoved(address(registry));
            return;
        }
        revert UnknownRegistry(address(registry));
    }

    function registriesLength() external view returns (uint256) {
        return registries.length;
    }

    /// @notice Drops a stored route. The automatic search still applies.
    function clearPath(address token) external onlyOwner {
        if (_paths[token].length == 0) revert NoPathStored(token);
        delete _paths[token];
        emit PathCleared(token);
    }

    // ---------------------------------------------------------------------
    // V4 reference pools for the automatic routes
    // ---------------------------------------------------------------------

    /**
     * @notice Registers an initialized V4 pool for the automatic search. One
     * side must be an anchor: native ETH, WETH or USDG. A pool of USDG
     * against ETH is registered as pricing USDG in ETH, which is the second
     * leg of the two-hop route. Tokens a registry knows about do not need
     * this, and neither does anything reached through `registerPath`.
     */
    function registerV4Pool(PoolKey calldata key) external returns (bytes32 poolId) {
        if (!allowedV4Hooks[address(key.hooks)]) revert HookNotAllowed(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        (address anchor, address token, bool ok) = _splitAnchor(c0, c1);
        if (!ok) revert NotAnAnchorPool();

        poolId = PoolId.unwrap(key.toId());
        if (_v4Pools[poolId].registered) revert PoolAlreadyRegistered(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (_v4PoolsOf[token].length >= MAX_V4_POOLS_PER_TOKEN) revert TooManyPools(token);

        _v4Pools[poolId] = V4Pool({key: key, token: token, anchor: anchor, registered: true});
        _v4PoolsOf[token].push(poolId);
        allV4Pools.push(poolId);
        emit V4PoolRegistered(poolId, token, anchor, key);
    }

    function allV4PoolsLength() external view returns (uint256) {
        return allV4Pools.length;
    }

    function v4PoolsOf(address token) external view returns (bytes32[] memory) {
        return _v4PoolsOf[token];
    }

    function v4PoolIdFor(PoolKey calldata key) external pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ---------------------------------------------------------------------
    // Registered routes
    // ---------------------------------------------------------------------

    /**
     * @notice Stores a route from `token` to ETH for anyone to price against.
     * The route must be well formed and every hop at or above its floor
     * right now. It replaces a stored route only when that one no longer
     * qualifies or this one is stronger, so a route cannot be swapped for
     * a worse one. Open to anyone: the checks are the same whoever calls.
     */
    function registerPath(address token, Hop[] calldata hops) external returns (uint256 strengthX18) {
        if (token == address(0) || token == weth) revert ZeroAddress();
        Hop[] memory offered = hops;
        (PathReport memory rep,) = _walk(token, offered, 0);
        if (rep.fault != PathFault.None) revert InvalidPath(rep.fault, rep.faultHop);
        if (!rep.qualifies) revert PathNotQualifying(_firstFailing(rep));

        Hop[] memory current = _paths[token];
        if (current.length != 0) {
            (PathReport memory cur,) = _walk(token, current, 0);
            if (cur.qualifies && cur.strengthX18 >= rep.strengthX18) {
                revert PathNotStronger(cur.strengthX18, rep.strengthX18);
            }
            delete _paths[token];
        }
        for (uint256 i = 0; i < offered.length; ++i) {
            _paths[token].push(offered[i]);
        }
        emit PathRegistered(token, msg.sender, offered, rep.strengthX18);
        return rep.strengthX18;
    }

    /// @notice The route stored for `token`, empty when none.
    function pathOf(address token) external view returns (Hop[] memory) {
        return _paths[token];
    }

    /**
     * @notice Measures a route without storing it. Never reverts for a
     * malformed route: the report says what is wrong and where.
     */
    function evaluatePath(address token, Hop[] calldata hops) external view returns (PathReport memory rep) {
        (rep,) = _walk(token, hops, 0);
    }

    // ---------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------

    /**
     * @notice Converts a launch's ETH-denominated phantom reserve into
     * `quoteToken` units at the route price. Reverts when the asset has no
     * qualifying route or the figure rounds to zero.
     */
    function quoteEconomics(address quoteToken, uint256 phantomQuoteEth) external view returns (uint256 phantomQuote) {
        phantomQuote = priceEthAmountInQuote(quoteToken, phantomQuoteEth);
        if (phantomQuote == 0) revert QuoteAssetNotPriceable(quoteToken);
    }

    /**
     * @notice Returns how much of `quoteToken` is worth `ethAmount` of ETH
     * along the asset's route (WETH is treated as ETH one-to-one).
     */
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) public view returns (uint256) {
        if (quoteToken == weth) return ethAmount;
        (, PathReport memory rep, uint256 amount) = _route(quoteToken, ethAmount);
        if (!rep.qualifies) revert QuoteAssetNotPriceable(quoteToken);
        return amount;
    }

    /**
     * @notice True when `quoteToken` currently has a qualifying route, for
     * frontends to check before offering it in a create flow.
     */
    function isPriceable(address quoteToken) external view returns (bool) {
        if (quoteToken == weth) return true;
        (, PathReport memory rep,) = _route(quoteToken, 0);
        return rep.qualifies;
    }

    /**
     * @notice The route that prices `quoteToken`, in trade order from the
     * asset to ETH, and whether it qualifies. When nothing qualifies the
     * closest route is returned anyway so a frontend can still trade along
     * it; empty when no pool is known at all.
     */
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies) {
        if (quoteToken == weth) return (hops, true);
        PathReport memory rep;
        (hops, rep,) = _route(quoteToken, 0);
        qualifies = rep.qualifies;
    }

    /**
     * @notice The route that prices `quoteToken` with every hop's depth and
     * floor, so an interface can say what is missing. Same selection as
     * `route`.
     */
    function describe(address quoteToken) external view returns (PathReport memory rep) {
        if (quoteToken == weth) {
            rep.qualifies = true;
            rep.strengthX18 = type(uint256).max;
            return rep;
        }
        (, rep,) = _route(quoteToken, 0);
    }

    // ---------------------------------------------------------------------
    // Route selection
    // ---------------------------------------------------------------------

    /**
     * @dev Picks between the stored route and the automatic one: a
     * qualifying route beats a failing one, and between two qualifying
     * routes the stronger wins. When neither qualifies the closer one is
     * reported so the interface can explain. `amount` is `ethAmount`
     * converted along the chosen route.
     */
    function _route(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop[] memory autoHops, PathReport memory autoRep, uint256 autoAmount) = _auto(token, ethAmount);

        Hop[] memory stored = _paths[token];
        if (stored.length == 0) return (autoHops, autoRep, autoAmount);

        (PathReport memory storedRep, uint256 storedAmount) = _walk(token, stored, ethAmount);
        storedRep.registered = true;
        if (_prefer(storedRep, autoRep)) return (stored, storedRep, storedAmount);
        return (autoHops, autoRep, autoAmount);
    }

    function _prefer(PathReport memory a, PathReport memory b) private pure returns (bool) {
        if (a.qualifies != b.qualifies) return a.qualifies;
        if (b.hops.length == 0) return true;
        if (a.hops.length == 0) return false;
        return a.strengthX18 >= b.strengthX18;
    }

    /**
     * @dev The automatic routes: the deepest direct pool against ETH, else
     * the deepest pool against USDG followed by the deepest USDG pool
     * against ETH. The direct route is taken when it qualifies; otherwise
     * whichever of the two is closer is reported.
     */
    function _auto(address token, uint256 ethAmount)
        private
        view
        returns (Hop[] memory hops, PathReport memory rep, uint256 amount)
    {
        (Hop memory direct, bool hasDirect) = _bestPool(token, true);
        if (hasDirect) {
            hops = new Hop[](1);
            hops[0] = direct;
            (rep, amount) = _walk(token, hops, ethAmount);
            if (rep.qualifies) return (hops, rep, amount);
        }

        (Hop memory viaUsdg, bool hasViaUsdg) = _bestPool(token, false);
        (Hop memory usdgLeg, bool hasUsdgLeg) = _bestPool(usdg, true);
        if (hasViaUsdg && (hasUsdgLeg || !hasDirect)) {
            Hop[] memory two = new Hop[](hasUsdgLeg ? 2 : 1);
            two[0] = viaUsdg;
            if (hasUsdgLeg) two[1] = usdgLeg;
            (PathReport memory twoRep, uint256 twoAmount) = _walk(token, two, ethAmount);
            if (!hasDirect || _prefer(twoRep, rep)) return (two, twoRep, twoAmount);
        }
        // Nothing at all: an empty report with the fault set, so `describe`
        // is honest about it.
        if (!hasDirect) {
            rep.fault = PathFault.Empty;
        }
    }

    // ---------------------------------------------------------------------
    // Route walking
    // ---------------------------------------------------------------------

    /**
     * @dev Checks a route's shape and measures every hop. Walks from the
     * quote to ETH to check the hops connect, then back from ETH to the
     * quote converting the floor and `ethAmount` hop by hop at spot. A
     * malformed route yields a report with `fault` set and never reverts,
     * except for an amount that overflows the conversion.
     */
    function _walk(address token, Hop[] memory hops, uint256 ethAmount)
        private
        view
        returns (PathReport memory rep, uint256 amount)
    {
        uint256 n = hops.length;
        if (n == 0) return (_faulted(rep, PathFault.Empty, 0), 0);
        if (n > MAX_HOPS) return (_faulted(rep, PathFault.TooLong, MAX_HOPS), 0);

        address[] memory chain = new address[](n + 1);
        chain[0] = token;
        for (uint256 i = 0; i < n; ++i) {
            (address next, PathFault fault) = _step(hops[i], chain[i]);
            if (fault != PathFault.None) return (_faulted(rep, fault, i), 0);
            for (uint256 j = 0; j <= i; ++j) {
                if (chain[j] == next) return (_faulted(rep, PathFault.Revisits, i), 0);
            }
            if (_isEth(next) && i + 1 < n) return (_faulted(rep, PathFault.EthMidRoute, i), 0);
            chain[i + 1] = next;
        }
        if (!_isEth(chain[n])) return (_faulted(rep, PathFault.NotToEth, n - 1), 0);

        rep.hops = new HopReport[](n);
        rep.qualifies = true;
        rep.strengthX18 = type(uint256).max;
        uint256 floor = minReferenceEth;
        amount = ethAmount;
        for (uint256 k = n; k > 0; --k) {
            uint256 i = k - 1;
            (uint160 sqrtPriceX96, uint256 depth) = _hopState(hops[i], chain[i + 1]);
            HopReport memory h = rep.hops[i];
            h.hop = hops[i];
            h.tokenIn = chain[i];
            h.tokenOut = chain[i + 1];
            h.depth = depth;
            h.floor = floor;
            h.qualifies = depth >= floor;
            if (!h.qualifies) rep.qualifies = false;
            uint256 strength = floor == 0 ? type(uint256).max : FullMath.mulDiv(depth, 1e18, floor);
            if (strength < rep.strengthX18) rep.strengthX18 = strength;

            if (i > 0) floor = _convertOrCap(sqrtPriceX96, floor, chain[i + 1], chain[i]);
            if (amount != 0) {
                if (amount > type(uint128).max) revert ConversionOverflow();
                amount = _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), chain[i + 1], chain[i]);
            }
        }
    }

    function _faulted(PathReport memory rep, PathFault fault, uint256 hopIndex)
        private
        pure
        returns (PathReport memory)
    {
        rep.fault = fault;
        rep.faultHop = hopIndex;
        rep.qualifies = false;
        return rep;
    }

    function _firstFailing(PathReport memory rep) private pure returns (uint256) {
        for (uint256 i = 0; i < rep.hops.length; ++i) {
            if (!rep.hops[i].qualifies) return i;
        }
        return 0;
    }

    /**
     * @dev Checks one hop is well formed and contains `tokenIn`, returning
     * the asset on the other side. For V3 the pool must exist at the factory
     * for the stated pair and fee; for V4 the hook must be allowed. Either
     * way the pool must be initialized.
     */
    function _step(Hop memory hop, address tokenIn) private view returns (address tokenOut, PathFault fault) {
        address c0 = Currency.unwrap(hop.key.currency0);
        address c1 = Currency.unwrap(hop.key.currency1);
        if (tokenIn == c0) tokenOut = c1;
        else if (tokenIn == c1) tokenOut = c0;
        else return (address(0), PathFault.Disconnected);

        if (hop.v3) {
            if (c0 == address(0)) return (tokenOut, PathFault.NativeOnV3);
            if (hop.key.tickSpacing != 0 || address(hop.key.hooks) != address(0)) {
                return (tokenOut, PathFault.V3KeyNotBare);
            }
            address pool = v3Factory.getPool(c0, c1, hop.key.fee);
            if (pool == address(0)) return (tokenOut, PathFault.NoV3Pool);
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        } else {
            if (!allowedV4Hooks[address(hop.key.hooks)]) return (tokenOut, PathFault.HookNotAllowed);
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(hop.key.toId());
            if (sqrtPriceX96 == 0) return (tokenOut, PathFault.NotInitialized);
        }
        return (tokenOut, PathFault.None);
    }

    /**
     * @dev A hop's spot price and how much of `side` it holds: the balance a
     * V3 pool physically holds, or for V4 the in-range virtual reserve at
     * the current price, `L / sqrtP` for currency0 and `L * sqrtP` for
     * currency1. Ranking V3 pools by the balance held rather than the
     * `liquidity()` figure is deliberate: that figure is nearly free to
     * inflate with a narrow position at an attacker-chosen tick, while
     * tokens sent to a V3 pool beyond its accounted reserves are simply
     * lost, so displacing an honest pool costs more than everything it
     * holds.
     */
    function _hopState(Hop memory hop, address side) private view returns (uint160 sqrtPriceX96, uint256 depth) {
        if (hop.v3) {
            address pool = v3Factory.getPool(
                Currency.unwrap(hop.key.currency0), Currency.unwrap(hop.key.currency1), hop.key.fee
            );
            (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            depth = IERC20(side).balanceOf(pool);
        } else {
            PoolId id = hop.key.toId();
            (sqrtPriceX96,,,) = poolManager.getSlot0(id);
            uint128 liquidity = poolManager.getLiquidity(id);
            if (sqrtPriceX96 == 0 || liquidity == 0) return (sqrtPriceX96, 0);
            depth = side == Currency.unwrap(hop.key.currency0)
                ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
                : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);
        }
    }

    function _isEth(address token) private view returns (bool) {
        return token == address(0) || token == weth;
    }

    // ---------------------------------------------------------------------
    // Automatic pool selection
    // ---------------------------------------------------------------------

    /**
     * @dev The deepest pool pairing `token` with ETH (V3 WETH pool, V4
     * native or WETH pool) or with USDG, as a hop.
     */
    function _bestPool(address token, bool ethAnchor) private view returns (Hop memory hop, bool found) {
        address v3Anchor = ethAnchor ? weth : usdg;
        (address v3Pool, uint24 v3Fee, uint256 v3Depth) = _bestV3Pool(token, v3Anchor);
        (PoolKey memory v4Key, uint256 v4Depth, bool v4Found) = _bestV4Pool(token, ethAnchor);

        if (v3Pool == address(0) && !v4Found) return (hop, false);
        if (v3Pool != address(0) && (!v4Found || v3Depth >= v4Depth)) {
            (address c0, address c1) = token < v3Anchor ? (token, v3Anchor) : (v3Anchor, token);
            hop.key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: v3Fee,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            });
            hop.v3 = true;
        } else {
            hop.key = v4Key;
        }
        found = true;
    }

    /// @dev The standard-tier V3 pool for the pair holding the most of the anchor.
    function _bestV3Pool(address token, address anchor)
        private
        view
        returns (address best, uint24 bestFee, uint256 bestBalance)
    {
        uint24[3] memory tiers = [FEE_LOW, FEE_MEDIUM, FEE_HIGH];
        for (uint256 i = 0; i < tiers.length; ++i) {
            address pool = v3Factory.getPool(token, anchor, tiers[i]);
            if (pool == address(0)) continue;
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
            if (sqrtPriceX96 == 0) continue;
            uint256 anchorBalance = IERC20(anchor).balanceOf(pool);
            if (anchorBalance > bestBalance) {
                bestBalance = anchorBalance;
                bestFee = tiers[i];
                best = pool;
            }
        }
    }

    /**
     * @dev The V4 pool pairing `token` with ETH (native or WETH) or USDG
     * with the deepest in-range anchor reserve, among hand-registered pools
     * and pools the registries know, whose hook is allowed.
     */
    function _bestV4Pool(address token, bool ethAnchor)
        private
        view
        returns (PoolKey memory bestKey, uint256 bestDepth, bool found)
    {
        bytes32[] storage ids = _v4PoolsOf[token];
        for (uint256 i = 0; i < ids.length; ++i) {
            V4Pool storage p = _v4Pools[ids[i]];
            (uint256 depth, bool ok) = _v4Candidate(p.key, p.anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (p.key, depth, true);
        }
        for (uint256 i = 0; i < registries.length; ++i) {
            (bool has, PoolKey memory key) = _registryPool(registries[i], token);
            if (!has) continue;
            (address anchor, address priced, bool split) =
                _splitAnchor(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
            if (!split || priced != token) continue;
            (uint256 depth, bool ok) = _v4Candidate(key, anchor, ethAnchor);
            if (ok && (!found || depth > bestDepth)) (bestKey, bestDepth, found) = (key, depth, true);
        }
    }

    /**
     * @dev A registry that reverts is skipped, not fatal. The code check
     * matters: a high-level call to an address without code reverts in the
     * caller, outside the try, and would take every launch down with it.
     */
    function _registryPool(IQuoteReferenceRegistry registry, address token)
        private
        view
        returns (bool found, PoolKey memory key)
    {
        if (address(registry).code.length == 0) return (false, key);
        try registry.referencePool(token) returns (bool f, PoolKey memory k) {
            return (f, k);
        } catch {
            return (false, key);
        }
    }

    function _v4Candidate(PoolKey memory key, address anchor, bool ethAnchor)
        private
        view
        returns (uint256 depth, bool ok)
    {
        if (_isEth(anchor) != ethAnchor) return (0, false);
        if (!allowedV4Hooks[address(key.hooks)]) return (0, false);
        Hop memory hop;
        hop.key = key;
        (, depth) = _hopState(hop, anchor);
        ok = depth > 0;
    }

    function _splitAnchor(address c0, address c1) private view returns (address anchor, address token, bool ok) {
        if (_isEth(c0) || _isEth(c1)) {
            // An ETH side always anchors, so an ETH/USDG pool prices USDG.
            return _isEth(c0) ? (c0, c1, true) : (c1, c0, true);
        }
        if (c0 == usdg) return (c0, c1, true);
        if (c1 == usdg) return (c1, c0, true);
        return (address(0), address(0), false);
    }

    // ---------------------------------------------------------------------
    // Conversion
    // ---------------------------------------------------------------------

    /// @dev Like `_quoteAtSqrtPrice` but saturates instead of reverting, for floors.
    function _convertOrCap(uint160 sqrtPriceX96, uint256 amount, address base, address quote)
        private
        pure
        returns (uint256)
    {
        if (amount > type(uint128).max) return type(uint256).max;
        return _quoteAtSqrtPrice(sqrtPriceX96, uint128(amount), base, quote);
    }

    /**
     * @dev Port of Uniswap V3 OracleLibrary.getQuoteAtTick, taking the sqrt
     * price directly. `baseToken` and `quoteToken` are the pool's currency
     * addresses (address zero for native ETH), so their ordering is the
     * pool's own.
     */
    function _quoteAtSqrtPrice(uint160 sqrtRatioX96, uint128 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
