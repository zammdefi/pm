// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract SelectorEncodingTest is Test {
    function testBytes4Encoding() public {
        bytes4 sel = 0xb9056dbd;

        bytes32 storedValue;
        assembly {
            let m := mload(0x40)
            mstore(m, sel)
            storedValue := mload(m)
        }

        // If bytes4 is right-aligned, first 4 bytes should be 0x00000000
        // If bytes4 is left-aligned, first 4 bytes should be 0xb9056dbd
        bytes4 first4Bytes = bytes4(storedValue);

        emit log_named_bytes32("Stored value", storedValue);
        emit log_named_bytes32("First4 as bytes32", bytes32(first4Bytes));

        // The question: is first4Bytes == 0xb9056dbd or 0x00000000?
        if (first4Bytes == 0xb9056dbd) {
            emit log_string("PASS: bytes4 is LEFT-aligned (comment is correct)");
        } else {
            emit log_string("FAIL: bytes4 is RIGHT-aligned (reviewer is correct)");
        }

        assertEq(uint32(first4Bytes), uint32(0xb9056dbd), "bytes4 should be left-aligned in memory");
    }
}
