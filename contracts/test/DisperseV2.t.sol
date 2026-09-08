// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PairPadDisperseV2} from "../src/fees/PairPadDisperseV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

/// @dev Accepts ETH but burns most of the stipend first: still within SEND_GAS.
contract SlowWallet {
    uint256 public sink;

    receive() external payable {
        for (uint256 i = 0; i < 12; i++) sink += i;
    }
}

/// @dev Tries to re-enter the disperser from its receive; must not break the round.
contract Reenterer {
    PairPadDisperseV2 internal d;

    constructor(PairPadDisperseV2 d_) {
        d = d_;
    }

    receive() external payable {
        address[] memory to = new address[](1);
        uint256[] memory am = new uint256[](1);
        to[0] = address(this);
        am[0] = 1;
        // no value attached: reverts with InsufficientValue inside, which we swallow
        try d.disperseEth(address(1), to, am, 0) {} catch {}
    }
}

contract DisperseV2Test is Test {
    PairPadDisperseV2 internal disperse;
    MockERC20 internal usdg;
    address internal launch = makeAddr("launch");

    function setUp() public {
        disperse = new PairPadDisperseV2();
        usdg = new MockERC20("USDG", "USDG", 6);
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ token

    function test_token_sendsManyTagsLaunchAndEmitsPerRecipient() public {
        usdg.mint(address(this), 100e6);
        usdg.approve(address(disperse), type(uint256).max);
        address[] memory to = new address[](3);
        uint256[] memory am = new uint256[](3);
        to[0] = makeAddr("h1");
        to[1] = makeAddr("h2");
        to[2] = makeAddr("h3");
        am[0] = 10e6;
        am[1] = 0; // skipped
        am[2] = 30e6;

        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Paid(launch, address(usdg), to[0], 10e6);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Paid(launch, address(usdg), to[2], 30e6);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Dispersed(launch, address(usdg), address(this), 7, 40e6, 3);
        uint256 total = disperse.disperseToken(launch, IERC20(address(usdg)), to, am, 7);

        assertEq(total, 40e6);
        assertEq(usdg.balanceOf(to[0]), 10e6);
        assertEq(usdg.balanceOf(to[1]), 0);
        assertEq(usdg.balanceOf(to[2]), 30e6);
        assertEq(usdg.balanceOf(address(this)), 60e6);
        assertEq(usdg.balanceOf(address(disperse)), 0);
    }

    function test_token_guards() public {
        address[] memory to = new address[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(PairPadDisperseV2.LengthMismatch.selector);
        disperse.disperseToken(launch, IERC20(address(usdg)), to, two, 1);

        uint256[] memory one = new uint256[](1);
        to[0] = makeAddr("h");
        vm.expectRevert(PairPadDisperseV2.NothingToSend.selector);
        disperse.disperseToken(launch, IERC20(address(usdg)), to, one, 1);

        address[] memory none = new address[](0);
        uint256[] memory noneAm = new uint256[](0);
        vm.expectRevert(PairPadDisperseV2.NothingToSend.selector);
        disperse.disperseToken(launch, IERC20(address(usdg)), none, noneAm, 1);

        usdg.mint(address(this), 1e6);
        one[0] = 1e6;
        vm.expectRevert(); // no approval
        disperse.disperseToken(launch, IERC20(address(usdg)), to, one, 1);
    }

    // -------------------------------------------------------------------- eth

    function test_eth_sendsManyAndEmits() public {
        address[] memory to = new address[](3);
        uint256[] memory am = new uint256[](3);
        to[0] = makeAddr("h1");
        to[1] = makeAddr("h2");
        to[2] = address(new SlowWallet());
        am[0] = 1 ether;
        am[1] = 0;
        am[2] = 2 ether;

        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Paid(launch, address(0), to[0], 1 ether);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Paid(launch, address(0), to[2], 2 ether);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Dispersed(launch, address(0), address(this), 9, 3 ether, 3);
        uint256 before = address(this).balance;
        uint256 total = disperse.disperseEth{value: 3 ether}(launch, to, am, 9);

        assertEq(total, 3 ether);
        assertEq(to[0].balance, 1 ether);
        assertEq(to[1].balance, 0);
        assertEq(to[2].balance, 2 ether);
        assertEq(address(disperse).balance, 0);
        assertEq(address(this).balance, before - 3 ether);
    }

    function test_eth_skipsRefusingRecipientAndRefunds() public {
        address bad = address(new RejectsEth());
        address good = makeAddr("good");
        address[] memory to = new address[](2);
        uint256[] memory am = new uint256[](2);
        to[0] = bad;
        to[1] = good;
        am[0] = 1 ether;
        am[1] = 1 ether;

        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Unpaid(launch, bad, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Paid(launch, address(0), good, 1 ether);
        vm.expectEmit(true, true, true, true);
        emit PairPadDisperseV2.Dispersed(launch, address(0), address(this), 1, 1 ether, 2);
        uint256 before = address(this).balance;
        uint256 total = disperse.disperseEth{value: 2 ether}(launch, to, am, 1);

        assertEq(total, 1 ether);
        assertEq(bad.balance, 0);
        assertEq(good.balance, 1 ether);
        assertEq(address(disperse).balance, 0);
        // only the delivered ether left this account
        assertEq(address(this).balance, before - 1 ether);
    }

    function test_eth_refundsExcessValue() public {
        address[] memory to = new address[](1);
        uint256[] memory am = new uint256[](1);
        to[0] = makeAddr("h");
        am[0] = 1 ether;
        uint256 before = address(this).balance;
        disperse.disperseEth{value: 1.5 ether}(launch, to, am, 1);
        assertEq(address(this).balance, before - 1 ether);
        assertEq(address(disperse).balance, 0);
    }

    function test_eth_guards() public {
        address[] memory to = new address[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(PairPadDisperseV2.LengthMismatch.selector);
        disperse.disperseEth{value: 1}(launch, to, two, 1);

        uint256[] memory one = new uint256[](1);
        to[0] = makeAddr("h");
        vm.expectRevert(PairPadDisperseV2.NothingToSend.selector);
        disperse.disperseEth{value: 1}(launch, to, one, 1);

        one[0] = 2 ether;
        vm.expectRevert(PairPadDisperseV2.InsufficientValue.selector);
        disperse.disperseEth{value: 1 ether}(launch, to, one, 1);

        // everyone refuses: nothing sent is a failed round, value comes back with the revert
        to[0] = address(new RejectsEth());
        one[0] = 1 ether;
        vm.expectRevert(PairPadDisperseV2.NothingToSend.selector);
        disperse.disperseEth{value: 1 ether}(launch, to, one, 1);
    }

    function test_eth_reentrantRecipientIsPaidAndHarmless() public {
        Reenterer r = new Reenterer(disperse);
        address[] memory to = new address[](2);
        uint256[] memory am = new uint256[](2);
        to[0] = address(r);
        to[1] = makeAddr("h");
        am[0] = 1 ether;
        am[1] = 1 ether;
        uint256 total = disperse.disperseEth{value: 2 ether}(launch, to, am, 1);
        // the re-entrant call has no value and fails inside its try; the outer round is unaffected
        assertEq(total, 2 ether);
        assertEq(address(r).balance, 1 ether);
        assertEq(to[1].balance, 1 ether);
        assertEq(address(disperse).balance, 0);
    }
}
