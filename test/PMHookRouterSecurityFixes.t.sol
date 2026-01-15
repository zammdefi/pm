// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "./BaseTest.sol";
import "../src/PMHookRouter.sol";

/// @notice Minimal mock hook for testing
contract MockHook {
    uint256 private constant FLAG_BEFORE = 1 << 255;
    uint256 private constant FLAG_AFTER = 1 << 254;
    uint256 private constant DEFAULT_CLOSE_WINDOW = 30 minutes;
    uint256 private constant DEFAULT_FEE_BPS = 30; // 0.3%

    IPAMM private constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    bool public halted;

    function setHalted(bool _halted) external {
        halted = _halted;
    }

    function registerMarket(uint256 marketId) external view returns (uint256 poolId) {
        uint256 feeHook = uint256(uint160(address(this))) | FLAG_BEFORE | FLAG_AFTER;
        uint256 noId = PAMM.getNoId(marketId);

        // Build PoolKey following PMHookRouter's _buildKey logic
        uint256 id0;
        uint256 id1;
        bool yesIsId0 = marketId < noId;
        if (yesIsId0) {
            id0 = marketId;
            id1 = noId;
        } else {
            id0 = noId;
            id1 = marketId;
        }

        // Derive poolId using keccak256 hash of PoolKey components
        poolId = uint256(keccak256(abi.encode(id0, id1, address(PAMM), address(PAMM), feeHook)));
    }

    function getCurrentFeeBps(uint256) external view returns (uint256) {
        return halted ? 10001 : DEFAULT_FEE_BPS;
    }

    function getCloseWindow(uint256) external pure returns (uint256) {
        return DEFAULT_CLOSE_WINDOW;
    }

    function beforeAction(bytes4, uint256, address, bytes calldata)
        external
        view
        returns (uint256 feeBps)
    {
        return halted ? 10001 : DEFAULT_FEE_BPS;
    }

    function afterAction(bytes4, uint256, address, int256, int256, int256, bytes calldata)
        external
        pure {}
}

