// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hop} from "../src/v2/libraries/Hop.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiLaunchLocker} from "../src/v3/PairPadMultiLaunchLocker.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";

/**
 * @notice End-to-end smoke of a deployed Arc stack: launch a token quoted in
 * the reference ERC-20 (USDC), buy it with USDC, sell part of it back, and
 * report the fees the market earned. Nothing here touches native USDC except
 * the launch fee and gas.
 *
 *   MULTI_FACTORY, MULTI_ROUTER, MULTI_LOCKER   deployed addresses
 *   SPEND                                        USDC to spend, 6-dec (default 5 USDC)
 *   TOKEN                                        optional: skip the launch, trade this one
 */
contract SmokeArc is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(vm.envAddress("MULTI_FACTORY"));
        PairPadMultiRouter router = PairPadMultiRouter(payable(vm.envAddress("MULTI_ROUTER")));
        PairPadMultiLaunchLocker locker = PairPadMultiLaunchLocker(payable(vm.envAddress("MULTI_LOCKER")));
        address ref = factory.weth();
        uint256 spend = vm.envOr("SPEND", uint256(5e6));

        console.log("chain", block.chainid);
        console.log("deployer", me);
        console.log("reference", ref);
        console.log("ref balance before", IERC20(ref).balanceOf(me));
        console.log("native balance before", me.balance);

        vm.startBroadcast(pk);

        address token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) {
            address[] memory pair = new address[](1);
            pair[0] = ref;
            token = factory.launchToken{value: factory.launchFee()}(
                PairPadMultiLaunchFactory.TokenParams({
                    name: "Arc Smoke",
                    symbol: "SMOKE",
                    logo: "",
                    description: "par on arc testnet smoke",
                    socials: PairPadLauncherToken.Socials("", "", "", "", ""),
                    creatorFeeRecipient: me,
                    creatorTaxBps: 0,
                    expectedEconomics: bytes32(0),
                    salt: keccak256(abi.encode("arc-smoke", block.timestamp))
                }),
                0,
                pair
            );
        }
        console.log("token", token);

        // Forge's EVM cannot execute Arc's blocklist precompile, which the
        // USDC predeploy consults on transferFrom; with LAUNCH_ONLY the trades
        // are left to `cast send`, which lets the node do the estimating.
        if (vm.envOr("LAUNCH_ONLY", false)) {
            vm.stopBroadcast();
            return;
        }

        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](1);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: new Hop[](0), amountIn: spend});

        IERC20(ref).approve(address(router), spend);
        uint256 tokensOut = router.buyWithReference(token, legs, spend, 0, me);
        console.log("tokens bought", tokensOut);

        uint256 sellAmt = tokensOut / 2;
        legs[0].amountIn = sellAmt;
        IERC20(token).approve(address(router), sellAmt);
        uint256 refOut = router.sellToReference(token, legs, 0, me);
        console.log("ref received for half", refOut);

        vm.stopBroadcast();

        console.log("token balance after", IERC20(token).balanceOf(me));
        console.log("ref balance after", IERC20(ref).balanceOf(me));
        console.log("native balance after", me.balance);
        (uint256[] memory f0, uint256[] memory f1) = locker.pendingFeesAll(token);
        console.log("pending fees market0: c0", f0[0]);
        console.log("pending fees market0: c1", f1[0]);
    }
}
