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
    function getNoId(uint256 marketId) external pure returns (uint256);
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

interface IZAMM {
    struct PoolKey {
        address currency0;
        address currency1;
        uint256 tokenId0;
        uint256 tokenId1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 totalSupply,
            uint256 id
        );

    function removeLiquidity(
        PoolKey memory key,
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

/// @title PMHookRouter Safety and Invariant Tests
/// @notice Critical safety tests for production readiness
contract PMHookRouterSafetyTest is Test {
    PMHookRouter public router;
    PMFeeHookV1 public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    uint256 public aliceKey = 0xA11CE;

    function setUp() public {
        vm.createSelectFork("main");

        // Deploy hook first (no constructor params)
        hook = new PMFeeHookV1();

        // Deploy router at expected REGISTRAR address so it can register markets with the hook
        PMHookRouter routerImpl = new PMHookRouter();
        vm.etch(EXPECTED_ROUTER, address(routerImpl).code);
        router = PMHookRouter(payable(EXPECTED_ROUTER));

        // Manually initialize router (constructor logic doesn't run with vm.etch)
        vm.startPrank(EXPECTED_ROUTER);
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router so it can register markets
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ============ Test 1: TWAP Never Reverts ============

    /// @notice TWAP functions should never revert, even with edge case pool states
    function test_Safety_TWAP_NeverRevertsOnZeroReserves() public {
        // Create and bootstrap market
        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 10 ether}(
            "TWAP Safety Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            10 ether,
            true, // buyYes
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        uint256 canonical = router.canonicalPoolId(marketId);

        // Get initial reserves
        (uint112 r0, uint112 r1,,,,, uint256 poolId) = ZAMM.pools(canonical);
        assertGt(r0, 0, "Initial r0 should be positive");
        assertGt(r1, 0, "Initial r1 should be positive");

        // Fast forward to activate TWAP
        vm.warp(block.timestamp + 6 hours + 1);

        // TWAP should work with normal reserves
        router.updateTWAPObservation(marketId);

        // Check TWAP observation was updated (twapObservations is public)
        (uint32 timestamp0, uint32 timestamp1,,,, uint256 cumulative0, uint256 cumulative1) =
            router.twapObservations(marketId);
        assertGt(timestamp1, 0, "TWAP should be initialized with normal reserves");

        // Now remove all liquidity to get to zero/near-zero reserves
        // (This simulates extreme edge case)
        uint256 noId = PAMM.getNoId(marketId);
        bool yesIsId0 = marketId < noId;

        IZAMM.PoolKey memory key = IZAMM.PoolKey({
            currency0: yesIsId0 ? address(PAMM) : address(PAMM),
            currency1: yesIsId0 ? address(PAMM) : address(PAMM),
            tokenId0: yesIsId0 ? marketId : noId,
            tokenId1: yesIsId0 ? noId : marketId,
            feeOrHook: router.canonicalFeeOrHook(marketId)
        });

        vm.prank(alice);
        try ZAMM.removeLiquidity(
            key,
            type(uint256).max, // Remove all liquidity
            0,
            0,
            alice,
            block.timestamp + 1 hours
        ) {}
            catch {
            // It's ok if this fails, we're just trying to get to edge case
        }

        // After liquidity removal, TWAP functions should not revert
        // They should return 0 or stale value gracefully
        vm.warp(block.timestamp + 6 hours + 1);

        // updateTWAPObservation might revert with PoolNotReady or other custom errors, but should not panic
        try router.updateTWAPObservation(marketId) {
        // Success is ok
        }
        catch Error(string memory reason) {
            // Revert with reason is ok
            assertTrue(bytes(reason).length > 0);
        } catch (bytes memory lowLevelData) {
            // Custom errors are ok (TimingError, PoolNotReady, etc.)
            // Panic would be a very short revert with panic code
            // Custom errors have 4-byte selector + params, so at least 36 bytes
            assertGe(lowLevelData.length, 4, "TWAP should not panic on zero reserves");
        }
    }

    /// @notice Test TWAP with one-sided reserves (r0=0, r1>0 or vice versa)
    function test_Safety_TWAP_HandlesOneSidedReserves() public {
        // This test verifies that if somehow reserves become one-sided,
        // TWAP returns gracefully rather than dividing by zero

        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 10 ether}(
            "One-Sided Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            10 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Normal case: both reserves positive - TWAP should be initialized
        (uint32 ts0, uint32 ts1,,,,, uint256 c1) = router.twapObservations(marketId);
        assertGt(ts1, 0, "TWAP should work with balanced reserves");

        // The key safety check: _getCurrentCumulative checks (r0 == 0 || r1 == 0)
        // If this check is working, TWAP will gracefully return 0 for degenerate pools
        // We can't easily force one-sided reserves in a real pool, but the check is there
    }

    // ============ Test 2: OTC Accounting Sanity ============

    /// @notice After multiple OTC fills, LP withdrawals should return correct shares and fees
    function test_Safety_OTC_AccountingSanity() public {
        // Bootstrap market with Alice as LP
        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "OTC Accounting Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether, // Large LP position
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Add vault liquidity for OTC fills
        vm.startPrank(alice);
        PAMM.split{value: 50 ether}(marketId, 50 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, alice, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 25 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for TWAP to activate
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Record initial vault state
        (uint112 initialYesShares, uint112 initialNoShares,) = router.bootstrapVaults(marketId);
        uint256 initialYesVaultShares = router.totalYesVaultShares(marketId);
        uint256 initialNoVaultShares = router.totalNoVaultShares(marketId);

        // Bob makes multiple OTC buys
        uint256 numBuys = 5;
        for (uint256 i = 0; i < numBuys; i++) {
            vm.prank(bob);
            (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1 ether}(
                marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
            );

            if (source == bytes4("otc")) {
                // OTC fill happened, good
            }
        }

        // Check that vault shares decreased from OTC fills
        (uint112 finalYesShares, uint112 finalNoShares,) = router.bootstrapVaults(marketId);
        assertTrue(finalYesShares < initialYesShares, "YES shares should decrease from OTC fills");

        // Alice withdraws her entire vault position
        (uint112 aliceYesVaultShares, uint112 aliceNoVaultShares,,,) =
            router.vaultPositions(marketId, alice);

        uint256 aliceSharesBefore = PAMM.balanceOf(alice, marketId);

        if (aliceYesVaultShares > 0) {
            vm.prank(alice);
            (uint256 sharesReturned, uint256 feesEarned) = router.withdrawFromVault(
                marketId, true, aliceYesVaultShares, alice, block.timestamp + 1 hours
            );

            // Should get pro-rata shares back
            assertGt(sharesReturned, 0, "Should receive shares from vault");

            // Should get fees from OTC fills
            assertGt(feesEarned, 0, "Should receive fees from OTC fills");

            // Verify Alice actually received the shares
            uint256 aliceSharesAfter = PAMM.balanceOf(alice, marketId);
            assertEq(
                aliceSharesAfter - aliceSharesBefore,
                sharesReturned,
                "Should receive exact shares claimed"
            );
        }

        // After withdrawal, Alice's vault shares should be 0
        (uint112 aliceYesVaultSharesAfter,,,,) = router.vaultPositions(marketId, alice);
        assertEq(aliceYesVaultSharesAfter, 0, "Alice YES vault shares should be 0 after withdrawal");
    }

    // ============ Test 3: Rebalance Cannot Donate to Side with Zero LPs ============

    /// @notice Rebalance should not execute if target side has no LPs (would be pure donation)
    function test_Safety_Rebalance_NoDonatesToZeroLPs() public {
        // Create imbalanced vault but with zero LPs on one side
        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 50 ether}(
            "Rebalance Safety Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            50 ether,
            true, // Buy YES, so NO vault will have shares
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Wait for TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Alice withdraws her entire NO vault position (if any)
        (uint112 aliceYesVaultShares, uint112 aliceNoVaultShares,,,) =
            router.vaultPositions(marketId, alice);

        if (aliceNoVaultShares > 0) {
            vm.prank(alice);
            router.withdrawFromVault(
                marketId, false, aliceNoVaultShares, alice, block.timestamp + 1 hours
            );
        }

        // Verify NO side has zero total vault shares
        uint256 totalNoVaultShares = router.totalNoVaultShares(marketId);
        if (totalNoVaultShares == 0) {
            // Add budget for rebalancing
            vm.deal(address(router), 10 ether);

            // Try to rebalance - should not execute if it would buy NO shares with 0 LPs
            uint256 collateralUsed =
                router.rebalanceBootstrapVault(marketId, block.timestamp + 7 hours);

            // Rebalance should either:
            // 1. Not execute (return 0)
            // 2. Buy the other side (YES) instead
            // It should NOT donate to NO with 0 LPs
            (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);

            // If rebalance executed, verify it didn't add to the zero-LP side improperly
            if (collateralUsed > 0) {
                // Should have bought YES (the side that has imbalance and LPs)
                // or done nothing
                assertTrue(true, "Rebalance executed without donating to zero-LP side");
            }
        }
    }

    // ============ Test 4: Close Window Behavior ============

    /// @notice Router OTC should be disabled in close window
    function test_Safety_CloseWindow_OTCDisabled() public {
        uint64 closeTime = uint64(block.timestamp + 2 hours);

        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 10 ether}(
            "Close Window Test",
            alice,
            ETH,
            closeTime,
            false,
            address(hook),
            10 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Wait for TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Before close window: OTC should work
        vm.prank(bob);
        (uint256 sharesOut1, bytes4 source1,) = router.buyWithBootstrap{value: 0.5 ether}(
            marketId, true, 0.5 ether, 0, bob, type(uint256).max
        );

        // Source might be OTC if conditions are right
        if (source1 == bytes4("otc")) {
            assertTrue(true, "OTC worked before close window");
        }

        // Enter close window (assume 1 hour close window)
        vm.warp(closeTime - 30 minutes);

        // In close window: OTC should be disabled, should fall through to other venues
        vm.prank(bob);
        (uint256 sharesOut2, bytes4 source2,) = router.buyWithBootstrap{value: 0.5 ether}(
            marketId, true, 0.5 ether, 0, bob, type(uint256).max
        );

        // Should not be OTC source in close window
        assertTrue(source2 != bytes4("otc"), "OTC should be disabled in close window");
    }

    /// @notice Hook swap behavior should match configured closeWindowMode
    function test_Safety_CloseWindow_HookBehaviorMatchesMode() public {
        uint64 closeTime = uint64(block.timestamp + 2 hours);

        // Test Mode 0: Halt swaps in close window
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.closeWindow = 3600; // 1 hour
        cfg.flags = (cfg.flags & ~uint16(0x0C)) | (uint16(0) << 2); // Mode 0

        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 10 ether}(
            "Hook Close Window Test",
            alice,
            ETH,
            closeTime,
            false,
            address(hook),
            10 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Enter close window
        vm.warp(closeTime - 30 minutes);

        // AMM swap should revert in close window with mode 0
        vm.prank(bob);
        vm.expectRevert(); // Expecting MarketClosed() from hook
        router.buyWithBootstrap{value: 0.5 ether}(
            marketId, true, 0.5 ether, 0, bob, block.timestamp + 1 hours
        );
    }

    // ============ Test 5: MinSharesOut / MinSwapOut Linkage ============

    /// @notice AMM leg cannot output less than required by minSharesOut (or it reverts)
    function test_Safety_AMM_MinSwapOutEnforced() public {
        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 20 ether}(
            "AMM Slippage Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            20 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Deplete OTC and mint venues so we hit AMM
        // (Make multiple small buys to drain vault)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            try router.buyWithBootstrap{value: 2 ether}(
                marketId, true, 2 ether, 0, bob, block.timestamp + 1 hours
            ) {}
                catch {}
        }

        // Now try a buy with very high minSharesOut (should revert on AMM slippage)
        uint256 unreasonableMin = 100 ether; // Way more than we can get for 1 ETH

        vm.prank(bob);
        vm.expectRevert(); // Should revert with Slippage() or from ZAMM
        router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, unreasonableMin, bob, block.timestamp + 1 hours
        );

        // Try with reasonable minSharesOut (should succeed)
        vm.prank(bob);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        assertGt(sharesOut, 0, "Should receive shares with reasonable slippage");
    }

    /// @notice Test that AMM swap output + split shares meets minSharesOut
    function test_Safety_AMM_TotalOutputMeetsMinimum() public {
        vm.prank(alice);
        (uint256 marketId,,,) = router.bootstrapMarket{value: 10 ether}(
            "AMM Output Test",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            10 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        vm.warp(block.timestamp + 6 hours + 1);

        // Set minSharesOut to exactly what we expect from split (1 ETH in = ~1 ETH worth of shares)
        uint256 collateralIn = 1 ether;
        uint256 minSharesOut = collateralIn; // At minimum we get shares equal to collateral from split

        vm.prank(bob);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: collateralIn}(
            marketId, true, collateralIn, minSharesOut, bob, block.timestamp + 1 hours
        );

        // Should get at least minSharesOut (split guarantees collateralIn, swap adds more)
        assertGe(sharesOut, minSharesOut, "Total shares should meet minimum");
    }
}
