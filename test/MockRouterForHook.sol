// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mock router that returns fixed values for transient storage reads
/// @dev Used in tests to simulate the real router at the hardcoded address
contract MockRouterForHook {
    address public actualUser;
    address public actualRecipient;

    function setActualUser(address user) external {
        actualUser = user;
    }

    function setActualRecipient(address recipient) external {
        actualRecipient = recipient;
    }

    function getActualUser() external view returns (address) {
        return actualUser;
    }

    function getActualRecipient() external view returns (address) {
        return actualRecipient;
    }
}
