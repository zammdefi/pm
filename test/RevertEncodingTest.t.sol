// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract RevertEncodingTest is Test {
    bytes4 constant ERR_TEST = 0xab143c06;

    // Test the _revert pattern used in PMHookRouter
    function testCurrentRevertEncoding() public {
        TestReverter reverter = new TestReverter();

        // Try to call and catch the revert
        try reverter.revertWithCurrentPattern(ERR_TEST, 42) {
            revert("Should have reverted");
        } catch (bytes memory revertData) {
            emit log_named_bytes("Current pattern revert data", revertData);
            emit log_named_uint("Revert data length", revertData.length);

            // Decode the first 4 bytes as selector
            bytes4 returnedSelector;
            assembly {
                returnedSelector := mload(add(revertData, 0x20))
            }
            emit log_named_bytes32("Returned selector (as bytes32)", bytes32(returnedSelector));

            // Check if selector matches
            if (returnedSelector == ERR_TEST) {
                emit log_string("PASS: Selector correctly encoded");
            } else {
                emit log_string("FAIL: Selector incorrectly encoded");
                emit log_named_bytes32("Expected", bytes32(ERR_TEST));
                emit log_named_bytes32("Got", bytes32(returnedSelector));
            }

            // If length >= 36, try to decode the parameter
            if (revertData.length >= 36) {
                uint256 returnedCode;
                assembly {
                    returnedCode := mload(add(revertData, 0x24))
                }
                emit log_named_uint("Returned code", returnedCode);
                assertEq(returnedCode, 42, "Code should be 42");
            }
        }
    }

    // Test a corrected pattern
    function testCorrectedRevertEncoding() public {
        TestReverter reverter = new TestReverter();

        try reverter.revertWithCorrectedPattern(ERR_TEST, 42) {
            revert("Should have reverted");
        } catch (bytes memory revertData) {
            emit log_named_bytes("Corrected pattern revert data", revertData);

            bytes4 returnedSelector;
            assembly {
                returnedSelector := mload(add(revertData, 0x20))
            }

            assertEq(returnedSelector, ERR_TEST, "Selector should match");

            if (revertData.length >= 36) {
                uint256 returnedCode;
                assembly {
                    returnedCode := mload(add(revertData, 0x24))
                }
                assertEq(returnedCode, 42, "Code should be 42");
            }
        }
    }
}

contract TestReverter {
    // Current pattern from PMHookRouter._revert
    function revertWithCurrentPattern(bytes4 selector, uint8 code) external pure {
        assembly {
            mstore(0x00, selector)
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }

    // Corrected pattern
    function revertWithCorrectedPattern(bytes4 selector, uint8 code) external pure {
        assembly {
            mstore(0x00, shl(224, selector))
            mstore(0x20, code)
            revert(0x00, 0x24)
        }
    }
}
