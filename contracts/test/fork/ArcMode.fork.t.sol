// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../../src/v2/PairPadQuotePricer.sol";
import {PairPadLaunchDeployer} from "../../src/v2/PairPadLaunchDeployer.sol";
import {ISwapRouter02, IWETH9} from "../../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {Hop} from "../../src/v2/libraries/Hop.sol";
import {IPairPadFeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadMultiLaunchLocker} from "../../src/v3/PairPadMultiLaunchLocker.sol";
import {PairPadMultiLaunchFactory} from "../../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiPositionMinter} from "../../src/v3/PairPadMultiPositionMinter.sol";
import {PairPadMultiRouter} from "../../src/v3/PairPadMultiRouter.sol";
import {PairPadMultiReferenceRegistry} from "../../src/v3/PairPadMultiReferenceRegistry.sol";
import {IPairPadMultiLaunchFactory} from "../../src/v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice The stack in its Arc configuration, exercised on a fork of
 * Robinhood Chain: `nativeIsReference = false`, a six-decimal dollar ERC-20
 * as the reference asset, native never paired. USDG stands in for Arc's
 * USDC (same decimals, same role) and WETH plays an ordinary ERC-20 quote
 * priced through its V3 pool against the reference, so the live Uniswap
 * infrastructure carries the whole flow before Arc's own RPC is reachable.
 *
 *   forge test --match-path "test/fork/ArcMode*" --fork-url $RPC_URL
 */
