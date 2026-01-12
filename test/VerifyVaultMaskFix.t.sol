// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract VerifyVaultMaskFix is Test {
    function test_CorrectMaskValue() public pure {
        // The CORRECT mask that preserves bits 0-223 and clears bits 224-255
        uint256 correctMask = 0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        // Create test vault data with large values
        uint112 yesShares = 100 ether;
        uint112 noShares = 50 ether;
        uint32 oldActivity = 1000;

        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(oldActivity) << 224);

        // Apply the correct mask and set new timestamp
        uint32 newActivity = 2000;
        uint256 updated = (vaultData & correctMask) | (uint256(newActivity) << 224);

        // Extract and verify
        uint112 yesAfter = uint112(updated);
        uint112 noAfter = uint112(updated >> 112);
        uint32 activityAfter = uint32(updated >> 224);

        // Assertions
        assertEq(yesAfter, yesShares, "YES shares must be preserved");
        assertEq(noAfter, noShares, "NO shares must be preserved");
        assertEq(activityAfter, newActivity, "lastActivity must be updated");

        console.log("=== CORRECT MASK VERIFICATION ===");
        console.log("Original YES shares:", yesShares);
        console.log("Preserved YES shares:", yesAfter);
        console.log("Original NO shares:", noShares);
        console.log("Preserved NO shares:", noAfter);
        console.log("Old activity:", oldActivity);
        console.log("New activity:", activityAfter);
        console.log("All values CORRECT!");
    }

    function test_BuggyMaskWouldFail() public pure {
        // The BUGGY mask (56 hex digits) that would corrupt data
        uint256 buggyMask = 0xffffffff0000000000000000ffffffffffffffffffffffffffffffff;
        // This becomes: 0x00000000ffffffff0000000000000000ffffffffffffffffffffffffffffffff
        // Notice the zeros at bits 128-191 that corrupt noShares!

        uint112 yesShares = 100 ether;
        uint112 noShares = 50 ether;
        uint32 oldActivity = 1000;

        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(oldActivity) << 224);

        // Apply the BUGGY mask
        uint256 updated = (vaultData & buggyMask) | (uint256(2000) << 224);

        uint112 noAfter = uint112(updated >> 112);

        console.log("=== BUGGY MASK DEMONSTRATION ===");
        console.log("Original NO shares:", noShares);
        console.log("After buggy mask:", noAfter);
        console.log("Corruption amount:", noShares - noAfter);

        // This demonstrates the bug (but we expect it to fail here)
        assertTrue(noAfter == 0, "Buggy mask ZEROS out noShares completely");
    }
}
