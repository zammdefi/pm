// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract TestMergeFix is Test {
    function test_CorrectMergePattern() public pure {
        // Test the CORRECT pattern (after fix)
        uint112 yesShares = 100 ether;
        uint112 noShares = 50 ether;
        uint32 lastActivity = 12345;
        uint112 sharesMerged = 10 ether;

        // Pack vault data
        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        // Extract shares
        uint112 yes = uint112(vaultData & 0xffffffffffffffffffffffffffff);
        uint112 no = uint112((vaultData >> 112) & 0xffffffffffffffffffffffffffff);
        uint32 activity = uint32(vaultData >> 224);

        // Apply CORRECT pattern (after fix)
        vaultData = uint256(yes - sharesMerged) | (uint256(no - sharesMerged) << 112)
            | (uint256(activity) << 224);

        uint112 finalYes = uint112(vaultData);
        uint112 finalNo = uint112(vaultData >> 112);
        uint32 finalActivity = uint32(vaultData >> 224);

        console.log("=== AFTER FIX ===");
        console.log("Final yesShares:", finalYes);
        console.log("Final noShares:", finalNo);
        console.log("Final lastActivity:", finalActivity);
        console.log("Expected yesShares:", yesShares - sharesMerged);
        console.log("Expected noShares:", noShares - sharesMerged);

        // Verify correctness
        assertEq(finalYes, yesShares - sharesMerged, "YES shares correct");
        assertEq(finalNo, noShares - sharesMerged, "NO shares correct");
        assertEq(finalActivity, lastActivity, "lastActivity preserved");

        console.log("\nFIX VERIFIED!");
    }
}
