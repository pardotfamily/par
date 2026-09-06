// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer} from "../../src/v2/PairPadQuotePricer.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {LaunchDeployment, PairPadLaunchDeployer} from "../../src/v2/PairPadLaunchDeployer.sol";
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
 * @notice Multi-market launches against a fork of Robinhood Chain mainnet
 * (4663): the live PoolManager, PositionManager, Permit2, V3 pools, and the
 * live v2 fee escrow and quote pricer, with a fresh v3 stack on top. Run with:
 *
 *   forge test --match-path "test/fork/Multi*" --fork-url $RPC_URL
 */
contract MultiLifecycleForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev Live v2 stack.
    address constant FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;
    address constant QUOTE_PRICER = 0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563;
    address constant V2_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;
    /// @dev $par, the platform token: a v2 launch quoted in ETH.
    address constant PAR = 0x507B6F349a80114097A67B8b4677367acC15b220;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant PHANTOM = 1.3557 ether;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    PairPadFeeEscrow feeEscrow = PairPadFeeEscrow(FEE_ESCROW);
    PairPadQuotePricer quotePricer = PairPadQuotePricer(QUOTE_PRICER);
    PairPadMultiLaunchLocker locker;
    PairPadMultiLaunchFactory factory;
    PairPadMultiPositionMinter minter;
    PairPadLaunchDeployer launchDeployer;
    PairPadMultiRouter router;
    PairPadMultiReferenceRegistry registry;
    PoolKey parKey;

    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");
    address protocolFees = makeAddr("protocolFees");

    receive() external payable {}

    function setUp() public {
        if (block.chainid != 4663) return;
        parKey = PairPadLaunchFactory(V2_FACTORY).poolKeyFor(PAR);

        locker = new PairPadMultiLaunchLocker(
            address(this), IPositionManager(POSITION_MANAGER), IPairPadFeeEscrow(FEE_ESCROW)
        );
        factory = new PairPadMultiLaunchFactory(
            address(this),
            manager,
            IPositionManager(POSITION_MANAGER),
            locker,
            IPairPadFeeEscrow(FEE_ESCROW),
            quotePricer,
            WETH,
            protocolFees,
            0
        );
        minter = new PairPadMultiPositionMinter(
            IPositionManager(POSITION_MANAGER), IAllowanceTransfer(PERMIT2), address(locker), address(factory)
        );
        launchDeployer = new PairPadLaunchDeployer(address(factory));
        router = new PairPadMultiRouter(manager, factory, ISwapRouter02(SWAP_ROUTER_02), IWETH9(WETH));
        registry = new PairPadMultiReferenceRegistry(IPairPadMultiLaunchFactory(address(factory)));

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

        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);
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
            name: "Multi Meme",
            symbol: "MULTI",
            logo: "",
            description: "multi e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _three() internal pure returns (address[] memory q) {
        q = new address[](3);
        q[0] = address(0);
        q[1] = USDG;
        q[2] = PAR;
    }

    function _launch3(bytes32 salt) internal returns (address token) {
        vm.prank(creator);
        token = factory.launchToken(_params(salt), 0, _three());
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

    /// @dev From storage, not a call: helpers used inline after `vm.prank`
    /// must not make an external call of their own.
    function _parLeg() internal view returns (Hop[] memory leg) {
        leg = new Hop[](1);
        leg[0] = Hop({key: parKey, v3: false});
    }

    /// @dev Equal thirds: ETH market bare, USDG through V3, $par through its V4 pool.
    function _buyLegs(uint256 total) internal view returns (PairPadMultiRouter.Leg[] memory legs) {
        legs = new PairPadMultiRouter.Leg[](3);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: total / 3});
        legs[1] = PairPadMultiRouter.Leg({market: 1, hops: _v3Leg(WETH, USDG, 500), amountIn: total / 3});
        legs[2] = PairPadMultiRouter.Leg({market: 2, hops: _parLeg(), amountIn: total - 2 * (total / 3)});
    }

    function _sellLegs(uint256 tokens) internal view returns (PairPadMultiRouter.Leg[] memory legs) {
        legs = new PairPadMultiRouter.Leg[](3);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: tokens / 3});
        legs[1] = PairPadMultiRouter.Leg({market: 1, hops: _v3Leg(WETH, USDG, 500), amountIn: tokens / 3});
        legs[2] = PairPadMultiRouter.Leg({market: 2, hops: _parLeg(), amountIn: tokens - 2 * (tokens / 3)});
    }

    /// @dev Tokens per one unit of quote at the pool's current price, scaled
    /// by 1e18 for ETH-sized quotes; used only to compare markets relatively.
    function _tokensPerQuoteX96(PoolKey memory key, address token) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96); // currency1 per currency0
        bool tokenIs1 = Currency.unwrap(key.currency1) == token;
        // tokens per quote: token is currency1 -> priceX96; token is currency0 -> 1/price
        return tokenIs1 ? priceX96 : FullMath.mulDiv(1 << 96, 1 << 96, priceX96);
    }

    // -------------------------------------------------------------------
    // Launch
    // -------------------------------------------------------------------

    function test_fork_launch_threeMarketsSplitEvenlyAtOneEthPrice() public onlyFork {
        address token = _launch3("three");
        IPairPadMultiLaunchFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        assertTrue(l.exists);
        assertEq(l.marketCount, 3);
        assertEq(l.deployer, creator);
        assertEq(l.creatorFeeRecipient, creator);
        assertEq(l.poolFee, 10_000);
        assertEq(l.protocolFeeRecipient, protocolFees);

        IPairPadMultiLaunchFactory.Market[] memory ms = factory.getMarkets(token);
        PoolKey[] memory keys = factory.poolKeysFor(token);
        assertEq(ms.length, 3);
        assertEq(keys.length, 3);
        assertEq(ms[0].pairToken, address(0));
        assertEq(ms[1].pairToken, USDG);
        assertEq(ms[2].pairToken, PAR);
        // ETH market: a third of the phantom reserve.
        assertEq(ms[0].phantomQuote, PHANTOM / 3);
        // ERC-20 markets: a third of the pricer's conversion.
        assertEq(ms[1].phantomQuote, quotePricer.quoteEconomics(USDG, PHANTOM) / 3);
        assertEq(ms[2].phantomQuote, quotePricer.quoteEconomics(PAR, PHANTOM) / 3);

        // Every position is the locker's; the locker cannot move any of them.
        uint256[] memory ids = locker.lockedPositions(token);
        assertEq(ids.length, 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(ids[i], ms[i].positionId);
            assertEq(IERC721(POSITION_MANAGER).ownerOf(ids[i]), address(locker));
            assertEq(address(keys[i].hooks), address(0));
            assertEq(keys[i].fee, 10_000);
            (uint128 liq,,) = manager.getPositionInfo(
                keys[i].toId(), POSITION_MANAGER, ms[i].tickLower, ms[i].tickUpper, bytes32(ms[i].positionId)
            );
            assertEq(liq, ms[i].liquidity);
        }
        assertTrue(locker.isLocked(token));

        // Whole supply in the PoolManager apart from dust locked away.
        uint256 inPool = IERC20(token).balanceOf(POOL_MANAGER);
        uint256 dust = IERC20(token).balanceOf(address(locker));
        assertEq(inPool + dust, SUPPLY);
        assertLt(dust, 1e12);
        assertEq(IERC20(token).balanceOf(address(minter)), 0);
        assertEq(IERC20(token).balanceOf(creator), 0);

        // Same ETH price on every market: tokens per ETH directly, tokens
        // per USDG times USDG per ETH, tokens per $par times $par per ETH.
        uint256 perEthDirect = _tokensPerQuoteX96(keys[0], token);
        uint256 usdgPerEth = quotePricer.priceEthAmountInQuote(USDG, 1 ether);
        uint256 perEthViaUsdg = FullMath.mulDiv(_tokensPerQuoteX96(keys[1], token), usdgPerEth, 1 ether);
        uint256 parPerEth = quotePricer.priceEthAmountInQuote(PAR, 1 ether);
        uint256 perEthViaPar = FullMath.mulDiv(_tokensPerQuoteX96(keys[2], token), parPerEth, 1 ether);
        // Each opening tick is rounded to a spacing of 10 (0.1%), so the
        // three agree to within a couple of tenths of a percent.
        assertApproxEqRel(perEthViaUsdg, perEthDirect, 0.003e18, "USDG market opens at the ETH market's price");
        assertApproxEqRel(perEthViaPar, perEthDirect, 0.003e18, "$par market opens at the ETH market's price");
        // And that price is the config's: 1B tokens per 1.3557 ETH.
        assertApproxEqRel(perEthDirect >> 96, SUPPLY / PHANTOM, 0.002e18);

        // The registry points the pricer at the ETH market.
        (bool found, PoolKey memory ref) = registry.referencePool(token);
        assertTrue(found);
        assertEq(PoolId.unwrap(ref.toId()), PoolId.unwrap(keys[0].toId()));
    }

    function test_fork_launch_validation() public onlyFork {
        address[] memory q = new address[](2);
        q[0] = address(0);
        q[1] = address(0);
        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.DuplicatePairToken.selector);
        factory.launchToken(_params("dup"), 0, q);

        q[1] = WETH;
        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.WethNotAllowed.selector);
        factory.launchToken(_params("weth"), 0, q);

        // One past MAX_MARKETS (the WETH slot never gets checked: count first).
        address[] memory six = new address[](6);
        six[0] = address(0);
        six[1] = USDG;
        six[2] = PAR;
        six[3] = address(0x1111);
        six[4] = address(0x2222);
        six[5] = WETH;
        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.InvalidMarketCount.selector);
        factory.launchToken(_params("six"), 0, six);

        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.InvalidMarketCount.selector);
        factory.launchToken(_params("none"), 0, new address[](0));

        // A single market is allowed (it is just a v2-shaped launch here).
        address[] memory one = new address[](1);
        one[0] = USDG;
        vm.prank(creator);
        address token = factory.launchToken(_params("one"), 0, one);
        assertEq(factory.getLaunchedToken(token).marketCount, 1);
        assertEq(factory.getMarkets(token)[0].phantomQuote, quotePricer.quoteEconomics(USDG, PHANTOM));
    }

    function test_fork_launch_economicsGuard() public onlyFork {
        PairPadMultiLaunchFactory.TokenParams memory p = _params("econ");
        p.expectedEconomics = factory.previewLaunchEconomics(0, _three());
        vm.prank(creator);
        address token = factory.launchToken(p, 0, _three());
        assertTrue(factory.getLaunchedToken(token).exists);

        p.salt = "econ-2";
        p.expectedEconomics = bytes32(uint256(1));
        vm.prank(creator);
        vm.expectRevert();
        factory.launchToken(p, 0, _three());

        uint256[] memory phantoms = factory.previewQuoteEconomics(0, _three());
        assertEq(phantoms[0], PHANTOM / 3);
    }

    function test_fork_launch_refusesAPoolSomeoneOpenedFirst() public onlyFork {
        PairPadMultiLaunchFactory.TokenParams memory p = _params("squat");
        address predicted = launchDeployer.predictTokenAddress(
            LaunchDeployment({
                originalDeployer: creator,
                supplyRecipient: address(minter),
                supply: SUPPLY,
                salt: p.salt,
                name: p.name,
                symbol: p.symbol,
                logo: p.logo,
                description: p.description,
                socials: p.socials
            })
        );
        // Squat the USDG market only.
        (address c0, address c1) = USDG < predicted ? (USDG, predicted) : (predicted, USDG);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        vm.prank(creator);
        vm.expectRevert(PairPadMultiLaunchFactory.PoolAlreadyExists.selector);
        factory.launchToken(p, 0, _three());
    }

    // -------------------------------------------------------------------
    // Trading through the router
    // -------------------------------------------------------------------

    function test_fork_buyAndSell_acrossThreeMarkets_roundTripInEth() public onlyFork {
        address token = _launch3("trade");

        vm.prank(buyer);
        uint256 tokensOut = router.buyWithEth{value: 0.3 ether}(token, _buyLegs(0.3 ether), 0, buyer);
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(buyer), tokensOut);
        // A tenth of an ETH per market against a 0.45 ETH phantom each:
        // roughly 0.1 / 0.55 of a third of the supply, thrice.
        uint256 perMarket = (SUPPLY / 3) * 0.099 ether / (PHANTOM / 3 + 0.099 ether);
        assertApproxEqRel(tokensOut, 3 * perMarket, 0.05e18, "three curves, each a third");
        assertEq(IERC20(USDG).balanceOf(buyer), 0, "buyer never touched USDG");
        assertEq(IERC20(PAR).balanceOf(buyer), 0, "buyer never touched $par");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(PAR).balanceOf(address(router)), 0);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0, "router keeps nothing");

        // Fees sit in each position, in the quote each market took.
        (uint256[] memory f0, uint256[] memory f1) = locker.pendingFeesAll(token);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(f0[i] > 0 || f1[i] > 0, "every market earned a fee");
        }

        // Sell everything back for ETH through all three.
        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        uint256 ethOut = router.sellToEth(token, _sellLegs(tokensOut), 0, buyer);
        vm.stopPrank();
        assertEq(buyer.balance, ethBefore + ethOut);
        assertEq(IERC20(token).balanceOf(buyer), 0);
        // Two 1% launch-pool fees plus the USDG and $par legs' fees and impact.
        assertGt(ethOut, 0.25 ether, "most of it comes back");
        assertLt(ethOut, 0.3 ether);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(PAR).balanceOf(address(router)), 0);
    }

    function test_fork_buy_floorIsOnTheTotal() public onlyFork {
        address token = _launch3("floor");
        PairPadMultiRouter.Leg[] memory legs = _buyLegs(0.3 ether);
        vm.prank(buyer);
        vm.expectRevert();
        router.buyWithEth{value: 0.3 ether}(token, legs, type(uint256).max, buyer);

        // Legs must add up to the value sent.
        vm.prank(buyer);
        vm.expectRevert(PairPadMultiRouter.NativeValueMismatch.selector);
        router.buyWithEth{value: 0.2 ether}(token, legs, 0, buyer);
    }

    function test_fork_sellToQuotes_deliversEachQuote() public onlyFork {
        address token = _launch3("quotes");
        vm.prank(buyer);
        uint256 tokensOut = router.buyWithEth{value: 0.3 ether}(token, _buyLegs(0.3 ether), 0, buyer);

        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](3);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: tokensOut / 3});
        legs[1] = PairPadMultiRouter.Leg({market: 1, hops: new Hop[](0), amountIn: tokensOut / 3});
        legs[2] = PairPadMultiRouter.Leg({market: 2, hops: new Hop[](0), amountIn: tokensOut - 2 * (tokensOut / 3)});
        uint256[] memory mins = new uint256[](3);

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        router.sellToQuotes(token, legs, mins, buyer);
        vm.stopPrank();
        assertGt(buyer.balance, ethBefore, "ETH from the ETH market");
        assertGt(IERC20(USDG).balanceOf(buyer), 0, "USDG from the USDG market");
        assertGt(IERC20(PAR).balanceOf(buyer), 0, "$par from the $par market");
        assertEq(IERC20(token).balanceOf(buyer), 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(PAR).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        // A leg with hops is refused here.
        legs[1].hops = _v3Leg(WETH, USDG, 500);
        vm.prank(buyer);
        vm.expectRevert(PairPadMultiRouter.LegMustEndAtQuote.selector);
        router.sellToQuotes(token, legs, mins, buyer);
    }

    function test_fork_buyWithQuote_singleMarket() public onlyFork {
        address token = _launch3("single");
        // ETH market directly.
        vm.prank(buyer);
        uint256 out0 = router.buyWithQuote{value: 0.1 ether}(token, 0, 0.1 ether, 0, buyer);
        assertGt(out0, 0);
        // $par market, paying $par the buyer already holds.
        deal(PAR, buyer, 1_000_000 ether);
        vm.startPrank(buyer);
        IERC20(PAR).approve(address(router), 1_000_000 ether);
        uint256 out2 = router.buyWithQuote(token, 2, 1_000_000 ether, 0, buyer);
        vm.stopPrank();
        assertGt(out2, 0);
        assertEq(IERC20(token).balanceOf(buyer), out0 + out2);
        assertEq(IERC20(PAR).balanceOf(address(router)), 0);
    }

    function test_fork_launchAndBuyWithEth_atomicOpeningBuyAcrossMarkets() public onlyFork {
        vm.prank(creator);
        (address token, uint256 tokensOut) =
            router.launchAndBuyWithEth{value: 0.3 ether}(_params("zap"), 0, _three(), _buyLegs(0.3 ether), 0);
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
        assertEq(factory.getLaunchedToken(token).deployer, creator);
        assertEq(factory.getLaunchedToken(token).marketCount, 3);
        assertEq(address(router).balance, 0);

        // Launch only, no buy.
        vm.prank(creator);
        (address token2, uint256 none) =
            router.launchAndBuyWithEth{value: 0}(_params("zap-none"), 0, _three(), new PairPadMultiRouter.Leg[](0), 0);
        assertEq(none, 0);
        assertTrue(factory.getLaunchedToken(token2).exists);
    }

    // -------------------------------------------------------------------
    // Fee collection and split
    // -------------------------------------------------------------------

    function test_fork_collectFees_everyMarket_splitBurnAndEscrow() public onlyFork {
        address token = _launch3("collect");
        vm.prank(buyer);
        uint256 tokensOut = router.buyWithEth{value: 0.3 ether}(token, _buyLegs(0.3 ether), 0, buyer);
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        router.sellToEth(token, _sellLegs(tokensOut), 0, buyer);
        vm.stopPrank();

        uint256 protocolEthBefore = protocolFees.balance;
        uint256 protocolUsdgBefore = IERC20(USDG).balanceOf(protocolFees);
        uint256 protocolParBefore = IERC20(PAR).balanceOf(protocolFees);
        uint256 creatorEthBefore = feeEscrow.balanceOf(creator);
        uint256 creatorUsdgBefore = feeEscrow.balanceOfToken(creator, USDG);
        uint256 creatorParBefore = feeEscrow.balanceOfToken(creator, PAR);
        uint256 creatorTokenBefore = feeEscrow.balanceOfToken(creator, token);
        uint256 supplyBefore = IERC20(token).totalSupply();

        vm.prank(other);
        uint256[] memory got = locker.collectFees(token);
        assertEq(got.length, 6);

        // Protocol paid on the spot in each quote, half of the 1% base fee.
        // The buy leg on the ETH market was 0.1 ETH: 0.001 ETH fee, 0.0005 to the protocol.
        assertApproxEqAbs(protocolFees.balance - protocolEthBefore, 0.0005 ether, 1e9, "protocol ETH share");
        assertGt(IERC20(USDG).balanceOf(protocolFees) - protocolUsdgBefore, 0, "protocol USDG share");
        assertGt(IERC20(PAR).balanceOf(protocolFees) - protocolParBefore, 0, "protocol $par share");
        // Creator credited in the shared escrow, every currency.
        assertApproxEqAbs(feeEscrow.balanceOf(creator) - creatorEthBefore, 0.0005 ether, 1e9, "creator ETH share");
        assertGt(feeEscrow.balanceOfToken(creator, USDG) - creatorUsdgBefore, 0);
        assertGt(feeEscrow.balanceOfToken(creator, PAR) - creatorParBefore, 0);
        // Sell fees were paid in the token: protocol's half burned, creator's half escrowed.
        uint256 burned = supplyBefore - IERC20(token).totalSupply();
        assertApproxEqRel(burned, tokensOut / 200, 0.001e18, "half of the 1% sell fee burned");
        assertApproxEqRel(feeEscrow.balanceOfToken(creator, token) - creatorTokenBefore, tokensOut / 200, 0.001e18);
        assertEq(IERC20(token).balanceOf(protocolFees), 0, "protocol never holds the launch token");
        assertEq(address(locker).balance, 0, "locker keeps no ETH");
        assertEq(IERC20(USDG).balanceOf(address(locker)), 0);
        assertEq(IERC20(PAR).balanceOf(address(locker)), 0);

        // Nothing left to collect; a second call is a no-op.
        (uint256[] memory f0, uint256[] memory f1) = locker.pendingFeesAll(token);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(f0[i], 0);
            assertEq(f1[i], 0);
        }
        uint256[] memory again = locker.collectFees(token);
        for (uint256 i = 0; i < 6; i++) assertEq(again[i], 0);

        // Claims pay out.
        vm.startPrank(creator);
        feeEscrow.claim();
        feeEscrow.claimToken(USDG);
        feeEscrow.claimToken(PAR);
        feeEscrow.claimToken(token);
        vm.stopPrank();
        assertGt(IERC20(USDG).balanceOf(creator), 0);
        assertGt(IERC20(PAR).balanceOf(creator), 0);
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    function test_fork_collectMarketFees_oneMarketOnly() public onlyFork {
        address token = _launch3("one-market");
        vm.prank(buyer);
        router.buyWithEth{value: 0.3 ether}(token, _buyLegs(0.3 ether), 0, buyer);

        (uint256 a0, uint256 a1) = locker.collectMarketFees(token, 1);
        assertTrue(a0 > 0 || a1 > 0);
        (uint256 p0, uint256 p1) = locker.pendingFees(token, 1);
        assertEq(p0 + p1, 0);
        (uint256 q0, uint256 q1) = locker.pendingFees(token, 0);
        assertGt(q0 + q1, 0, "other markets untouched");

        vm.expectRevert(PairPadMultiLaunchLocker.TokenNotLaunched.selector);
        locker.collectFees(other);
    }

    // -------------------------------------------------------------------
    // Markets diverge and can be brought back: the arbitrage story
    // -------------------------------------------------------------------

    function test_fork_oneMarketBought_othersUnmoved_arbCloses() public onlyFork {
        address token = _launch3("arb");
        PoolKey[] memory keys = factory.poolKeysFor(token);
        uint256 usdgPerEth = quotePricer.priceEthAmountInQuote(USDG, 1 ether);

        uint256 ethBefore = _tokensPerQuoteX96(keys[0], token);
        uint256 usdgBefore = _tokensPerQuoteX96(keys[1], token);

        // Buy only through the ETH market.
        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](1);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: 0.2 ether});
        vm.prank(buyer);
        uint256 got = router.buyWithEth{value: 0.2 ether}(token, legs, 0, buyer);

        assertLt(_tokensPerQuoteX96(keys[0], token), ethBefore, "ETH market: fewer tokens per ETH now");
        assertEq(_tokensPerQuoteX96(keys[1], token), usdgBefore, "USDG market did not move");

        // An arbitrageur buys in the cheap USDG market and sells in the ETH
        // market until the two agree: net of fees this is profitable and
        // ends with the markets within a few percent of each other.
        Hop[] memory usdgHop = _v3Leg(WETH, USDG, 500);
        PairPadMultiRouter.Leg[] memory buyCheap = new PairPadMultiRouter.Leg[](1);
        buyCheap[0] = PairPadMultiRouter.Leg({market: 1, hops: usdgHop, amountIn: 0.09 ether});
        vm.prank(other);
        uint256 cheap = router.buyWithEth{value: 0.09 ether}(token, buyCheap, 0, other);
        PairPadMultiRouter.Leg[] memory sellDear = new PairPadMultiRouter.Leg[](1);
        sellDear[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: cheap});
        vm.startPrank(other);
        IERC20(token).approve(address(router), cheap);
        uint256 back = router.sellToEth(token, sellDear, 0, other);
        vm.stopPrank();
        assertGt(back, 0.09 ether, "arbitrage pays");

        uint256 perEthDirect = _tokensPerQuoteX96(keys[0], token);
        uint256 perEthViaUsdg = FullMath.mulDiv(_tokensPerQuoteX96(keys[1], token), usdgPerEth, 1 ether);
        assertApproxEqRel(perEthViaUsdg, perEthDirect, 0.1e18, "markets pulled back together");
        assertGt(got, 0);
    }
}
