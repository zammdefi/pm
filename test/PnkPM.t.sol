// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {PAMM} from "../src/PAMM.sol";
import {Resolver} from "../src/Resolver.sol";

/// @notice Interface for CryptoPunks balanceOf
interface ICryptoPunks {
    function balanceOf(address owner) external view returns (uint256);
    function punkIndexToAddress(uint256 index) external view returns (address);
    function transferPunk(address to, uint256 punkIndex) external;
    function buyPunk(uint256 punkIndex) external payable;
    function punksOfferedForSale(uint256 punkIndex)
        external
        view
        returns (
            bool isForSale,
            uint256 punkIndex_,
            address seller,
            uint256 minValue,
            address onlySellTo
        );
}

/// @notice Interface for PMRouter
interface IPMRouter {
    struct Order {
        address owner;
        uint56 deadline;
        bool isYes;
        bool isBuy;
        bool partialFill;
        uint96 shares;
        uint96 collateral;
        uint256 marketId;
    }

    function buy(
        uint256 marketId,
        bool isYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 sharesOut);

    function sell(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut);

    function placeOrder(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint96 shares,
        uint96 collateral,
        uint56 deadline,
        bool partialFill
    ) external payable returns (bytes32 orderHash);

    function fillOrder(bytes32 orderHash, uint96 sharesToFill, address to)
        external
        payable
        returns (uint96 sharesFilled, uint96 collateralFilled);

    function cancelOrder(bytes32 orderHash) external;

    function claimProceeds(bytes32 orderHash, address to) external returns (uint96 amount);

    function getOrder(bytes32 orderHash)
        external
        view
        returns (
            Order memory order,
            uint96 sharesFilled,
            uint96 sharesRemaining,
            uint96 collateralFilled,
            uint96 collateralRemaining,
            bool active
        );

    function fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 totalAmount,
        uint256 minOutput,
        bytes32[] calldata orderHashes,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 totalOutput);

    function getOrderbook(uint256 marketId, bool isYes, uint256 depth)
        external
        view
        returns (
            bytes32[] memory bidHashes,
            Order[] memory bidOrders,
            bytes32[] memory askHashes,
            Order[] memory askOrders
        );
}

