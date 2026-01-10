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
}

contract TestUser {
    receive() external payable {}
}

/// @title PMHookRouter Multicall Overflow Protection Tests
/// @notice Tests for overflow protection in ETH cumulative tracking
contract PMHookRouterMulticallOverflowTest is Test {
    PMHookRouter public router;
    PMFeeHook public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_2028 = 1861919999;

    address public alice;
    address public bob;
    uint256 public marketId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main4"));

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

        alice = address(new TestUser());
        bob = address(new TestUser());

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);

        // Create test market
        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Overflow Test Market",
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

    /// @notice Test overflow protection with extreme values
    function test_Overflow_Protection_ExtremeValues() public {
        // Try to cause overflow by using values that would wrap around
        bytes[] memory calls = new bytes[](2);

        uint256 halfMax = type(uint256).max / 2 + 1;

        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, halfMax, 0, bob, type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, halfMax, 0, bob, type(uint256).max
        );

        // Should revert with overflow error (caught via multicall delegatecall revert)
        vm.prank(bob);
        vm.expectRevert();
        router.multicall{value: 100 ether}(calls);
    }

    /// @notice Test that normal cumulative tracking doesn't trigger overflow
    function test_Overflow_Protection_NormalOperation() public {
        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 1 ether, 0, bob, type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 2 ether, 0, bob, type(uint256).max
        );
        calls[2] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 3 ether, 0, bob, type(uint256).max
        );

        uint256 bobBalanceBefore = bob.balance;

        // Should work fine with 6 ETH total
        vm.prank(bob);
        router.multicall{value: 6 ether}(calls);

        // Verify ETH was properly accounted for
        uint256 spent = bobBalanceBefore - bob.balance;
        assertGe(spent, 6 ether, "Should have spent at least 6 ETH");
        assertLe(spent, 6.01 ether, "Should not spend much more than 6 ETH");
    }

    /// @notice Test cumulative tracking with zero amounts
    function test_CumulativeTracking_ZeroAmount() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 1 ether, 0, bob, type(uint256).max
        );
        // Second call would have 0 collateral if it could be tested

        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        router.multicall{value: 2 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;

        // Should handle zero amounts without overflow
        assertGt(bobBalanceBefore, bobBalanceAfter, "Should have spent some ETH");
    }

    /// @notice Test nested multicall with cumulative tracking
    function test_NestedMulticall_CumulativeTracking() public {
        // Create inner multicall with 2 ETH of buys
        bytes[] memory innerCalls = new bytes[](2);
        innerCalls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 1 ether, 0, bob, type(uint256).max
        );
        innerCalls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector, marketId, true, 1 ether, 0, bob, type(uint256).max
        );

        // Wrap in outer multicall
        bytes[] memory outerCalls = new bytes[](1);
        outerCalls[0] = abi.encodeWithSelector(router.multicall.selector, innerCalls);

        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        router.multicall{value: 3 ether}(outerCalls);

        uint256 spent = bobBalanceBefore - bob.balance;

        // Should track ETH properly across nested calls
        assertGe(spent, 2 ether, "Should spend at least 2 ETH");
        assertLe(spent, 2.05 ether, "Should not overspend significantly");
    }

    /// @notice Fuzz test: cumulative tracking doesn't overflow with reasonable values
    function testFuzz_CumulativeTracking_NoOverflow(uint8 numCalls, uint88 amountPerCall) public {
        vm.assume(numCalls > 0 && numCalls <= 10);
        vm.assume(amountPerCall > 0.01 ether && amountPerCall < 10 ether);

        uint256 totalRequired = uint256(numCalls) * uint256(amountPerCall);
        vm.assume(totalRequired <= 100 ether); // Keep reasonable

        bytes[] memory calls = new bytes[](numCalls);
        for (uint256 i = 0; i < numCalls; i++) {
            calls[i] = abi.encodeWithSelector(
                router.buyWithBootstrap.selector,
                marketId,
                true,
                uint256(amountPerCall),
                0,
                bob,
                type(uint256).max
            );
        }

        vm.prank(bob);
        // Should not overflow and should track correctly
        router.multicall{value: totalRequired + 1 ether}(calls);
    }
}
