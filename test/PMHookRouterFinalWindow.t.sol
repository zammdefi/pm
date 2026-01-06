// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
}

/**
 * @title PMHookRouter Final Window Tests
 * @notice Tests for final window cooldown logic (12h before close requires 24h cooldown)
 */
contract PMHookRouterFinalWindowTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHookV1 public hook;
    address public ALICE;
    address public BOB;
    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Initialize router
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        deal(ALICE, 100000 ether);
        deal(BOB, 100000 ether);

        console.log("=== PMHookRouter Final Window Test Suite ===");
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Final Window Test Market",
            ALICE,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            1000 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_NormalDeposit_Uses6hCooldown() public {
        _bootstrapMarket();

        console.log("=== NORMAL DEPOSIT - 6H COOLDOWN ===");

        // Deposit well before the final window (13h before close)
        uint256 depositTime = DEADLINE_2028 - 13 hours;
        vm.warp(depositTime);

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);
        console.log("Deposited at:", depositTime);
        console.log("Time to close:", DEADLINE_2028 - depositTime, "seconds");

        // Try to withdraw after 6h + 1 (should succeed with normal cooldown)
        vm.warp(depositTime + 6 hours + 1);

        (uint256 sharesWithdrawn,) =
            router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028);

        console.log("Withdrew after 6h cooldown:", sharesWithdrawn);
        assertGt(sharesWithdrawn, 0, "Should withdraw successfully after 6h");

        vm.stopPrank();
    }

    function test_FinalWindowDeposit_Requires24hCooldown() public {
        _bootstrapMarket();

        console.log("=== FINAL WINDOW DEPOSIT - 24H COOLDOWN ===");

        // Deposit within the final window (10h before close, < 12h threshold)
        uint256 depositTime = DEADLINE_2028 - 10 hours;
        vm.warp(depositTime);

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);
        console.log("Deposited at:", depositTime);
        console.log("Time to close:", DEADLINE_2028 - depositTime, "seconds (< 12h)");

        // Try to withdraw after only 6h (should FAIL - needs 24h)
        vm.warp(depositTime + 6 hours + 1);
        vm.expectRevert(); // WithdrawalTooSoon
        router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028);

        console.log("Correctly blocked withdrawal after 6h");

        // Try after 12h (should still FAIL - needs 24h)
        vm.warp(depositTime + 12 hours + 1);
        vm.expectRevert(); // WithdrawalTooSoon
        router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028);

        console.log("Correctly blocked withdrawal after 12h");

        // Withdraw after 24h + 1 (should succeed)
        vm.warp(depositTime + 24 hours + 1);
        (uint256 sharesWithdrawn,) =
            router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028 + 1 days);

        console.log("Withdrew after 24h cooldown:", sharesWithdrawn);
        assertGt(sharesWithdrawn, 0, "Should withdraw successfully after 24h");

        vm.stopPrank();
    }

    function test_EdgeCase_ExactlyAt12hBoundary() public {
        _bootstrapMarket();

        console.log("=== EDGE CASE - EXACTLY 12H BEFORE CLOSE ===");

        // Deposit exactly 12h before close
        uint256 depositTime = DEADLINE_2028 - 12 hours;
        vm.warp(depositTime);

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);

        // At exactly 12h, the condition is: timeToClose < 12h
        // Since timeToClose = 12h (43200), it's NOT < 43200, so uses 6h cooldown
        vm.warp(depositTime + 6 hours + 1);

        (uint256 sharesWithdrawn,) =
            router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028);

        console.log("At exactly 12h boundary, uses 6h cooldown (not final window)");
        assertGt(sharesWithdrawn, 0, "Should withdraw after 6h at boundary");

        vm.stopPrank();
    }

    function test_FinalWindow_PostCloseStillEnforces24h() public {
        _bootstrapMarket();

        console.log("=== FINAL WINDOW - POST-CLOSE ENFORCEMENT ===");

        // Deposit 6h before close (well within final window)
        uint256 depositTime = DEADLINE_2028 - 6 hours;
        vm.warp(depositTime);

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);

        // Warp to after market close (but before 24h cooldown)
        vm.warp(DEADLINE_2028 + 1);

        // Should still enforce 24h cooldown even after market close
        vm.expectRevert(); // WithdrawalTooSoon
        router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028 + 1 days);

        console.log("Post-close: still enforces 24h cooldown for final window deposits");

        // Warp to full 24h after deposit
        vm.warp(depositTime + 24 hours + 1);

        (uint256 sharesWithdrawn,) =
            router.withdrawFromVault(marketId, true, shares, ALICE, DEADLINE_2028 + 1 days);

        console.log("After 24h: withdrawal succeeds");
        assertGt(sharesWithdrawn, 0, "Should withdraw after 24h even post-close");

        vm.stopPrank();
    }

    function test_HarvestAlsoRespectsFinalWindow() public {
        _bootstrapMarket();

        console.log("=== HARVEST - FINAL WINDOW ENFORCEMENT ===");

        // Create some fees first
        vm.prank(BOB);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Deposit within final window
        uint256 depositTime = DEADLINE_2028 - 8 hours;
        vm.warp(depositTime);

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        // Try to harvest after 6h (should fail - needs 24h)
        vm.warp(depositTime + 6 hours + 1);
        vm.expectRevert(); // WithdrawalTooSoon
        router.harvestVaultFees(marketId, true);

        console.log("Harvest correctly enforces 24h cooldown for final window");

        // Harvest after 24h (should succeed)
        vm.warp(depositTime + 24 hours + 1);
        uint256 feesHarvested = router.harvestVaultFees(marketId, true);

        console.log("Harvested fees after 24h:", feesHarvested);

        vm.stopPrank();
    }
}
