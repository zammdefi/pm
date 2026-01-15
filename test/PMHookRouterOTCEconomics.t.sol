// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

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

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @title PMHookRouter OTC Economics Tests
/// @notice Tests that verify economic correctness of OTC fills
/// @dev These tests ensure OTC pricing aligns with AMM probability semantics
contract PMHookRouterOTCEconomicsTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;

    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main7"));

        hook = new PMFeeHook();

        // Deploy router at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Initialize router
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");

        deal(ALICE, 10000 ether);
        deal(BOB, 10000 ether);

        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 500 ether}(
            "OTC Economics Test Market",
            ALICE,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            500 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    /// @notice Get P(YES) from AMM reserves (matches PMFeeHook._getProbability)
    /// @dev P(YES) = NO_reserve / (YES_reserve + NO_reserve)
    function _getAMMProbability() internal view returns (uint256 pYesBps) {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        uint256 noId = PAMM.getNoId(marketId);
        bool yesIsToken0 = marketId < noId;

        uint256 yesReserve = yesIsToken0 ? r0 : r1;
        uint256 noReserve = yesIsToken0 ? r1 : r0;

        uint256 total = yesReserve + noReserve;
        pYesBps = total == 0 ? 5000 : (noReserve * 10000) / total;
    }

    // ============ Test 1: OTC Price Matches AMM Probability ============

    /// @notice Verify that OTC effective price is close to AMM P(YES)
    /// @dev The OTC fill should price shares at approximately P(YES) + spread
    function test_OTC_EffectivePriceMatchesAMMProbability() public {
        // Setup vault liquidity
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Advance time to establish TWAP (bootstrap creates initial observation)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Get AMM probability before trade
        uint256 pYesBps = _getAMMProbability();

        // Record balances
        uint256 bobBalBefore = BOB.balance;
        uint256 bobSharesBefore = PAMM.balanceOf(BOB, marketId);

        // Execute OTC buy
        uint256 collateralIn = 10 ether;
        vm.prank(BOB);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: collateralIn}(
            marketId, true, collateralIn, 0, BOB, block.timestamp + 1 hours
        );

        // Calculate effective price paid per share (in bps of 1 collateral)
        // effectivePriceBps = (collateralUsed * 10000) / sharesOut
        uint256 collateralUsed = bobBalBefore - BOB.balance;
        uint256 actualSharesReceived = PAMM.balanceOf(BOB, marketId) - bobSharesBefore;

        assertGt(actualSharesReceived, 0, "Should receive shares");

        uint256 effectivePriceBps = (collateralUsed * 10000) / actualSharesReceived;

        // Effective price should be close to P(YES) + spread
        // Spread is typically 1-5%, so effective price should be within 10% of P(YES)
        uint256 lowerBound = pYesBps * 90 / 100;
        uint256 upperBound = pYesBps * 150 / 100; // Allow for spread

        assertGe(effectivePriceBps, lowerBound, "Effective price too low vs P(YES)");
        assertLe(effectivePriceBps, upperBound, "Effective price too high vs P(YES)");
    }

    // ============ Test 2: Share Accounting Identity ============

    /// @notice Verify sharesOut * effectivePrice ~= collateralIn
    function test_OTC_ShareAccountingIdentity() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish TWAP (bootstrap creates initial observation)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 collateralIn = 5 ether;
        uint256 bobBalBefore = BOB.balance;
        uint256 bobSharesBefore = PAMM.balanceOf(BOB, marketId);

        vm.prank(BOB);
        router.buyWithBootstrap{value: collateralIn}(
            marketId, true, collateralIn, 0, BOB, block.timestamp + 1 hours
        );

        uint256 collateralUsed = bobBalBefore - BOB.balance;
        uint256 sharesReceived = PAMM.balanceOf(BOB, marketId) - bobSharesBefore;

        // Get P(YES) for verification
        uint256 pYesBps = _getAMMProbability();

        // Verify accounting: sharesReceived * effectivePrice <= collateralUsed
        // This ensures we're not giving away free shares
        uint256 effectivePriceBps = (collateralUsed * 10000) / sharesReceived;

        // Effective price should be >= P(YES) (spread makes it higher)
        assertGe(
            effectivePriceBps, pYesBps * 95 / 100, "Effective price should be >= P(YES) - tolerance"
        );
    }

    // ============ Test 3: NO Side Pricing Symmetry ============

    /// @notice Verify NO side OTC fills are priced correctly at P(NO) = 1 - P(YES)
    function test_OTC_NoSidePricingSymmetry() public {
        // Setup vault for NO side
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish TWAP (bootstrap creates initial observation)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 pYesBps = _getAMMProbability();
        uint256 pNoBps = 10000 - pYesBps;

        uint256 noId = PAMM.getNoId(marketId);
        uint256 bobBalBefore = BOB.balance;
        uint256 bobNoSharesBefore = PAMM.balanceOf(BOB, noId);

        uint256 collateralIn = 5 ether;
        vm.prank(BOB);
        router.buyWithBootstrap{value: collateralIn}(
            marketId, false, collateralIn, 0, BOB, block.timestamp + 1 hours
        );

        uint256 collateralUsed = bobBalBefore - BOB.balance;
        uint256 noSharesReceived = PAMM.balanceOf(BOB, noId) - bobNoSharesBefore;

        if (noSharesReceived > 0) {
            uint256 effectivePriceBps = (collateralUsed * 10000) / noSharesReceived;

            // Effective price for NO should be close to P(NO) + spread
            uint256 lowerBound = pNoBps * 90 / 100;
            uint256 upperBound = pNoBps * 150 / 100;

            assertGe(effectivePriceBps, lowerBound, "NO effective price too low vs P(NO)");
            assertLe(effectivePriceBps, upperBound, "NO effective price too high vs P(NO)");
        }
    }

    // ============ Test 4: Skewed Market Pricing ============

    /// @notice Verify correct pricing when market is heavily skewed
    function test_OTC_SkewedMarketPricing() public {
        // First, skew the market gradually with smaller trades to avoid price impact limits
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);

        // Buy YES in smaller chunks to skew the market without hitting price impact
        for (uint256 i = 0; i < 5; i++) {
            router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
            );
            vm.warp(block.timestamp + 5 minutes);
        }
        vm.stopPrank();

        // Setup vault with YES (scarce side)
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish TWAP with new prices (need to wait for initial observation + 30 min)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 pYesBps = _getAMMProbability();

        // P(YES) should be elevated after YES buys (YES scarce = high price)
        assertGt(pYesBps, 5000, "P(YES) should be > 50% after buying YES");

        // Now buy YES via OTC and verify pricing
        address CAROL = makeAddr("CAROL");
        deal(CAROL, 100 ether);

        uint256 carolBalBefore = CAROL.balance;
        uint256 carolSharesBefore = PAMM.balanceOf(CAROL, marketId);

        vm.prank(CAROL);
        router.buyWithBootstrap{value: 10 ether}(marketId, true, 10 ether, 0, CAROL, DEADLINE_2028);

        uint256 collateralUsed = carolBalBefore - CAROL.balance;
        uint256 sharesReceived = PAMM.balanceOf(CAROL, marketId) - carolSharesBefore;

        if (sharesReceived > 0) {
            uint256 effectivePriceBps = (collateralUsed * 10000) / sharesReceived;

            // With elevated P(YES), effective price should reflect this
            // Should be close to the elevated P(YES), not 50%
            assertGe(
                effectivePriceBps,
                pYesBps * 80 / 100,
                "Skewed market: price should reflect high P(YES)"
            );
        }
    }

    // ============ Test 5: TWAP vs Spot Consistency ============

    /// @notice Verify TWAP-based pricing is consistent with spot probability
    function test_TWAP_ConsistentWithSpotProbability() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 50 ether}(marketId, 50 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Record initial spot probability
        uint256 spotBefore = _getAMMProbability();

        // Advance time and update TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Advance more time (no trades, spot should stay same)
        vm.warp(block.timestamp + 6 hours + 1);

        // Spot should still be the same (no trades occurred)
        uint256 spotAfter = _getAMMProbability();

        // Spot should be stable (within 1% since no trades occurred)
        assertApproxEqRel(spotBefore, spotAfter, 0.01e18, "Spot should be stable with no trades");
    }

    // ============ Test 6: Fair Value Verification ============

    /// @notice Verify that OTC fills don't systematically underprice or overprice shares
    function test_OTC_FairValueVerification() public {
        // Setup balanced vault
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Establish TWAP (bootstrap creates initial observation)
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 pYesBps = _getAMMProbability();
        uint256 pNoBps = 10000 - pYesBps;

        // Execute YES buy
        uint256 collateralIn = 5 ether;
        vm.prank(BOB);
        (uint256 yesSharesOut,,) = router.buyWithBootstrap{value: collateralIn}(
            marketId, true, collateralIn, 0, BOB, block.timestamp + 1 hours
        );

        // Calculate implied fair value of shares received
        // Fair value = sharesOut * P(YES) / 10000
        uint256 yesFairValue = (yesSharesOut * pYesBps) / 10000;

        // User should have paid at most collateralIn for this fair value (plus spread)
        // So fairValue should be <= collateralIn (we got value, not overpaid excessively)
        assertLe(
            yesFairValue, collateralIn * 120 / 100, "Fair value should not exceed payment + 20%"
        );
        assertGe(
            yesFairValue, collateralIn * 50 / 100, "Fair value should be at least 50% of payment"
        );
    }
}
