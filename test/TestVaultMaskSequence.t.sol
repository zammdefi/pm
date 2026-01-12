// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract TestVaultMaskSequence is Test {
    function test_SimulateBugSequence() public pure {
        // Simulate what happens in sellWithBootstrap OTC fill
        uint112 yesShares = 10 ether;
        uint112 noShares = 20 ether;
        uint32 lastActivity = 1000;
        uint112 filled = 50 ether; // Adding 50 ether to NO shares via OTC
        bool sellYes = false; // User selling YES, vault buying YES (increasing yesShares)

        // Initial state
        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        console.log("=== INITIAL STATE ===");
        console.log("yesShares:", yesShares);
        console.log("noShares:", noShares);

        // STEP 1: Update shares (lines 1431-1448) - CORRECT
        uint256 mask = 0xffffffffffffffffffffffffffff;
        uint256 shift = sellYes ? 0 : 112; // sellYes=false means yesShares
        uint256 current = (vaultData >> shift) & mask;
        uint256 updated = current + filled;
        uint256 clearMask = ~(mask << shift);
        vaultData = (vaultData & clearMask) | ((updated & mask) << shift);

        console.log("\n=== AFTER STEP 1 (correct share update) ===");
        console.log("yesShares:", uint112(vaultData));
        console.log("noShares:", uint112(vaultData >> 112));

        // STEP 2: Update lastActivity (lines 1449-1455) - BUGGY
        uint256 buggyMask = 0xffffffff0000000000000000ffffffffffffffffffffffffffffffff;
        vaultData = (vaultData & buggyMask) | (uint256(2000) << 224);

        console.log("\n=== AFTER STEP 2 (buggy lastActivity update) ===");
        console.log("yesShares:", uint112(vaultData));
        console.log("noShares:", uint112(vaultData >> 112));
        console.log("lastActivity:", uint32(vaultData >> 224));

        uint112 finalYes = uint112(vaultData);
        uint112 expectedYes = yesShares + filled;
        console.log("\n=== CORRUPTION ===");
        console.log("Expected yesShares:", expectedYes);
        console.log("Actual yesShares:", finalYes);
        console.log("SHARES LOST:", expectedYes - finalYes);
    }
}