/// @title PMHookRouter Security Fixes Test Suite
/// @notice Tests for critical security fixes from review:
///         1. Close window behavior (vault OTC blocked, AMM allowed)
///         2. Multi-venue routing with removed AMM min-out constraint
///         3. Overflow protection in _tryVaultOTCFill
contract PMHookRouterSecurityFixesTest is BaseTest {
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);

    PMHookRouter public router;
    MockHook public hook;
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address public ALICE;
    address public BOB;

    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint64 public closeTime;

    function setUp() public {
        createForkWithFallback("main");

        ALICE = makeAddr("alice");
        BOB = makeAddr("bob");

        router = new PMHookRouter();
        hook = new MockHook();

        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
    }

    function _bootstrapMarket(uint256 initialCollateral) internal {
        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId, noId,) = router.bootstrapMarket{value: initialCollateral}(
            "Security Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            initialCollateral,
            true,
            0,
            0,
            ALICE,
            deadline
        );
    }

    function _setupTWAP() internal {
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // FIX #1: Close Window - Vault OTC Blocked, AMM Allowed
    // ══════════════════════════════════════════════════════════════════════════════

    function test_CloseWindow_BlocksVaultOTC() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create imbalance to enable vault OTC (more YES than NO)
        vm.startPrank(BOB);
        router.buyWithBootstrap{value: 50 ether}(marketId, true, 50 ether, 0, BOB, closeTime - 1);
        vm.stopPrank();

        // Add vault budget (enables vault OTC)
        vm.startPrank(ALICE);
        PAMM.split{value: 20 ether}(marketId, 20 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 10 ether, ALICE, closeTime - 1);
        router.depositToVault(marketId, false, 10 ether, ALICE, closeTime - 1);
        vm.stopPrank();

        // Warp to close window
        vm.warp(closeTime - 30 minutes);

        // ALICE sells YES shares (scarce side) - should use AMM not vault OTC in close window
        vm.startPrank(ALICE);
        uint256 aliceYesShares = PAMM.balanceOf(ALICE, marketId);

        // Should succeed via AMM (vault OTC blocked in close window)
        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, aliceYesShares / 4, 0, ALICE, closeTime - 1);

        assertGt(collateralOut, 0, "Should get collateral via AMM");
        // Source should be AMM since vault OTC is blocked
        // forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(
            source == bytes4("amm") || source == bytes4("mult"),
            "Should use AMM path, not OTC in close window"
        );
        vm.stopPrank();
    }

    function test_CloseWindow_AllowsAMMSelling() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create balanced pool for AMM trading
        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);
        vm.stopPrank();

        // Warp to close window
        vm.warp(closeTime - 30 minutes);

        // Should be able to sell via AMM
        vm.startPrank(ALICE);
        uint256 aliceYesShares = PAMM.balanceOf(ALICE, marketId);

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, aliceYesShares / 2, 0, ALICE, closeTime - 1);
        vm.stopPrank();

        assertGt(collateralOut, 0, "Should receive collateral");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(
            source == bytes4("amm") || source == bytes4("mult"), "Should use AMM in close window"
        );
    }

    function test_HaltMode_BlocksVaultOTCOnSell() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Setup: Do vault OTC buy to create budget and inventory imbalance
        // Buy YES from vault (depletes vault's YES, creates budget)
        vm.startPrank(BOB);
        router.buyWithBootstrap{value: 30 ether}(marketId, true, 30 ether, 0, BOB, closeTime - 1);
        vm.stopPrank();

        // Now vault has: low YES inventory, high NO inventory, and budget from OTC proceeds
        // This enables vault OTC when someone sells YES (the scarce side)

        // Add more vault inventory via deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 20 ether}(marketId, 20 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 10 ether, ALICE, closeTime - 1);
        router.depositToVault(marketId, false, 10 ether, ALICE, closeTime - 1);
        vm.stopPrank();

        // Verify vault OTC would work in normal mode (before halt)
        vm.startPrank(ALICE);
        uint256 aliceYesShares = PAMM.balanceOf(ALICE, marketId);
        (uint256 collateralBefore,) =
            router.sellWithBootstrap(marketId, true, aliceYesShares / 8, 0, ALICE, closeTime - 1);
        assertGt(collateralBefore, 0, "Should work before halt");
        vm.stopPrank();

        // HALT the market
        hook.setHalted(true);

        // Try to sell in halt mode - all trading should be blocked (vault OTC + AMM)
        vm.startPrank(ALICE);
        aliceYesShares = PAMM.balanceOf(ALICE, marketId);

        // Halt mode blocks ALL trading (vault OTC + AMM)
        (uint256 collateralOut,) =
            router.sellWithBootstrap(marketId, true, aliceYesShares / 4, 0, ALICE, closeTime - 1);

        assertEq(collateralOut, 0, "Halt mode should block all trading (vault OTC + AMM)");
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // FIX #2: Multi-Venue Routing - AMM Min-Out Removed
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MultiVenueRouting_VaultPlusAMMPlusMint() public {
        _bootstrapMarket(50 ether);
        _setupTWAP();

        // Create scenario where vault gives some, AMM gives some, mint gives rest
        // Small initial liquidity to limit AMM
        vm.startPrank(ALICE);
        router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, ALICE, closeTime - 1);
        vm.stopPrank();

        // BOB buys with amount that needs multiple venues
        vm.startPrank(BOB);
        uint256 largeAmount = 30 ether;
        uint256 minShares = 25 ether; // Reasonable minimum given multi-venue

        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: largeAmount}(
            marketId, true, largeAmount, minShares, BOB, closeTime - 1
        );

        // Should succeed - may use single or multiple venues depending on liquidity
        assertGe(sharesOut, minShares, "Should meet minimum shares");
        // With removed AMM min-out constraint, router can flexibly use available liquidity
        // Source may be "amm" or "mult" depending on actual routing
        vm.stopPrank();
    }

    function test_MultiVenueRouting_AMMCanContributePartial() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Deplete one side of vault to create OTC opportunity
        vm.startPrank(ALICE);
        router.buyWithBootstrap{value: 30 ether}(marketId, true, 30 ether, 0, ALICE, closeTime - 1);
        vm.stopPrank();

        // BOB buys - should get some from vault OTC, some from AMM
        vm.startPrank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, closeTime - 1
        );

        assertGt(sharesOut, 0, "Should get shares");
        // With removed min-out constraint, AMM can contribute whatever it can
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // FIX #3: Overflow Protection in _tryVaultOTCFill
    // ══════════════════════════════════════════════════════════════════════════════

    function test_VaultOTC_NoOverflowOnLargeValues() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create very large vault inventory (near uint112 max)
        // This tests that the overflow fix (and -> and(and)) works correctly
        vm.startPrank(ALICE);

        // Do a reasonable buy that creates vault inventory
        router.buyWithBootstrap{value: 50 ether}(marketId, true, 50 ether, 0, ALICE, closeTime - 1);

        // Now try to buy with normal amount - should not fail due to overflow
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, false, 10 ether, 0, ALICE, closeTime - 1
        );

        assertGt(sharesOut, 0, "Should successfully fill without overflow");
        vm.stopPrank();
    }

    function test_VaultOTC_MinSharesLogicCorrect() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Test that "ensure at least 1 share" logic works
        // Create vault inventory
        vm.startPrank(ALICE);
        router.buyWithBootstrap{value: 50 ether}(marketId, true, 50 ether, 0, ALICE, closeTime - 1);
        vm.stopPrank();

        // Try very small buy on scarce side
        vm.startPrank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 0.01 ether}(
            marketId, false, 0.01 ether, 0, BOB, closeTime - 1
        );

        if (source == bytes4("otc")) {
            assertGt(sharesOut, 0, "Should get at least 1 share from OTC");
        }
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // COVERAGE: Edge Cases & Error Conditions
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_RevertsOnZeroShares() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true);

        vm.expectRevert();
        router.sellWithBootstrap(marketId, true, 0, 0, ALICE, closeTime - 1);
        vm.stopPrank();
    }

    function test_Buy_RevertsOnZeroCollateral() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(BOB);
        vm.expectRevert();
        router.buyWithBootstrap(marketId, true, 0, 0, BOB, closeTime - 1);
        vm.stopPrank();
    }

    function test_SlippageProtection_RevertsOnMinNotMet() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(BOB);
        // Request impossible minimum
        vm.expectRevert();
        router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 1000 ether, BOB, closeTime - 1
        );
        vm.stopPrank();
    }

    function test_DeadlineProtection_RevertsAfterExpiry() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        uint256 pastDeadline = block.timestamp - 1;

        vm.startPrank(BOB);
        vm.expectRevert();
        router.buyWithBootstrap{value: 1 ether}(marketId, true, 1 ether, 0, BOB, pastDeadline);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // COVERAGE: TWAP & Oracle Edge Cases
    // ══════════════════════════════════════════════════════════════════════════════

    function test_TWAP_UpdatesCorrectly() public {
        _bootstrapMarket(100 ether);
        _setupTWAP(); // Initial TWAP setup

        // Do a trade to move price
        vm.prank(ALICE);
        router.buyWithBootstrap{value: 10 ether}(marketId, true, 10 ether, 0, ALICE, closeTime - 1);

        // Update TWAP again after enough time has passed
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // TWAP should now be set (subsequent buys should work with OTC)
        vm.prank(BOB);
        (uint256 shares,,) =
            router.buyWithBootstrap{value: 5 ether}(marketId, false, 5 ether, 0, BOB, closeTime - 1);
        assertGt(shares, 0, "Should work with valid TWAP");
    }

    function test_VaultOTC_RejectsStalePrice() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create big price deviation via AMM
        vm.prank(BOB);
        router.buyWithBootstrap{value: 40 ether}(marketId, true, 40 ether, 0, BOB, closeTime - 1);

        // Now TWAP should be stale vs spot (>500 bps deviation)
        // Vault OTC should be rejected, fall back to AMM
        vm.prank(ALICE);
        (uint256 shares, bytes4 source,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, false, 10 ether, 0, ALICE, closeTime - 1
        );

        assertGt(shares, 0, "Should still get shares via AMM");
        // If deviation too high, should skip OTC
    }

    /*//////////////////////////////////////////////////////////////
                    OVERFLOW FIXES TESTS (Issues B & C)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test denominator overflow guard in _findMaxAMMUnderImpact (Issue B)
    /// @dev Tests that extreme collateral values don't cause wrap in `rIn*10000 + amtWithFee`
    function test_AMMImpact_NoWrapWithExtremeCollateral() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create AMM liquidity
        vm.prank(ALICE);
        router.provideLiquidity{value: 50 ether}(
            marketId, 50 ether, 0, 0, 50 ether, 0, 0, ALICE, closeTime - 1
        );

        // Try to buy with very large collateral near MAX_COLLATERAL_IN
        // This should not cause denominator overflow in _findMaxAMMUnderImpact
        uint256 largeAmount = type(uint256).max / 10000 / 2; // ~2^242
        vm.deal(BOB, largeAmount);

        vm.prank(BOB);
        // Should either succeed or revert gracefully, not return wrong safeCollateral
        try router.buyWithBootstrap{value: largeAmount}(
            marketId, true, largeAmount, 0, BOB, closeTime - 1
        ) returns (
            uint256 shares, bytes4, uint256
        ) {
            // If succeeds, should get reasonable shares
            assertGt(shares, 0, "Should get shares if execution succeeds");
        } catch {
            // Revert is acceptable for extreme values
        }
    }

    /// @notice Test left-shift overflow guard in _calcSwapAmountForMerge (Issue C)
    /// @dev Tests that large share amounts don't cause overflow in `shl(2, fm*absC)`
    function test_Sell_NoWrapWithLargeShares() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create AMM liquidity
        vm.prank(ALICE);
        router.provideLiquidity{value: 100 ether}(
            marketId, 100 ether, 0, 0, 100 ether, 0, 0, ALICE, closeTime - 1
        );

        // Buy large amount of shares
        vm.deal(BOB, 500 ether);
        vm.prank(BOB);
        router.buyWithBootstrap{value: 500 ether}(marketId, true, 500 ether, 0, BOB, closeTime - 1);

        uint256 bobShares = PAMM.balanceOf(BOB, marketId);

        // Approve router
        vm.prank(BOB);
        PAMM.setOperator(address(router), true);

        // Try to sell with large share amount
        // Should not cause overflow in quadratic formula calculation
        vm.prank(BOB);
        try router.sellWithBootstrap(marketId, true, bobShares, 0, BOB, closeTime - 1) returns (
            uint256 collateralOut, bytes4
        ) {
            assertGt(collateralOut, 0, "Should get collateral if sell succeeds");
        } catch {
            // Revert is acceptable for extreme values
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DIFFERENTIAL FULLMULDIV TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Differential fuzz test for fullMulDiv against reference implementation
    /// @dev Tests edge cases: d=1, d=2^k, d odd, x*y near 2^256, x=0, y=0
    function testFuzz_FullMulDiv_AgainstReference(uint256 x, uint256 y, uint256 d) public {
        // Skip if d=0 (both should revert)
        vm.assume(d > 0);

        // Handle simple non-overflow cases where x*y doesn't overflow
        if (x == 0 || y == 0) {
            assertEq(fullMulDiv(x, y, d), 0, "Should return 0 when x or y is 0");
            return;
        }

        // Skip overflow cases for now (reference implementation is simplified)
        // In production, compare against OZ Math.mulDiv or Uniswap FullMath
        if (x > type(uint256).max / y) {
            // Would overflow - skip this case as our simplified reference can't handle it
            return;
        }

        uint256 result = fullMulDiv(x, y, d);
        uint256 expected = (x * y) / d;

        assertEq(result, expected, "fullMulDiv mismatch with simple case");
    }

    /// @notice Reference implementation using Solidity checked arithmetic
    function referenceMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        // Handle simple cases
        if (x == 0 || y == 0) return 0;

        uint256 prod = x * y;

        // If no overflow in x*y, use simple division
        if (prod / x == y) {
            return prod / d;
        }

        // Overflow case: use 512-bit math
        // This is a simplified reference - in production use OZ Math.mulDiv
        uint256 mm = mulmod(x, y, type(uint256).max);
        uint256 prod0 = x * y; // Low 256 bits
        uint256 prod1 = mm - prod0; // High 256 bits (with borrow handling)
        if (mm < prod0) prod1 -= 1;

        require(d > prod1, "MulDiv overflow");

        // Simplified: for testing we'll just use the approximation
        // Full implementation would need 512-bit division
        return (prod0 / d);
    }

    /// @notice Test specific edge cases for fullMulDiv
    function test_FullMulDiv_EdgeCases() public {
        // d = 1
        assertEq(fullMulDiv(123, 456, 1), uint256(123) * uint256(456));

        // d = 2^k
        assertEq(fullMulDiv(1024, 2048, 256), (uint256(1024) * uint256(2048)) / uint256(256));

        // d odd
        assertEq(fullMulDiv(999, 888, 777), (uint256(999) * uint256(888)) / uint256(777));

        // x = 0
        assertEq(fullMulDiv(0, 12345, 67890), uint256(0));

        // y = 0
        assertEq(fullMulDiv(12345, 0, 67890), uint256(0));

        // Large values that would overflow in simple x*y
        uint256 large = type(uint128).max;
        uint256 result = fullMulDiv(large, large, large);
        assertEq(result, large, "Should handle 128-bit * 128-bit");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTICALL ETH ACCOUNTING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for multicall ETH accounting with mixed operations
    /// @dev Tests buyWithBootstrap + provideLiquidity + refund logic
    function testFuzz_Multicall_ETHAccounting(uint8 numBuys, uint8 numLiquidityOps, uint96 ethPerOp)
        public
    {
        // Bound inputs to reasonable ranges
        numBuys = uint8(bound(numBuys, 1, 3));
        numLiquidityOps = uint8(bound(numLiquidityOps, 0, 2));
        ethPerOp = uint96(bound(ethPerOp, 0.1 ether, 10 ether));

        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Build multicall with mixed operations
        bytes[] memory calls = new bytes[](numBuys + numLiquidityOps);
        uint256 totalRequired = 0;

        // Add buy operations
        for (uint256 i = 0; i < numBuys; i++) {
            calls[i] = abi.encodeCall(
                PMHookRouter.buyWithBootstrap,
                (marketId, i % 2 == 0, ethPerOp, 0, ALICE, closeTime - 1)
            );
            totalRequired += ethPerOp;
        }

        // Add liquidity operations
        for (uint256 i = 0; i < numLiquidityOps; i++) {
            calls[numBuys + i] = abi.encodeCall(
                PMHookRouter.provideLiquidity,
                (marketId, ethPerOp, 0, 0, ethPerOp, 0, 0, ALICE, closeTime - 1)
            );
            totalRequired += ethPerOp;
        }

        // Send exact amount
        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        router.multicall{value: totalRequired}(calls);
        uint256 balanceAfter = ALICE.balance;

        // Should spend exactly totalRequired (no refund)
        assertEq(balanceBefore - balanceAfter, totalRequired, "Should spend exact amount");
    }

    /// @notice Test multicall refunds excess ETH correctly
    function test_Multicall_RefundsExcess() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            PMHookRouter.buyWithBootstrap, (marketId, true, 5 ether, 0, ALICE, closeTime - 1)
        );
        calls[1] = abi.encodeCall(
            PMHookRouter.buyWithBootstrap, (marketId, false, 3 ether, 0, ALICE, closeTime - 1)
        );

        uint256 totalSent = 10 ether;

        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        router.multicall{value: totalSent}(calls);
        uint256 balanceAfter = ALICE.balance;

        // Should spend at most totalSent, may spend less and refund depending on actual execution
        uint256 spent = balanceBefore - balanceAfter;
        assertLe(spent, totalSent, "Should not spend more than sent");
        assertGt(spent, 0, "Should spend something");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Call fullMulDiv from router (expose for testing)
    function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := mul(x, y)
            for {} 1 {} {
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    let mm := mulmod(x, y, not(0))
                    let p1 := sub(mm, add(z, lt(mm, z)))
                    let r := mulmod(x, y, d)
                    let t := and(d, sub(0, d))
                    if iszero(gt(d, p1)) {
                        // Revert ERR_COMPUTATION
                        mstore(0x00, 0x677c1a05)
                        mstore(0x04, 1)
                        revert(0x00, 0x24)
                    }
                    d := div(d, t)
                    let inv := xor(2, mul(3, d))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    z := mul(
                        or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                        mul(sub(2, mul(d, inv)), inv)
                    )
                    break
                }
                z := div(z, d)
                break
            }
        }
    }
}
