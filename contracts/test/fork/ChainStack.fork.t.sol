// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployChain} from "../../script/DeployChain.s.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiRouter} from "../../src/v3/PairPadMultiRouter.sol";
import {PairPadFloorVault} from "../../src/fees/PairPadFloorVault.sol";
import {Hop} from "../../src/v2/libraries/Hop.sol";

/// @dev Runs the deploy script's internals in-process: the harness is the owner of everything it deploys.
contract DeployChainHarness is DeployChain {
    function deployAll(address protocolFeeRecipient, address buyback, address treasury, address distributor)
        external
        returns (Core memory c, Fees memory f, Infra memory infra, Defaults memory d)
    {
        (infra, d) = _table(block.chainid);
        Params memory p = Params({
            owner: address(this),
            protocolFeeRecipient: protocolFeeRecipient,
            launchFee: d.launchFee,
            minReference: d.minReference,
            supply: 1_000_000_000 ether,
            phantom: d.phantom,
            buyback: buyback,
            treasury: treasury,
            distributor: distributor,
            buybackBps: 6000
        });
        c = _deployCore(infra, p);
        _deployMulti(infra, p, c);
        f = _deployFees(p, c);
    }
}

/**
 * @notice The whole par stack, deployed the way `DeployChain` deploys it,
 * exercised on a fork of a chain whose gas token is the reference (Base,
 * BNB Chain): single-market and multi-market launches quoted in native,
 * a second market in the chain's dollar anchor through its V3 pool, fee
 * collection, and all three creator-fee vaults. Skips on any other chain.
 *
 *   forge test --match-path "test/fork/ChainStack*" --fork-url $BASE_RPC
 *   forge test --match-path "test/fork/ChainStack*" --fork-url $BNB_RPC
 */
