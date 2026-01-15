// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract TestMergeFix2 is Test {
    function test_AssemblyMergePattern() public pure {
        // Simulate exact assembly pattern (after fix)
        uint112 yesShares = 100 ether;
        uint112 noShares = 50 ether;
        uint32 lastActivity = 12345;
        uint112 sharesMerged = 10 ether;

        // Pack vault data
        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        console.log("=== INITIAL ===");
        console.log("Packed vaultData:");
        console.logBytes32(bytes32(vaultData));

        // Simulate assembly: extract FIRST, then modify
        uint112 yes;
        uint112 no;
        uint32 activity;
        assembly {
            yes := and(vaultData, 0xffffffffffffffffffffffffffff)
            no := and(shr(112, vaultData), 0xffffffffffffffffffffffffffff)
            activity := shr(224, vaultData)
        }

        console.log("\n=== EXTRACTED ===");
        console.log("yes:", yes);
        console.log("no:", no);
        console.log("activity:", activity);

        // Apply the FIXED pattern
        assembly {
            vaultData := sub(yes, sharesMerged)
            vaultData := or(vaultData, shl(112, sub(no, sharesMerged)))
            vaultData := or(vaultData, shl(224, activity))
        }

        console.log("\n=== AFTER FIX ===");
        console.log("vaultData:");
        console.logBytes32(bytes32(vaultData));

        uint112 finalYes = uint112(vaultData);
        uint112 finalNo = uint112(vaultData >> 112);
        uint32 finalActivity = uint32(vaultData >> 224);

        console.log("Final yesShares:", finalYes);
        console.log("Final noShares:", finalNo);
        console.log("Final lastActivity:", finalActivity);

        // Verify correctness
        assertEq(finalYes, yesShares - sharesMerged, "YES shares correct");
        assertEq(finalNo, noShares - sharesMerged, "NO shares correct");
        assertEq(finalActivity, lastActivity, "lastActivity preserved");

        console.log("\nFIX VERIFIED!");
    }
}