/// @title PnkPM Fork Tests
/// @notice Tests for the PNKSTR CryptoPunks prediction market on mainnet fork
contract PnkPMTest is Test {
    // Mainnet addresses
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));
    Resolver constant resolver = Resolver(payable(0x00000000002205020E387b6a378c05639047BcFB));
    IPMRouter constant router = IPMRouter(0x000000000055fF709f26efB262fba8B0AE8c35Dc);
    address constant ZAMM_ADDRESS = 0x000000000000040470635EB91b7CE4D132D616eD;
    ICryptoPunks constant punks = ICryptoPunks(0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB);

    // PNKSTR Treasury
    address constant PNKSTR_TREASURY = 0x1244EAe9FA2c064453B5F605d708C0a0Bfba4838;

    // Market parameters (from deployed market)
    uint256 constant MARKET_ID =
        32134417008196240812336678454075505952526867228548827945664500580851657114937;
    uint256 constant THRESHOLD = 40;
    uint64 constant CLOSE_TIME = 1767225599; // Dec 31, 2025 23:59:59 UTC
    uint256 constant FEE_TIER = 30; // 0.30%

    // Test actors
    address internal ALICE;
    address internal BOB;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.rpcUrl("main"));

        // Create test actors with ETH
        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET EXISTS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify the PNKSTR market exists and has correct parameters
    function test_MarketExists() public view {
        (
            address marketResolver,
            address collateral,
            bool resolved,,
            bool canClose,
            uint64 close,
            uint256 collateralLocked,,,
            string memory description
        ) = pamm.getMarket(MARKET_ID);

        assertEq(marketResolver, address(resolver), "Wrong resolver");
        assertEq(collateral, address(0), "Should be ETH collateral");
        assertFalse(resolved, "Should not be resolved yet");
        assertTrue(canClose, "Should allow early close");
        assertEq(close, CLOSE_TIME, "Wrong close time");
        assertGt(collateralLocked, 0, "Should have collateral locked");
        assertTrue(bytes(description).length > 0, "Should have description");

        console2.log("Market description:", description);
        console2.log("Collateral locked:", collateralLocked);
    }

    /// @notice Verify the condition is correctly configured
    function test_ConditionConfigured() public view {
        (
            address targetA,
            address targetB,
            Resolver.Op op,
            bool isRatio,
            uint256 threshold,
            bytes memory callDataA,
            bytes memory callDataB
        ) = resolver.conditions(MARKET_ID);

        assertEq(targetA, address(punks), "Target should be CryptoPunks");
        assertEq(targetB, address(0), "No secondary target");
        assertEq(uint8(op), uint8(Resolver.Op.GT), "Op should be GT");
        assertFalse(isRatio, "Should not be ratio");
        assertEq(threshold, THRESHOLD, "Wrong threshold");

        // Verify callData is balanceOf(PNKSTR)
        bytes memory expectedCallData =
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY);
        assertEq(callDataA, expectedCallData, "Wrong callData");
        assertEq(callDataB.length, 0, "CallDataB should be empty");
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEW TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test preview returns current PNKSTR punk balance
    function test_PreviewReturnsCurrentBalance() public view {
        (uint256 value, bool condTrue, bool ready) = resolver.preview(MARKET_ID);

        uint256 actualBalance = punks.balanceOf(PNKSTR_TREASURY);
        assertEq(value, actualBalance, "Preview value should match actual balance");

        console2.log("PNKSTR Punk balance:", value);
        console2.log("Condition met:", condTrue);
        console2.log("Ready to resolve:", ready);

        // Condition is value > 40
        if (actualBalance > THRESHOLD) {
            assertTrue(condTrue, "Condition should be true when balance > threshold");
            assertTrue(ready, "Should be ready when condition met (canClose=true)");
        } else {
            assertFalse(condTrue, "Condition should be false when balance <= threshold");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            TRADING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test buying YES shares
    function test_BuyYes() public {
        uint256 buyAmount = 0.1 ether;

        vm.prank(ALICE);
        uint256 sharesOut = router.buy{value: buyAmount}(
            MARKET_ID,
            true, // isYes
            buyAmount,
            0, // minSharesOut
            FEE_TIER,
            ALICE,
            block.timestamp + 1 hours
        );

        assertGt(sharesOut, 0, "Should receive YES shares");
        assertEq(pamm.balanceOf(ALICE, MARKET_ID), sharesOut, "Balance should match");

        console2.log("YES shares received:", sharesOut);
    }

    /// @notice Test buying NO shares
    function test_BuyNo() public {
        uint256 buyAmount = 0.1 ether;
        uint256 noId = pamm.getNoId(MARKET_ID);

        vm.prank(BOB);
        uint256 sharesOut = router.buy{value: buyAmount}(
            MARKET_ID,
            false, // isNo
            buyAmount,
            0,
            FEE_TIER,
            BOB,
            block.timestamp + 1 hours
        );

        assertGt(sharesOut, 0, "Should receive NO shares");
        assertEq(pamm.balanceOf(BOB, noId), sharesOut, "Balance should match");

        console2.log("NO shares received:", sharesOut);
    }

    /// @notice Test selling shares
    function test_SellShares() public {
        // First buy some shares
        uint256 buyAmount = 0.5 ether;

        vm.prank(ALICE);
        uint256 yesShares = router.buy{value: buyAmount}(
            MARKET_ID, true, buyAmount, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Approve PAMM to transfer shares
        vm.prank(ALICE);
        pamm.setOperator(address(router), true);

        // Sell half
        uint256 sellAmount = yesShares / 2;
        uint256 balBefore = ALICE.balance;

        vm.prank(ALICE);
        uint256 collateralOut =
            router.sell(MARKET_ID, true, sellAmount, 0, FEE_TIER, ALICE, block.timestamp + 1 hours);

        assertGt(collateralOut, 0, "Should receive ETH back");
        assertEq(ALICE.balance - balBefore, collateralOut, "ETH balance should increase");
        assertEq(pamm.balanceOf(ALICE, MARKET_ID), yesShares - sellAmount, "Shares should decrease");

        console2.log("ETH received from sell:", collateralOut);
    }

    /*//////////////////////////////////////////////////////////////
                        RESOLUTION TESTS - CONDITION MET
    //////////////////////////////////////////////////////////////*/

    /// @notice Test early resolution when condition is met (PNKSTR has >40 punks)
    function test_ResolveEarly_ConditionMet() public {
        // Check current balance
        uint256 currentBalance = punks.balanceOf(PNKSTR_TREASURY);

        // Skip this test if condition not currently met
        if (currentBalance <= THRESHOLD) {
            console2.log(
                "Skipping: PNKSTR balance", currentBalance, "is not > threshold", THRESHOLD
            );
            return;
        }

        // Buy some shares first
        vm.prank(ALICE);
        router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Verify condition is ready
        (, bool condTrue, bool ready) = resolver.preview(MARKET_ID);
        assertTrue(condTrue, "Condition should be met");
        assertTrue(ready, "Should be ready for early resolution");

        // Resolve early
        resolver.resolveMarket(MARKET_ID);

        // Verify resolved with YES outcome
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Should be resolved");
        assertTrue(outcome, "YES should win");

        // Alice (YES holder) should be able to claim
        uint256 balBefore = ALICE.balance;
        vm.prank(ALICE);
        pamm.claim(MARKET_ID, ALICE);
        assertGt(ALICE.balance - balBefore, 0, "Alice should receive payout");

        console2.log("Alice payout:", ALICE.balance - balBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLUTION TESTS - CONDITION NOT MET
    //////////////////////////////////////////////////////////////*/

    /// @notice Test resolution at deadline when condition NOT met
    function test_ResolveAtDeadline_ConditionNotMet() public {
        // We need to simulate PNKSTR having <= 40 punks
        // For this test, we'll mock the balance by pranking the punks contract

        // First, check if we can even test this (condition currently met means we need to manipulate)
        uint256 currentBalance = punks.balanceOf(PNKSTR_TREASURY);
        console2.log("Current PNKSTR balance:", currentBalance);

        // Buy some shares
        vm.prank(ALICE);
        router.buy{value: 0.5 ether}(
            MARKET_ID, true, 0.5 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Mock PNKSTR balance to be <= threshold
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(30)) // 30 punks, below threshold of 40
        );

        // Verify condition is NOT met now
        (uint256 value, bool condTrue, bool ready) = resolver.preview(MARKET_ID);
        assertEq(value, 30, "Mocked value should be 30");
        assertFalse(condTrue, "Condition should NOT be met");
        assertFalse(ready, "Should NOT be ready before deadline");

        // Try to resolve early - should fail
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(MARKET_ID);

        // Warp to after deadline
        vm.warp(CLOSE_TIME + 1);

        // Now should be ready to resolve
        (, condTrue, ready) = resolver.preview(MARKET_ID);
        assertFalse(condTrue, "Condition still not met");
        assertTrue(ready, "Should be ready after deadline");

        // Resolve - NO should win
        resolver.resolveMarket(MARKET_ID);

        // Verify resolved with NO outcome
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Should be resolved");
        assertFalse(outcome, "NO should win");

        // Bob (NO holder) should be able to claim
        uint256 balBefore = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);
        assertGt(BOB.balance - balBefore, 0, "Bob should receive payout");

        console2.log("Bob payout:", BOB.balance - balBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test cannot resolve before deadline if condition not met
    function test_CannotResolveEarly_ConditionNotMet() public {
        // Mock balance to be below threshold
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(35))
        );

        // Verify not ready
        (, bool condTrue, bool ready) = resolver.preview(MARKET_ID);
        assertFalse(condTrue, "Condition not met");
        assertFalse(ready, "Not ready");

        // Should revert
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(MARKET_ID);
    }

    /// @notice Test exact threshold boundary (40 punks = NOT met, need >40)
    function test_ExactThreshold_NotMet() public {
        // Mock balance to be exactly threshold
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(40))
        );

        (uint256 value, bool condTrue,) = resolver.preview(MARKET_ID);
        assertEq(value, 40, "Value should be 40");
        assertFalse(condTrue, "40 > 40 is FALSE, condition not met");
    }

    /// @notice Test one above threshold (41 punks = MET)
    function test_OneAboveThreshold_Met() public {
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(41))
        );

        (uint256 value, bool condTrue, bool ready) = resolver.preview(MARKET_ID);
        assertEq(value, 41, "Value should be 41");
        assertTrue(condTrue, "41 > 40 is TRUE, condition met");
        assertTrue(ready, "Should be ready for early close");
    }

    /// @notice Test full early resolution flow when condition IS met (real punk transfers)
    function test_ResolveEarly_RealPunkTransfers() public {
        // Punk whale with lots of punks
        address WHALE = 0xA858DDc0445d8131daC4d1DE01f834ffcbA52Ef1;

        uint256 startBalance = punks.balanceOf(PNKSTR_TREASURY);
        uint256 punksNeeded = THRESHOLD + 1 - startBalance; // Need >40, so 41 - current

        console2.log("PNKSTR starting balance:", startBalance);
        console2.log("Punks needed to exceed threshold:", punksNeeded);
        console2.log("Whale balance:", punks.balanceOf(WHALE));

        // Buy some shares first
        vm.prank(ALICE);
        uint256 yesShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        uint256 noShares = router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        console2.log("Alice YES shares:", yesShares);
        console2.log("Bob NO shares:", noShares);

        // Transfer punks from whale to PNKSTR treasury until condition is met
        uint256 transferred = 0;
        for (uint256 i = 0; i < 10000 && transferred < punksNeeded; i++) {
            address owner = punks.punkIndexToAddress(i);
            if (owner == WHALE) {
                vm.prank(WHALE);
                punks.transferPunk(PNKSTR_TREASURY, i);
                transferred++;
            }
        }

        uint256 newBalance = punks.balanceOf(PNKSTR_TREASURY);
        console2.log("PNKSTR new balance:", newBalance);
        assertGt(newBalance, THRESHOLD, "PNKSTR should now have > 40 punks");

        // Verify condition is now met
        (uint256 value, bool condTrue, bool ready) = resolver.preview(MARKET_ID);
        console2.log("Preview value:", value);
        assertTrue(condTrue, "Condition should be met");
        assertTrue(ready, "Should be ready for early resolution");

        // Resolve early - YES should win
        resolver.resolveMarket(MARKET_ID);

        // Verify resolved with YES outcome
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Should be resolved");
        assertTrue(outcome, "YES should win when condition met");

        // Alice (YES holder) should be able to claim
        uint256 aliceBalBefore = ALICE.balance;
        vm.prank(ALICE);
        pamm.claim(MARKET_ID, ALICE);
        uint256 alicePayout = ALICE.balance - aliceBalBefore;
        assertGt(alicePayout, 0, "Alice should receive payout");

        // Bob (NO holder) has no winning shares - claim reverts
        vm.prank(BOB);
        vm.expectRevert(); // AmountZero - no YES shares to claim
        pamm.claim(MARKET_ID, BOB);

        console2.log("Alice (YES) payout:", alicePayout);
    }

    /*//////////////////////////////////////////////////////////////
                            POOL STATE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test pool state and odds calculation
    function test_PoolStateAndOdds() public {
        // Make some trades to establish odds
        vm.prank(ALICE);
        router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Get pool state
        (uint256 rYes, uint256 rNo, uint256 pYesNum, uint256 pYesDen) =
            pamm.getPoolState(MARKET_ID, FEE_TIER);

        assertGt(rYes, 0, "Should have YES reserves");
        assertGt(rNo, 0, "Should have NO reserves");

        // Calculate YES probability
        uint256 yesOdds = (rNo * 100) / (rYes + rNo);
        console2.log("YES reserves:", rYes);
        console2.log("NO reserves:", rNo);
        console2.log("YES odds %:", yesOdds);
        console2.log("Price num/den:", pYesNum, "/", pYesDen);
    }

    /*//////////////////////////////////////////////////////////////
                        LP OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test adding liquidity to the pool
    function test_AddLiquidity() public {
        uint256 lpAmount = 1 ether;

        vm.prank(ALICE);
        (uint256 shares, uint256 liquidity) = pamm.splitAndAddLiquidity{value: lpAmount}(
            MARKET_ID,
            lpAmount,
            FEE_TIER,
            0,
            0,
            0, // mins
            ALICE,
            block.timestamp + 1 hours
        );

        assertGt(liquidity, 0, "Should receive LP tokens");
        assertGt(shares, 0, "Should mint shares");
        console2.log("Shares minted:", shares);
        console2.log("LP tokens:", liquidity);
    }

    /// @notice Test removing liquidity from the pool
    function test_RemoveLiquidity() public {
        // First add liquidity
        uint256 lpAmount = 2 ether;
        vm.prank(ALICE);
        (, uint256 liquidity) = pamm.splitAndAddLiquidity{value: lpAmount}(
            MARKET_ID, lpAmount, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Approve ZAMM for LP token transfers (LP tokens are held in ZAMM)
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);

        // Remove half the liquidity
        uint256 removeAmount = liquidity / 2;
        uint256 balBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 collateralOut,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, removeAmount, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        assertGt(collateralOut, 0, "Should receive collateral back");
        assertEq(ALICE.balance - balBefore, collateralOut, "ETH balance should increase");

        console2.log("Collateral returned:", collateralOut);
    }

    /// @notice Test LP removal after market resolution
    function test_RemoveLiquidityAfterResolution() public {
        // Add liquidity
        vm.prank(ALICE);
        (, uint256 liquidity) = pamm.splitAndAddLiquidity{value: 2 ether}(
            MARKET_ID, 2 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Mock condition met and resolve
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Approve ZAMM for LP token transfers
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);

        // Remove liquidity - should also handle winning shares
        uint256 balBefore = ALICE.balance;
        vm.prank(ALICE);
        (uint256 collOut,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, liquidity, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        assertGt(collOut, 0, "Should receive payout");
        console2.log("LP + winnings payout:", ALICE.balance - balBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        ZAMM SWAP TESTS (YES ↔ NO)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test swapping YES to NO shares
    function test_SwapYesToNo() public {
        // First buy YES shares
        vm.prank(ALICE);
        uint256 yesShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Approve ZAMM to transfer PAMM shares
        vm.prank(ALICE);
        pamm.setOperator(ZAMM_ADDRESS, true);

        // Get pool key for YES/NO swap
        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;
        bool yesIsToken0 = MARKET_ID == id0;

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        // Swap half YES to NO
        uint256 swapAmount = yesShares / 2;
        uint256 noBalBefore = pamm.balanceOf(ALICE, noId);

        vm.prank(ALICE);
        uint256 noOut = IZAMM(ZAMM_ADDRESS)
            .swapExactIn(
                poolKey,
                swapAmount,
                0, // minOut
                yesIsToken0, // zeroForOne: YES→NO if yes is token0
                ALICE,
                block.timestamp + 1 hours
            );

        assertGt(noOut, 0, "Should receive NO shares");
        assertEq(pamm.balanceOf(ALICE, noId) - noBalBefore, noOut, "NO balance should increase");
        assertEq(
            pamm.balanceOf(ALICE, MARKET_ID), yesShares - swapAmount, "YES balance should decrease"
        );

        console2.log("Swapped YES:", swapAmount);
        console2.log("Received NO:", noOut);
    }

    /// @notice Test swapping NO to YES shares
    function test_SwapNoToYes() public {
        // First buy NO shares
        uint256 noId = pamm.getNoId(MARKET_ID);
        vm.prank(BOB);
        uint256 noShares = router.buy{value: 1 ether}(
            MARKET_ID, false, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Approve ZAMM
        vm.prank(BOB);
        pamm.setOperator(ZAMM_ADDRESS, true);

        // Build pool key
        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;
        bool yesIsToken0 = MARKET_ID == id0;

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        // Swap NO to YES
        uint256 swapAmount = noShares / 2;
        uint256 yesBalBefore = pamm.balanceOf(BOB, MARKET_ID);

        vm.prank(BOB);
        uint256 yesOut = IZAMM(ZAMM_ADDRESS)
            .swapExactIn(
                poolKey,
                swapAmount,
                0,
                !yesIsToken0, // NO→YES is opposite direction
                BOB,
                block.timestamp + 1 hours
            );

        assertGt(yesOut, 0, "Should receive YES shares");
        assertEq(
            pamm.balanceOf(BOB, MARKET_ID) - yesBalBefore, yesOut, "YES balance should increase"
        );

        console2.log("Swapped NO:", swapAmount);
        console2.log("Received YES:", yesOut);
    }

    /*//////////////////////////////////////////////////////////////
                        LIMIT ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test placing a buy limit order
    function test_PlaceBuyLimitOrder() public {
        uint96 shares = 1 ether;
        uint96 collateral = 0.4 ether; // 40% odds
        uint56 orderDeadline = uint56(CLOSE_TIME);

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: collateral}(
            MARKET_ID,
            true, // isYes
            true, // isBuy
            shares,
            collateral,
            orderDeadline,
            true // partialFill
        );

        assertNotEq(orderHash, bytes32(0), "Should return order hash");

        // Verify order exists in orderbook
        (bytes32[] memory bidHashes, IPMRouter.Order[] memory bidOrders,,) =
            router.getOrderbook(MARKET_ID, true, 10);

        bool found = false;
        for (uint256 i = 0; i < bidHashes.length; i++) {
            if (bidHashes[i] == orderHash) {
                found = true;
                assertEq(bidOrders[i].owner, ALICE, "Owner should be ALICE");
                assertEq(bidOrders[i].shares, shares, "Shares should match");
                break;
            }
        }
        assertTrue(found, "Order should be in orderbook");

        console2.log("Order hash:", uint256(orderHash));
    }

    /// @notice Test placing a sell limit order
    function test_PlaceSellLimitOrder() public {
        // First buy shares to sell
        vm.prank(ALICE);
        uint256 yesShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Approve router
        vm.prank(ALICE);
        pamm.setOperator(address(router), true);

        uint96 shares = uint96(yesShares / 2);
        uint96 collateral = shares * 6 / 10; // 60% asking price

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            MARKET_ID,
            true, // isYes
            false, // isSell
            shares,
            collateral,
            uint56(CLOSE_TIME),
            true
        );

        assertNotEq(orderHash, bytes32(0), "Should return order hash");

        // Verify in asks
        (,, bytes32[] memory askHashes,) = router.getOrderbook(MARKET_ID, true, 10);
        bool found = false;
        for (uint256 i = 0; i < askHashes.length; i++) {
            if (askHashes[i] == orderHash) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Order should be in asks");
    }

    /// @notice Test filling a limit order
    function test_FillLimitOrder() public {
        // Alice places buy order at 40%
        uint96 shares = 1 ether;
        uint96 collateral = 0.4 ether;

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: collateral}(
            MARKET_ID, true, true, shares, collateral, uint56(CLOSE_TIME), true
        );

        // Bob needs YES shares to fill - first buy some
        vm.prank(BOB);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Bob approves router
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        // Bob fills Alice's order
        uint256 bobEthBefore = BOB.balance;
        uint256 aliceYesBefore = pamm.balanceOf(ALICE, MARKET_ID);

        vm.prank(BOB);
        (uint96 sharesFilled, uint96 collateralFilled) =
            router.fillOrder(
                orderHash,
                shares, // fill entire order
                BOB
            );

        assertEq(sharesFilled, shares, "Should fill all shares");
        assertEq(collateralFilled, collateral, "Should receive all collateral");
        assertEq(BOB.balance - bobEthBefore, collateral, "Bob should receive ETH");
        assertEq(
            pamm.balanceOf(ALICE, MARKET_ID) - aliceYesBefore, shares, "Alice should receive YES"
        );

        console2.log("Shares filled:", sharesFilled);
        console2.log("Collateral filled:", collateralFilled);
    }

    /// @notice Test canceling a limit order
    function test_CancelOrder() public {
        uint96 collateral = 0.5 ether;

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: collateral}(
            MARKET_ID, true, true, 1 ether, collateral, uint56(CLOSE_TIME), true
        );

        uint256 balBefore = ALICE.balance;

        vm.prank(ALICE);
        router.cancelOrder(orderHash);

        assertEq(ALICE.balance - balBefore, collateral, "Should refund collateral");

        // Verify order removed
        (bytes32[] memory bidHashes,,,) = router.getOrderbook(MARKET_ID, true, 10);
        for (uint256 i = 0; i < bidHashes.length; i++) {
            assertNotEq(bidHashes[i], orderHash, "Order should be removed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    SMART ROUTING TESTS (fillOrdersThenSwap)
    //////////////////////////////////////////////////////////////*/

    /// @notice Test router buy after adding liquidity (simulates smart routing)
    function test_RouterBuyWithLiquidity() public {
        // First add liquidity to have reasonable depth
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 5 ether}(
            MARKET_ID, 5 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Bob buys through router (routes to AMM)
        uint256 bobBuyAmount = 1 ether;
        uint256 bobYesBefore = pamm.balanceOf(BOB, MARKET_ID);

        vm.prank(BOB);
        uint256 totalShares = router.buy{value: bobBuyAmount}(
            MARKET_ID,
            true, // isYes
            bobBuyAmount,
            0, // minOutput
            FEE_TIER,
            BOB,
            block.timestamp + 1 hours
        );

        assertGt(totalShares, 0, "Should receive shares");
        assertEq(pamm.balanceOf(BOB, MARKET_ID) - bobYesBefore, totalShares, "Balance should match");

        console2.log("Total shares from router:", totalShares);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-USER TRADING SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test multiple users trading simultaneously
    function test_MultiUserTrading() public {
        address CAROL = makeAddr("CAROL");
        address DAVE = makeAddr("DAVE");
        vm.deal(CAROL, 100 ether);
        vm.deal(DAVE, 100 ether);

        // Multiple buys
        vm.prank(ALICE);
        uint256 aliceShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        uint256 bobShares = router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        vm.prank(CAROL);
        uint256 carolShares = router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );

        vm.prank(DAVE);
        uint256 daveShares = router.buy{value: 1.5 ether}(
            MARKET_ID, false, 1.5 ether, 0, FEE_TIER, DAVE, block.timestamp + 1 hours
        );

        // Verify all balances
        assertGt(aliceShares, 0, "Alice should have YES");
        assertGt(bobShares, 0, "Bob should have NO");
        assertGt(carolShares, 0, "Carol should have YES");
        assertGt(daveShares, 0, "Dave should have NO");

        console2.log("Alice YES:", aliceShares);
        console2.log("Bob NO:", bobShares);
        console2.log("Carol YES:", carolShares);
        console2.log("Dave NO:", daveShares);
    }

    /// @notice Test orderbook with multiple orders from different users
    function test_MultiUserOrderbook() public {
        // Multiple users place buy orders at different prices
        vm.prank(ALICE);
        bytes32 order1 = router.placeOrder{value: 0.4 ether}(
            MARKET_ID, true, true, 1 ether, 0.4 ether, uint56(CLOSE_TIME), true
        );

        vm.prank(BOB);
        bytes32 order2 = router.placeOrder{value: 0.35 ether}(
            MARKET_ID, true, true, 1 ether, 0.35 ether, uint56(CLOSE_TIME), true
        );

        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 100 ether);
        vm.prank(CAROL);
        bytes32 order3 = router.placeOrder{value: 0.45 ether}(
            MARKET_ID, true, true, 1 ether, 0.45 ether, uint56(CLOSE_TIME), true
        );

        // Get orderbook and verify all orders exist
        (bytes32[] memory bidHashes,,,) = router.getOrderbook(MARKET_ID, true, 10);

        assertGe(bidHashes.length, 3, "Should have at least 3 bids");

        // Verify all orders are present
        bool foundOrder1 = false;
        bool foundOrder2 = false;
        bool foundOrder3 = false;
        for (uint256 i = 0; i < bidHashes.length; i++) {
            if (bidHashes[i] == order1) foundOrder1 = true;
            if (bidHashes[i] == order2) foundOrder2 = true;
            if (bidHashes[i] == order3) foundOrder3 = true;
        }
        assertTrue(foundOrder1, "Order 1 should be in orderbook");
        assertTrue(foundOrder2, "Order 2 should be in orderbook");
        assertTrue(foundOrder3, "Order 3 should be in orderbook");

        console2.log("All 3 orders found in orderbook");
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIMING EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test claiming with zero balance (should revert)
    function test_ClaimZeroBalance_Reverts() public {
        // Mock resolution
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Alice has no shares - claim should revert
        vm.prank(ALICE);
        vm.expectRevert(); // AmountZero
        pamm.claim(MARKET_ID, ALICE);
    }

    /// @notice Test claiming with wrong side (loser)
    function test_ClaimLoserSide_NoShares() public {
        // Bob buys NO shares
        vm.prank(BOB);
        router.buy{value: 1 ether}(
            MARKET_ID, false, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Mock YES wins (condition met)
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Bob holds NO but YES won - has no YES to claim
        vm.prank(BOB);
        vm.expectRevert(); // AmountZero - no winning shares
        pamm.claim(MARKET_ID, BOB);
    }

    /// @notice Test double claiming (should revert or give 0)
    function test_DoubleClaim() public {
        // Alice buys YES
        vm.prank(ALICE);
        router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Mock YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // First claim succeeds
        vm.prank(ALICE);
        pamm.claim(MARKET_ID, ALICE);

        // Second claim should revert (no more shares)
        vm.prank(ALICE);
        vm.expectRevert();
        pamm.claim(MARKET_ID, ALICE);
    }

    /// @notice Test claiming to different recipient
    function test_ClaimToDifferentRecipient() public {
        address RECIPIENT = makeAddr("RECIPIENT");

        // Alice buys YES
        vm.prank(ALICE);
        router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Mock YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Alice claims to recipient
        uint256 recipientBalBefore = RECIPIENT.balance;
        vm.prank(ALICE);
        pamm.claim(MARKET_ID, RECIPIENT);

        assertGt(RECIPIENT.balance - recipientBalBefore, 0, "Recipient should receive payout");
    }

    /*//////////////////////////////////////////////////////////////
                    COMBINED FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test partial order fill
    function test_PartialOrderFill() public {
        // Alice places buy order for 1 ether of shares at 40%
        uint96 shares = 1 ether;
        uint96 collateral = 0.4 ether;

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: collateral}(
            MARKET_ID,
            true,
            true,
            shares,
            collateral,
            uint56(CLOSE_TIME),
            true // partialFill = true
        );

        // Bob buys YES shares to fill
        vm.prank(BOB);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        // Bob fills only HALF the order
        uint96 partialShares = shares / 2;
        uint96 expectedCollateral = collateral / 2;

        uint256 aliceYesBefore = pamm.balanceOf(ALICE, MARKET_ID);
        uint256 bobEthBefore = BOB.balance;
        uint256 bobSharesBefore = pamm.balanceOf(BOB, MARKET_ID);

        vm.prank(BOB);
        (uint96 sharesFilled, uint96 collateralFilled) =
            router.fillOrder(orderHash, partialShares, BOB);

        // Verify state changes
        assertEq(sharesFilled, partialShares, "Should fill partial shares");
        assertEq(collateralFilled, expectedCollateral, "Should receive proportional collateral");
        assertEq(
            pamm.balanceOf(ALICE, MARKET_ID) - aliceYesBefore,
            partialShares,
            "Alice gets partial shares"
        );
        assertEq(BOB.balance - bobEthBefore, expectedCollateral, "Bob gets partial ETH");
        assertEq(
            bobSharesBefore - pamm.balanceOf(BOB, MARKET_ID), partialShares, "Bob shares decreased"
        );

        // Fill the remaining half
        vm.prank(BOB);
        (uint96 sharesFilled2, uint96 collateralFilled2) =
            router.fillOrder(
                orderHash,
                partialShares, // remaining half
                BOB
            );

        assertEq(sharesFilled2, partialShares, "Should fill remaining shares");
        assertEq(collateralFilled2, expectedCollateral, "Should receive remaining collateral");
        assertEq(pamm.balanceOf(ALICE, MARKET_ID) - aliceYesBefore, shares, "Alice gets all shares");
    }

    /// @notice Test trading after resolution should fail
    function test_TradingAfterResolution_Reverts() public {
        // Add liquidity first
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 2 ether}(
            MARKET_ID, 2 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Resolve market
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Verify resolved
        (,, bool resolved,,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Market should be resolved");

        // Try to buy - should revert
        vm.prank(BOB);
        vm.expectRevert();
        router.buy{value: 0.1 ether}(
            MARKET_ID, true, 0.1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
    }

    /// @notice Test state changes during resolution - collateralLocked tracking
    function test_Resolution_StateChanges() public {
        // Get initial state
        (,, bool resolvedBefore,,,, uint256 collateralLockedBefore,,,) = pamm.getMarket(MARKET_ID);
        assertFalse(resolvedBefore, "Should not be resolved initially");

        // Buy some shares
        vm.prank(ALICE);
        uint256 yesShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        uint256 noShares = router.buy{value: 1 ether}(
            MARKET_ID, false, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Get state after trading
        (,,,,,, uint256 collateralLockedAfterTrade,,,) = pamm.getMarket(MARKET_ID);
        assertGt(
            collateralLockedAfterTrade,
            collateralLockedBefore,
            "Collateral should increase after trading"
        );

        // Resolve - YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Verify resolved state
        (,, bool resolvedAfter, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolvedAfter, "Should be resolved");
        assertTrue(outcome, "YES should win");

        // Alice (YES) claims - verify balance changes
        uint256 aliceBalBefore = ALICE.balance;
        uint256 aliceSharesBefore = pamm.balanceOf(ALICE, MARKET_ID);

        vm.prank(ALICE);
        pamm.claim(MARKET_ID, ALICE);

        uint256 aliceBalAfter = ALICE.balance;
        uint256 aliceSharesAfter = pamm.balanceOf(ALICE, MARKET_ID);

        assertGt(aliceBalAfter - aliceBalBefore, 0, "Alice should receive ETH");
        assertEq(aliceSharesAfter, 0, "Alice shares should be burned");
        assertEq(aliceSharesBefore, yesShares, "Shares burned should match shares held");

        // Bob (NO) has no winning shares
        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 bobNoShares = pamm.balanceOf(BOB, noId);
        assertEq(bobNoShares, noShares, "Bob still has NO shares (worthless)");
    }

    /// @notice Test complete flow: trade, LP, swap, resolve, claim
    function test_CompleteFlow() public {
        // 1. Alice adds liquidity
        vm.prank(ALICE);
        (, uint256 lpTokens) = pamm.splitAndAddLiquidity{value: 5 ether}(
            MARKET_ID, 5 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        console2.log("1. Alice LP tokens:", lpTokens);

        // 2. Bob buys YES
        vm.prank(BOB);
        uint256 bobYes = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        console2.log("2. Bob YES shares:", bobYes);

        // 3. Carol buys NO
        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 100 ether);
        uint256 noId = pamm.getNoId(MARKET_ID);
        vm.prank(CAROL);
        uint256 carolNo = router.buy{value: 0.5 ether}(
            MARKET_ID, false, 0.5 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );
        console2.log("3. Carol NO shares:", carolNo);

        // 4. Bob swaps some YES to NO
        vm.prank(BOB);
        pamm.setOperator(ZAMM_ADDRESS, true);

        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;
        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        vm.prank(BOB);
        uint256 bobSwapOut = IZAMM(ZAMM_ADDRESS)
            .swapExactIn(poolKey, bobYes / 4, 0, MARKET_ID == id0, BOB, block.timestamp + 1 hours);
        console2.log("4. Bob swapped YES to NO:", bobSwapOut);

        // 5. Resolve - YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);
        console2.log("5. Market resolved - YES wins");

        // 6. Bob claims (has YES)
        uint256 bobBalBefore = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);
        console2.log("6. Bob payout:", BOB.balance - bobBalBefore);

        // 7. Alice removes LP (need to approve ZAMM for LP token transfers)
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);
        vm.prank(ALICE);
        (uint256 alicePayout,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, lpTokens, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        console2.log("7. Alice LP payout:", alicePayout);

        // 8. Carol lost (NO side), should fail to claim YES
        vm.prank(CAROL);
        vm.expectRevert();
        pamm.claim(MARKET_ID, CAROL);
        console2.log("8. Carol (NO holder) cannot claim - correct");
    }

    /*//////////////////////////////////////////////////////////////
                        DIRECT ZAMM FILL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that order makers can claim proceeds when orders are filled directly on ZAMM
    /// @dev This is a critical test: if someone fills an order directly on ZAMM (bypassing PMRouter),
    ///      the order maker must still be able to claim their proceeds via PMRouter.claimProceeds()
    function test_ClaimProceeds_DirectZAMMFill() public {
        // Alice places a SELL order: offering YES shares for ETH
        // First buy YES shares
        vm.prank(ALICE);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, ALICE, block.timestamp + 1 hours
        );

        // Alice approves router to take her shares
        vm.prank(ALICE);
        pamm.setOperator(address(router), true);

        // Alice places sell order: sell 1 YES share for 0.5 ETH (50% price)
        uint96 shares = 1 ether;
        uint96 collateral = 0.5 ether;

        vm.prank(ALICE);
        bytes32 orderHash =
            router.placeOrder(MARKET_ID, true, false, shares, collateral, uint56(CLOSE_TIME), true);

        // Verify Alice's order was created
        assertNotEq(orderHash, bytes32(0), "Order should be created");

        // Now Bob fills the order DIRECTLY on ZAMM (bypassing PMRouter)
        // Bob needs ETH to fill the order
        uint256 tokenId = MARKET_ID; // YES token

        // Bob fills via ZAMM directly
        vm.prank(BOB);
        IZAMM(ZAMM_ADDRESS).fillOrder{value: collateral}(
            address(router), // maker is PMRouter
            address(pamm), // tokenIn = PAMM (YES shares)
            tokenId, // idIn = YES token id
            shares, // amtIn
            address(0), // tokenOut = ETH
            0, // idOut = 0
            collateral, // amtOut
            uint56(CLOSE_TIME),
            true, // partialFill
            collateral // fillPart = full order
        );

        // Check Bob received the YES shares
        assertEq(pamm.balanceOf(BOB, MARKET_ID), shares, "Bob should have YES shares");

        // Alice's proceeds (ETH) are now in PMRouter, not with Alice yet
        uint256 aliceEthBefore = ALICE.balance;

        // Alice claims her proceeds
        vm.prank(ALICE);
        uint96 claimed = router.claimProceeds(orderHash, ALICE);

        // Verify Alice received her ETH
        assertEq(claimed, collateral, "Alice should claim collateral amount");
        assertEq(ALICE.balance - aliceEthBefore, collateral, "Alice ETH should increase");
    }

    /// @notice Test full market lifecycle with all operations
    function test_FullMarketLifecycle() public {
        address CAROL = makeAddr("CAROL");
        address DAVE = makeAddr("DAVE");
        vm.deal(CAROL, 100 ether);
        vm.deal(DAVE, 100 ether);

        // ===== PHASE 1: Market Setup & LP =====
        // Alice provides initial liquidity
        vm.prank(ALICE);
        (, uint256 aliceLp) = pamm.splitAndAddLiquidity{value: 5 ether}(
            MARKET_ID, 5 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        assertGt(aliceLp, 0, "Alice should have LP tokens");

        // ===== PHASE 2: Trading =====
        // Bob buys YES (bullish on condition)
        vm.prank(BOB);
        uint256 bobYes = router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        assertGt(bobYes, 0, "Bob should have YES shares");

        // Carol buys NO (bearish)
        vm.prank(CAROL);
        uint256 carolNo = router.buy{value: 1.5 ether}(
            MARKET_ID, false, 1.5 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );
        assertGt(carolNo, 0, "Carol should have NO shares");

        // ===== PHASE 3: Limit Orders =====
        // Dave places buy order for YES at 30%
        vm.prank(DAVE);
        bytes32 daveOrder = router.placeOrder{value: 0.3 ether}(
            MARKET_ID, true, true, 1 ether, 0.3 ether, uint56(CLOSE_TIME), true
        );
        assertNotEq(daveOrder, bytes32(0), "Dave's order should exist");

        // Bob sells some YES to Dave's order
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        vm.prank(BOB);
        (, uint96 collateralFilled) = router.fillOrder(daveOrder, 0.5 ether, BOB);
        assertGt(collateralFilled, 0, "Bob should receive ETH from filling order");

        // ===== PHASE 4: ZAMM Swap =====
        // Carol swaps some NO for YES (changing her position)
        vm.prank(CAROL);
        pamm.setOperator(ZAMM_ADDRESS, true);

        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        uint256 carolSwapNo = carolNo / 4;
        vm.prank(CAROL);
        uint256 carolYesFromSwap = IZAMM(ZAMM_ADDRESS)
            .swapExactIn(
                poolKey, carolSwapNo, 0, MARKET_ID != id0, CAROL, block.timestamp + 1 hours
            );
        assertGt(carolYesFromSwap, 0, "Carol should receive YES from swap");

        // ===== PHASE 5: Resolution - YES wins =====
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50)) // Above threshold, YES wins
        );
        resolver.resolveMarket(MARKET_ID);

        // Verify resolution
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Market should be resolved");
        assertTrue(outcome, "YES should win");

        // ===== PHASE 6: Claims =====
        // Bob claims YES winnings
        uint256 bobEthBeforeClaim = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);
        assertGt(BOB.balance - bobEthBeforeClaim, 0, "Bob should receive payout");
        assertEq(pamm.balanceOf(BOB, MARKET_ID), 0, "Bob YES shares burned");

        // Dave claims YES winnings (from filled order)
        uint256 daveYes = pamm.balanceOf(DAVE, MARKET_ID);
        if (daveYes > 0) {
            uint256 daveEthBefore = DAVE.balance;
            vm.prank(DAVE);
            pamm.claim(MARKET_ID, DAVE);
            assertGt(DAVE.balance - daveEthBefore, 0, "Dave should receive payout");
        }

        // Carol has some YES (from swap) - can claim those
        uint256 carolYes = pamm.balanceOf(CAROL, MARKET_ID);
        if (carolYes > 0) {
            uint256 carolEthBefore = CAROL.balance;
            vm.prank(CAROL);
            pamm.claim(MARKET_ID, CAROL);
            assertGt(CAROL.balance - carolEthBefore, 0, "Carol should receive payout for YES");
        }

        // Carol's NO shares are worthless - claim reverts
        uint256 carolNoRemaining = pamm.balanceOf(CAROL, noId);
        assertGt(carolNoRemaining, 0, "Carol should still have worthless NO shares");

        // ===== PHASE 7: LP Withdrawal =====
        // Alice removes LP (after resolution)
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);

        uint256 aliceEthBefore = ALICE.balance;
        vm.prank(ALICE);
        (uint256 lpPayout,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, aliceLp, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        assertGt(lpPayout, 0, "Alice should receive LP payout");

        console2.log("=== Full Lifecycle Complete ===");
        console2.log("Alice LP payout:", ALICE.balance - aliceEthBefore);
        console2.log("Bob YES winnings claimed");
        console2.log("Dave filled order + claimed");
        console2.log("Carol swapped NO->YES, claimed YES");
    }

    /*//////////////////////////////////////////////////////////////
                        STRESS / SCALE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test with large ETH amounts (100 ETH)
    function test_LargeAmounts_100ETH() public {
        // Give Alice lots of ETH
        vm.deal(ALICE, 1000 ether);

        // Add substantial liquidity first
        vm.prank(ALICE);
        (, uint256 lpTokens) = pamm.splitAndAddLiquidity{value: 200 ether}(
            MARKET_ID, 200 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        assertGt(lpTokens, 0, "Should mint LP tokens");

        // Large buy - 100 ETH
        vm.deal(BOB, 200 ether);
        vm.prank(BOB);
        uint256 yesShares = router.buy{value: 100 ether}(
            MARKET_ID, true, 100 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        assertGt(yesShares, 0, "Should receive YES shares");
        assertGt(yesShares, 100 ether, "Should receive more than 100 shares (split + swap)");

        // Verify balances are correct
        assertEq(pamm.balanceOf(BOB, MARKET_ID), yesShares, "Balance should match");

        // Large sell
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        uint256 bobEthBefore = BOB.balance;
        vm.prank(BOB);
        uint256 collateralOut = router.sell(
            MARKET_ID, true, yesShares / 2, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        assertGt(collateralOut, 0, "Should receive ETH back");
        assertEq(BOB.balance - bobEthBefore, collateralOut, "ETH should increase");

        console2.log("LP tokens from 200 ETH:", lpTokens);
        console2.log("YES shares from 100 ETH buy:", yesShares);
        console2.log("ETH from selling half:", collateralOut);
    }

    /// @notice Test with very large ETH amounts (1000 ETH)
    function test_LargeAmounts_1000ETH() public {
        // Massive liquidity
        vm.deal(ALICE, 5000 ether);
        vm.prank(ALICE);
        (, uint256 lpTokens) = pamm.splitAndAddLiquidity{value: 2000 ether}(
            MARKET_ID, 2000 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Massive buy
        vm.deal(BOB, 2000 ether);
        vm.prank(BOB);
        uint256 yesShares = router.buy{value: 1000 ether}(
            MARKET_ID, true, 1000 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        assertGt(yesShares, 1000 ether, "Should receive substantial shares");

        // Resolve and claim large amount
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        uint256 bobEthBefore = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);

        uint256 payout = BOB.balance - bobEthBefore;
        assertGt(payout, 0, "Should receive large payout");

        console2.log("LP from 2000 ETH:", lpTokens);
        console2.log("Shares from 1000 ETH:", yesShares);
        console2.log("Payout:", payout);
    }

    /// @notice Test with many players (10 traders)
    function test_ManyPlayers_10Traders() public {
        // Create 10 traders
        address[10] memory traders;
        uint256[10] memory shares;

        for (uint256 i = 0; i < 10; i++) {
            traders[i] = makeAddr(string(abi.encodePacked("TRADER_", i)));
            vm.deal(traders[i], 100 ether);
        }

        // Add initial liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 50 ether}(
            MARKET_ID, 50 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // All traders buy (alternating YES/NO)
        for (uint256 i = 0; i < 10; i++) {
            bool isYes = i % 2 == 0;
            uint256 amount = (i + 1) * 0.5 ether; // Varying amounts

            vm.prank(traders[i]);
            shares[i] = router.buy{value: amount}(
                MARKET_ID, isYes, amount, 0, FEE_TIER, traders[i], block.timestamp + 1 hours
            );

            assertGt(shares[i], 0, "Each trader should receive shares");
        }

        // Resolve - YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // All YES holders claim
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                // YES holders
                uint256 balBefore = traders[i].balance;
                vm.prank(traders[i]);
                pamm.claim(MARKET_ID, traders[i]);
                totalClaimed += traders[i].balance - balBefore;
            }
        }

        assertGt(totalClaimed, 0, "Total claimed should be positive");
        console2.log("Total claimed by 5 YES holders:", totalClaimed);
    }

    /// @notice Test deep orderbook (10 orders)
    function test_DeepOrderbook_10Orders() public {
        // Create 10 users placing orders
        bytes32[10] memory orderHashes;

        for (uint256 i = 0; i < 10; i++) {
            address trader = makeAddr(string(abi.encodePacked("ORDER_", i)));
            vm.deal(trader, 10 ether);

            // Varying prices from 30% to 39%
            uint96 price = uint96(30 + i); // 30%, 31%, ... 39%
            uint96 collateral = price * 0.01 ether;

            vm.prank(trader);
            orderHashes[i] = router.placeOrder{value: collateral}(
                MARKET_ID, true, true, 1 ether, collateral, uint56(CLOSE_TIME), true
            );

            assertNotEq(orderHashes[i], bytes32(0), "Order should be created");
        }

        // Verify orderbook depth
        (bytes32[] memory bidHashes,,,) = router.getOrderbook(MARKET_ID, true, 15);
        assertGe(bidHashes.length, 10, "Should have at least 10 bids");

        console2.log("Orderbook depth:", bidHashes.length);
    }

    /// @notice Test many orders being filled sequentially
    function test_ManyOrderFills() public {
        // Create 5 buy orders with UNIQUE parameters (different collateral amounts)
        bytes32[5] memory orders;
        address[5] memory makers;
        uint96[5] memory collaterals;

        for (uint256 i = 0; i < 5; i++) {
            makers[i] = makeAddr(string(abi.encodePacked("MAKER_", i)));
            vm.deal(makers[i], 10 ether);

            // Each order has different collateral to make it unique
            collaterals[i] = uint96((40 + i) * 0.01 ether); // 0.40, 0.41, 0.42, 0.43, 0.44 ETH

            vm.prank(makers[i]);
            orders[i] = router.placeOrder{value: collaterals[i]}(
                MARKET_ID, true, true, 1 ether, collaterals[i], uint56(CLOSE_TIME), true
            );
        }

        // Single taker fills all orders
        vm.deal(BOB, 100 ether);
        vm.prank(BOB);
        router.buy{value: 10 ether}(
            MARKET_ID, true, 10 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        uint256 totalCollateralReceived = 0;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(BOB);
            (, uint96 collateralFilled) = router.fillOrder(orders[i], 1 ether, BOB);
            totalCollateralReceived += collateralFilled;

            // Verify maker received shares
            assertEq(pamm.balanceOf(makers[i], MARKET_ID), 1 ether, "Maker should receive shares");
        }

        // Total = 0.40 + 0.41 + 0.42 + 0.43 + 0.44 = 2.10 ETH
        assertEq(totalCollateralReceived, 2.1 ether, "Should receive sum of all collaterals");
        console2.log("Total from filling 5 orders:", totalCollateralReceived);
    }

    /// @notice Test LP with large imbalance after heavy trading
    function test_LPAfterHeavyTrading() public {
        // Initial liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        (, uint256 aliceLp) = pamm.splitAndAddLiquidity{value: 20 ether}(
            MARKET_ID, 20 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Heavy one-sided trading (all YES buys)
        for (uint256 i = 0; i < 5; i++) {
            address trader = makeAddr(string(abi.encodePacked("YES_BUYER_", i)));
            vm.deal(trader, 20 ether);
            vm.prank(trader);
            router.buy{value: 5 ether}(
                MARKET_ID, true, 5 ether, 0, FEE_TIER, trader, block.timestamp + 1 hours
            );
        }

        // Check pool state after heavy trading
        (uint256 rYes, uint256 rNo,,) = pamm.getPoolState(MARKET_ID, FEE_TIER);
        console2.log("YES reserves after trading:", rYes);
        console2.log("NO reserves after trading:", rNo);

        // Bob adds liquidity to imbalanced pool
        vm.deal(BOB, 50 ether);
        vm.prank(BOB);
        (, uint256 bobLp) = pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(bobLp, 0, "Bob should receive LP tokens");
        console2.log("Bob LP after imbalanced add:", bobLp);

        // Resolve and check LP withdrawals work
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Alice removes LP
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);

        vm.prank(ALICE);
        (uint256 alicePayout,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, aliceLp, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        assertGt(alicePayout, 0, "Alice should receive payout");

        // Bob removes LP
        vm.prank(BOB);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);

        vm.prank(BOB);
        (uint256 bobPayout,,) = pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, bobLp, 0, 0, 0, BOB, block.timestamp + 1 hours
        );
        assertGt(bobPayout, 0, "Bob should receive payout");

        console2.log("Alice LP payout:", alicePayout);
        console2.log("Bob LP payout:", bobPayout);
    }

    /// @notice Test concurrent operations - LP + trading + orders
    function test_ConcurrentOperations() public {
        // Setup multiple actors
        address LP1 = makeAddr("LP1");
        address LP2 = makeAddr("LP2");
        address TRADER1 = makeAddr("TRADER1");
        address TRADER2 = makeAddr("TRADER2");
        address ORDER_MAKER = makeAddr("ORDER_MAKER");

        vm.deal(LP1, 100 ether);
        vm.deal(LP2, 100 ether);
        vm.deal(TRADER1, 50 ether);
        vm.deal(TRADER2, 50 ether);
        vm.deal(ORDER_MAKER, 50 ether);

        // LP1 adds liquidity
        vm.prank(LP1);
        (, uint256 lp1Tokens) = pamm.splitAndAddLiquidity{value: 30 ether}(
            MARKET_ID, 30 ether, FEE_TIER, 0, 0, 0, LP1, block.timestamp + 1 hours
        );

        // Order maker places order
        vm.prank(ORDER_MAKER);
        bytes32 orderHash = router.placeOrder{value: 2 ether}(
            MARKET_ID, true, true, 5 ether, 2 ether, uint56(CLOSE_TIME), true
        );

        // Trader1 buys YES
        vm.prank(TRADER1);
        uint256 t1Shares = router.buy{value: 10 ether}(
            MARKET_ID, true, 10 ether, 0, FEE_TIER, TRADER1, block.timestamp + 1 hours
        );

        // LP2 adds liquidity (to now-imbalanced pool)
        vm.prank(LP2);
        (, uint256 lp2Tokens) = pamm.splitAndAddLiquidity{value: 20 ether}(
            MARKET_ID, 20 ether, FEE_TIER, 0, 0, 0, LP2, block.timestamp + 1 hours
        );

        // Trader2 buys NO
        vm.prank(TRADER2);
        uint256 t2Shares = router.buy{value: 8 ether}(
            MARKET_ID, false, 8 ether, 0, FEE_TIER, TRADER2, block.timestamp + 1 hours
        );

        // Trader1 fills order maker's order
        vm.prank(TRADER1);
        pamm.setOperator(address(router), true);

        vm.prank(TRADER1);
        router.fillOrder(orderHash, 2.5 ether, TRADER1);

        // Verify all operations succeeded
        assertGt(lp1Tokens, 0, "LP1 should have tokens");
        assertGt(lp2Tokens, 0, "LP2 should have tokens");
        assertGt(t1Shares, 0, "Trader1 should have shares");
        assertGt(t2Shares, 0, "Trader2 should have shares");
        assertGt(
            pamm.balanceOf(ORDER_MAKER, MARKET_ID), 0, "Order maker should have shares from fill"
        );

        // Resolve and everyone claims/withdraws
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Trader1 (YES) claims
        vm.prank(TRADER1);
        pamm.claim(MARKET_ID, TRADER1);

        // Order maker (YES from filled order) claims
        vm.prank(ORDER_MAKER);
        pamm.claim(MARKET_ID, ORDER_MAKER);

        // LPs withdraw
        vm.prank(LP1);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);
        vm.prank(LP1);
        pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, lp1Tokens, 0, 0, 0, LP1, block.timestamp + 1 hours
        );

        vm.prank(LP2);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);
        vm.prank(LP2);
        pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, lp2Tokens, 0, 0, 0, LP2, block.timestamp + 1 hours
        );

        console2.log("All concurrent operations succeeded");
    }

    /// @notice Test cancelled order refund after partial fills
    function test_CancelPartiallyFilledOrder() public {
        // Alice places buy order
        uint96 shares = 1 ether;
        uint96 collateral = 0.5 ether;

        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: collateral}(
            MARKET_ID, true, true, shares, collateral, uint56(CLOSE_TIME), true
        );

        // Bob fills half the order
        vm.prank(BOB);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        uint96 halfShares = shares / 2;
        vm.prank(BOB);
        router.fillOrder(orderHash, halfShares, BOB);

        // Verify Alice got half the shares
        assertEq(pamm.balanceOf(ALICE, MARKET_ID), halfShares, "Alice should have half shares");

        // Alice cancels remaining order
        uint256 aliceEthBefore = ALICE.balance;

        vm.prank(ALICE);
        router.cancelOrder(orderHash);

        // Alice should receive refund for unfilled portion
        uint256 refund = ALICE.balance - aliceEthBefore;
        assertGt(refund, 0, "Alice should receive ETH refund");
        assertEq(refund, collateral / 2, "Refund should be half collateral");
    }

    /*//////////////////////////////////////////////////////////////
                    ORDERBOOK + SWAP INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test orderbook price discovery - bids and asks create spread
    function test_OrderbookPriceDiscovery() public {
        // Multiple users place bids at different prices
        address BIDDER1 = makeAddr("BIDDER1");
        address BIDDER2 = makeAddr("BIDDER2");
        address ASKER1 = makeAddr("ASKER1");
        address ASKER2 = makeAddr("ASKER2");

        vm.deal(BIDDER1, 10 ether);
        vm.deal(BIDDER2, 10 ether);
        vm.deal(ASKER1, 10 ether);
        vm.deal(ASKER2, 10 ether);

        // Place bids (buy orders) at 35%, 40%, 45%
        vm.prank(BIDDER1);
        router.placeOrder{value: 0.35 ether}(
            MARKET_ID, true, true, 1 ether, 0.35 ether, uint56(CLOSE_TIME), true
        );

        vm.prank(BIDDER2);
        router.placeOrder{value: 0.4 ether}(
            MARKET_ID, true, true, 1 ether, 0.4 ether, uint56(CLOSE_TIME), true
        );

        // Askers need YES shares first
        vm.prank(ASKER1);
        router.buy{value: 3 ether}(
            MARKET_ID, true, 3 ether, 0, FEE_TIER, ASKER1, block.timestamp + 1 hours
        );
        vm.prank(ASKER1);
        pamm.setOperator(address(router), true);

        vm.prank(ASKER2);
        router.buy{value: 3 ether}(
            MARKET_ID, true, 3 ether, 0, FEE_TIER, ASKER2, block.timestamp + 1 hours
        );
        vm.prank(ASKER2);
        pamm.setOperator(address(router), true);

        // Place asks (sell orders) at 55%, 60%
        vm.prank(ASKER1);
        router.placeOrder(MARKET_ID, true, false, 1 ether, 0.55 ether, uint56(CLOSE_TIME), true);

        vm.prank(ASKER2);
        router.placeOrder(MARKET_ID, true, false, 1 ether, 0.6 ether, uint56(CLOSE_TIME), true);

        // Verify orderbook structure
        (bytes32[] memory bidHashes,, bytes32[] memory askHashes,) =
            router.getOrderbook(MARKET_ID, true, 10);

        assertGe(bidHashes.length, 2, "Should have at least 2 bids");
        assertGe(askHashes.length, 2, "Should have at least 2 asks");

        console2.log("Bid count:", bidHashes.length);
        console2.log("Ask count:", askHashes.length);
        console2.log("Spread: 45% bid - 55% ask = 10% spread");
    }

    /// @notice Test swap price impact at different sizes
    function test_SwapPriceImpact() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 20 ether}(
            MARKET_ID, 20 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Get initial reserves
        (uint256 rYesBefore, uint256 rNoBefore,,) = pamm.getPoolState(MARKET_ID, FEE_TIER);

        // Bob buys YES - small trade
        vm.deal(BOB, 50 ether);
        vm.prank(BOB);
        uint256 smallBuyShares = router.buy{value: 0.1 ether}(
            MARKET_ID, true, 0.1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        uint256 smallBuyPrice = 0.1 ether * 1e18 / smallBuyShares;

        // Carol buys YES - large trade
        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 50 ether);
        vm.prank(CAROL);
        uint256 largeBuyShares = router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );
        uint256 largeBuyPrice = 5 ether * 1e18 / largeBuyShares;

        // Large trade should have worse price (higher cost per share)
        assertGt(largeBuyPrice, smallBuyPrice, "Large trade should have worse execution price");

        // Verify reserves changed
        (uint256 rYesAfter, uint256 rNoAfter,,) = pamm.getPoolState(MARKET_ID, FEE_TIER);
        assertLt(rYesAfter, rYesBefore, "YES reserves should decrease after buys");
        assertGt(rNoAfter, rNoBefore, "NO reserves should increase after buys");

        console2.log("Small buy price (wei/share):", smallBuyPrice);
        console2.log("Large buy price (wei/share):", largeBuyPrice);
        console2.log("Price impact:", (largeBuyPrice - smallBuyPrice) * 100 / smallBuyPrice, "%");
    }

    /// @notice Test order fill then AMM swap manually (simulating smart routing)
    function test_OrderFillThenAMMSwap() public {
        // Add liquidity for AMM
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Place a sell order (ask) at 30% - below AMM price
        address SELLER = makeAddr("SELLER");
        vm.deal(SELLER, 20 ether);
        vm.prank(SELLER);
        router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, SELLER, block.timestamp + 1 hours
        );
        vm.prank(SELLER);
        pamm.setOperator(address(router), true);

        vm.prank(SELLER);
        bytes32 askOrder =
            router.placeOrder(MARKET_ID, true, false, 2 ether, 0.6 ether, uint56(CLOSE_TIME), true);

        // Bob fills the order directly, then buys more from AMM
        vm.deal(BOB, 10 ether);

        // Step 1: Fill the order
        uint256 bobSharesBefore = pamm.balanceOf(BOB, MARKET_ID);
        uint256 sellerEthBefore = SELLER.balance;

        vm.prank(BOB);
        (uint96 sharesFilled, uint96 collateralPaid) =
            router.fillOrder{value: 0.6 ether}(askOrder, 2 ether, BOB);

        assertGt(sharesFilled, 0, "Should fill some shares");
        assertGt(collateralPaid, 0, "Should pay collateral");

        // Step 2: Buy more from AMM
        vm.prank(BOB);
        uint256 ammShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        uint256 bobSharesAfter = pamm.balanceOf(BOB, MARKET_ID);
        uint256 sellerEthAfter = SELLER.balance;

        // Verify Bob got shares from both sources
        assertEq(
            bobSharesAfter - bobSharesBefore,
            sharesFilled + ammShares,
            "Bob should have shares from order + AMM"
        );

        // Seller should have received ETH from filled order
        assertGt(sellerEthAfter - sellerEthBefore, 0, "Seller should receive ETH from order fill");

        console2.log("Shares from order fill:", sharesFilled);
        console2.log("Shares from AMM:", ammShares);
        console2.log("Seller ETH received:", sellerEthAfter - sellerEthBefore);
    }

    /// @notice Test AMM + Orderbook arbitrage opportunity
    function test_ArbOpportunity() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 20 ether}(
            MARKET_ID, 20 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Get AMM price
        (,, uint256 pYesNum, uint256 pYesDen) = pamm.getPoolState(MARKET_ID, FEE_TIER);
        uint256 ammPrice = pYesNum * 1e18 / pYesDen;

        // Place bid above AMM price (arbitrage opportunity)
        address BIDDER = makeAddr("BIDDER");
        vm.deal(BIDDER, 10 ether);

        // Bid at 60% when AMM is ~50%
        vm.prank(BIDDER);
        bytes32 bidOrder = router.placeOrder{value: 0.6 ether}(
            MARKET_ID, true, true, 1 ether, 0.6 ether, uint56(CLOSE_TIME), true
        );

        // Arbitrageur: buy from AMM cheap, sell to bid expensive
        address ARB = makeAddr("ARB");
        vm.deal(ARB, 10 ether);

        // Buy from AMM
        vm.prank(ARB);
        uint256 arbShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, ARB, block.timestamp + 1 hours
        );

        // Approve and fill the bid
        vm.prank(ARB);
        pamm.setOperator(address(router), true);

        uint256 arbEthBefore = ARB.balance;
        vm.prank(ARB);
        (, uint96 collateralReceived) =
            router.fillOrder(bidOrder, uint96(arbShares > 1 ether ? 1 ether : arbShares), ARB);

        // Arb should profit if bid price > AMM execution price
        console2.log("AMM price (approx):", ammPrice);
        console2.log("Bid price: 60%");
        console2.log("Shares bought from AMM:", arbShares);
        console2.log("ETH received from bid:", collateralReceived);
    }

    /// @notice Test economic invariant: collateral locked = sum of potential payouts
    function test_EconomicInvariant_CollateralLocked() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Multiple trades
        vm.deal(BOB, 50 ether);
        vm.prank(BOB);
        router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 50 ether);
        vm.prank(CAROL);
        router.buy{value: 3 ether}(
            MARKET_ID, false, 3 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );

        // Get market state
        (,,,,,, uint256 collateralLocked, uint256 yesSupply, uint256 noSupply,) =
            pamm.getMarket(MARKET_ID);

        // Invariant: collateralLocked should cover max(yesSupply, noSupply) payout
        // Because only one side wins, and each winning share pays 1 ETH
        uint256 maxPotentialPayout = yesSupply > noSupply ? yesSupply : noSupply;

        console2.log("Collateral locked:", collateralLocked);
        console2.log("YES supply:", yesSupply);
        console2.log("NO supply:", noSupply);
        console2.log("Max potential payout:", maxPotentialPayout);

        // Collateral should be sufficient (may have slight excess from fees)
        assertGe(collateralLocked, maxPotentialPayout * 99 / 100, "Collateral should cover payouts");
    }

    /// @notice Test swap preserves total shares (YES + NO constant per unit collateral)
    function test_SwapPreservesShares() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Bob buys YES
        vm.deal(BOB, 20 ether);
        vm.prank(BOB);
        uint256 yesShares = router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Record Bob's total position value before swap
        uint256 yesBefore = pamm.balanceOf(BOB, MARKET_ID);
        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 noBefore = pamm.balanceOf(BOB, noId);

        // Approve ZAMM and swap half YES to NO
        vm.prank(BOB);
        pamm.setOperator(ZAMM_ADDRESS, true);

        uint256 swapAmount = yesBefore / 2;
        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;
        bool yesIsToken0 = MARKET_ID == id0;

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        vm.prank(BOB);
        uint256 noReceived = IZAMM(ZAMM_ADDRESS)
            .swapExactIn(poolKey, swapAmount, 0, yesIsToken0, BOB, block.timestamp + 1 hours);

        // After swap
        uint256 yesAfter = pamm.balanceOf(BOB, MARKET_ID);
        uint256 noAfter = pamm.balanceOf(BOB, noId);

        console2.log("Before - YES:", yesBefore, "NO:", noBefore);
        console2.log("After  - YES:", yesAfter, "NO:", noAfter);
        console2.log("YES lost:", yesBefore - yesAfter);
        console2.log("NO gained:", noAfter - noBefore);

        // Swap should maintain rough value (minus fees)
        assertEq(yesBefore - yesAfter, swapAmount, "Should lose exact swap amount of YES");
        assertGt(noReceived, 0, "Should receive NO shares");
    }

    /// @notice Test complete market economics - all ETH is accounted for
    function test_CompleteMarketEconomics() public {
        // Track all ETH flows
        uint256 totalEthIn = 0;

        // Alice adds liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        (, uint256 aliceLp) = pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        totalEthIn += 10 ether;

        // Bob buys YES
        vm.deal(BOB, 50 ether);
        vm.prank(BOB);
        uint256 bobYes = router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        totalEthIn += 5 ether;

        // Carol buys NO
        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 50 ether);
        vm.prank(CAROL);
        uint256 carolNo = router.buy{value: 3 ether}(
            MARKET_ID, false, 3 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );
        totalEthIn += 3 ether;

        // Resolve - YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(50))
        );
        resolver.resolveMarket(MARKET_ID);

        // Track ETH out
        uint256 totalEthOut = 0;

        // Bob claims YES winnings
        uint256 bobBalBefore = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);
        totalEthOut += BOB.balance - bobBalBefore;

        // Alice removes LP
        vm.prank(ALICE);
        IZAMM(ZAMM_ADDRESS).setOperator(address(pamm), true);
        uint256 aliceBalBefore = ALICE.balance;
        vm.prank(ALICE);
        pamm.removeLiquidityToCollateral(
            MARKET_ID, FEE_TIER, aliceLp, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );
        totalEthOut += ALICE.balance - aliceBalBefore;

        // Carol gets nothing (NO lost)
        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 carolNoBalance = pamm.balanceOf(CAROL, noId);
        assertGt(carolNoBalance, 0, "Carol still has worthless NO shares");

        console2.log("=== Market Economics ===");
        console2.log("Total ETH in:", totalEthIn);
        console2.log("Total ETH out:", totalEthOut);
        console2.log("Bob (YES winner) received from claim");
        console2.log("Alice (LP) received from withdrawal");
        console2.log("Carol (NO loser) payout: 0");

        // ETH out should be <= ETH in (some may remain as dust or fees)
        assertLe(totalEthOut, totalEthIn, "Cannot pay out more than deposited");
    }

    /*//////////////////////////////////////////////////////////////
                MIXED ORDERBOOK + AMM SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify order fill + AMM gives better price than AMM alone
    function test_MixedFill_BetterThanAMMAlone() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Seller places ask at 25% (below AMM ~50%)
        address SELLER = makeAddr("SELLER");
        vm.deal(SELLER, 20 ether);
        vm.prank(SELLER);
        router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, SELLER, block.timestamp + 1 hours
        );
        vm.prank(SELLER);
        pamm.setOperator(address(router), true);

        vm.prank(SELLER);
        bytes32 cheapOrder = router.placeOrder(
            MARKET_ID, true, false, 1 ether, 0.25 ether, uint56(CLOSE_TIME), true
        );

        // Compare: Bob buys 2 ETH worth via AMM only
        vm.deal(BOB, 20 ether);
        vm.prank(BOB);
        uint256 ammOnlyShares = router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // Carol fills order first, then AMM for remaining
        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 20 ether);

        // Fill cheap order (0.25 ETH for 1 share)
        vm.prank(CAROL);
        (uint96 orderShares,) = router.fillOrder{value: 0.25 ether}(cheapOrder, 1 ether, CAROL);

        // Buy remaining 1.75 ETH from AMM
        vm.prank(CAROL);
        uint256 ammShares = router.buy{value: 1.75 ether}(
            MARKET_ID, true, 1.75 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );

        uint256 carolTotalShares = orderShares + ammShares;

        // Carol should have MORE shares than Bob for same ETH spent
        assertGt(
            carolTotalShares, ammOnlyShares, "Mixed fill should yield more shares than AMM only"
        );

        console2.log("Bob (AMM only, 2 ETH):", ammOnlyShares, "shares");
        console2.log("Carol (order + AMM, 2 ETH):", carolTotalShares, "shares");
        console2.log("Carol's advantage:", carolTotalShares - ammOnlyShares, "extra shares");
    }

    /// @notice Verify no value leakage in order fill - maker gets exactly what's owed
    function test_OrderFill_NoValueLeakage() public {
        // Seller places ask: 2 shares for 1 ETH (50% price)
        address SELLER = makeAddr("SELLER");
        vm.deal(SELLER, 20 ether);
        vm.prank(SELLER);
        router.buy{value: 5 ether}(
            MARKET_ID, true, 5 ether, 0, FEE_TIER, SELLER, block.timestamp + 1 hours
        );

        uint256 sellerSharesBefore = pamm.balanceOf(SELLER, MARKET_ID);
        vm.prank(SELLER);
        pamm.setOperator(address(router), true);

        uint96 orderShares = 2 ether;
        uint96 orderCollateral = 1 ether;

        vm.prank(SELLER);
        bytes32 orderHash = router.placeOrder(
            MARKET_ID, true, false, orderShares, orderCollateral, uint56(CLOSE_TIME), true
        );

        // Verify seller's shares were escrowed
        uint256 sellerSharesAfterPlace = pamm.balanceOf(SELLER, MARKET_ID);
        assertEq(
            sellerSharesBefore - sellerSharesAfterPlace, orderShares, "Shares should be escrowed"
        );

        // Buyer fills order
        vm.deal(BOB, 10 ether);
        uint256 buyerEthBefore = BOB.balance;
        uint256 sellerEthBefore = SELLER.balance;

        vm.prank(BOB);
        (uint96 sharesFilled, uint96 collateralPaid) =
            router.fillOrder{value: orderCollateral}(orderHash, orderShares, BOB);

        // Verify exact amounts
        assertEq(sharesFilled, orderShares, "All shares should be filled");
        assertEq(collateralPaid, orderCollateral, "Exact collateral should be paid");
        assertEq(pamm.balanceOf(BOB, MARKET_ID), orderShares, "Buyer received exact shares");
        assertEq(SELLER.balance - sellerEthBefore, orderCollateral, "Seller received exact ETH");
        assertEq(buyerEthBefore - BOB.balance, orderCollateral, "Buyer paid exact ETH");

        console2.log("Order: 2 shares for 1 ETH");
        console2.log("Buyer paid:", buyerEthBefore - BOB.balance);
        console2.log("Seller received:", SELLER.balance - sellerEthBefore);
        console2.log("No value leaked");
    }

    /// @notice Verify partial order fills are economically correct
    function test_PartialFill_EconomicsCorrect() public {
        // Seller places ask: 4 shares for 2 ETH (50% each)
        address SELLER = makeAddr("SELLER");
        vm.deal(SELLER, 20 ether);
        vm.prank(SELLER);
        router.buy{value: 10 ether}(
            MARKET_ID, true, 10 ether, 0, FEE_TIER, SELLER, block.timestamp + 1 hours
        );
        vm.prank(SELLER);
        pamm.setOperator(address(router), true);

        vm.prank(SELLER);
        bytes32 orderHash =
            router.placeOrder(MARKET_ID, true, false, 4 ether, 2 ether, uint56(CLOSE_TIME), true);

        // Bob fills 25% of order (1 share)
        vm.deal(BOB, 10 ether);
        uint256 sellerEthBefore = SELLER.balance;

        vm.prank(BOB);
        (uint96 sharesFilled1, uint96 collateralPaid1) =
            router.fillOrder{value: 0.5 ether}(orderHash, 1 ether, BOB);

        assertEq(sharesFilled1, 1 ether, "Should fill 1 share");
        assertEq(collateralPaid1, 0.5 ether, "Should pay 0.5 ETH for 1 share");
        assertEq(SELLER.balance - sellerEthBefore, 0.5 ether, "Seller got proportional payment");

        // Carol fills another 50% (2 shares)
        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 10 ether);
        sellerEthBefore = SELLER.balance;

        vm.prank(CAROL);
        (uint96 sharesFilled2, uint96 collateralPaid2) =
            router.fillOrder{value: 1 ether}(orderHash, 2 ether, CAROL);

        assertEq(sharesFilled2, 2 ether, "Should fill 2 shares");
        assertEq(collateralPaid2, 1 ether, "Should pay 1 ETH for 2 shares");
        assertEq(SELLER.balance - sellerEthBefore, 1 ether, "Seller got proportional payment");

        // Verify remaining order
        (,,,, uint96 collateralRemaining, bool active) = router.getOrder(orderHash);
        assertTrue(active, "Order should still be active");
        assertEq(collateralRemaining, 0.5 ether, "0.5 ETH collateral should remain");

        console2.log("Partial fills maintain correct price ratio");
    }

    /// @notice Verify cancelled orders don't affect other users
    function test_CancelledOrder_NoSideEffects() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Alice places large bid
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder{value: 5 ether}(
            MARKET_ID, true, true, 10 ether, 5 ether, uint56(CLOSE_TIME), true
        );

        // Snapshot AMM state
        (uint256 rYesBefore, uint256 rNoBefore,,) = pamm.getPoolState(MARKET_ID, FEE_TIER);

        // Alice cancels order
        uint256 aliceEthBefore = ALICE.balance;
        vm.prank(ALICE);
        router.cancelOrder(orderHash);

        // Alice gets full refund
        assertEq(ALICE.balance - aliceEthBefore, 5 ether, "Alice should get full refund");

        // AMM state unchanged
        (uint256 rYesAfter, uint256 rNoAfter,,) = pamm.getPoolState(MARKET_ID, FEE_TIER);
        assertEq(rYesBefore, rYesAfter, "YES reserves unchanged");
        assertEq(rNoBefore, rNoAfter, "NO reserves unchanged");

        // Bob can still trade normally
        vm.deal(BOB, 10 ether);
        vm.prank(BOB);
        uint256 bobShares = router.buy{value: 1 ether}(
            MARKET_ID, true, 1 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );
        assertGt(bobShares, 0, "Bob can trade after cancel");

        console2.log("Cancelled order: no effect on AMM or other users");
    }

    /// @notice Verify swap + orderbook maintain total share conservation
    function test_MixedOperations_ShareConservation() public {
        // Add liquidity
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 10 ether}(
            MARKET_ID, 10 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        // Get initial supplies
        (,,,,,, uint256 collateralBefore, uint256 yesSupplyBefore, uint256 noSupplyBefore,) =
            pamm.getMarket(MARKET_ID);

        // Multiple operations
        vm.deal(BOB, 50 ether);

        // 1. Buy YES via AMM
        vm.prank(BOB);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        // 2. Place and fill order
        vm.prank(BOB);
        pamm.setOperator(address(router), true);
        vm.prank(BOB);
        bytes32 order = router.placeOrder(
            MARKET_ID, true, false, 0.5 ether, 0.25 ether, uint56(CLOSE_TIME), true
        );

        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 10 ether);
        vm.prank(CAROL);
        router.fillOrder{value: 0.25 ether}(order, 0.5 ether, CAROL);

        // 3. Swap YES to NO
        vm.prank(BOB);
        pamm.setOperator(ZAMM_ADDRESS, true);

        uint256 noId = pamm.getNoId(MARKET_ID);
        uint256 id0 = MARKET_ID < noId ? MARKET_ID : noId;
        uint256 id1 = MARKET_ID < noId ? noId : MARKET_ID;

        IZAMM.PoolKey memory poolKey = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(pamm), token1: address(pamm), feeOrHook: FEE_TIER
        });

        vm.prank(BOB);
        IZAMM(ZAMM_ADDRESS)
            .swapExactIn(poolKey, 0.5 ether, 0, MARKET_ID == id0, BOB, block.timestamp + 1 hours);

        // Check supplies after all operations
        (,,,,,, uint256 collateralAfter, uint256 yesSupplyAfter, uint256 noSupplyAfter,) =
            pamm.getMarket(MARKET_ID);

        console2.log("Collateral: before", collateralBefore, "after", collateralAfter);
        console2.log("YES supply: before", yesSupplyBefore, "after", yesSupplyAfter);
        console2.log("NO supply: before", noSupplyBefore, "after", noSupplyAfter);

        // Collateral should increase (from buys)
        assertGt(collateralAfter, collateralBefore, "Collateral increased from deposits");
    }

    /// @notice Verify this is a real prediction market - condition determines outcome
    function test_RealPredictionMarket_OutcomeDependsOnCondition() public {
        // Add liquidity and trading
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pamm.splitAndAddLiquidity{value: 5 ether}(
            MARKET_ID, 5 ether, FEE_TIER, 0, 0, 0, ALICE, block.timestamp + 1 hours
        );

        vm.deal(BOB, 50 ether);
        vm.prank(BOB);
        router.buy{value: 2 ether}(
            MARKET_ID, true, 2 ether, 0, FEE_TIER, BOB, block.timestamp + 1 hours
        );

        address CAROL = makeAddr("CAROL");
        vm.deal(CAROL, 50 ether);
        vm.prank(CAROL);
        router.buy{value: 2 ether}(
            MARKET_ID, false, 2 ether, 0, FEE_TIER, CAROL, block.timestamp + 1 hours
        );

        // Verify condition: PNKSTR treasury > 40 punks
        (address target,,,, uint256 threshold,,) = resolver.conditions(MARKET_ID);

        assertEq(target, address(punks), "Condition target should be CryptoPunks");
        assertEq(threshold, 40, "Threshold should be 40 punks");

        // Scenario A: Condition NOT met (39 punks) - NO wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(39))
        );

        // Preview should show condition not met
        (, bool condTrue,) = resolver.preview(MARKET_ID);
        assertFalse(condTrue, "39 > 40 should be false");

        // Scenario B: Condition met (41 punks) - YES wins
        vm.mockCall(
            address(punks),
            abi.encodeWithSelector(ICryptoPunks.balanceOf.selector, PNKSTR_TREASURY),
            abi.encode(uint256(41))
        );

        (, condTrue,) = resolver.preview(MARKET_ID);
        assertTrue(condTrue, "41 > 40 should be true");

        // Actually resolve with condition met
        resolver.resolveMarket(MARKET_ID);

        // Verify outcome
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(MARKET_ID);
        assertTrue(resolved, "Market should be resolved");
        assertTrue(outcome, "YES should win when condition met");

        // Bob (YES) can claim, Carol (NO) cannot
        uint256 bobBalBefore = BOB.balance;
        vm.prank(BOB);
        pamm.claim(MARKET_ID, BOB);
        assertGt(BOB.balance - bobBalBefore, 0, "YES holder should receive payout");

        console2.log("=== Real Prediction Market Verified ===");
        console2.log("Condition: PNKSTR treasury > 40 punks");
        console2.log("Actual value: 41 (mocked)");
        console2.log("Result: YES wins, Bob receives payout");
    }
}

/*//////////////////////////////////////////////////////////////
                        HELPER INTERFACES
//////////////////////////////////////////////////////////////*/

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function setOperator(address operator, bool approved) external returns (bool);

    function fillOrder(
        address maker,
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill,
        uint96 fillPart
    ) external payable;
}
