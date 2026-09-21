// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadHookRegistry} from "../../src/hook/PairPadHookRegistry.sol";
import {PairPadQuoteFeeHook, IPairPadHookRegistry} from "../../src/hook/PairPadQuoteFeeHook.sol";
import {HookTestRouter} from "../utils/HookTestRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @dev Runs against a live PoolManager: `forge test --fork-url <rpc>
 * --match-contract QuoteFeeHook`. POOL_MANAGER in the env overrides the
 * Robinhood Chain default so the same file covers Base, BNB and Arc.
 */
contract QuoteFeeHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint16 constant FEE_BPS = 100; // 1%
    uint16 constant PROTOCOL_SHARE_BPS = 5_000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;

    IPoolManager manager;
    PairPadFeeEscrow escrow;
    PairPadHookRegistry registry;
    PairPadQuoteFeeHook hook;
    HookTestRouter router;
    MockERC20 token;
    MockERC20 usd;

    address creator = makeAddr("creator");
    address protocol = makeAddr("protocol");
    address trader = makeAddr("trader");

    PoolKey ethKey; // quote = native
    PoolKey usdKey; // quote = ERC-20

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(vm.envOr("POOL_MANAGER", address(0x8366a39CC670B4001A1121B8F6A443A643e40951)));
        escrow = new PairPadFeeEscrow();
        registry = new PairPadHookRegistry(address(this));
        registry.configure(address(manager), address(escrow));
        hook = _deployHook();
        router = new HookTestRouter(manager);
        registry.setFactory(address(this), true);

        token = new MockERC20("Launch", "LNCH", 18);
        usd = new MockERC20("Dollar", "USD", 6);
        token.mint(address(this), 1e30);
        usd.mint(address(this), 1e30);
        token.approve(address(router), type(uint256).max);
        usd.approve(address(router), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        ethKey = _key(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)));
        _open(ethKey, CurrencyLibrary.ADDRESS_ZERO, 1e21);

        usdKey = _key(Currency.wrap(address(usd)), Currency.wrap(address(token)));
        _open(usdKey, Currency.wrap(address(usd)), 1e21);

        vm.deal(trader, 1_000 ether);
        token.mint(trader, 1e24);
        usd.mint(trader, 1e15);
        vm.startPrank(trader);
        token.approve(address(router), type(uint256).max);
        usd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- native quote

    function test_buyExactIn_feeOnQuoteInput() public {
        uint256 amountIn = 1 ether;
        uint256 tokenBefore = token.balanceOf(trader);
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap{value: amountIn}(ethKey, _swap(true, -int256(amountIn)));
        assertEq(ethBefore - trader.balance, amountIn, "pays exactly amountIn");
        assertGt(token.balanceOf(trader) - tokenBefore, 0, "receives tokens");
        assertEq(hook.accrued(ethKey.toId()), amountIn * FEE_BPS / 10_000, "1% of quote in");
        assertEq(address(hook).balance, 0, "hook holds no ETH; fee is a claim");
    }

    function test_buyExactOut_feeOnQuoteUnspecified() public {
        uint256 want = 1e20;
        uint256 tokenBefore = token.balanceOf(trader);
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap{value: 200 ether}(ethKey, _swap(true, int256(want)));
        assertEq(token.balanceOf(trader) - tokenBefore, want, "receives exactly want");
        uint256 paid = ethBefore - trader.balance;
        uint256 fee = hook.accrued(ethKey.toId());
        // paid = pool amount + fee, fee = 1% of pool amount (rounded down).
        assertApproxEqAbs(fee, (paid - fee) * FEE_BPS / 10_000, 1, "1% of quote paid to the pool");
        assertGt(fee, 0);
    }

    function test_sellExactIn_feeOnQuoteOutput() public {
        uint256 amountIn = 1e20;
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap(ethKey, _swap(false, -int256(amountIn)));
        uint256 received = trader.balance - ethBefore;
        uint256 fee = hook.accrued(ethKey.toId());
        assertGt(received, 0);
        assertApproxEqAbs(fee, (received + fee) * FEE_BPS / 10_000, 1, "1% of quote out of the pool");
        assertEq(token.balanceOf(address(hook)), 0, "no token-side fee");
    }

    function test_sellExactOut_feeOnQuoteSpecified() public {
        uint256 want = 0.5 ether;
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        router.swap(ethKey, _swap(false, int256(want)));
        assertEq(trader.balance - ethBefore, want, "receives exactly want");
        assertEq(hook.accrued(ethKey.toId()), want * FEE_BPS / 10_000, "1% of quote out");
    }

    function test_collect_splitsProtocolAndCreator_native() public {
        vm.prank(trader);
        router.swap{value: 2 ether}(ethKey, _swap(true, -2 ether));
        uint256 fee = hook.accrued(ethKey.toId());
        assertEq(fee, 0.02 ether);
        uint256 protocolBefore = protocol.balance;
        (uint256 p, uint256 c) = hook.collect(ethKey);
        assertEq(p, fee / 2);
        assertEq(c, fee - p);
        assertEq(protocol.balance - protocolBefore, p, "protocol paid directly");
        assertEq(escrow.balanceOf(creator), c, "creator credited in escrow");
        assertEq(hook.accrued(ethKey.toId()), 0);
        vm.prank(creator);
        assertEq(escrow.claim(), c);
    }

    // -------------------------------------------------------------- ERC-20 quote

    function test_erc20Quote_buyAndSell_thenCollect() public {
        PoolId id = usdKey.toId();
        bool usdIs0 = usdKey.currency0 == Currency.wrap(address(usd));

        uint256 buyIn = 1e9; // 1,000 USD
        uint256 usdBefore = usd.balanceOf(trader);
        vm.prank(trader);
        router.swap(usdKey, _swap(usdIs0, -int256(buyIn)));
        assertEq(usdBefore - usd.balanceOf(trader), buyIn);
        assertEq(hook.accrued(id), buyIn * FEE_BPS / 10_000, "buy fee in USD");

        uint256 sellIn = 1e19;
        usdBefore = usd.balanceOf(trader);
        uint256 accruedBefore = hook.accrued(id);
        vm.prank(trader);
        router.swap(usdKey, _swap(!usdIs0, -int256(sellIn)));
        uint256 received = usd.balanceOf(trader) - usdBefore;
        uint256 sellFee = hook.accrued(id) - accruedBefore;
        assertGt(received, 0);
        assertApproxEqAbs(sellFee, (received + sellFee) * FEE_BPS / 10_000, 1, "sell fee in USD, none in token");
        assertEq(token.balanceOf(address(hook)), 0);

        uint256 total = hook.accrued(id);
        (uint256 p, uint256 c) = hook.collect(usdKey);
        assertEq(p + c, total);
        assertEq(usd.balanceOf(protocol), p);
        assertEq(escrow.balanceOfToken(creator, address(usd)), c);
        vm.prank(creator);
        assertEq(escrow.claimToken(address(usd)), c);
    }

    // ------------------------------------------------------------------ gating

    function test_register_rejectsNonFactory() public {
        PoolKey memory k = _key(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usd)));
        vm.prank(trader);
        vm.expectRevert(PairPadQuoteFeeHook.NotFactory.selector);
        hook.register(k, _cfg(CurrencyLibrary.ADDRESS_ZERO));
    }

    function test_initialize_rejectsUnregisteredPool() public {
        PoolKey memory k = _key(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usd)));
        vm.expectRevert();
        manager.initialize(k, 2 ** 96);
    }

    function test_initialize_rejectsNonFactorySender() public {
        PoolKey memory k = _key(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usd)));
        hook.register(k, _cfg(CurrencyLibrary.ADDRESS_ZERO));
        vm.prank(trader);
        vm.expectRevert();
        manager.initialize(k, 2 ** 96);
    }

    function test_register_rejectsDuplicateAndBadConfig() public {
        vm.expectRevert(PairPadQuoteFeeHook.AlreadyRegistered.selector);
        hook.register(ethKey, _cfg(CurrencyLibrary.ADDRESS_ZERO));

        PoolKey memory k = _key(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usd)));
        PairPadQuoteFeeHook.PoolConfig memory bad = _cfg(Currency.wrap(address(token)));
        vm.expectRevert(PairPadQuoteFeeHook.QuoteNotInPool.selector);
        hook.register(k, bad);

        bad = _cfg(CurrencyLibrary.ADDRESS_ZERO);
        bad.feeBps = 2_001;
        vm.expectRevert(PairPadQuoteFeeHook.FeeTooHigh.selector);
        hook.register(k, bad);
    }

    function test_hookAddressEncodesFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    // ----------------------------------------------------------------- helpers

    function _deployHook() private returns (PairPadQuoteFeeHook h) {
        bytes memory initCode =
            abi.encodePacked(type(PairPadQuoteFeeHook).creationCode, abi.encode(IPairPadHookRegistry(address(registry))));
        bytes32 initHash = keccak256(initCode);
        for (uint256 i = 0;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, address(this));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) {
                h = new PairPadQuoteFeeHook{salt: salt}(IPairPadHookRegistry(address(registry)));
                assertEq(address(h), predicted);
                return h;
            }
        }
    }

    function _key(Currency a, Currency b) private view returns (PoolKey memory) {
        (Currency c0, Currency c1) = a < b ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});
    }

    function _cfg(Currency quote) private view returns (PairPadQuoteFeeHook.PoolConfig memory) {
        return PairPadQuoteFeeHook.PoolConfig({
            quote: quote, feeBps: FEE_BPS, protocolShareBps: PROTOCOL_SHARE_BPS, creator: creator, protocol: protocol
        });
    }

    function _open(PoolKey memory key, Currency quote, int256 liquidity) private {
        hook.register(key, _cfg(quote));
        manager.initialize(key, 2 ** 96);
        uint256 value = key.currency0.isAddressZero() || key.currency1.isAddressZero() ? 5_000 ether : 0;
        router.modifyLiquidity{value: value}(
            key, ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity, salt: 0})
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }
}
