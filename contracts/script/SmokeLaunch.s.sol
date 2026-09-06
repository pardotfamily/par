// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadLaunchLocker} from "../src/v2/PairPadLaunchLocker.sol";
import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadRouter} from "../src/v2/PairPadRouter.sol";
import {Hop} from "../src/v2/libraries/Hop.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";

/**
 * @notice Live smoke test of a deployed stack: launch a token on the given
 * config with an opening buy, buy again, sell part of it back, collect the
 * fees and print what the position earned and what was burned. Costs the
 * launch fee plus the small amounts below.
 *
 * QUOTE (optional) is the quote asset; ETH when unset. For an ERC-20 quote
 * every leg is paid in ETH along the pricer's route, so a token quoted in
 * something three pools away from ETH is the full exercise of the router.
 *
 *   FACTORY=... ROUTER=... CONFIG_ID=0 [QUOTE=0x...] forge script script/SmokeLaunch.s.sol --rpc-url ... --broadcast
 */
contract SmokeLaunch is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadLaunchFactory factory = PairPadLaunchFactory(payable(vm.envAddress("FACTORY")));
        PairPadRouter router = PairPadRouter(payable(vm.envAddress("ROUTER")));
        PairPadLaunchLocker locker = factory.locker();
        PairPadQuotePricer pricer = PairPadQuotePricer(address(factory.quotePricer()));
        uint256 configId = vm.envOr("CONFIG_ID", uint256(0));
        uint256 openingBuy = vm.envOr("OPENING_BUY", uint256(0.0002 ether));
        uint256 secondBuy = vm.envOr("SECOND_BUY", uint256(0.0002 ether));
        address quote = vm.envOr("QUOTE", address(0));

        // The sell leg is the pricer's route, quote to ETH; the buy leg is it reversed.
        Hop[] memory sellLeg = new Hop[](0);
        if (quote != address(0)) {
            bool qualifies;
            (sellLeg, qualifies) = pricer.route(quote);
            require(sellLeg.length > 0 && qualifies, "quote has no qualifying route");
            console2.log("route hops:", sellLeg.length);
        }
        Hop[] memory buyLeg = new Hop[](sellLeg.length);
        for (uint256 i = 0; i < sellLeg.length; i++) buyLeg[i] = sellLeg[sellLeg.length - 1 - i];

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
        }(params, configId, quote, buyLeg, 0);
        console2.log("token:        ", token);
        console2.log("poolId:       ", vm.toString(PoolId.unwrap(poolId)));
        console2.log("opening buy tokens out:", openingOut);

        PoolKey memory poolKey = factory.poolKeyFor(token);
        bool tokenIs0 = Currency.unwrap(poolKey.currency0) == token;

        uint256 out2;
        if (quote == address(0)) {
            out2 = router.swapExactIn{value: secondBuy}(poolKey, true, secondBuy, 0, me);
        } else {
            out2 = router.buyWithEth{value: secondBuy}(poolKey, buyLeg, 0, me);
        }
        console2.log("second buy tokens out: ", out2);

        uint256 sellAmount = out2 / 2;
        IERC20(token).approve(address(router), sellAmount);
        uint256 ethOut;
        if (quote == address(0)) {
            ethOut = router.swapExactIn(poolKey, false, sellAmount, 0, me);
        } else {
            ethOut = router.sellToEth(poolKey, tokenIs0, sellAmount, sellLeg, 0, me);
        }
        console2.log("sold half of second buy, ETH out:", ethOut);

        (uint256 fees0, uint256 fees1) = locker.pendingFees(token);
        console2.log("pool fee (pips):", poolKey.fee);
        console2.log("pending fees currency0 / currency1:", fees0, fees1);

        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 got0, uint256 got1) = locker.collectFees(token);
        console2.log("collected currency0 / currency1:", got0, got1);
        console2.log("burned (supply drop):", supplyBefore - IERC20(token).totalSupply());

        vm.stopBroadcast();

        console2.log("my token balance:", IERC20(token).balanceOf(me));
    }
}
