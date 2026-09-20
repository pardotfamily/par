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
import {Hop} from "../src/v2/libraries/Hop.sol";

/**
 * @notice Live smoke of one creator-fee mode on a freshly deployed chain:
 * launch a reference-quoted token whose creator fee goes to the caller
 * (creator), the holder vault (holders), the burn vault (burn) or the
 * floor vault (floor), trade it a little so fees accrue, collect them and
 * print where the creator share went. What the vault then does with it is
 * the distributor's job; this only proves the on-chain half.
 *
 *   PRIVATE_KEY=... FACTORY=... ROUTER=... FEE_MODE=holders VAULT=0x... \
 *   forge script script/SmokeModes.s.sol --rpc-url ... --broadcast
 */
contract SmokeModes is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadLaunchFactory factory = PairPadLaunchFactory(payable(vm.envAddress("FACTORY")));
        PairPadRouter router = PairPadRouter(payable(vm.envAddress("ROUTER")));
        PairPadLaunchLocker locker = factory.locker();
        string memory mode = vm.envOr("FEE_MODE", string("creator"));
        address recipient = keccak256(bytes(mode)) == keccak256("creator") ? me : vm.envAddress("VAULT");
        uint16 taxBps = uint16(vm.envOr("CREATOR_TAX_BPS", uint256(300)));
        uint256 openingBuy = vm.envOr("OPENING_BUY", uint256(0.0002 ether));
        uint256 secondBuy = vm.envOr("SECOND_BUY", uint256(0.0003 ether));

        Hop[] memory noLeg = new Hop[](0);
        PairPadLaunchFactory.TokenParams memory params = _params(mode, recipient, taxBps);

        uint256 recipientBefore = recipient.balance;
        vm.startBroadcast(key);
        address token = _launch(factory, router, params, openingBuy, noLeg);
        console2.log("mode:               ", mode);
        console2.log("fee recipient:      ", recipient);
        _trade(factory, router, token, secondBuy, me);
        _collect(locker, token);
        vm.stopBroadcast();

        // In creator mode the recipient is the caller, whose balance also paid for all of this.
        if (recipient.balance >= recipientBefore) console2.log("recipient ref gain: ", recipient.balance - recipientBefore);
        else console2.log("recipient ref change (paid gas+buys): -", recipientBefore - recipient.balance);
        console2.log("recipient token bal:", IERC20(token).balanceOf(recipient));
        console2.log("my token balance:   ", IERC20(token).balanceOf(me));
    }

    function _params(string memory mode, address recipient, uint16 taxBps)
        internal
        view
        returns (PairPadLaunchFactory.TokenParams memory p)
    {
        p.name = vm.envOr("TOKEN_NAME", string(string.concat("par test ", mode)));
        p.symbol = vm.envOr("TOKEN_SYMBOL", string(string.concat("T", _upper(mode))));
        p.description = string.concat("Bring-up test of the ", mode, " fee mode. Not a real token.");
        p.creatorFeeRecipient = recipient;
        p.creatorTaxBps = taxBps;
        p.salt = keccak256(abi.encode("smoke-modes", mode, block.timestamp));
    }

    function _launch(
        PairPadLaunchFactory factory,
        PairPadRouter router,
        PairPadLaunchFactory.TokenParams memory params,
        uint256 openingBuy,
        Hop[] memory noLeg
    ) internal returns (address token) {
        uint256 launchFee = factory.launchFee();
        PoolId poolId;
        uint256 openingOut;
        (token, poolId, openingOut) = router.launchAndBuyWithEth{value: launchFee + openingBuy}(params, 0, address(0), noLeg, 0);
        console2.log("token:              ", token);
        console2.log("poolId:             ", vm.toString(PoolId.unwrap(poolId)));
        console2.log("opening buy out:    ", openingOut);
    }

    function _trade(PairPadLaunchFactory factory, PairPadRouter router, address token, uint256 secondBuy, address me) internal {
        PoolKey memory poolKey = factory.poolKeyFor(token);
        uint256 out2 = router.swapExactIn{value: secondBuy}(poolKey, true, secondBuy, 0, me);
        console2.log("second buy out:     ", out2);
        uint256 sellAmount = out2 / 2;
        IERC20(token).approve(address(router), sellAmount);
        uint256 ethOut = router.swapExactIn(poolKey, false, sellAmount, 0, me);
        console2.log("sold half, ref out: ", ethOut);
    }

    function _collect(PairPadLaunchLocker locker, address token) internal {
        (uint256 fees0, uint256 fees1) = locker.pendingFees(token);
        console2.log("pending fees c0/c1: ", fees0, fees1);
        uint256 supplyBefore = IERC20(token).totalSupply();
        (uint256 got0, uint256 got1) = locker.collectFees(token);
        console2.log("collected c0/c1:    ", got0, got1);
        console2.log("supply drop (burn): ", supplyBefore - IERC20(token).totalSupply());
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(string.concat(s, ""));
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x61 && b[i] <= 0x7a) b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }
}
