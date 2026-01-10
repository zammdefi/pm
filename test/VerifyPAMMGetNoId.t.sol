// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

interface IPAMM {
    function getNoId(uint256 marketId) external pure returns (uint256);
}

contract VerifyPAMMGetNoIdTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main7"));
    }

    function _getNoIdRouter(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    /// @notice Verify router implementation matches PAMM
    function testFuzz_RouterMatchesPAMM(uint256 marketId) public view {
        uint256 pammResult = PAMM.getNoId(marketId);
        uint256 routerResult = _getNoIdRouter(marketId);

        assertEq(routerResult, pammResult, "Router must match PAMM.getNoId()");
    }

    /// @notice Test specific cases
    function test_RouterMatchesPAMM_EdgeCases() public view {
        uint256[] memory testCases = new uint256[](6);
        testCases[0] = 0;
        testCases[1] = 1;
        testCases[2] = 42;
        testCases[3] = 1000;
        testCases[4] = type(uint256).max;
        testCases[5] = 0x123456789abcdef;

        for (uint256 i = 0; i < testCases.length; i++) {
            uint256 marketId = testCases[i];
            uint256 pammResult = PAMM.getNoId(marketId);
            uint256 routerResult = _getNoIdRouter(marketId);

            assertEq(routerResult, pammResult, "Mismatch for edge case");
        }
    }
}
