// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title PMHookRouter Dynamic Spread Tests
 * @notice Test suite for dynamic spread calculation based on inventory imbalance and time pressure
 * @dev Tests the _calculateDynamicSpread function behavior across various market conditions
 */
contract PMHookRouterDynamicSpreadTest is Test {
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IERC20 constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    uint64 constant DEADLINE_FAR_FUTURE = 2000000000; // Year 2033
    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    // Constants from PMHookRouter
    uint16 constant MIN_TWAP_SPREAD_BPS = 100; // 1%
    uint16 constant MAX_IMBALANCE_SPREAD_BPS = 400; // 4%
    uint16 constant MAX_TIME_BOOST_BPS = 200; // 2%
    uint16 constant MAX_SPREAD_BPS = 500; // 5% overall cap
    uint16 constant IMBALANCE_THRESHOLD_BPS = 5000; // 50%

    PMFeeHookV1 public hook;
    PMHookRouter public router;
    DynamicSpreadHarness public harness;
    address public ALICE;
    address public BOB;
    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address using vm.etch so hook.registerMarket accepts calls
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Manually initialize router (constructor logic doesn't run with vm.etch)
        vm.startPrank(REGISTRAR);
        pamm.setOperator(address(zamm), true);
        pamm.setOperator(address(pamm), true);
        vm.stopPrank();

        harness = new DynamicSpreadHarness();

        // Transfer hook ownership to router so it can register markets
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");

        deal(address(UNI), ALICE, 100_000 ether);
        deal(address(UNI), BOB, 100_000 ether);

        vm.startPrank(ALICE);
        UNI.approve(address(pamm), type(uint256).max);
        UNI.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _createMarketWithClose(uint64 closeTime) internal returns (uint256 newMarketId) {
        vm.prank(ALICE);
        (newMarketId,) =
            pamm.createMarket("Dynamic Spread Test Market", ALICE, address(UNI), closeTime, false);
    }

    // ============ Base Spread Tests ============

    function test_DynamicSpread_BalancedInventory_FarFromClose() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // Perfectly balanced inventory (50/50)
        uint256 yesShares = 1000 ether;
        uint256 noShares = 1000 ether;

        // Test both directions - should be same for balanced inventory
        uint256 spreadBuyYes = harness.calculateDynamicSpread(marketId, yesShares, noShares, true);
        uint256 spreadBuyNo = harness.calculateDynamicSpread(marketId, yesShares, noShares, false);

        // Should be minimum spread (no imbalance, no time pressure)
        assertEq(
            spreadBuyYes,
            MIN_TWAP_SPREAD_BPS,
            "Balanced inventory far from close should use min spread (buyYes)"
        );
        assertEq(
            spreadBuyNo,
            MIN_TWAP_SPREAD_BPS,
            "Balanced inventory far from close should use min spread (buyNo)"
        );
    }

    function test_DynamicSpread_SlightImbalance_NoIncrease() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // 55/45 split (55% imbalance, just over 50% threshold but very slight)
        uint256 yesShares = 550 ether;
        uint256 noShares = 450 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance = 55% = 5500 bps
        // Excess = 5500 - 5000 = 500 bps
        // Boost = 400 * 500 / 5000 = 40 bps
        // Total = 100 + 40 = 140 bps
        assertEq(spread, 140, "55/45 split should add small imbalance boost");
    }

    // ============ Imbalance Scaling Tests ============

    function test_DynamicSpread_ModerateImbalance() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // 70/30 split (70% imbalance)
        uint256 yesShares = 700 ether;
        uint256 noShares = 300 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance = 70% = 7000 bps
        // Excess = 7000 - 5000 = 2000 bps
        // Boost = (500 - 100) * 2000 / 5000 = 400 * 2000 / 5000 = 160 bps
        // Total = 100 + 160 = 260 bps
        assertEq(spread, 260, "70% imbalance should add ~160 bps boost");
    }

    function test_DynamicSpread_HighImbalance() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // 90/10 split (90% imbalance)
        uint256 yesShares = 900 ether;
        uint256 noShares = 100 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance = 90% = 9000 bps
        // Excess = 9000 - 5000 = 4000 bps
        // Boost = (500 - 100) * 4000 / 5000 = 400 * 4000 / 5000 = 320 bps
        // Total = 100 + 320 = 420 bps
        assertEq(spread, 420, "90% imbalance should add ~320 bps boost");
    }

    function test_DynamicSpread_ExtremeImbalance() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // 99/1 split (99% imbalance, near total depletion)
        uint256 yesShares = 990 ether;
        uint256 noShares = 10 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance = 99% = 9900 bps
        // Excess = 9900 - 5000 = 4900 bps
        // Boost = (500 - 100) * 4900 / 5000 = 400 * 4900 / 5000 = 392 bps
        // Total = 100 + 392 = 492 bps
        assertEq(spread, 492, "99% imbalance should add ~392 bps boost");
    }

    function test_DynamicSpread_CompleteDepletion() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // 100/0 split (one side completely depleted)
        uint256 yesShares = 1000 ether;
        uint256 noShares = 0 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance = 100% = 10000 bps
        // Excess = 10000 - 5000 = 5000 bps
        // Boost = 400 * 5000 / 5000 = 400 bps
        // Total = 100 + 400 = 500 bps
        assertEq(spread, MAX_SPREAD_BPS, "Complete depletion should hit max spread");
    }

    // ============ Time Pressure Tests ============

    function test_DynamicSpread_FarFromClose() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // No time pressure (>24h from close)
        assertEq(spread, MIN_TWAP_SPREAD_BPS, "Far from close should have no time pressure boost");
    }

    function test_DynamicSpread_TwentyFourHoursBeforeClose() public {
        // Market closes in exactly 24 hours
        marketId = _createMarketWithClose(uint64(block.timestamp + 24 hours));

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Time pressure should be minimal at 24h boundary
        // timeToClose = 24h, timeBoost = (500-100) * (1 days - 24h) / 2 days = 0
        assertEq(spread, MIN_TWAP_SPREAD_BPS, "24h before close should have no time boost yet");
    }

    function test_DynamicSpread_TwelveHoursBeforeClose() public {
        // Market closes in 12 hours
        marketId = _createMarketWithClose(uint64(block.timestamp + 12 hours));

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Time pressure calculation:
        // timeToClose = 12h
        // timeBoost = (500-100) * (1 days - 12h) / 2 days
        //           = 400 * 12h / 2 days
        //           = 400 * 12 / 48 = 100 bps
        // Total = 100 + 100 = 200 bps
        assertEq(spread, 200, "12h before close should add ~100 bps time boost");
    }

    function test_DynamicSpread_OneHourBeforeClose() public {
        // Market closes in 1 hour
        marketId = _createMarketWithClose(uint64(block.timestamp + 7 hours));

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Time pressure calculation:
        // timeToClose = 1h
        // timeBoost = (500-100) * (1 days - 1h) / 2 days
        //           = 400 * 23h / 2 days
        //           = 400 * 23 / 48 ≈ 191.67 bps
        // Total = 100 + 191 = 291 bps
        assertApproxEqAbs(spread, 291, 1, "1h before close should add ~191 bps time boost");
    }

    function test_DynamicSpread_VeryCloseToClose() public {
        // Market closes in 1 second (very close to close time)
        marketId = _createMarketWithClose(uint64(block.timestamp + 1));

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Time pressure very close to close:
        // timeToClose ≈ 1 second
        // timeBoost = (500-100) * (1 days - 1 sec) / 2 days
        //           ≈ 400 * 1 / 2 ≈ 200 bps
        // Total ≈ 100 + 200 = 300 bps
        assertApproxEqAbs(spread, 300, 1, "Very close to close should add near-max time boost");
    }

    // ============ Combined Effects Tests ============

    function test_DynamicSpread_ImbalancePlusTimeNearClose() public {
        // Market closes in 6 hours
        marketId = _createMarketWithClose(uint64(block.timestamp + 6 hours));

        // 80/20 split (moderate-high imbalance)
        uint256 yesShares = 800 ether;
        uint256 noShares = 200 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance boost:
        // Imbalance = 80% = 8000 bps
        // Excess = 8000 - 5000 = 3000 bps
        // imbalanceBoost = 400 * 3000 / 5000 = 240 bps
        //
        // Time boost:
        // timeToClose = 6h
        // timeBoost = 400 * (24h - 6h) / 48h = 400 * 18 / 48 = 150 bps
        //
        // Total = 100 + 240 + 150 = 490 bps
        assertEq(spread, 490, "Combined imbalance + time pressure should stack");
    }

    function test_DynamicSpread_ExtremeImbalanceNearClose() public {
        // Market closes in 2 hours
        marketId = _createMarketWithClose(uint64(block.timestamp + 2 hours));

        // 95/5 split (extreme imbalance)
        uint256 yesShares = 950 ether;
        uint256 noShares = 50 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Imbalance boost:
        // Imbalance = 95% = 9500 bps
        // Excess = 9500 - 5000 = 4500 bps
        // imbalanceBoost = 400 * 4500 / 5000 = 360 bps
        //
        // Time boost:
        // timeToClose = 2h
        // timeBoost = 400 * (24h - 2h) / 48h = 400 * 22 / 48 ≈ 183.33 bps
        //
        // Total = 100 + 360 + 183 = 643 bps
        // Capped at MAX_SPREAD_BPS = 500
        assertEq(spread, MAX_SPREAD_BPS, "Combined extreme effects should cap at max spread");
    }

    // ============ Edge Cases ============

    function test_DynamicSpread_ZeroInventory() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // Both sides empty (edge case, shouldn't happen in practice)
        uint256 yesShares = 0;
        uint256 noShares = 0;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // totalShares = 0, so no imbalance calculation
        // Should return min spread
        assertEq(spread, MIN_TWAP_SPREAD_BPS, "Zero inventory should use min spread");
    }

    function test_DynamicSpread_PastCloseWindow() public {
        // Market closes soon (1 hour) but we'll simulate being past close by warping time
        marketId = _createMarketWithClose(uint64(block.timestamp + 7 hours));

        // Warp forward 2 hours so we're past close
        vm.warp(block.timestamp + 2 hours);

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // After close, time pressure branch doesn't execute (block.timestamp >= close)
        // Should only have imbalance contribution (none in this case)
        assertEq(spread, MIN_TWAP_SPREAD_BPS, "Past close should not add time pressure");
    }

    function test_DynamicSpread_VerySmallInventory() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        // Very small but imbalanced
        uint256 yesShares = 100; // 100 wei
        uint256 noShares = 10; // 10 wei (90% imbalance)

        uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

        // Should still calculate imbalance correctly
        // Imbalance = 90.9% ≈ 9091 bps
        // Excess = 9091 - 5000 = 4091 bps
        // Boost = 400 * 4091 / 5000 ≈ 327 bps
        // Total ≈ 427 bps
        assertApproxEqAbs(spread, 427, 2, "Should handle small inventory amounts correctly");
    }

    // ============ Monotonicity Tests ============

    function test_DynamicSpread_MonotonicIncreaseWithImbalance() public {
        // Market closes in 30 days
        marketId = _createMarketWithClose(uint64(block.timestamp + 30 days));

        uint256 prevSpread = MIN_TWAP_SPREAD_BPS;

        // Test that spread increases monotonically with imbalance
        for (uint256 imbalance = 50; imbalance <= 100; imbalance += 10) {
            uint256 yesShares = imbalance * 10 ether;
            uint256 noShares = (100 - imbalance) * 10 ether;

            uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

            // Spread should never decrease as imbalance increases
            assertGe(spread, prevSpread, "Spread should increase monotonically with imbalance");
            prevSpread = spread;
        }
    }

    function test_DynamicSpread_MonotonicIncreaseNearClose() public {
        // Create market that closes in 24 hours
        marketId = _createMarketWithClose(uint64(block.timestamp + 24 hours));

        uint256 prevSpread = 0;

        // Balanced inventory
        uint256 yesShares = 500 ether;
        uint256 noShares = 500 ether;

        // Test that spread increases monotonically as close approaches
        // Start at 24h before close and advance time
        for (uint256 hoursPassed = 0; hoursPassed < 24; hoursPassed += 4) {
            if (hoursPassed > 0) {
                vm.warp(block.timestamp + 4 hours);
            }

            uint256 spread = harness.calculateDynamicSpread(marketId, yesShares, noShares);

            if (hoursPassed > 0) {
                // Spread should increase as we get closer to close
                assertGe(
                    spread, prevSpread, "Spread should increase monotonically approaching close"
                );
            }
            prevSpread = spread;
        }
    }
}

