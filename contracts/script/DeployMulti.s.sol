// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadLaunchDeployer} from "../src/v2/PairPadLaunchDeployer.sol";
import {ISwapRouter02, IWETH9} from "../src/v2/PairPadRouter.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadMultiLaunchLocker} from "../src/v3/PairPadMultiLaunchLocker.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiPositionMinter} from "../src/v3/PairPadMultiPositionMinter.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";
import {PairPadMultiReferenceRegistry} from "../src/v3/PairPadMultiReferenceRegistry.sol";
import {IPairPadMultiLaunchFactory} from "../src/v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice Deploys the multi-market launch stack beside the existing v2 stack.
 * Reuses the live PairPadFeeEscrow and PairPadQuotePricer (FEE_ESCROW and
 * QUOTE_PRICER, defaulting to the Robinhood Chain mainnet deployment);
 * everything else (locker, factory, minter, deployer, router, registry) is
 * new and wired to itself only. Nothing here touches the v2 contracts.
 *
 * The registry that lets multi-market tokens serve as quotes must be added to
 * the pricer by the pricer's owner afterwards (`quotePricer.addRegistry`);
 * it is deployed and printed here, not added.
 *
 * Usage:
 *   forge script script/DeployMulti.s.sol --rpc-url $RPC_URL --broadcast
 */
contract DeployMulti is Script {
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant RH_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant RH_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev Live v2 deployment on Robinhood Chain mainnet.
    address internal constant RH_FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;
    address internal constant RH_QUOTE_PRICER = 0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        address poolManager = vm.envOr("POOL_MANAGER", RH_POOL_MANAGER);
        address positionManager = vm.envOr("POSITION_MANAGER", RH_POSITION_MANAGER);
        address permit2 = vm.envOr("PERMIT2", RH_PERMIT2);
        address swapRouter02 = vm.envOr("SWAP_ROUTER_02", RH_SWAP_ROUTER_02);
        address weth = vm.envOr("WETH", RH_WETH);
        address feeEscrow = vm.envOr("FEE_ESCROW", RH_FEE_ESCROW);
        address quotePricer = vm.envOr("QUOTE_PRICER", RH_QUOTE_PRICER);
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", owner);
        uint256 launchFee = vm.envOr("LAUNCH_FEE", uint256(0.0005 ether));
        // Same curve as v2's config 0: 1B supply, 1.3557 ETH opening cap.
        uint256 supply = vm.envOr("LAUNCH_SUPPLY", uint256(1_000_000_000 ether));
        uint256 phantom = vm.envOr("LAUNCH_PHANTOM", uint256(1.3557 ether));

        if (block.chainid == 4663) {
            require(poolManager == RH_POOL_MANAGER, "mainnet: POOL_MANAGER override");
            require(positionManager == RH_POSITION_MANAGER, "mainnet: POSITION_MANAGER override");
            require(swapRouter02 == RH_SWAP_ROUTER_02, "mainnet: SWAP_ROUTER_02 override");
            require(weth == RH_WETH, "mainnet: WETH override");
            require(feeEscrow == RH_FEE_ESCROW, "mainnet: FEE_ESCROW override");
            require(quotePricer == RH_QUOTE_PRICER, "mainnet: QUOTE_PRICER override");
        }

        vm.startBroadcast(deployerKey);

        PairPadMultiLaunchLocker locker =
            new PairPadMultiLaunchLocker(owner, IPositionManager(positionManager), IPairPadFeeEscrow(feeEscrow));

        PairPadMultiLaunchFactory factory = new PairPadMultiLaunchFactory(
            owner,
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            locker,
            IPairPadFeeEscrow(feeEscrow),
            PairPadQuotePricer(quotePricer),
            weth,
            protocolFeeRecipient,
            launchFee
        );

        PairPadMultiPositionMinter minter = new PairPadMultiPositionMinter(
            IPositionManager(positionManager), IAllowanceTransfer(permit2), address(locker), address(factory)
        );
        PairPadLaunchDeployer launchDeployer = new PairPadLaunchDeployer(address(factory));
        PairPadMultiRouter router =
            new PairPadMultiRouter(IPoolManager(poolManager), factory, ISwapRouter02(swapRouter02), IWETH9(weth));
        PairPadMultiReferenceRegistry registry =
            new PairPadMultiReferenceRegistry(IPairPadMultiLaunchFactory(address(factory)));

        locker.setFactory(address(factory));
        factory.setPositionMinter(minter);
        factory.setLaunchDeployer(launchDeployer);
        factory.setLaunchForwarder(address(router));
        factory.addLaunchConfig(
            PairPadMultiLaunchFactory.LaunchConfig({supply: supply, phantomQuote: phantom, tickSpacing: 10, enabled: true})
        );
        // Closed to the public until the interface ships; the owner may
        // whitelist test launchers meanwhile.
        factory.setLaunchEnabled(vm.envOr("LAUNCH_ENABLED", false));

        address finalOwner = vm.envOr("FINAL_OWNER", owner);
        if (finalOwner != owner) {
            factory.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
            console2.log("Ownership transfer started to:", finalOwner);
            console2.log("FINAL_OWNER must call acceptOwnership() on factory and locker.");
        }

        vm.stopBroadcast();

        console2.log("PairPadMultiLaunchLocker:      ", address(locker));
        console2.log("PairPadMultiLaunchFactory:     ", address(factory));
        console2.log("PairPadMultiPositionMinter:    ", address(minter));
        console2.log("PairPadLaunchDeployer (multi): ", address(launchDeployer));
        console2.log("PairPadMultiRouter:            ", address(router));
        console2.log("PairPadMultiReferenceRegistry: ", address(registry));
        console2.log("Pricer owner still has to: quotePricer.addRegistry(registry)");
    }
}
