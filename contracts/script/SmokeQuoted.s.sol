// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";
import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";
import {Hop} from "../src/v2/libraries/Hop.sol";

/**
 * @notice Live smoke of a launch quoted in an ERC-20 the pricer routes to
 * the gas token (a tokenized stock on Base or BNB Chain, say): one market,
 * opening buy paid in the gas token along the pricer's route, a second buy,
 * a sale back to the gas token. Proves the external V3 side (Uniswap or
 * PancakeSwap) end to end on a real chain.
 *
 *   PRIVATE_KEY=... MULTI_FACTORY=... MULTI_ROUTER=... PRICER=... QUOTE=0x... \
 *   forge script script/SmokeQuoted.s.sol --rpc-url ... --broadcast
 */
contract SmokeQuoted is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(payable(vm.envAddress("MULTI_FACTORY")));
        PairPadMultiRouter router = PairPadMultiRouter(payable(vm.envAddress("MULTI_ROUTER")));
        PairPadQuotePricer pricer = PairPadQuotePricer(vm.envAddress("PRICER"));
        address quote = vm.envAddress("QUOTE");
        uint256 openingBuy = vm.envOr("OPENING_BUY", uint256(0.001 ether));
        uint256 secondBuy = vm.envOr("SECOND_BUY", uint256(0.0015 ether));

        (Hop[] memory sellLeg, bool qualifies) = pricer.route(quote);
        require(qualifies && sellLeg.length > 0, "quote has no qualifying route");
        console2.log("route hops:        ", sellLeg.length);
        Hop[] memory buyLeg = new Hop[](sellLeg.length);
        for (uint256 i = 0; i < sellLeg.length; i++) buyLeg[i] = sellLeg[sellLeg.length - 1 - i];

        address[] memory pair = new address[](1);
        pair[0] = quote;
        PairPadMultiLaunchFactory.TokenParams memory params = _params(me, vm.envOr("TOKEN_SYMBOL", string("TQUOTE")));

        vm.startBroadcast(key);
        uint256 fee = factory.launchFee();
        PairPadMultiRouter.Leg[] memory legs = new PairPadMultiRouter.Leg[](1);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: buyLeg, amountIn: openingBuy});
        (address token, uint256 out0) = router.launchAndBuyWithEth{value: fee + openingBuy}(params, 0, pair, legs, 0);
        console2.log("token:             ", token);
        console2.log("quote:             ", quote);
        console2.log("opening buy out:   ", out0);

        legs[0].amountIn = secondBuy;
        uint256 out1 = router.buyWithEth{value: secondBuy}(token, legs, 0, me);
        console2.log("second buy out:    ", out1);

        IERC20(token).approve(address(router), out1 / 2);
        PairPadMultiRouter.Leg[] memory sellLegs = new PairPadMultiRouter.Leg[](1);
        sellLegs[0] = PairPadMultiRouter.Leg({market: 0, hops: sellLeg, amountIn: out1 / 2});
        uint256 ethOut = router.sellToEth(token, sellLegs, 0, me);
        console2.log("sold half, gas out:", ethOut);
        vm.stopBroadcast();

        console2.log("my token balance:  ", IERC20(token).balanceOf(me));
        console2.log("router quote bal:  ", IERC20(quote).balanceOf(address(router)));
    }

    function _params(address recipient, string memory symbol) internal view returns (PairPadMultiLaunchFactory.TokenParams memory p) {
        p.name = string.concat("par test ", symbol);
        p.symbol = symbol;
        p.description = "Bring-up test of a stock-quoted launch. Not a real token.";
        p.creatorFeeRecipient = recipient;
        p.creatorTaxBps = 300;
        p.salt = keccak256(abi.encode("smoke-quoted", symbol, block.timestamp));
    }
}
