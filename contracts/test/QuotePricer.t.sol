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

        (PairPadQuotePricer.Reference memory direct,,) = pricer.describe(address(qt));
        assertEq(uint8(direct.kind), uint8(PairPadQuotePricer.ReferenceKind.V3));
        assertEq(direct.anchorDepth, 4.99 ether);
        assertEq(direct.anchorFloor, 5 ether);
        assertFalse(direct.qualifies);

        weth.mint(direct.v3Pool, 0.01 ether);
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

        (PairPadQuotePricer.Reference memory direct,,) = pricer.describe(address(qt));
        assertEq(uint8(direct.kind), uint8(PairPadQuotePricer.ReferenceKind.V4));
        assertEq(direct.anchor, address(0));
        assertEq(direct.anchorDepth, 1e21);
        assertTrue(direct.qualifies);
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
        (, PairPadQuotePricer.Reference memory usdgLeg, PairPadQuotePricer.Reference memory viaUsdg) =
            pricer.describe(address(qt));
        assertTrue(usdgLeg.qualifies);
        assertApproxEqAbs(viaUsdg.anchorFloor, 10_000e6, 2e6);
        assertFalse(viaUsdg.qualifies);

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
        (, PairPadQuotePricer.Reference memory usdgLeg, PairPadQuotePricer.Reference memory viaUsdg) =
            pricer.describe(address(qt));
        assertEq(uint8(usdgLeg.kind), uint8(PairPadQuotePricer.ReferenceKind.None));
        assertFalse(viaUsdg.qualifies);
    }

    function test_noPath_reverts() public {
        assertFalse(pricer.isPriceable(address(qt)));
        vm.expectRevert(abi.encodeWithSelector(PairPadQuotePricer.QuoteAssetNotPriceable.selector, address(qt)));
        pricer.priceEthAmountInQuote(address(qt), 1 ether);
        (PairPadQuotePricer.Reference memory direct,,) = pricer.describe(address(qt));
        assertEq(uint8(direct.kind), uint8(PairPadQuotePricer.ReferenceKind.None));
        assertEq(direct.anchorFloor, 5 ether);
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
