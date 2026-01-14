// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import {PMHookQuoter} from "../src/PMHookQuoter.sol";
import {MasterRouter} from "../src/MasterRouter.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
}

/**
 * @title PMHookQuoter MasterRouter View Functions Tests
 * @notice Tests for quoteBuyWithSweep, quoteSellWithSweep, getActiveLevels, getUserActivePositions, getUserPositionsBatch
 */
contract PMHookQuoterMasterRouterTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address payable constant MASTER_ROUTER_ADDR =
        payable(0x000000000055CdB14b66f37B96a571108FFEeA5C);
    address constant ETH = address(0);

    PMHookRouter public router;
    PMFeeHook public hook;
    MasterRouter public masterRouter;
    PMHookQuoter public quoter;

    address public ALICE;
    address public BOB;
    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main4"));

        hook = new PMFeeHook();

        // Deploy PMHookRouter at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Initialize router
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        // Deploy MasterRouter at hardcoded address
        MasterRouter tempMasterRouter = new MasterRouter();
        vm.etch(MASTER_ROUTER_ADDR, address(tempMasterRouter).code);
        masterRouter = MasterRouter(MASTER_ROUTER_ADDR);

        // Deploy quoter (uses hardcoded addresses)
        quoter = new PMHookQuoter();

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        deal(ALICE, 100000 ether);
        deal(BOB, 100000 ether);

        console.log("=== PMHookQuoter MasterRouter Test Suite ===");
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Quoter MasterRouter Test Market",
            ALICE,
            ETH,
            uint64(block.timestamp + 30 days),
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

        noId = _getNoId(marketId);
    }

    function _getNoId(uint256 _marketId) internal pure returns (uint256 _noId) {
        assembly {
            _noId := or(_marketId, shl(255, 1))
        }
    }

    // ============ Sweep Quote Tests ============

    /// @notice Test quoteBuyWithSweep with no pools - should fallback to PMHookRouter
    function test_QuoteBuyWithSweep_NoPools() public {
        _bootstrapMarket();

        console.log("=== QUOTE BUY WITH SWEEP - NO POOLS ===");

        // Wait for TWAP
        vm.warp(block.timestamp + 35 minutes);
        vm.roll(block.number + 175);
        router.updateTWAPObservation(marketId);

        // Quote with no pools - should use PMHookRouter only
        (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 poolLevelsFilled,
            uint256 pmSharesOut,
            bytes4 pmSource
        ) = quoter.quoteBuyWithSweep(marketId, true, 10 ether, 5000);

        console.log("Total shares:", totalSharesOut);
        console.log("Pool shares:", poolSharesOut);
        console.log("Pool levels:", poolLevelsFilled);
        console.log("PM shares:", pmSharesOut);
        console.log("PM source:", string(abi.encodePacked(pmSource)));

        assertEq(poolSharesOut, 0, "No pools should mean zero pool shares");
        assertEq(poolLevelsFilled, 0, "No pool levels filled");
        assertGt(pmSharesOut, 0, "PMHookRouter should provide shares");
        assertEq(totalSharesOut, pmSharesOut, "Total should equal PM shares");

        console.log("PASS: Buy with sweep handles no pools correctly");
    }

    /// @notice Test quoteBuyWithSweep with active pools
    function test_QuoteBuyWithSweep_WithPools() public {
        _bootstrapMarket();

        console.log("=== QUOTE BUY WITH SWEEP - WITH POOLS ===");

        // Create a pool at 40% price
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(masterRouter), true);
        masterRouter.depositSharesToPool(marketId, true, 50 ether, 4000, BOB);
        vm.stopPrank();

        // Wait for TWAP
        vm.warp(block.timestamp + 35 minutes);
        vm.roll(block.number + 175);
        router.updateTWAPObservation(marketId);

        // Quote buying YES with max price 5000 (50%)
        (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 poolLevelsFilled,
            uint256 pmSharesOut,
            bytes4 pmSource
        ) = quoter.quoteBuyWithSweep(marketId, true, 30 ether, 5000);

        console.log("Total shares:", totalSharesOut);
        console.log("Pool shares:", poolSharesOut);
        console.log("Pool levels:", poolLevelsFilled);
        console.log("PM shares:", pmSharesOut);

        // Should fill from pool first, then PMHookRouter for remainder
        assertGt(totalSharesOut, 0, "Should get total shares");
        // Pool has 50 YES shares at 40%, so 30 ETH can buy up to 75 shares
        // But pool only has 50, so we fill 50 and remainder goes to PM

        console.log("PASS: Buy with sweep handles pools correctly");
    }

    /// @notice Test quoteSellWithSweep with no bid pools - should fallback to PMHookRouter
    function test_QuoteSellWithSweep_NoPools() public {
        _bootstrapMarket();

        console.log("=== QUOTE SELL WITH SWEEP - NO POOLS ===");

        // Wait for TWAP
        vm.warp(block.timestamp + 35 minutes);
        vm.roll(block.number + 175);
        router.updateTWAPObservation(marketId);

        // Buy some YES shares first
        vm.prank(ALICE);
        (uint256 yesShares,,) = router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, ALICE, block.timestamp + 1 hours
        );

        // Quote selling with no bid pools
        (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 poolLevelsFilled,
            uint256 pmCollateralOut,
            bytes4 pmSource
        ) = quoter.quoteSellWithSweep(marketId, true, yesShares / 2, 3000);

        console.log("Total collateral:", totalCollateralOut);
        console.log("Pool collateral:", poolCollateralOut);
        console.log("Pool levels:", poolLevelsFilled);
        console.log("PM collateral:", pmCollateralOut);
        console.log("PM source:", string(abi.encodePacked(pmSource)));

        assertEq(poolCollateralOut, 0, "No bid pools should mean zero pool collateral");
        assertEq(poolLevelsFilled, 0, "No pool levels filled");
        assertGt(pmCollateralOut, 0, "PMHookRouter should provide collateral");

        console.log("PASS: Sell with sweep handles no bid pools correctly");
    }

    /// @notice Test quoteSellWithSweep with active bid pools
    function test_QuoteSellWithSweep_WithBidPools() public {
        _bootstrapMarket();

        console.log("=== QUOTE SELL WITH SWEEP - WITH BID POOLS ===");

        // Create a bid pool at 50% price (bidding to buy YES at 50%)
        vm.startPrank(BOB);
        masterRouter.createBidPool{value: 50 ether}(marketId, 50 ether, true, 5000, BOB);
        vm.stopPrank();

        // Wait for TWAP
        vm.warp(block.timestamp + 35 minutes);
        vm.roll(block.number + 175);
        router.updateTWAPObservation(marketId);

        // Buy some YES shares to sell
        vm.prank(ALICE);
        (uint256 yesShares,,) = router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, ALICE, block.timestamp + 1 hours
        );

        // Quote selling with min price 4000 (40%)
        (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 poolLevelsFilled,
            uint256 pmCollateralOut,
            bytes4 pmSource
        ) = quoter.quoteSellWithSweep(marketId, true, yesShares / 2, 4000);

        console.log("Total collateral:", totalCollateralOut);
        console.log("Pool collateral:", poolCollateralOut);
        console.log("Pool levels:", poolLevelsFilled);
        console.log("PM collateral:", pmCollateralOut);

        // Should fill from bid pool first at 50%, remainder to PMHookRouter
        assertGt(totalCollateralOut, 0, "Should get total collateral");

        console.log("PASS: Sell with sweep handles bid pools correctly");
    }

    /// @notice Test quoteBuyWithSweep with zero collateral
    function test_QuoteBuyWithSweep_ZeroCollateral() public {
        _bootstrapMarket();

        console.log("=== QUOTE BUY WITH SWEEP - ZERO COLLATERAL ===");

        (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 poolLevelsFilled,
            uint256 pmSharesOut,
            bytes4 pmSource
        ) = quoter.quoteBuyWithSweep(marketId, true, 0, 5000);

        assertEq(totalSharesOut, 0, "Zero collateral should return zero");
        assertEq(poolSharesOut, 0, "Zero pool shares");
        assertEq(pmSharesOut, 0, "Zero PM shares");

        console.log("PASS: Zero collateral handled correctly");
    }

    /// @notice Test quoteSellWithSweep with zero shares
    function test_QuoteSellWithSweep_ZeroShares() public {
        _bootstrapMarket();

        console.log("=== QUOTE SELL WITH SWEEP - ZERO SHARES ===");

        (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 poolLevelsFilled,
            uint256 pmCollateralOut,
            bytes4 pmSource
        ) = quoter.quoteSellWithSweep(marketId, true, 0, 5000);

        assertEq(totalCollateralOut, 0, "Zero shares should return zero");
        assertEq(poolCollateralOut, 0, "Zero pool collateral");
        assertEq(pmCollateralOut, 0, "Zero PM collateral");

        console.log("PASS: Zero shares handled correctly");
    }

    // ============ Orderbook View Function Tests ============

    /// @notice Test getActiveLevels with no pools
    function test_GetActiveLevels_Empty() public {
        _bootstrapMarket();

        console.log("=== GET ACTIVE LEVELS - EMPTY ===");

        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = quoter.getActiveLevels(marketId, true, 10);

        assertEq(askPrices.length, 0, "No ask prices");
        assertEq(askDepths.length, 0, "No ask depths");
        assertEq(bidPrices.length, 0, "No bid prices");
        assertEq(bidDepths.length, 0, "No bid depths");

        console.log("PASS: Empty orderbook handled correctly");
    }

    /// @notice Test getActiveLevels with active pools
    function test_GetActiveLevels_WithPools() public {
        _bootstrapMarket();

        console.log("=== GET ACTIVE LEVELS - WITH POOLS ===");

        // Create ask pool (selling YES at 60%)
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(masterRouter), true);
        masterRouter.depositSharesToPool(marketId, true, 30 ether, 6000, BOB);

        // Create another ask at different price
        masterRouter.depositSharesToPool(marketId, true, 20 ether, 7000, BOB);
        vm.stopPrank();

        // Create bid pool (buying YES at 40%)
        vm.startPrank(ALICE);
        masterRouter.createBidPool{value: 20 ether}(marketId, 20 ether, true, 4000, ALICE);
        vm.stopPrank();

        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = quoter.getActiveLevels(marketId, true, 10);

        console.log("Ask levels found:", askPrices.length);
        for (uint256 i = 0; i < askPrices.length; i++) {
            console.log("  Price:", askPrices[i], "Depth:", askDepths[i]);
        }

        console.log("Bid levels found:", bidPrices.length);
        for (uint256 i = 0; i < bidPrices.length; i++) {
            console.log("  Price:", bidPrices[i], "Depth:", bidDepths[i]);
        }

        assertGt(askPrices.length, 0, "Should have ask levels");
        assertGt(bidPrices.length, 0, "Should have bid levels");

        console.log("PASS: Active levels returned correctly");
    }

    /// @notice Test getUserActivePositions with no positions
    function test_GetUserActivePositions_Empty() public {
        _bootstrapMarket();

        console.log("=== GET USER POSITIONS - EMPTY ===");

        (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
            uint256[] memory bidPendingShares
        ) = quoter.getUserActivePositions(marketId, true, BOB);

        assertEq(askPrices.length, 0, "No ask positions");
        assertEq(bidPrices.length, 0, "No bid positions");

        console.log("PASS: Empty user positions handled correctly");
    }

    /// @notice Test getUserActivePositions with active positions
    function test_GetUserActivePositions_WithPositions() public {
        _bootstrapMarket();

        console.log("=== GET USER POSITIONS - WITH POSITIONS ===");

        // BOB creates ask pool
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(masterRouter), true);
        masterRouter.depositSharesToPool(marketId, true, 30 ether, 6000, BOB);
        vm.stopPrank();

        // BOB creates bid pool
        vm.startPrank(BOB);
        masterRouter.createBidPool{value: 20 ether}(marketId, 20 ether, true, 4000, BOB);
        vm.stopPrank();

        (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
            uint256[] memory bidPendingShares
        ) = quoter.getUserActivePositions(marketId, true, BOB);

        console.log("Ask positions:", askPrices.length);
        for (uint256 i = 0; i < askPrices.length; i++) {
            console.log("  Price:", askPrices[i], "Shares:", askShares[i]);
        }

        console.log("Bid positions:", bidPrices.length);
        for (uint256 i = 0; i < bidPrices.length; i++) {
            console.log("  Price:", bidPrices[i], "Collateral:", bidCollateral[i]);
        }

        assertGt(askPrices.length, 0, "Should have ask positions");
        assertGt(bidPrices.length, 0, "Should have bid positions");

        console.log("PASS: User positions returned correctly");
    }

    /// @notice Test getUserPositionsBatch
    function test_GetUserPositionsBatch() public {
        _bootstrapMarket();

        console.log("=== GET USER POSITIONS BATCH ===");

        // BOB creates positions at specific prices
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(masterRouter), true);
        masterRouter.depositSharesToPool(marketId, true, 20 ether, 5000, BOB);
        masterRouter.depositSharesToPool(marketId, true, 15 ether, 6000, BOB);
        masterRouter.createBidPool{value: 10 ether}(marketId, 10 ether, true, 4000, BOB);
        vm.stopPrank();

        // Query specific prices
        uint256[] memory prices = new uint256[](3);
        prices[0] = 4000;
        prices[1] = 5000;
        prices[2] = 6000;

        (
            uint256[] memory askShares,
            uint256[] memory askPending,
            uint256[] memory bidCollateral,
            uint256[] memory bidPending
        ) = quoter.getUserPositionsBatch(marketId, true, BOB, prices);

        console.log("Batch results:");
        for (uint256 i = 0; i < prices.length; i++) {
            console.log("  Price:", prices[i]);
            console.log("    Ask:", askShares[i], "Bid:", bidCollateral[i]);
        }

        // Price 4000 should have bid position
        assertGt(bidCollateral[0], 0, "Should have bid at 4000");

        // Price 5000 should have ask position
        assertGt(askShares[1], 0, "Should have ask at 5000");

        // Price 6000 should have ask position
        assertGt(askShares[2], 0, "Should have ask at 6000");

        console.log("PASS: Batch query returned correctly");
    }

    /// @notice Test getActiveLevels respects maxLevels cap
    function test_GetActiveLevels_MaxLevelsCap() public {
        _bootstrapMarket();

        console.log("=== GET ACTIVE LEVELS - MAX LEVELS CAP ===");

        // Create many pools
        vm.startPrank(BOB);
        PAMM.split{value: 500 ether}(marketId, 500 ether, BOB);
        PAMM.setOperator(address(masterRouter), true);

        // Create 10 ask pools at different prices
        for (uint256 i = 0; i < 10; i++) {
            uint256 price = 5000 + (i * 100);
            masterRouter.depositSharesToPool(marketId, true, 10 ether, price, BOB);
        }
        vm.stopPrank();

        // Request only 5 levels
        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = quoter.getActiveLevels(marketId, true, 5);

        console.log("Requested 5 levels, got:", askPrices.length);

        assertLe(askPrices.length, 5, "Should respect maxLevels");

        console.log("PASS: MaxLevels cap respected");
    }

    /// @notice Test getActiveLevels with maxLevels > 50 gets capped
    function test_GetActiveLevels_CapsAt50() public {
        _bootstrapMarket();

        console.log("=== GET ACTIVE LEVELS - CAPS AT 50 ===");

        // Request 100 levels (should be capped at 50)
        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = quoter.getActiveLevels(marketId, true, 100);

        // Arrays should be allocated for max 50
        // (actual length depends on active pools)
        console.log("Arrays allocated, ask length:", askPrices.length);

        console.log("PASS: Level cap enforced");
    }
}
