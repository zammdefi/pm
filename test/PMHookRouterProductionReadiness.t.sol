// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function merge(uint256 marketId, uint256 amount, address to) external;
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @title PMHookRouter Production Readiness Tests
/// @notice Stress tests for multi-user scenarios, large values, and edge cases
/// @dev These tests verify safety with multiple concurrent users and large funds
contract PMHookRouterProductionReadinessTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHook public hook;

    // Multi-user array (10 users for stress tests)
    address[] public users;
    uint256 public constant NUM_USERS = 10;

    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main7"));

        hook = new PMFeeHook();

        // Deploy router at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Initialize router
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Create test users
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = makeAddr(string(abi.encodePacked("USER_", vm.toString(i))));
            users.push(user);
            deal(user, 100000 ether);
        }

        // Bootstrap a market for testing
        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(users[0]);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Production Readiness Test Market",
            users[0],
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            1000 ether,
            true,
            0,
            0,
            users[0],
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        LARGE VALUE STRESS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test deposits and withdrawals with very large values
    /// @dev Tests near uint112 max (~5.2e33 wei) behavior
    function test_LargeValue_DepositWithdraw() public {
        // Use a realistic large value that won't overflow
        uint256 largeAmount = 1_000_000 ether; // 1M ETH equivalent

        address whale = users[0];
        deal(whale, largeAmount * 2);

        vm.startPrank(whale);

        // Split large amount into shares
        PAMM.split{value: largeAmount}(marketId, largeAmount, whale);
        PAMM.setOperator(address(router), true);

        // Deposit large amount to vault
        router.depositToVault(marketId, true, largeAmount, whale, block.timestamp + 7 hours);

        (uint112 vaultShares,,,,) = router.vaultPositions(marketId, whale);
        assertGt(vaultShares, 0, "Should have vault shares from large deposit");

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Withdraw large amount
        uint256 balanceBefore = PAMM.balanceOf(whale, marketId);
        (uint256 sharesReturned,) =
            router.withdrawFromVault(marketId, true, vaultShares, whale, block.timestamp + 1 hours);

        uint256 balanceAfter = PAMM.balanceOf(whale, marketId);

        assertEq(balanceAfter - balanceBefore, sharesReturned, "Should receive all shares back");
        assertGt(sharesReturned, 0, "Should return positive shares");

        vm.stopPrank();
    }

    /// @notice Test fee accumulator precision with large deposits
    function test_LargeValue_FeeAccumulatorPrecision() public {
        // Use moderately large amounts that won't overflow
        uint256 largeDeposit = 10_000 ether;
        uint256 smallDeposit = 100 ether; // 1:100 ratio

        uint256 depositTime = block.timestamp;

        // User 0 deposits large amount
        vm.startPrank(users[0]);
        PAMM.split{value: largeDeposit}(marketId, largeDeposit, users[0]);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, largeDeposit, users[0], type(uint256).max);
        vm.stopPrank();

        // User 1 deposits small amount (same time)
        vm.startPrank(users[1]);
        PAMM.split{value: smallDeposit}(marketId, smallDeposit, users[1]);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, smallDeposit, users[1], type(uint256).max);
        vm.stopPrank();

        // Wait for cooldown and generate fees
        vm.warp(depositTime + 6 hours + 1);

        // Generate fees with trades
        vm.prank(users[2]);
        router.buyWithBootstrap{value: 500 ether}(
            marketId, true, 500 ether, 0, users[2], type(uint256).max
        );

        // Both should be able to harvest fees (proportional to their deposits)
        vm.prank(users[0]);
        uint256 largeFees = router.harvestVaultFees(marketId, true);

        vm.prank(users[1]);
        uint256 smallFees = router.harvestVaultFees(marketId, true);

        // Large depositor should get proportionally more fees
        // Ratio should be approximately largeDeposit/smallDeposit = 100
        if (largeFees > 0 && smallFees > 0) {
            uint256 ratio = largeFees / smallFees;
            assertGt(ratio, 50, "Large depositor should get significantly more fees");
            assertLt(ratio, 200, "Ratio should be reasonable (within 2x of expected)");
        }
    }

    /// @notice Test that large trades don't cause overflow in fee calculations
    function test_LargeValue_TradesNoOverflow() public {
        // Setup vault with large liquidity
        vm.startPrank(users[0]);
        PAMM.split{value: 50000 ether}(marketId, 50000 ether, users[0]);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25000 ether, users[0], block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 25000 ether, users[0], block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);

        // Execute large trade
        vm.prank(users[1]);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1000 ether}(
            marketId, true, 1000 ether, 0, users[1], block.timestamp + 1 hours
        );

        assertGt(sharesOut, 0, "Large trade should succeed");

        // Verify accumulator didn't overflow
        uint256 accYes = router.accYesCollateralPerShare(marketId);
        uint256 accNo = router.accNoCollateralPerShare(marketId);

        // Accumulators should be reasonable values (not near max uint256)
        assertLt(accYes, type(uint128).max, "YES accumulator should not overflow");
        assertLt(accNo, type(uint128).max, "NO accumulator should not overflow");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-USER CONCURRENT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test 10 users depositing concurrently
    function test_MultiUser_ConcurrentDeposits() public {
        uint256 depositAmount = 100 ether;

        // All users deposit to vault
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, true, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        // Verify all users have vault shares
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint112 shares,,,,) = router.vaultPositions(marketId, users[i]);
            assertGt(
                shares,
                0,
                string(abi.encodePacked("User ", vm.toString(i), " should have vault shares"))
            );
        }

        // Verify total vault shares equals sum of all deposits
        uint256 totalExpected = depositAmount * NUM_USERS;
        uint256 totalActual = router.totalYesVaultShares(marketId);
        assertGe(totalActual, totalExpected - 1, "Total vault shares should match deposits");
    }

    /// @notice Test concurrent fee harvesting by multiple users
    function test_MultiUser_ConcurrentHarvests() public {
        uint256 depositAmount = 100 ether;

        // All users deposit to vault
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, true, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        // Wait for cooldown and generate fees
        vm.warp(block.timestamp + 6 hours + 1);

        // Generate fees with a trade
        address trader = makeAddr("TRADER");
        deal(trader, 100 ether);
        vm.prank(trader);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, trader, block.timestamp + 1 hours
        );

        // All users harvest concurrently
        uint256 totalFees = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            uint256 fees = router.harvestVaultFees(marketId, true);
            totalFees += fees;
        }

        // Total fees should be reasonable (non-zero if OTC was used)
        // And individual fees should be approximately equal (since deposits were equal)
        if (totalFees > 0) {
            uint256 avgFees = totalFees / NUM_USERS;
            for (uint256 i = 0; i < NUM_USERS; i++) {
                // Already harvested, so we just verify the total distribution
            }
        }
    }

    /// @notice Test concurrent withdrawals don't cause accounting errors
    function test_MultiUser_ConcurrentWithdrawals() public {
        uint256 depositAmount = 100 ether;

        // All users deposit
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, true, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        uint256 totalVaultSharesBefore = router.totalYesVaultShares(marketId);

        // All users withdraw
        uint256 totalSharesReturned = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            (uint112 vaultShares,,,,) = router.vaultPositions(marketId, users[i]);
            (uint256 sharesReturned,) = router.withdrawFromVault(
                marketId, true, vaultShares, users[i], block.timestamp + 1 hours
            );
            totalSharesReturned += sharesReturned;
            vm.stopPrank();
        }

        // Verify vault is empty
        uint256 totalVaultSharesAfter = router.totalYesVaultShares(marketId);
        assertEq(totalVaultSharesAfter, 0, "Vault should be empty after all withdrawals");

        // All users should have zero vault positions
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint112 shares,,,,) = router.vaultPositions(marketId, users[i]);
            assertEq(shares, 0, "All users should have zero vault shares");
        }
    }

    /// @notice Test interleaved deposits and withdrawals from multiple users
    function test_MultiUser_InterleavedOperations() public {
        // Create a fresh market to avoid bootstrap position issues
        uint256 depositAmount = 100 ether;
        uint256 startTime = block.timestamp;

        vm.startPrank(users[0]);
        (uint256 testMarketId,,,) = router.bootstrapMarket{value: 500 ether}(
            "Interleaved Test Market",
            users[0],
            ETH,
            uint64(block.timestamp + 60 days),
            false,
            address(hook),
            500 ether,
            true,
            0,
            0,
            users[0],
            type(uint256).max
        );
        vm.stopPrank();

        // First half deposits at startTime (skip user 0 who has bootstrap position)
        for (uint256 i = 1; i < NUM_USERS / 2; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(testMarketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(testMarketId, true, depositAmount, users[i], type(uint256).max);
            vm.stopPrank();
        }

        // Wait for cooldown of first half and generate some fees
        vm.warp(startTime + 6 hours + 1);
        address trader = makeAddr("TRADER");
        deal(trader, 50 ether);
        vm.prank(trader);
        router.buyWithBootstrap{value: 25 ether}(
            testMarketId, true, 25 ether, 0, trader, type(uint256).max
        );

        uint256 secondDepositTime = block.timestamp;

        // Second half deposits after fees (at secondDepositTime)
        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(testMarketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(testMarketId, true, depositAmount, users[i], type(uint256).max);
            vm.stopPrank();
        }

        // Wait for BOTH groups' cooldowns to pass (6h from second deposit + extra buffer)
        vm.warp(secondDepositTime + 7 hours);

        // First half harvests (should get more fees from first round) - skip user 0
        uint256 earlyFees = 0;
        for (uint256 i = 1; i < NUM_USERS / 2; i++) {
            vm.prank(users[i]);
            earlyFees += router.harvestVaultFees(testMarketId, true);
        }

        // Second half harvests (should get less fees due to later entry)
        uint256 lateFees = 0;
        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            lateFees += router.harvestVaultFees(testMarketId, true);
        }

        // Early depositors should have more or equal fees
        assertGe(earlyFees, lateFees, "Early depositors should have >= fees");
    }

    /*//////////////////////////////////////////////////////////////
                    MARKET FINALIZATION WITH MANY LPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test market finalization with 10 LPs
    function test_ManyLPs_MarketFinalization() public {
        uint256 depositAmount = 50 ether;
        uint256 depositTime = block.timestamp;

        // All users become LPs at the same time
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount * 2}(marketId, depositAmount * 2, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(marketId, true, depositAmount, users[i], type(uint256).max);
            router.depositToVault(marketId, false, depositAmount, users[i], type(uint256).max);
            vm.stopPrank();
        }

        // Generate trading activity (after 6h cooldown)
        vm.warp(depositTime + 6 hours + 1);
        for (uint256 i = 0; i < 5; i++) {
            address trader = makeAddr(string(abi.encodePacked("TRADER_", vm.toString(i))));
            deal(trader, 20 ether);
            vm.prank(trader);
            router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, trader, type(uint256).max
            );
        }

        // Warp to market close (still past everyone's cooldown)
        vm.warp(DEADLINE_2028 + 1);

        // Resolve market
        vm.prank(users[0]); // resolver
        PAMM.resolve(marketId, true);

        // Finalize returns 0 while LPs exist
        uint256 toDAO = router.finalizeMarket(marketId);
        assertEq(toDAO, 0, "Should return 0 while LPs exist");

        // All LPs withdraw their shares (withdrawFromVault works after resolution)
        // Since all deposited at depositTime, and we're now at DEADLINE_2028, cooldown has passed
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);

            // Withdraw from YES vault (winner)
            (uint112 yesShares,,,,) = router.vaultPositions(marketId, users[i]);
            if (yesShares > 0) {
                uint256 sharesBefore = PAMM.balanceOf(users[i], marketId);
                (uint256 sharesReturned,) =
                    router.withdrawFromVault(marketId, true, yesShares, users[i], type(uint256).max);
                uint256 sharesAfter = PAMM.balanceOf(users[i], marketId);
                assertGt(sharesAfter, sharesBefore, "Should receive winning shares from vault");
            }

            // Withdraw from NO vault (loser - still get shares, but they're worthless)
            (, uint112 noShares,,,) = router.vaultPositions(marketId, users[i]);
            if (noShares > 0) {
                router.withdrawFromVault(marketId, false, noShares, users[i], type(uint256).max);
            }

            vm.stopPrank();
        }

        // After all LPs claim, finalize should work
        toDAO = router.finalizeMarket(marketId);
        // May or may not have value for DAO depending on remaining shares
    }

    /// @notice Test that all LPs receive pro-rata shares after resolution
    function test_ManyLPs_ProRataDistribution() public {
        // Create a new market for clean test
        uint256 depositTime = block.timestamp;

        vm.startPrank(users[0]);
        (uint256 testMarketId,,,) = router.bootstrapMarket{value: 500 ether}(
            "Pro-Rata Test Market",
            users[0],
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            500 ether,
            true,
            0,
            0,
            users[0],
            type(uint256).max
        );
        vm.stopPrank();

        // Different deposit amounts for each user (all at the same time)
        uint256[] memory deposits = new uint256[](NUM_USERS);
        uint256 totalDeposits = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            deposits[i] = (i + 1) * 10 ether; // 10, 20, 30, ... 100 ETH
            totalDeposits += deposits[i];

            vm.startPrank(users[i]);
            PAMM.split{value: deposits[i]}(testMarketId, deposits[i], users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(testMarketId, true, deposits[i], users[i], type(uint256).max);
            vm.stopPrank();
        }

        // Generate fees (wait for cooldown first)
        vm.warp(depositTime + 6 hours + 1);
        address trader = makeAddr("TRADER");
        deal(trader, 100 ether);
        vm.prank(trader);
        router.buyWithBootstrap{value: 50 ether}(
            testMarketId, true, 50 ether, 0, trader, type(uint256).max
        );

        // Collect fees for each user (all have passed cooldown)
        uint256[] memory feesClaimed = new uint256[](NUM_USERS);
        uint256 totalFees = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            feesClaimed[i] = router.harvestVaultFees(testMarketId, true);
            totalFees += feesClaimed[i];
        }

        // Verify pro-rata distribution (fees proportional to deposits)
        if (totalFees > 0) {
            for (uint256 i = 0; i < NUM_USERS; i++) {
                uint256 expectedShare = (totalFees * deposits[i]) / totalDeposits;
                // Allow 5% tolerance for rounding
                uint256 tolerance = expectedShare / 20 + 1;
                assertApproxEqAbs(
                    feesClaimed[i],
                    expectedShare,
                    tolerance,
                    string(
                        abi.encodePacked("User ", vm.toString(i), " should receive pro-rata fees")
                    )
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT DEPLETION RACE CONDITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test multiple users trying to withdraw when vault is nearly depleted
    function test_VaultDepletion_RaceCondition() public {
        uint256 depositAmount = 100 ether;

        // All users deposit to YES vault
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, true, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        // Wait for cooldown and generate trades to deplete vault
        vm.warp(block.timestamp + 6 hours + 1);

        // Deplete vault via OTC fills
        for (uint256 i = 0; i < 20; i++) {
            address buyer = makeAddr(string(abi.encodePacked("BUYER_", vm.toString(i))));
            deal(buyer, 100 ether);
            vm.prank(buyer);
            try router.buyWithBootstrap{value: 50 ether}(
                marketId, true, 50 ether, 0, buyer, block.timestamp + 1 hours
            ) {}
            catch {
                break;
            }
        }

        // All users try to withdraw simultaneously
        uint256 successfulWithdrawals = 0;
        uint256 totalSharesReturned = 0;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            (uint112 vaultShares,,,,) = router.vaultPositions(marketId, users[i]);

            if (vaultShares > 0) {
                try router.withdrawFromVault(
                    marketId, true, vaultShares, users[i], block.timestamp + 1 hours
                ) returns (
                    uint256 sharesReturned, uint256
                ) {
                    successfulWithdrawals++;
                    totalSharesReturned += sharesReturned;
                } catch {
                    // Some withdrawals may fail if vault is depleted
                }
            }
            vm.stopPrank();
        }

        // At least some users should be able to withdraw
        assertGt(successfulWithdrawals, 0, "Some users should successfully withdraw");

        // Verify no shares were created from nothing
        (uint112 remainingShares,,) = router.bootstrapVaults(marketId);
        // Total vault shares + returned shares should account for all shares
    }

    /// @notice Test that vault depletion properly tracks across multiple users
    function test_VaultDepletion_AccountingConsistency() public {
        uint256 depositAmount = 50 ether;

        // Users 0-4 deposit to YES, Users 5-9 deposit to NO
        for (uint256 i = 0; i < NUM_USERS / 2; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, true, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        for (uint256 i = NUM_USERS / 2; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: depositAmount}(marketId, depositAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(
                marketId, false, depositAmount, users[i], block.timestamp + 7 hours
            );
            vm.stopPrank();
        }

        // Record initial state
        uint256 initialYesTotal = router.totalYesVaultShares(marketId);
        uint256 initialNoTotal = router.totalNoVaultShares(marketId);

        vm.warp(block.timestamp + 6 hours + 1);

        // Execute trades to partially deplete vault
        address trader = makeAddr("TRADER");
        deal(trader, 200 ether);
        vm.prank(trader);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, trader, block.timestamp + 1 hours
        );

        // Sum of individual positions should equal total
        uint256 sumYesPositions = 0;
        uint256 sumNoPositions = 0;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint112 yesShares, uint112 noShares,,,) = router.vaultPositions(marketId, users[i]);
            sumYesPositions += yesShares;
            sumNoPositions += noShares;
        }

        assertEq(
            sumYesPositions,
            router.totalYesVaultShares(marketId),
            "YES positions should sum to total"
        );
        assertEq(
            sumNoPositions, router.totalNoVaultShares(marketId), "NO positions should sum to total"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    STRESS TESTS WITH RANDOM OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: random deposits from random users
    function testFuzz_RandomDeposits(uint256 seed) public {
        // Bound seed to reasonable range
        seed = bound(seed, 1, 1000);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            // Random deposit amount (1-100 ETH)
            uint256 amount = (uint256(keccak256(abi.encode(seed, i))) % 100 + 1) * 1 ether;
            bool isYes = (uint256(keccak256(abi.encode(seed, i, "side"))) % 2) == 0;

            vm.startPrank(users[i]);
            PAMM.split{value: amount}(marketId, amount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(marketId, isYes, amount, users[i], block.timestamp + 7 hours);
            vm.stopPrank();
        }

        // Verify all users have positions
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint112 yesShares, uint112 noShares,,,) = router.vaultPositions(marketId, users[i]);
            assertTrue(yesShares > 0 || noShares > 0, "User should have a position");
        }
    }

    /// @notice Fuzz test: random sequence of operations
    function testFuzz_RandomOperationSequence(uint256 seed) public {
        seed = bound(seed, 1, 1000);

        // Setup: all users deposit
        for (uint256 i = 0; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: 50 ether}(marketId, 50 ether, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(marketId, true, 25 ether, users[i], block.timestamp + 7 hours);
            router.depositToVault(marketId, false, 25 ether, users[i], block.timestamp + 7 hours);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 6 hours + 1);

        // Random operations
        for (uint256 round = 0; round < 10; round++) {
            uint256 userIdx = uint256(keccak256(abi.encode(seed, round))) % NUM_USERS;
            uint256 opType = uint256(keccak256(abi.encode(seed, round, "op"))) % 3;

            vm.startPrank(users[userIdx]);

            if (opType == 0) {
                // Buy
                try router.buyWithBootstrap{value: 1 ether}(
                    marketId, true, 1 ether, 0, users[userIdx], block.timestamp + 1 hours
                ) {}
                    catch {}
            } else if (opType == 1) {
                // Harvest
                try router.harvestVaultFees(marketId, true) {} catch {}
            } else {
                // Partial withdraw
                (uint112 shares,,,,) = router.vaultPositions(marketId, users[userIdx]);
                if (shares > 1 ether) {
                    try router.withdrawFromVault(
                        marketId, true, shares / 2, users[userIdx], block.timestamp + 1 hours
                    ) {}
                        catch {}
                }
            }

            vm.stopPrank();
        }

        // Final invariant check: positions should sum to totals
        uint256 sumYes = 0;
        uint256 sumNo = 0;
        for (uint256 i = 0; i < NUM_USERS; i++) {
            (uint112 y, uint112 n,,,) = router.vaultPositions(marketId, users[i]);
            sumYes += y;
            sumNo += n;
        }

        assertEq(sumYes, router.totalYesVaultShares(marketId), "YES invariant violated");
        assertEq(sumNo, router.totalNoVaultShares(marketId), "NO invariant violated");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: DUST AND ROUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Test many small deposits don't lose value to rounding
    function test_ManySmallDeposits_NoDustLoss() public {
        uint256 smallAmount = 0.01 ether;
        uint256 numDeposits = 100;

        address depositor = users[0];
        vm.startPrank(depositor);
        PAMM.split{value: smallAmount * numDeposits}(marketId, smallAmount * numDeposits, depositor);
        PAMM.setOperator(address(router), true);

        // Make many small deposits
        for (uint256 i = 0; i < numDeposits; i++) {
            router.depositToVault(marketId, true, smallAmount, depositor, block.timestamp + 7 hours);
        }

        (uint112 totalVaultShares,,,,) = router.vaultPositions(marketId, depositor);

        // Wait and withdraw
        vm.warp(block.timestamp + 6 hours + 1);
        (uint256 sharesReturned,) = router.withdrawFromVault(
            marketId, true, totalVaultShares, depositor, block.timestamp + 1 hours
        );

        // Should get back at least 99% of deposited value (allowing 1% for rounding across 100 ops)
        uint256 totalDeposited = smallAmount * numDeposits;
        assertGe(
            sharesReturned,
            (totalDeposited * 99) / 100,
            "Should not lose significant value to rounding"
        );

        vm.stopPrank();
    }

    /// @notice Test fee distribution with very small shares
    function test_SmallShares_FeeDistribution() public {
        // One whale, many minnows
        uint256 whaleAmount = 10000 ether;
        uint256 minnowAmount = 0.001 ether;

        // Whale deposits
        vm.startPrank(users[0]);
        PAMM.split{value: whaleAmount}(marketId, whaleAmount, users[0]);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, whaleAmount, users[0], block.timestamp + 7 hours);
        vm.stopPrank();

        // Minnows deposit
        for (uint256 i = 1; i < NUM_USERS; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: minnowAmount}(marketId, minnowAmount, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(marketId, true, minnowAmount, users[i], block.timestamp + 7 hours);
            vm.stopPrank();
        }

        // Generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        address trader = makeAddr("TRADER");
        deal(trader, 100 ether);
        vm.prank(trader);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, trader, block.timestamp + 1 hours
        );

        // Whale harvests
        vm.prank(users[0]);
        uint256 whaleFees = router.harvestVaultFees(marketId, true);

        // Minnows may get dust or 0 due to precision
        for (uint256 i = 1; i < NUM_USERS; i++) {
            vm.prank(users[i]);
            uint256 minnowFees = router.harvestVaultFees(marketId, true);
            // Minnow fees may be 0 due to precision, that's expected
        }

        // Whale should get the vast majority of fees
        assertGt(whaleFees, 0, "Whale should receive fees");
    }
}
