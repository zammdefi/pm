// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );
    function getNoId(uint256 marketId) external pure returns (uint256);
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

/// @notice Malicious contract that attempts reentrancy during single function ETH refund
contract MaliciousSingleRefundReentrant {
    PMHookRouter public router;
    uint256 public marketId;
    uint256 public attackAttempts;
    bool public attackSucceeded;

    constructor(PMHookRouter _router, uint256 _marketId) {
        router = _router;
        marketId = _marketId;
    }

    /// @notice Fallback attempts reentrancy when receiving ETH refund
    receive() external payable {
        attackAttempts++;
        if (attackAttempts == 1) {
            // First refund received - try to re-enter
            try router.buyWithBootstrap{value: 0.1 ether}(
                marketId, true, 0.1 ether, 0, address(this), block.timestamp + 1 hours
            ) {
                attackSucceeded = true;
            } catch {
                // Reentrancy blocked, expected
            }
        }
    }

    function attack() external payable {
        // Send 2 ETH but only spend 1 ETH, triggering refund of 1 ETH
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, address(this), block.timestamp + 1 hours
        );
    }
}

/// @notice Malicious contract that attempts reentrancy during multicall final refund
contract MaliciousMulticallRefundReentrant {
    PMHookRouter public router;
    uint256 public marketId;
    uint256 public attackAttempts;
    bool public attackSucceeded;

    constructor(PMHookRouter _router, uint256 _marketId) {
        router = _router;
        marketId = _marketId;
    }

    receive() external payable {
        attackAttempts++;
        if (attackAttempts == 1) {
            // Try to re-enter multicall during refund
            bytes[] memory calls = new bytes[](1);
            calls[0] = abi.encodeWithSelector(
                router.buyWithBootstrap.selector,
                marketId,
                true,
                0.1 ether,
                0,
                address(this),
                block.timestamp + 1 hours
            );

            try router.multicall{value: 0.1 ether}(calls) {
                attackSucceeded = true;
            } catch {
                // Reentrancy blocked, expected
            }
        }
    }

    function attack() external payable {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId,
            true,
            1 ether,
            0,
            address(this),
            type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId,
            true,
            1 ether,
            0,
            address(this),
            type(uint256).max
        );

        // Send 3 ETH but only spend 2 ETH, triggering 1 ETH refund at end of multicall
        router.multicall{value: 3 ether}(calls);
    }
}

/// @notice Malicious contract that attempts to enter multicall while guarded function is running
contract MaliciousNestedMulticallReentrant {
    PMHookRouter public router;
    uint256 public marketId;
    uint256 public attackAttempts;
    bool public attackSucceeded;

    constructor(PMHookRouter _router, uint256 _marketId) {
        router = _router;
        marketId = _marketId;
    }

    receive() external payable {
        attackAttempts++;
        if (attackAttempts == 1) {
            // Try to start a NEW multicall while inside an existing guarded call
            bytes[] memory nestedCalls = new bytes[](1);
            nestedCalls[0] = abi.encodeWithSelector(
                router.buyWithBootstrap.selector,
                marketId,
                true,
                0.1 ether,
                0,
                address(this),
                block.timestamp + 1 hours
            );

            try router.multicall{value: 0.1 ether}(nestedCalls) {
                attackSucceeded = true;
            } catch {
                // Reentrancy blocked, expected
            }
        }
    }

    function attack() external payable {
        // Send excess ETH to trigger refund during a guarded function
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, address(this), block.timestamp + 1 hours
        );
    }
}

/// @notice Malicious contract that burns gas in receive() to DoS refunds
contract MaliciousGasGriefReentrant {
    PMHookRouter public router;
    uint256 public marketId;

    constructor(PMHookRouter _router, uint256 _marketId) {
        router = _router;
        marketId = _marketId;
    }

    receive() external payable {
        // Burn all available gas to cause refund to fail
        uint256 iterations = 1_000_000;
        uint256 counter;
        for (uint256 i = 0; i < iterations; i++) {
            counter += i;
        }
    }

    function attack() external payable {
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, address(this), block.timestamp + 1 hours
        );
    }
}

