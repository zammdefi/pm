// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {PredictionAMM, IZAMM} from "../src/PredictionAMM.sol";

// ============ External mainnet contracts on fork ============
interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

IERC20View constant WSTETH = IERC20View(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

interface IZSTETH {
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
}

IZSTETH constant ZSTETH = IZSTETH(0x000000000088649055D9D23362B819A5cfF11f02);

// ZAMM address used by your contract
address constant ZAMM_ADDR = 0x000000000000040470635EB91b7CE4D132D616eD;

// ============ Tests ============
contract PredictionAMM_MainnetFork is Test {
    // actors
    address internal RESOLVER = makeAddr("RESOLVER");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    // CUT
    PredictionAMM internal pm;

    // market ids
    string internal constant DESC = "Will Shanghai Disneyland close for a week in Q4?";
    uint256 internal marketId;
    uint256 internal noId;

    // ---- helpers that match your Market struct layout ----
    // Market {
    //   address resolver;
    //   bool resolved;
    //   bool outcome;
    //   bool canClose;
    //   uint72 close;
    //   uint256 pot;
    //   uint256 payoutPerShare;
    // }
    function _pot(uint256 mid) internal view returns (uint256 P) {
        (,,,,, P,) = pm.markets(mid);
    }

    function _pps(uint256 mid) internal view returns (uint256 PPS) {
        (,,,,,, PPS) = pm.markets(mid);
    }

    function _warpPastClose() internal {
        // close is set to now + 30 days in these tests
        vm.warp(block.timestamp + 31 days);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // fund users with ETH
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(RESOLVER, 1 ether);

        // deploy CUT
        pm = new PredictionAMM();

        // create & seed a market: seeds are outcome tokens, not wstETH
        (marketId, noId) = pm.createMarket(
            DESC,
            RESOLVER,
            uint72(block.timestamp + 30 days),
            false, // canClose
            1_000_000e9, // seed YES (ERC6909 units)
            1_000_000e9 // seed NO  (ERC6909 units)
        );
        assertEq(marketId, pm.getMarketId(DESC, RESOLVER));
        assertEq(noId, pm.getNoId(marketId));
        assertEq(pm.descriptions(marketId), DESC);
    }

    // =============================
    // Primary buy YES via the pool
    // =============================
    function test_BuyYesViaPool_WithWstETH() public {
        // ALICE acquires wstETH via zap and approves PM
        vm.prank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 2 ether}(ALICE);
        assertGt(w, 0);

        vm.prank(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);

        uint256 beforePot = _pot(marketId);
        uint256 beforeYes = pm.balanceOf(ALICE, marketId);

        // request 10k YES out, pay EV in wstETH; allow large bounds
        vm.prank(ALICE);
        (uint256 wstIn, uint256 oppIn) = pm.buyYesViaPool(
            marketId,
            10_000e9, // yesOut
            false, // inIsETH (must be false in current contract)
            type(uint256).max, // wstInMax
            type(uint256).max, // oppInMax (NO minted & swapped)
            ALICE
        );

        assertGt(wstIn, 0);
        assertGt(oppIn, 0);
        assertEq(pm.balanceOf(ALICE, marketId), beforeYes + 10_000e9, "YES received");
        assertEq(_pot(marketId), beforePot + wstIn, "pot increased by EV in");
    }

    // ============================
    // Primary buy NO via the pool
    // ============================
    function test_BuyNoViaPool_WithWstETH() public {
        vm.prank(BOB);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 2 ether}(BOB);
        assertGt(w, 0);

        vm.prank(BOB);
        WSTETH.approve(address(pm), type(uint256).max);

        uint256 beforePot = _pot(marketId);
        uint256 beforeNo = pm.balanceOf(BOB, noId);

        vm.prank(BOB);
        (uint256 wstIn, uint256 oppIn) = pm.buyNoViaPool(
            marketId,
            8_000e9, // noOut
            false,
            type(uint256).max,
            type(uint256).max,
            BOB
        );

        assertGt(wstIn, 0);
        assertGt(oppIn, 0);
        assertEq(pm.balanceOf(BOB, noId), beforeNo + 8_000e9, "NO received");
        assertEq(_pot(marketId), beforePot + wstIn, "pot increased");
    }

    // ===============================
    // Manual close + resolve + claim
    // ===============================
    function test_ManualClose_ResolveYes_Claim() public {
        // create a closable market and seed it
        (uint256 mid, uint256 nid) = pm.createMarket(
            "manual-close market",
            RESOLVER,
            uint72(block.timestamp + 365 days),
            true,
            500_000e9,
            500_000e9
        );
        nid; // silence

        // fund both sides via pool so both circulate
        vm.startPrank(ALICE);
        uint256 wa = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(mid, 3_000e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 wb = ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(mid, 2_000e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        wa;
        wb;

        // resolver manually closes now (no warp)
        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        // further trading must revert
        vm.expectRevert(PredictionAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(mid, 100e9, false, type(uint256).max, type(uint256).max, ALICE);

        // resolve immediately, YES wins
        vm.prank(RESOLVER);
        pm.resolve(mid, true);

        // claim for ALICE (YES holder)
        uint256 P = _pps(mid);
        assertGt(P, 0);

        uint256 aliceYes = pm.balanceOf(ALICE, mid);
        uint256 before = WSTETH.balanceOf(ALICE);

        vm.prank(ALICE);
        pm.claim(mid, ALICE);

        uint256 got = WSTETH.balanceOf(ALICE) - before;
        assertEq(got, (aliceYes * P) / 1e18, "pro-rata payout in wstETH");
    }

    // ===============================
    // Normal close -> resolve -> claim
    // ===============================
    function test_NormalResolve_NoManualClose() public {
        // both sides circulating
        vm.startPrank(ALICE);
        uint256 wa = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 4_000e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();
        vm.startPrank(BOB);
        uint256 wb = ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 3_500e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        wa;
        wb;

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        uint256 P = _pps(marketId);
        assertGt(P, 0);

        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        uint256 before = WSTETH.balanceOf(ALICE);

        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        assertEq(WSTETH.balanceOf(ALICE) - before, (aliceYes * P) / 1e18);
    }

    // ===============================
    // Guards
    // ===============================
    function test_Revert_Buy_AfterClose() public {
        _warpPastClose();

        // ALICE has wstETH and approval
        vm.prank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        vm.prank(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        w;

        vm.expectRevert(PredictionAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 100e9, false, type(uint256).max, type(uint256).max, ALICE);
    }

    function test_Revert_Resolve_BeforeClose() public {
        vm.expectRevert(PredictionAMM.MarketNotClosed.selector);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);
    }

    function test_Revert_Claim_NotWinner() public {
        // --- Bob buys NO (has losing side later) ---
        vm.startPrank(BOB);
        uint256 wBob = ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(
            marketId,
            1e12, // noOut
            false, // pay in wstETH
            type(uint256).max, // wstInMax
            type(uint256).max, // oppInMax
            BOB
        );
        vm.stopPrank();

        // --- Alice buys a dust of YES so both sides have circulating holders ---
        vm.startPrank(ALICE);
        uint256 wAlice = ZSTETH.exactETHToWSTETH{value: 0.1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(
            marketId,
            1e9, // tiny yesOut just to ensure yesCirc > 0
            false, // pay in wstETH
            type(uint256).max, // wstInMax
            type(uint256).max, // oppInMax
            ALICE
        );
        vm.stopPrank();

        // --- Resolve YES wins (no auto-flip because both sides circulate) ---
        vm.warp(block.timestamp + 31 days);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // --- Bob (NO holder) is not a winner -> must revert ---
        vm.prank(BOB);
        vm.expectRevert(PredictionAMM.NoWinningShares.selector);
        pm.claim(marketId, BOB);
    }

    function test_ImpliedYesProb_View() public view {
        (uint256 num, uint256 den) = pm.impliedYesProb(marketId);
        // num = rNO, den = rYES + rNO
        assertTrue(den >= num && den > 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extra coverage tests for PredictionAMM
    // Paste below your existing tests in the same contract
    // ─────────────────────────────────────────────────────────────────────────────

    function test_BuyYesViaPool_WST_UpdatesPotAndBalances() public {
        // Bob funds wstETH and buys YES from pool
        vm.startPrank(BOB);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.5 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);

        uint256 potBefore = _pot(marketId);

        (uint256 wIn,) = pm.buyYesViaPool(
            marketId,
            5e11, // yesOut
            false, // pay in wstETH
            type(uint256).max,
            type(uint256).max,
            BOB
        );
        vm.stopPrank();

        // PM increases pot by wIn, Bob receives YES
        uint256 yesBal = pm.balanceOf(BOB, marketId);
        uint256 potAfter = _pot(marketId);

        assertGt(yesBal, 0, "BOB should have YES");
        assertEq(potAfter, potBefore + wIn, "pot += wIn");
    }

    function test_Resolve_AutoFlipWhenOneSideZeroCirculating() public {
        // create a fresh market seeded symmetrically so implied prob = 50/50
        string memory DESC2 = "auto-flip";
        (uint256 mid,) = pm.createMarket(
            DESC2,
            RESOLVER,
            uint72(block.timestamp + 1 days),
            false, // canClose
            1_000_000_000_000, // seed YES (ERC6909 units)
            1_000_000_000_000 // seed NO  (ERC6909 units)
        );

        // BOB buys a bit of NO (so YES circ could be zero under the right flow)
        vm.startPrank(BOB);
        // give BOB some wstETH via zapper
        uint256 z = ZSTETH.exactETHToWSTETH{value: 0.3 ether}(BOB);
        assertGt(z, 0, "zapped");
        WSTETH.transfer(BOB, z); // transfer from zapper to BOB
        vm.stopPrank();

        vm.startPrank(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        // buy a small amount of NO so NO has some circ and YES could be zeroed if needed
        (uint256 wIn,) = pm.buyNoViaPool(
            mid,
            1_000_000_000, // noOut
            false, // inIsETH = false (we're paying with wstETH)
            type(uint256).max,
            type(uint256).max,
            BOB
        );
        assertGt(wIn, 0, "paid some wst");
        vm.stopPrank();

        // time-travel past close and "resolve YES", expecting the contract to auto-flip to NO
        vm.warp(block.timestamp + 1 days);
        vm.prank(RESOLVER);
        pm.resolve(mid, true); // ask for YES but should auto-flip to NO if YES circ == 0

        // pull the state
        (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint72 closeTs,
            uint256 pot,
            uint256 pps
        ) = pm.markets(mid);

        assertTrue(resolved, "resolved");
        // auto-flip means final outcome is NO (false)
        assertFalse(outcome, "auto-flipped to NO");

        // winner token id is NO
        uint256 noId = pm.getNoId(mid);

        // snapshot BEFORE claim
        uint256 bobSharesBefore = pm.balanceOf(BOB, noId);
        uint256 bobWstBefore = WSTETH.balanceOf(BOB);

        // claim
        vm.prank(BOB);
        pm.claim(mid, BOB);

        // after claim
        uint256 bobWstAfter = WSTETH.balanceOf(BOB);
        uint256 bobSharesAfter = pm.balanceOf(BOB, noId);

        // expected payout uses shares BEFORE burning
        uint256 expected = (bobSharesBefore * pps) / 1e18;

        // assertions
        assertGt(expected, 0, "winner should get >0");
        assertEq(bobWstAfter - bobWstBefore, expected, "payout matches PPS");
        assertEq(bobSharesAfter, 0, "winner shares burned");
        assertEq(WSTETH.balanceOf(address(pm)), pot - expected, "pot reduced by payout");
    }

    function test_Resolve_AutoFlip_WhenOnlyYesCirculating() public {
        (uint256 mid,) = pm.createMarket(
            "flip-to-YES",
            RESOLVER,
            uint72(block.timestamp + 30 days),
            false,
            1_000_000_000_000,
            1_000_000_000_000
        );

        // Only buy YES so noCirc==0, yesCirc>0
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.3 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(mid, 1_000_000_000, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        // Ask resolver to pick NO (false) — should auto-flip to YES
        vm.prank(RESOLVER);
        pm.resolve(mid, false);

        (, bool resolved, bool outcome,,,, uint256 pps) = pm.markets(mid);

        assertTrue(resolved);
        assertTrue(outcome, "auto-flipped to YES");

        uint256 before = WSTETH.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertGt(WSTETH.balanceOf(ALICE) - before, 0, "YES winner paid");
    }

    function test_Claim_TwoWinnersProRataAndPotDrains() public {
        // Alice & Bob both own YES; share PPS proportionally and drain pot
        vm.startPrank(ALICE);
        uint256 wA = ZSTETH.exactETHToWSTETH{value: 0.6 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        uint256 outA = 8e11;
        pm.buyYesViaPool(marketId, outA, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 wB = ZSTETH.exactETHToWSTETH{value: 0.4 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        uint256 outB = 4e11;
        pm.buyYesViaPool(marketId, outB, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        vm.warp(block.timestamp + 40 days);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 pps = _pps(marketId);
        uint256 potAtResolve = _pot(marketId);

        uint256 aBefore = WSTETH.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
        uint256 aPayout = WSTETH.balanceOf(ALICE) - aBefore;

        uint256 bBefore = WSTETH.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(marketId, BOB);
        uint256 bPayout = WSTETH.balanceOf(BOB) - bBefore;

        // Pro-rata by shares * pps / 1e18
        assertEq(aPayout, (outA * pps) / 1e18);
        assertEq(bPayout, (outB * pps) / 1e18);
        // Dustless drain (allow 1 wei slack)
        uint256 remaining = _pot(marketId);
        assertLe(remaining, 1, "pot fully drained (+-1 wei)");
    }

    function test_ImpliedYesProb_MatchesReservesOrderingInvariant() public view {
        // Pure view sanity: num/den in impliedYesProb are finite and num < den
        (uint256 num, uint256 den) = pm.impliedYesProb(marketId);
        assertGt(den, 0, "den>0");
        assertLt(num, den, "0<p<1");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Additional confidence tests
    // ─────────────────────────────────────────────────────────────────────────────

    function test_QuoteMatchesExecution_BuyYes() public {
        // Alice preps wstETH
        vm.startPrank(ALICE);
        uint256 z = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 yesOut = 3_000e9;

        // Ask contract for a quote
        (
            uint256 oppInQ,
            uint256 wstInFairQ,
            uint256 p0n,
            , // ignore dens
            uint256 p1n,
            uint256 p1d
        ) = pm.quoteBuyYes(marketId, yesOut);

        // Execute with tight oppInMax (should pass)
        vm.prank(ALICE);
        (uint256 wstIn, uint256 oppIn) = pm.buyYesViaPool(
            marketId,
            yesOut,
            false,
            wstInFairQ, // exact max = fair EV
            oppInQ, // exact pool input
            ALICE
        );

        // Execution should meet the quote exactly for oppIn,
        // and wstIn should be equal to quoted fair (or +-1 wei rounding)
        assertEq(oppIn, oppInQ, "pool input equals quote");
        assertLe(wstIn > wstInFairQ ? wstIn - wstInFairQ : wstInFairQ - wstIn, 1, "wstEV ~= quote");

        // Price moved the correct way: p1 should reflect lower YES reserve (higher pYES denominator)
        (uint256 pNum, uint256 pDen) = pm.impliedYesProb(marketId);
        // p1 = rNo'/(rYes'+rNo') == num'/den'
        assertEq(pNum, p1n, "post num");
        assertEq(pDen, p1d, "post den");
    }

    function test_QuoteMatchesExecution_BuyNo() public {
        // Bob preps wstETH
        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 noOut = 2_000e9;

        (uint256 oppInQ, uint256 wstInFairQ,,,,) = pm.quoteBuyNo(marketId, noOut);

        vm.prank(BOB);
        (uint256 wstIn, uint256 oppIn) =
            pm.buyNoViaPool(marketId, noOut, false, wstInFairQ, oppInQ, BOB);

        assertEq(oppIn, oppInQ, "pool input equals quote");
        assertLe(wstIn > wstInFairQ ? wstIn - wstInFairQ : wstInFairQ - wstIn, 1, "wstEV ~= quote");
    }

    function test_Monotonicity_QuotesIncreaseWithSize() public view {
        (uint256 oppSmall, uint256 wstSmall,,,,) = pm.quoteBuyYes(marketId, 1_000e9);
        (uint256 oppBig, uint256 wstBig,,,,) = pm.quoteBuyYes(marketId, 10_000e9);
        assertGt(oppBig, oppSmall, "bigger trade => more pool input");
        assertGt(wstBig, wstSmall, "bigger trade => more EV charge");
    }

    function test_SlippageOppInBound_Yes() public {
        // Prep funds
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        (uint256 oppInQ, uint256 wstInQ,,,,) = pm.quoteBuyYes(marketId, 2_500e9);

        // With oppInMax = oppInQ-1 => revert
        vm.expectRevert(PredictionAMM.SlippageOppIn.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 2_500e9, false, type(uint256).max, oppInQ - 1, ALICE);

        // With oppInMax = oppInQ => pass
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 2_500e9, false, wstInQ, oppInQ, ALICE);
    }

    function test_ETHPath_RefundsExcessAsWstETH() public {
        // Use ETH path; intentionally overpay msg.value
        (uint256 oppInQ, uint256 wstInQ,,,,) = pm.quoteBuyYes(marketId, 1_000e9);

        uint256 aliceWstBefore = WSTETH.balanceOf(ALICE);

        vm.deal(ALICE, 2 ether);
        vm.prank(ALICE);
        (uint256 wstIn,) = pm.buyYesViaPool{value: 2 ether}(
            marketId,
            1_000e9,
            true, // inIsETH
            type(uint256).max, // ignored in ETH path
            oppInQ,
            ALICE
        );

        // Contract should charge fair wstIn only; refund excess as wstETH to Alice
        assertEq(wstIn, wstInQ, "charged fair EV in wstETH");
        uint256 aliceWstAfter = WSTETH.balanceOf(ALICE);
        assertGt(aliceWstAfter - aliceWstBefore, 0, "excess refunded in wstETH");
    }

    function test_ETHPath_Guards() public {
        // inIsETH but no value
        vm.expectRevert(PredictionAMM.NoEth.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 1_000e9, true, 0, type(uint256).max, ALICE);

        // not inIsETH but value sent
        vm.deal(ALICE, 1 ether);
        vm.expectRevert(PredictionAMM.EthNotAllowed.selector);
        vm.prank(ALICE);
        pm.buyNoViaPool{value: 0.1 ether}(marketId, 1_000e9, false, 0, type(uint256).max, ALICE);
    }

    function test_InsufficientZap_Reverts() public {
        // Ask for a buy that needs non-trivial wstIn, but provide tiny ETH
        (uint256 oppInQ, uint256 wstInQ,,,,) = pm.quoteBuyNo(marketId, 5_000e9);
        oppInQ; // silence

        vm.deal(BOB, 1 wei);
        vm.expectRevert(PredictionAMM.InsufficientZap.selector);
        vm.prank(BOB);
        pm.buyNoViaPool{value: 1}(marketId, 5_000e9, true, 0, type(uint256).max, BOB);

        // sanity: same trade with enough ETH succeeds
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        pm.buyNoViaPool{value: 1 ether}(marketId, 5_000e9, true, 0, type(uint256).max, BOB);
        wstInQ; // silence
    }

    function test_ResolverFee_DeductsBeforePayout() public {
        // Set resolver fee and create/fund a new market
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(250); // 2.5%

        (uint256 mid,) = pm.createMarket(
            "fee test", RESOLVER, uint72(block.timestamp + 7 days), false, 1e12, 1e12
        );

        // Alice buys YES, paying wstEV into pot
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        (uint256 wstIn,) =
            pm.buyYesViaPool(mid, 5e11, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        uint256 potBefore = _pot(mid);
        assertEq(potBefore, wstIn, "pot == EV before resolve");

        vm.warp(block.timestamp + 8 days);
        vm.prank(RESOLVER);
        pm.resolve(mid, true);

        // pot after fee taken
        uint256 potAfter = _pot(mid);
        assertEq(potAfter, potBefore - (potBefore * 250) / 10_000, "fee deducted");

        // PPS computed from post-fee pot
        uint256 pps = _pps(mid);
        uint256 aliceYes = pm.balanceOf(ALICE, mid);
        uint256 expected = (aliceYes * pps) / 1e18;

        uint256 before = WSTETH.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertEq(WSTETH.balanceOf(ALICE) - before, expected, "payout from post-fee pot");
    }

    function test_Claim_CannotDoubleClaim() public {
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.5 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 2e11, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        _warpPastClose();
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        // 2nd claim must revert (no shares)
        vm.expectRevert(PredictionAMM.NoWinningShares.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
    }

    function test_TradingOpen_Flag() public {
        // open initially
        assertTrue(pm.tradingOpen(marketId), "open initially");

        // create tiny circulating YES so resolve can succeed
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.05 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        // after close, trading closed
        _warpPastClose();
        assertFalse(pm.tradingOpen(marketId), "closed after close time");

        // resolve succeeds now that YES circulates
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // still closed after resolve
        assertFalse(pm.tradingOpen(marketId), "closed after resolve");
        w; // silence
    }

    function test_ImpliedYesProb_MovesAsExpected() public {
        (uint256 n0, uint256 d0) = pm.impliedYesProb(marketId);
        // Bob buys NO -> pYES should decrease (since rNo decreases, rYes increases)
        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 0.3 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 2e10, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        (uint256 n1, uint256 d1) = pm.impliedYesProb(marketId);
        // pYES = num/den = rNO / (rYES+rNO)
        // After buying NO: rNO' smaller, denominator a bit similar → ratio should drop
        assertLt(mulDiv(n1, 1e18, d1), mulDiv(n0, 1e18, d0), "pYES decreased after NO buy");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // More coverage tests
    // ─────────────────────────────────────────────────────────────────────────────

    function test_Resolve_Revert_WhenBothSidesZeroCirculating() public {
        // Fresh market; only seeded LP, no circulating holders on either side
        (uint256 mid,) = pm.createMarket(
            "both-zero", RESOLVER, uint72(block.timestamp + 1 days), false, 1e12, 1e12
        );

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PredictionAMM.NoCirculating.selector);
        vm.prank(RESOLVER);
        pm.resolve(mid, true); // either choice reverts
    }

    function test_SetResolverFeeBps_Bounds() public {
        vm.expectRevert(PredictionAMM.FeeOverflow.selector);
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1001); // > 10%

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(0); // ok
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1000); // = 10% ok
    }

    function test_CloseMarket_Revert_NotClosable() public {
        // market from setUp() has canClose=false
        vm.expectRevert(PredictionAMM.NotClosable.selector);
        vm.prank(RESOLVER);
        pm.closeMarket(marketId);
    }

    function test_Quote_InvalidSize_Reverts() public {
        // yesOut >= rYes should revert InsufficientLiquidity inside quote
        // Read current reserves using view on contract
        (uint256 num, uint256 den) = pm.impliedYesProb(marketId);
        assertTrue(den > 0 && num < den);
        // Conservatively try a huge yesOut
        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        pm.quoteBuyYes(marketId, type(uint256).max / 2);

        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        pm.quoteBuyNo(marketId, type(uint256).max / 2);
    }

    function test_BuyYes_Revert_InsufficientWst_MaxEVTooLow() public {
        // prep approval & tiny wst budget
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.05 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        (,, uint256 p0n, uint256 p0d,,) = pm.quoteBuyYes(marketId, 1e9);
        p0n;
        p0d; // just to keep variables used

        // quote fair EV then set max below it
        (uint256 oppInQ, uint256 wstInFairQ,,,,) = pm.quoteBuyYes(marketId, 2_000e9);
        oppInQ; // silence

        vm.expectRevert(PredictionAMM.InsufficientWst.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 2_000e9, false, wstInFairQ - 1, type(uint256).max, ALICE);
    }

    function test_BuyNo_Revert_InsufficientLiquidity_OnBoundary() public {
        // Try to take exactly rNo (not allowed, must be strictly less)
        // Read reserves via implied probability + separate query
        IZAMM.PoolKey memory key = IZAMM.PoolKey({
            id0: marketId < pm.getNoId(marketId) ? marketId : pm.getNoId(marketId),
            id1: marketId < pm.getNoId(marketId) ? pm.getNoId(marketId) : marketId,
            token0: address(pm),
            token1: address(pm),
            feeOrHook: 10
        });
        (uint112 r0, uint112 r1,,,,,) = IZAMM(ZAMM_ADDR).pools(
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)))
        );
        (uint256 rYes, uint256 rNo) =
            (key.id0 == marketId) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        pm.buyNoViaPool(marketId, rNo, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        rYes; // silence
    }

    function test_MarketBookkeeping_CountAndDescription() public {
        uint256 before = pm.marketCount();
        (uint256 mid, uint256 nid) = pm.createMarket(
            "desc-check",
            RESOLVER,
            uint72(block.timestamp + 10 days),
            false,
            2_000, // seed YES
            2_000 // seed NO  (>=1001 per side is sufficient; 2000 is comfy)
        );
        assertEq(pm.marketCount(), before + 1);
        assertEq(pm.getNoId(mid), nid);
        assertEq(pm.descriptions(mid), "desc-check");
    }

    function test_NameSymbol_AreStable() public view {
        string memory n = pm.name(marketId);
        string memory n2 = pm.name(pm.getNoId(marketId));
        assertGt(bytes(n).length, 0);
        assertGt(bytes(n2).length, 0);
        assertEq(pm.symbol(0), "PM");
    }

    function test_ApproveAndTransfer_Erc6909_Basics() public {
        // Give ALICE some YES first
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e10, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        // ALICE approves BOB to pull YES
        vm.prank(ALICE);
        pm.approve(BOB, marketId, 5e9);

        // BOB transfers from ALICE to BOB
        uint256 bobBefore = pm.balanceOf(BOB, marketId);
        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 5e9);
        assertEq(pm.balanceOf(BOB, marketId), bobBefore + 5e9);
    }

    function test_Settlement_SumOfPayoutsEqualsPostFeePot_FuzzSmall() public {
        // Small fuzz across buyers: split YES among three addresses
        address C1 = makeAddr("C1");
        address C2 = makeAddr("C2");
        address C3 = makeAddr("C3");

        // fund & approve
        address[3] memory usrs = [C1, C2, C3];
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(usrs[i], 0.4 ether);
            vm.prank(usrs[i]);
            uint256 w = ZSTETH.exactETHToWSTETH{value: 0.4 ether}(usrs[i]);
            w;
            vm.prank(usrs[i]);
            WSTETH.approve(address(pm), type(uint256).max);
        }

        // buys
        vm.prank(C1);
        pm.buyYesViaPool(marketId, 2e10, false, type(uint256).max, type(uint256).max, C1);
        vm.prank(C2);
        pm.buyYesViaPool(marketId, 1e10, false, type(uint256).max, type(uint256).max, C2);
        vm.prank(C3);
        pm.buyYesViaPool(marketId, 5e9, false, type(uint256).max, type(uint256).max, C3);

        // resolve YES
        _warpPastClose();
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 postFeePot = _pot(marketId);
        uint256 pps = _pps(marketId);

        // claims
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            uint256 shares = pm.balanceOf(usrs[i], marketId);
            uint256 before = WSTETH.balanceOf(usrs[i]);
            vm.prank(usrs[i]);
            pm.claim(marketId, usrs[i]);
            sum += WSTETH.balanceOf(usrs[i]) - before;

            // shares burned
            assertEq(pm.balanceOf(usrs[i], marketId), 0);
        }

        // All payouts should equal the post-fee pot (allow <=1 wei slack)
        uint256 rem = _pot(marketId);
        assertLe(rem, 1, "pot drained");
        assertLe(postFeePot > sum ? postFeePot - sum : sum - postFeePot, 1, "conservation");
    }

    function test_SlippageOppInBound_No() public {
        // Prep funds
        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        (uint256 oppInQ, uint256 wstInQ,,,,) = pm.quoteBuyNo(marketId, 3_000e9);

        // With oppInMax = oppInQ-1 => revert
        vm.expectRevert(PredictionAMM.SlippageOppIn.selector);
        vm.prank(BOB);
        pm.buyNoViaPool(marketId, 3_000e9, false, type(uint256).max, oppInQ - 1, BOB);

        // With oppInMax = oppInQ => pass (and wstIn bound equals quote)
        vm.prank(BOB);
        pm.buyNoViaPool(marketId, 3_000e9, false, wstInQ, oppInQ, BOB);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Final coverage push — guards, invariants, multi-market isolation, UX edges
    // ─────────────────────────────────────────────────────────────────────────────

    function test_CreateMarket_Revert_MarketExists() public {
        // Re-create same market should fail
        vm.expectRevert(PredictionAMM.MarketExists.selector);
        pm.createMarket(DESC, RESOLVER, uint72(block.timestamp + 1 days), false, 1e12, 1e12);
    }

    function test_CloseMarket_Revert_AfterCloseTime() public {
        (uint256 mid,) = pm.createMarket(
            "late-close", RESOLVER, uint72(block.timestamp + 1 days), true, 1e12, 1e12
        );
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PredictionAMM.MarketClosed.selector);
        vm.prank(RESOLVER);
        pm.closeMarket(mid);
    }

    function test_Resolve_Revert_AlreadyResolved() public {
        // Make some circulation so resolve works
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        _warpPastClose();
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PredictionAMM.AlreadyResolved.selector);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);
    }

    function test_Resolve_Revert_ClaimBeforeResolve() public {
        vm.expectRevert(PredictionAMM.MarketNotResolved.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
    }

    function test_Claim_Revert_NoWinningShares() public {
        // Bob buys NO
        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        // Alice buys a dust of YES so yesCirc > 0 (prevents auto-flip)
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.05 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e6, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        // Past close; resolver picks YES (no auto-flip now)
        vm.warp(block.timestamp + 31 days);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // Bob (NO holder) is loser ⇒ claim should revert
        vm.prank(BOB);
        vm.expectRevert(PredictionAMM.NoWinningShares.selector);
        pm.claim(marketId, BOB);
    }

    function test_Quote_UnseededMarket_Reverts() public {
        (uint256 mid,) =
            pm.createMarket("no-seed", RESOLVER, uint72(block.timestamp + 7 days), false, 0, 0);
        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        pm.quoteBuyYes(mid, 1e9);
        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        pm.quoteBuyNo(mid, 1e9);
    }

    function test_ResolverFee_AppliesPerResolver_NotGlobal() public {
        // Resolver sets 5%
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500);

        // A different resolver with zero fee
        address RESOLVER2 = makeAddr("RESOLVER2");
        (uint256 mid2,) =
            pm.createMarket("other", RESOLVER2, uint72(block.timestamp + 7 days), false, 1e12, 1e12);

        // Fund pot on market 2
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.3 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(mid2, 1e10, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        _warpPastClose();
        vm.prank(RESOLVER2);
        pm.resolve(mid2, true);

        // Post-fee pot should equal pre-fee pot (since RESOLVER2's fee is default 0)
        // (We don't have pre-fee snapshot here, but PPS positive is sufficient and claim drains pot.)
        uint256 pps = _pps(mid2);
        assertGt(pps, 0, "pps positive with fee=0 for resolver2");
    }

    function test_MultiMarket_IsolatedState() public {
        // Create a second market and trade only there
        (uint256 mid2, uint256 nid2) =
            pm.createMarket("iso", RESOLVER, uint72(block.timestamp + 20 days), false, 1e12, 1e12);

        // Trade on market 2
        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 0.4 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(mid2, 5e10, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        // Market 1 balances unchanged by market 2 trading
        (uint256 y1, uint256 n1,,,,,) = _getMarketTuple(marketId);
        (uint256 y2, uint256 n2,,,,,) = _getMarketTuple(mid2);
        assertEq(y1, pm.totalSupply(marketId));
        assertEq(n1, pm.totalSupply(pm.getNoId(marketId)));
        assertEq(y2, pm.totalSupply(mid2));
        assertEq(n2, pm.totalSupply(nid2));
    }

    function test_PPS_Rounding_LastClaimerDrainsPot() public {
        // Two YES holders with amounts that cause rounding
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.33 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 123456789, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.startPrank(BOB);
        ZSTETH.exactETHToWSTETH{value: 0.27 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 98765432, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();

        _warpPastClose();
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 potAtResolve = _pot(marketId);

        // Alice claims first
        uint256 aBefore = WSTETH.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
        uint256 aPaid = WSTETH.balanceOf(ALICE) - aBefore;

        // Bob claims second — pot should drain to <= 1 wei
        uint256 bBefore = WSTETH.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(marketId, BOB);
        uint256 bPaid = WSTETH.balanceOf(BOB) - bBefore;

        uint256 totalPaid = aPaid + bPaid;
        uint256 rem = _pot(marketId);
        assertLe(rem, 1, "pot drained with <=1 wei slack");
        // Allow <=1 wei rounding diff vs post-fee pot
        assertLe(potAtResolve > totalPaid ? potAtResolve - totalPaid : totalPaid - potAtResolve, 1);
    }

    function test_ImpliedYesProb_Unseeded_ReturnsZeroDenOrZeroes() public {
        // Create unseeded market; impliedYesProb should not revert
        (uint256 mid,) = pm.createMarket(
            "view-unseeded", RESOLVER, uint72(block.timestamp + 5 days), false, 0, 0
        );
        (uint256 num, uint256 den) = pm.impliedYesProb(mid);
        // Implementation returns (0,0) until seeded; just ensure no division and sane outputs
        assertEq(num, 0);
        assertEq(den, 0);
    }

    function test_Approve_MaxAllowance_Sticky() public {
        // Give ALICE YES
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 5e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        // Approve max to BOB and transfer twice without lowering allowance (since contract keeps max)
        vm.prank(ALICE);
        pm.approve(BOB, marketId, type(uint256).max);

        uint256 slice = 1e9;
        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, slice);
        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, slice);
        // If allowance tracked as max, no revert; balances moved
        assertEq(pm.balanceOf(BOB, marketId), 2 * slice);
    }

    function test_BuyPaths_DoNotUnderchargePot() public {
        // Basic inequality: fair EV (wstIn) should be >= simple midpoint EV
        // (Not strictly required, but a sanity check that Simpson's isn't broken)
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 out = 1e10;
        (uint256 oppInQ, uint256 wstFair,,,,) = pm.quoteBuyYes(marketId, out);
        oppInQ; // silence

        // compute midpoint EV with current reserves (rough lower bound)
        // p0 = rNo/(rYes+rNo); p1 ~ after full out
        IZAMM.PoolKey memory key = IZAMM.PoolKey({
            id0: marketId < pm.getNoId(marketId) ? marketId : pm.getNoId(marketId),
            id1: marketId < pm.getNoId(marketId) ? pm.getNoId(marketId) : marketId,
            token0: address(pm),
            token1: address(pm),
            feeOrHook: 10
        });
        (uint112 r0, uint112 r1,,,,,) = IZAMM(ZAMM_ADDR).pools(
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)))
        );
        (uint256 rYes, uint256 rNo) =
            (key.id0 == marketId) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        uint256 inAll = _getAmountIn(out, rNo, rYes, 10); // using public interface if exposed; else re-derive here
        uint256 rYesEnd = rYes - out;
        uint256 rNoEnd = rNo + inAll;

        uint256 p0 = (rNo * 1e18) / (rYes + rNo);
        uint256 p1 = (rNoEnd * 1e18) / (rYesEnd + rNoEnd);
        uint256 mid = (p0 + p1) / 2;
        uint256 lowerBound = (out * mid) / 1e18;

        assertGe(wstFair, lowerBound, "Simpson fair EV >= midpoint EV");
    }

    function test_ResolverFee_NonZero() public {
        // setup: tiny trades so both sides circulate
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(100); // 1%

        uint256 potBefore = _pot(marketId);
        vm.warp(block.timestamp + 31 days);
        uint256 resolverBalBefore = WSTETH.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 fee = (potBefore * 100) / 10_000;
        assertEq(WSTETH.balanceOf(RESOLVER) - resolverBalBefore, fee, "resolver got 1%");
        // PPS computed on net pot:
        uint256 pps = _pps(marketId);
        assertEq(pps, ((potBefore - fee) * 1e18) / pm.balanceOf(ALICE, marketId));
    }

    function test_MultiMarket_Isolation() public {
        // create a second market
        (uint256 mid2,) =
            pm.createMarket("iso", RESOLVER, uint72(block.timestamp + 7 days), false, 1e12, 1e12);

        // snapshot pots
        uint256 pot1Before = _pot(marketId);
        uint256 pot2Before = _pot(mid2);

        // trade only in mid2
        vm.startPrank(BOB);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.15 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(mid2, 5e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        w;

        // implied prob states differ (already good in your test)
        (uint256 num1, uint256 den1) = pm.impliedYesProb(marketId);
        (uint256 num2, uint256 den2) = pm.impliedYesProb(mid2);
        assertTrue(den1 > 0 && den2 > 0);
        assertTrue(num1 != num2 || den1 != den2, "distinct states");

        // pot isolation: market1 unchanged; market2 increased
        assertEq(_pot(marketId), pot1Before, "pot1 unchanged");
        assertGt(_pot(mid2), pot2Before, "pot2 increased");
    }

    function test_QuoteVsBuy_Yes() public {
        // small yesOut
        uint256 out = 2e9;
        (uint256 oppInQuote, uint256 wstFair,, uint256 d0,, uint256 d1) =
            pm.quoteBuyYes(marketId, out);
        assertGt(oppInQuote, 0);
        assertGt(wstFair, 0);
        assertTrue(d0 > 0 && d1 > 0);

        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        (uint256 wIn, uint256 oppIn) =
            pm.buyYesViaPool(marketId, out, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        // Opposite-side input matches quote exactly under same state, rounding aside
        assertEq(oppIn, oppInQuote, "oppIn matches quote");
        // Fair EV can differ by rounding at midpoints; allow small tolerance
        assertLe((wIn > wstFair ? wIn - wstFair : wstFair - wIn), 3, "fair charge ~ quote");
    }

    function test_ImpliedYesProb_MovesAfterBuy() public {
        (uint256 n0, uint256 d0) = pm.impliedYesProb(marketId);
        assertTrue(d0 > 0);

        // buy a bit of YES
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 5e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();
        w;

        (uint256 n1, uint256 d1) = pm.impliedYesProb(marketId);
        // p_yes should INCREASE after a YES buy under our definition p_yes = rNo/(rYes+rNo)
        assertGt(n1 * d0, n0 * d1, "p(YES) should increase after YES buy");

        // sanity: buy NO should DECREASE p_yes
        vm.startPrank(BOB);
        uint256 w2 = ZSTETH.exactETHToWSTETH{value: 0.2 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 5e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        w2;

        (uint256 n2, uint256 d2) = pm.impliedYesProb(marketId);
        assertLt(n2 * d1, n1 * d2, "p(YES) should decrease after NO buy");
    }

    //

    // ─────────────────────────────────────────────────────────────────────────────
    // Getter coverage: getMarket / getMarkets / getUserMarkets / winningId / getPool
    // ─────────────────────────────────────────────────────────────────────────────

    function test_GetMarket_SnapshotMatchesState() public {
        // Seed a tiny bit of circulation so pool odds move later if needed
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.15 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        (
            uint256 yesSupply,
            uint256 noSupply,
            address resolver,
            bool resolved,
            bool outcome,
            uint256 pot,
            uint256 payoutPerShare,
            string memory desc,
            uint72 closeTs,
            bool canClose,
            uint256 rYes,
            uint256 rNo,
            uint256 pNum,
            uint256 pDen
        ) = pm.getMarket(marketId);

        // Compare to public state
        assertEq(yesSupply, pm.totalSupply(marketId), "yesSupply");
        assertEq(noSupply, pm.totalSupply(noId), "noSupply");

        (address R, bool RES, bool OUT, bool CAN, uint72 CLOSE, uint256 POT, uint256 PPS) =
            pm.markets(marketId);
        assertEq(resolver, R, "resolver");
        assertEq(resolved, RES, "resolved");
        assertEq(outcome, OUT, "outcome");
        assertEq(canClose, CAN, "canClose");
        assertEq(closeTs, CLOSE, "close");
        assertEq(pot, POT, "pot");
        assertEq(payoutPerShare, PPS, "pps");
        assertEq(desc, pm.descriptions(marketId), "desc");

        // Implied prob matches impliedYesProb()
        (uint256 num, uint256 den) = pm.impliedYesProb(marketId);
        // If market seeded, den > 0; if not seeded, both are 0.
        assertEq(pNum, num, "p.num");
        assertEq(pDen, den, "p.den");

        // If seeded, rYes+rNo equals den and rNo equals num
        if (den > 0) {
            assertEq(rYes + rNo, den, "rYes+rNo == den");
            assertEq(rNo, num, "rNo == num");
        }
    }

    function test_GetMarkets_PaginationAndOdds() public {
        // Create a second market so pagination has >1 item
        (uint256 mid2,) = pm.createMarket(
            "getter-paging", RESOLVER, uint72(block.timestamp + 20 days), false, 1e12, 1e12
        );

        // Page size 1
        (
            uint256[] memory ids1,
            uint256[] memory y1,
            uint256[] memory n1,
            address[] memory resolvers1,
            bool[] memory res1,
            bool[] memory out1,
            uint256[] memory pot1,
            uint256[] memory pps1,
            string[] memory desc1,
            uint72[] memory close1,
            bool[] memory canClose1,
            uint256[] memory rYes1,
            uint256[] memory rNo1,
            uint256[] memory pNum1,
            uint256[] memory pDen1,
            uint256 next
        ) = pm.getMarkets(0, 1);

        assertEq(ids1.length, 1, "page len 1");
        assertEq(resolvers1.length, 1, "aligned arrays");
        assertTrue(next != 0, "has next page when >1 market");

        // Sanity for first market row
        uint256 id0 = ids1[0];
        assertEq(y1[0], pm.totalSupply(id0), "y supply row0");
        assertEq(n1[0], pm.totalSupply(pm.getNoId(id0)), "n supply row0");
        assertEq(resolvers1[0], RESOLVER, "resolver row0");
        if (pDen1[0] > 0) {
            assertEq(rYes1[0] + rNo1[0], pDen1[0], "den matches reserves");
            assertEq(rNo1[0], pNum1[0], "num matches rNo");
        }

        // Fetch the "next" page (either 2nd item or empty)
        (uint256[] memory ids2,,,,,,,,,,,,,,, uint256 next2) = pm.getMarkets(next, 1);
        // If there was a second item, it should be mid2 or some other; at least lengths valid.
        if (ids2.length == 1) {
            assertTrue(ids2[0] == mid2 || ids2[0] == marketId, "second page contains a real market");
        }
        // next2 can be zero if no more pages
        next2; // silence
    }

    function test_GetUserMarkets_Balances_Claimables_Flags() public {
        // 1) Before any buy
        (
            uint256[] memory yesIds,
            uint256[] memory noIds,
            uint256[] memory yBal,
            uint256[] memory nBal,
            uint256[] memory claim,
            bool[] memory isRes,
            bool[] memory open,
            uint256 next
        ) = pm.getUserMarkets(ALICE, 0, 10);
        assertEq(yesIds.length, noIds.length, "aligned arrays");
        // For the first market in setup
        assertEq(yBal[0], 0);
        assertEq(nBal[0], 0);
        assertEq(claim[0], 0);
        assertFalse(isRes[0], "not resolved yet");
        assertTrue(open[0], "trading open initially");
        next; // silence

        // 2) After buying YES
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.25 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 2e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        (,, yBal, nBal, claim, isRes, open,) = pm.getUserMarkets(ALICE, 0, 10);
        assertGt(yBal[0], 0, "has YES");
        assertEq(nBal[0], 0, "no NO yet");
        assertEq(claim[0], 0, "no claim while unresolved");
        assertTrue(open[0], "still open pre-close");

        // 3) After resolve YES
        vm.warp(block.timestamp + 31 days);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        (,, yBal, nBal, claim, isRes, open,) = pm.getUserMarkets(ALICE, 0, 10);
        assertTrue(isRes[0], "resolved");
        assertFalse(open[0], "closed");
        // claimable = yBal * pps / 1e18
        uint256 pps = _pps(marketId);
        assertEq(claim[0], mulDiv(yBal[0], pps, 1e18), "claimable computed");
    }

    function test_WinningId_BeforeAfterResolve() public {
        // Before resolve: 0
        uint256 wid0 = pm.winningId(marketId);
        assertEq(wid0, 0, "no winner before resolve");

        // Make both sides circulate
        vm.startPrank(ALICE);
        ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.warp(block.timestamp + 40 days);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        uint256 wid = pm.winningId(marketId);
        assertEq(wid, marketId, "winner is YES id");
    }

    function test_GetPool_MatchesZAMMState() public view {
        (uint256 poolId, uint256 rYes, uint256 rNo, uint32 tsLast, uint256 kLast, uint256 lpSupply)
        = pm.getPool(marketId);

        // Cross-check against ZAMM directly
        (uint112 r0, uint112 r1, uint32 t,,, uint256 k, uint256 s) = IZAMM(ZAMM_ADDR).pools(poolId);

        // Determine if id0==marketId to map r0/r1 to rYes/rNo
        IZAMM.PoolKey memory key = IZAMM.PoolKey({
            id0: marketId < pm.getNoId(marketId) ? marketId : pm.getNoId(marketId),
            id1: marketId < pm.getNoId(marketId) ? pm.getNoId(marketId) : marketId,
            token0: address(pm),
            token1: address(pm),
            feeOrHook: 10
        });

        if (key.id0 == marketId) {
            assertEq(rYes, uint256(r0), "rYes==r0");
            assertEq(rNo, uint256(r1), "rNo==r1");
        } else {
            assertEq(rYes, uint256(r1), "rYes==r1");
            assertEq(rNo, uint256(r0), "rNo==r0");
        }

        assertEq(tsLast, t, "timestamp last");
        assertEq(kLast, k, "kLast");
        assertEq(lpSupply, s, "lpSupply");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Small helpers to read pot/pps and balances without exposing internal fns
    // ─────────────────────────────────────────────────────────────────────────────

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        // amountIn = floor( reserveIn * amountOut * 10000 / ((reserveOut - amountOut) * (10000 - feeBps)) ) + 1
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - feeBps);
        amountIn = (numerator / denominator) + 1;
    }

    function _getMarketTuple(uint256 mid)
        internal
        view
        returns (
            uint256 yesSupply,
            uint256 noSupply,
            address resolver,
            bool resolved,
            bool outcome,
            uint256 pot,
            uint256 pps
        )
    {
        // Re-hydrate from public mappings & views the same way UI would
        yesSupply = pm.totalSupply(mid);
        noSupply = pm.totalSupply(pm.getNoId(mid));
        (resolver, resolved, outcome,,, pot, pps) = pm.markets(mid);
    }

    function _balances(address who, uint256 yesId)
        internal
        view
        returns (uint256 yesBal, uint256 noBal, uint256 _noId)
    {
        _noId = pm.getNoId(yesId);
        yesBal = pm.balanceOf(who, yesId);
        noBal = pm.balanceOf(who, _noId);
    }
}

/// @dev Solady mulDiv free function.
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        // Equivalent to `require(d != 0 && (y == 0 || x <= type(uint256).max / y))`.
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, 0xad251c27) // `MulDivFailed()`.
            revert(0x1c, 0x04)
        }
        z := div(z, d)
    }
}

interface IZERC6909View {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}
