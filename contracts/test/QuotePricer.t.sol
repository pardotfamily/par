// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    PairPadQuotePricer,
    IUniswapV3FactoryMinimal,
    IQuoteReferenceRegistry
} from "../src/v2/PairPadQuotePricer.sol";
import {
    PairPadReferenceRegistry,
    PonsReferenceRegistry,
    IPairPadFactoryPoolKeys,
    IPonsV2LaunchFactory
} from "../src/v2/PairPadReferenceRegistries.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Factory, MockV3Pool} from "./mocks/MockUniswapV3.sol";
import {MockV4State} from "./mocks/MockV4State.sol";
import {Hop} from "../src/v2/libraries/Hop.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath as TickMathLib} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath as FullMathLib} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev Stands in for a launchpad factory: answers poolKeyFor for tokens it was told about.
contract FakeLaunchpad is IPairPadFactoryPoolKeys {
    mapping(address => PoolKey) private _keys;
    mapping(address => bool) private _has;

    function set(address token, PoolKey memory key) external {
        _keys[token] = key;
        _has[token] = true;
    }

    function poolKeyFor(address token) external view returns (PoolKey memory) {
        require(_has[token], "not launched");
        return _keys[token];
    }
}

/// @dev Stands in for PonsV2LaunchFactory.getLaunchedToken.
contract FakePonsFactory is IPonsV2LaunchFactory {
    mapping(address => LaunchedToken) private _t;

    function set(address token, address pairToken, uint24 fee, int24 spacing) external {
        LaunchedToken memory t;
        t.token = token;
        t.pairToken = pairToken;
        t.poolFee = fee;
        t.tickSpacing = spacing;
        t.exists = true;
        _t[token] = t;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return _t[token];
    }
}