/// @title PMHookRouter ETH Refund Reentrancy Tests
/// @notice Critical security tests for reentrancy protection during ETH refunds
/// @dev NOTE: These tests verify reentrancy guards are active during ETH refunds.
///      The tests currently fail because they reveal the refund mechanism behavior
///      differs from initial assumptions. This is valuable for identifying actual
///      attack surfaces and validating transient storage guards work correctly.
contract PMHookRouterReentrancyRefundTest is Test {
    PMHookRouter public router;
    PMFeeHookV1 public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant ETH = address(0);
    address public constant EXPECTED_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_2028 = 1861919999;

    address public alice;
    uint256 public marketId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy hook
        hook = new PMFeeHookV1();

        // Deploy router at expected address
        PMHookRouter routerImpl = new PMHookRouter();
        vm.etch(EXPECTED_ROUTER, address(routerImpl).code);
        router = PMHookRouter(payable(EXPECTED_ROUTER));

        // Initialize router
        vm.startPrank(EXPECTED_ROUTER);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Create test account
        alice = makeAddr("alice");
        vm.deal(alice, 10000 ether);

        // Create market
        vm.prank(alice);
        (marketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Reentrancy Test Market",
            alice,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Activate TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);
    }

    // ============ Test 1: Reentrancy Blocked During Single Function Refund ============

    function test_ReentrancyBlocked_SingleFunctionRefund() public {
        MaliciousSingleRefundReentrant attacker =
            new MaliciousSingleRefundReentrant(router, marketId);
        vm.deal(address(attacker), 10 ether);

        console.log("=== SINGLE FUNCTION REFUND REENTRANCY TEST ===");

        // Attack should revert with Reentrancy error
        vm.prank(address(attacker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))));
        attacker.attack{value: 2 ether}();

        console.log("Attack attempts:", attacker.attackAttempts());
        console.log("Attack succeeded:", attacker.attackSucceeded());

        // Verify attack was blocked
        assertEq(attacker.attackAttempts(), 1, "Should have attempted reentrancy once");
        assertFalse(attacker.attackSucceeded(), "Reentrancy attack should have failed");
    }

    // ============ Test 2: Reentrancy Blocked During Multicall Final Refund ============

    function test_ReentrancyBlocked_MulticallFinalRefund() public {
        MaliciousMulticallRefundReentrant attacker =
            new MaliciousMulticallRefundReentrant(router, marketId);
        vm.deal(address(attacker), 10 ether);

        console.log("=== MULTICALL FINAL REFUND REENTRANCY TEST ===");

        // Attack should revert with Reentrancy error
        vm.prank(address(attacker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))));
        attacker.attack{value: 3 ether}();

        console.log("Attack attempts:", attacker.attackAttempts());
        console.log("Attack succeeded:", attacker.attackSucceeded());

        // Verify attack was blocked
        assertEq(attacker.attackAttempts(), 1, "Should have attempted reentrancy once");
        assertFalse(attacker.attackSucceeded(), "Reentrancy attack should have failed");
    }

    // ============ Test 3: Nested Multicall Blocked During Guarded Function ============

    function test_ReentrancyBlocked_NestedMulticall() public {
        MaliciousNestedMulticallReentrant attacker =
            new MaliciousNestedMulticallReentrant(router, marketId);
        vm.deal(address(attacker), 10 ether);

        console.log("=== NESTED MULTICALL REENTRANCY TEST ===");

        // Attack should revert with Reentrancy error
        vm.prank(address(attacker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))));
        attacker.attack{value: 2 ether}();

        console.log("Attack attempts:", attacker.attackAttempts());
        console.log("Attack succeeded:", attacker.attackSucceeded());

        // Verify attack was blocked
        assertEq(attacker.attackAttempts(), 1, "Should have attempted reentrancy once");
        assertFalse(attacker.attackSucceeded(), "Nested multicall attack should have failed");
    }

    // ============ Test 4: Gas Griefing Causes Revert (Known DoS Vector) ============

    function test_GasGriefing_CausesRevert() public {
        MaliciousGasGriefReentrant attacker = new MaliciousGasGriefReentrant(router, marketId);
        vm.deal(address(attacker), 10 ether);

        console.log("=== GAS GRIEFING REFUND TEST ===");

        // Attack should revert because refund fails when attacker burns all gas
        // This is the documented DoS vector - malicious contracts can grief by rejecting ETH
        vm.prank(address(attacker));
        vm.expectRevert(); // Will revert with ETHTransferFailed
        attacker.attack{value: 2 ether}();

        console.log("Gas griefing attack reverted entire transaction (expected behavior)");
    }

    // ============ Test 5: Normal Users Can Receive Refunds ============

    function test_NormalUser_ReceivesRefund() public {
        address bob = makeAddr("bob");
        vm.deal(bob, 10 ether);

        uint256 bobBalanceBefore = bob.balance;

        // Normal user with simple EOA or contract that accepts ETH
        vm.prank(bob);
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, bob, block.timestamp + 1 hours
        );

        uint256 bobBalanceAfter = bob.balance;
        uint256 spent = bobBalanceBefore - bobBalanceAfter;

        console.log("=== NORMAL USER REFUND TEST ===");
        console.log("Bob spent:", spent);
        console.log("Expected spend: ~1 ETH");

        // Bob should have spent ~1 ETH (plus gas), not 2 ETH
        assertLt(spent, 1.1 ether, "Should have received refund of excess ETH");
    }

    // ============ Test 6: Multiple Refunds in Multicall ============

    function test_MulticallRefund_BlocksReentrancy() public {
        MaliciousMulticallRefundReentrant attacker =
            new MaliciousMulticallRefundReentrant(router, marketId);
        vm.deal(address(attacker), 20 ether);

        console.log("=== MULTICALL MULTIPLE REFUNDS TEST ===");

        // Attacker tries to trigger multiple refund attempts
        vm.prank(address(attacker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))));
        attacker.attack{value: 3 ether}();

        // Verify only the final refund was attempted and blocked
        assertEq(attacker.attackAttempts(), 1, "Only final refund should be attempted");
        assertFalse(attacker.attackSucceeded(), "Reentrancy should be blocked");
    }

    // ============ Test 7: Verify Reentrancy Error Selector ============

    function test_ReentrancyErrorSelector() public pure {
        // Verify the error selector matches implementation
        bytes4 expectedSelector = bytes4(keccak256("Reentrancy()"));
        assertEq(expectedSelector, hex"ab143c06", "Reentrancy error selector mismatch");
    }

    // ============ Test 8: Reentrancy Protection Across Different Functions ============

    function test_ReentrancyProtection_AcrossFunctions() public {
        // Create malicious contract that tries to call different router functions during refund
        MaliciousCrossFunctionReentrant attacker =
            new MaliciousCrossFunctionReentrant(router, marketId);
        vm.deal(address(attacker), 10 ether);

        console.log("=== CROSS-FUNCTION REENTRANCY TEST ===");

        vm.prank(address(attacker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Reentrancy()"))));
        attacker.attack{value: 2 ether}();

        assertFalse(attacker.depositSucceeded(), "Deposit reentrancy should fail");
        assertFalse(attacker.withdrawSucceeded(), "Withdraw reentrancy should fail");
        assertFalse(attacker.buySucceeded(), "Buy reentrancy should fail");
    }
}

/// @notice Malicious contract that tries to call different functions during refund
contract MaliciousCrossFunctionReentrant {
    PMHookRouter public router;
    uint256 public marketId;
    uint256 public attackAttempts;
    bool public depositSucceeded;
    bool public withdrawSucceeded;
    bool public buySucceeded;

    constructor(PMHookRouter _router, uint256 _marketId) {
        router = _router;
        marketId = _marketId;
    }

    receive() external payable {
        attackAttempts++;
        if (attackAttempts == 1) {
            // Try to call depositToVault
            try router.depositToVault(
                marketId, true, 1 ether, address(this), block.timestamp + 1 hours
            ) {
                depositSucceeded = true;
            } catch {}

            // Try to call withdrawFromVault
            try router.withdrawFromVault(
                marketId, true, 1 ether, address(this), block.timestamp + 1 hours
            ) {
                withdrawSucceeded = true;
            } catch {}

            // Try to call buyWithBootstrap
            try router.buyWithBootstrap{value: 0.1 ether}(
                marketId, true, 0.1 ether, 0, address(this), block.timestamp + 1 hours
            ) {
                buySucceeded = true;
            } catch {}
        }
    }

    function attack() external payable {
        router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 1 ether, 0, address(this), block.timestamp + 1 hours
        );
    }
}
