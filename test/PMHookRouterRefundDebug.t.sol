// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

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
    function setOperator(address operator, bool approved) external returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract PMHookRouterRefundDebugTest is Test {
    PMHookRouter public router;
    PMFeeHookV1 public hook;
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_2028 = 1861919999;

    address public alice;
    address public bob;
    uint256 public marketId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

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
        bob = makeAddr("bob");
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);

        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Debug Test Market",
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

    function test_RefundDebug_CheckRouterBalance() public {
        uint256 bobBalanceBefore = bob.balance;
        uint256 routerBalanceBefore = address(router).balance;

        console.log("=== BEFORE TRANSACTION ===");
        console.log("Bob balance:", bobBalanceBefore);
        console.log("Router balance:", routerBalanceBefore);

        vm.prank(bob);
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        uint256 bobBalanceAfter = bob.balance;
        uint256 routerBalanceAfter = address(router).balance;

        console.log("=== AFTER TRANSACTION ===");
        console.log("Bob balance:", bobBalanceAfter);
        console.log("Router balance:", routerBalanceAfter);
        console.log("Bob spent:", bobBalanceBefore - bobBalanceAfter);
        console.log("Router gained:", routerBalanceAfter - routerBalanceBefore);

        // Router should not keep any ETH
        assertEq(routerBalanceAfter, routerBalanceBefore, "Router should not accumulate ETH");

        // Bob should have spent ~1 ETH (plus gas)
        uint256 bobSpent = bobBalanceBefore - bobBalanceAfter;
        assertLt(bobSpent, 1.1 ether, "Bob should have received refund of excess ETH");
    }
}
