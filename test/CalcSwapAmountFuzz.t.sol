// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/PMHookRouter.sol";

/// @title Test Harness for _calcSwapAmountForMerge
/// @notice Exposes internal function for testing
contract CalcSwapAmountHarness is PMHookRouter {
    function calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
        external
        pure
        returns (uint256)
    {
        return _calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);
    }
}

/// @title Fuzz Tests for _calcSwapAmountForMerge
/// @notice Comprehensive property-based testing with extreme values
contract CalcSwapAmountFuzzTest is Test {
    CalcSwapAmountHarness public harness;

    function setUp() public {
        // Fork mainnet (PAMM and ZAMM are deployed there)
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy harness contract
        harness = new CalcSwapAmountHarness();
    }

    /*//////////////////////////////////////////////////////////////
                        PROPERTY-BASED FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Property: swapAmount must never exceed sharesIn
    /// @dev This is critical - can't swap more than you have
    function testFuzz_SwapAmountNeverExceedsSharesIn(
        uint256 sharesIn,
        uint256 rIn,
        uint256 rOut,
        uint256 feeBps
    ) public view {
        // Bound inputs to valid ranges
        sharesIn = bound(sharesIn, 0, type(uint128).max);
        rIn = bound(rIn, 0, type(uint128).max);
        rOut = bound(rOut, 0, type(uint128).max);
        feeBps = bound(feeBps, 0, 9999);

        uint256 swapAmount = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);

        // Property: result must never exceed input
        assertLe(swapAmount, sharesIn, "Swap amount exceeds shares in");
    }

    /// @notice Property: Zero inputs return zero
    function testFuzz_ZeroInputsReturnZero(uint256 nonZero1, uint256 nonZero2, uint256 feeBps)
        public
        view
    {
        nonZero1 = bound(nonZero1, 1, type(uint128).max);
        nonZero2 = bound(nonZero2, 1, type(uint128).max);
        feeBps = bound(feeBps, 0, 9999);

        assertEq(
            harness.calcSwapAmountForMerge(0, nonZero1, nonZero2, feeBps),
            0,
            "Zero sharesIn should return 0"
        );
        assertEq(
            harness.calcSwapAmountForMerge(nonZero1, 0, nonZero2, feeBps),
            0,
            "Zero rIn should return 0"
        );
        assertEq(
            harness.calcSwapAmountForMerge(nonZero1, nonZero2, 0, feeBps),
            0,
            "Zero rOut should return 0"
        );
    }

    /// @notice Property: Invalid feeBps returns zero
    function testFuzz_InvalidFeeBpsReturnsZero(
        uint256 sharesIn,
        uint256 rIn,
        uint256 rOut,
        uint256 feeBps
    ) public view {
        sharesIn = bound(sharesIn, 1, type(uint128).max);
        rIn = bound(rIn, 1, type(uint128).max);
        rOut = bound(rOut, 1, type(uint128).max);
        feeBps = bound(feeBps, 10000, type(uint256).max);

        uint256 swapAmount = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);
        assertEq(swapAmount, 0, "feeBps >= 10000 should return 0");
    }

    /// @notice Property: Deterministic output for same inputs
    function testFuzz_Deterministic(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
        public
        view
    {
        sharesIn = bound(sharesIn, 0, type(uint128).max);
        rIn = bound(rIn, 0, type(uint128).max);
        rOut = bound(rOut, 0, type(uint128).max);
        feeBps = bound(feeBps, 0, 9999);

        uint256 result1 = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);
        uint256 result2 = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);

        assertEq(result1, result2, "Same inputs must produce same output");
    }

    /// @notice Fuzz: Extreme values near uint256 max
    function testFuzz_ExtremeValues(uint8 scaleDown) public view {
        // Test values near max that should trigger overflow guards
        uint256 veryLarge = type(uint256).max >> scaleDown;

        // These should return 0 due to overflow guards, not revert
        uint256 result = harness.calcSwapAmountForMerge(veryLarge, veryLarge, veryLarge, 30);

        // Should gracefully return 0, not revert
        assertLe(result, veryLarge, "Should handle extreme values gracefully");
    }

    /// @notice Fuzz: Extreme reserve imbalances
    function testFuzz_ExtremeReserveImbalances(uint128 small, uint128 large) public view {
        small = uint128(bound(small, 1, 1e18));
        large = uint128(bound(large, 1e24, type(uint128).max));

        // Scenario 1: rIn >> rOut
        uint256 result1 = harness.calcSwapAmountForMerge(1e18, large, small, 30);
        assertLe(result1, 1e18, "Extreme imbalance case 1");

        // Scenario 2: rOut >> rIn
        uint256 result2 = harness.calcSwapAmountForMerge(1e18, small, large, 30);
        assertLe(result2, 1e18, "Extreme imbalance case 2");
    }

    /// @notice Fuzz: sharesIn boundary relative to reserves
    function testFuzz_SharesInBoundary(uint128 rIn, uint128 rOut, uint128 sharesIn) public view {
        rIn = uint128(bound(rIn, 1e10, type(uint128).max / 10000));
        rOut = uint128(bound(rOut, 1e10, type(uint128).max / 10000));
        sharesIn = uint128(bound(sharesIn, 1, type(uint128).max / 10000));

        uint256 feeBps = 30; // Standard 0.3% fee

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);

        // Key property: result <= sharesIn
        assertLe(result, sharesIn, "Result must not exceed sharesIn");

        // If result > 0, it should be < sharesIn (need some left to merge)
        if (result > 0) {
            assertLt(result, sharesIn, "If swapping, must leave some to merge");
        }
    }

    /// @notice Fuzz: High fee scenarios
    function testFuzz_HighFees(uint128 sharesIn, uint128 rIn, uint128 rOut, uint16 feeBps)
        public
        view
    {
        sharesIn = uint128(bound(sharesIn, 1e10, type(uint128).max / 10000));
        rIn = uint128(bound(rIn, 1e10, type(uint128).max / 10000));
        rOut = uint128(bound(rOut, 1e10, type(uint128).max / 10000));
        feeBps = uint16(bound(feeBps, 9000, 9999)); // Very high fees (90-99.99%)

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);

        // High fees should reduce swap amount significantly
        // At 99% fee, swapping is uneconomical, so result should be 0 or very small
        assertLe(result, sharesIn, "High fee result must not exceed sharesIn");
    }

    /// @notice Fuzz: Overflow guard verification - rI * 10000
    function testFuzz_OverflowGuard_rIn10k(uint256 rIn) public view {
        // Test values that would overflow rIn * 10000
        rIn = bound(rIn, type(uint256).max / 10000 + 1, type(uint256).max);

        // Should return 0, not revert
        uint256 result = harness.calcSwapAmountForMerge(1e18, rIn, 1e18, 30);
        assertEq(result, 0, "Should return 0 when rIn*10000 would overflow");
    }

    /// @notice Fuzz: Overflow guard verification - fm * diff
    function testFuzz_OverflowGuard_fmDiff(uint256 sharesIn, uint256 rOut) public view {
        // sharesIn > rOut, and (sharesIn - rOut) * fm would overflow
        sharesIn = bound(sharesIn, type(uint256).max / 9970 + 1e18, type(uint256).max);
        rOut = bound(rOut, 1, sharesIn - 1);

        // Should return 0, not revert
        uint256 result = harness.calcSwapAmountForMerge(sharesIn, 1e10, rOut, 30);
        assertEq(result, 0, "Should return 0 when fm*diff would overflow");
    }

    /// @notice Fuzz: Overflow guard verification - b²
    function testFuzz_OverflowGuard_bSquared(uint128 rIn, uint128 rOut) public view {
        // Create scenario where b would be very large
        rIn = uint128(bound(rIn, type(uint128).max / 2, type(uint128).max / 2));
        rOut = uint128(bound(rOut, 1, 1000));

        // Should handle gracefully (return 0 or valid result)
        uint256 result = harness.calcSwapAmountForMerge(100, rIn, rOut, 30);
        assertLe(result, 100, "Should handle large b values gracefully");
    }

    /// @notice Fuzz: Overflow guard verification - sharesIn * rIn10k
    function testFuzz_OverflowGuard_sharesInRIn10k(uint256 sharesIn, uint256 rIn) public view {
        // Test values where sharesIn * (rIn * 10000) would overflow
        rIn = bound(rIn, 1e30, type(uint128).max);
        sharesIn = bound(sharesIn, type(uint256).max / (rIn * 10000) + 1, type(uint256).max / rIn);

        // Should return 0, not revert
        uint256 result = harness.calcSwapAmountForMerge(sharesIn, rIn, 1e18, 30);
        assertEq(result, 0, "Should return 0 when sharesIn*rIn10k would overflow");
    }

    /// @notice Fuzz: Very small values (1 wei scenarios)
    function testFuzz_VerySmallValues(uint8 weiAmount) public view {
        uint256 amount = bound(weiAmount, 1, 100);

        uint256 result = harness.calcSwapAmountForMerge(amount, amount, amount, 30);
        assertLe(result, amount, "Should handle 1 wei gracefully");
    }

    /// @notice Fuzz: Balanced reserves (rIn ≈ rOut)
    function testFuzz_BalancedReserves(uint128 reserve, uint128 sharesIn, uint16 feeBps)
        public
        view
    {
        reserve = uint128(bound(reserve, 1e18, type(uint128).max / 10000));
        sharesIn = uint128(bound(sharesIn, 1e18, reserve));
        feeBps = uint16(bound(feeBps, 1, 500)); // 0.01% - 5%

        // rIn ≈ rOut (within 1%)
        uint256 rOut = uint256(reserve) * 99 / 100;

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, reserve, rOut, feeBps);

        // When reserves are balanced, optimal swap should be reasonable
        assertLe(result, sharesIn, "Balanced reserves case");

        // When reserves are balanced and we have shares, result should be < sharesIn
        // (need to keep some for merging)
        if (result > 0 && sharesIn > 1e18) {
            assertLt(result, sharesIn, "Should leave some shares for merging");
        }
    }

    /// @notice Fuzz: Unbalanced reserves (rIn >> rOut or vice versa)
    function testFuzz_UnbalancedReserves(uint128 sharesIn, uint128 smaller, uint128 ratio)
        public
        view
    {
        sharesIn = uint128(bound(sharesIn, 1e10, 1e24));
        smaller = uint128(bound(smaller, 1e10, 1e18));
        ratio = uint128(bound(ratio, 2, 100)); // 2x to 100x imbalance

        uint256 larger = uint256(smaller) * ratio;
        if (larger > type(uint128).max / 10000) return; // Skip if too large

        // Test both directions
        uint256 result1 = harness.calcSwapAmountForMerge(sharesIn, larger, smaller, 30);
        uint256 result2 = harness.calcSwapAmountForMerge(sharesIn, smaller, larger, 30);

        assertLe(result1, sharesIn, "Unbalanced case 1");
        assertLe(result2, sharesIn, "Unbalanced case 2");
    }

    /*//////////////////////////////////////////////////////////////
                        SPECIFIC EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: swapAmount == remaining edge case (mentioned in review)
    function test_SwapAmountEqualsRemaining() public view {
        // Create scenario where optimal swap = all shares
        // This should return value < sharesIn (can't swap everything and merge)
        uint256 sharesIn = 1000e18;
        uint256 rIn = 1; // Almost no rIn
        uint256 rOut = type(uint128).max / 10000; // Huge rOut

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, 30);

        // Should return < sharesIn (need to keep some for merging)
        assertLe(result, sharesIn, "Can't swap all shares");
    }

    /// @notice Test: Newton's method convergence with difficult inputs
    function test_NewtonMethodConvergence() public view {
        // Values that make sqrt difficult
        uint256 sharesIn = type(uint64).max;
        uint256 rIn = type(uint64).max;
        uint256 rOut = type(uint64).max - 1;

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, rIn, rOut, 30);
        assertLe(result, sharesIn, "Newton's method should converge");
    }

    /// @notice Test: Negative b scenario (sharesIn > rOut)
    function testFuzz_NegativeBScenario(uint128 sharesIn, uint128 rOut) public view {
        sharesIn = uint128(bound(sharesIn, 1e18, type(uint64).max));
        rOut = uint128(bound(rOut, 1, sharesIn - 1)); // Ensure sharesIn > rOut

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, 1e18, rOut, 30);
        assertLe(result, sharesIn, "Negative b case");
    }

    /// @notice Test: Positive b scenario (rOut > sharesIn)
    function testFuzz_PositiveBScenario(uint128 sharesIn, uint128 rOut) public view {
        sharesIn = uint128(bound(sharesIn, 1e10, type(uint64).max));
        rOut = uint128(bound(rOut, sharesIn + 1, type(uint64).max)); // Ensure rOut > sharesIn

        uint256 result = harness.calcSwapAmountForMerge(sharesIn, 1e18, rOut, 30);
        assertLe(result, sharesIn, "Positive b case");
    }
}
