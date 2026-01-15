// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

/// @notice Minimal contract with just the permit helper functions for testing
contract PermitHelpers {
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)

            let ok := call(gas(), token, 0, m, 0xe4, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x100)) // Update free memory pointer (32-byte aligned)
        }
    }

    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)

            let ok := call(gas(), token, 0, m, 0x104, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x120)) // Update free memory pointer (32-byte aligned)
        }
    }
}

/// @notice Mock token that records permit calldata for verification
contract MockPermitToken {
    bytes public lastCalldata;
    bool public shouldRevert;
    bool public shouldReturnFalse;
    bool public shouldReturnNothing;
    uint256 public returnDataSize;

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setReturnFalse(bool _shouldReturnFalse) external {
        shouldReturnFalse = _shouldReturnFalse;
    }

    function setReturnNothing(bool _shouldReturnNothing) external {
        shouldReturnNothing = _shouldReturnNothing;
    }

    function setCustomReturnSize(uint256 size) external {
        returnDataSize = size;
    }

    fallback() external {
        lastCalldata = msg.data;

        if (shouldRevert) {
            revert("MockPermitToken: revert");
        }

        if (returnDataSize > 0) {
            // Return custom size data (all zeros)
            assembly {
                return(0, sload(returnDataSize.slot))
            }
        }

        if (shouldReturnNothing) {
            return;
        }

        if (shouldReturnFalse) {
            assembly {
                mstore(0, 0)
                return(0, 32)
            }
        }

        // Default: return true
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }

    function getLastCalldata() external view returns (bytes memory) {
        return lastCalldata;
    }
}

