// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../src/v2/PairPadQuotePricer.sol";
import {
    PairPadReferenceRegistry,
    PonsReferenceRegistry,
    IPairPadFactoryPoolKeys,
    IPonsV2LaunchFactory
} from "../src/v2/PairPadReferenceRegistries.sol";
import {PairPadLaunchLocker} from "../src/v2/PairPadLaunchLocker.sol";
import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadPositionMinter} from "../src/v2/PairPadPositionMinter.sol";
import {PairPadLaunchDeployer} from "../src/v2/PairPadLaunchDeployer.sol";
import {PairPadRouter, ISwapRouter02, IWETH9} from "../src/v2/PairPadRouter.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";

/**
 * @notice Deploys and wires the full PairPad stack against an existing
 * Uniswap deployment. Reads external addresses from the environment, with
 * Robinhood Chain mainnet (4663) canonical values as defaults.
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    // Canonical Robinhood Chain mainnet (4663) addresses.
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant RH_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant RH_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev PONS launchpad hook; every PONS graduate's V4 pool carries it.
    address internal constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    /// @dev PONS V2 factory; getLaunchedToken gives a PONS token's pool terms.
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        address poolManager = vm.envOr("POOL_MANAGER", RH_POOL_MANAGER);
        address positionManager = vm.envOr("POSITION_MANAGER", RH_POSITION_MANAGER);
        address permit2 = vm.envOr("PERMIT2", RH_PERMIT2);
        address v3Factory = vm.envOr("V3_FACTORY", RH_V3_FACTORY);
        address swapRouter02 = vm.envOr("SWAP_ROUTER_02", RH_SWAP_ROUTER_02);
        address weth = vm.envOr("WETH", RH_WETH);
        address usdg = vm.envOr("USDG", RH_USDG);
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", owner);
        uint256 launchFee = vm.envOr("LAUNCH_FEE", uint256(0.0005 ether));

        if (block.chainid == 4663) {
            require(poolManager == RH_POOL_MANAGER, "mainnet: POOL_MANAGER override");
            require(positionManager == RH_POSITION_MANAGER, "mainnet: POSITION_MANAGER override");
            require(v3Factory == RH_V3_FACTORY, "mainnet: V3_FACTORY override");
            require(swapRouter02 == RH_SWAP_ROUTER_02, "mainnet: SWAP_ROUTER_02 override");
            require(weth == RH_WETH, "mainnet: WETH override");
            require(usdg == RH_USDG, "mainnet: USDG override");
        }

        vm.startBroadcast(deployerKey);

        // 1. Shared claimable-fee ledger.
        PairPadFeeEscrow feeEscrow = new PairPadFeeEscrow();

        // 2. Spot pricer for permissionless quote assets (V3 pools, hookless
        //    V4 pools, and V4 pools found through launchpad registries).
        PairPadQuotePricer quotePricer = new PairPadQuotePricer(
            owner, IUniswapV3FactoryMinimal(v3Factory), weth, usdg, IPoolManager(poolManager)
        );
        if (block.chainid == 4663) {
            quotePricer.setV4HookAllowed(PONS_HOOK, true);
            quotePricer.addRegistry(
                new PonsReferenceRegistry(IPonsV2LaunchFactory(PONS_FACTORY), IHooks(PONS_HOOK))
            );
        }

        // 3. Permanent position locker, which also collects the LP fees.
        PairPadLaunchLocker locker =
            new PairPadLaunchLocker(owner, IPositionManager(positionManager), IPairPadFeeEscrow(address(feeEscrow)));

        // 4. The factory itself.
        PairPadLaunchFactory factory = new PairPadLaunchFactory(
            owner,
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            locker,
            IPairPadFeeEscrow(address(feeEscrow)),
            quotePricer,
            protocolFeeRecipient,
            launchFee
        );

        // 5. Post-factory helpers.
        PairPadPositionMinter minter = new PairPadPositionMinter(
            IPositionManager(positionManager), IAllowanceTransfer(permit2), locker, address(factory)
        );
        PairPadLaunchDeployer launchDeployer = new PairPadLaunchDeployer(address(factory));
        PairPadRouter router =
            new PairPadRouter(IPoolManager(poolManager), factory, ISwapRouter02(swapRouter02), IWETH9(weth));

        // 6. Wiring. Our own launches are hookless pools, which the pricer
        //    accepts by default, so they may serve as quotes for later launches.
        quotePricer.addRegistry(new PairPadReferenceRegistry(IPairPadFactoryPoolKeys(address(factory))));
        locker.setFactory(address(factory));
        factory.setPositionMinter(minter);
        factory.setLaunchDeployer(launchDeployer);
        factory.setLaunchForwarder(address(router));

        // 7. Canonical launch config: 1B supply, 1.3557 ETH phantom reserve,
        //    which is the opening market cap. Tick spacing 10 keeps the
        //    opening price within 0.05% of the configured one.
        factory.addLaunchConfig(
            PairPadLaunchFactory.LaunchConfig({
                supply: 1_000_000_000 ether, phantomQuote: 1.3557 ether, tickSpacing: 10, enabled: true
            })
        );
        factory.setLaunchEnabled(true);

        // 8. Optional ownership handover for mainnet: when FINAL_OWNER is a
        //    multisig, start the two-step transfer on every owned contract.
        address finalOwner = vm.envOr("FINAL_OWNER", owner);
        if (finalOwner != owner) {
            factory.transferOwnership(finalOwner);
            quotePricer.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
            console2.log("Ownership transfer started to:", finalOwner);
            console2.log("FINAL_OWNER must call acceptOwnership() on factory, pricer, locker.");
        }

        vm.stopBroadcast();

        console2.log("PairPadFeeEscrow:        ", address(feeEscrow));
        console2.log("PairPadQuotePricer:      ", address(quotePricer));
        console2.log("PairPadLaunchLocker:     ", address(locker));
        console2.log("PairPadLaunchFactory:    ", address(factory));
        console2.log("PairPadPositionMinter:   ", address(minter));
        console2.log("PairPadLaunchDeployer:   ", address(launchDeployer));
        console2.log("PairPadRouter:           ", address(router));
    }
}
