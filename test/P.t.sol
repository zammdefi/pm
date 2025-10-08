// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {PredictionAMM} from "../src/PredictionAMM.sol";

/* ──────────────────────────────────────────────────────────
   External mainnet contracts on fork (addresses you use)
   ────────────────────────────────────────────────────────── */

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IZSTETH {
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
}

IERC20Like constant WSTETH = IERC20Like(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
IZSTETH constant ZSTETH = IZSTETH(0x000000000088649055D9D23362B819A5cfF11f02);
address constant ZAMM_ADDR = 0x000000000000040470635EB91b7CE4D132D616eD;

/* ──────────────────────────────────────────────────────────
   Tests
   ────────────────────────────────────────────────────────── */

contract PredictionAMM_MainnetFork is Test {
    // actors
    address internal RESOLVER = makeAddr("RESOLVER");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    // CUT
    PredictionAMM internal pm;

    // market ids
    string internal constant DESC = "Will Shanghai Disneyland close for a week in Q4?";
    uint256 internal marketId; // YES id
    uint256 internal noId; // NO id

    /* ───────── helpers that match your contract ───────── */

    function _pot(uint256 mid) internal view returns (uint256 P) {
        (,,,,, P,,,,,,,,) = pm.getMarket(mid);
    }

    function _pps(uint256 mid) internal view returns (uint256 PPS) {
        (,,,,,, PPS,,,,,,,) = pm.getMarket(mid);
    }

    function _totalYes(uint256 yesId) internal view returns (uint256) {
        return pm.totalSupply(yesId);
    }

    function _totalNo(uint256 yesId) internal view returns (uint256) {
        return pm.totalSupply(pm.getNoId(yesId));
    }

    function _warpPast(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // fund users with ETH
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(RESOLVER, 1 ether);

        // deploy CUT
        pm = new PredictionAMM();

        // create & seed a market (seeds are outcome tokens, not wstETH)
        (marketId, noId) = _createAndSeedDefault();
        assertEq(pm.descriptions(marketId), DESC);
        assertEq(noId, pm.getNoId(marketId));
    }

    function _createAndSeedDefault() internal returns (uint256 mid, uint256 nid) {
        (mid, nid) = pm.createMarket(
            DESC,
            RESOLVER,
            uint72(block.timestamp + 30 days),
            false, // canClose
            1_000_000e9, // YES seed
            1_000_000e9 // NO seed
        );
    }

    function _circYes(uint256 yesId) internal view returns (uint256) {
        uint256 c = pm.totalSupply(yesId);
        c -= pm.balanceOf(address(pm), yesId);
        c -= pm.balanceOf(ZAMM_ADDR, yesId);
        return c;
    }

    function _circNo(uint256 yesId) internal view returns (uint256) {
        uint256 nid = pm.getNoId(yesId);
        uint256 c = pm.totalSupply(nid);
        c -= pm.balanceOf(address(pm), nid);
        c -= pm.balanceOf(ZAMM_ADDR, nid);
        return c;
    }

    /* ──────────────────────────────────────────────────────────
       Happy path: buys using wstETH path (no native ETH)
       ────────────────────────────────────────────────────────── */

    function test_BuyYes_WithWstETH_IncreasesPotAndYesBalance() public {
        // ALICE gets wstETH via zap
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 2 ether}(ALICE);
        assertGt(w, 0);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 potBefore = _pot(marketId);
        uint256 yesBefore = pm.balanceOf(ALICE, marketId);

        // ask for quote then execute tightly
        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyYes(marketId, 10_000e9);

        vm.prank(ALICE);
        (uint256 wstIn, uint256 oppIn) = pm.buyYesViaPool(
            marketId,
            10_000e9,
            false, // pay in wstETH
            wstFairQ, // exact fair bound
            oppInQ, // exact CPMM input
            ALICE
        );

        assertEq(oppIn, oppInQ, "pool input equals quote");
        // allow 1 wei rounding
        assertLe(wstIn > wstFairQ ? (wstIn - wstFairQ) : (wstFairQ - wstIn), 1);

        assertEq(pm.balanceOf(ALICE, marketId), yesBefore + 10_000e9, "YES received");
        assertEq(_pot(marketId), potBefore + wstIn, "pot increased by EV charge");
    }

    function test_BuyNo_WithWstETH_IncreasesPotAndNoBalance() public {
        vm.startPrank(BOB);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 2 ether}(BOB);
        assertGt(w, 0);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 potBefore = _pot(marketId);
        uint256 noBefore = pm.balanceOf(BOB, noId);

        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyNo(marketId, 8_000e9);

        vm.prank(BOB);
        (uint256 wstIn, uint256 oppIn) =
            pm.buyNoViaPool(marketId, 8_000e9, false, wstFairQ, oppInQ, BOB);

        assertEq(oppIn, oppInQ);
        assertLe(wstIn > wstFairQ ? (wstIn - wstFairQ) : (wstFairQ - wstIn), 1);

        assertEq(pm.balanceOf(BOB, noId), noBefore + 8_000e9, "NO received");
        assertEq(_pot(marketId), potBefore + wstIn, "pot increased");
    }

    /* ──────────────────────────────────────────────────────────
       Sell paths (refund from pot); supply bookkeeping
       ────────────────────────────────────────────────────────── */

    function test_SellYes_RefundsFromPot_AndReducesSupply() public {
        // Give ALICE some YES first
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 5_000e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();
        w;

        uint256 yesCircBefore = _circYes(marketId);
        uint256 noTotalBefore = _totalNo(marketId);
        uint256 potBefore = _pot(marketId);
        uint256 aliceYesBefore = pm.balanceOf(ALICE, marketId);

        // quote sell
        (uint256 oppOutQ, uint256 wstOutFair,,,,) = pm.quoteSellYes(marketId, 1_000e9);

        vm.prank(ALICE);
        (uint256 wstOut, uint256 oppOut) =
            pm.sellYesViaPool(marketId, 1_000e9, wstOutFair, oppOutQ, ALICE);

        assertEq(oppOut, oppOutQ, "CPMM out equals quote");
        assertLe(
            wstOut > wstOutFair ? (wstOut - wstOutFair) : (wstOutFair - wstOut), 1, "refund~quote"
        );

        // balances/supply
        assertEq(pm.balanceOf(ALICE, marketId), aliceYesBefore - 1_000e9, "user YES burned");

        // circulating YES drops by full sold amount
        assertEq(_circYes(marketId), yesCircBefore - 1_000e9, "YES circulating down by sold amt");

        // opposite side totalSupply drops by oppOut (we burn the NO received)
        assertEq(_totalNo(marketId), noTotalBefore - oppOut, "NO totalSupply down by oppOut");

        // pot pays out
        assertEq(_pot(marketId), potBefore - wstOut, "pot reduced by refund");
        assertGt(WSTETH.balanceOf(ALICE), 0, "alice received wstETH");
    }

    function test_SellNo_RefundsFromPot_AndReducesSupply() public {
        // Give BOB some NO first
        vm.startPrank(BOB);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 4_000e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        w;

        uint256 noCircBefore = _circNo(marketId);
        uint256 yesTotalBefore = _totalYes(marketId);
        uint256 potBefore = _pot(marketId);
        uint256 bobNoBefore = pm.balanceOf(BOB, noId);

        (uint256 oppOutQ, uint256 wstOutFair,,,,) = pm.quoteSellNo(marketId, 500e9);

        vm.prank(BOB);
        (uint256 wstOut, uint256 oppOut) =
            pm.sellNoViaPool(marketId, 500e9, wstOutFair, oppOutQ, BOB);

        assertEq(oppOut, oppOutQ);
        assertLe(wstOut > wstOutFair ? (wstOut - wstOutFair) : (wstOutFair - wstOut), 1);

        assertEq(pm.balanceOf(BOB, noId), bobNoBefore - 500e9, "user NO burned");

        // circulating NO drops by full sold amount
        assertEq(_circNo(marketId), noCircBefore - 500e9, "NO circulating down by sold amt");

        // opposite side totalSupply drops by oppOut (we burn the YES received)
        assertEq(_totalYes(marketId), yesTotalBefore - oppOut, "YES totalSupply down by oppOut");

        assertEq(_pot(marketId), potBefore - wstOut, "pot reduced by refund");
    }

    /* ──────────────────────────────────────────────────────────
       Close, resolve, claim
       ────────────────────────────────────────────────────────── */

    function test_ResolveYes_ThenClaim() public {
        // circulate both sides a bit
        vm.startPrank(ALICE);
        uint256 wa = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyYesViaPool(marketId, 3_000e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 wb = ZSTETH.exactETHToWSTETH{value: 1 ether}(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        pm.buyNoViaPool(marketId, 2_000e9, false, type(uint256).max, type(uint256).max, BOB);
        vm.stopPrank();
        wa;
        wb;

        _warpPast(31 days);

        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        uint256 pps = _pps(marketId);
        assertGt(pps, 0, "pps set");

        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        uint256 before = WSTETH.balanceOf(ALICE);

        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        uint256 got = WSTETH.balanceOf(ALICE) - before;
        assertEq(got, (aliceYes * pps) / 1e18, "pro-rata payout");
        assertEq(pm.balanceOf(ALICE, marketId), 0, "shares burned");
    }

    function test_CloseMarket_BlocksTrading() public {
        // create closable market
        (uint256 mid,) = pm.createMarket(
            "closable", RESOLVER, uint72(block.timestamp + 365 days), true, 1e12, 1e12
        );

        // resolver closes
        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        // Alice tries to trade -> revert
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 0.2 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.expectRevert(PredictionAMM.MarketClosed.selector);
        pm.buyYesViaPool(mid, 1e9, false, type(uint256).max, type(uint256).max, ALICE);
        vm.stopPrank();
        w;
    }

    /* ──────────────────────────────────────────────────────────
       Quotes & slippage guards
       ────────────────────────────────────────────────────────── */

    function test_QuoteVsExecution_BuyYes_TightBounds() public {
        // prep funds
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();
        w;

        uint256 out = 2_000e9;
        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyYes(marketId, out);

        vm.prank(ALICE);
        (uint256 wstIn, uint256 oppIn) =
            pm.buyYesViaPool(marketId, out, false, wstFairQ, oppInQ, ALICE);

        assertEq(oppIn, oppInQ, "oppIn matches quote");
        assertLe(wstIn > wstFairQ ? (wstIn - wstFairQ) : (wstFairQ - wstIn), 1);
    }

    function test_SlippageOppInBound_Yes_Reverts() public {
        // prep
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();
        w;

        (uint256 oppInQ,,,,,) = pm.quoteBuyYes(marketId, 3_000e9);
        vm.expectRevert(PredictionAMM.SlippageOppIn.selector);
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, 3_000e9, false, type(uint256).max, oppInQ - 1, ALICE);
    }

    function test_SellYes_Guards_InsufficientLiquidity() public {
        // Try to sell absurd amount (>= rYES)
        // Read reserves from getter
        (,,,,,,,,,, uint256 rYes, uint256 rNo,,) = pm.getMarket(marketId);
        rNo; // silence
        vm.expectRevert(PredictionAMM.InsufficientLiquidity.selector);
        vm.prank(ALICE);
        pm.sellYesViaPool(marketId, rYes, 0, 0, ALICE);
    }

    /* ──────────────────────────────────────────────────────────
       Getters sanity
       ────────────────────────────────────────────────────────── */

    function test_GetMarket_SnapshotIsCoherent() public {
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

        assertEq(resolver, RESOLVER);
        assertFalse(resolved);
        assertFalse(outcome);
        assertEq(desc, DESC);
        assertGt(closeTs, block.timestamp);
        assertEq(yesSupply, _totalYes(marketId));
        assertEq(noSupply, _totalNo(marketId));
        assertEq(pot, _pot(marketId));
        assertEq(payoutPerShare, _pps(marketId));

        if (pDen > 0) {
            assertEq(rYes + rNo, pDen);
            assertEq(rNo, pNum);
        }
    }

    /* ──────────────────────────────────────────────────────────
       Small integration: buy then sell → pot near unchanged
       (modulo fees & rounding)
       ────────────────────────────────────────────────────────── */

    function test_BuyThenSell_RoughPotNeutral() public {
        vm.startPrank(ALICE);
        uint256 w = ZSTETH.exactETHToWSTETH{value: 1.5 ether}(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();
        w;

        uint256 pot0 = _pot(marketId);

        // buy YES
        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyYes(marketId, 2_500e9);
        vm.prank(ALICE);
        (uint256 wIn,) = pm.buyYesViaPool(marketId, 2_500e9, false, wstFairQ, oppInQ, ALICE);

        // sell the same YES back
        (uint256 oppOutQ, uint256 refundFair,,,,) = pm.quoteSellYes(marketId, 2_500e9);
        vm.prank(ALICE);
        (uint256 wOut,) = pm.sellYesViaPool(marketId, 2_500e9, refundFair, oppOutQ, ALICE);

        // CPMM fee + rounding → pot should be pot0 + (wIn - wOut) >= pot0
        assertGe(_pot(marketId), pot0, "pot should not be drained by buy-then-sell loop");
    }
}