contract ChainStackForkTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    DeployChainHarness harness;
    DeployChain.Core c;
    DeployChain.Fees f;
    DeployChain.Infra infra;
    DeployChain.Defaults d;

    // Namespaced labels: the plain ones collide with contracts that exist on
    // the forked mainnets (makeAddr("treasury") is a forwarder on Base).
    address creator = makeAddr("par.chainstack.creator");
    address buyer = makeAddr("par.chainstack.buyer");
    address protocolFees = makeAddr("par.chainstack.protocolFees");
    address buyback = makeAddr("par.chainstack.buyback");
    address treasury = makeAddr("par.chainstack.treasury");
    address distributor = makeAddr("par.chainstack.distributor");

    receive() external payable {}

    function _supported() internal view returns (bool) {
        return block.chainid == 8453 || block.chainid == 56;
    }

    modifier onlyFork() {
        if (!_supported()) vm.skip(true);
        _;
    }

    function setUp() public {
        if (!_supported()) return;
        // Plain EOAs whatever the fork holds at those addresses.
        vm.etch(treasury, "");
        vm.etch(buyback, "");
        vm.etch(distributor, "");
        vm.etch(protocolFees, "");
        harness = new DeployChainHarness();
        (c, f, infra, d) = harness.deployAll(protocolFees, buyback, treasury, distributor);
        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    // -------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------

    function _single(bytes32 salt, address feeRecipient, uint16 tax)
        internal
        pure
        returns (PairPadLaunchFactory.TokenParams memory)
    {
        return PairPadLaunchFactory.TokenParams({
            name: "Chain Meme",
            symbol: "CHM",
            logo: "",
            description: "chain stack e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: feeRecipient,
            creatorTaxBps: tax,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _multi(bytes32 salt, address feeRecipient, uint16 tax)
        internal
        pure
        returns (PairPadMultiLaunchFactory.TokenParams memory)
    {
        return PairPadMultiLaunchFactory.TokenParams({
            name: "Chain Multi",
            symbol: "CHMM",
            logo: "",
            description: "chain stack multi e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: feeRecipient,
            creatorTaxBps: tax,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _launchSingle(bytes32 salt, address feeRecipient, uint16 tax) internal returns (address token) {
        vm.prank(creator);
        (token,) = c.factory.launchToken{value: d.launchFee}(_single(salt, feeRecipient, tax), 0, address(0));
    }

    /// @dev Native market plus the chain's dollar anchor as a second market.
    function _launchMulti(bytes32 salt, address feeRecipient, uint16 tax) internal returns (address token) {
        address[] memory pair = new address[](2);
        pair[0] = address(0);
        pair[1] = infra.secondAnchor;
        vm.prank(creator);
        token = c.multiFactory.launchToken{value: d.launchFee}(_multi(salt, feeRecipient, tax), 0, pair);
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

    function _legs(uint256 total) internal view returns (PairPadMultiRouter.Leg[] memory legs) {
        legs = new PairPadMultiRouter.Leg[](2);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: total / 2});
        legs[1] = PairPadMultiRouter.Leg({
            market: 1, hops: _v3Leg(infra.weth, infra.secondAnchor, 500), amountIn: total - total / 2
        });
    }

    function _buySingle(address token, uint256 value) internal returns (uint256 out) {
        PoolKey memory key = c.factory.poolKeyFor(token);
        vm.prank(buyer);
        out = c.router.buyWithEth{value: value}(key, new Hop[](0), 0, buyer);
    }

    function _sellSingle(address token, uint256 amount) internal returns (uint256 ethOut) {
        PoolKey memory key = c.factory.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        vm.startPrank(buyer);
        IERC20(token).approve(address(c.router), amount);
        ethOut = c.router.sellToEth(key, tokenIs0, amount, new Hop[](0), 0, buyer);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Pricer and infra
    // -------------------------------------------------------------------

    function test_fork_pricer_nativeIsReference_anchorRoutes() public onlyFork {
        assertTrue(c.pricer.nativeIsReference());
        assertEq(c.pricer.minReferenceEth(), d.minReference);
        // Native is priced as the reference through its wrapped slot; the pricer answers for `weth`.
        assertTrue(c.pricer.isPriceable(infra.weth), "wrapped native is the reference anchor");
        assertEq(c.pricer.priceEthAmountInQuote(infra.weth, 1 ether), 1 ether, "identity in the reference");
        assertTrue(c.pricer.isPriceable(infra.secondAnchor), "the dollar anchor routes through its V3 pool");
        uint256 perEth = c.pricer.priceEthAmountInQuote(infra.secondAnchor, 1 ether);
        uint8 dec = IERC20Metadata(infra.secondAnchor).decimals();
        // One ETH or BNB is worth somewhere between $100 and $50,000.
        assertGt(perEth, 100 * 10 ** dec);
        assertLt(perEth, 50_000 * 10 ** dec);
    }

    /**
     * BNB Chain only: the V3 side is PancakeSwap's. Ondo's NVDAon has its
     * liquidity in a Pancake 1% USDT pool, which Uniswap's factory never
     * saw; with Pancake's factory and fee tiers the pricer routes it
     * NVDAon -> USDT -> WBNB and a launch can be quoted in it.
     */
    function test_fork_bnb_pancakeStockRoutes() public onlyFork {
        if (block.chainid != 56) return;
        address nvdaOn = 0xA9eE28C80f960B889dFbd1902055218cBa016F75;
        assertEq(c.pricer.v3FeeTiersLength(), 4, "Pancake tiers set");
        assertEq(c.pricer.v3FeeTiers(2), 2_500);
        assertTrue(c.pricer.isPriceable(nvdaOn), "NVDAon priced through Pancake");
        uint256 perEth = c.pricer.priceEthAmountInQuote(nvdaOn, 1 ether);
        assertGt(perEth, 0);
        // 1 BNB (~$770) is a handful of NVDAon (~$180 each): between 1 and 20 tokens.
        assertGt(perEth, 1e18);
        assertLt(perEth, 20e18);

        // A launch quoted in NVDAon opens and takes a buy paid in BNB along the route.
        address[] memory pair = new address[](1);
        pair[0] = nvdaOn;
        vm.prank(creator);
        address token = c.multiFactory.launchToken{value: d.launchFee}(_multi("pk", creator, 0), 0, pair);
        assertEq(c.multiFactory.getMarkets(token)[0].pairToken, nvdaOn);
        (Hop[] memory sellLeg, bool qualifies) = c.pricer.route(nvdaOn);
        assertTrue(qualifies && sellLeg.length > 0);
        Hop[] memory buyLeg = new Hop[](sellLeg.length);
        for (uint256 i = 0; i < sellLeg.length; i++) buyLeg[i] = sellLeg[sellLeg.length - 1 - i];
        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](1);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: buyLeg, amountIn: 0.05 ether});
        vm.prank(buyer);
        uint256 out = c.multiRouter.buyWithEth{value: 0.05 ether}(token, legs, 0, buyer);
        assertGt(out, 0, "bought through Pancake into an NVDAon-quoted pool");
        assertEq(IERC20(nvdaOn).balanceOf(address(c.multiRouter)), 0, "router keeps nothing");
    }

    // -------------------------------------------------------------------
    // Single-market launch (native quote)
    // -------------------------------------------------------------------

    function test_fork_single_launch_buy_sell_collect() public onlyFork {
        address token = _launchSingle("s1", creator, 0);
        // The splitter is the protocol fee recipient once the fee stack is wired; it forwards launch fees to the treasury whole.
        assertEq(treasury.balance, d.launchFee, "launch fee paid in native, forwarded to the treasury");
        assertEq(IERC20(token).balanceOf(address(c.factory.poolManager())) + IERC20(token).balanceOf(address(c.locker)), SUPPLY);

        uint256 out = _buySingle(token, 0.05 ether);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(buyer), out);
        // Opening cap is the phantom reserve: 0.05 ETH against it buys about that share of supply.
        uint256 expected = SUPPLY * 0.0495 ether / (d.phantom + 0.0495 ether);
        assertApproxEqRel(out, expected, 0.02e18, "curve from the phantom reserve");

        uint256 ethOut = _sellSingle(token, out / 2);
        assertGt(ethOut, 0.02 ether);
        assertLt(ethOut, 0.025 ether);

        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 splitterBefore = address(f.splitter).balance;
        c.locker.collectFees(token);
        // The buy's 1% fee in native: half to the protocol (splitter), half escrowed for the creator.
        assertApproxEqAbs(address(f.splitter).balance - splitterBefore, 0.00025 ether, 0.00002 ether, "protocol share of the buy fee");
        assertApproxEqAbs(c.feeEscrow.balanceOf(creator), 0.00025 ether, 0.00002 ether, "creator share escrowed");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "token-side fee burned");

        uint256 before = creator.balance;
        vm.prank(creator);
        c.feeEscrow.claim();
        assertGt(creator.balance, before);
    }

    // -------------------------------------------------------------------
    // Multi-market launch: native + dollar anchor
    // -------------------------------------------------------------------

    function test_fork_multi_launch_buy_sell_acrossMarkets() public onlyFork {
        address token = _launchMulti("m1", creator, 0);
        assertEq(c.multiFactory.getMarkets(token).length, 2);
        assertEq(c.multiFactory.getMarkets(token)[1].pairToken, infra.secondAnchor);

        uint256 spend = 0.1 ether;
        vm.prank(buyer);
        uint256 out = c.multiRouter.buyWithEth{value: spend}(token, _legs(spend), 0, buyer);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(buyer), out);
        // Two curves with half the phantom each, half the spend each: about the same as one curve with the whole.
        uint256 expected = SUPPLY * 0.099 ether / (d.phantom + 0.099 ether);
        assertApproxEqRel(out, expected, 0.05e18, "two halves add up");
        assertEq(address(c.multiRouter).balance, 0);
        assertEq(IERC20(infra.secondAnchor).balanceOf(address(c.multiRouter)), 0);
        assertEq(IERC20(infra.weth).balanceOf(address(c.multiRouter)), 0);

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(token).approve(address(c.multiRouter), out);
        uint256 ethOut = c.multiRouter.sellToEth(token, _legs(out), 0, buyer);
        vm.stopPrank();
        assertEq(buyer.balance, ethBefore + ethOut);
        assertGt(ethOut, 0.09 ether, "most of it comes back through both markets");
        assertLt(ethOut, spend);

        c.multiLocker.collectFees(token);
        assertGt(c.feeEscrow.balanceOf(creator), 0, "native fee from the native market");
        assertGt(c.feeEscrow.balanceOfToken(creator, infra.secondAnchor), 0, "anchor fee from the anchor market");
    }

    // -------------------------------------------------------------------
    // Fee modes
    // -------------------------------------------------------------------

    function test_fork_feesToHolders_harvestReachesDistributor() public onlyFork {
        address token = _launchSingle("h1", address(f.holderVault), 500);
        uint256 out = _buySingle(token, 0.2 ether);
        _sellSingle(token, out / 2);
        c.locker.collectFees(token);
        assertGt(c.feeEscrow.balanceOf(address(f.holderVault)), 0);
        assertGt(c.feeEscrow.balanceOfToken(address(f.holderVault), token), 0);

        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = token;
        uint256 nativeBefore = distributor.balance;
        f.holderVault.harvest(assets);
        assertGt(distributor.balance, nativeBefore, "native fee reached the distributor wallet");
        assertGt(IERC20(token).balanceOf(distributor), 0, "token fee reached the distributor wallet");
        assertEq(c.feeEscrow.balanceOf(address(f.holderVault)), 0);
    }

    function test_fork_buybackAndBurn_vaultBuysAndBurns() public onlyFork {
        address token = _launchSingle("b1", address(f.burnVault), 500);
        uint256 out = _buySingle(token, 0.2 ether);
        _sellSingle(token, out / 2);
        c.locker.collectFees(token);
        uint256 owed = c.feeEscrow.balanceOf(address(f.burnVault));
        assertGt(owed, 0);

        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(distributor);
        (uint256 bought, uint256 burnedNow) = f.burnVault.buyback(token, address(0), owed, 0);
        assertGt(bought, 0);
        assertGe(burnedNow, bought, "bought tokens and the token-side fee both burned");
        assertEq(IERC20(token).totalSupply(), supplyBefore - burnedNow);
        assertEq(IERC20(token).balanceOf(address(f.burnVault)), 0);
        assertEq(address(f.burnVault).balance, 0);
    }

    function test_fork_floorMode_wallStandsAfterRebalance() public onlyFork {
        address token = _launchSingle("f1", address(f.floorVault), 500);
        uint256 out = _buySingle(token, 0.5 ether);
        _sellSingle(token, out / 4);

        // The vault collects for itself inside rebalance; a direct collect would leave the fee unattributed.
        f.floorVault.rebalance(token);
        assertEq(f.floorVault.unattributed(address(0)), 0, "nothing stray");
        PoolKey memory key = c.factory.poolKeyFor(token);
        (uint256 quoteInWall, uint256 idle, uint256 circulating, PairPadFloorVault.Wall memory wall, uint160 edge) =
            f.floorVault.floorOf(token, address(0));
        uint256 floorMcap = FullMath.mulDiv(_priceX18(key, token, edge), IERC20(token).totalSupply(), 1e18);
        assertGt(quoteInWall, 0, "the creator fee became a wall");
        assertGt(wall.liquidity, 0);
        assertLt(wall.tickLower, wall.tickUpper);
        assertGt(circulating, 0);
        assertLt(idle, quoteInWall / 10 + 1, "almost everything sits in the wall");
        assertEq(c.feeEscrow.balanceOf(address(f.floorVault)), 0, "escrow drained into the wall");

        // More trading, another rebalance: the wall only grows.
        uint256 out2 = _buySingle(token, 0.5 ether);
        _sellSingle(token, out2 / 4);
        f.floorVault.rebalance(token);
        (uint256 quoteInWall2,,, PairPadFloorVault.Wall memory wall2, uint160 edge2) = f.floorVault.floorOf(token, address(0));
        assertGt(quoteInWall2, quoteInWall);
        assertGt(wall2.liquidity, 0);
        uint256 floorMcap2 = FullMath.mulDiv(_priceX18(key, token, edge2), IERC20(token).totalSupply(), 1e18);
        assertGe(floorMcap2, floorMcap, "floor market cap never falls");
    }

    /// @dev Price of `token` in the quote, 1e18-scaled, from a sqrt price (currency1 per currency0).
    function _priceX18(PoolKey memory key, address token, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        if (Currency.unwrap(key.currency0) == token) return FullMath.mulDiv(ratioX128, 1e18, 1 << 128);
        return FullMath.mulDiv(1e18, 1 << 128, ratioX128);
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
