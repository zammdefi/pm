// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";

/**
 * @title TWAPConversionHarness
 * @notice Exposes internal _convertUQ112x112ToBps for testing
 */
contract TWAPConversionHarness {
    function convertUQ112x112ToBps(uint256 twapUQ112x112) external pure returns (uint256 twapBps) {
        // Inline the exact implementation from PMHookRouter._convertUQ112x112ToBps
        // Returns P(YES) = NO/(YES+NO), where r = NO/YES in UQ112x112
        assembly ("memory-safe") {
            let denom := add(shl(112, 1), twapUQ112x112)
            twapBps := div(mul(10000, twapUQ112x112), denom)
            if iszero(twapBps) { twapBps := 1 }
            if iszero(lt(twapBps, 10000)) { twapBps := 9999 }
        }
    }
}

/**
 * @title PMHookRouterTWAPConversionTest
 * @notice Tests TWAP UQ112x112 to BPS conversion accuracy
 * @dev Validates that the conversion formula returns P(YES) = NO/(YES+NO)
 *      This matches PMFeeHook._getProbability semantics
 */
contract PMHookRouterTWAPConversionTest is Test {
    TWAPConversionHarness public harness;

    function setUp() public {
        harness = new TWAPConversionHarness();
    }

    /**
     * @notice Property test: TWAP conversion matches P(YES) formula
     * @dev Given reserves (yes, no), computes:
     *      - pYesBps = (no * 10000) / (yes + no)  [P(YES) = NO/(YES+NO)]
     *      - twapBps = convertUQ112x112ToBps((no << 112) / yes)
     *      Asserts they are equal within 1 bps rounding error
     */
    function testFuzz_ConvertUQ112x112ToBps_MatchesProbabilityFormula(uint112 yes, uint112 no)
        public
        view
    {
        // Require non-zero reserves (realistic constraint)
        vm.assume(yes > 0 && no > 0);
        // Avoid extreme ratios that would cause precision issues
        vm.assume(yes >= 1e6 && no >= 1e6);

        // Compute P(YES) in bps: P(YES) = NO / (YES + NO) * 10000
        // This matches PMFeeHook._getProbability
        uint256 pYesBps;
        unchecked {
            pYesBps = (uint256(no) * 10000) / (uint256(yes) + uint256(no));
        }

        // Compute TWAP UQ112x112: r = (NO << 112) / YES
        uint256 twapUQ;
        unchecked {
            twapUQ = (uint256(no) << 112) / uint256(yes);
        }

        // Convert TWAP to bps: P(YES) = (10000 * r) / (2^112 + r)
        uint256 twapBps = harness.convertUQ112x112ToBps(twapUQ);

        // Assert equality within 1 bps (accounting for rounding)
        assertApproxEqAbs(
            pYesBps, twapBps, 1, "TWAP conversion must match P(YES) formula within 1 bps"
        );
    }

    /**
     * @notice Test extreme case: all YES reserves (P(YES) ~ 0%)
     * @dev When no = 0, r = 0, P(YES) = 10000 * 0 / (2^112 + 0) = 0, clamped to 1
     */
    function test_ConvertUQ112x112ToBps_AllYes() public view {
        uint256 twapBps = harness.convertUQ112x112ToBps(0);
        assertEq(twapBps, 1, "All YES (no NO) should be clamped to 1 bps (P(YES) ~ 0)");
    }

    /**
     * @notice Test extreme case: all NO reserves (P(YES) ~ 100%)
     * @dev When NO >> YES, r is very large, P(YES) approaches 10000, clamped to 9999
     */
    function test_ConvertUQ112x112ToBps_AllNo() public view {
        // Use a very large r (avoiding overflow: r << 2^256 - 2^112)
        // This represents an extremely skewed pool (e.g., NO reserves >> YES reserves)
        uint256 veryLargeR = type(uint256).max >> 120; // Large but won't overflow
        uint256 twapBps = harness.convertUQ112x112ToBps(veryLargeR);
        assertEq(twapBps, 9999, "All NO (no YES) should be clamped to 9999 bps (P(YES) ~ 100%)");
    }

    /**
     * @notice Test 50/50 split (P(YES) = 50%)
     */
    function test_ConvertUQ112x112ToBps_FiftyFifty() public view {
        // When yes = no, r = 1 in UQ112x112 = 2^112
        // P(YES) = (10000 * 2^112) / (2^112 + 2^112) = 10000 / 2 = 5000
        uint256 rFiftyFifty = 1 << 112;
        uint256 twapBps = harness.convertUQ112x112ToBps(rFiftyFifty);
        assertEq(twapBps, 5000, "50/50 split should give 5000 bps");
    }

    /**
     * @notice Test known ratio: yes=3, no=1 (P(YES) = 25%)
     * @dev P(YES) = NO/(YES+NO) = 1/4 = 2500 bps
     */
    function test_ConvertUQ112x112ToBps_ThreeToOne() public view {
        uint112 yes = 3e18;
        uint112 no = 1e18;

        // P(YES) = NO / (YES + NO) - this matches PMFeeHook._getProbability
        uint256 pYesBps = (uint256(no) * 10000) / (uint256(yes) + uint256(no));
        uint256 twapUQ = (uint256(no) << 112) / uint256(yes);
        uint256 twapBps = harness.convertUQ112x112ToBps(twapUQ);

        assertEq(pYesBps, 2500, "3:1 YES:NO should give P(YES) = 2500 bps");
        assertApproxEqAbs(pYesBps, twapBps, 1, "TWAP conversion should match P(YES)");
    }

    /**
     * @notice Test realistic reserves from actual pool
     */
    function test_ConvertUQ112x112ToBps_RealisticReserves() public view {
        uint112 yes = 1234567890123456789;
        uint112 no = 9876543210987654321;

        // P(YES) = NO / (YES + NO)
        uint256 pYesBps = (uint256(no) * 10000) / (uint256(yes) + uint256(no));
        uint256 twapUQ = (uint256(no) << 112) / uint256(yes);
        uint256 twapBps = harness.convertUQ112x112ToBps(twapUQ);

        assertApproxEqAbs(
            pYesBps, twapBps, 1, "Realistic reserves should match P(YES) within 1 bps"
        );
    }
}