contract ArcModeForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev The reference in this configuration: a six-decimal dollar.
    address constant REF = USDG;
    uint256 constant ONE_REF = 1e6;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    /// @dev Opening market cap, in reference units: 5,000 dollars.
    uint256 constant PHANTOM = 5_000e6;
    uint256 constant MIN_REFERENCE = 2_500e6;
    uint256 constant LAUNCH_FEE = 0.001 ether;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    PairPadFeeEscrow feeEscrow;
    PairPadQuotePricer pricer;
    PairPadMultiLaunchLocker locker;
    PairPadMultiLaunchFactory factory;
    PairPadMultiRouter router;

    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address protocolFees = makeAddr("protocolFees");

    receive() external payable {}

    function setUp() public {
        if (block.chainid != 4663) return;

        feeEscrow = new PairPadFeeEscrow();
        // WETH is the second anchor here purely to satisfy the constructor;
        // nothing routes through it as an anchor in these tests.
        pricer = new PairPadQuotePricer(
            address(this), IUniswapV3FactoryMinimal(_v3Factory()), REF, WETH, manager, false
        );
        pricer.setMinReferenceEth(MIN_REFERENCE);

        locker = new PairPadMultiLaunchLocker(
            address(this), IPositionManager(POSITION_MANAGER), IPairPadFeeEscrow(address(feeEscrow))
        );
        factory = new PairPadMultiLaunchFactory(
            address(this),
            manager,
            IPositionManager(POSITION_MANAGER),
            locker,
            IPairPadFeeEscrow(address(feeEscrow)),
            pricer,
            REF,
            false,
            protocolFees,
            LAUNCH_FEE
        );
        PairPadMultiPositionMinter minter = new PairPadMultiPositionMinter(
            IPositionManager(POSITION_MANAGER), IAllowanceTransfer(PERMIT2), address(locker), address(factory)
        );
        PairPadLaunchDeployer launchDeployer = new PairPadLaunchDeployer(address(factory));
        router = new PairPadMultiRouter(manager, factory, ISwapRouter02(SWAP_ROUTER_02), IWETH9(REF));
        pricer.addRegistry(new PairPadMultiReferenceRegistry(IPairPadMultiLaunchFactory(address(factory))));

        locker.setFactory(address(factory));
        factory.setPositionMinter(minter);
        factory.setLaunchDeployer(launchDeployer);
        factory.setLaunchForwarder(address(router));
        factory.addLaunchConfig(
            PairPadMultiLaunchFactory.LaunchConfig({
                supply: SUPPLY, phantomQuote: PHANTOM, tickSpacing: 10, enabled: true
            })
        );
        factory.setLaunchEnabled(true);

        vm.deal(creator, 1 ether);
        vm.deal(buyer, 1 ether);
        deal(REF, creator, 10_000e6);
        deal(REF, buyer, 10_000e6);
    }

    /// @dev The live pricer's V3 factory, so this test does not hardcode it.
    function _v3Factory() internal view returns (address) {
        return address(PairPadQuotePricer(0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563).v3Factory());
    }

    modifier onlyFork() {
        if (block.chainid != 4663) vm.skip(true);
        _;
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    function _params(bytes32 salt) internal pure returns (PairPadMultiLaunchFactory.TokenParams memory) {
        return PairPadMultiLaunchFactory.TokenParams({
            name: "Arc Meme",
            symbol: "ARCM",
            logo: "",
            description: "arc mode e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    /// @dev The reference market bare, plus WETH priced through its V3 pool.
    function _two() internal pure returns (address[] memory q) {
        q = new address[](2);
        q[0] = REF;
        q[1] = WETH;
    }

    function _launch2(bytes32 salt) internal returns (address token) {
        vm.startPrank(creator);
        token = factory.launchToken{value: LAUNCH_FEE}(_params(salt), 0, _two());
        vm.stopPrank();
    }

    function _v3Leg(address a, address b, uint24 fee) internal pure returns (Hop[] memory leg) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        leg = new Hop[](1);
        leg[0] = Hop({
            key: PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: fee,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            v3: true
        });
    }

    function _legs(uint256 total) internal pure returns (PairPadMultiRouter.Leg[] memory legs) {
        legs = new PairPadMultiRouter.Leg[](2);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: total / 2});
        legs[1] = PairPadMultiRouter.Leg({market: 1, hops: _v3Leg(REF, WETH, 500), amountIn: total - total / 2});
    }

    function _tokensPerQuoteX96(PoolKey memory key, address token) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        bool tokenIs1 = Currency.unwrap(key.currency1) == token;
        return tokenIs1 ? priceX96 : FullMath.mulDiv(1 << 96, 1 << 96, priceX96);
    }

    // -------------------------------------------------------------------
    // Pricer in reference mode
    // -------------------------------------------------------------------

    function test_fork_pricer_referenceIsTheDollarErc20() public onlyFork {
        assertFalse(pricer.nativeIsReference());
        assertTrue(pricer.isPriceable(REF), "the reference prices itself");
        assertEq(pricer.priceEthAmountInQuote(REF, 123e6), 123e6, "identity in reference units");
        (Hop[] memory hops, bool ok) = pricer.route(REF);
        assertTrue(ok);
        assertEq(hops.length, 0);

        // WETH is an ordinary ERC-20 quote here: priced through WETH/USDG V3.
        assertTrue(pricer.isPriceable(WETH), "WETH priced against the dollar");
        uint256 wethPer4500 = pricer.priceEthAmountInQuote(WETH, 4_500e6);
        // Whatever ether costs, 4,500 dollars is somewhere between a fifth
        // of an ether and five of them.
        assertGt(wethPer4500, 0.2 ether);
        assertLt(wethPer4500, 5 ether);

        // Native is not the reference: the pricer knows no route for it.
        assertFalse(pricer.isPriceable(address(0)), "address zero is not an asset here");
    }

    // -------------------------------------------------------------------
    // Launch
    // -------------------------------------------------------------------

    function test_fork_launch_referenceMarketAndErc20Market() public onlyFork {
        address token = _launch2("two");
        IPairPadMultiLaunchFactory.Market[] memory ms = factory.getMarkets(token);
        PoolKey[] memory keys = factory.poolKeysFor(token);
        assertEq(ms.length, 2);
        assertEq(ms[0].pairToken, REF);
        assertEq(ms[1].pairToken, WETH);
        // The reference market takes its half of the phantom reserve as is,
        // in six decimals; the WETH market the pricer's conversion of it.
        assertEq(ms[0].phantomQuote, PHANTOM / 2);
        assertEq(ms[1].phantomQuote, pricer.priceEthAmountInQuote(WETH, PHANTOM) / 2);
        assertEq(protocolFees.balance, LAUNCH_FEE, "launch fee paid in native");

        // Same dollar price on both markets: tokens per dollar directly, and
        // tokens per WETH times WETH per dollar.
        uint256 perRefDirect = _tokensPerQuoteX96(keys[0], token);
        uint256 wethPerRef = pricer.priceEthAmountInQuote(WETH, ONE_REF);
        uint256 perRefViaWeth = FullMath.mulDiv(_tokensPerQuoteX96(keys[1], token), wethPerRef, ONE_REF);
        assertApproxEqRel(perRefViaWeth, perRefDirect, 0.01e18, "one price, two quotes");

        // Whole supply in the pools apart from dust.
        uint256 inPool = IERC20(token).balanceOf(POOL_MANAGER);
        uint256 dust = IERC20(token).balanceOf(address(locker));
        assertEq(inPool + dust, SUPPLY);
        assertLt(dust, 1e12);
    }

    function test_fork_launch_nativeIsRefused_referenceErc20IsNot() public onlyFork {
        address[] memory native = new address[](1);
        native[0] = address(0);
        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.NativeNotAllowed.selector);
        factory.launchToken{value: LAUNCH_FEE}(_params("native"), 0, native);

        address[] memory ref = new address[](1);
        ref[0] = REF;
        vm.prank(creator);
        address token = factory.launchToken{value: LAUNCH_FEE}(_params("ref-only"), 0, ref);
        assertEq(factory.getMarkets(token)[0].phantomQuote, PHANTOM);
    }

    // -------------------------------------------------------------------
    // Trading in the reference ERC-20
    // -------------------------------------------------------------------

    function test_fork_buyWithReference_thenSellToReference_roundTrip() public onlyFork {
        address token = _launch2("trade");
        uint256 spend = 300e6;

        vm.startPrank(buyer);
        IERC20(REF).approve(address(router), spend);
        uint256 tokensOut = router.buyWithReference(token, _legs(spend), spend, 0, buyer);
        vm.stopPrank();
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(buyer), tokensOut);
        assertEq(IERC20(REF).balanceOf(buyer), 10_000e6 - spend, "paid exactly the legs' sum");
        // 150 dollars per market against a 2,500 dollar phantom each.
        uint256 perMarket = (SUPPLY / 2) * 148.5e6 / (PHANTOM / 2 + 148.5e6);
        assertApproxEqRel(tokensOut, 2 * perMarket, 0.05e18, "two curves, each a half");
        assertEq(IERC20(WETH).balanceOf(buyer), 0, "buyer never touched WETH");
        assertEq(IERC20(REF).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        (uint256[] memory f0, uint256[] memory f1) = locker.pendingFeesAll(token);
        for (uint256 i = 0; i < 2; i++) {
            assertTrue(f0[i] > 0 || f1[i] > 0, "every market earned a fee");
        }

        uint256 refBefore = IERC20(REF).balanceOf(buyer);
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        uint256 refOut = router.sellToReference(token, _legs(tokensOut), 0, buyer);
        vm.stopPrank();
        assertEq(IERC20(REF).balanceOf(buyer), refBefore + refOut);
        assertEq(IERC20(token).balanceOf(buyer), 0);
        // Two 1% fees on the launch pools plus the WETH leg's fee and impact.
        assertGt(refOut, 250e6, "most of it comes back");
        assertLt(refOut, spend);
        assertEq(IERC20(REF).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    function test_fork_buyWithReference_legsMustSumToAmount_andFloorOnTotal() public onlyFork {
        address token = _launch2("floor");
        PairPadMultiRouter.Leg[] memory legs = _legs(300e6);
        vm.startPrank(buyer);
        IERC20(REF).approve(address(router), 300e6);
        vm.expectRevert(PairPadMultiRouter.NativeValueMismatch.selector);
        router.buyWithReference(token, legs, 200e6, 0, buyer);
        vm.expectRevert();
        router.buyWithReference(token, legs, 300e6, type(uint256).max, buyer);
        vm.stopPrank();
    }

    function test_fork_nativePaths_haveNoRouteHere() public onlyFork {
        address token = _launch2("no-native");
        // Native cannot enter a reference pool: the first hop does not carry it.
        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](1);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: 0.1 ether});
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PairPadMultiRouter.RouteBroken.selector, 0));
        router.buyWithEth{value: 0.1 ether}(token, legs, 0, buyer);
    }

    function test_fork_buyWithQuote_referenceMarket() public onlyFork {
        address token = _launch2("quote");
        vm.startPrank(buyer);
        IERC20(REF).approve(address(router), 100e6);
        uint256 out = router.buyWithQuote(token, 0, 100e6, 0, buyer);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(buyer), out);
    }

    function test_fork_launchAndBuyWithReference_atomic() public onlyFork {
        uint256 spend = 200e6;
        vm.startPrank(creator);
        IERC20(REF).approve(address(router), spend);
        (address token, uint256 tokensOut) = router.launchAndBuyWithReference{value: LAUNCH_FEE}(
            _params("zap"), 0, _two(), _legs(spend), spend, 0
        );
        vm.stopPrank();
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
        assertEq(factory.getLaunchedToken(token).deployer, creator);
        assertEq(IERC20(REF).balanceOf(creator), 10_000e6 - spend);
        assertEq(address(router).balance, 0);

        // The fee must be exact.
        vm.prank(creator);
        vm.expectRevert(PairPadMultiRouter.InsufficientLaunchValue.selector);
        router.launchAndBuyWithReference{value: LAUNCH_FEE + 1}(
            _params("zap-2"), 0, _two(), new PairPadMultiRouter.Leg[](0), 0, 0
        );

        // Launch only.
        vm.prank(creator);
        (address token2, uint256 none) = router.launchAndBuyWithReference{value: LAUNCH_FEE}(
            _params("zap-none"), 0, _two(), new PairPadMultiRouter.Leg[](0), 0, 0
        );
        assertEq(none, 0);
        assertTrue(factory.getLaunchedToken(token2).exists);
    }

    // -------------------------------------------------------------------
    // Fees in the reference ERC-20
    // -------------------------------------------------------------------

    function test_fork_collectFees_referenceIsAnErc20Everywhere() public onlyFork {
        address token = _launch2("collect");
        vm.startPrank(buyer);
        IERC20(REF).approve(address(router), 300e6);
        uint256 tokensOut = router.buyWithReference(token, _legs(300e6), 300e6, 0, buyer);
        IERC20(token).approve(address(router), tokensOut);
        router.sellToReference(token, _legs(tokensOut), 0, buyer);
        vm.stopPrank();

        uint256 protocolRefBefore = IERC20(REF).balanceOf(protocolFees);
        uint256 protocolNativeBefore = protocolFees.balance;
        uint256 supplyBefore = IERC20(token).totalSupply();

        locker.collectFees(token);

        // The reference market's buy fee: 1% of 150 dollars, half to the protocol.
        assertApproxEqAbs(IERC20(REF).balanceOf(protocolFees) - protocolRefBefore, 0.75e6, 1e4, "protocol share");
        assertEq(protocolFees.balance, protocolNativeBefore, "no native moves for fees");
        assertApproxEqAbs(feeEscrow.balanceOfToken(creator, REF), 0.75e6, 1e4, "creator share escrowed");
        assertGt(feeEscrow.balanceOfToken(creator, WETH), 0);
        assertEq(feeEscrow.balanceOf(creator), 0, "nothing in the native ledger");
        uint256 burned = supplyBefore - IERC20(token).totalSupply();
        assertApproxEqRel(burned, tokensOut / 200, 0.001e18, "half of the 1% sell fee burned");
        assertEq(IERC20(REF).balanceOf(address(locker)), 0);

        vm.startPrank(creator);
        feeEscrow.claimToken(REF);
        feeEscrow.claimToken(WETH);
        vm.stopPrank();
        assertApproxEqAbs(IERC20(REF).balanceOf(creator), 10_000e6 + 0.75e6, 1e4);
    }
}
