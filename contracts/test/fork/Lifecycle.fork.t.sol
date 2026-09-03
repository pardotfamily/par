// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../../src/v2/PairPadQuotePricer.sol";
import {PonsReferenceRegistry, IPonsV2LaunchFactory} from "../../src/v2/PairPadReferenceRegistries.sol";
import {PairPadLaunchLocker} from "../../src/v2/PairPadLaunchLocker.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadPositionMinter} from "../../src/v2/PairPadPositionMinter.sol";
import {LaunchDeployment, PairPadLaunchDeployer} from "../../src/v2/PairPadLaunchDeployer.sol";
import {PairPadRouter, ISwapRouter02, IWETH9} from "../../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {IPairPadFeeEscrow, IPairPadLaunchFactory} from "../../src/v2/interfaces/ILaunchpadV2.sol";

/**
 * @dev A bare PoolManager caller standing in for any third-party router or
 * LP: swaps and adds liquidity with nothing but the pool key.
 */
contract V4Probe is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external payable {
        manager.unlock(abi.encode(uint8(0), key, zeroForOne, amountIn, int128(0)));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int128 liquidity) external payable {
        manager.unlock(abi.encode(uint8(1), key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint8 op = abi.decode(data, (uint8));
        BalanceDelta delta;
        PoolKey memory key;
        if (op == 0) {
            (, PoolKey memory k, bool zeroForOne, uint256 amountIn,) =
                abi.decode(data, (uint8, PoolKey, bool, uint256, int128));
            key = k;
            delta = manager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        } else {
            (, PoolKey memory k, int24 tickLower, int24 tickUpper, int128 liquidity) =
                abi.decode(data, (uint8, PoolKey, int24, int24, int128));
            key = k;
            (delta,) = manager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(0)
                }),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/**
 * @notice End-to-end lifecycle against a fork of Robinhood Chain mainnet
 * (4663) with the real Uniswap V4 PoolManager and PositionManager, V3 zap
 * path and Permit2. Run with:
 *
 *   forge test --match-path "test/fork/*" --fork-url robinhood
 *
 * Skipped automatically when no fork is active.
 */

/// @dev A protocol fee recipient that refuses plain ETH transfers.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract LifecycleForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    /// @dev A PONS graduate whose only real market is its V4 ETH pool.
    address constant BLOKKS = 0x66e73ef65528Baf192679222c6D2810D7D7e2c68;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant PHANTOM = 1.3557 ether;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    PairPadFeeEscrow feeEscrow;
    PairPadQuotePricer quotePricer;
    PairPadLaunchLocker locker;
    PairPadLaunchFactory factory;
    PairPadPositionMinter minter;
    PairPadLaunchDeployer launchDeployer;
    PairPadRouter router;
    V4Probe probe;

    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");
    address protocolFees = makeAddr("protocolFees");

    receive() external payable {}

    function setUp() public {
        if (block.chainid != 4663) return;

        feeEscrow = new PairPadFeeEscrow();
        quotePricer = new PairPadQuotePricer(
            address(this), IUniswapV3FactoryMinimal(V3_FACTORY), WETH, USDG, manager
        );
        quotePricer.setV4HookAllowed(PONS_HOOK, true);
        quotePricer.addRegistry(new PonsReferenceRegistry(IPonsV2LaunchFactory(PONS_FACTORY), IHooks(PONS_HOOK)));
        locker = new PairPadLaunchLocker(
            address(this), IPositionManager(POSITION_MANAGER), IPairPadFeeEscrow(address(feeEscrow))
        );

        factory = new PairPadLaunchFactory(
            address(this),
            manager,
            IPositionManager(POSITION_MANAGER),
            locker,
            IPairPadFeeEscrow(address(feeEscrow)),
            quotePricer,
            protocolFees,
            0
        );
        minter = new PairPadPositionMinter(
            IPositionManager(POSITION_MANAGER), IAllowanceTransfer(PERMIT2), locker, address(factory)
        );
        launchDeployer = new PairPadLaunchDeployer(address(factory));
        router = new PairPadRouter(manager, factory, ISwapRouter02(SWAP_ROUTER_02), IWETH9(WETH));
        probe = new V4Probe(manager);

        locker.setFactory(address(factory));
        factory.setPositionMinter(minter);
        factory.setLaunchDeployer(launchDeployer);
        factory.setLaunchForwarder(address(router));
        factory.addLaunchConfig(
            PairPadLaunchFactory.LaunchConfig({supply: SUPPLY, phantomQuote: PHANTOM, tickSpacing: 10, enabled: true})
        );
        factory.setLaunchEnabled(true);

        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(other, 100 ether);
        vm.deal(address(probe), 100 ether);
    }

    modifier onlyFork() {
        if (block.chainid != 4663) vm.skip(true);
        _;
    }

    function _params(bytes32 salt) internal pure returns (PairPadLaunchFactory.TokenParams memory) {
        return PairPadLaunchFactory.TokenParams({
            name: "Fork Meme",
            symbol: "FORK",
            logo: "",
            description: "fork e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    function _launchNative(bytes32 salt) internal returns (address token, PoolKey memory key) {
        vm.prank(creator);
        (token,) = factory.launchToken(_params(salt), 0, address(0));
        key = factory.poolKeyFor(token);
    }

    /// @dev Direction of a buy (quote in, token out) for a native-quoted pool:
    /// ETH is always currency0, so buys are zeroForOne.
    function _buyEth(PoolKey memory key, address who, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.swapExactIn{value: ethIn}(key, true, ethIn, 0, who);
    }

    function _sellEth(PoolKey memory key, address token, address who, uint256 tokensIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(token).approve(address(router), tokensIn);
        out = router.swapExactIn(key, false, tokensIn, 0, who);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Launch: pool, position, custody
    // -------------------------------------------------------------------

    function test_fork_launch_mintsLockedPositionHoldingWholeSupply() public onlyFork {
        (address token, PoolKey memory key) = _launchNative("launch");
        PoolId poolId = key.toId();

        IPairPadLaunchFactory.LaunchedToken memory launched = factory.getLaunchedToken(token);
        assertTrue(launched.exists);
        assertEq(launched.deployer, creator);
        assertEq(launched.creatorFeeRecipient, creator);
        assertEq(launched.pairToken, address(0));
        assertEq(launched.phantomQuote, PHANTOM);
        assertEq(launched.poolFee, 10_000);
        assertEq(launched.baseFeeBps, 100);
        assertEq(launched.protocolFeeShareBps, 5_000);
        assertEq(launched.protocolFeeRecipient, protocolFees);

        // The pool is a plain V4 pool: no hook, 1% static LP fee.
        assertEq(address(key.hooks), address(0));
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, 10);
        assertEq(Currency.unwrap(key.currency1), token);
        assertEq(PoolId.unwrap(factory.poolIdFor(token)), PoolId.unwrap(poolId));

        // Custody: the NFT belongs to the locker, which cannot move it.
        assertTrue(locker.isLocked(token));
        assertEq(IERC721(POSITION_MANAGER).ownerOf(launched.positionId), address(locker));
        assertEq(locker.lockedPositions(token), launched.positionId);

        // The whole supply sits in the PoolManager, apart from rounding dust
        // that went to the locker. Nobody else holds anything.
        uint256 inPool = IERC20(token).balanceOf(POOL_MANAGER);
        uint256 dust = IERC20(token).balanceOf(address(locker));
        assertEq(inPool + dust, SUPPLY);
        assertLt(dust, 1e12);
        assertEq(IERC20(token).balanceOf(creator), 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(address(minter)), 0);

        // Nothing earned yet.
        (uint256 f0, uint256 f1) = locker.pendingFees(token);
        assertEq(f0, 0);
        assertEq(f1, 0);

        // Opening price: PHANTOM / 1B tokens, within a tick spacing.
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 priceX96 = (uint256(sqrtPriceX96) * sqrtPriceX96) >> 96; // token per ETH (currency1/currency0)
        uint256 tokensPerEth = priceX96 >> 96;
        assertApproxEqRel(tokensPerEth, SUPPLY / PHANTOM, 0.001e18);
    }

    function test_fork_launch_creatorTaxRaisesThePoolFee() public onlyFork {
        PairPadLaunchFactory.TokenParams memory p = _params("taxed");
        p.creatorTaxBps = 200;
        vm.prank(creator);
        (address token,) = factory.launchToken(p, 0, address(0));
        PoolKey memory key = factory.poolKeyFor(token);
        assertEq(key.fee, 30_000);
        assertEq(factory.getLaunchedToken(token).creatorTaxBps, 200);
    }

    function test_fork_launch_refusesAPoolSomeoneOpenedFirst() public onlyFork {
        PairPadLaunchFactory.TokenParams memory p = _params("squat");
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
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(predicted),
            fee: 10_000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        // A squatter initializes the exact key at a price of their choosing.
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        vm.prank(creator);
        vm.expectRevert(PairPadLaunchFactory.PoolAlreadyExists.selector);
        factory.launchToken(p, 0, address(0));

        // A different salt gives a different address and the launch goes through.
        p.salt = "squat-2";
        vm.prank(creator);
        (address token,) = factory.launchToken(p, 0, address(0));
        assertTrue(token != predicted);
    }

    // -------------------------------------------------------------------
    // Trading: through the router and through a stranger's V4 caller
    // -------------------------------------------------------------------

    function test_fork_buyAndSell_nativeQuote_feesAccrueToThePosition() public onlyFork {
        (address token, PoolKey memory key) = _launchNative("trade");

        // Buy 1 ETH. The pool takes 1% off the input, then the curve:
        // tokens out = S * q / (P + q) with q = 0.99 ETH.
        uint256 tokensOut = _buyEth(key, buyer, 1 ether);
        uint256 netIn = 0.99 ether;
        uint256 expected = SUPPLY * netIn / (PHANTOM + netIn);
        assertApproxEqRel(tokensOut, expected, 0.002e18, "buy follows the curve");
        assertEq(IERC20(token).balanceOf(buyer), tokensOut);

        // The fee sits in the locked position, in ETH.
        (uint256 ethFees, uint256 tokenFees) = locker.pendingFees(token);
        assertApproxEqAbs(ethFees, 0.01 ether, 1e9, "1% of the buy in ETH");
        assertEq(tokenFees, 0);

        // Sell everything back: 1% of the tokens is the fee and stays in the
        // position, the other 99% go back down the curve. From reserves
        // (P + q, S - T), selling 0.99 T tokens returns
        // (P + q) - P * S / (S - 0.01 T), a little more than 0.99 q because
        // the first tokens sold fetch the highest price.
        uint256 ethBefore = buyer.balance;
        uint256 ethOut = _sellEth(key, token, buyer, tokensOut);
        assertEq(buyer.balance, ethBefore + ethOut);
        uint256 expectedOut = (PHANTOM + netIn) - PHANTOM * SUPPLY / (SUPPLY - tokensOut / 100);
        assertApproxEqRel(ethOut, expectedOut, 0.002e18, "sell follows the curve net of fee");
        (ethFees, tokenFees) = locker.pendingFees(token);
        assertApproxEqAbs(ethFees, 0.01 ether, 1e9);
        assertApproxEqRel(tokenFees, tokensOut / 100, 0.001e18, "1% of the sell in tokens");
    }

    function test_fork_strangerCanSwapAndAddLiquidityFromDayOne() public onlyFork {
        (address token, PoolKey memory key) = _launchNative("open");
        PoolId poolId = key.toId();

        // A raw PoolManager caller in the launch block, no router, no
        // hookData: this is what every terminal's router does.
        probe.swap(key, true, 0.1 ether);
        uint256 got = IERC20(token).balanceOf(address(probe));
        assertApproxEqRel(got, SUPPLY * 0.099 ether / (PHANTOM + 0.099 ether), 0.002e18);

        // And anyone may LP alongside the locked position.
        probe.addLiquidity(key, -887_220, 887_220, 1e12);
        assertEq(manager.getLiquidity(poolId), factory.getLaunchedToken(token).liquidity + 1e12);
    }

    // -------------------------------------------------------------------
    // Fee collection and split
    // -------------------------------------------------------------------

    function test_fork_collectFees_splitsBaseFeeAndPaysTaxToCreator() public onlyFork {
        PairPadLaunchFactory.TokenParams memory p = _params("collect");
        p.creatorTaxBps = 100; // 1% creator tax on top of the 1% base fee: a 2% pool
        vm.prank(creator);
        (address token,) = factory.launchToken(p, 0, address(0));
        PoolKey memory key = factory.poolKeyFor(token);
        assertEq(key.fee, 20_000);
        uint256 dustAtLaunch = IERC20(token).balanceOf(address(locker));

        uint256 tokensOut = _buyEth(key, buyer, 2 ether);
        (uint256 ethFees,) = locker.pendingFees(token);
        assertApproxEqAbs(ethFees, 0.04 ether, 1e9, "2% of 2 ETH");

        // Anyone may trigger the collection.
        uint256 protocolEthBefore = protocolFees.balance;
        vm.prank(other);
        (uint256 got0, uint256 got1) = locker.collectFees(token);
        assertEq(got0, ethFees);
        assertEq(got1, 0);
        (ethFees,) = locker.pendingFees(token);
        assertEq(ethFees, 0);

        // Of the 2%, the base 1% is split in half and the 1% tax is the
        // creator's: protocol 0.5% of the trade, creator 1.5%. The protocol
        // is paid on the spot; the creator's share waits in the escrow.
        assertApproxEqAbs(protocolFees.balance - protocolEthBefore, 0.01 ether, 1e9);
        assertEq(feeEscrow.balanceOf(protocolFees), 0, "protocol has nothing to claim");
        assertApproxEqAbs(feeEscrow.balanceOf(creator), 0.03 ether, 1e9);
        assertEq(address(locker).balance, 0, "locker keeps nothing");

        // Sells pay their fee in the token, split the same way.
        _sellEth(key, token, buyer, tokensOut);
        (, uint256 tokenFees) = locker.pendingFees(token);
        assertApproxEqRel(tokenFees, tokensOut / 50, 0.001e18);
        locker.collectFees(token);
        assertApproxEqRel(IERC20(token).balanceOf(protocolFees), tokensOut / 200, 0.001e18);
        assertEq(feeEscrow.balanceOfToken(protocolFees, token), 0);
        assertApproxEqRel(feeEscrow.balanceOfToken(creator, token), tokensOut * 3 / 200, 0.001e18);
        assertEq(IERC20(token).balanceOf(address(locker)), dustAtLaunch, "locker forwards every collected token");

        // Claims pay out.
        uint256 before = creator.balance;
        vm.prank(creator);
        feeEscrow.claim();
        assertApproxEqAbs(creator.balance, before + 0.03 ether, 1e9);
        vm.prank(creator);
        feeEscrow.claimToken(token);
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    function test_fork_collectFees_nothingToCollectIsANoop() public onlyFork {
        (address token,) = _launchNative("empty");
        (uint256 a, uint256 b) = locker.collectFees(token);
        assertEq(a, 0);
        assertEq(b, 0);
        vm.expectRevert(PairPadLaunchLocker.TokenNotLaunched.selector);
        locker.collectFees(other);
    }

    function test_fork_creatorRecipientChange_redirectsUncollectedFees() public onlyFork {
        (address token, PoolKey memory key) = _launchNative("redirect");
        _buyEth(key, buyer, 1 ether);

        vm.prank(creator);
        factory.transferCreatorFeeRecipient(token, other);
        uint256 protocolEthBefore = protocolFees.balance;
        locker.collectFees(token);

        assertEq(feeEscrow.balanceOf(creator), 0);
        assertApproxEqAbs(feeEscrow.balanceOf(other), 0.005 ether, 1e9);
        assertApproxEqAbs(protocolFees.balance - protocolEthBefore, 0.005 ether, 1e9);
    }

    function test_fork_collectFees_protocolEthFallsBackToEscrowWhenRecipientRejects() public onlyFork {
        // A recipient that cannot take ETH must not block the collection; its
        // share is credited to the escrow instead.
        RejectsEth sink = new RejectsEth();
        factory.setProtocolFeeRecipient(address(sink));
        (address token, PoolKey memory key) = _launchNative("reject");
        _buyEth(key, buyer, 1 ether);

        locker.collectFees(token);
        assertEq(address(sink).balance, 0);
        assertApproxEqAbs(feeEscrow.balanceOf(address(sink)), 0.005 ether, 1e9);
        assertApproxEqAbs(feeEscrow.balanceOf(creator), 0.005 ether, 1e9);
    }

    function test_fork_feePolicyChange_onlyAffectsNewLaunches() public onlyFork {
        (address token,) = _launchNative("before");
        factory.setBaseFeeBps(50);
        factory.setProtocolFeeShareBps(10_000);
        (address token2,) = _launchNative("after");

        assertEq(factory.poolKeyFor(token).fee, 10_000);
        assertEq(factory.getLaunchedToken(token).protocolFeeShareBps, 5_000);
        assertEq(factory.poolKeyFor(token2).fee, 5_000);
        assertEq(factory.getLaunchedToken(token2).baseFeeBps, 50);
        assertEq(factory.getLaunchedToken(token2).protocolFeeShareBps, 10_000);
    }

    // -------------------------------------------------------------------
    // ERC-20 quote (USDG) with the ETH zap
    // -------------------------------------------------------------------

    function test_fork_usdgQuote_pricedEconomicsAndZapRoundTrip() public onlyFork {
        uint256 phantomUsdg = quotePricer.priceEthAmountInQuote(USDG, PHANTOM);
        assertGt(phantomUsdg, 0);

        vm.prank(creator);
        (address token,) = factory.launchToken(_params("usdg"), 0, USDG);
        PoolKey memory key = factory.poolKeyFor(token);
        assertEq(factory.getLaunchedToken(token).phantomQuote, phantomUsdg);

        bool quoteIs0 = Currency.unwrap(key.currency0) == USDG;
        PairPadRouter.EthLeg memory buyLeg =
            PairPadRouter.EthLeg(abi.encodePacked(WETH, uint24(500), USDG), new PoolKey[](0));
        PairPadRouter.EthLeg memory sellLeg =
            PairPadRouter.EthLeg(abi.encodePacked(USDG, uint24(500), WETH), new PoolKey[](0));

        vm.prank(buyer);
        uint256 tokensOut = router.buyWithEth{value: 1 ether}(key, buyLeg, 0, buyer);
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(buyer), tokensOut);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router keeps nothing");

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        uint256 ethOut = router.sellToEth(key, !quoteIs0, tokensOut, sellLeg, 0, buyer);
        vm.stopPrank();
        assertEq(buyer.balance, ethBefore + ethOut);
        // Two V3 hops and two 1% pool fees: still in the right ballpark.
        assertGt(ethOut, 0.95 ether);

        // Fees for an ERC-20 quote come out as that token (buys) and as the
        // launch token (sells).
        (uint256 f0, uint256 f1) = locker.pendingFees(token);
        assertGt(f0, 0);
        assertGt(f1, 0);
        locker.collectFees(token);
        assertGt(feeEscrow.balanceOfToken(creator, USDG), 0);
        assertGt(IERC20(USDG).balanceOf(protocolFees), 0);
        assertGt(feeEscrow.balanceOfToken(creator, token), 0);
        assertGt(IERC20(token).balanceOf(protocolFees), 0);
    }

    function test_fork_launchAndBuyWithEth_atomicOpeningBuy() public onlyFork {
        PairPadRouter.EthLeg memory leg =
            PairPadRouter.EthLeg(abi.encodePacked(WETH, uint24(500), USDG), new PoolKey[](0));

        vm.prank(creator);
        (address token,, uint256 tokensOut) =
            router.launchAndBuyWithEth{value: 1 ether}(_params("zap-launch"), 0, USDG, leg, 0);

        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
        assertEq(factory.getLaunchedToken(token).deployer, creator);
        // 1 ETH of USDG against a 1.3557 ETH phantom reserve buys well over
        // a third of the supply.
        assertGt(tokensOut, 350_000_000 ether);
    }

    function test_fork_launchAndBuy_nativeQuote() public onlyFork {
        vm.prank(creator);
        (address token,, uint256 tokensOut) = router.launchAndBuyWithEth{value: 0.5 ether}(
            _params("zap-native"), 0, address(0), PairPadRouter.EthLeg("", new PoolKey[](0)), 0
        );
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(creator), tokensOut);
        uint256 expected = SUPPLY * 0.495 ether / (PHANTOM + 0.495 ether);
        assertApproxEqRel(tokensOut, expected, 0.002e18);
    }

    // -------------------------------------------------------------------
    // Quote that only trades on V4 (a PONS graduate): ETH leg entirely in V4
    // -------------------------------------------------------------------

    /// @dev The pricer's chosen reference for BLOKKS is a V4 ETH pool; the
    /// same key is the zap's hop, so ETH -> BLOKKS -> token runs in one unlock.
    function _blokksLeg() internal view returns (PairPadRouter.EthLeg memory leg, PoolKey memory ref) {
        (PairPadQuotePricer.Reference memory direct,,) = quotePricer.describe(BLOKKS);
        assertTrue(direct.qualifies, "BLOKKS priceable");
        assertEq(uint8(direct.kind), uint8(PairPadQuotePricer.ReferenceKind.V4));
        assertEq(direct.anchor, address(0), "native ETH anchor");
        ref = direct.v4Key;
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = ref;
        leg = PairPadRouter.EthLeg("", hops);
    }

    function test_fork_v4Quote_launchAndBuyThenRoundTrip() public onlyFork {
        (PairPadRouter.EthLeg memory leg,) = _blokksLeg();

        // Opening buy paid in ETH through the BLOKKS pool, no BLOKKS held.
        assertEq(IERC20(BLOKKS).balanceOf(creator), 0);
        vm.prank(creator);
        (address token,, uint256 opening) =
            router.launchAndBuyWithEth{value: 0.3 ether}(_params("v4-quote"), 0, BLOKKS, leg, 0);
        assertGt(opening, 0);
        assertEq(IERC20(token).balanceOf(creator), opening);
        assertEq(IERC20(BLOKKS).balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(address(router).balance, 0);

        PoolKey memory key = factory.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;

        vm.prank(buyer);
        uint256 tokensOut = router.buyWithEth{value: 0.2 ether}(key, leg, 0, buyer);
        assertGt(tokensOut, 0);

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        IERC20(token).approve(address(router), tokensOut);
        uint256 ethOut = router.sellToEth(key, tokenIs0, tokensOut, leg, 0, buyer);
        vm.stopPrank();
        assertEq(buyer.balance, ethBefore + ethOut);
        // Two BLOKKS-pool fees plus two 1% launch-pool fees and the price
        // impact of a 0.2 ETH trade on both sides.
        assertGt(ethOut, 0.15 ether);
        assertEq(IERC20(BLOKKS).balanceOf(address(router)), 0);
        assertEq(IERC20(BLOKKS).balanceOf(buyer), 0, "buyer never touched the quote");

        // The floor is enforced on the far end of the route.
        vm.prank(buyer);
        vm.expectRevert();
        router.buyWithEth{value: 0.01 ether}(key, leg, type(uint256).max, buyer);
    }

    function test_fork_v4Quote_brokenHopReverts() public onlyFork {
        (, PoolKey memory ref) = _blokksLeg();
        vm.prank(creator);
        (address token,) = factory.launchToken(_params("v4-broken"), 0, BLOKKS);
        PoolKey memory key = factory.poolKeyFor(token);

        // ETH -> BLOKKS -> ETH, then the launch pool has no ETH side.
        PoolKey[] memory hops = new PoolKey[](2);
        hops[0] = ref;
        hops[1] = ref;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PairPadRouter.RouteBroken.selector, 2));
        router.buyWithEth{value: 0.01 ether}(key, PairPadRouter.EthLeg("", hops), 0, buyer);

        // Claiming ETH comes out where BLOKKS does.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PairPadRouter.RouteBroken.selector, 0));
        router.buyWithEth{value: 0.01 ether}(key, PairPadRouter.EthLeg("", new PoolKey[](0)), 0, buyer);
    }
}
