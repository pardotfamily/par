// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract FeeEscrowTest is Test {
    PairPadFeeEscrow internal escrow;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");

    function setUp() public {
        escrow = new PairPadFeeEscrow();
        token = new MockERC20("Token", "TKN", 18);
        vm.deal(address(this), 10 ether);
    }

    function test_creditAndClaimNative() public {
        escrow.credit{value: 1 ether}(alice);
        assertEq(escrow.balanceOf(alice), 1 ether);

        vm.prank(alice);
        uint256 claimed = escrow.claim();
        assertEq(claimed, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(escrow.balanceOf(alice), 0);
    }

    function test_partialNativeClaim() public {
        escrow.credit{value: 1 ether}(alice);
        vm.prank(alice);
        escrow.claim(0.4 ether);
        assertEq(escrow.balanceOf(alice), 0.6 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PairPadFeeEscrow.InsufficientBalance.selector, 1 ether, 0.6 ether)
        );
        escrow.claim(1 ether);
    }

    function test_creditAndClaimToken() public {
        token.mint(address(this), 100 ether);
        token.approve(address(escrow), type(uint256).max);
        escrow.creditToken(alice, address(token), 5 ether);
        assertEq(escrow.balanceOfToken(alice, address(token)), 5 ether);

        vm.prank(alice);
        uint256 claimed = escrow.claimToken(address(token));
        assertEq(claimed, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    function test_claimWithNothingPendingReturnsZero() public {
        vm.prank(alice);
        assertEq(escrow.claim(), 0);
    }
}
