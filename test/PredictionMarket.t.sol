// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {PredictionMarket} from "../src/PredictionMarket.sol";

// Minimal ERC20 view for balance/approve in tests
interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

// Use the real mainnet addresses you used in the contract
IERC20View constant WSTETH_TOKEN = IERC20View(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

interface IZSTETH {
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
}

IZSTETH constant ZSTETH_ZAP = IZSTETH(0x000000000088649055D9D23362B819A5cfF11f02);

contract PredictionMarketWstETHTest is Test {
    // Actors
    address internal RESOLVER = makeAddr("RESOLVER");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");
    address internal CAROL = makeAddr("CAROL");

    // CUT
    PredictionMarket internal pm;

    // Market ids
    string internal constant DESC = "Will Shanghai Disneyland close for a week in Q4?";
    uint256 internal marketId;
    uint256 internal noId;

    event Closed(uint256 indexed marketId, uint256 closedAt, address indexed by);

    function setUp() public {
        // Use a mainnet fork so WSTETH + ZSTETH exist
        vm.createSelectFork(vm.rpcUrl("main"));

        // Fund users with ETH for buys / zap
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);
        vm.deal(RESOLVER, 1 ether);

        pm = new PredictionMarket();

        // Create a market with far close; tests will warp past close before resolve.
        (marketId, noId) =
            pm.createMarket(DESC, RESOLVER, uint72(block.timestamp + 365 days), false);
        assertEq(marketId, pm.getMarketId(DESC, RESOLVER));
        assertEq(noId, pm.getNoId(marketId));
    }

    // --- Helpers ---
    function pot(uint256 mid) internal view returns (uint256 P) {
        // getMarket returns (yesSupply,noSupply,resolver,resolved,outcome,pot,payoutPerShare,desc)
        (,,,,, P,,) = pm.getMarket(mid);
    }

    function pps(uint256 mid) internal view returns (uint256 PPS) {
        (,,,,,, PPS,) = pm.getMarket(mid);
    }

    function _warpPastClose() internal {
        // Our created market closes at now + 365d; jump beyond that.
        vm.warp(block.timestamp + 366 days);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Core flows
    // ═════════════════════════════════════════════════════════════════════════════

    function testBuyYesWithETH_MintsSharesAndEscrowsWSTETH() public {
        vm.prank(ALICE);
        uint256 wstIn = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        assertGt(wstIn, 0, "zap should return >0 WSTETH");

        assertEq(pm.balanceOf(ALICE, marketId), wstIn);
        assertEq(pm.totalSupply(marketId), wstIn);
        assertEq(pot(marketId), wstIn);
    }

    function testSellYes_ReturnsWSTETH_PreResolve() public {
        vm.prank(ALICE);
        uint256 wstIn = pm.buyYes{value: 3 ether}(marketId, 0, ALICE);
        uint256 half = wstIn / 2;

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);

        vm.prank(ALICE);
        pm.sellYes(marketId, half, ALICE);

        uint256 afterBal = WSTETH_TOKEN.balanceOf(ALICE);
        assertEq(afterBal - before, half, "sell should return WSTETH");
        assertEq(pm.balanceOf(ALICE, marketId), wstIn - half);
        assertEq(pm.totalSupply(marketId), wstIn - half);
        assertEq(pot(marketId), wstIn - half);
    }

    function testResolveYesAndClaim_PaysOutInWSTETH() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 1 ether}(marketId, 0, BOB);
        vm.prank(BOB);
        n += pm.buyNo{value: 1 ether}(marketId, 0, BOB);
        assertGt(y, 0);
        assertGt(n, 0);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 PPS = pps(marketId);
        assertGt(PPS, 0);

        uint256 cBefore = WSTETH_TOKEN.balanceOf(CAROL);
        vm.prank(ALICE);
        pm.claim(marketId, CAROL);
        uint256 got = WSTETH_TOKEN.balanceOf(CAROL) - cBefore;

        assertEq(got, (y * PPS) / 1e18);
        uint256 num = pot(marketId);
        num == 1 ? num = 0 : 1;
        assertEq(num, pm.totalSupply(pm.winningId(marketId)) * PPS / 1e18);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // WSTETH transferFrom path
    // ═════════════════════════════════════════════════════════════════════════════

    function testBuyWithWSTETH_TransferFromPath() public {
        vm.prank(CAROL);
        uint256 w0 = ZSTETH_ZAP.exactETHToWSTETH{value: 1 ether}(CAROL);
        assertGt(w0, 0);

        vm.prank(CAROL);
        WSTETH_TOKEN.approve(address(pm), type(uint256).max);

        vm.prank(CAROL);
        uint256 wIn = pm.buyNo(marketId, w0, CAROL);
        assertEq(wIn, w0, "amount pulled should equal buy amount");
        assertEq(pm.balanceOf(CAROL, noId), w0);
        assertEq(pm.totalSupply(noId), w0);
        assertEq(pot(marketId), w0);
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Guards / invariants / lifecycle
    // ═════════════════════════════════════════════════════════════════════════════

    function testResolveBeforeClose_Reverts() public {
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        vm.prank(RESOLVER);
        vm.expectRevert(PredictionMarket.MarketNotClosed.selector);
        pm.resolve(marketId, true);
    }

    function testTradingBlocked_AfterClose() public {
        vm.prank(ALICE);
        pm.buyYes{value: 0.5 ether}(marketId, 0, ALICE);

        _warpPastClose();

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.buyYes{value: 0.5 ether}(marketId, 0, ALICE);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.buyNo{value: 0.5 ether}(marketId, 0, ALICE);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.sellYes(marketId, 1, ALICE);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.sellNo(marketId, 1, ALICE);
    }

    // --- Cancellation (one-sided) tests ---

    function testCancel_OnlyYesSide_RedeemsPar() public {
        (uint256 mId,) =
            pm.createMarket("cancel-yes-only", RESOLVER, uint72(block.timestamp + 1 hours), false);

        vm.deal(ALICE, 2 ether);
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mId, 0, ALICE);
        assertGt(y, 0);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(mId, true);

        (,,, bool resolved,,, uint256 PPS,) = pm.getMarket(mId);
        assertTrue(resolved);
        assertEq(PPS, 0, "pps==0 sentinel for cancel");

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mId, ALICE);
        uint256 got = WSTETH_TOKEN.balanceOf(ALICE) - before;
        assertEq(got, y, "par refund for YES");

        assertEq(pot(mId), 0, "pot reduced to zero after sole claimant");
    }

    function testCancel_OnlyNoSide_RedeemsPar() public {
        (uint256 mId,) =
            pm.createMarket("cancel-no-only", RESOLVER, uint72(block.timestamp + 1 hours), false);

        vm.deal(BOB, 2 ether);
        vm.prank(BOB);
        uint256 w = pm.buyNo{value: 1 ether}(mId, 0, BOB);
        assertGt(w, 0);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(mId, false);

        (,,, bool resolved,,, uint256 PPS,) = pm.getMarket(mId);
        assertTrue(resolved);
        assertEq(PPS, 0, "pps==0 sentinel for cancel");

        uint256 before = WSTETH_TOKEN.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(mId, BOB);
        uint256 got = WSTETH_TOKEN.balanceOf(BOB) - before;
        assertEq(got, w, "par refund for NO");
    }

    function testCancel_MultiClaimers_ParAndPotZero() public {
        (uint256 mId,) =
            pm.createMarket("cancel-multi", RESOLVER, uint72(block.timestamp + 1 hours), false);

        vm.deal(ALICE, 2 ether);
        vm.deal(BOB, 2 ether);

        vm.prank(ALICE);
        uint256 a = pm.buyYes{value: 0.7 ether}(mId, 0, ALICE);
        vm.prank(BOB);
        uint256 b = pm.buyYes{value: 0.3 ether}(mId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(mId, true); // cancels (NO side is 0)

        uint256 potAtResolve = pot(mId);

        vm.prank(ALICE);
        pm.claim(mId, ALICE);
        vm.prank(BOB);
        pm.claim(mId, BOB);

        assertEq(pot(mId), potAtResolve - a - b, "pot reduced by total payouts");
        assertEq(pot(mId), 0, "pot fully drained");
    }

    function testCancel_ClaimAllowsEitherSide_NoSharesOtherSideReverts() public {
        (uint256 mId,) =
            pm.createMarket("cancel-either", RESOLVER, uint72(block.timestamp + 1 hours), false);

        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mId, 0, ALICE);
        assertGt(y, 0);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(mId, false); // cancels

        vm.prank(BOB);
        vm.expectRevert(PredictionMarket.NoWinningShares.selector);
        pm.claim(mId, BOB);

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mId, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - before, y);
    }

    // Invariant: pot equals yes+no supplies before resolve
    function testInvariant_PotEqualsYesPlusNo_PreResolve() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 3 ether}(marketId, 0, BOB);

        vm.prank(ALICE);
        pm.sellYes(marketId, y / 2, ALICE);
        vm.prank(BOB);
        pm.sellNo(marketId, n / 3, BOB);

        uint256 sYes = pm.totalSupply(marketId);
        uint256 sNo = pm.totalSupply(noId);
        assertEq(pot(marketId), sYes + sNo, "pot must equal sum of supplies (WSTETH units)");
    }

    function testLosersCannotClaim_WinnersCan() public {
        vm.prank(ALICE);
        pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        vm.prank(BOB);
        vm.expectRevert(PredictionMarket.NoWinningShares.selector);
        pm.claim(marketId, BOB);

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
        assertGt(WSTETH_TOKEN.balanceOf(ALICE) - before, 0);
    }

    function testRegistryCounts() public {
        uint256 before = pm.marketCount();
        vm.prank(ALICE);
        pm.createMarket("Second market", RESOLVER, uint72(block.timestamp + 365 days), false);
        assertEq(pm.marketCount(), before + 1);
    }

    function testCreateMarket_InvalidResolver_Reverts() public {
        vm.expectRevert(PredictionMarket.InvalidResolver.selector);
        pm.createMarket("bad", address(0), uint72(block.timestamp + 365 days), false);
    }

    function testCreateMarket_Duplicate_Reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(PredictionMarket.MarketExists.selector);
        pm.createMarket(DESC, RESOLVER, uint72(block.timestamp + 365 days), false);
    }

    function testMarketNotFound_BuyAndResolve() public {
        uint256 fake = 0xDEADBEEF;
        vm.expectRevert(PredictionMarket.MarketNotFound.selector);
        pm.buyYes{value: 1 ether}(fake, 0, ALICE);

        vm.expectRevert(PredictionMarket.MarketNotFound.selector);
        pm.resolve(fake, true);
    }

    function testBuySellBlocked_AfterResolve() public {
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PredictionMarket.MarketResolved.selector);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.expectRevert(PredictionMarket.MarketResolved.selector);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        vm.prank(ALICE);
        vm.expectRevert(PredictionMarket.MarketResolved.selector);
        pm.sellYes(marketId, 1, ALICE);

        vm.prank(BOB);
        vm.expectRevert(PredictionMarket.MarketResolved.selector);
        pm.sellNo(marketId, 1, BOB);
    }

    function testApproveAndTransferFrom_DecrementsAllowance_WST() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, y / 2);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, y / 4);
        assertEq(pm.allowance(ALICE, BOB, marketId), (y / 2) - (y / 4));

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, y / 4);
        assertLt(pm.allowance(ALICE, BOB, marketId), 2);
    }

    function testApproveMax_SkipsDecrement_WST() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(marketId, 0, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, type(uint256).max);

        vm.startPrank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, y / 3);
        pm.transferFrom(ALICE, BOB, marketId, y / 3);
        vm.stopPrank();

        assertEq(pm.allowance(ALICE, BOB, marketId), type(uint256).max);
    }

    function testOperatorTransfer_WST_PostResolve_RecipientClaims() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 2 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.prank(ALICE);
        pm.setOperator(BOB, true);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, y / 2);

        uint256 before = WSTETH_TOKEN.balanceOf(BOB);
        uint256 P = pps(marketId);
        vm.prank(BOB);
        pm.claim(marketId, BOB);
        uint256 got = WSTETH_TOKEN.balanceOf(BOB) - before;

        assertEq(got, (y / 2) * P / 1e18);
    }

    function testOperatorRevoke_BlocksTransferFrom() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(ALICE);
        pm.setOperator(BOB, true);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, y / 2);
        vm.prank(ALICE);
        pm.setOperator(BOB, false);

        vm.prank(BOB);
        vm.expectRevert(); // allowance branch underflows
        pm.transferFrom(ALICE, BOB, marketId, 1);
    }

    function testSellFullBalance_ThenOversellReverts_WST() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(marketId, 0, ALICE);

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.sellYes(marketId, y, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - before, y);
        assertEq(pm.balanceOf(ALICE, marketId), 0);
        assertEq(pm.totalSupply(marketId), 0);

        vm.prank(ALICE);
        vm.expectRevert(); // panic underflow
        pm.sellYes(marketId, 1, ALICE);
    }

    function testWinningId_ZeroBeforeResolve_WST() public view {
        assertEq(0, pm.winningId(marketId));
    }

    function testWinningId_YesWins_WST() public {
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);
        assertEq(pm.winningId(marketId), marketId);
    }

    function testWinningId_NoWins_WST() public {
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 2 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, false);
        assertEq(pm.winningId(marketId), noId);
    }

    function testPPS_TinyExact_WST() public {
        vm.prank(ALICE);
        uint256 wA = ZSTETH_ZAP.exactETHToWSTETH{value: 0.01 ether}(ALICE);
        vm.prank(BOB);
        uint256 wB = ZSTETH_ZAP.exactETHToWSTETH{value: 0.005 ether}(BOB);
        if (wA == 0 || wB == 0) return;

        vm.prank(ALICE);
        WSTETH_TOKEN.approve(address(pm), type(uint256).max);
        vm.prank(BOB);
        WSTETH_TOKEN.approve(address(pm), type(uint256).max);

        vm.prank(ALICE);
        pm.buyYes(marketId, wA, ALICE);
        vm.prank(BOB);
        pm.buyNo(marketId, wB, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 P = pps(marketId);
        uint256 before = IERC20View(address(WSTETH_TOKEN)).balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
        assertEq(IERC20View(address(WSTETH_TOKEN)).balanceOf(ALICE) - before, (wA * P) / 1e18);
    }

    function testForceSendETH_DoesNotAffectPot_WST() public {
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(marketId, 0, BOB);

        uint256 potBefore = pot(marketId);
        uint256 balBefore = address(pm).balance;

        ForceSend fs = new ForceSend{value: 5 ether}();
        fs.boom(address(pm));

        assertEq(pot(marketId), potBefore, "WST pot unchanged");

        assertApproxEqAbs(
            address(pm).balance, balBefore + 5 ether, 2, "ETH forced in, ignored by logic"
        );
    }

    function testAccounting_SumPayoutsPlusDustEqualsPotAtResolve_WST() public {
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(marketId, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 3 ether}(marketId, 0, BOB);

        _warpPastClose();

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 potAtResolve = pot(marketId);
        uint256 P = pps(marketId);

        vm.prank(ALICE);
        pm.transfer(BOB, marketId, y / 2);

        uint256 aBefore = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
        uint256 aPayout = WSTETH_TOKEN.balanceOf(ALICE) - aBefore;

        uint256 bBefore = WSTETH_TOKEN.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(marketId, BOB);
        uint256 bPayout = WSTETH_TOKEN.balanceOf(BOB) - bBefore;

        uint256 remaining = pot(marketId);
        assertEq(aPayout + bPayout + remaining, potAtResolve, "payouts + dust == initial pot");
    }

    function testBuyWithWSTETH_AmountZero_Reverts() public {
        vm.expectRevert(PredictionMarket.AmountZero.selector);
        pm.buyYes(marketId, 0, ALICE);
    }

    function testRegistry_GetMarket_ViewFields() public {
        (
            uint256 ySup,
            uint256 nSup,
            address r,
            bool resolved,
            bool outcome,
            uint256 P,
            uint256 PPS,
            string memory desc
        ) = pm.getMarket(marketId);

        assertEq(r, RESOLVER);
        assertEq(desc, "Will Shanghai Disneyland close for a week in Q4?");
        assertFalse(resolved);
        assertFalse(outcome);
        assertEq(P, 0);
        assertEq(PPS, 0);
        assertEq(ySup, 0);
        assertEq(nSup, 0);

        uint256 before = pm.marketCount();
        vm.prank(ALICE);
        pm.createMarket("extra", RESOLVER, uint72(block.timestamp + 365 days), false);
        assertEq(pm.marketCount(), before + 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Manual close (canClose) tests
    // ─────────────────────────────────────────────────────────────────────────────

    function testManualClose_BlocksTrading_AllowsResolve() public {
        // Create a market with canClose = true and far future close
        (uint256 mid,) = pm.createMarket(
            "manual-close: YES vs NO",
            RESOLVER,
            uint72(block.timestamp + 365 days),
            true // canClose
        );

        // Fund both sides pre-close
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(mid, 0, BOB);

        // Resolver manually closes *now* (no warp)
        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        // Trading is now blocked
        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.buyYes{value: 0.1 ether}(mid, 0, ALICE);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.sellNo(mid, 1, BOB);

        // But resolve is allowed immediately (market is "closed")
        vm.prank(RESOLVER);
        pm.resolve(mid, true); // YES wins

        // Winner can claim
        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertGt(WSTETH_TOKEN.balanceOf(ALICE) - before, 0, "winner should receive payout");
    }

    function testManualClose_NotAllowed_WhenFlagFalse() public {
        (uint256 mid,) = pm.createMarket(
            "no-manual-close",
            RESOLVER,
            uint72(block.timestamp + 365 days),
            false // canClose disabled
        );

        vm.prank(RESOLVER);
        vm.expectRevert(PredictionMarket.CannotClose.selector);
        pm.closeMarket(mid);
    }

    function testManualClose_OnlyResolver() public {
        (uint256 mid,) = pm.createMarket(
            "only-resolver-can-close", RESOLVER, uint72(block.timestamp + 365 days), true
        );

        // Anyone else cannot close
        vm.prank(ALICE);
        vm.expectRevert(PredictionMarket.OnlyResolver.selector);
        pm.closeMarket(mid);

        // Resolver can
        vm.prank(RESOLVER);
        pm.closeMarket(mid);
    }

    function testManualClose_RevertsIfAlreadyClosedOrResolved() public {
        // Create with canClose = true and far close
        (uint256 mid,) =
            pm.createMarket("re-close guard", RESOLVER, uint72(block.timestamp + 365 days), true);

        // FUND BOTH SIDES BEFORE CLOSING
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(mid, 0, BOB);

        // Close once
        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        // Closing again → MarketClosed
        vm.prank(RESOLVER);
        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.closeMarket(mid);

        // Now resolve (allowed immediately after manual close)
        vm.prank(RESOLVER);
        pm.resolve(mid, true);

        // Closing after resolve → MarketResolved
        vm.prank(RESOLVER);
        vm.expectRevert(PredictionMarket.MarketResolved.selector);
        pm.closeMarket(mid);
    }

    function testManualClose_BlocksTradingAfterClose() public {
        (uint256 mid,) = pm.createMarket(
            "trading blocked after close", RESOLVER, uint72(block.timestamp + 365 days), true
        );

        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.buyYes{value: 0.1 ether}(mid, 0, ALICE);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.sellNo(mid, 1, BOB);
    }

    function testManualClose_EmitsClosedEvent_AndLocksAtTimestamp() public {
        (uint256 mid,) =
            pm.createMarket("event:Closed", RESOLVER, uint72(block.timestamp + 365 days), true);

        vm.expectEmit(true, true, true, true);
        emit Closed(mid, uint64(block.timestamp), RESOLVER);

        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.buyNo{value: 0.01 ether}(mid, 0, BOB);
    }

    function testManualClose_NoEffectOnPotOrSupply() public {
        (uint256 mid,) = pm.createMarket(
            "no state change on close", RESOLVER, uint72(block.timestamp + 365 days), true
        );

        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 0.5 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 0.75 ether}(mid, 0, BOB);

        (,,,,, uint256 potBefore,,) = pm.getMarket(mid);
        uint256 yBefore = pm.totalSupply(mid);
        uint256 nBefore = pm.totalSupply(pm.getNoId(mid));

        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        (,,,,, uint256 potAfter,,) = pm.getMarket(mid);
        assertEq(potAfter, potBefore, "pot unchanged");
        assertEq(pm.totalSupply(mid), yBefore, "YES supply unchanged");
        assertEq(pm.totalSupply(pm.getNoId(mid)), nBefore, "NO supply unchanged");

        vm.expectRevert(PredictionMarket.MarketClosed.selector);
        pm.sellYes(mid, y / 4, ALICE);
    }

    function testManualClose_WorksWithCanceledMarket_RedeemParOnEitherSide() public {
        (uint256 mid,) = pm.createMarket(
            "cancelable manual close", RESOLVER, uint72(block.timestamp + 365 days), true
        );

        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mid, 0, ALICE);

        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        vm.prank(RESOLVER);
        pm.resolve(mid, true); // canceled path if one-sided

        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - before, y, "par redemption on cancel");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pagination getters
    // ─────────────────────────────────────────────────────────────────────────────

    function testGetMarkets_Pagination() public {
        // Create 3 more markets for paging
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(ALICE);
            pm.createMarket(
                string(abi.encodePacked("M-", vm.toString(i))),
                RESOLVER,
                uint72(block.timestamp + 30 days),
                false
            );
        }

        // Page size 2
        (
            uint256[] memory ids1,
            uint256[] memory yes1,
            uint256[] memory no1,
            address[] memory resolvers1,
            bool[] memory resolved1,
            bool[] memory outcome1,
            uint256[] memory pot1,
            uint256[] memory pps1,
            string[] memory descs1,
            uint256 next1
        ) = pm.getMarkets(0, 2);

        assertEq(ids1.length, 2);
        assertEq(resolvers1.length, 2);
        assertGt(next1, 0);

        (
            uint256[] memory ids2,
            uint256[] memory yes2,
            uint256[] memory no2,
            address[] memory resolvers2,
            bool[] memory resolved2,
            bool[] memory outcome2,
            uint256[] memory pot2,
            uint256[] memory pps2,
            string[] memory descs2,
            uint256 next2
        ) = pm.getMarkets(next1, 2);

        assertEq(ids2.length, 2);
        // After second page, likely no more pages (depending on initial market)
        // So next2 may be 0 if exactly consumed.
        // Basic sanity on shapes:
        assertEq(yes1.length, 2);
        assertEq(no1.length, 2);
        assertEq(pot1.length, 2);
        assertEq(pps1.length, 2);
        assertEq(descs1.length, 2);

        assertEq(yes2.length, ids2.length);
        assertEq(no2.length, ids2.length);
        assertEq(pot2.length, ids2.length);
        assertEq(pps2.length, ids2.length);
        assertEq(descs2.length, ids2.length);
    }

    function testGetUserMarkets_Pagination() public {
        // Seed a couple of markets and positions for ALICE
        (uint256 m1,) = pm.createMarket("U-1", RESOLVER, uint72(block.timestamp + 10 days), false);
        (uint256 m2,) = pm.createMarket("U-2", RESOLVER, uint72(block.timestamp + 20 days), false);
        (uint256 m3,) = pm.createMarket("U-3", RESOLVER, uint72(block.timestamp + 30 days), false);

        vm.prank(ALICE);
        pm.buyYes{value: 0.5 ether}(m1, 0, ALICE);

        vm.prank(ALICE);
        pm.buyNo{value: 0.75 ether}(m2, 0, ALICE);

        // page size 2
        (
            uint256[] memory yesIds1,
            uint256[] memory noIds1,
            uint256[] memory yesBal1,
            uint256[] memory noBal1,
            uint256[] memory claim1,
            bool[] memory resolved1,
            bool[] memory open1,
            uint256 next1
        ) = pm.getUserMarkets(ALICE, 0, 2);

        assertEq(yesIds1.length, 2);
        assertEq(noIds1.length, 2);
        assertEq(yesBal1.length, 2);
        assertEq(noBal1.length, 2);
        assertEq(claim1.length, 2);
        assertEq(resolved1.length, 2);
        assertEq(open1.length, 2);
        assertGt(next1, 0, "should have next page");

        (
            uint256[] memory yesIds2,
            uint256[] memory noIds2,
            uint256[] memory yesBal2,
            uint256[] memory noBal2,
            uint256[] memory claim2,
            bool[] memory resolved2,
            bool[] memory open2,
            uint256 next2
        ) = pm.getUserMarkets(ALICE, next1, 2);

        assertEq(yesIds2.length, yesBal2.length);
        assertEq(noIds2.length, noBal2.length);
        assertEq(claim2.length, yesIds2.length);
        assertEq(resolved2.length, yesIds2.length);
        assertEq(open2.length, yesIds2.length);
        // next2 may be 0 if last page
    }

    // EXTRA

    function testCancel_SingleUser_DoubleClaimReverts_AndPotZero() public {
        // Create a market that will cancel (fund only YES).
        (uint256 mId,) = pm.createMarket(
            "cancel-single-user", RESOLVER, uint72(block.timestamp + 1 hours), false
        );

        // ALICE buys YES only → NO side remains 0 → cancel on resolve.
        vm.deal(ALICE, 2 ether);
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mId, 0, ALICE);
        assertGt(y, 0);

        // Warp beyond close and resolve (canceled path: PPS==0).
        vm.warp(block.timestamp + 2 hours);
        vm.prank(RESOLVER);
        pm.resolve(mId, true);

        (
            ,
            ,
            ,
            ,
            , // yesSupply, noSupply, resolver, resolved, outcome (unused here)
            uint256 potBefore,
            uint256 PPS,
        ) = pm.getMarket(mId);

        assertEq(PPS, 0, "pps==0 sentinel for canceled market");

        // First claim returns par (y).
        uint256 before = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mId, ALICE);
        uint256 got = WSTETH_TOKEN.balanceOf(ALICE) - before;
        assertEq(got, y, "par redemption for canceled market");

        // Pot decreased exactly by y.
        (,,,,, uint256 potAfter,,) = pm.getMarket(mId);

        assertEq(potAfter, potBefore - y, "pot reduced by the payout");

        // Second claim should revert: no remaining shares.
        vm.prank(ALICE);
        vm.expectRevert(PredictionMarket.NoWinningShares.selector);
        pm.claim(mId, ALICE);
    }

    function testWinningId_IsZeroOnCanceledMarket() public {
        // Create a market that will cancel (fund only NO this time).
        (uint256 mId,) = pm.createMarket(
            "canceled-winningId-zero", RESOLVER, uint72(block.timestamp + 1 hours), false
        );

        // BOB buys NO only → YES side remains 0 → canceled on resolve.
        vm.deal(BOB, 1 ether);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 1 ether}(mId, 0, BOB);
        assertGt(n, 0);

        // Warp and resolve; canceled path will be taken.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(RESOLVER);
        pm.resolve(mId, false);

        // winningId must be 0 for canceled markets.
        assertEq(pm.winningId(mId), 0, "winningId() returns 0 for canceled markets");

        // Sanity: BOB can redeem par on NO side.
        uint256 before = WSTETH_TOKEN.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(mId, BOB);
        assertEq(WSTETH_TOKEN.balanceOf(BOB) - before, n, "par redemption for NO on cancel");
    }

    // ═════════════════════════════════════════════════════════════════════════════
    // Resolver fee (storage-driven) tests
    // Assumes your contract exposes: setResolverFeeBps(uint16), resolverFeeBps(address) public
    // and fee is applied in resolve() BEFORE computing payoutPerShare, and skipped on cancel (pps=0).
    // ═════════════════════════════════════════════════════════════════════════════

    // Local helpers to read pot / pps from the extended getMarket tuple.
    function _pot2(uint256 mid) internal view returns (uint256 P) {
        (,,,,, P,,) = pm.getMarket(mid);
    }

    function _pps2(uint256 mid) internal view returns (uint256 PPS) {
        (,,,,,, PPS,) = pm.getMarket(mid);
    }

    function _resolved2(uint256 mid) internal view returns (bool r) {
        (,,, r,,,,) = pm.getMarket(mid);
    }

    function testResolverFee_DefaultZero_NoFeeApplied() public {
        // fee defaults to 0
        (uint256 mid,) = pm.createMarket(
            "fee=0 default", RESOLVER, uint72(block.timestamp + 2 days), false /*canClose*/
        );

        // Seed both sides
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 2 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 1 ether}(mid, 0, BOB);

        vm.warp(block.timestamp + 3 days);

        uint256 potBefore = _pot2(mid); // should equal y + n
        uint256 resolverBalBefore = WSTETH_TOKEN.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(mid, true); // YES wins

        assertTrue(_resolved2(mid));
        assertEq(WSTETH_TOKEN.balanceOf(RESOLVER), resolverBalBefore, "no fee at 0 bps");

        // PPS should be (potBefore / y) * 1e18
        uint256 P = _pps2(mid);
        assertGt(P, 0);
        assertEq(P, (potBefore * 1e18) / y);

        // Winner claim matches shares * PPS / 1e18
        uint256 aBefore = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - aBefore, (y * P) / 1e18);
    }

    function testResolverFee_Set1Percent_AppliesAndAdjustsPPS() public {
        // Resolver sets 1% fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(100); // 1%

        (uint256 mid,) =
            pm.createMarket("fee=1% via storage", RESOLVER, uint72(block.timestamp + 2 days), false);

        // Seed both sides
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 3 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 1 ether}(mid, 0, BOB);

        vm.warp(block.timestamp + 3 days);

        uint256 potBefore = _pot2(mid);
        uint256 feeExpected = (potBefore * 100) / 10_000; // 1%
        uint256 resolverBalBefore = WSTETH_TOKEN.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(mid, true); // YES wins

        // Fee was transferred to resolver
        uint256 resolverGain = WSTETH_TOKEN.balanceOf(RESOLVER) - resolverBalBefore;
        assertEq(resolverGain, feeExpected, "resolver receives 1%");

        // PPS uses net pot (after fee)
        uint256 netPot = potBefore - feeExpected;
        uint256 P = _pps2(mid);
        assertEq(P, (netPot * 1e18) / y, "pps derived from net pot");

        // Winner claim matches net PPS
        uint256 aBefore = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - aBefore, (y * P) / 1e18);
    }

    function testResolverFee_SkippedOnCanceledMarket() public {
        // Resolver sets 2% fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(200); // 2%

        (uint256 mid,) =
            pm.createMarket("fee=2% canceled", RESOLVER, uint72(block.timestamp + 1 hours), false);

        // One-sided: YES only → canceled path (pps=0)
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mid, 0, ALICE);

        vm.warp(block.timestamp + 2 hours);
        uint256 resolverBalBefore = WSTETH_TOKEN.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(mid, true); // outcome unused on cancel

        // No fee taken on canceled markets
        assertEq(WSTETH_TOKEN.balanceOf(RESOLVER), resolverBalBefore, "no fee on cancel");
        assertEq(_pps2(mid), 0, "pps=0 sentinel");

        // ALICE can redeem par
        uint256 aBefore = WSTETH_TOKEN.balanceOf(ALICE);
        vm.prank(ALICE);
        pm.claim(mid, ALICE);
        assertEq(WSTETH_TOKEN.balanceOf(ALICE) - aBefore, y, "par redemption");
    }

    function testResolverFee_ManualCloseThenResolve_WithFee() public {
        // Resolver sets 0.5% fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(50); // 0.5%

        (uint256 mid,) = pm.createMarket(
            "manual close + fee=0.5%",
            RESOLVER,
            uint72(block.timestamp + 365 days),
            true /*canClose*/
        );

        // Seed both sides
        vm.prank(ALICE);
        uint256 y = pm.buyYes{value: 1 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        uint256 n = pm.buyNo{value: 2 ether}(mid, 0, BOB);

        // Manual close now
        vm.prank(RESOLVER);
        pm.closeMarket(mid);

        // Resolve immediately (NO wins)
        uint256 potBefore = _pot2(mid);
        uint256 feeExpected = (potBefore * 50) / 10_000;
        uint256 resolverBalBefore = WSTETH_TOKEN.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(mid, false);

        // Fee paid to resolver
        assertEq(
            WSTETH_TOKEN.balanceOf(RESOLVER) - resolverBalBefore,
            feeExpected,
            "resolver fee received"
        );

        // PPS = (net pot / NO supply) * 1e18
        uint256 netPot = potBefore - feeExpected;
        uint256 P = _pps2(mid);
        assertEq(P, (netPot * 1e18) / n);

        // BOB can claim proportionally
        uint256 bBefore = WSTETH_TOKEN.balanceOf(BOB);
        vm.prank(BOB);
        pm.claim(mid, BOB);
        assertEq(WSTETH_TOKEN.balanceOf(BOB) - bBefore, (n * P) / 1e18);
    }

    function testSetResolverFeeBps_GuardAbove10000() public {
        vm.prank(RESOLVER);
        vm.expectRevert(PredictionMarket.FeeOverflow.selector);
        pm.setResolverFeeBps(10_001);
    }

    function testSetResolverFeeBps_UpdateAndReflectsInResolve() public {
        (uint256 mid,) = pm.createMarket(
            "fee change reflected", RESOLVER, uint72(block.timestamp + 2 days), false
        );

        // Start with 0 bps
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(0);

        // Fund both sides
        vm.prank(ALICE);
        pm.buyYes{value: 1 ether}(mid, 0, ALICE);
        vm.prank(BOB);
        pm.buyNo{value: 1 ether}(mid, 0, BOB);

        // Change fee before resolve to 1.5%
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(150);

        vm.warp(block.timestamp + 3 days);

        uint256 potBefore = _pot2(mid);
        uint256 feeExpected = (potBefore * 150) / 10_000;
        uint256 resolverBalBefore = WSTETH_TOKEN.balanceOf(RESOLVER);

        vm.prank(RESOLVER);
        pm.resolve(mid, true);

        assertEq(
            WSTETH_TOKEN.balanceOf(RESOLVER) - resolverBalBefore, feeExpected, "updated fee applied"
        );
    }
}

contract ForceSend {
    constructor() payable {}

    function boom(address target) external {
        selfdestruct(payable(target));
    }
}