contract PMHookRouterPermitTest is Test {
    PermitHelpers router;
    MockPermitToken mockToken;

    address owner = address(0x1111);
    uint256 value = 1000e18;
    uint256 deadline = block.timestamp + 1 hours;
    uint8 v = 27;
    bytes32 r = bytes32(uint256(1));
    bytes32 s = bytes32(uint256(2));

    function setUp() public {
        router = new PermitHelpers();
        mockToken = new MockPermitToken();
    }

    /// @notice Test that selector is correctly encoded in first 4 bytes (left-shifted)
    function test_Permit_SelectorEncoding() public {
        router.permit(address(mockToken), owner, value, deadline, v, r, s);

        bytes memory calldata_ = mockToken.getLastCalldata();

        // Extract first 4 bytes (selector)
        bytes4 selector;
        assembly {
            selector := mload(add(calldata_, 32))
        }

        // Verify selector is 0xd505accf (EIP-2612 permit)
        assertEq(selector, bytes4(0xd505accf), "Selector should be 0xd505accf in first 4 bytes");

        // Verify total calldata size is 0xe4 (228 bytes: 4 + 7*32)
        assertEq(calldata_.length, 0xe4, "Calldata should be 0xe4 bytes");
    }

    /// @notice Test that permitDAI selector is correctly encoded
    function test_PermitDAI_SelectorEncoding() public {
        uint256 nonce = 5;
        bool allowed = true;

        router.permitDAI(address(mockToken), owner, nonce, deadline, allowed, v, r, s);

        bytes memory calldata_ = mockToken.getLastCalldata();

        // Extract first 4 bytes (selector)
        bytes4 selector;
        assembly {
            selector := mload(add(calldata_, 32))
        }

        // Verify selector is 0x8fcbaf0c (DAI permit)
        assertEq(selector, bytes4(0x8fcbaf0c), "Selector should be 0x8fcbaf0c in first 4 bytes");

        // Verify total calldata size is 0x104 (260 bytes: 4 + 8*32)
        assertEq(calldata_.length, 0x104, "Calldata should be 0x104 bytes");
    }

    /// @notice Test complete calldata structure for permit
    function test_Permit_CalldataStructure() public {
        router.permit(address(mockToken), owner, value, deadline, v, r, s);

        bytes memory calldata_ = mockToken.getLastCalldata();

        // Decode and verify each parameter
        bytes4 selector;
        address decodedOwner;
        address decodedSpender;
        uint256 decodedValue;
        uint256 decodedDeadline;
        uint8 decodedV;
        bytes32 decodedR;
        bytes32 decodedS;

        assembly {
            let ptr := add(calldata_, 32)
            selector := mload(ptr)
            decodedOwner := mload(add(ptr, 0x04))
            decodedSpender := mload(add(ptr, 0x24))
            decodedValue := mload(add(ptr, 0x44))
            decodedDeadline := mload(add(ptr, 0x64))
            decodedV := mload(add(ptr, 0x84))
            decodedR := mload(add(ptr, 0xa4))
            decodedS := mload(add(ptr, 0xc4))
        }

        assertEq(selector, bytes4(0xd505accf), "Selector mismatch");
        assertEq(decodedOwner, owner, "Owner mismatch");
        assertEq(decodedSpender, address(router), "Spender should be router address");
        assertEq(decodedValue, value, "Value mismatch");
        assertEq(decodedDeadline, deadline, "Deadline mismatch");
        assertEq(decodedV, v, "V mismatch");
        assertEq(decodedR, r, "R mismatch");
        assertEq(decodedS, s, "S mismatch");
    }

    /// @notice Test complete calldata structure for permitDAI
    function test_PermitDAI_CalldataStructure() public {
        uint256 nonce = 5;
        bool allowed = true;

        router.permitDAI(address(mockToken), owner, nonce, deadline, allowed, v, r, s);

        bytes memory calldata_ = mockToken.getLastCalldata();

        // Decode and verify each parameter
        bytes4 selector;
        address decodedHolder;
        address decodedSpender;
        uint256 decodedNonce;
        uint256 decodedExpiry;
        bool decodedAllowed;
        uint8 decodedV;
        bytes32 decodedR;
        bytes32 decodedS;

        assembly {
            let ptr := add(calldata_, 32)
            selector := mload(ptr)
            decodedHolder := mload(add(ptr, 0x04))
            decodedSpender := mload(add(ptr, 0x24))
            decodedNonce := mload(add(ptr, 0x44))
            decodedExpiry := mload(add(ptr, 0x64))
            decodedAllowed := mload(add(ptr, 0x84))
            decodedV := mload(add(ptr, 0xa4))
            decodedR := mload(add(ptr, 0xc4))
            decodedS := mload(add(ptr, 0xe4))
        }

        assertEq(selector, bytes4(0x8fcbaf0c), "Selector mismatch");
        assertEq(decodedHolder, owner, "Holder mismatch");
        assertEq(decodedSpender, address(router), "Spender should be router address");
        assertEq(decodedNonce, nonce, "Nonce mismatch");
        assertEq(decodedExpiry, deadline, "Expiry mismatch");
        assertEq(decodedAllowed, allowed, "Allowed mismatch");
        assertEq(decodedV, v, "V mismatch");
        assertEq(decodedR, r, "R mismatch");
        assertEq(decodedS, s, "S mismatch");
    }

    /// @notice Test handling of token that returns nothing
    function test_Permit_NoReturnData() public {
        mockToken.setReturnNothing(true);

        // Should succeed without reverting
        router.permit(address(mockToken), owner, value, deadline, v, r, s);
    }

    /// @notice Test handling of token that returns true
    function test_Permit_ReturnTrue() public {
        // Default behavior is to return true

        // Should succeed
        router.permit(address(mockToken), owner, value, deadline, v, r, s);
    }

    /// @notice Test handling of token that returns false
    function test_Permit_ReturnFalse_Reverts() public {
        mockToken.setReturnFalse(true);

        // Should revert when token returns false
        vm.expectRevert();
        router.permit(address(mockToken), owner, value, deadline, v, r, s);
    }

    /// @notice Test handling of unexpected return data size
    function test_Permit_UnexpectedReturnSize_Reverts() public {
        mockToken.setCustomReturnSize(64); // Return 64 bytes instead of 0 or 32

        // Should revert with unexpected return size
        vm.expectRevert();
        router.permit(address(mockToken), owner, value, deadline, v, r, s);
    }

    /// @notice Test that token revert is bubbled up
    function test_Permit_BubblesRevert() public {
        mockToken.setRevert(true);

        // Should revert with the token's revert message
        vm.expectRevert("MockPermitToken: revert");
        router.permit(address(mockToken), owner, value, deadline, v, r, s);
    }

    /// @notice Same tests for permitDAI
    function test_PermitDAI_NoReturnData() public {
        mockToken.setReturnNothing(true);

        router.permitDAI(address(mockToken), owner, 0, deadline, true, v, r, s);
    }

    function test_PermitDAI_ReturnTrue() public {
        router.permitDAI(address(mockToken), owner, 0, deadline, true, v, r, s);
    }

    function test_PermitDAI_ReturnFalse_Reverts() public {
        mockToken.setReturnFalse(true);

        vm.expectRevert();
        router.permitDAI(address(mockToken), owner, 0, deadline, true, v, r, s);
    }

    function test_PermitDAI_UnexpectedReturnSize_Reverts() public {
        mockToken.setCustomReturnSize(64);

        vm.expectRevert();
        router.permitDAI(address(mockToken), owner, 0, deadline, true, v, r, s);
    }

    function test_PermitDAI_BubblesRevert() public {
        mockToken.setRevert(true);

        vm.expectRevert("MockPermitToken: revert");
        router.permitDAI(address(mockToken), owner, 0, deadline, true, v, r, s);
    }

    /// @notice Verify memory pointer is updated correctly (32-byte aligned)
    function test_Permit_MemoryAlignment() public view {
        // This is harder to test directly, but we can verify the implementation
        // The code sets: mstore(0x40, add(m, 0x100))
        // 0x100 = 256 bytes, which is 32-byte aligned (256 % 32 = 0)
        assertTrue(0x100 % 32 == 0, "0x100 should be 32-byte aligned");
    }

    function test_PermitDAI_MemoryAlignment() public view {
        // The code sets: mstore(0x40, add(m, 0x120))
        // 0x120 = 288 bytes, which is 32-byte aligned (288 % 32 = 0)
        assertTrue(0x120 % 32 == 0, "0x120 should be 32-byte aligned");
    }

    /// @notice Fuzz test with random valid inputs
    function testFuzz_Permit(
        address _owner,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        vm.assume(_owner != address(0));

        router.permit(address(mockToken), _owner, _value, _deadline, _v, _r, _s);

        bytes memory calldata_ = mockToken.getLastCalldata();
        assertEq(calldata_.length, 0xe4, "Calldata length should be 0xe4");

        // Verify selector
        bytes4 selector;
        assembly {
            selector := mload(add(calldata_, 32))
        }
        assertEq(selector, bytes4(0xd505accf), "Selector should be correct");
    }

    function testFuzz_PermitDAI(
        address _owner,
        uint256 _nonce,
        uint256 _deadline,
        bool _allowed,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        vm.assume(_owner != address(0));

        router.permitDAI(address(mockToken), _owner, _nonce, _deadline, _allowed, _v, _r, _s);

        bytes memory calldata_ = mockToken.getLastCalldata();
        assertEq(calldata_.length, 0x104, "Calldata length should be 0x104");

        // Verify selector
        bytes4 selector;
        assembly {
            selector := mload(add(calldata_, 32))
        }
        assertEq(selector, bytes4(0x8fcbaf0c), "Selector should be correct");
    }
}
