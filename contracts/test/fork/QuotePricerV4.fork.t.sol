// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../../src/v2/PairPadQuotePricer.sol";
import {PonsReferenceRegistry, IPonsV2LaunchFactory} from "../../src/v2/PairPadReferenceRegistries.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @notice The pricer against real PONS graduates on a Robinhood Chain
 * mainnet fork. VOXEL trades only on Uniswap V4 (native ETH pool with the
 * PONS hook); PONS itself is quoted in USDG. Neither needs registering: the
 * PONS registry adapter reads their pool terms from the PONS factory. Run:
 *
 *   forge test --match-path "test/fork/QuotePricerV4*" --fork-url robinhood -vv
 */
contract QuotePricerV4ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant VOXEL = 0xA01Bc586CD5F4f253BfAB4e44400c52dbC18bC50;

    PairPadQuotePricer pricer;

    function setUp() public {
        if (block.chainid != 4663) return;
        pricer = new PairPadQuotePricer(
            address(this), IUniswapV3FactoryMinimal(V3_FACTORY), WETH, USDG, IPoolManager(POOL_MANAGER)
        );
        pricer.setV4HookAllowed(PONS_HOOK, true);
        pricer.addRegistry(new PonsReferenceRegistry(IPonsV2LaunchFactory(PONS_FACTORY), IHooks(PONS_HOOK)));
    }

    function test_ponsGraduate_pricedThroughRegistry_noRegistration() public {
        if (block.chainid != 4663) return;

        PairPadQuotePricer.PathReport memory rep = pricer.describe(VOXEL);
        assertEq(rep.hops.length, 1);
        PairPadQuotePricer.HopReport memory direct = rep.hops[0];
        assertFalse(direct.hop.v3);
        assertEq(direct.tokenOut, address(0));
        assertEq(Currency.unwrap(direct.hop.key.currency1), VOXEL);
        assertEq(address(direct.hop.key.hooks), PONS_HOOK);
        console2.log("VOXEL/ETH in-range ETH depth (wei):", direct.depth);
        console2.log("floor (wei):", direct.floor);

        if (!rep.qualifies) {
            console2.log("VOXEL pool under the floor at this block; checking the revert path only");
            assertFalse(pricer.isPriceable(VOXEL));
            return;
        }
        assertTrue(pricer.isPriceable(VOXEL));

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(direct.hop.key.toId());
        uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        uint256 spot = FullMath.mulDiv(ratioX192, 4.2 ether, 1 << 192);
        uint256 phantom = pricer.quoteEconomics(VOXEL, 1.3557 ether);
        uint256 fourPointTwo = pricer.priceEthAmountInQuote(VOXEL, 4.2 ether);
        console2.log("4.2 ETH in VOXEL:", fourPointTwo);
        assertEq(fourPointTwo, spot);
        assertApproxEqRel(phantom * 42, fourPointTwo * 13557 / 1000, 0.0001e18);
    }

    function test_usdgLeg_fromV3() public {
        if (block.chainid != 4663) return;
        PairPadQuotePricer.PathReport memory rep = pricer.describe(USDG);
        assertEq(rep.hops.length, 1);
        console2.log("USDG/ETH reference is V3:", rep.hops[0].hop.v3);
        console2.log("USDG/ETH anchor depth (wei):", rep.hops[0].depth);
        if (rep.qualifies) {
            uint256 usdgFor1Eth = pricer.priceEthAmountInQuote(USDG, 1 ether);
            console2.log("1 ETH in USDG (6 dp):", usdgFor1Eth);
            assertGt(usdgFor1Eth, 500e6);
            assertLt(usdgFor1Eth, 20_000e6);
        }
    }
}
