// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Script, console} from "@forge/Script.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";

/**
 * @title CheckBytecodeSize
 * @notice Script to check the deployment bytecode size of PMHookRouter
 * @dev Run with: forge script script/CheckBytecodeSize.s.sol
 */
contract CheckBytecodeSize is Script {
    uint256 constant MAX_BYTECODE_SIZE = 24576; // 24KB limit (EIP-170)

    function run() public view {
        bytes memory bytecode = type(PMHookRouter).creationCode;
        uint256 size = bytecode.length;

        console.log("=== PMHookRouter Bytecode Size ===");
        console.log("Deployment bytecode size:", size, "bytes");
        console.log("Maximum allowed size:   ", MAX_BYTECODE_SIZE, "bytes");
        console.log("Size in KB:             ", size / 1024, "KB");
        console.log("Remaining space:        ", MAX_BYTECODE_SIZE - size, "bytes");
        console.log("Usage percentage:       ", (size * 100) / MAX_BYTECODE_SIZE, "%");
        console.log("");

        if (size > MAX_BYTECODE_SIZE) {
            console.log("ERROR: Contract exceeds maximum bytecode size!");
            console.log("Exceeds by:", size - MAX_BYTECODE_SIZE, "bytes");
        } else {
            console.log("SUCCESS: Contract is within bytecode size limit");
        }
    }
}
