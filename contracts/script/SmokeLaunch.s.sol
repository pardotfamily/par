// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadLaunchLocker} from "../src/v2/PairPadLaunchLocker.sol";
import {PairPadRouter} from "../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";

/**
 * @notice Live smoke test of a deployed stack: launch a token on the given
 * config with an opening buy, buy again, sell part of it back, and print the
 * fees the locked position has earned. Costs the launch fee plus the small
 * amounts below.
 *
 *   FACTORY=... ROUTER=... CONFIG_ID=0 forge script script/SmokeLaunch.s.sol --rpc-url ... --broadcast
 */
contract SmokeLaunch is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadLaunchFactory factory = PairPadLaunchFactory(payable(vm.envAddress("FACTORY")));
        PairPadRouter router = PairPadRouter(payable(vm.envAddress("ROUTER")));
        PairPadLaunchLocker locker = factory.locker();
        uint256 configId = vm.envOr("CONFIG_ID", uint256(0));
        uint256 openingBuy = vm.envOr("OPENING_BUY", uint256(0.0002 ether));
        uint256 secondBuy = vm.envOr("SECOND_BUY", uint256(0.0002 ether));

        PairPadLaunchFactory.TokenParams memory params = PairPadLaunchFactory.TokenParams({
            name: vm.envOr("TOKEN_NAME", string("Smoke Test")),
            symbol: vm.envOr("TOKEN_SYMBOL", string("SMOKE")),
            logo: vm.envOr("TOKEN_LOGO", string("")),
            description: vm.envOr("TOKEN_DESCRIPTION", string("Live smoke test of the launch flow.")),
            socials: PairPadLauncherToken.Socials({
                twitter: vm.envOr("TOKEN_TWITTER", string("")),
                telegram: vm.envOr("TOKEN_TELEGRAM", string("")),
                discord: vm.envOr("TOKEN_DISCORD", string("")),
                website: vm.envOr("TOKEN_WEBSITE", string("")),
                farcaster: vm.envOr("TOKEN_FARCASTER", string(""))
            }),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode("smoke", block.timestamp))
        });

        vm.startBroadcast(key);

        uint256 launchFee = factory.launchFee();
        (address token, PoolId poolId, uint256 openingOut) = router.launchAndBuyWithEth{
            value: launchFee + openingBuy
        }(params, configId, address(0), PairPadRouter.EthLeg("", new PoolKey[](0)), 0);
        console2.log("token:        ", token);
        console2.log("poolId:       ", vm.toString(PoolId.unwrap(poolId)));
        console2.log("opening buy tokens out:", openingOut);

        PoolKey memory poolKey = factory.poolKeyFor(token);
        uint256 out2 = router.swapExactIn{value: secondBuy}(poolKey, true, secondBuy, 0, me);
        console2.log("second buy tokens out: ", out2);

        uint256 sellAmount = out2 / 2;
        IERC20(token).approve(address(router), sellAmount);
        uint256 ethOut = router.swapExactIn(poolKey, false, sellAmount, 0, me);
        console2.log("sold half of second buy, ETH out:", ethOut);

        vm.stopBroadcast();

        (uint256 fees0, uint256 fees1) = locker.pendingFees(token);
        console2.log("pool fee (pips):", poolKey.fee);
        console2.log("pending fees currency0 / currency1:", fees0, fees1);
        console2.log("my token balance:", IERC20(token).balanceOf(me));
    }
}
