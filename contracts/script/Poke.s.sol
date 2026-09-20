// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadRouter} from "../src/v2/PairPadRouter.sol";

/**
 * @notice Trades a little in each listed reference-quoted launch (buy, then
 * sell half) so fees accrue for the keeper and the vaults to work on.
 *
 *   PRIVATE_KEY=... FACTORY=... ROUTER=... TOKENS=0xa,0xb BUY=200000000000000 \
 *   forge script script/Poke.s.sol --rpc-url ... --broadcast
 */
contract Poke is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadLaunchFactory factory = PairPadLaunchFactory(payable(vm.envAddress("FACTORY")));
        PairPadRouter router = PairPadRouter(payable(vm.envAddress("ROUTER")));
        address[] memory tokens = vm.envAddress("TOKENS", ",");
        uint256 buy = vm.envOr("BUY", uint256(0.0002 ether));

        vm.startBroadcast(key);
        for (uint256 i = 0; i < tokens.length; i++) {
            PoolKey memory poolKey = factory.poolKeyFor(tokens[i]);
            uint256 out = router.swapExactIn{value: buy}(poolKey, true, buy, 0, me);
            IERC20(tokens[i]).approve(address(router), out / 2);
            uint256 back = router.swapExactIn(poolKey, false, out / 2, 0, me);
            console2.log("token", tokens[i]);
            console2.log("  bought", out, "sold half for", back);
        }
        vm.stopBroadcast();
    }
}
