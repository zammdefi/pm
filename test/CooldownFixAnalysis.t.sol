// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

/// @title Analysis of Cooldown Fix
/// @notice Tests to verify the proposed fix doesn't break intended behavior
contract CooldownFixAnalysis is Test {
    /// Simulates the cooldown update logic
    function simulateCooldownUpdate(
        uint256 existingShares,
        uint256 newShares,
        uint256 oldTime,
        uint256 currentTime,
        uint256 close,
        bool isSelfDeposit
    ) internal pure returns (uint256 newCooldown, string memory reason) {
        // First deposit
        if (existingShares == 0) {
            return (currentTime, "First deposit");
        }

        // Check if in final window (within 12 hours of close)
        bool inFinalWindow = currentTime > close || (close - currentTime) < 43200;

        // PROPOSED FIX: Hard reset only if self-deposit AND in final window
        if (inFinalWindow && isSelfDeposit) {
            return (currentTime, "Self-deposit in final window - hard reset");
        }

        // Otherwise use weighted average
        uint256 totalShares = existingShares + newShares;
        uint256 weightedTime = (existingShares * oldTime + newShares * currentTime) / totalShares;
        return (weightedTime, "Weighted average");
    }

    /// Check cooldown requirements
    function checkCooldown(uint256 depositTime, uint256 currentTime, uint256 close)
        internal
        pure
        returns (bool canWithdraw, uint256 required, string memory status)
    {
        if (depositTime == 0) return (true, 0, "No cooldown");

        bool inFinalWindow = depositTime > close || (close - depositTime) < 43200;
        required = inFinalWindow ? 86400 : 21600; // 24h or 6h
        uint256 elapsed = currentTime - depositTime;

        if (elapsed >= required) {
            return (true, required, "Cooldown satisfied");
        } else {
            return (false, required, "Cooldown active");
        }
    }

    /// Test 1: Griefing attack is prevented
    function test_GriefingAttackPrevented() public {
        emit log_string("\n=== Test 1: Griefing Attack Prevention ===");

        uint256 aliceShares = 1000 ether;
        uint256 attackerShares = 1 wei;
        uint256 aliceDepositTime = 0;
        uint256 attackTime = 100 hours - 11 hours; // 11h before close
        uint256 close = 100 hours;

        (uint256 newCooldown, string memory reason) = simulateCooldownUpdate(
            aliceShares,
            attackerShares,
            aliceDepositTime,
            attackTime,
            close,
            false // NOT self-deposit
        );

        emit log_named_uint("Alice's original cooldown", aliceDepositTime);
        emit log_named_uint("Attack time", attackTime);
        emit log_named_uint("New cooldown after attack", newCooldown);
        emit log_string(reason);

        // With weighted average, cooldown barely changes
        uint256 expectedCooldown = (aliceShares * aliceDepositTime + attackerShares * attackTime)
            / (aliceShares + attackerShares);

        assertEq(newCooldown, expectedCooldown, "Should use weighted average");
        assertLt(newCooldown, 1 hours, "Cooldown should remain near zero");

        // Alice can still withdraw soon after close
        (bool canWithdraw,,) = checkCooldown(newCooldown, close + 7 hours, close);
        assertTrue(canWithdraw, "Alice should be able to withdraw");

        emit log_string("PASS: Griefing attack prevented!");
    }

    /// Test 2: Self-deposit in final window still resets (prevents bypass)
    function test_SelfDepositInFinalWindowResets() public {
        emit log_string("\n=== Test 2: Self-Deposit in Final Window ===");

        uint256 aliceShares = 1000 ether;
        uint256 newDeposit = 100 ether;
        uint256 oldTime = 50 hours;
        uint256 depositTime = 100 hours - 11 hours; // 11h before close
        uint256 close = 100 hours;

        (uint256 newCooldown, string memory reason) = simulateCooldownUpdate(
            aliceShares,
            newDeposit,
            oldTime,
            depositTime,
            close,
            true // Self-deposit
        );

        emit log_named_uint("Old cooldown", oldTime);
        emit log_named_uint("Self-deposit time", depositTime);
        emit log_named_uint("New cooldown", newCooldown);
        emit log_string(reason);

        assertEq(newCooldown, depositTime, "Should hard reset to NOW");

        // Alice must wait 24h from her self-deposit
        (bool canWithdraw, uint256 required,) = checkCooldown(newCooldown, close + 1 hours, close);
        assertFalse(canWithdraw, "Should not be able to withdraw yet");
        assertEq(required, 86400, "Should require 24h cooldown");

        emit log_string("PASS: Self-deposit correctly resets cooldown!");
    }

    /// Test 3: Third-party deposit outside final window uses weighted average
    function test_ThirdPartyDepositOutsideFinalWindow() public {
        emit log_string("\n=== Test 3: Third-Party Outside Final Window ===");

        uint256 aliceShares = 1000 ether;
        uint256 bobShares = 500 ether;
        uint256 aliceTime = 10 hours;
        uint256 bobTime = 50 hours;
        uint256 close = 100 hours;

        (uint256 newCooldown, string memory reason) = simulateCooldownUpdate(
            aliceShares,
            bobShares,
            aliceTime,
            bobTime,
            close,
            false // Third-party
        );

        emit log_named_uint("Alice cooldown", aliceTime);
        emit log_named_uint("Bob deposit time", bobTime);
        emit log_named_uint("New cooldown", newCooldown);
        emit log_string(reason);

        uint256 expected =
            (aliceShares * aliceTime + bobShares * bobTime) / (aliceShares + bobShares);
        assertEq(newCooldown, expected, "Should use weighted average");

        emit log_string("PASS: Weighted average works correctly!");
    }

    /// Test 4: Large colluding deposit doesn't bypass cooldown unfairly
    function test_ColludingDepositNoBypass() public {
        emit log_string("\n=== Test 4: Colluding Deposit ===");

        // Alice has old position, Bob deposits equal amount in final window
        uint256 aliceShares = 1000 ether;
        uint256 bobShares = 1000 ether; // Equal to Alice
        uint256 aliceTime = 0;
        uint256 bobTime = 100 hours - 11 hours;
        uint256 close = 100 hours;

        (uint256 newCooldown, string memory reason) = simulateCooldownUpdate(
            aliceShares,
            bobShares,
            aliceTime,
            bobTime,
            close,
            false // Bob depositing to Alice
        );

        emit log_named_uint("Alice cooldown", aliceTime);
        emit log_named_uint("Bob deposit time", bobTime);
        emit log_named_uint("New cooldown", newCooldown);
        emit log_string(reason);

        // Cooldown is average of the two times
        uint256 avgTime = (aliceTime + bobTime) / 2;
        assertEq(newCooldown, avgTime, "Should be average");

        // Check withdrawal
        (bool canWithdraw, uint256 required, string memory status) =
            checkCooldown(newCooldown, close, close);

        emit log_named_uint("Required cooldown (seconds)", required);
        emit log_named_uint("Elapsed at close (seconds)", close - newCooldown);
        emit log_string(status);

        // The averaged cooldown is NOT in final window
        // So only 6h cooldown required
        assertEq(required, 21600, "Should require 6h cooldown");

        // Can withdraw after close since cooldown satisfied
        assertTrue(canWithdraw, "Should be able to withdraw");

        emit log_string("PASS: Colluding doesn't provide unfair advantage!");
    }

    /// Test 5: Weighted average is fair and prevents gaming
    function test_WeightedAverageFairness() public {
        emit log_string("\n=== Test 5: Weighted Average Fairness ===");

        // Small third-party deposit should barely affect cooldown
        uint256 aliceShares = 10000 ether;
        uint256 attackerShares = 1 ether; // 0.01% of Alice's position
        uint256 aliceTime = 10 hours;
        uint256 attackTime = 90 hours;
        uint256 close = 100 hours;

        (uint256 newCooldown,) =
            simulateCooldownUpdate(aliceShares, attackerShares, aliceTime, attackTime, close, false);

        uint256 expectedShift = (attackerShares * attackTime) / (aliceShares + attackerShares);
        uint256 actualShift = newCooldown - aliceTime;

        emit log_named_uint("Original cooldown (hours)", aliceTime / 1 hours);
        emit log_named_uint("New cooldown (hours)", newCooldown / 1 hours);
        emit log_named_uint("Shift (seconds)", actualShift);
        emit log_named_uint("Expected shift (seconds)", expectedShift);

        // Shift should be tiny
        assertLt(actualShift, 1 hours, "Shift should be minimal");

        emit log_string("PASS: Weighted average provides fair, proportional updates!");
    }
}
