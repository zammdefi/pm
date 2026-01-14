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
    function resolve(uint256 marketId, bool outcome) external;
    function claim(uint256 marketId, address to) external returns (uint256 amount);
}

/// @title MasterRouter Lifecycle Tests
/// @notice Tests critical lifecycle scenarios: trading closed, resolution, deadlines, multi-user
contract MasterRouterLifecycleTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public dave = address(0x4);
    address public resolver = address(0x999);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        router = new MasterRouter();

        // Create market with resolver (so we can test resolution)
        (marketId, noId) = pamm.createMarket(
            "Lifecycle Test Market",
            resolver, // Use dedicated resolver
            address(0), // ETH collateral
            uint64(block.timestamp + 1 days),
            true // canClose
        );

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    TRADING CLOSED SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Operations should revert when trading is closed
    function test_tradingClosed_mintAndPoolReverts() public {
        // First, create a pool while trading is open
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Warp past close time
        vm.warp(block.timestamp + 2 days);

        // Verify trading is closed
        assertFalse(pamm.tradingOpen(marketId), "Trading should be closed");

        // Try to mint and pool - should revert
        vm.prank(bob);
        vm.expectRevert(); // ERR_STATE, 0
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, bob);
    }

    /// @notice fillFromPool should revert when trading is closed
    function test_tradingClosed_fillFromPoolReverts() public {
        // Create pool
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Warp past close
        vm.warp(block.timestamp + 2 days);

        // Try to fill - should revert
        vm.prank(bob);
        vm.expectRevert();
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);
    }

    /// @notice createBidPool should revert when trading is closed
    function test_tradingClosed_createBidPoolReverts() public {
        // Warp past close
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert();
        router.createBidPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);
    }

    /// @notice sellToPool should revert when trading is closed
    function test_tradingClosed_sellToPoolReverts() public {
        // Create bid pool
        vm.prank(alice);
        router.createBidPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob gets shares
        vm.prank(bob);
        pamm.split{value: 5 ether}(marketId, 5 ether, bob);
        vm.prank(bob);
        pamm.setOperator(address(router), true);

        // Warp past close
        vm.warp(block.timestamp + 2 days);

        // Try to sell - should revert
        vm.prank(bob);
        vm.expectRevert();
        router.sellToPool(marketId, true, 5000, 5 ether, 0, bob, 0);
    }

    /// @notice buy() should revert when trading is closed
    function test_tradingClosed_buyReverts() public {
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert();
        router.buy{value: 10 ether}(marketId, true, 10 ether, 0, 0, alice, 0);
    }

    /// @notice sell() should revert when trading is closed
    function test_tradingClosed_sellReverts() public {
        // Get shares first
        vm.prank(alice);
        pamm.split{value: 10 ether}(marketId, 10 ether, alice);
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 5 ether, 0, 0, alice, 0);
    }

    /// @notice claimProceeds should work even when trading is closed
    function test_tradingClosed_claimProceedsWorks() public {
        // Create pool and fill it
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);

        // Warp past close
        vm.warp(block.timestamp + 2 days);

        // Claim should still work
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 5000, alice);

        assertEq(claimed, 5 ether, "Should claim full proceeds");
        assertEq(alice.balance, balanceBefore + 5 ether, "Balance should increase");
    }

    /// @notice withdrawFromPool should work even when trading is closed
    function test_tradingClosed_withdrawFromPoolWorks() public {
        // Create pool
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Warp past close
        vm.warp(block.timestamp + 2 days);

        // Withdraw should still work
        vm.prank(alice);
        (uint256 withdrawn,) = router.withdrawFromPool(marketId, false, 5000, 0, alice);

        assertEq(withdrawn, 10 ether, "Should withdraw all shares");
    }

    /*//////////////////////////////////////////////////////////////
                    DEADLINE SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice buy() should revert with expired deadline
    function test_deadline_buyExpiredReverts() public {
        uint256 deadline = block.timestamp + 1 hours;

        // Warp past deadline
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(); // ERR_TIMING, 0
        router.buy{value: 10 ether}(marketId, true, 10 ether, 0, 0, alice, deadline);
    }

    /// @notice sell() should revert with expired deadline
    function test_deadline_sellExpiredReverts() public {
        // Get shares
        vm.prank(alice);
        pamm.split{value: 10 ether}(marketId, 10 ether, alice);
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        uint256 deadline = block.timestamp + 1 hours;
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 5 ether, 0, 0, alice, deadline);
    }

    /// @notice deadline=0 should work (no deadline check)
    function test_deadline_zeroMeansNoDeadline() public {
        // Create pool
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Even with deadline=0 and time passed, should work (deadline=0 means no check)
        vm.prank(bob);
        (uint256 shares,) = router.buy{value: 5 ether}(marketId, false, 5 ether, 0, 5000, bob, 0);

        assertGt(shares, 0, "Should successfully buy with deadline=0");
    }

    /// @notice Future deadline should work
    function test_deadline_futureDeadlineWorks() public {
        // Create pool
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(bob);
        (uint256 shares,) =
            router.buy{value: 5 ether}(marketId, false, 5 ether, 0, 5000, bob, deadline);

        assertGt(shares, 0, "Should buy with valid deadline");
    }

    /*//////////////////////////////////////////////////////////////
                    FULL LIFECYCLE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Complete lifecycle: create pools → trade → resolve → claim
    function test_fullLifecycle_createTradeResolveClaim() public {
        // Phase 1: Create liquidity
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);
        // Alice keeps YES, pools NO at 50%

        vm.prank(bob);
        router.createBidPool{value: 50 ether}(marketId, 50 ether, true, 6000, bob);
        // Bob creates bid pool for YES at 60%

        // Phase 2: Trading
        // Carol buys NO from Alice's pool (pays 50% for NO)
        vm.prank(carol);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, carol, 0);
        // Carol now has 50 NO shares, Alice earned 25 ETH

        // Dave sells YES to Bob's bid pool
        vm.prank(dave);
        pamm.split{value: 40 ether}(marketId, 40 ether, dave);
        vm.prank(dave);
        pamm.setOperator(address(router), true);
        vm.prank(dave);
        router.sellToPool(marketId, true, 6000, 40 ether, 0, dave, 0);
        // Dave sold 40 YES at 60%, Bob's pool now has 40 YES shares

        // Phase 3: Claims while trading is open
        vm.prank(alice);
        uint256 aliceProceeds = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(aliceProceeds, 25 ether, "Alice should claim from pool fills");

        vm.prank(bob);
        uint256 bobShares = router.claimBidShares(marketId, true, 6000, bob);
        assertEq(bobShares, 40 ether, "Bob should claim YES shares");

        // Phase 4: Close and resolve market (YES wins)
        vm.warp(block.timestamp + 2 days);
        vm.prank(resolver);
        pamm.resolve(marketId, true); // YES wins

        // Phase 5: Claim from PAMM (market resolution payouts)
        // Alice has 100 YES (kept) - wins
        // Carol has 50 NO - loses
        // Bob has 40 YES from bid pool - wins
        // Dave has 40 NO (from split) - loses

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        pamm.claim(marketId, alice);
        assertEq(alice.balance - aliceBalBefore, 100 ether, "Alice wins with YES");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        pamm.claim(marketId, bob);
        assertEq(bob.balance - bobBalBefore, 40 ether, "Bob wins with YES from bid pool");

        // Carol and Dave held losing tokens, so they have nothing to claim
        // (PAMM reverts with AmountZero if no winning tokens)
        // Just verify they have NO tokens (losers)
        assertEq(pamm.balanceOf(carol, noId), 50 ether, "Carol has losing NO tokens");
        // Note: Dave's NO balance may be 0 if he sold all YES for NO already
    }

    /*//////////////////////////////////////////////////////////////
                    CONCURRENT MULTI-USER SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Multiple users creating pools at same price level
    function test_concurrent_multipleDepositsToSamePool() public {
        // All users deposit to same pool
        vm.prank(alice);
        router.mintAndPool{value: 30 ether}(marketId, 30 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 20 ether}(marketId, 20 ether, true, 5000, bob);

        vm.prank(carol);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, carol);

        // Total pool should have 100 shares
        bytes32 poolId = router.getPoolId(marketId, false, 5000);
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, 100 ether, "Total shares should be sum of deposits");

        // Fill entire pool
        vm.prank(dave);
        router.fillFromPool{value: 50 ether}(marketId, false, 5000, 100 ether, 0, dave, 0);

        // Each user claims proportionally
        vm.prank(alice);
        uint256 aliceClaim = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaim = router.claimProceeds(marketId, false, 5000, bob);

        vm.prank(carol);
        uint256 carolClaim = router.claimProceeds(marketId, false, 5000, carol);

        assertEq(aliceClaim, 15 ether, "Alice gets 30% of 50 ETH");
        assertEq(bobClaim, 10 ether, "Bob gets 20% of 50 ETH");
        assertEq(carolClaim, 25 ether, "Carol gets 50% of 50 ETH");
    }

    /// @notice Multiple users interleaving deposits and fills
    function test_concurrent_interleavedDepositsAndFills() public {
        // Alice deposits
        vm.prank(alice);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        // Dave fills half
        vm.prank(dave);
        router.fillFromPool{value: 12.5 ether}(marketId, false, 5000, 25 ether, 0, dave, 0);

        // Bob deposits (joins pool with 25 remaining shares)
        vm.prank(bob);
        router.mintAndPool{value: 25 ether}(marketId, 25 ether, true, 5000, bob);
        // Pool now has 50 shares total (25 from Alice remaining + 25 from Bob)

        // Dave fills the rest
        vm.prank(dave);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, dave, 0);

        // Claims:
        // Alice: 12.5 ETH (first fill) + 12.5 ETH (half of second fill) = 25 ETH
        // Bob: 12.5 ETH (half of second fill only - wasn't in pool for first fill)

        vm.prank(alice);
        uint256 aliceClaim = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaim = router.claimProceeds(marketId, false, 5000, bob);

        assertEq(aliceClaim, 25 ether, "Alice should get 25 ETH");
        assertEq(bobClaim, 12.5 ether, "Bob should get 12.5 ETH (only second fill)");
    }

    /// @notice Users withdrawing while others are filling
    function test_concurrent_withdrawDuringFills() public {
        // Alice and Bob deposit
        vm.prank(alice);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, bob);

        // Dave fills half (50 shares worth)
        vm.prank(dave);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, dave, 0);

        // Alice withdraws her remaining shares
        vm.prank(alice);
        (uint256 aliceWithdrawn, uint256 aliceClaimed) =
            router.withdrawFromPool(marketId, false, 5000, 0, alice);

        // Alice should get 25 shares (half filled) + 12.5 ETH (half of 25 ETH collateral)
        assertEq(aliceWithdrawn, 25 ether, "Alice withdraws 25 remaining shares");
        assertEq(aliceClaimed, 12.5 ether, "Alice claims 12.5 ETH proceeds");

        // Dave fills remaining 25 shares (Bob's)
        vm.prank(dave);
        router.fillFromPool{value: 12.5 ether}(marketId, false, 5000, 25 ether, 0, dave, 0);

        // Bob claims
        vm.prank(bob);
        uint256 bobClaim = router.claimProceeds(marketId, false, 5000, bob);
        assertEq(bobClaim, 25 ether, "Bob gets 12.5 from first fill + 12.5 from second");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES AND STRESS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Many small fills to a single pool
    function test_stress_manySmallFills() public {
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // 100 small fills
        for (uint256 i = 0; i < 100; i++) {
            vm.deal(address(uint160(1000 + i)), 1 ether);
            vm.prank(address(uint160(1000 + i)));
            router.fillFromPool{value: 0.5 ether}(
                marketId, false, 5000, 1 ether, 0, address(uint160(1000 + i)), 0
            );
        }

        // Alice claims all
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(claimed, 50 ether, "Alice should claim all 50 ETH from 100 fills");
    }

    /// @notice Many users in one pool
    function test_stress_manyUsersInPool() public {
        // 50 users deposit
        for (uint256 i = 0; i < 50; i++) {
            address user = address(uint160(2000 + i));
            vm.deal(user, 10 ether);
            vm.prank(user);
            router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, user);
        }

        // Total pool should have 100 shares
        bytes32 poolId = router.getPoolId(marketId, false, 5000);
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, 100 ether, "Should have 100 shares from 50 users");

        // One fill for all
        vm.prank(dave);
        router.fillFromPool{value: 50 ether}(marketId, false, 5000, 100 ether, 0, dave, 0);

        // Each user claims
        for (uint256 i = 0; i < 50; i++) {
            address user = address(uint160(2000 + i));
            vm.prank(user);
            uint256 claimed = router.claimProceeds(marketId, false, 5000, user);
            assertEq(claimed, 1 ether, "Each user should claim 1 ETH (2% of 50 ETH)");
        }
    }

    /// @notice Rapid deposits and withdrawals
    function test_stress_rapidDepositsWithdrawals() public {
        bytes32 poolId = router.getPoolId(marketId, false, 5000);

        for (uint256 i = 0; i < 20; i++) {
            // Deposit
            vm.prank(alice);
            router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, alice);

            // Partial fill
            vm.prank(bob);
            router.fillFromPool{value: 1.25 ether}(marketId, false, 5000, 2.5 ether, 0, bob, 0);

            // Withdraw and claim
            vm.prank(alice);
            router.withdrawFromPool(marketId, false, 5000, 0, alice);
        }

        // Pool should be empty
        (uint256 totalShares, uint256 totalScaled,,) = router.pools(poolId);
        assertEq(totalShares, 0, "Pool should be empty after withdrawals");
        assertEq(totalScaled, 0, "Scaled should be 0 after full withdrawals");
    }

    /*//////////////////////////////////////////////////////////////
                    ERC20 COLLATERAL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Create market with ERC20 collateral and test full lifecycle
    /// @dev This test uses a real forked environment with USDC
    function test_lifecycle_erc20Collateral() public {
        // Get USDC
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Create ERC20 market
        (uint256 usdcMarketId,) = pamm.createMarket(
            "USDC Test Market", resolver, USDC, uint64(block.timestamp + 1 days), true
        );

        // Get USDC for alice (whale: Binance)
        address usdcWhale = 0x28C6c06298d514Db089934071355E5743bf21d60;
        uint256 amount = 1000e6; // 1000 USDC

        vm.prank(usdcWhale);
        (bool success,) =
            USDC.call(abi.encodeWithSignature("transfer(address,uint256)", alice, amount));
        require(success, "USDC transfer failed");

        // Alice approves and creates pool
        vm.startPrank(alice);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success, "Approve failed");

        router.mintAndPool(usdcMarketId, amount, true, 5000, alice);
        vm.stopPrank();

        // Verify pool created
        bytes32 poolId = router.getPoolId(usdcMarketId, false, 5000);
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, amount, "Pool should have USDC shares");

        // Bob fills (needs USDC)
        vm.prank(usdcWhale);
        (success,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", bob, 500e6));
        require(success, "USDC transfer failed");

        vm.startPrank(bob);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success);

        router.fillFromPool(usdcMarketId, false, 5000, amount, 0, bob, 0);
        vm.stopPrank();

        // Alice claims USDC
        (, bytes memory data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", alice));
        uint256 aliceBalBefore = abi.decode(data, (uint256));

        vm.prank(alice);
        router.claimProceeds(usdcMarketId, false, 5000, alice);

        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", alice));
        uint256 aliceBalAfter = abi.decode(data, (uint256));

        assertEq(aliceBalAfter - aliceBalBefore, 500e6, "Alice should receive 500 USDC");
    }

    /*//////////////////////////////////////////////////////////////
                    MINT AND SELL OTHER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: mintAndSellOther basic flow - mint and sell into bid pools
    function test_mintAndSellOther_basic() public {
        // Bob creates a bid pool at 40% (wants to buy NO)
        vm.prank(bob);
        router.createBidPool{value: 40 ether}(marketId, 40 ether, false, 4000, bob);

        // Alice uses mintAndSellOther: mint 100 YES+NO, keep YES, sell NO into bid pools
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        (uint256 sharesKept, uint256 collateralRecovered) =
            router.mintAndSellOther{value: 100 ether}(marketId, 100 ether, true, 1, alice, 0);

        // Alice should have 100 YES shares
        assertEq(sharesKept, 100 ether, "Should keep 100 YES shares");
        assertEq(pamm.balanceOf(alice, marketId), 100 ether, "Alice YES balance wrong");

        // Alice should recover ~40 ETH from selling NO into bid pool
        assertGt(collateralRecovered, 0, "Should recover some collateral");

        // Net cost should be less than 100 ETH (since we recovered from selling NO)
        uint256 netCost = aliceBalBefore - alice.balance;
        assertLt(netCost, 100 ether, "Net cost should be less than 100 ETH");
    }

    /// @notice Test: mintAndSellOther when no bid pools exist - routes through PMHookRouter
    function test_mintAndSellOther_noBidPools() public {
        vm.prank(alice);
        (uint256 sharesKept, uint256 collateralRecovered) =
            router.mintAndSellOther{value: 10 ether}(marketId, 10 ether, true, 1, alice, 0);

        // Should still get YES shares
        assertEq(sharesKept, 10 ether, "Should keep YES shares");

        // PMHookRouter may or may not be able to sell (depends on vault state)
        // but function should not revert
    }

    /// @notice Test: mintAndSellOther with minPriceBps = 0 skips bid pools
    function test_mintAndSellOther_skipBidPools() public {
        // Bob creates bid pool
        vm.prank(bob);
        router.createBidPool{value: 50 ether}(marketId, 50 ether, false, 5000, bob);

        // Alice mints with minPriceBps = 0 (skip bid pools)
        vm.prank(alice);
        (uint256 sharesKept, uint256 collateralRecovered) =
            router.mintAndSellOther{value: 10 ether}(marketId, 10 ether, true, 0, alice, 0);

        assertEq(sharesKept, 10 ether, "Should keep YES shares");

        // Bob's bid pool should still be full (wasn't used)
        bytes32 bidPoolId = router.getBidPoolId(marketId, false, 5000);
        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 50 ether, "Bid pool should be untouched");
    }

    /// @notice Test: mintAndSellOther deadline
    function test_mintAndSellOther_deadline() public {
        vm.prank(alice);
        vm.expectRevert(); // ERR_TIMING, 0
        router.mintAndSellOther{value: 10 ether}(
            marketId, 10 ether, true, 1, alice, block.timestamp - 1
        );
    }

    /// @notice Test: mintAndSellOther reverts when trading closed
    function test_mintAndSellOther_tradingClosed() public {
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert(); // ERR_STATE, 0
        router.mintAndSellOther{value: 10 ether}(marketId, 10 ether, true, 1, alice, 0);
    }

    /// @notice Test: mintAndSellOther sweeps multiple bid pools
    function test_mintAndSellOther_multiPoolSweep() public {
        // Create multiple bid pools at different prices
        vm.prank(bob);
        router.createBidPool{value: 20 ether}(marketId, 20 ether, false, 4500, bob); // 45%

        vm.prank(carol);
        router.createBidPool{value: 30 ether}(marketId, 30 ether, false, 4000, carol); // 40%

        vm.prank(dave);
        router.createBidPool{value: 25 ether}(marketId, 25 ether, false, 3500, dave); // 35%

        // Alice mints and sells 100 NO - should sweep highest bids first
        vm.prank(alice);
        (uint256 sharesKept, uint256 collateralRecovered) =
            router.mintAndSellOther{value: 100 ether}(marketId, 100 ether, true, 3000, alice, 0);

        assertEq(sharesKept, 100 ether, "Should keep all YES shares");
        assertGt(collateralRecovered, 0, "Should recover collateral from bid pools");

        // Check that highest priced pool was hit first
        bytes32 highBidId = router.getBidPoolId(marketId, false, 4500);
        (uint256 highPoolRemaining,,,) = router.bidPools(highBidId);
        assertLt(highPoolRemaining, 20 ether, "High bid pool should be partially/fully filled");
    }

    /// @notice Test: mintAndSellOther keepYes=false (keep NO, sell YES)
    function test_mintAndSellOther_keepNo() public {
        // Create bid pool for YES shares
        vm.prank(bob);
        router.createBidPool{value: 30 ether}(marketId, 30 ether, true, 4000, bob);

        vm.prank(alice);
        (uint256 sharesKept, uint256 collateralRecovered) =
            router.mintAndSellOther{value: 50 ether}(marketId, 50 ether, false, 1, alice, 0);

        // Alice should have NO shares
        assertEq(sharesKept, 50 ether, "Should keep NO shares");
        assertEq(pamm.balanceOf(alice, noId), 50 ether, "Alice NO balance wrong");
        assertGt(collateralRecovered, 0, "Should recover from selling YES");
    }
}
