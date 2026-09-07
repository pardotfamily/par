// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadFeeSplitter} from "../src/fees/PairPadFeeSplitter.sol";
import {PairPadHolderVault} from "../src/fees/PairPadHolderVault.sol";
import {PairPadDisperse} from "../src/fees/PairPadDisperse.sol";

/**
 * @notice Deploys the fee-routing add-ons. None of them has an owner; the
 * only follow-up is the factories' owner pointing both factories at the
 * splitter:
 *
 *   cast send <factory> "setProtocolFeeRecipient(address)" <splitter> --private-key <owner>
 *
 * Env: PRIVATE_KEY (deployer), BUYBACK_WALLET (60% of protocol quote),
 * TREASURY (40% plus the launch fees; the fee wallet), DISTRIBUTOR
 * (holder-rewards operator), optional BUYBACK_BPS (default 6000),
 * FEE_ESCROW / FACTORY / MULTI_FACTORY (default mainnet).
 */
contract DeployFees is Script {
    address internal constant RH_FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;
    address internal constant RH_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;
    address internal constant RH_MULTI_FACTORY = 0x3ea29975a79900179F3e1aEF93347Ba4210c29C1;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address buyback = vm.envAddress("BUYBACK_WALLET");
        address treasury = vm.envAddress("TREASURY");
        address distributor = vm.envAddress("DISTRIBUTOR");
        uint16 buybackBps = uint16(vm.envOr("BUYBACK_BPS", uint256(6000)));
        address feeEscrow = vm.envOr("FEE_ESCROW", RH_FEE_ESCROW);
        address factory = vm.envOr("FACTORY", RH_FACTORY);
        address multiFactory = vm.envOr("MULTI_FACTORY", RH_MULTI_FACTORY);

        require(buyback != treasury, "buyback and treasury must differ");
        require(buyback != distributor, "buyback and distributor must differ");

        vm.startBroadcast(deployerKey);
        PairPadFeeSplitter splitter = new PairPadFeeSplitter(buyback, treasury, buybackBps, factory, multiFactory);
        PairPadHolderVault vault = new PairPadHolderVault(IPairPadFeeEscrow(feeEscrow), distributor);
        PairPadDisperse disperse = new PairPadDisperse();
        vm.stopBroadcast();

        console2.log("PairPadFeeSplitter:  ", address(splitter));
        console2.log("PairPadHolderVault:  ", address(vault));
        console2.log("PairPadDisperse:     ", address(disperse));
        console2.log("buyback wallet:      ", buyback);
        console2.log("treasury:            ", treasury);
        console2.log("distributor:         ", distributor);
        console2.log("buyback bps:         ", uint256(buybackBps));
    }
}

/**
 * @notice Deploys only a new splitter (the vault and disperse stay). Used to
 * change the split: deploy, then point both factories at the new address.
 */
contract DeploySplitter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address buyback = vm.envAddress("BUYBACK_WALLET");
        address treasury = vm.envAddress("TREASURY");
        uint16 buybackBps = uint16(vm.envOr("BUYBACK_BPS", uint256(6000)));
        address factory = vm.envOr("FACTORY", 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F);
        address multiFactory = vm.envOr("MULTI_FACTORY", 0x3ea29975a79900179F3e1aEF93347Ba4210c29C1);
        require(buyback != treasury, "buyback and treasury must differ");

        vm.startBroadcast(deployerKey);
        PairPadFeeSplitter splitter = new PairPadFeeSplitter(buyback, treasury, buybackBps, factory, multiFactory);
        vm.stopBroadcast();

        console2.log("PairPadFeeSplitter:  ", address(splitter));
        console2.log("buyback bps:         ", uint256(buybackBps));
        console2.log("factory:             ", factory);
        console2.log("multi factory:       ", multiFactory);
    }
}
