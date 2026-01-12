// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract TestVaultMergeBug is Test {
    function test_MergeShiftPattern() public pure {
        // Simulate settleRebalanceBudget vault data manipulation
        uint112 yesShares = 100 ether;
        uint112 noShares = 50 ether;
        uint32 lastActivity = 12345;
        uint112 sharesMerged = 10 ether;

        // Pack vault data
        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        console.log("=== BEFORE MERGE ===");
        console.log("yesShares:", yesShares);
        console.log("noShares:", noShares);
        console.log("lastActivity:", lastActivity);

        // Extract shares
        uint112 yes = uint112(vaultData & 0xffffffffffffffffffffffffffff);
        uint112 no = uint112((vaultData >> 112) & 0xffffffffffffffffffffffffffff);

        console.log("\n=== EXTRACTED ===");
        console.log("Extracted yes:", yes);
        console.log("Extracted no:", no);

        // Apply the SUSPICIOUS pattern from settleRebalanceBudget
        vaultData = (vaultData << 224) >> 224;

        console.log("\n=== AFTER shr(224, shl(224, vaultData)) ===");
        console.logBytes32(bytes32(vaultData));
        console.log("Remaining yes:", uint112(vaultData));
        console.log("Remaining no:", uint112(vaultData >> 112));
        console.log("Remaining activity:", uint32(vaultData >> 224));

        // OR new values
        vaultData = vaultData | (yes - sharesMerged);
        vaultData = vaultData | ((no - sharesMerged) << 112);

        console.log("\n=== AFTER OR OPERATIONS ===");
        uint112 finalYes = uint112(vaultData);
        uint112 finalNo = uint112(vaultData >> 112);
        uint32 finalActivity = uint32(vaultData >> 224);

        console.log("Final yesShares:", finalYes);
        console.log("Final noShares:", finalNo);
        console.log("Final lastActivity:", finalActivity);

        console.log("\n=== EXPECTED ===");
        console.log("Expected yesShares:", yesShares - sharesMerged);
        console.log("Expected noShares:", noShares - sharesMerged);

        // Check if correct
        bool correct =
            (finalYes == yesShares - sharesMerged) && (finalNo == noShares - sharesMerged);
        console.log("\n=== VERDICT ===");
        console.log("Is correct?", correct);
        if (!correct) {
            console.log("BUG FOUND!");
        }
    }
}
