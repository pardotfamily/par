// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {CreatorAccountFactory} from "../src/creator/CreatorAccountFactory.sol";

/**
 * @notice Deploys CreatorAccountFactory through the canonical CREATE2
 * deployer so it has the same address on every chain, which in turn makes
 * every social account's address the same on every chain.
 *
 * Env:  PRIVATE_KEY (factory owner), ATTESTER (address of the attestation signer)
 */
contract DeployCreatorAccounts is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = keccak256("par.creator.factory.v2");

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address attester = vm.envAddress("ATTESTER");
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 deployer");

        bytes memory initCode = abi.encodePacked(type(CreatorAccountFactory).creationCode, abi.encode(owner, attester));
        address predicted = vm.computeCreate2Address(SALT, keccak256(initCode), CREATE2_DEPLOYER);

        if (predicted.code.length == 0) {
            vm.startBroadcast(pk);
            (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initCode));
            vm.stopBroadcast();
            require(ok && predicted.code.length != 0, "create2 failed");
        } else {
            console2.log("already deployed");
        }
        CreatorAccountFactory f = CreatorAccountFactory(predicted);
        require(f.attester() == attester && f.owner() == owner, "config mismatch");

        console2.log("chain id:               ", block.chainid);
        console2.log("CreatorAccountFactory:  ", predicted);
        console2.log("owner:                  ", owner);
        console2.log("attester:               ", attester);
        console2.log("example x:pardotfamily: ", f.accountFor("x", "2095190242215034887"));
    }
}
