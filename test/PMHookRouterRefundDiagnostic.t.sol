// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function setOperator(address operator, bool approved) external returns (bool);
}

/// @notice Simple test contract that logs when it receives ETH
contract ETHLogger {
    event ReceivedETH(uint256 amount, uint256 gasleft);

    receive() external payable {
        emit ReceivedETH(msg.value, gasleft());
    }
}

/// @title Diagnostic test to understand refund behavior
contract PMHookRouterRefundDiagnosticTest is Test {
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

        // Deploy hook
        hook = new PMFeeHook();

        // Deploy router at expected address
        PMHookRouter routerImpl = new PMHookRouter();
        vm.etch(EXPECTED_ROUTER, address(routerImpl).code);
        router = PMHookRouter(payable(EXPECTED_ROUTER));

        // Initialize router
        vm.startPrank(EXPECTED_ROUTER);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Create test account
        alice = makeAddr("alice");
        vm.deal(alice, 10000 ether);

        // Create market
        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Diagnostic Test Market",
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

        // Activate TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);
    }

    /// @notice Test 1: Does EOA receive refund?
    function test_Diagnostic_EOA_Refund() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        uint256 bobBalanceBefore = bob.balance;

        console.log("=== EOA REFUND TEST ===");
        console.log("Bob balance before:", bobBalanceBefore);
        console.log("Sending: 2 ETH");
        console.log("CollateralIn: 1 ETH");

        vm.prank(bob);
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        uint256 bobBalanceAfter = bob.balance;
        uint256 spent = bobBalanceBefore - bobBalanceAfter;

        console.log("Bob balance after:", bobBalanceAfter);
        console.log("Bob spent:", spent);
        console.log("Expected spent: ~1 ETH + gas");

        // Bob should have spent ~1 ETH + gas, not 2 ETH
        if (spent < 1.5 ether) {
            console.log("SUCCESS: Refund received!");
        } else {
            console.log("PROBLEM: No refund received");
        }
    }

    /// @notice Test 2: Does contract with receive() get refund?
    function test_Diagnostic_Contract_Refund() public {
        ETHLogger logger = new ETHLogger();
        vm.deal(address(logger), 10 ether);

        uint256 loggerBalanceBefore = address(logger).balance;

        console.log("=== CONTRACT REFUND TEST ===");
        console.log("Logger balance before:", loggerBalanceBefore);
        console.log("Sending: 2 ETH");
        console.log("CollateralIn: 1 ETH");

        // Record logs to see if receive() was called
        vm.recordLogs();

        vm.prank(address(logger));
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, address(logger), block.timestamp + 1 hours
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 loggerBalanceAfter = address(logger).balance;
        uint256 spent = loggerBalanceBefore - loggerBalanceAfter;

        console.log("Logger balance after:", loggerBalanceAfter);
        console.log("Logger spent:", spent);

        // Check if ReceivedETH event was emitted
        bool receivedETH = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ReceivedETH(uint256,uint256)")) {
                receivedETH = true;
                uint256 amount = abi.decode(logs[i].data, (uint256));
                console.log("Contract received ETH via receive():", amount);
            }
        }

        if (receivedETH) {
            console.log("SUCCESS: Contract received refund");
        } else {
            console.log("PROBLEM: Contract did NOT receive refund");
        }

        if (spent < 1.5 ether) {
            console.log("Balance confirms refund received");
        } else {
            console.log("Balance shows NO refund");
        }
    }

    /// @notice Test 3: What happens with exact amount (no refund needed)?
    function test_Diagnostic_ExactAmount() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        uint256 bobBalanceBefore = bob.balance;

        console.log("=== EXACT AMOUNT TEST ===");
        console.log("Sending: 1 ETH");
        console.log("CollateralIn: 1 ETH");

        vm.prank(bob);
        router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        uint256 bobBalanceAfter = bob.balance;
        uint256 spent = bobBalanceBefore - bobBalanceAfter;

        console.log("Bob spent:", spent);
        console.log("Expected: ~1 ETH + gas");
    }
}
