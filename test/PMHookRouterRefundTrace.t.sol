// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function setOperator(address operator, bool approved) external returns (bool);
}

/// @title Deep trace to understand refund flow
contract PMHookRouterRefundTraceTest is Test {
    PMHookRouter public router;
    PMFeeHook public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_2028 = 1861919999;

    address public alice;
    uint256 public marketId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main5"));

        hook = new PMFeeHook();

        PMHookRouter routerImpl = new PMHookRouter();
        vm.etch(EXPECTED_ROUTER, address(routerImpl).code);
        router = PMHookRouter(payable(EXPECTED_ROUTER));

        vm.startPrank(EXPECTED_ROUTER);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        alice = makeAddr("alice");
        vm.deal(alice, 10000 ether);

        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Trace Test Market",
            alice,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);
    }

    /// @notice Use vm.startPrank instead of vm.prank to see if it makes a difference
    function test_Trace_EOA_WithStartPrank() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        uint256 bobBalanceBefore = bob.balance;
        uint256 routerBalanceBefore = address(router).balance;

        console.log("=== EOA WITH START_PRANK TEST ===");
        console.log("Bob balance before:", bobBalanceBefore);
        console.log("Router balance before:", routerBalanceBefore);

        vm.startPrank(bob);
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 bobBalanceAfter = bob.balance;
        uint256 routerBalanceAfter = address(router).balance;

        console.log("Bob balance after:", bobBalanceAfter);
        console.log("Router balance after:", routerBalanceAfter);
        console.log("Bob spent:", bobBalanceBefore - bobBalanceAfter);
        console.log("Router gained:", routerBalanceAfter - routerBalanceBefore);

        if (bobBalanceBefore - bobBalanceAfter < 1.5 ether) {
            console.log("SUCCESS: Bob received refund");
        } else {
            console.log("PROBLEM: Bob did NOT receive refund");
        }
    }

    /// @notice Check if msg.value vs collateralIn matters
    function test_Trace_WhatIsActuallySpent() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        console.log("=== TRACE ACTUAL SPENDING ===");

        // Test with msg.value == collateralIn (should spend all)
        uint256 before1 = bob.balance;
        vm.prank(bob);
        router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );
        uint256 spent1 = before1 - bob.balance;
        console.log("Test 1 - msg.value=1, collateralIn=1, spent:", spent1);

        // Test with msg.value > collateralIn (should refund excess)
        uint256 before2 = bob.balance;
        vm.prank(bob);
        router.buyWithBootstrap{value: 3 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );
        uint256 spent2 = before2 - bob.balance;
        console.log("Test 2 - msg.value=3, collateralIn=1, spent:", spent2);

        if (spent2 < 2 ether) {
            console.log("SUCCESS: Excess was refunded in test 2");
        } else {
            console.log("PROBLEM: NO refund in test 2 (spent", spent2, "expected ~1 ETH)");
        }
    }

    /// @notice Check router ETH balance to see if it's accumulating
    function test_Trace_RouterBalance() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        uint256 routerBefore = address(router).balance;

        console.log("=== ROUTER BALANCE TRACE ===");
        console.log("Router ETH before:", routerBefore);

        vm.prank(bob);
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        uint256 routerAfter = address(router).balance;

        console.log("Router ETH after:", routerAfter);
        console.log("Router gained:", routerAfter - routerBefore);

        if (routerAfter - routerBefore >= 1 ether) {
            console.log("PROBLEM: Router kept the excess ETH!");
        } else {
            console.log("OK: Router didn't keep excess");
        }
    }
}
