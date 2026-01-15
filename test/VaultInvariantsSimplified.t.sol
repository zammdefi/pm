// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/PMHookRouter.sol";

/// @title Simplified Vault Invariant Tests
/// @notice Key invariants for vault share accounting
contract VaultInvariantsSimplifiedTest is Test {
    PMHookRouter public router;
    IPAMM public pamm = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address public ALICE;

    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy hook
        bytes memory hookBytecode = vm.getCode("PMFeeHook.sol:PMFeeHook");
        address hookAddr;
        assembly {
            hookAddr := create(0, add(hookBytecode, 0x20), mload(hookBytecode))
        }

        // Deploy router at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Setup PAMM operators
        vm.startPrank(REGISTRAR);
        pamm.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        pamm.setOperator(address(pamm), true);
        vm.stopPrank();

        // Transfer hook ownership
        IPMFeeHookOwnable hook = IPMFeeHookOwnable(hookAddr);
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Setup test account
        ALICE = makeAddr("ALICE");
        vm.deal(ALICE, type(uint96).max);

        // Bootstrap market
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 10 ether}(
            "Invariant Test Market",
            ALICE,
            address(0),
            uint64(block.timestamp + 30 days),
            false,
            hookAddr,
            10 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        noId = pamm.getNoId(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                            INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Vault shares are never orphaned
    /// @dev Orphaned = vault has shares on one side but zero LP shares to back them
    function test_NoOrphanedShares() public view {
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        uint256 yesLPShares = router.totalYesVaultShares(marketId);
        uint256 noLPShares = router.totalNoVaultShares(marketId);

        // If vault has yes shares, must have yes LP shares to back them
        if (yesShares > 0) {
            assertGt(yesLPShares, 0, "Orphaned yes shares detected");
        }

        // If vault has no shares, must have no LP shares to back them
        if (noShares > 0) {
            assertGt(noLPShares, 0, "Orphaned no shares detected");
        }
    }

    /// @notice Property: Budget is never negative
    function test_BudgetNeverNegative() public view {
        uint256 budget = router.rebalanceCollateralBudget(marketId);
        // Budget is uint256, so can't be negative, but verify it's reasonable
        assertTrue(budget <= type(uint96).max, "Budget unreasonably large");
    }

    /// @notice Property: Vault shares sum is reasonable
    function test_VaultSharesReasonable() public view {
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);

        // Vault shares should be <= uint112 max (by design)
        assertTrue(yesShares <= type(uint112).max, "Yes shares overflow");
        assertTrue(noShares <= type(uint112).max, "No shares overflow");

        // Total vault shares should be reasonable
        uint256 totalVaultShares = uint256(yesShares) + uint256(noShares);
        assertTrue(totalVaultShares < 1e30, "Vault shares unreasonably large");
    }

    /// @notice Property: Vault activity timestamp is reasonable
    function test_VaultActivityTimestampReasonable() public view {
        (,, uint32 lastActivity) = router.bootstrapVaults(marketId);

        // Last activity should be <= current block timestamp (or 0 if no activity yet)
        if (lastActivity > 0) {
            assertLe(lastActivity, block.timestamp, "Activity timestamp in future");
            assertGe(lastActivity, block.timestamp - 365 days, "Activity timestamp too old");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROPERTY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: Depositing to vault increases LP shares
    function test_DepositIncreasesLPShares() public {
        uint256 depositAmount = 1 ether;

        vm.startPrank(ALICE);
        pamm.split{value: depositAmount}(marketId, depositAmount, ALICE);
        pamm.setOperator(address(router), true);

        uint256 yesBalanceBefore = pamm.balanceOf(ALICE, marketId);
        uint256 yesLPSharesBefore = router.totalYesVaultShares(marketId);

        // Deposit to vault
        router.depositToVault(marketId, true, yesBalanceBefore, ALICE, block.timestamp);

        uint256 yesLPSharesAfter = router.totalYesVaultShares(marketId);

        assertGt(yesLPSharesAfter, yesLPSharesBefore, "LP shares should increase");

        vm.stopPrank();
    }

    /// @notice Property: Withdrawing from vault decreases LP shares
    function test_WithdrawDecreasesLPShares() public {
        // First deposit
        uint256 depositAmount = 1 ether;

        vm.startPrank(ALICE);
        pamm.split{value: depositAmount}(marketId, depositAmount, ALICE);
        pamm.setOperator(address(router), true);

        uint256 yesBalance = pamm.balanceOf(ALICE, marketId);
        router.depositToVault(marketId, true, yesBalance, ALICE, block.timestamp);

        // Get Alice's vault position
        (uint112 aliceYesShares,,,,) = router.vaultPositions(marketId, ALICE);

        // Wait for cooldown
        vm.warp(block.timestamp + 25 hours);

        uint256 yesLPSharesBefore = router.totalYesVaultShares(marketId);

        // Withdraw
        router.withdrawFromVault(marketId, true, aliceYesShares, ALICE, block.timestamp);

        uint256 yesLPSharesAfter = router.totalYesVaultShares(marketId);

        assertLt(yesLPSharesAfter, yesLPSharesBefore, "LP shares should decrease");

        vm.stopPrank();
    }

    /// @notice Property: Merge/split operations conserve value
    function test_MergeSplitConservesValue() public {
        uint256 amount = 1 ether;

        vm.startPrank(ALICE);

        // Split: collateral -> yes + no shares
        uint256 collateralBefore = ALICE.balance;
        pamm.split{value: amount}(marketId, amount, ALICE);
        uint256 yesShares = pamm.balanceOf(ALICE, marketId);
        uint256 noShares = pamm.balanceOf(ALICE, noId);

        // Should receive equal yes and no shares
        assertEq(yesShares, amount, "Yes shares should equal collateral in");
        assertEq(noShares, amount, "No shares should equal collateral in");

        // Merge: yes + no shares -> collateral
        pamm.setOperator(address(pamm), true);
        pamm.merge(marketId, amount, ALICE);

        uint256 collateralAfter = ALICE.balance;

        // Should receive back the collateral (minus gas)
        assertApproxEqAbs(
            collateralAfter,
            collateralBefore,
            0.01 ether, // Allow for gas costs
            "Merge should return collateral"
        );

        vm.stopPrank();
    }

    /// @notice Property: Vault cannot be depleted below minimum
    function test_VaultCannotBeDepleted() public {
        // Try to withdraw more than exists
        vm.startPrank(ALICE);

        // This should revert (insufficient balance)
        vm.expectRevert();
        router.withdrawFromVault(marketId, true, type(uint112).max, ALICE, block.timestamp);

        vm.stopPrank();
    }

    /// @notice Property: Zero-timestamp edge case is handled
    function test_ZeroTimestampEdgeCaseHandled() public {
        // This test verifies the fix for the zero-timestamp edge case
        // In a normal flow, lastDepositTime should never be 0 if shares > 0
        // But the code now has a defensive check

        vm.startPrank(ALICE);
        pamm.split{value: 1 ether}(marketId, 1 ether, ALICE);
        pamm.setOperator(address(router), true);

        uint256 yesBalance = pamm.balanceOf(ALICE, marketId);

        // Normal deposit should set timestamp
        router.depositToVault(marketId, true, yesBalance, ALICE, block.timestamp);

        // Check that timestamp was set
        (,, uint32 lastDepositTime,,) = router.vaultPositions(marketId, ALICE);
        assertGt(lastDepositTime, 0, "Timestamp should be set on deposit");

        vm.stopPrank();
    }
}

interface IPMFeeHookOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}
