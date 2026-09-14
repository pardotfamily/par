// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadLaunchLocker} from "../../src/v2/PairPadLaunchLocker.sol";
import {PairPadRouter} from "../../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiLaunchLocker} from "../../src/v3/PairPadMultiLaunchLocker.sol";
import {IPairPadFeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";
import {
    PairPadFloorVault,
    IFloorSingleFactory,
    IFloorSingleLocker,
    IFloorMultiFactory,
    IFloorMultiLocker
} from "../../src/fees/PairPadFloorVault.sol";

/**
 * @notice The floor vault against the live mainnet stack: a launch names it
 * as creator recipient, trades happen, a rebalance pulls the fees through
 * the locker, burns the token side and stands the quote side as a wall in
 * the launch pool; then every holder dumps and the price stops at the wall.
 *
 *   forge test --match-path "test/fork/FloorVault*" --fork-url robinhood
 */
contract FloorVaultForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V2_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;
    address constant V2_ROUTER = 0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120;
    address constant V2_LOCKER = 0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231;
    address constant MULTI_FACTORY = 0x3ea29975a79900179F3e1aEF93347Ba4210c29C1;
    address constant MULTI_LOCKER = 0x5826FBB6201DaAcD924A3d292841DA9142952D59;
    address constant FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    PairPadLaunchFactory factory = PairPadLaunchFactory(V2_FACTORY);
    PairPadRouter router = PairPadRouter(payable(V2_ROUTER));
    PairPadLaunchLocker locker = PairPadLaunchLocker(payable(V2_LOCKER));
    PairPadFeeEscrow escrow = PairPadFeeEscrow(FEE_ESCROW);

    PairPadFloorVault vault;

    address operator = makeAddr("operator");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address whale = makeAddr("whale");

    modifier onlyFork() {
        if (block.chainid != 4663) vm.skip(true);
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        vault = new PairPadFloorVault(
            manager,
            IPairPadFeeEscrow(FEE_ESCROW),
            IFloorSingleFactory(V2_FACTORY),
            IFloorSingleLocker(V2_LOCKER),
            IFloorMultiFactory(MULTI_FACTORY),
            IFloorMultiLocker(MULTI_LOCKER),
            operator
        );
        vm.deal(creator, 10 ether);
        vm.deal(trader, 100 ether);
        vm.deal(whale, 500 ether);
    }

    function _launchEthQuoted(uint16 taxBps, address recipient) internal returns (address token, PoolKey memory key) {
        PairPadLaunchFactory.TokenParams memory p = PairPadLaunchFactory.TokenParams({
            name: "Floor",
            symbol: "FLR",
            logo: "",
            description: "floor mode e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: recipient,
            creatorTaxBps: taxBps,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode(recipient, taxBps, block.number, gasleft()))
        });
        uint256 fee = factory.launchFee();
        vm.prank(creator);
        (token,) = factory.launchToken{value: fee}(p, 0, address(0));
        key = factory.poolKeyFor(token);
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = manager.getSlot0(key.toId());
    }

    /// @dev Quote per whole token at `sqrtPriceX96`, scaled by 1e18 (token is currency1 when ETH is quote).
    function _priceX18(PoolKey memory key, address token, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        // ratio = currency1 / currency0
        if (Currency.unwrap(key.currency0) == token) return FullMath.mulDiv(ratioX128, 1e18, 1 << 128);
        return FullMath.mulDiv(1e18, 1 << 128, ratioX128);
    }

    function test_fork_ethQuoted_wallStandsAndHoldsUnderFullDump() public onlyFork {
        (address token, PoolKey memory key) = _launchEthQuoted(100, address(vault));
        assertEq(factory.getLaunchedToken(token).creatorFeeRecipient, address(vault));
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        assertFalse(tokenIs0, "ETH is currency0 on this chain's pools");

        // Volume: a whale and a trader buy, the trader sells half back.
        vm.startPrank(whale);
        uint256 whaleGot = router.swapExactIn{value: 40 ether}(key, true, 40 ether, 0, whale);
        vm.stopPrank();
        vm.startPrank(trader);
        uint256 got = router.swapExactIn{value: 10 ether}(key, true, 10 ether, 0, trader);
        IERC20(token).approve(address(router), type(uint256).max);
        router.swapExactIn(key, false, got / 2, 0, trader);
        vm.stopPrank();

        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 pend0, uint256 pend1) = locker.pendingFees(token);
        assertGt(pend0 + pend1, 0, "fees accrued");

        // Round 1: collect, burn the token side, stand the wall.
        vault.rebalance(token);

        assertEq(escrow.balanceOf(address(vault)), 0, "ETH claimed out of the escrow");
        assertEq(escrow.balanceOfToken(address(vault), token), 0, "token claimed out of the escrow");
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "vault holds no token");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "token-side fee burned");
        assertGt(vault.burned(token), 0);

        (uint256 inWall, uint256 idleQ, uint256 circ, PairPadFloorVault.Wall memory wall, uint160 wallEdge) =
            vault.floorOf(token, address(0));
        assertGt(wall.liquidity, 0, "wall stands");
        assertGt(inWall, 0, "wall holds ETH");
        assertLt(idleQ, 1e9, "at most rounding dust idle");
        assertEq(address(vault).balance, idleQ, "vault ETH balance is the idle ledger");
        assertEq(vault.idleTotal(address(0)), idleQ);
        assertGt(circ, 0);
        // ETH is currency0: the wall sits above the current tick (lower token price).
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGt(wall.tickLower, tick, "wall entirely on the quote side of the price");
        assertEq(wall.tickUpper - wall.tickLower, key.tickSpacing, "one spacing wide");

        // The curve buys back on the way down, so the wall stands above the
        // naive ETH / circulating, and the floor mcap is above the opening mcap.
        uint256 naiveX18 = FullMath.mulDiv(inWall, 1e18, circ);
        uint256 edgeX18 = _priceX18(key, token, wallEdge);
        assertGe(edgeX18, naiveX18 * 95 / 100, "wall at least where the ETH alone would put it");
        uint256 floorMcap = FullMath.mulDiv(edgeX18, IERC20(token).totalSupply(), 1e18);
        uint256 openingMcap = factory.getLaunchedToken(token).phantomQuote;
        assertGt(floorMcap, openingMcap, "floor above the opening mcap");
        assertLt(floorMcap, openingMcap + inWall * 3, "and not absurdly so");
        console2.log("ETH in wall", inWall);
        console2.log("circulating", circ);
        console2.log("floor price x1e18 (ETH per token)", edgeX18);
        console2.log("floor mcap (wei ETH)", floorMcap);
        console2.log("opening mcap (wei ETH)", openingMcap);
        console2.log("market price x1e18", _priceX18(key, token, _sqrtPrice(key)));

        // Everyone dumps everything. The price must stop inside the wall.
        vm.startPrank(whale);
        IERC20(token).approve(address(router), type(uint256).max);
        router.swapExactIn(key, false, whaleGot, 0, whale);
        vm.stopPrank();
        uint256 traderBal = IERC20(token).balanceOf(trader);
        vm.prank(trader);
        router.swapExactIn(key, false, traderBal, 0, trader);

        uint160 after_ = _sqrtPrice(key);
        // Lower token price = higher pool price here; the wall's far edge is tickUpper.
        assertLe(after_, TickMath.getSqrtPriceAtTick(wall.tickUpper), "price never crossed the wall");
        assertGe(after_, TickMath.getSqrtPriceAtTick(wall.tickLower), "and the dump reached the wall");
        console2.log("price after full dump x1e18", _priceX18(key, token, after_));

        // Round 2: the wall bought tokens; they are burned and the rest of the ETH stands again.
        uint256 burnedBefore = vault.burned(token);
        uint256 supplyBeforeR2 = IERC20(token).totalSupply();
        vault.rebalance(token);
        assertGt(vault.burned(token), burnedBefore, "absorbed tokens burned");
        assertLt(IERC20(token).totalSupply(), supplyBeforeR2);
        (uint256 inWall2,, uint256 circ2, PairPadFloorVault.Wall memory wall2,) = vault.floorOf(token, address(0));
        assertLt(inWall2, inWall, "some ETH was spent absorbing the dump");
        assertLt(circ2, circ, "fewer tokens in circulation");
        console2.log("ETH in wall after round 2", inWall2);
        console2.log("circulating after round 2", circ2);
        if (circ2 > 0) {
            assertGt(wall2.liquidity, 0, "wall re-stood");
        }
    }

    function test_fork_floorOnlyRises() public onlyFork {
        (address token, PoolKey memory key) = _launchEthQuoted(100, address(vault));
        uint256 lastFloor;
        for (uint256 i = 0; i < 4; i++) {
            vm.startPrank(trader);
            uint256 got = router.swapExactIn{value: 3 ether}(key, true, 3 ether, 0, trader);
            IERC20(token).approve(address(router), type(uint256).max);
            router.swapExactIn(key, false, got / 3, 0, trader);
            vm.stopPrank();
            vault.rebalance(token);
            (uint256 inWall,, uint256 circ,, uint160 edge) = vault.floorOf(token, address(0));
            uint256 floorMcapX18 = FullMath.mulDiv(_priceX18(key, token, edge), IERC20(token).totalSupply(), 1e18);
            console2.log("round", i);
            console2.log("  ETH in wall", inWall);
            console2.log("  circulating", circ);
            console2.log("  floor mcap (wei ETH)", floorMcapX18);
            assertGe(floorMcapX18, lastFloor, "floor mcap never falls");
            lastFloor = floorMcapX18;
        }
    }

    function test_fork_nonFloorLaunchRejected_andStrayCollectionAssignable() public onlyFork {
        (address token, PoolKey memory key) = _launchEthQuoted(100, address(vault));
        (address other,) = _launchEthQuoted(100, creator);

        vm.expectRevert(abi.encodeWithSelector(PairPadFloorVault.NotFloorLaunch.selector, other));
        vault.rebalance(other);

        // Someone collects the floor launch directly: the ETH lands unattributed.
        vm.startPrank(trader);
        router.swapExactIn{value: 2 ether}(key, true, 2 ether, 0, trader);
        vm.stopPrank();
        locker.collectFees(token);
        uint256 stray = vault.unattributed(address(0));
        assertGt(stray, 0, "stray ETH visible");
        assertEq(vault.idle(token, address(0)), 0);

        vm.prank(trader);
        vm.expectRevert(PairPadFloorVault.NotOperator.selector);
        vault.assignUnattributed(token, address(0), stray);

        vm.prank(operator);
        vm.expectRevert();
        vault.assignUnattributed(token, address(0), stray + 1);

        vm.prank(operator);
        vault.assignUnattributed(token, address(0), stray);
        assertEq(vault.idle(token, address(0)), stray);
        assertEq(vault.unattributed(address(0)), 0);

        // And the next rebalance stands it as the wall.
        vault.rebalance(token);
        (uint256 inWall,,, PairPadFloorVault.Wall memory wall,) = vault.floorOf(token, address(0));
        assertGt(wall.liquidity, 0);
        assertGt(inWall, stray * 99 / 100);
    }

    function test_fork_multiMarket_usdgWallInUsdgPool() public onlyFork {
        PairPadMultiLaunchFactory mf = PairPadMultiLaunchFactory(MULTI_FACTORY);
        PairPadMultiLaunchFactory.TokenParams memory p = PairPadMultiLaunchFactory.TokenParams({
            name: "Floor Multi",
            symbol: "FLRM",
            logo: "",
            description: "floor multi e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(vault),
            creatorTaxBps: 100,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode("multi-floor", address(vault), block.number))
        });
        address[] memory quotes = new address[](2);
        quotes[0] = address(0);
        quotes[1] = USDG;
        uint256 fee = mf.launchFee();
        vm.prank(creator);
        address token = mf.launchToken{value: fee}(p, 0, quotes);

        PoolKey memory usdgKey = mf.poolKeyFor(token, 1);
        deal(USDG, trader, 50_000e6);
        bool usdgIs0 = USDG < token;
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), type(uint256).max);
        uint256 got = router.swapExactIn(usdgKey, usdgIs0, 20_000e6, 0, trader);
        IERC20(token).approve(address(router), got);
        router.swapExactIn(usdgKey, !usdgIs0, got / 2, 0, trader);
        vm.stopPrank();

        vault.rebalance(token);
        (uint256 inWall, uint256 idleQ, uint256 circ, PairPadFloorVault.Wall memory wall,) = vault.floorOf(token, USDG);
        assertGt(wall.liquidity, 0, "USDG wall stands");
        assertGt(inWall, 0);
        assertLt(idleQ, 10, "dust only");
        assertEq(IERC20(USDG).balanceOf(address(vault)), idleQ);
        assertGt(circ, 0);
        // The ETH market saw no trade: no ETH wall.
        (,,, PairPadFloorVault.Wall memory ethWall,) = vault.floorOf(token, address(0));
        assertEq(ethWall.liquidity, 0);
        console2.log("USDG in wall", inWall);
    }
}
