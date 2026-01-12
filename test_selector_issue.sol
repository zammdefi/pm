// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

contract SelectorTest is Test {
    function testSelectorAlignment() public {
        bytes4 sel = 0x5f598ac3;
        uint256 arg = 123;
        
        // Simulate what _staticUint does
        bytes memory calldata_;
        assembly {
            let m := mload(0x40)
            mstore(m, sel)  // Store bytes4 directly
            mstore(add(m, 0x04), arg)
            
            // Extract what would be sent as calldata
            calldata_ := mload(0x40)
            mstore(calldata_, 0x24)  // length
            mstore(0x40, add(calldata_, 0x44))
            
            // Copy the calldata
            let src := m
            let dst := add(calldata_, 0x20)
            mstore(dst, mload(src))
            mstore(add(dst, 0x20), mload(add(src, 0x20)))
        }
        
        console.log("First 4 bytes of calldata:");
        console.logBytes4(bytes4(bytes32(calldata_) << 160));
        console.log("Expected selector: 0x5f598ac3");
        
        // Check if first 4 bytes match selector
        bytes4 actualFirst4 = bytes4(uint32(uint256(bytes32(calldata_) << 160) >> 224));
        console.log("Actual first 4 bytes are zero?", actualFirst4 == bytes4(0));
    }
}
