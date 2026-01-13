// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouter.sol";

interface IPAMMExtended is IPAMM {
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

/// @title MasterRouter Discoverability Tests
/// @notice Tests for orderbook view functions and user position queries
contract MasterRouterDiscoverabilityTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public ALICE = address(0x1);
    address public BOB = address(0x2);
    address public CAROL = address(0x3);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = new MasterRouter();

        // Create a fresh market for testing
        (marketId, noId) = pamm.createMarket(
            "Test Market", address(this), address(0), uint64(block.timestamp + 30 days), false
        );

        // Fund test accounts
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);

        // Approve router as operator for all users
        vm.prank(ALICE);
        pamm.setOperator(address(router), true);
        vm.prank(BOB);
        pamm.setOperator(address(router), true);
        vm.prank(CAROL);
        pamm.setOperator(address(router), true);
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBestAsk_empty() public view {
        (uint256 price, uint256 depth) = router.getBestAsk(marketId, true);
        assertEq(price, 0, "empty market should have 0 price");
        assertEq(depth, 0, "empty market should have 0 depth");
    }

    function test_getBestBid_empty() public view {
        (uint256 price, uint256 depth) = router.getBestBid(marketId, true);
        assertEq(price, 0, "empty market should have 0 price");
        assertEq(depth, 0, "empty market should have 0 depth");
    }

    function test_getSpread_empty() public view {
        (uint256 bidPrice, uint256 bidDepth, uint256 askPrice, uint256 askDepth) =
            router.getSpread(marketId, true);
        assertEq(bidPrice, 0);
        assertEq(bidDepth, 0);
        assertEq(askPrice, 0);
        assertEq(askDepth, 0);
    }

    function test_getActiveLevels_empty() public view {
        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = router.getActiveLevels(marketId, true, 10);

        assertEq(askPrices.length, 0);
        assertEq(askDepths.length, 0);
        assertEq(bidPrices.length, 0);
        assertEq(bidDepths.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ASK POOL DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBestAsk_singlePool() public {
        // Alice creates an ASK at 50%
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, ALICE);

        (uint256 price, uint256 depth) = router.getBestAsk(marketId, false); // NO side
        assertEq(price, 5000, "best ask should be 5000 bps");
        assertEq(depth, 1 ether, "depth should be 1 ether");
    }

    function test_getBestAsk_multiplePoolsReturnsLowest() public {
        // Alice creates ASK at 60%
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 6000, ALICE);

        // Bob creates ASK at 40%
        vm.prank(BOB);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 4000, BOB);

        // Carol creates ASK at 50%
        vm.prank(CAROL);
        router.mintAndPool{value: 1.5 ether}(marketId, 1.5 ether, true, 5000, CAROL);

        (uint256 price, uint256 depth) = router.getBestAsk(marketId, false);
        assertEq(price, 4000, "best ask should be lowest price (4000)");
        assertEq(depth, 2 ether, "depth should be Bob's 2 ether");
    }

    function test_getActiveLevels_multiplePools() public {
        // Create pools at different prices
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 3000, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, BOB);

        vm.prank(CAROL);
        router.mintAndPool{value: 1.5 ether}(marketId, 1.5 ether, true, 7000, CAROL);

        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = router.getActiveLevels(marketId, false, 10); // NO side ASKs

        assertEq(askPrices.length, 3, "should have 3 ask levels");
        assertEq(bidPrices.length, 0, "should have 0 bid levels");

        // Should be sorted ascending
        assertEq(askPrices[0], 3000);
        assertEq(askPrices[1], 5000);
        assertEq(askPrices[2], 7000);

        assertEq(askDepths[0], 1 ether);
        assertEq(askDepths[1], 2 ether);
        assertEq(askDepths[2], 1.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        BID POOL DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBestBid_singlePool() public {
        // Alice creates a BID at 45%
        vm.prank(ALICE);
        router.createBidPool{value: 1 ether}(marketId, 1 ether, true, 4500, ALICE);

        (uint256 price, uint256 depth) = router.getBestBid(marketId, true);
        assertEq(price, 4500, "best bid should be 4500 bps");
        assertEq(depth, 1 ether, "depth should be 1 ether collateral");
    }

    function test_getBestBid_multiplePoolsReturnsHighest() public {
        // Create bids at different prices
        vm.prank(ALICE);
        router.createBidPool{value: 1 ether}(marketId, 1 ether, true, 3000, ALICE);

        vm.prank(BOB);
        router.createBidPool{value: 2 ether}(marketId, 2 ether, true, 5500, BOB);

        vm.prank(CAROL);
        router.createBidPool{value: 1.5 ether}(marketId, 1.5 ether, true, 4000, CAROL);

        (uint256 price, uint256 depth) = router.getBestBid(marketId, true);
        assertEq(price, 5500, "best bid should be highest price (5500)");
        assertEq(depth, 2 ether, "depth should be Bob's 2 ether");
    }

    /*//////////////////////////////////////////////////////////////
                        SPREAD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getSpread_bothSides() public {
        // Create ASK at 55%
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5500, ALICE);

        // Create BID at 45%
        vm.prank(BOB);
        router.createBidPool{value: 2 ether}(marketId, 2 ether, false, 4500, BOB);

        (uint256 bidPrice, uint256 bidDepth, uint256 askPrice, uint256 askDepth) =
            router.getSpread(marketId, false); // NO side

        assertEq(bidPrice, 4500, "bid price");
        assertEq(bidDepth, 2 ether, "bid depth");
        assertEq(askPrice, 5500, "ask price");
        assertEq(askDepth, 1 ether, "ask depth");
    }

    /*//////////////////////////////////////////////////////////////
                        POOL DEPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getBestAsk_updatesAfterFill() public {
        // Create two ASK pools
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, BOB);

        // Verify best is 4000
        (uint256 price,) = router.getBestAsk(marketId, false);
        assertEq(price, 4000);

        // Fill the 4000 pool completely
        vm.prank(CAROL);
        router.fillFromPool{value: 0.4 ether}(marketId, false, 4000, 1 ether, CAROL);

        // Now best should be 5000
        (price,) = router.getBestAsk(marketId, false);
        assertEq(price, 5000, "after depletion, best should move to next level");
    }

    /*//////////////////////////////////////////////////////////////
                        USER POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getUserActivePositions_singlePosition() public {
        // Alice creates an ASK
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, ALICE);

        (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
            uint256[] memory bidPendingShares
        ) = router.getUserActivePositions(marketId, false, ALICE);

        assertEq(askPrices.length, 1);
        assertEq(askPrices[0], 5000);
        assertEq(askShares[0], 1 ether);
        assertEq(askPendingColl[0], 0); // No fills yet

        assertEq(bidPrices.length, 0);
    }

    function test_getUserActivePositions_multiplePositions() public {
        // Alice creates multiple positions
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, ALICE);

        vm.prank(ALICE);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 6000, ALICE);

        vm.prank(ALICE);
        router.createBidPool{value: 1.5 ether}(marketId, 1.5 ether, false, 3500, ALICE);

        (
            uint256[] memory askPrices,
            uint256[] memory askShares,,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
        ) = router.getUserActivePositions(marketId, false, ALICE);

        assertEq(askPrices.length, 2);
        assertEq(bidPrices.length, 1);

        assertEq(askPrices[0], 4000);
        assertEq(askShares[0], 1 ether);
        assertEq(askPrices[1], 6000);
        assertEq(askShares[1], 2 ether);

        assertEq(bidPrices[0], 3500);
        assertEq(bidCollateral[0], 1.5 ether);
    }

    function test_getUserActivePositions_afterPartialFill() public {
        // Alice creates ASK
        vm.prank(ALICE);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, ALICE);

        // Bob fills half
        vm.prank(BOB);
        router.fillFromPool{value: 0.5 ether}(marketId, false, 5000, 1 ether, BOB);

        (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,,,
        ) = router.getUserActivePositions(marketId, false, ALICE);

        assertEq(askPrices.length, 1);
        assertEq(askShares[0], 1 ether, "1 ether shares remaining");
        assertEq(askPendingColl[0], 0.5 ether, "0.5 ether pending from fill");
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH QUERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getUserPositionsBatch_basic() public {
        // Alice creates positions at specific prices
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, ALICE);

        vm.prank(ALICE);
        router.createBidPool{value: 2 ether}(marketId, 2 ether, false, 3000, ALICE);

        uint256[] memory prices = new uint256[](3);
        prices[0] = 3000;
        prices[1] = 4000;
        prices[2] = 5000; // No position here

        (
            uint256[] memory askShares,
            uint256[] memory askPending,
            uint256[] memory bidCollateral,
            uint256[] memory bidPending
        ) = router.getUserPositionsBatch(marketId, false, ALICE, prices);

        assertEq(askShares.length, 3);

        // Price 3000: bid position only
        assertEq(askShares[0], 0);
        assertEq(bidCollateral[0], 2 ether);

        // Price 4000: ask position only
        assertEq(askShares[1], 1 ether);
        assertEq(bidCollateral[1], 0);

        // Price 5000: no positions
        assertEq(askShares[2], 0);
        assertEq(bidCollateral[2], 0);
    }

    function test_getUserPositionsBatch_depletedPool() public {
        // Alice creates ASK
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, ALICE);

        // Bob fills completely
        vm.prank(BOB);
        router.fillFromPool{value: 0.5 ether}(marketId, false, 5000, 1 ether, BOB);

        // Pool is depleted, but Alice has pending collateral
        // getUserActivePositions won't find it (documented limitation)
        (uint256[] memory askPrices,,,,,) = router.getUserActivePositions(marketId, false, ALICE);
        assertEq(askPrices.length, 0, "depleted pool not found via bitmap");

        // But getUserPositionsBatch with known price will find it
        uint256[] memory prices = new uint256[](1);
        prices[0] = 5000;

        (uint256[] memory askShares, uint256[] memory askPending,,) =
            router.getUserPositionsBatch(marketId, false, ALICE, prices);

        assertEq(askShares[0], 0, "no shares left");
        assertEq(askPending[0], 0.5 ether, "pending collateral from fill");
    }

    /*//////////////////////////////////////////////////////////////
                        DEPTH QUERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getPoolDepths_batch() public {
        // Create pools at specific prices
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 3000, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, BOB);

        uint256[] memory prices = new uint256[](4);
        prices[0] = 2000; // empty
        prices[1] = 3000; // 1 ether
        prices[2] = 4000; // empty
        prices[3] = 5000; // 2 ether

        uint256[] memory depths = router.getPoolDepths(marketId, false, prices);

        assertEq(depths[0], 0);
        assertEq(depths[1], 1 ether);
        assertEq(depths[2], 0);
        assertEq(depths[3], 2 ether);
    }

    function test_getOrderbook_combined() public {
        // Create ASK
        vm.prank(ALICE);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5500, ALICE);

        // Create BID
        vm.prank(BOB);
        router.createBidPool{value: 2 ether}(marketId, 2 ether, false, 4500, BOB);

        uint256[] memory prices = new uint256[](2);
        prices[0] = 4500;
        prices[1] = 5500;

        (uint256[] memory askDepths, uint256[] memory bidDepths) =
            router.getOrderbook(marketId, false, prices);

        assertEq(askDepths[0], 0, "no ask at 4500");
        assertEq(askDepths[1], 1 ether, "ask at 5500");
        assertEq(bidDepths[0], 2 ether, "bid at 4500");
        assertEq(bidDepths[1], 0, "no bid at 5500");
    }

    /*//////////////////////////////////////////////////////////////
                        MAX LEVELS CAP TEST
    //////////////////////////////////////////////////////////////*/

    function test_getActiveLevels_cappedAt50() public view {
        // Just verify the cap works (don't create 50+ pools)
        (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        ) = router.getActiveLevels(marketId, true, 1000); // Request 1000

        // Should return empty but not revert
        assertEq(askPrices.length, 0);
        assertEq(askDepths.length, 0);
        assertEq(bidPrices.length, 0);
        assertEq(bidDepths.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        QUOTE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_quoteBuyFromPools_empty() public view {
        (uint256 sharesOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteBuyFromPools(marketId, true, 1 ether);
        assertEq(sharesOut, 0);
        assertEq(avgPrice, 0);
        assertEq(levelsFilled, 0);
    }

    function test_quoteBuyFromPools_singlePool() public {
        // Create ASK at 60% (selling NO for 60 cents)
        vm.prank(ALICE);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 6000, ALICE);

        // Quote buying 3 ether worth
        (uint256 sharesOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteBuyFromPools(marketId, false, 3 ether);

        // At 60%, 3 ether should buy 5 ether worth of shares
        assertEq(sharesOut, 5 ether, "should get 5 shares for 3 collateral at 60%");
        assertEq(avgPrice, 6000, "avg price should be 60%");
        assertEq(levelsFilled, 1, "should fill 1 level");
    }

    function test_quoteBuyFromPools_multipleLevels() public {
        // Create ASKs at different prices
        vm.prank(ALICE);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 4000, ALICE); // 2 shares at 40%

        vm.prank(BOB);
        router.mintAndPool{value: 3 ether}(marketId, 3 ether, true, 5000, BOB); // 3 shares at 50%

        // Quote buying enough to sweep both levels
        // Level 1: 2 shares * 0.4 = 0.8 ether
        // Level 2: 3 shares * 0.5 = 1.5 ether
        // Total: 2.3 ether for 5 shares
        (uint256 sharesOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteBuyFromPools(marketId, false, 2.3 ether);

        assertEq(sharesOut, 5 ether, "should fill both pools");
        assertEq(levelsFilled, 2, "should touch 2 levels");
        // Avg price = 2.3 / 5 = 0.46 = 4600 bps
        assertEq(avgPrice, 4600, "weighted avg should be 46%");
    }

    function test_quoteBuyFromPools_partialFill() public {
        // Create ASK at 50%
        vm.prank(ALICE);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, ALICE);

        // Quote buying only 2.5 ether (half the pool)
        (uint256 sharesOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteBuyFromPools(marketId, false, 2.5 ether);

        assertEq(sharesOut, 5 ether, "should get 5 shares for 2.5 collateral at 50%");
        assertEq(avgPrice, 5000);
        assertEq(levelsFilled, 1);
    }

    function test_quoteSellToPools_empty() public view {
        (uint256 collateralOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteSellToPools(marketId, true, 1 ether);
        assertEq(collateralOut, 0);
        assertEq(avgPrice, 0);
        assertEq(levelsFilled, 0);
    }

    function test_quoteSellToPools_singlePool() public {
        // Create BID at 40% with 4 ether (can buy 10 shares)
        vm.prank(ALICE);
        router.createBidPool{value: 4 ether}(marketId, 4 ether, true, 4000, ALICE);

        // Quote selling 5 shares
        (uint256 collateralOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteSellToPools(marketId, true, 5 ether);

        assertEq(collateralOut, 2 ether, "5 shares at 40% = 2 ether");
        assertEq(avgPrice, 4000);
        assertEq(levelsFilled, 1);
    }

    function test_quoteSellToPools_multipleLevels() public {
        // Create BIDs at different prices (higher price first in execution)
        vm.prank(ALICE);
        router.createBidPool{value: 2 ether}(marketId, 2 ether, true, 5000, ALICE); // 4 shares capacity

        vm.prank(BOB);
        router.createBidPool{value: 1.5 ether}(marketId, 1.5 ether, true, 3000, BOB); // 5 shares capacity

        // Sell 7 shares (fills 50% pool completely + 3 from 30% pool)
        (uint256 collateralOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteSellToPools(marketId, true, 7 ether);

        // 4 shares at 50% = 2 ether
        // 3 shares at 30% = 0.9 ether
        // Total = 2.9 ether
        assertEq(collateralOut, 2.9 ether, "should receive 2.9 ether");
        assertEq(levelsFilled, 2, "should touch 2 levels");
        // Avg = 2.9 / 7 ≈ 0.4142... = ~4142 bps
        assertApproxEqAbs(avgPrice, 4142, 1, "weighted avg ~41.4%");
    }

    function test_quoteSellToPools_zeroInput() public view {
        (uint256 collateralOut, uint256 avgPrice, uint256 levelsFilled) =
            router.quoteSellToPools(marketId, true, 0);
        assertEq(collateralOut, 0);
        assertEq(avgPrice, 0);
        assertEq(levelsFilled, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET INFO TEST
    //////////////////////////////////////////////////////////////*/

    function test_getMarketInfo() public view {
        (address collateral, uint64 closeTime, bool tradingOpen, bool resolved) =
            router.getMarketInfo(marketId);

        assertEq(collateral, address(0), "should be ETH market");
        assertGt(closeTime, block.timestamp, "close should be in future");
        assertTrue(tradingOpen, "trading should be open");
        assertFalse(resolved, "market not resolved");
    }
}
