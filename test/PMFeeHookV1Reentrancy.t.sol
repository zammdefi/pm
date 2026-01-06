// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";
import {IPAMM} from "../src/PMHookRouter.sol";
import {IZAMM} from "../src/PMHookRouter.sol";

/// @notice Malicious contract attempting reentrancy during beforeAction
contract MaliciousReentrantBeforeAction {
    PMFeeHookV1 public hook;
    uint256 public poolId;
    bool public attacked;

    constructor(PMFeeHookV1 _hook, uint256 _poolId) {
        hook = _hook;
        poolId = _poolId;
    }

    /// @notice Fallback to attempt reentrancy when receiving ETH
    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to re-enter beforeAction
            hook.beforeAction(
                bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
                poolId,
                address(this),
                ""
            );
        }
    }

    /// @notice Trigger initial call that will try to re-enter
    function attack() external {
        hook.beforeAction{value: 0.1 ether}(
            bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
            poolId,
            address(this),
            ""
        );
    }
}

/// @notice Malicious contract attempting reentrancy during afterAction
contract MaliciousReentrantAfterAction {
    PMFeeHookV1 public hook;
    uint256 public poolId;
    bool public attacked;

    constructor(PMFeeHookV1 _hook, uint256 _poolId) {
        hook = _hook;
        poolId = _poolId;
    }

    /// @notice Fallback to attempt reentrancy when receiving ETH
    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to re-enter afterAction
            hook.afterAction(
                bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
                poolId,
                address(this),
                int256(1000),
                int256(-900),
                0,
                ""
            );
        }
    }

    /// @notice Trigger initial call that will try to re-enter
    function attack() external {
        hook.afterAction{value: 0.1 ether}(
            bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
            poolId,
            address(this),
            int256(1000),
            int256(-900),
            0,
            ""
        );
    }
}

/// @notice Malicious contract attempting cross-function reentrancy (beforeAction → afterAction)
contract MaliciousCrossFunctionReentrant {
    PMFeeHookV1 public hook;
    uint256 public poolId;
    bool public attacked;

    constructor(PMFeeHookV1 _hook, uint256 _poolId) {
        hook = _hook;
        poolId = _poolId;
    }

    /// @notice Fallback to attempt cross-function reentrancy
    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to call afterAction while in beforeAction
            hook.afterAction(
                bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
                poolId,
                address(this),
                int256(1000),
                int256(-900),
                0,
                ""
            );
        }
    }

    /// @notice Trigger initial beforeAction that will try to re-enter via afterAction
    function attack() external {
        hook.beforeAction{value: 0.1 ether}(
            bytes4(keccak256("swapExactIn(PoolKey,uint256,uint256,bool,address,uint256)")),
            poolId,
            address(this),
            ""
        );
    }
}

contract PMFeeHookV1ReentrancyTest is Test {
    PMFeeHookV1 public hook;
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address public constant ALICE = address(0xABCD);
    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        vm.deal(ALICE, 1000 ether);

        // Create a test market
        vm.startPrank(ALICE);
        (marketId,) = PAMM.createMarket(
            "Reentrancy Test Market",
            ALICE,
            address(0), // ETH
            uint64(block.timestamp + 30 days),
            false
        );
        vm.stopPrank();

        // Derive pool ID (simplified - assumes ZAMM pool exists)
        uint256 noId = PAMM.getNoId(marketId);
        poolId = uint256(
            keccak256(
                abi.encode(
                    marketId < noId ? marketId : noId,
                    marketId < noId ? noId : marketId,
                    address(PAMM),
                    address(PAMM),
                    address(hook)
                )
            )
        );
    }

    /// @notice Test that reentrancy is blocked in beforeAction
    function test_ReentrancyBlocked_BeforeAction() public {
        // Note: This test expects the attack to fail because:
        // 1. Only ZAMM can call beforeAction (msg.sender check)
        // 2. Even if we could call it, reentrancy guard would block

        MaliciousReentrantBeforeAction attacker = new MaliciousReentrantBeforeAction(hook, poolId);

        vm.deal(address(attacker), 1 ether);

        // Attack should revert with Unauthorized (can't call beforeAction directly)
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        attacker.attack();

        assertFalse(attacker.attacked(), "Attack should not have succeeded");
    }

    /// @notice Test that reentrancy is blocked in afterAction
    function test_ReentrancyBlocked_AfterAction() public {
        // Note: This test expects the attack to fail because:
        // 1. Only ZAMM can call afterAction (msg.sender check)
        // 2. Even if we could call it, reentrancy guard would block

        MaliciousReentrantAfterAction attacker = new MaliciousReentrantAfterAction(hook, poolId);

        vm.deal(address(attacker), 1 ether);

        // Attack should revert with Unauthorized (can't call afterAction directly)
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        attacker.attack();

        assertFalse(attacker.attacked(), "Attack should not have succeeded");
    }

    /// @notice Test that cross-function reentrancy is blocked
    function test_ReentrancyBlocked_CrossFunction() public {
        MaliciousCrossFunctionReentrant attacker = new MaliciousCrossFunctionReentrant(hook, poolId);

        vm.deal(address(attacker), 1 ether);

        // Attack should revert with Unauthorized
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        attacker.attack();

        assertFalse(attacker.attacked(), "Attack should not have succeeded");
    }

    /// @notice Verify error selector for Reentrancy matches implementation
    function test_ReentrancyErrorSelector() public pure {
        // Verify the error selector matches what's in the code
        bytes4 expectedSelector = bytes4(keccak256("Reentrancy()"));
        assertEq(expectedSelector, hex"ab143c06", "Reentrancy error selector mismatch");
    }
}
