// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );
    function getNoId(uint256 marketId) external pure returns (uint256);
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

/// @notice Test user contract that can receive ETH
contract TestUser {
    receive() external payable {}
}

/// @title PMHookRouter Multicall ETH Security Tests
/// @notice Tests for multicall ETH handling, refund logic, and anti-double-spend
contract PMHookRouterMulticallETHTest is Test {
    PMHookRouter public router;
    PMFeeHook public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_2028 = 1861919999;

    address public alice;
    address public bob;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main4"));

        // Deploy hook
        hook = new PMFeeHook();

        // Deploy router at expected address
        PMHookRouter routerImpl = new PMHookRouter();
        vm.etch(EXPECTED_ROUTER, address(routerImpl).code);
        router = PMHookRouter(payable(EXPECTED_ROUTER));

        // Initialize router
        vm.startPrank(EXPECTED_ROUTER);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Create test accounts with receive() support
        alice = address(new TestUser());
        bob = address(new TestUser());

        // Fund accounts
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
    }

    uint256 private marketCounter;

    function _createMarket() internal returns (uint256 marketId) {
        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            string(abi.encodePacked("Test Market ", vm.toString(marketCounter++))),
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

    // ============ Test 1: Basic Multicall with Proper ETH Refund ============

    function test_Multicall_BasicETHRefund() public {
        uint256 marketId1 = _createMarket();
        uint256 marketId2 = _createMarket();

        uint256 bobBalanceBefore = bob.balance;

        // Prepare two buy calls
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId1,
            true, // buyYes
            1 ether, // collateralIn
            0, // minSharesOut
            bob,
            type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId2, true, 1 ether, 0, bob, type(uint256).max
        );

        // Execute multicall with 3 ETH (should spend 2 ETH, refund 1 ETH)
        vm.prank(bob);
        router.multicall{value: 3 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;

        // Bob should have spent 2 ETH total (1 ETH per buy) and received 1 ETH refund
        assertEq(bobBalanceBefore - bobBalanceAfter, 2 ether, "Should spend exactly 2 ETH");
    }

    // ============ Test 2: Cumulative ETH Tracking Prevents Double-Spend ============

    function test_Multicall_PreventsMsgValueDoubleSpend() public {
        uint256 marketId1 = _createMarket();
        uint256 marketId2 = _createMarket();

        // Try to spend more than msg.value across multiple calls
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId1,
            true,
            5 ether, // First buy: 5 ETH
            0,
            bob,
            type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId2,
            true,
            6 ether, // Second buy: 6 ETH (total 11 ETH)
            0,
            bob,
            type(uint256).max
        );

        // Send only 10 ETH - should revert because 5 + 6 > 10
        vm.prank(bob);
        vm.expectRevert(); // Should revert with InvalidETHAmount
        router.multicall{value: 10 ether}(calls);
    }

    function test_Multicall_ExactETHAmount() public {
        uint256 marketId1 = _createMarket();
        uint256 marketId2 = _createMarket();

        uint256 bobBalanceBefore = bob.balance;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId1, true, 3 ether, 0, bob, type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId2, true, 7 ether, 0, bob, type(uint256).max
        );

        // Send exactly 10 ETH - should work with no refund
        vm.prank(bob);
        router.multicall{value: 10 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;

        // Should spend exactly 10 ETH with no refund
        assertEq(bobBalanceBefore - bobBalanceAfter, 10 ether, "Should spend exactly 10 ETH");
    }

    // ============ Test 3: Empty Multicall Refunds All ETH ============

    function test_Multicall_EmptyCallsRefundAll() public {
        uint256 bobBalanceBefore = bob.balance;

        // Empty multicall
        bytes[] memory calls = new bytes[](0);

        vm.prank(bob);
        router.multicall{value: 10 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;
        uint256 spent = bobBalanceBefore - bobBalanceAfter;

        // Should refund all 10 ETH (minus gas)
        // Gas costs should be trivial (< 0.01 ETH)
        assertLt(spent, 0.01 ether, "Should only spend gas, not 10 ETH");
    }

    // ============ Test 4: Partial Revert Refunds All ============

    function test_Multicall_PartialRevertRefundsAll() public {
        uint256 marketId1 = _createMarket();
        uint256 marketId2 = _createMarket();

        uint256 bobBalanceBefore = bob.balance;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId1, true, 2 ether, 0, bob, type(uint256).max
        );
        // Second call has invalid market ID - should revert
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            999999999, // Invalid market ID
            true,
            3 ether,
            0,
            bob,
            type(uint256).max
        );

        // Entire multicall should revert
        vm.prank(bob);
        vm.expectRevert();
        router.multicall{value: 5 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;

        // No ETH should be spent (full revert)
        assertEq(bobBalanceAfter, bobBalanceBefore, "All ETH should be refunded on revert");
    }
}