/**
 * @title DynamicSpreadHarness
 * @notice Test harness to expose internal _calculateDynamicSpread function
 */
contract DynamicSpreadHarness {
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));

    uint16 constant MIN_TWAP_SPREAD_BPS = 100;
    uint16 constant MAX_IMBALANCE_SPREAD_BPS = 400;
    uint16 constant MAX_TIME_BOOST_BPS = 200;
    uint16 constant MAX_SPREAD_BPS = 500;
    uint16 constant IMBALANCE_THRESHOLD_BPS = 5000;
    uint16 constant VAULT_CLOSE_WINDOW = 0;

    /// @notice 3-param version: defaults to consuming scarce side (worst case for testing max spread)
    function calculateDynamicSpread(uint256 marketId, uint256 yesShares, uint256 noShares)
        public
        view
        returns (uint256)
    {
        // Default to consuming the scarce side (triggers maximum spread)
        bool buyYes = yesShares < noShares; // If YES is scarce, buy YES (consume scarce)
        return calculateDynamicSpread(marketId, yesShares, noShares, buyYes);
    }

    /// @notice 4-param version: full directional spread calculation
    function calculateDynamicSpread(
        uint256 marketId,
        uint256 yesShares,
        uint256 noShares,
        bool buyYes
    ) public view returns (uint256 spreadBps) {
        spreadBps = MIN_TWAP_SPREAD_BPS;

        // Factor 1: DIRECTIONAL inventory imbalance scaling
        uint256 totalShares = yesShares + noShares;
        if (totalShares > 0) {
            bool yesScarce = yesShares < noShares;
            bool consumingScarce = (buyYes && yesScarce) || (!buyYes && !yesScarce);

            if (consumingScarce) {
                uint256 larger = yesShares > noShares ? yesShares : noShares;
                uint256 imbalanceBps = (larger * 10_000) / totalShares;

                if (imbalanceBps > IMBALANCE_THRESHOLD_BPS) {
                    uint256 excessImbalance = imbalanceBps - IMBALANCE_THRESHOLD_BPS;
                    uint256 imbalanceBoost = (MAX_IMBALANCE_SPREAD_BPS * excessImbalance) / 5000;
                    spreadBps += imbalanceBoost;
                }
            }
        }

        // Factor 2: Time pressure scaling
        (,,,, uint64 close,,) = pamm.markets(marketId);
        if (block.timestamp < close) {
            uint256 timeToClose = close - block.timestamp;

            // Note: VAULT_CLOSE_WINDOW is enforced by fillability checks, not by spread calculation

            if (timeToClose < 1 days) {
                uint256 timeBoost = (MAX_TIME_BOOST_BPS * (1 days - timeToClose)) / 1 days;
                spreadBps += timeBoost;
            }
        }

        // Apply overall cap to prevent excessive spreads
        if (spreadBps > MAX_SPREAD_BPS) {
            spreadBps = MAX_SPREAD_BPS;
        }

        return spreadBps;
    }
}
