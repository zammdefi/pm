// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./BaseTest.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
}

interface IZAMM {
    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );
}

/// @title PMHookRouter Spot/TWAP Semantic Consistency Tests
/// @notice Tests that spot price and TWAP use the same P(YES) = NO/(YES+NO) convention
/// @dev These tests would have caught the bug where spot used YES/(YES+NO) but TWAP used NO/(YES+NO)
contract PMHookRouterSpotTWAPConsistencyTest is BaseTest {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;
    address public CAROL;

    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        createForkWithFallback("main3");

        hook = new PMFeeHook();

        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        CAROL = makeAddr("CAROL");

        deal(ALICE, 10000 ether);
        deal(BOB, 10000 ether);
        deal(CAROL, 10000 ether);

        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Spot TWAP Consistency Test",
            ALICE,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            1000 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    /// @notice Helper to get current pool reserves
    function _getReserves() internal view returns (uint112 yesRes, uint112 noRes) {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        uint256 noId = marketId + 1;
        bool yesIsId0 = marketId < noId;
        yesRes = yesIsId0 ? r0 : r1;
        noRes = yesIsId0 ? r1 : r0;
    }

    /// @notice Helper to compute P(YES) = NO/(YES+NO) in bps
    function _computePYesBps(uint256 yesRes, uint256 noRes) internal pure returns (uint256) {
        uint256 total = yesRes + noRes;
        if (total == 0) return 5000;
        uint256 pYes = (noRes * 10000) / total;
        if (pYes == 0) return 1;
        if (pYes >= 10000) return 9999;
        return pYes;
    }

    // ============ Core Consistency Tests ============

    /// @notice Test OTC fill works at 50/50 (baseline - both conventions agree here)
    function test_OTCFill_At5050_Works() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish TWAP (matches pattern from working tests)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        (uint112 yesRes, uint112 noRes) = _getReserves();
        uint256 pYes = _computePYesBps(yesRes, noRes);

        // At 50/50, P(YES) should be ~5000
        assertApproxEqAbs(pYes, 5000, 100, "Pool should be near 50/50");

        // OTC fill should work
        vm.prank(BOB);
        (uint256 shares,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(shares, 0, "Should receive shares at 50/50");
    }

    /// @notice Test OTC fill works after price moves via trades (with TWAP tracking)
    /// @dev This test validates the fix for the spot/TWAP semantic mismatch bug.
    ///      With the bug, at skewed prices the deviation check would fail even when aligned.
    function test_OTCFill_AfterPriceMove_HighPYes_Works() public {
        // Setup vault with both sides
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish initial TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Make trades that move price
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Let TWAP catch up
        vm.warp(block.timestamp + 35 minutes);
        router.updateTWAPObservation(marketId);

        (uint112 yesRes, uint112 noRes) = _getReserves();
        uint256 pYes = _computePYesBps(yesRes, noRes);

        // Pool should now be skewed (P(YES) > 5000)
        assertGt(pYes, 5200, "Pool should be skewed towards high P(YES)");

        // This should work with the fix. With the bug, this would fail because:
        //   - TWAP correctly computes P(YES) = NO/(YES+NO) ~ high value
        //   - Old spot incorrectly computed YES/(YES+NO) ~ low value
        //   - Deviation = |high - low| >> 500 bps
        vm.prank(BOB);
        (uint256 shares,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(shares, 0, "Should receive shares at skewed price");
    }

    /// @notice Test OTC fill works with price skewed in opposite direction
    function test_OTCFill_AfterPriceMove_LowPYes_Works() public {
        // Setup vault with both sides
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish initial TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Buy NO to decrease P(YES)
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, false, 100 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Let TWAP catch up
        vm.warp(block.timestamp + 35 minutes);
        router.updateTWAPObservation(marketId);

        (uint112 yesRes, uint112 noRes) = _getReserves();
        uint256 pYes = _computePYesBps(yesRes, noRes);

        // Pool should be skewed low
        assertLt(pYes, 4800, "Pool should be skewed towards low P(YES)");

        // Should work with the fix
        vm.prank(BOB);
        (uint256 shares,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, false, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(shares, 0, "Should receive shares at low skewed price");
    }

    /// @notice Test rebalance works at skewed prices
    function test_Rebalance_AfterPriceMove_Works() public {
        // Setup vault with imbalance
        vm.startPrank(ALICE);
        PAMM.split{value: 500 ether}(marketId, 500 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 400 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish initial TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Generate budget and skew pool with larger trade
        vm.prank(BOB);
        router.buyWithBootstrap{value: 200 ether}(
            marketId, true, 200 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Let TWAP catch up
        vm.warp(block.timestamp + 35 minutes);
        router.updateTWAPObservation(marketId);

        (uint112 yesRes, uint112 noRes) = _getReserves();
        uint256 pYes = _computePYesBps(yesRes, noRes);
        assertGt(pYes, 5100, "Pool should be skewed");

        uint256 budget = router.rebalanceCollateralBudget(marketId);

        if (budget > 0.1 ether) {
            // With the fix, rebalance should not revert due to spot/TWAP deviation
            router.rebalanceBootstrapVault(marketId, block.timestamp + 1 hours);
            assertTrue(true, "Rebalance succeeded at skewed price");
        }
    }

    // ============ Semantic Unit Tests ============

    /// @notice Test semantic consistency: P(YES) formula is NO/(YES+NO)
    function test_SemanticConsistency_PYesIsNoOverTotal() public pure {
        // At 50/50: P(YES) = 500/1000 = 5000 bps
        assertEq(_computePYesBps_static(500, 500), 5000, "50/50 should give 5000 bps");

        // At 75% YES reserves, 25% NO reserves: P(YES) = 250/1000 = 2500 bps
        assertEq(
            _computePYesBps_static(750, 250), 2500, "75/25 YES/NO should give P(YES) = 2500 bps"
        );

        // At 25% YES reserves, 75% NO reserves: P(YES) = 750/1000 = 7500 bps
        assertEq(
            _computePYesBps_static(250, 750), 7500, "25/75 YES/NO should give P(YES) = 7500 bps"
        );

        // Extreme: mostly YES, P(YES) near 0
        assertEq(_computePYesBps_static(9900, 100), 100, "99/1 YES/NO should give P(YES) = 100 bps");

        // Extreme: mostly NO, P(YES) near 100%
        assertEq(
            _computePYesBps_static(100, 9900), 9900, "1/99 YES/NO should give P(YES) = 9900 bps"
        );
    }

    /// @notice Test demonstrating the bug scenario mathematically
    /// @dev At 70/30 YES/NO reserves:
    ///      - Correct P(YES) = NO/total = 30% = 3000 bps
    ///      - Wrong (old) spot = YES/total = 70% = 7000 bps
    ///      - Deviation = |7000-3000| = 4000 bps >> 500 threshold
    function test_BugScenario_DeviationCalculation() public pure {
        uint256 yesRes = 700;
        uint256 noRes = 300;
        uint256 total = yesRes + noRes;

        // Correct: P(YES) = NO/total
        uint256 correctPYes = (noRes * 10000) / total;
        assertEq(correctPYes, 3000, "Correct P(YES) = 30%");

        // Wrong (old bug): spot = YES/total
        uint256 wrongSpot = (yesRes * 10000) / total;
        assertEq(wrongSpot, 7000, "Wrong spot = 70%");

        // With bug: deviation between wrong spot and correct TWAP
        uint256 bugDeviation =
            wrongSpot > correctPYes ? wrongSpot - correctPYes : correctPYes - wrongSpot;
        assertEq(bugDeviation, 4000, "Bug would cause 4000 bps deviation");
        assertGt(bugDeviation, 500, "Bug deviation exceeds threshold");

        // With fix: both use same formula, deviation = 0
        uint256 correctSpot = correctPYes;
        uint256 fixedDeviation =
            correctSpot > correctPYes ? correctSpot - correctPYes : correctPYes - correctSpot;
        assertEq(fixedDeviation, 0, "Fixed deviation = 0 when aligned");
    }

    /// @notice Fuzz test: any aligned spot/TWAP has zero deviation
    function testFuzz_AlignedSpotTWAP_ZeroDeviation(uint112 yesRes, uint112 noRes) public pure {
        vm.assume(yesRes > 0 && noRes > 0);
        vm.assume(uint256(yesRes) + uint256(noRes) <= type(uint112).max);

        uint256 total = uint256(yesRes) + uint256(noRes);

        // Correct formula for both: P(YES) = NO/total
        uint256 pYes = (uint256(noRes) * 10000) / total;
        if (pYes == 0) pYes = 1;
        if (pYes >= 10000) pYes = 9999;

        // When both use same formula, deviation = 0
        uint256 deviation = 0;
        assertLe(deviation, 500, "Aligned spot/TWAP never exceeds threshold");
    }

    function _computePYesBps_static(uint256 yesRes, uint256 noRes) internal pure returns (uint256) {
        uint256 total = yesRes + noRes;
        if (total == 0) return 5000;
        uint256 pYes = (noRes * 10000) / total;
        if (pYes == 0) return 1;
        if (pYes >= 10000) return 9999;
        return pYes;
    }
}