contract QuotePricerTest is Test {
    using PoolIdLibrary for PoolKey;

    PairPadQuotePricer internal pricer;
    MockV3Factory internal v3Factory;
    MockV4State internal v4;
    MockERC20 internal weth;
    MockERC20 internal usdg;
    MockERC20 internal qt;

    // Liquidity 1e21 at tick 0 has 1e21 of each side in range: deep.
    uint128 internal constant DEEP = 1e21;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        qt = new MockERC20("Quote", "QT", 18);
        v3Factory = new MockV3Factory();
        v4 = new MockV4State();
        pricer = new PairPadQuotePricer(
            address(this),
            IUniswapV3FactoryMinimal(address(v3Factory)),
            address(weth),
            address(usdg),
            IPoolManager(address(v4))
        );
    }

    function _key(address a, address b, address hook) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
    }

    function _addV3Pool(address a, address b, uint24 fee, int24 tick, address anchor, uint256 anchorBal)
        internal
        returns (MockV3Pool pool)
    {
        pool = new MockV3Pool(tick, 1e24);
        MockERC20(anchor).mint(address(pool), anchorBal);
        v3Factory.setPool(a, b, fee, address(pool));
    }

    // ------------------------------------------------------------------
    // Direct ETH references
    // ------------------------------------------------------------------

    function test_wethPassesThrough() public view {
        assertEq(pricer.priceEthAmountInQuote(address(weth), 4.2 ether), 4.2 ether);
        assertTrue(pricer.isPriceable(address(weth)));
    }

    function test_v3_tickZeroIsOneToOne_noWaiting() public {
        // Pool created in this very block: usable at once.
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 5 ether);
        assertTrue(pricer.isPriceable(address(qt)));
        assertEq(pricer.priceEthAmountInQuote(address(qt), 4.2 ether), 4.2 ether);
        assertEq(pricer.quoteEconomics(address(qt), 1.3557 ether), 1.3557 ether);
    }

    function test_v3_floorIsFiveEth() public {
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 4.99 ether);
        assertFalse(pricer.isPriceable(address(qt)));
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.QuoteAssetNotPriceable.selector, address(qt)));
        pricer.priceEthAmountInQuote(address(qt), 1 ether);

        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertEq(rep.hops.length, 1);
        assertTrue(rep.hops[0].hop.v3);
        assertEq(rep.hops[0].tokenIn, address(qt));
        assertEq(rep.hops[0].tokenOut, address(weth));
        assertEq(rep.hops[0].depth, 4.99 ether);
        assertEq(rep.hops[0].floor, 5 ether);
        assertFalse(rep.qualifies);
        assertFalse(rep.registered);
        assertEq(rep.strengthX18, 0.998e18);

        weth.mint(v3Factory.getPool(address(qt), address(weth), 3000), 0.01 ether);
        assertTrue(pricer.isPriceable(address(qt)));
    }

    function test_v3_ranksByAnchorBalance_notLiquidityFigure() public {
        // The honest pool holds more WETH; the rival reports an enormous
        // in-range liquidity figure at a manipulated tick but holds less WETH.
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 10 ether);
        MockV3Pool rival = new MockV3Pool(100_000, type(uint128).max);
        weth.mint(address(rival), 6 ether);
        v3Factory.setPool(address(qt), address(weth), 500, address(rival));
        assertEq(pricer.priceEthAmountInQuote(address(qt), 1 ether), 1 ether);
    }

    function test_v3_nonZeroTick_convertsWithDirection() public {
        // tick 6932 ~ price ratio of 2. Which side doubles depends on the
        // address ordering, so assert the pair of outcomes.
        _addV3Pool(address(qt), address(weth), 3000, 6932, address(weth), 5 ether);
        uint256 out = pricer.priceEthAmountInQuote(address(qt), 1 ether);
        if (address(weth) < address(qt)) assertApproxEqRel(out, 2 ether, 0.001e18);
        else assertApproxEqRel(out, 0.5 ether, 0.001e18);
    }

    function test_v4_registeredNativePool_pricesAtOnce() public {
        PoolKey memory key = _key(address(0), address(qt), address(0));
        v4.setPool(key, 0, DEEP);
        bytes32 id = pricer.registerV4Pool(key);
        assertEq(id, PoolId.unwrap(key.toId()));
        assertEq(pricer.v4PoolIdFor(key), id);
        assertTrue(pricer.isPriceable(address(qt)));
        assertEq(pricer.priceEthAmountInQuote(address(qt), 4.2 ether), 4.2 ether);

        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertEq(rep.hops.length, 1);
        assertFalse(rep.hops[0].hop.v3);
        assertEq(rep.hops[0].tokenOut, address(0));
        assertEq(rep.hops[0].depth, 1e21);
        assertTrue(rep.qualifies);

        (Hop[] memory hops, bool qualifies) = pricer.route(address(qt));
        assertTrue(qualifies);
        assertEq(hops.length, 1);
        assertEq(PoolId.unwrap(hops[0].key.toId()), id);
    }

    function test_v4_depthFloorFiltersThinPools() public {
        // Liquidity 4e18 at tick 0 has 4 ETH in range: under the floor.
        PoolKey memory key = _key(address(0), address(qt), address(0));
        v4.setPool(key, 0, 4e18);
        pricer.registerV4Pool(key);
        assertFalse(pricer.isPriceable(address(qt)));
        v4.setPool(key, 0, 5e18);
        assertTrue(pricer.isPriceable(address(qt)));
    }

    function test_v4_disallowedHook_rejectedAndRevocable() public {
        address hook = makeAddr("hook");
        PoolKey memory key = _key(address(0), address(qt), hook);
        v4.setPool(key, 0, DEEP);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.HookNotAllowed.selector, hook));
        pricer.registerV4Pool(key);

        pricer.setV4HookAllowed(hook, true);
        pricer.registerV4Pool(key);
        assertTrue(pricer.isPriceable(address(qt)));

        pricer.setV4HookAllowed(hook, false);
        assertFalse(pricer.isPriceable(address(qt)));
    }

    function test_v4_registrationGuards() public {
        PoolKey memory key = _key(address(0), address(qt), address(0));
        vm.expectRevert(PairPadQuotePricer.PoolNotInitialized.selector);
        pricer.registerV4Pool(key);

        v4.setPool(key, 0, DEEP);
        bytes32 id = pricer.registerV4Pool(key);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.PoolAlreadyRegistered.selector, id));
        pricer.registerV4Pool(key);

        MockERC20 other = new MockERC20("Other", "OTH", 18);
        PoolKey memory noAnchor = _key(address(qt), address(other), address(0));
        v4.setPool(noAnchor, 0, DEEP);
        vm.expectRevert(PairPadQuotePricer.NotAnAnchorPool.selector);
        pricer.registerV4Pool(noAnchor);
    }

    function test_deeperReferenceWins_acrossVersions() public {
        // V3 at tick 0 holding 5 WETH, V4 at a 2x tick with 50 ETH in range:
        // the deeper V4 pool is the reference.
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 5 ether);
        PoolKey memory key = _key(address(0), address(qt), address(0));
        v4.setPool(key, 6932, 50e18);
        pricer.registerV4Pool(key);
        assertApproxEqRel(pricer.priceEthAmountInQuote(address(qt), 1 ether), 2 ether, 0.001e18);

        // Shrink the V4 pool below the V3 depth and the V3 reference is back.
        v4.setPool(key, 6932, 2e18);
        assertEq(pricer.priceEthAmountInQuote(address(qt), 1 ether), 1 ether);
    }

    // ------------------------------------------------------------------
    // Two hops through USDG
    // ------------------------------------------------------------------

    function test_twoHop_v3_usdgFloorIsFiveEthWorth() public {
        // WETH/USDG at a tick where 1 WETH = 2000 USDG (raw 1e18 -> 2000e6 is
        // a ratio of 2e-9, tick ~ -200311). Use the mock's tick directly.
        int24 tick = _tickFor(address(weth), address(usdg), 2000e6, 1e18);
        _addV3Pool(address(usdg), address(weth), 500, tick, address(weth), 20 ether);
        // QT/USDG at 1:1 raw. The USDG floor is 5 ETH worth: 10,000 USDG.
        MockV3Pool qtPool = _addV3Pool(address(qt), address(usdg), 3000, 0, address(usdg), 9_999e6);
        assertFalse(pricer.isPriceable(address(qt)));
        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertEq(rep.hops.length, 2);
        assertEq(rep.hops[0].tokenOut, address(usdg));
        assertEq(rep.hops[1].tokenIn, address(usdg));
        assertEq(rep.hops[1].tokenOut, address(weth));
        assertTrue(rep.hops[1].qualifies);
        assertApproxEqAbs(rep.hops[0].floor, 10_000e6, 2e6);
        assertFalse(rep.hops[0].qualifies);
        assertFalse(rep.qualifies);

        usdg.mint(address(qtPool), 10e6);
        assertTrue(pricer.isPriceable(address(qt)));
        // 2 ETH -> ~4000 USDG -> ~4000e6 raw QT (QT has 18 decimals but the
        // pool is 1:1 in raw units).
        assertApproxEqRel(pricer.priceEthAmountInQuote(address(qt), 2 ether), 4_000e6, 0.001e18);
    }

    function test_twoHop_v4_ethUsdgThenQuoteUsdg() public {
        PoolKey memory ethUsdg = _key(address(0), address(usdg), address(0));
        PoolKey memory qtUsdg = _key(address(qt), address(usdg), address(0));
        v4.setPool(ethUsdg, 0, DEEP);
        v4.setPool(qtUsdg, 0, DEEP);
        pricer.registerV4Pool(ethUsdg);
        pricer.registerV4Pool(qtUsdg);
        assertTrue(pricer.isPriceable(address(qt)));
        assertEq(pricer.priceEthAmountInQuote(address(qt), 2 ether), 2 ether);
    }

    function test_twoHop_needsBothLegs() public {
        _addV3Pool(address(qt), address(usdg), 3000, 0, address(usdg), 1_000_000e6);
        // No USDG/ETH reference at all: not priceable, whatever the QT/USDG depth.
        assertFalse(pricer.isPriceable(address(qt)));
        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertFalse(rep.qualifies);
        // The QT/USDG hop alone does not reach ETH.
        assertEq(uint8(rep.fault), uint8(PairPadQuotePricer.PathFault.NotToEth));
    }

    function test_noPath_reverts() public {
        assertFalse(pricer.isPriceable(address(qt)));
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.QuoteAssetNotPriceable.selector, address(qt)));
        pricer.priceEthAmountInQuote(address(qt), 1 ether);
        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertEq(rep.hops.length, 0);
        assertEq(uint8(rep.fault), uint8(PairPadQuotePricer.PathFault.Empty));
        (Hop[] memory hops, bool qualifies) = pricer.route(address(qt));
        assertEq(hops.length, 0);
        assertFalse(qualifies);
    }

    // ------------------------------------------------------------------
    // Registered routes
    // ------------------------------------------------------------------

    MockERC20 internal br;

    function _v3Hop(address a, address b, uint24 fee) internal pure returns (Hop memory hop) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        hop.key = PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: fee, tickSpacing: 0, hooks: IHooks(address(0))
        });
        hop.v3 = true;
    }

    function _v4Hop(PoolKey memory key) internal pure returns (Hop memory hop) {
        hop.key = key;
    }

    /// @dev QT trades only against a bridge token BR on V4; BR trades against
    /// USDG on V3; USDG against WETH on V3 at 2000 per ETH. Three hops.
    function _threeHopWorld() internal returns (Hop[] memory hops, MockV3Pool brUsdg) {
        br = new MockERC20("Bridge", "BR", 18);
        PoolKey memory qtBr = _key(address(qt), address(br), address(0));
        v4.setPool(qtBr, 0, DEEP);
        brUsdg = _addV3Pool(address(br), address(usdg), 3000, 0, address(usdg), 50_000e6);
        int24 tick = _tickFor(address(weth), address(usdg), 2000e6, 1e18);
        _addV3Pool(address(usdg), address(weth), 500, tick, address(weth), 20 ether);

        hops = new Hop[](3);
        hops[0] = _v4Hop(qtBr);
        hops[1] = _v3Hop(address(br), address(usdg), 3000);
        hops[2] = _v3Hop(address(usdg), address(weth), 500);
    }

    function test_path_threeHops_registeredThenPriced() public {
        (Hop[] memory hops,) = _threeHopWorld();
        // Nothing automatic reaches QT: no ETH or USDG pool for it.
        assertFalse(pricer.isPriceable(address(qt)));

        PairPadQuotePricer.PathReport memory rep = pricer.evaluatePath(address(qt), hops);
        assertTrue(rep.qualifies);
        assertEq(rep.hops.length, 3);
        assertEq(rep.hops[0].tokenOut, address(br));
        assertEq(rep.hops[1].tokenOut, address(usdg));
        assertEq(rep.hops[2].tokenOut, address(weth));
        assertEq(rep.hops[2].floor, 5 ether);
        // 5 ETH is 10,000 USDG; BR is 1:1 raw with USDG so the same figure.
        assertApproxEqAbs(rep.hops[1].floor, 10_000e6, 2e6);
        assertApproxEqAbs(rep.hops[0].floor, 10_000e6, 2e6);
        // Weakest hop: USDG/WETH holds 20 of a 5 floor, BR/USDG 50k of 10k,
        // QT/BR 1e21 of 1e10; strength is 4x.
        assertApproxEqRel(rep.strengthX18, 4e18, 0.001e18);

        vm.expectEmit(true, true, false, false);
        emit PairPadQuotePricer.PathRegistered(address(qt), address(this), hops, 0);
        uint256 strength = pricer.registerPath(address(qt), hops);
        assertEq(strength, rep.strengthX18);

        assertTrue(pricer.isPriceable(address(qt)));
        // 2 ETH -> ~4000 USDG -> ~4000e6 BR raw -> ~4000e6 QT raw.
        assertApproxEqRel(pricer.priceEthAmountInQuote(address(qt), 2 ether), 4_000e6, 0.001e18);

        (Hop[] memory used, bool qualifies) = pricer.route(address(qt));
        assertTrue(qualifies);
        assertEq(used.length, 3);
        assertTrue(pricer.describe(address(qt)).registered);
        assertEq(pricer.pathOf(address(qt)).length, 3);
    }

    function test_path_everyHopMustClearItsFloor() public {
        (Hop[] memory hops, MockV3Pool brUsdg) = _threeHopWorld();
        // Drain the middle hop under its 10k USDG floor.
        vm.prank(address(brUsdg));
        usdg.transfer(address(1), 45_000e6);

        PairPadQuotePricer.PathReport memory rep = pricer.evaluatePath(address(qt), hops);
        assertFalse(rep.qualifies);
        assertTrue(rep.hops[0].qualifies);
        assertFalse(rep.hops[1].qualifies);
        assertTrue(rep.hops[2].qualifies);

        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.PathNotQualifying.selector, 1));
        pricer.registerPath(address(qt), hops);
    }

    function test_path_shapeFaults() public {
        (Hop[] memory hops,) = _threeHopWorld();

        // Middle hop swapped for one that does not contain BR.
        Hop[] memory broken = _clone(hops);
        broken[1] = _v3Hop(address(weth), address(usdg), 500);
        _expectFault(broken, PairPadQuotePricer.PathFault.Disconnected, 1);

        // Stops at USDG.
        Hop[] memory short_ = new Hop[](2);
        short_[0] = hops[0];
        short_[1] = hops[1];
        _expectFault(short_, PairPadQuotePricer.PathFault.NotToEth, 1);

        // Reaches ETH and then keeps going.
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        _addV3Pool(address(weth), address(other), 3000, 0, address(weth), 10 ether);
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 1 ether);
        Hop[] memory mid = new Hop[](2);
        mid[0] = _v3Hop(address(qt), address(weth), 3000);
        mid[1] = _v3Hop(address(weth), address(other), 3000);
        _expectFault(mid, PairPadQuotePricer.PathFault.EthMidRoute, 0);

        // A V3 hop naming native ETH.
        Hop[] memory native = new Hop[](1);
        native[0] = _v3Hop(address(qt), address(0), 3000);
        _expectFault(native, PairPadQuotePricer.PathFault.NativeOnV3, 0);

        // A V3 hop at a tier with no pool.
        Hop[] memory noPool = _clone(hops);
        noPool[1] = _v3Hop(address(br), address(usdg), 10_000);
        _expectFault(noPool, PairPadQuotePricer.PathFault.NoV3Pool, 1);

        // A V3 hop dressed as a V4 key.
        Hop[] memory notBare = _clone(hops);
        notBare[1].key.tickSpacing = 60;
        _expectFault(notBare, PairPadQuotePricer.PathFault.V3KeyNotBare, 1);

        // Too long, and empty.
        Hop[] memory long_ = new Hop[](5);
        _expectFault(long_, PairPadQuotePricer.PathFault.TooLong, 4);
        _expectFault(new Hop[](0), PairPadQuotePricer.PathFault.Empty, 0);

        // A V4 hop with a hook that is not allowed, and one never initialized.
        Hop[] memory hooked = _clone(hops);
        hooked[0].key.hooks = IHooks(makeAddr("hook"));
        _expectFault(hooked, PairPadQuotePricer.PathFault.HookNotAllowed, 0);
        Hop[] memory cold = _clone(hops);
        cold[0].key.fee = 3000;
        _expectFault(cold, PairPadQuotePricer.PathFault.NotInitialized, 0);

        // Round trip through the same asset.
        Hop[] memory loop = new Hop[](3);
        loop[0] = hops[0];
        loop[1] = hops[0];
        loop[2] = hops[2];
        _expectFault(loop, PairPadQuotePricer.PathFault.Revisits, 1);
    }

    function test_path_replacementOnlyByStronger() public {
        (Hop[] memory hops, MockV3Pool brUsdg) = _threeHopWorld();
        uint256 first = pricer.registerPath(address(qt), hops);

        // The same route again is not stronger.
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.PathNotStronger.selector, first, first));
        pricer.registerPath(address(qt), hops);

        // Deepening a hop that is not the weakest changes nothing: strength
        // is the weakest hop's, here USDG/WETH at 20 over a 5 floor.
        _addV3Pool(address(br), address(usdg), 500, 0, address(usdg), 500_000e6);
        Hop[] memory sideways = _clone(hops);
        sideways[1] = _v3Hop(address(br), address(usdg), 500);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.PathNotStronger.selector, first, first));
        pricer.registerPath(address(qt), sideways);

        // A route through a deeper USDG/WETH tier is stronger and replaces it.
        int24 tick = _tickFor(address(weth), address(usdg), 2000e6, 1e18);
        MockV3Pool deep = _addV3Pool(address(usdg), address(weth), 3000, tick, address(weth), 40 ether);
        Hop[] memory deeper = _clone(hops);
        deeper[2] = _v3Hop(address(usdg), address(weth), 3000);
        uint256 second = pricer.registerPath(address(qt), deeper);
        // The weakest hop is now BR/USDG: 50k over a 10k floor.
        assertApproxEqRel(second, 5e18, 0.001e18);
        assertGt(second, first);
        assertEq(pricer.pathOf(address(qt))[2].key.fee, 3000);

        // Once the stored route stops qualifying anything that qualifies may
        // replace it, stronger or not.
        vm.prank(address(deep));
        weth.transfer(address(1), 36 ether);
        assertFalse(pricer.isPriceable(address(qt)));
        pricer.registerPath(address(qt), hops);
        assertTrue(pricer.isPriceable(address(qt)));
        assertEq(pricer.pathOf(address(qt))[2].key.fee, 500);
        brUsdg;
    }

    function test_path_strongerOfRegisteredAndAutomaticWins() public {
        (Hop[] memory hops,) = _threeHopWorld();
        pricer.registerPath(address(qt), hops);

        // A thin direct pool: qualifies, 6 WETH over a 5 floor, weaker than
        // the registered route's 4x. Registered route prices.
        MockV3Pool direct = _addV3Pool(address(qt), address(weth), 3000, 6932, address(weth), 6 ether);
        PairPadQuotePricer.PathReport memory rep = pricer.describe(address(qt));
        assertTrue(rep.registered);
        assertEq(rep.hops.length, 3);

        // Deepen the direct pool past 4x and it takes over.
        weth.mint(address(direct), 20 ether);
        rep = pricer.describe(address(qt));
        assertFalse(rep.registered);
        assertEq(rep.hops.length, 1);

        // Registered route failing, automatic qualifying: automatic.
        pricer.setV4HookAllowed(address(0), false);
        rep = pricer.describe(address(qt));
        assertFalse(rep.registered);
        pricer.setV4HookAllowed(address(0), true);

        // Automatic failing, registered qualifying: registered.
        vm.prank(address(direct));
        weth.transfer(address(1), 25 ether);
        rep = pricer.describe(address(qt));
        assertTrue(rep.registered);
        assertTrue(rep.qualifies);
    }

    function test_path_ownerCanClear() public {
        (Hop[] memory hops,) = _threeHopWorld();
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.NoPathStored.selector, address(qt)));
        pricer.clearPath(address(qt));

        pricer.registerPath(address(qt), hops);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        pricer.clearPath(address(qt));

        pricer.clearPath(address(qt));
        assertEq(pricer.pathOf(address(qt)).length, 0);
        assertFalse(pricer.isPriceable(address(qt)));
    }

    function test_path_wethAndZeroRejected() public {
        Hop[] memory none = new Hop[](0);
        vm.expectRevert(PairPadQuotePricer.ZeroAddress.selector);
        pricer.registerPath(address(weth), none);
        vm.expectRevert(PairPadQuotePricer.ZeroAddress.selector);
        pricer.registerPath(address(0), none);
    }

    /// @dev A deep copy: memory structs assign by reference, and the fault
    /// tests each tamper with one hop.
    function _clone(Hop[] memory hops) internal pure returns (Hop[] memory out) {
        out = new Hop[](hops.length);
        for (uint256 i = 0; i < hops.length; ++i) {
            PoolKey memory k = hops[i].key;
            out[i] = Hop({
                key: PoolKey({
                    currency0: k.currency0, currency1: k.currency1, fee: k.fee, tickSpacing: k.tickSpacing, hooks: k.hooks
                }),
                v3: hops[i].v3
            });
        }
    }

    function _expectFault(Hop[] memory hops, PairPadQuotePricer.PathFault fault, uint256 at) internal {
        PairPadQuotePricer.PathReport memory rep = pricer.evaluatePath(address(qt), hops);
        assertEq(uint8(rep.fault), uint8(fault), "fault");
        assertEq(rep.faultHop, at, "faultHop");
        assertFalse(rep.qualifies);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.InvalidPath.selector, fault, at));
        pricer.registerPath(address(qt), hops);
    }

    // ------------------------------------------------------------------
    // Launchpad registries
    // ------------------------------------------------------------------

    function test_registry_ownLaunchpad_noRegistrationNeeded() public {
        FakeLaunchpad pad = new FakeLaunchpad();
        address hook = makeAddr("ourHook");
        pricer.setV4HookAllowed(hook, true);
        pricer.addRegistry(new PairPadReferenceRegistry(pad));

        PoolKey memory key = _key(address(0), address(qt), hook);
        pad.set(address(qt), key);
        // Pool not initialized yet (token still to launch): not priceable.
        assertFalse(pricer.isPriceable(address(qt)));

        v4.setPool(key, 0, DEEP);
        assertTrue(pricer.isPriceable(address(qt)));
        assertEq(pricer.priceEthAmountInQuote(address(qt), 1 ether), 1 ether);
        assertEq(pricer.v4PoolsOf(address(qt)).length, 0);
    }

    function test_registry_pons_buildsKeyFromLaunchTerms() public {
        FakePonsFactory pons = new FakePonsFactory();
        address ponsHook = makeAddr("ponsHook");
        pricer.setV4HookAllowed(ponsHook, true);
        pricer.addRegistry(new PonsReferenceRegistry(pons, IHooks(ponsHook)));

        // A PONS token quoted in native ETH, fee 0, spacing 200.
        pons.set(address(qt), address(0), 0, 200);
        PoolKey memory key = _key(address(0), address(qt), ponsHook);
        v4.setPool(key, 6932, DEEP);
        assertApproxEqRel(pricer.priceEthAmountInQuote(address(qt), 1 ether), 2 ether, 0.001e18);

        // A PONS token quoted in USDG resolves through the USDG leg.
        MockERC20 pt = new MockERC20("Pons Token", "PT", 18);
        pons.set(address(pt), address(usdg), 3000, 60);
        PoolKey memory ptKey = PoolKey({
            currency0: Currency.wrap(address(pt) < address(usdg) ? address(pt) : address(usdg)),
            currency1: Currency.wrap(address(pt) < address(usdg) ? address(usdg) : address(pt)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(ponsHook)
        });
        v4.setPool(ptKey, 0, DEEP);
        assertFalse(pricer.isPriceable(address(pt)));
        _addV3Pool(address(usdg), address(weth), 500, 0, address(weth), 20 ether);
        assertTrue(pricer.isPriceable(address(pt)));
    }

    function test_registry_revertingOrUnknownIsSkipped() public {
        FakeLaunchpad pad = new FakeLaunchpad();
        pricer.addRegistry(new PairPadReferenceRegistry(pad));
        // Nothing launched: poolKeyFor reverts, pricer just says no.
        assertFalse(pricer.isPriceable(address(qt)));
        // A registry that is not a contract cannot be added, and one whose
        // code is gone (selfdestruct in a past life) is skipped.
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.NotAContract.selector, makeAddr("dead")));
        pricer.addRegistry(IQuoteReferenceRegistry(makeAddr("dead")));
        PairPadReferenceRegistry gone = new PairPadReferenceRegistry(pad);
        pricer.addRegistry(gone);
        vm.etch(address(gone), "");
        assertFalse(pricer.isPriceable(address(qt)));
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 5 ether);
        assertTrue(pricer.isPriceable(address(qt)));
    }

    function test_registry_disallowedHookIsIgnored() public {
        FakeLaunchpad pad = new FakeLaunchpad();
        pricer.addRegistry(new PairPadReferenceRegistry(pad));
        address hook = makeAddr("strangeHook");
        PoolKey memory key = _key(address(0), address(qt), hook);
        pad.set(address(qt), key);
        v4.setPool(key, 0, DEEP);
        assertFalse(pricer.isPriceable(address(qt)));
        pricer.setV4HookAllowed(hook, true);
        assertTrue(pricer.isPriceable(address(qt)));
    }

    function test_registry_addRemoveGuards() public {
        FakeLaunchpad pad = new FakeLaunchpad();
        PairPadReferenceRegistry reg = new PairPadReferenceRegistry(pad);
        pricer.addRegistry(reg);
        assertEq(pricer.registriesLength(), 1);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.RegistryAlreadyAdded.selector, address(reg)));
        pricer.addRegistry(reg);
        pricer.removeRegistry(reg);
        assertEq(pricer.registriesLength(), 0);
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.UnknownRegistry.selector, address(reg)));
        pricer.removeRegistry(reg);
        vm.expectRevert(PairPadQuotePricer.ZeroAddress.selector);
        pricer.addRegistry(IQuoteReferenceRegistry(address(0)));

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        pricer.addRegistry(reg);
    }

    function test_ownerCanTuneFloor() public {
        _addV3Pool(address(qt), address(weth), 3000, 0, address(weth), 2 ether);
        assertFalse(pricer.isPriceable(address(qt)));
        pricer.setMinReferenceEth(2 ether);
        assertEq(pricer.minReferenceEth(), 2 ether);
        assertTrue(pricer.isPriceable(address(qt)));

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        pricer.setMinReferenceEth(1 ether);
    }

    /// @dev Tick at which `amountB` raw of tokenB equals `amountA` raw of tokenA, to the nearest tick.
    function _tickFor(address a, address b, uint256 amountB, uint256 amountA) internal pure returns (int24) {
        // price = token1/token0 in raw units. ln(price)/ln(1.0001).
        (uint256 num, uint256 den) = a < b ? (amountB, amountA) : (amountA, amountB);
        // Fixed-point ln via a coarse search; precision to one tick is enough here.
        // Bounded so sqrt^2 below fits in 256 bits.
        int24 lo = -400_000;
        int24 hi = 400_000;
        while (hi - lo > 1) {
            int24 mid = (lo + hi) / 2;
            // 1.0001^mid >= num/den ?
            if (_priceGe(mid, num, den)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _priceGe(int24 tick, uint256 num, uint256 den) private pure returns (bool) {
        uint160 sqrt = TickMathLib.getSqrtPriceAtTick(tick);
        // price * 2^192 = sqrt^2
        uint256 lhs = FullMathLib.mulDiv(uint256(sqrt) * sqrt, den, 1 << 192);
        return lhs >= num;
    }
}
