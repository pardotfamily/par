// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PairPadHookRegistry} from "../src/hook/PairPadHookRegistry.sol";
import {PairPadQuoteFeeHook} from "../src/hook/PairPadQuoteFeeHook.sol";
import {HookTestRouter} from "../test/utils/HookTestRouter.sol";

/// @dev Throwaway token for the review pool. Whole supply to the deployer.
contract PairPadHookTestToken is ERC20 {
    constructor() ERC20("par hook test", "PHT") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/**
 * @notice Opens the pool Uniswap's allowlist review asks for: a hooked pool
 * with a little liquidity and one swap through it, on each chain. The
 * deployer is allowed as a factory only for the duration of the script.
 *
 * Env:  PRIVATE_KEY, REGISTRY, HOOK, QUOTE (0x0 for native), QUOTE_AMOUNT (raw units
 *       of quote to seed, e.g. 2000000000000000 = 0.002 ETH, 5000000 = 5 USDC),
 *       PROTOCOL (protocol fee recipient)
 */
contract HookTestPool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        PairPadHookRegistry registry = PairPadHookRegistry(vm.envAddress("REGISTRY"));
        PairPadQuoteFeeHook hook = PairPadQuoteFeeHook(payable(vm.envAddress("HOOK")));
        Currency quote = Currency.wrap(vm.envAddress("QUOTE"));
        uint256 quoteAmount = vm.envUint("QUOTE_AMOUNT");
        address protocol = vm.envAddress("PROTOCOL");
        IPoolManager manager = IPoolManager(registry.poolManager());

        vm.startBroadcast(pk);
        HookTestRouter router = new HookTestRouter(manager);
        PairPadHookTestToken token = new PairPadHookTestToken();
        Currency tok = Currency.wrap(address(token));
        (Currency c0, Currency c1) = quote < tok ? (quote, tok) : (tok, quote);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))});

        registry.setFactory(deployer, true);
        hook.register(
            key,
            PairPadQuoteFeeHook.PoolConfig({
                quote: quote, feeBps: 100, protocolShareBps: 5_000, creator: deployer, protocol: protocol
            })
        );
        // 1:1 price; at full range the seeded amounts of both sides ~= liquidity.
        manager.initialize(key, 2 ** 96);
        registry.setFactory(deployer, false);

        token.approve(address(router), type(uint256).max);
        if (!quote.isAddressZero()) IERC20(Currency.unwrap(quote)).approve(address(router), type(uint256).max);
        uint256 value = quote.isAddressZero() ? quoteAmount + quoteAmount / 100 : 0;
        router.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(quoteAmount), salt: 0
            })
        );

        // One swap each way so the review can see the fee taken in quote on
        // both a buy and a sell, then a collect.
        bool quoteIs0 = quote == c0;
        uint256 buyIn = quoteAmount / 20;
        router.swap{value: quote.isAddressZero() ? buyIn : 0}(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        router.swap(
            key,
            SwapParams({
                zeroForOne: !quoteIs0,
                amountSpecified: -int256(buyIn / 2),
                sqrtPriceLimitX96: !quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        uint256 accrued = hook.accrued(key.toId());
        (uint256 p, uint256 c) = hook.collect(key);
        vm.stopBroadcast();

        console2.log("chain id:        ", block.chainid);
        console2.log("test token:      ", address(token));
        console2.log("test router:     ", address(router));
        console2.log("quote:           ", Currency.unwrap(quote));
        console2.log("pool id:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("fee accrued (quote raw):", accrued);
        console2.log("collected protocol/creator:", p, c);
        console2.log("deployer still factory?", registry.isFactory(deployer));
    }
}
