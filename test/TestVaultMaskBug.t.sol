// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract TestVaultMaskBug is Test {
    function test_VaultMaskAnalysis() public pure {
        // Vault layout: yesShares (0-111) | noShares (112-223) | lastActivity (224-255)

        // Create test data with noShares = 100,000 (should have bits 16-17 set)
        uint112 yesShares = 50_000;
        uint112 noShares = 100_000;
        uint32 lastActivity = 12345;

        // Pack the vault data
        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        console.log("Original vaultData:");
        console.logBytes32(bytes32(vaultData));
        console.log("Original yesShares:", yesShares);
        console.log("Original noShares:", noShares);
        console.log("Original lastActivity:", lastActivity);

        // Apply the BUGGY mask
        uint256 buggyMask = 0xffffffff0000000000000000ffffffffffffffffffffffffffffffff;
        uint256 maskedData = vaultData & buggyMask;

        console.log("\nAfter buggy mask:");
        console.logBytes32(bytes32(maskedData));

        // Extract shares after masking
        uint112 yesAfter = uint112(maskedData);
        uint112 noAfter = uint112(maskedData >> 112);

        console.log("yesShares after mask:", yesAfter);
        console.log("noShares after mask:", noAfter);
        console.log("noShares CORRUPTED:", noShares != noAfter);

        // Apply CORRECT mask
        uint256 correctMask = 0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        uint256 correctMasked = vaultData & correctMask;

        console.log("\nAfter correct mask:");
        uint112 noCorrect = uint112(correctMasked >> 112);
        console.log("noShares after correct mask:", noCorrect);
        console.log("noShares preserved:", noShares == noCorrect);
    }

    function test_VaultMaskWithSmallValues() public pure {
        // Test with small values (< 65536)
        uint112 yesShares = 1000;
        uint112 noShares = 2000;
        uint32 lastActivity = 12345;

        uint256 vaultData =
            uint256(yesShares) | (uint256(noShares) << 112) | (uint256(lastActivity) << 224);

        // Apply buggy mask
        uint256 buggyMask = 0xffffffff0000000000000000ffffffffffffffffffffffffffffffff;
        uint256 maskedData = vaultData & buggyMask;

        uint112 noAfter = uint112(maskedData >> 112);

        console.log("Small noShares (2000) after buggy mask:", noAfter);
        console.log("Bug hidden with small values:", noShares == noAfter);
    }
}

contract TestVaultMaskBugWithEther is Test {
    function test_VaultMaskWithRealisticShares() public pure {
        // Real scenario: vault has 50 ether worth of shares
        uint112 noShares = 50 ether; // 50 * 10^18

        console.log("Testing with 50 ether shares:");
        console.log("noShares value:", noShares);
        console.log("Binary representation has bits > 16 set");

        // Check if bit 16+ is set
        bool hasBit16Plus = noShares >= 65536;
        console.log("Will trigger bug:", hasBit16Plus);

        // Apply buggy mask
        uint256 vaultData = uint256(noShares) << 112;
        uint256 buggyMask = 0xffffffff0000000000000000ffffffffffffffffffffffffffffffff;
        uint256 masked = vaultData & buggyMask;

        uint112 noAfter = uint112(masked >> 112);
        console.log("noShares after mask:", noAfter);
        console.log("Loss:", noShares - noAfter);
        console.log("Loss percentage:", ((noShares - noAfter) * 100) / noShares);
    }
}
