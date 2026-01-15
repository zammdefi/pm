// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract VerifyGetNoIdTest is Test {
    function _getNoIdSolidity(uint256 marketId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("PMARKET:NO", marketId)));
    }

    function _getNoIdAssembly(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    /// @notice Fuzz test to verify assembly implementation matches Solidity
    function testFuzz_GetNoIdMatchesSolidity(uint256 marketId) public pure {
        uint256 solidityResult = _getNoIdSolidity(marketId);
        uint256 assemblyResult = _getNoIdAssembly(marketId);

        assertEq(assemblyResult, solidityResult, "Assembly must match Solidity implementation");
    }

    /// @notice Test specific edge cases
    function test_GetNoIdEdgeCases() public pure {
        uint256[] memory testCases = new uint256[](5);
        testCases[0] = 0;
        testCases[1] = 1;
        testCases[2] = type(uint256).max;
        testCases[3] = 0x123456789abcdef;
        testCases[4] = 12345678;

        for (uint256 i = 0; i < testCases.length; i++) {
            uint256 marketId = testCases[i];
            uint256 solidityResult = _getNoIdSolidity(marketId);
            uint256 assemblyResult = _getNoIdAssembly(marketId);

            assertEq(assemblyResult, solidityResult, "Mismatch for edge case");
        }
    }

    /// @notice Verify the byte layout is correct
    function test_ByteLayout() public pure {
        // "PMARKET:NO" should be exactly 10 bytes
        bytes memory prefix = bytes("PMARKET:NO");
        assertEq(prefix.length, 10, "Prefix must be 10 bytes");

        // Verify hex encoding
        assertEq(uint8(prefix[0]), 0x50, "P");
        assertEq(uint8(prefix[1]), 0x4d, "M");
        assertEq(uint8(prefix[2]), 0x41, "A");
        assertEq(uint8(prefix[3]), 0x52, "R");
        assertEq(uint8(prefix[4]), 0x4b, "K");
        assertEq(uint8(prefix[5]), 0x45, "E");
        assertEq(uint8(prefix[6]), 0x54, "T");
        assertEq(uint8(prefix[7]), 0x3a, ":");
        assertEq(uint8(prefix[8]), 0x4e, "N");
        assertEq(uint8(prefix[9]), 0x4f, "O");
    }

    /// @notice Test what reviewer suggested would produce (should FAIL)
    function test_ReviewerSuggestionIsWrong() public pure {
        uint256 marketId = 12345;

        // Reviewer's suggested implementation (WRONG)
        uint256 reviewerResult;
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x09, marketId) // offset 9 instead of 10
            reviewerResult := keccak256(0x00, 0x29) // 41 bytes instead of 42
        }

        uint256 correctResult = _getNoIdSolidity(marketId);

        // These should NOT match - reviewer's implementation is wrong
        assertTrue(
            reviewerResult != correctResult, "Reviewer suggestion should produce different hash"
        );
    }
}
