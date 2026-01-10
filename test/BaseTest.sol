// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

/// @title BaseTest
/// @notice Base test contract with RPC fallback mechanism
/// @dev Provides helpers to create forks with automatic fallback to alternative RPCs
abstract contract BaseTest is Test {
    // RPC endpoint names in order of preference
    string[] internal rpcEndpoints;

    constructor() {
        // Initialize RPC endpoints - order by reliability/speed
        rpcEndpoints.push("main"); // blastapi
        rpcEndpoints.push("main2"); // mevblocker
        rpcEndpoints.push("main3"); // publicnode
        rpcEndpoints.push("main4"); // flashbots
        rpcEndpoints.push("main5"); // drpc
        rpcEndpoints.push("main6"); // ankr
        rpcEndpoints.push("main7"); // cloudflare
        rpcEndpoints.push("main8"); // alchemy demo
        rpcEndpoints.push("main9"); // 1rpc
    }

    /// @notice Create a fork with automatic fallback to alternative RPCs
    /// @param preferredRpc The preferred RPC endpoint name (e.g., "main3")
    /// @return The fork ID
    function createForkWithFallback(string memory preferredRpc) internal returns (uint256) {
        // Try preferred RPC first
        try vm.createSelectFork(vm.rpcUrl(preferredRpc)) returns (uint256 forkId) {
            return forkId;
        } catch {}

        // Fall back to other RPCs
        for (uint256 i = 0; i < rpcEndpoints.length; i++) {
            // Skip if same as preferred (already tried)
            if (keccak256(bytes(rpcEndpoints[i])) == keccak256(bytes(preferredRpc))) {
                continue;
            }

            try vm.createSelectFork(vm.rpcUrl(rpcEndpoints[i])) returns (uint256 forkId) {
                return forkId;
            } catch {
                continue;
            }
        }

        revert("All RPC endpoints failed");
    }

    /// @notice Create a fork trying RPCs in round-robin based on test contract address
    /// @dev Uses contract address to distribute load across RPCs
    /// @return The fork ID
    function createForkDistributed() internal returns (uint256) {
        // Use contract address to pick starting RPC (distributes load)
        uint256 startIdx = uint256(uint160(address(this))) % rpcEndpoints.length;

        for (uint256 i = 0; i < rpcEndpoints.length; i++) {
            uint256 idx = (startIdx + i) % rpcEndpoints.length;
            try vm.createSelectFork(vm.rpcUrl(rpcEndpoints[idx])) returns (uint256 forkId) {
                return forkId;
            } catch {
                continue;
            }
        }

        revert("All RPC endpoints failed");
    }

    /// @notice Create a fork at a specific block with fallback
    /// @param preferredRpc The preferred RPC endpoint name
    /// @param blockNumber The block number to fork at
    /// @return The fork ID
    function createForkWithFallback(string memory preferredRpc, uint256 blockNumber)
        internal
        returns (uint256)
    {
        // Try preferred RPC first
        try vm.createSelectFork(vm.rpcUrl(preferredRpc), blockNumber) returns (uint256 forkId) {
            return forkId;
        } catch {}

        // Fall back to other RPCs
        for (uint256 i = 0; i < rpcEndpoints.length; i++) {
            if (keccak256(bytes(rpcEndpoints[i])) == keccak256(bytes(preferredRpc))) {
                continue;
            }

            try vm.createSelectFork(vm.rpcUrl(rpcEndpoints[i]), blockNumber) returns (
                uint256 forkId
            ) {
                return forkId;
            } catch {
                continue;
            }
        }

        revert("All RPC endpoints failed");
    }
}
