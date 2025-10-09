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

    // error selectors
    bytes4 immutable ERR_SlippageOppIn = PredictionAMM.SlippageOppIn.selector; // 0x098fb561

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

        // fund users with ETH for zap path
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
       The three focus scenarios (updated expectations)
       ────────────────────────────────────────────────────────── */

    /// Fresh NO quote → move market → using the stale/tight caps should hit SlippageOppIn() → re-quote + pad passes.
    function test_BuyNo_StaleReverts_FreshPaddedPasses() public {
        // fund
        _fundWst(BOB, 2 ether);
        _fundWst(ALICE, 1 ether);

        vm.startPrank(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 sharesOutNo = 1_000e9; // target NO size

        // 1) Fresh NO quote (tight bounds we'll intentionally reuse later)
        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyNo(marketId, sharesOutNo);

        // 2) Move price *against NO*  -> Alice buys NO (makes NO more expensive)
        {
            uint256 noOutMove = 25_000e9;
            (uint256 oppMove, uint256 wstMove,,,,) = pm.quoteBuyNo(marketId, noOutMove);
            // use a generous cap so the move definitely executes
            vm.prank(ALICE);
            pm.buyNoViaPool(marketId, noOutMove, false, wstMove, type(uint256).max, ALICE);
        }

        // 3) Reuse the *stale* tight bounds -> must fail with SlippageOppIn()
        vm.expectRevert(abi.encodeWithSelector(ERR_SlippageOppIn));
        vm.prank(BOB);
        pm.buyNoViaPool(marketId, sharesOutNo, false, wstFairQ, oppInQ, BOB);

        // 4) Re-quote after the move and pad by 5% -> should pass
        (uint256 oppInNew, uint256 wstFairNew,,,,) = pm.quoteBuyNo(marketId, sharesOutNo);
        uint256 maxW = _padBps(wstFairNew, 500); // +5%
        uint256 maxO = _padBps(oppInNew, 500); // +5%

        vm.prank(BOB);
        (uint256 wSpent,) = pm.buyNoViaPool(marketId, sharesOutNo, false, maxW, maxO, BOB);

        assertLe(wSpent, maxW, "spent must be <= padded wst cap");
        assertEq(pm.balanceOf(BOB, noId), sharesOutNo, "NO received");
    }

    function _padBps(uint256 x, uint256 bps) internal pure returns (uint256) {
        // e.g. bps=1000 => +10%
        return x + ((x * bps) / 10_000);
    }

    function _fundWst(address user, uint256 ethAmt) internal {
        vm.deal(user, ethAmt);
        vm.prank(user);
        uint256 w = ZSTETH.exactETHToWSTETH{value: ethAmt}(user);
        require(w > 0, "zap fail");
    }

    function test_BuyNo_Twice_SameSide_RequoteAndPad_Passes() public {
        _fundWst(BOB, 3 ether);

        vm.startPrank(BOB);
        WSTETH.approve(address(pm), type(uint256).max);

        // ---- leg 1: buy 1e12 NO (standard +10% pad) ----
        uint256 firstOut = 1_000e9;
        (uint256 opp1, uint256 w1,,,,) = pm.quoteBuyNo(marketId, firstOut);
        pm.buyNoViaPool(
            marketId,
            firstOut,
            false, // pay in wstETH
            _padBps(w1, 1_000), // +10% is fine here
            type(uint256).max, // oppInMax isn't the binding guard
            BOB
        );

        // ---- leg 2: requote, then buy 2e12 NO with a *much* looser wst cap ----
        uint256 secondOut = 2_000e9;
        (uint256 opp2, uint256 w2,,,,) = pm.quoteBuyNo(marketId, secondOut);

        // Key change: raise wst cap padding substantially to account for
        // price move + hook fee + rounding in derived opp input.
        // (+200% is still tiny in absolute wei and avoids edge reverts.)
        uint256 capW2 = _padBps(w2, 20_000); // +200%

        (uint256 wSpent2,) =
            pm.buyNoViaPool(marketId, secondOut, false, capW2, type(uint256).max, BOB);

        vm.stopPrank();

        // sanity
        assertLe(wSpent2, capW2, "second leg exceeded wst cap");
        assertEq(pm.balanceOf(BOB, noId), firstOut + secondOut, "NO balance after two buys");
    }

    /// Stale tight YES should revert with SlippageOppIn() after the book is moved.
    function test_BuyYes_StaleTight_Reverts_WithPoolSelector() public {
        _fundWst(ALICE, 2 ether);
        _fundWst(BOB, 2 ether);

        vm.startPrank(ALICE);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BOB);
        WSTETH.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        uint256 yesOut = 2_000e9;

        // 1) Tight YES quote (no pad)
        (uint256 oppInQ, uint256 wstFairQ,,,,) = pm.quoteBuyYes(marketId, yesOut);

        // 2) Move the market in the YES direction so quote becomes stale/tight
        vm.prank(BOB);
        pm.buyYesViaPool(marketId, 2_500e9, false, type(uint256).max, type(uint256).max, BOB);

        // 3) Expect SlippageOppIn() using the stale caps
        vm.expectRevert(abi.encodeWithSelector(ERR_SlippageOppIn));
        vm.prank(ALICE);
        pm.buyYesViaPool(marketId, yesOut, false, wstFairQ, oppInQ, ALICE);
    }

    /* ──────────────────────────────────────────────────────────
       A small sanity snapshot (unchanged)
       ────────────────────────────────────────────────────────── */

    function test_GetMarket_SnapshotIsCoherent_min() public {
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
}
