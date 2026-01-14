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
}

/// @title Mock PMHookRouter for testing MasterRouter integration
/// @notice Simulates PMHookRouter's vault and trading functionality
contract MockPMHookRouter {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant ETH = address(0);

    // Track vault deposits per market/side
    mapping(uint256 => mapping(bool => uint256)) public vaultBalances;
    mapping(uint256 => mapping(bool => mapping(address => uint256))) public userVaultShares;

    receive() external payable {}

    function _getCollateral(uint256 marketId) internal view returns (address collateral) {
        (,,,,, collateral,) = PAMM.markets(marketId);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success,) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(success, "transferFrom failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success,) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success, "transfer failed");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success,) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(success, "approve failed");
    }

    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 /*deadline*/
    )
        external
        returns (uint256 vaultShares)
    {
        // Transfer shares from caller to this contract
        uint256 tokenId = isYes ? marketId : _getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), tokenId, shares);

        // Mint 1:1 vault shares
        vaultShares = shares;
        vaultBalances[marketId][isYes] += shares;
        userVaultShares[marketId][isYes][receiver] += vaultShares;

        return vaultShares;
    }

    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256,
        /*minSharesOut*/
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) {
        address collateral = _getCollateral(marketId);

        // Take collateral from caller (for ERC20)
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _safeApprove(collateral, address(PAMM), collateralIn);
        }

        // Check if we have vault liquidity on the opposite side
        bool sellSide = !buyYes;
        uint256 available = vaultBalances[marketId][sellSide];

        if (available > 0) {
            // OTC from vault - simplified: 1:1 exchange
            sharesOut = collateralIn > available ? available : collateralIn;
            vaultBalances[marketId][sellSide] -= sharesOut;

            // Transfer shares to buyer
            uint256 tokenId = buyYes ? marketId : _getNoId(marketId);

            // Mint new shares for the buyer (simplified - in reality would use vault shares)
            if (collateral == ETH) {
                PAMM.split{value: sharesOut}(marketId, sharesOut, address(this));
            } else {
                PAMM.split(marketId, sharesOut, address(this));
            }
            PAMM.transfer(to, tokenId, sharesOut);

            source = bytes4(0x6f746300); // "otc\0"

            // Refund excess collateral to msg.sender (MasterRouter)
            uint256 refund = collateralIn - sharesOut;
            if (refund > 0) {
                if (collateral == ETH) {
                    payable(msg.sender).transfer(refund);
                } else {
                    // ERC20 refund - this is what we're testing!
                    _safeTransfer(collateral, msg.sender, refund);
                }
            }
        } else {
            // No vault liquidity - mint new shares
            if (collateral == ETH) {
                PAMM.split{value: collateralIn}(marketId, collateralIn, address(this));
            } else {
                PAMM.split(marketId, collateralIn, address(this));
            }

            uint256 tokenId = buyYes ? marketId : _getNoId(marketId);
            PAMM.transfer(to, tokenId, collateralIn);

            // Deposit opposite side to vault
            uint256 oppositeId = buyYes ? _getNoId(marketId) : marketId;
            vaultBalances[marketId][!buyYes] += collateralIn;
            vaultSharesMinted = collateralIn;

            sharesOut = collateralIn;
            source = bytes4(0x6d696e74); // "mint"
        }
    }

    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256,
        /*minCollateralOut*/
        address to,
        uint256 /*deadline*/
    ) external returns (uint256 collateralOut, bytes4 source) {
        address collateral = _getCollateral(marketId);

        // Transfer shares from seller
        uint256 tokenId = sellYes ? marketId : _getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        // Check if we have vault liquidity on opposite side to merge
        bool buySide = !sellYes;
        uint256 available = vaultBalances[marketId][buySide];

        if (available >= sharesIn) {
            // Can merge with vault shares
            vaultBalances[marketId][buySide] -= sharesIn;
            collateralOut = sharesIn; // Simplified 1:1

            // Send collateral to seller
            if (collateral == ETH) {
                payable(to).transfer(collateralOut);
            } else {
                _safeTransfer(collateral, to, collateralOut);
            }
            source = bytes4(0x6f746300); // "otc\0"
        } else {
            // Deposit to vault instead
            vaultBalances[marketId][sellYes] += sharesIn;
            collateralOut = 0;
            source = bytes4(0x7661756c); // "vaul"
        }
    }

    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }
}

/// @title MasterRouter PMHookRouter Integration Tests
/// @notice Tests MasterRouter integration with PMHookRouter (mocked)
contract MasterRouterPMHookIntegrationTest is Test {
    MasterRouter public router;
    MockPMHookRouter public mockPMHookRouter;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0xa11ce);
    address public bob = address(0xb0b);
    address public carol = address(0xca201);
    address public dave = address(0xda4e);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        // Fork mainnet where PAMM is deployed
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy mock PMHookRouter
        mockPMHookRouter = new MockPMHookRouter();

        // Deploy the mock at the expected address using vm.etch
        address expectedAddr = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
        vm.etch(expectedAddr, address(mockPMHookRouter).code);

        // Also need to copy storage - give the mock some ETH
        vm.deal(expectedAddr, 1000 ether);

        // Set PAMM operator approval for the mock
        vm.prank(expectedAddr);
        pamm.setOperator(expectedAddr, true);

        // Deploy MasterRouter (will use the mock at expectedAddr)
        router = new MasterRouter();

        // Create market directly via PAMM
        (marketId, noId) = pamm.createMarket(
            "Test Market - MasterRouter Integration",
            address(this),
            address(0), // ETH
            uint64(block.timestamp + 30 days),
            false
        );

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
    }

    function _getNoId(uint256 _marketId) internal pure returns (uint256 _noId) {
        assembly {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, _marketId)
            _noId := keccak256(0x00, 0x2a)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    POOLED ORDERBOOK TESTS (no PMHookRouter needed)
    //////////////////////////////////////////////////////////////*/

    function test_mintAndPool_basic() public {
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 4000, alice);

        // Alice should have YES tokens
        assertEq(pamm.balanceOf(alice, marketId), 10 ether, "Alice should have YES");

        // Pool should have NO tokens
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, 10 ether, "Pool should have 10 NO shares");
    }

    function test_fillFromPool_basic() public {
        // Alice pools NO at 40%
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 4000, alice);

        // Bob fills from pool
        vm.prank(bob);
        (uint256 bought, uint256 paid) =
            router.fillFromPool{value: 4 ether}(marketId, false, 4000, 10 ether, 0, bob, 0);

        assertEq(bought, 10 ether, "Should buy 10 NO shares");
        assertEq(paid, 4 ether, "Should pay 4 ETH (10 * 0.40)");
        assertEq(pamm.balanceOf(bob, noId), 10 ether, "Bob should have NO tokens");
    }

    function test_claimProceeds_basic() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob fills
        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);

        // Alice claims
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 5000, alice);

        assertEq(claimed, 5 ether, "Alice should claim 5 ETH");
        assertEq(alice.balance - aliceBalBefore, 5 ether, "Alice balance should increase");
    }

    function test_withdrawFromPool_basic() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob fills half
        vm.prank(bob);
        router.fillFromPool{value: 2.5 ether}(marketId, false, 5000, 5 ether, 0, bob, 0);

        // Alice claims first (required before withdraw)
        vm.prank(alice);
        router.claimProceeds(marketId, false, 5000, alice);

        // Alice withdraws remaining
        vm.prank(alice);
        (uint256 withdrawn,) = router.withdrawFromPool(marketId, false, 5000, 0, alice);

        assertEq(withdrawn, 5 ether, "Alice should withdraw 5 NO shares");
        assertEq(pamm.balanceOf(alice, noId), 5 ether, "Alice should have NO tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-USER POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multiUser_poolAndFill() public {
        // Alice and Bob both pool at same price
        vm.prank(alice);
        router.mintAndPool{value: 6 ether}(marketId, 6 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 4 ether}(marketId, 4 ether, true, 5000, bob);

        // Carol fills everything
        vm.prank(carol);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, carol, 0);

        // Both should be able to claim proportionally
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);

        // Alice had 60%, Bob had 40%
        assertEq(aliceClaimed, 3 ether, "Alice should get 60% = 3 ETH");
        assertEq(bobClaimed, 2 ether, "Bob should get 40% = 2 ETH");
    }

    function test_multiUser_partialFillAndWithdraw() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob pools
        vm.prank(bob);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, bob);

        // Carol fills 10 (half the pool)
        vm.prank(carol);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, carol, 0);

        // Alice claims her share (2.5 ETH = 50% of 5 ETH)
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(aliceClaimed, 2.5 ether, "Alice claims 2.5 ETH");

        // Alice withdraws remaining shares
        vm.prank(alice);
        (uint256 aliceWithdrawn,) = router.withdrawFromPool(marketId, false, 5000, 0, alice);
        assertEq(aliceWithdrawn, 5 ether, "Alice withdraws 5 NO shares");

        // Bob can still claim his share
        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);
        assertEq(bobClaimed, 2.5 ether, "Bob claims 2.5 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE TIER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multiplePriceTiers() public {
        // Alice pools at 40%
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 4000, alice);

        // Bob pools at 60%
        vm.prank(bob);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 6000, bob);

        // Carol buys from cheaper tier first
        vm.prank(carol);
        (uint256 bought1,) =
            router.fillFromPool{value: 2 ether}(marketId, false, 4000, 5 ether, 0, carol, 0);
        assertEq(bought1, 5 ether, "Should buy all 5 shares at 40%");

        // Carol buys from more expensive tier
        vm.prank(carol);
        (uint256 bought2,) =
            router.fillFromPool{value: 3 ether}(marketId, false, 6000, 5 ether, 0, carol, 0);
        assertEq(bought2, 5 ether, "Should buy all 5 shares at 60%");

        // Verify claims
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 4000, alice);
        assertEq(aliceClaimed, 2 ether, "Alice gets 2 ETH from 40% tier");

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 6000, bob);
        assertEq(bobClaimed, 3 ether, "Bob gets 3 ETH from 60% tier");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_fillMoreThanAvailable() public {
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, alice);

        vm.prank(bob);
        vm.expectRevert();
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);
    }

    function test_revert_withdrawMoreThanOwned() public {
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, alice);

        vm.prank(bob);
        vm.expectRevert();
        router.withdrawFromPool(marketId, false, 5000, 1 ether, bob);
    }

    function test_revert_invalidPrice() public {
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 0, alice);

        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 10000, alice);
    }

    /*//////////////////////////////////////////////////////////////
                    GAS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function testGas_mintAndPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);
    }

    function testGas_fillFromPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);
    }

    function testGas_claimProceeds() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, 0, bob, 0);

        vm.prank(alice);
        router.claimProceeds(marketId, false, 5000, alice);
    }

    function testGas_withdrawFromPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 5 ether, alice);
    }

    /*//////////////////////////////////////////////////////////////
                    PMHOOKROUTER ROUTING INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test buy() routes correctly through PMHookRouter
    /// @dev This tests the PMHookRouter integration path (not just pool fills)
    function test_buy_routesThroughPMHookRouter() public {
        // Buy YES shares via PMHookRouter (no pool price specified)
        vm.prank(alice);
        (uint256 sharesOut, bytes4[] memory sources) = router.buy{value: 5 ether}(
            marketId,
            true, // buyYes
            5 ether, // collateralIn
            0, // minSharesOut
            0, // poolPriceInBps (0 = skip pool)
            alice,
            0 // deadline
        );

        assertGt(sharesOut, 0, "Should receive shares");
        assertEq(sources.length, 1, "Should have one source");
        assertEq(pamm.balanceOf(alice, marketId), sharesOut, "Alice should have YES tokens");
    }

    /// @notice Test sell() routes correctly through PMHookRouter
    /// @dev This is the critical test that would have caught the pre-transfer bug
    function test_sell_routesThroughPMHookRouter() public {
        // First, alice gets some YES shares
        vm.prank(alice);
        router.buy{value: 10 ether}(marketId, true, 10 ether, 0, 0, alice, 0);

        uint256 aliceYesBefore = pamm.balanceOf(alice, marketId);
        assertGt(aliceYesBefore, 0, "Alice should have YES shares");

        // Approve MasterRouter to transfer shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Sell YES shares via PMHookRouter (no bid pool price specified)
        vm.prank(alice);
        (uint256 collateralOut, bytes4[] memory sources) = router.sell(
            marketId,
            true, // sellYes
            aliceYesBefore, // sharesIn
            0, // minCollateralOut
            0, // bidPoolPriceInBps (0 = skip bid pool)
            alice,
            0 // deadline
        );

        // Should complete without reverting - this would have failed with the bug
        assertEq(pamm.balanceOf(alice, marketId), 0, "Alice should have sold all YES");
        assertEq(sources.length, 1, "Should have one source");
    }

    /// @notice Test sell() with bid pool partial fill + PMHookRouter routing
    function test_sell_bidPoolThenPMHookRouter() public {
        // Setup: Carol creates a bid pool for YES at 60%
        vm.prank(carol);
        router.createBidPool{value: 3 ether}(marketId, 3 ether, true, 6000, carol);

        // Alice gets YES shares
        vm.prank(alice);
        router.buy{value: 10 ether}(marketId, true, 10 ether, 0, 0, alice, 0);

        uint256 aliceYes = pamm.balanceOf(alice, marketId);

        // Approve
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Sell with bid pool routing (should fill some from pool, rest from PMHookRouter)
        vm.prank(alice);
        (uint256 collateralOut, bytes4[] memory sources) = router.sell(
            marketId,
            true, // sellYes
            aliceYes, // sharesIn
            0, // minCollateralOut
            6000, // bidPoolPriceInBps (try Carol's bid pool)
            alice,
            0
        );

        // Should have filled from bid pool + PMHookRouter
        assertEq(pamm.balanceOf(alice, marketId), 0, "Alice sold all shares");
        // Sources could be 1 (just bid pool or just PMHookRouter) or 2 (both)
        assertGt(sources.length, 0, "Should have sources");
    }

    /// @notice Test buy() with pool fill + PMHookRouter routing
    function test_buy_poolThenPMHookRouter() public {
        // Setup: Alice creates a pool selling NO at 40%
        vm.prank(alice);
        router.mintAndPool{value: 3 ether}(marketId, 3 ether, true, 4000, alice);

        // Bob buys with pool routing (should fill some from pool, rest from PMHookRouter)
        vm.prank(bob);
        (uint256 sharesOut, bytes4[] memory sources) = router.buy{value: 10 ether}(
            marketId,
            false, // buyNo
            10 ether, // collateralIn
            0, // minSharesOut
            4000, // poolPriceInBps (try Alice's pool)
            bob,
            0
        );

        assertGt(sharesOut, 0, "Bob should receive NO shares");
        // Could be 1 source (pool filled everything) or 2 (pool + PMHookRouter)
        assertGt(sources.length, 0, "Should have sources");
    }

    /// @notice Test mintAndVault routes correctly through PMHookRouter
    function test_mintAndVault_integration() public {
        vm.prank(alice);
        (uint256 sharesKept, uint256 vaultShares) = router.mintAndVault{value: 5 ether}(
            marketId,
            5 ether, // collateralIn
            true, // keepYes
            alice
        );

        assertEq(sharesKept, 5 ether, "Should keep 5 YES shares");
        assertEq(pamm.balanceOf(alice, marketId), 5 ether, "Alice has YES");
        assertGt(vaultShares, 0, "Should receive vault shares");
    }

    /*//////////////////////////////////////////////////////////////
                    REGRESSION TESTS FOR BUG FIXES
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression test: buy() must properly handle ETH refunds from PMHookRouter
    /// @dev When PMHookRouter does a partial fill and refunds unused ETH, MasterRouter must
    ///      detect this and update ETH tracking so the user gets their refund.
    ///      BUG: The old code checked (balanceAfter > balanceBefore) which is NEVER true
    ///      because we sent ETH out. Fix: check (balanceAfter > balanceBefore - amountSent)
    function test_regression_buyETHRefundFromPMHookRouter() public {
        // Step 1: Create vault liquidity that's LESS than what we'll try to buy
        // mintAndVault(keepYes=true) deposits NO shares to vault
        vm.prank(alice);
        router.mintAndVault{value: 3 ether}(marketId, 3 ether, true, alice);
        // Now vault has 3 ETH worth of NO shares

        // Step 2: Bob tries to buy YES with 10 ETH
        // Mock will check NO vault (sellSide for YES buy), find 3 ETH liquidity
        // Mock does OTC for 3 ETH, refunds 7 ETH back to MasterRouter
        uint256 bobBalanceBefore = bob.balance;
        uint256 routerBalanceBefore = address(router).balance;

        vm.prank(bob);
        (uint256 sharesOut,) = router.buy{value: 10 ether}(
            marketId,
            true, // buyYes - will check NO vault for OTC
            10 ether,
            0, // minSharesOut
            0, // poolPriceInBps (skip pool)
            bob,
            0
        );

        // Step 3: Verify ETH handling
        // Bob should have received a refund for the unused 7 ETH
        // With the bug: Bob loses 7 ETH (stuck in router)
        // With the fix: Bob only spends 3 ETH

        uint256 bobBalanceAfter = bob.balance;
        uint256 routerBalanceAfter = address(router).balance;

        // Bob should only have spent 3 ETH (the OTC fill amount)
        assertEq(
            bobBalanceBefore - bobBalanceAfter,
            3 ether,
            "Bob should only spend ETH for actual fill, not lose refund"
        );

        // Router should not be holding any excess ETH
        assertEq(
            routerBalanceAfter,
            routerBalanceBefore,
            "Router should not hold excess ETH from failed refund detection"
        );

        // Verify Bob got shares
        assertEq(sharesOut, 3 ether, "Bob should receive shares equal to OTC fill");
        assertEq(pamm.balanceOf(bob, marketId), 3 ether, "Bob has YES tokens");
    }

    /// @notice Regression test: buy() ETH refund works correctly in multicall
    /// @dev Same bug but in multicall context where ETH tracking is cumulative
    function test_regression_buyETHRefundInMulticall() public {
        // Setup vault liquidity
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        uint256 bobBalanceBefore = bob.balance;

        // Bob does multicall: [buy 10 ETH] where only 5 ETH can be filled via OTC
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(router.buy, (marketId, true, 10 ether, 0, 0, bob, 0));

        vm.prank(bob);
        router.multicall{value: 10 ether}(calls);

        uint256 bobBalanceAfter = bob.balance;

        // Bob should get 5 ETH refund (10 sent - 5 used)
        assertEq(
            bobBalanceBefore - bobBalanceAfter,
            5 ether,
            "Multicall: Bob should only spend ETH for actual fill"
        );

        // Router should have no significant excess ETH (allow minor dust from rounding)
        assertLe(address(router).balance, 10, "Multicall: Router should not hold significant ETH");
    }

    /// @notice Regression test: sell() must not pre-transfer shares before PMHookRouter call
    /// @dev PMHookRouter.sellWithBootstrap pulls shares via transferFrom(msg.sender, ...)
    ///      If MasterRouter pre-transfers, the transferFrom fails because shares are gone
    function test_regression_sellDoesNotPreTransfer() public {
        // Get shares
        vm.prank(alice);
        router.buy{value: 5 ether}(marketId, true, 5 ether, 0, 0, alice, 0);

        uint256 shares = pamm.balanceOf(alice, marketId);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // This call would revert with the old buggy code that pre-transferred shares
        // because PMHookRouter.sellWithBootstrap does:
        //   PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn)
        // which expects shares to still be in MasterRouter
        vm.prank(alice);
        router.sell(marketId, true, shares, 0, 0, alice, 0);

        // If we get here, the fix is working
        assertEq(pamm.balanceOf(alice, marketId), 0, "Shares sold successfully");
    }

    /*//////////////////////////////////////////////////////////////
                    BUY WITH SWEEP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test buyWithSweep fills multiple price levels in order
    /// @dev When keepYes=false, mintAndPool creates ASK pools selling YES shares
    function test_buyWithSweep_multiplePoolLevels() public {
        // Alice creates pool selling YES at 40% (keepYes=false means sell YES)
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4000, alice);

        // Bob creates pool selling YES at 45%
        vm.prank(bob);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4500, bob);

        // Carol creates pool selling YES at 50%
        vm.prank(carol);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 5000, carol);

        // Dave buys YES with sweep up to 50%
        vm.prank(dave);
        (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 levelsFilled,
            bytes4[] memory sources
        ) = router.buyWithSweep{value: 10 ether}(
            marketId,
            true, // buyYes - buy from ASK pools selling YES
            10 ether,
            0, // minSharesOut
            5000, // maxPriceBps - sweep all pools up to 50%
            dave,
            0
        );

        // Should have filled from 40% and 45% pools (cheapest first)
        // 40%: 5 shares cost 2 ETH (5 * 0.4)
        // 45%: 5 shares cost 2.25 ETH (5 * 0.45)
        // Total from pools: 10 shares for ~4.25 ETH
        // Remaining ~5.75 ETH goes to PMHookRouter

        assertGt(poolSharesOut, 0, "Should have filled from pools");
        assertGe(levelsFilled, 2, "Should have filled at least 2 price levels");
        assertGt(totalSharesOut, poolSharesOut, "Should have additional shares from PMHookRouter");
        assertEq(sources.length, 2, "Should have 2 sources (POOL + PMHookRouter)");
        assertEq(sources[0], bytes4(keccak256("POOL")), "First source should be POOL");

        // Verify Dave received shares
        assertEq(pamm.balanceOf(dave, marketId), totalSharesOut, "Dave has correct YES balance");
    }

    /// @notice Test buyWithSweep respects maxPriceBps limit
    function test_buyWithSweep_respectsMaxPrice() public {
        // Create pools selling YES at different prices
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4000, alice); // 40%

        vm.prank(bob);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 6000, bob); // 60%

        // Dave sweeps only up to 45% - should skip 60% pool
        vm.prank(dave);
        (uint256 totalSharesOut, uint256 poolSharesOut, uint256 levelsFilled,) = router.buyWithSweep{
            value: 10 ether
        }(
            marketId,
            true,
            10 ether,
            0,
            4500, // maxPriceBps - only fill pools at 45% or below
            dave,
            0
        );

        // Should only fill from 40% pool
        assertEq(levelsFilled, 1, "Should have filled exactly 1 price level");

        // 40% pool: 5 shares cost 2 ETH
        assertEq(poolSharesOut, 5 ether, "Should have filled entire 40% pool");

        // 60% pool should be untouched (isYes=true because we're buying YES)
        bytes32 pool60 = router.getPoolId(marketId, true, 6000);
        (uint256 remaining,,,) = router.pools(pool60);
        assertEq(remaining, 5 ether, "60% pool should be untouched");
    }

    /// @notice Test buyWithSweep with maxPriceBps=0 skips pools entirely
    function test_buyWithSweep_skipPoolsWhenMaxPriceZero() public {
        // Create a pool selling YES
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4000, alice);

        // Dave buys with maxPriceBps=0 - should skip pools
        vm.prank(dave);
        (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 levelsFilled,
            bytes4[] memory sources
        ) = router.buyWithSweep{value: 5 ether}(
            marketId,
            true,
            5 ether,
            0,
            0, // maxPriceBps=0 - skip pools
            dave,
            0
        );

        assertEq(poolSharesOut, 0, "No shares from pools");
        assertEq(levelsFilled, 0, "No levels filled");
        assertGt(totalSharesOut, 0, "Should have shares from PMHookRouter");
        assertEq(sources.length, 1, "Only PMHookRouter source");

        // Pool should be untouched (isYes=true for YES ASK pool)
        bytes32 poolId = router.getPoolId(marketId, true, 4000);
        (uint256 remaining,,,) = router.pools(poolId);
        assertEq(remaining, 5 ether, "Pool should be untouched");
    }

    /// @notice Test buyWithSweep partial fill of last pool
    function test_buyWithSweep_partialFillLastPool() public {
        // Create single pool selling YES at 50%
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, false, 5000, alice);

        // Dave buys 3 ETH worth - should partially fill
        vm.prank(dave);
        (uint256 totalSharesOut, uint256 poolSharesOut, uint256 levelsFilled,) =
            router.buyWithSweep{value: 3 ether}(marketId, true, 3 ether, 0, 5000, dave, 0);

        // At 50%, 3 ETH buys 6 shares
        assertEq(poolSharesOut, 6 ether, "Should buy 6 shares at 50%");
        assertEq(levelsFilled, 1, "One level touched");
        assertEq(totalSharesOut, poolSharesOut, "All shares from pool (no PMHookRouter needed)");

        // Pool should have 4 shares remaining
        bytes32 poolId = router.getPoolId(marketId, true, 5000);
        (uint256 remaining,,,) = router.pools(poolId);
        assertEq(remaining, 4 ether, "Pool should have 4 shares remaining");
    }

    /// @notice Test buyWithSweep fills pools in correct order (lowest first)
    function test_buyWithSweep_fillsLowestPriceFirst() public {
        // Create pools in reverse order (highest first) - all selling YES
        vm.prank(carol);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, false, 5000, carol); // 50%

        vm.prank(bob);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, false, 4000, bob); // 40%

        vm.prank(alice);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, false, 3000, alice); // 30%

        // Dave buys exactly enough to fill 30% and 40% pools
        // 30%: 2 shares = 0.6 ETH
        // 40%: 2 shares = 0.8 ETH
        // Total: 1.4 ETH
        vm.prank(dave);
        (, uint256 poolSharesOut, uint256 levelsFilled, bytes4[] memory sources) =
            router.buyWithSweep{value: 1.4 ether}(marketId, true, 1.4 ether, 0, 5000, dave, 0);

        assertEq(poolSharesOut, 4 ether, "Should have bought 4 shares from pools");
        assertEq(levelsFilled, 2, "Should have filled 2 levels");
        assertEq(sources.length, 1, "Only pool source (no PMHookRouter needed)");

        // 30% and 40% pools should be empty
        bytes32 pool30 = router.getPoolId(marketId, true, 3000);
        bytes32 pool40 = router.getPoolId(marketId, true, 4000);
        bytes32 pool50 = router.getPoolId(marketId, true, 5000);

        (uint256 remaining30,,,) = router.pools(pool30);
        (uint256 remaining40,,,) = router.pools(pool40);
        (uint256 remaining50,,,) = router.pools(pool50);

        assertEq(remaining30, 0, "30% pool should be empty");
        assertEq(remaining40, 0, "40% pool should be empty");
        assertEq(remaining50, 2 ether, "50% pool should be untouched");
    }

    /// @notice Gas test for buyWithSweep
    function testGas_buyWithSweep() public {
        // Create multiple pools selling YES
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4000, alice);
        vm.prank(bob);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 4500, bob);
        vm.prank(carol);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, false, 5000, carol);

        // Measure gas for sweep
        vm.prank(dave);
        router.buyWithSweep{value: 10 ether}(marketId, true, 10 ether, 0, 5000, dave, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SELL WITH SWEEP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test sellWithSweep fills multiple bid pool levels in order (highest first)
    /// @dev Bid pools are created by createBidPool - collateral pools waiting to buy shares
    function test_sellWithSweep_multipleBidPoolLevels() public {
        // First, give Alice some YES shares to sell
        vm.prank(alice);
        router.mintAndVault{value: 20 ether}(marketId, 20 ether, true, alice);
        // Alice now has 20 YES shares

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create bid pools at different prices (buyers waiting to buy YES)
        vm.prank(bob);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 6000, bob); // Bid at 60%

        vm.prank(carol);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 5500, carol); // Bid at 55%

        vm.prank(dave);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 5000, dave); // Bid at 50%

        // Alice sells YES shares with sweep down to 50%
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 levelsFilled,
            bytes4[] memory sources
        ) = router.sellWithSweep(
            marketId,
            true, // sellYes - sell to BID pools buying YES
            15 ether, // Sell 15 shares
            0, // minCollateralOut
            5000, // minPriceBps - accept bids at 50% or higher
            alice,
            0
        );

        // Should have filled from 60%, 55%, and potentially 50% pools (highest price first)
        assertGt(poolCollateralOut, 0, "Should have filled from bid pools");
        assertGe(levelsFilled, 2, "Should have filled at least 2 price levels");
        assertGt(totalCollateralOut, 0, "Should have received collateral");

        // Verify Alice received collateral
        assertGt(alice.balance, aliceBalanceBefore, "Alice should have more ETH");
    }

    /// @notice Test sellWithSweep respects minPriceBps limit
    function test_sellWithSweep_respectsMinPrice() public {
        // Give Alice YES shares
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, true, alice);

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create bid pools at different prices
        vm.prank(bob);
        router.createBidPool{value: 3 ether}(marketId, 3 ether, true, 6000, bob); // 60%

        vm.prank(carol);
        router.createBidPool{value: 3 ether}(marketId, 3 ether, true, 4000, carol); // 40%

        // Alice sells with minPrice=55% - should skip 40% pool
        vm.prank(alice);
        (uint256 totalCollateralOut, uint256 poolCollateralOut, uint256 levelsFilled,) = router.sellWithSweep(
            marketId,
            true,
            10 ether,
            0,
            5500, // minPriceBps - only accept bids at 55% or higher
            alice,
            0
        );

        // Should only fill from 60% pool
        assertEq(levelsFilled, 1, "Should have filled exactly 1 price level");

        // 40% pool should be untouched
        bytes32 pool40 = router.getBidPoolId(marketId, true, 4000);
        (uint256 remaining,,,) = router.bidPools(pool40);
        assertEq(remaining, 3 ether, "40% bid pool should be untouched");
    }

    /// @notice Test sellWithSweep with minPriceBps=0 skips pools entirely
    function test_sellWithSweep_skipPoolsWhenMinPriceZero() public {
        // Give Alice YES shares
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create a bid pool
        vm.prank(bob);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 6000, bob);

        // Alice sells with minPriceBps=0 - should skip pools
        vm.prank(alice);
        (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 levelsFilled,
            bytes4[] memory sources
        ) = router.sellWithSweep(
            marketId,
            true,
            5 ether,
            0,
            0, // minPriceBps=0 - skip pools
            alice,
            0
        );

        assertEq(poolCollateralOut, 0, "No collateral from pools");
        assertEq(levelsFilled, 0, "No levels filled");
        assertGt(totalCollateralOut, 0, "Should have collateral from PMHookRouter");
        assertEq(sources.length, 1, "Only PMHookRouter source");

        // Bid pool should be untouched
        bytes32 bidPoolId = router.getBidPoolId(marketId, true, 6000);
        (uint256 remaining,,,) = router.bidPools(bidPoolId);
        assertEq(remaining, 5 ether, "Bid pool should be untouched");
    }

    /// @notice Test sellWithSweep partial fill of last pool
    function test_sellWithSweep_partialFillLastPool() public {
        // Give Alice YES shares
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, true, alice);

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create single bid pool at 50% with enough collateral for 10 shares
        vm.prank(bob);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 5000, bob);
        // At 50%, 5 ETH can buy 10 shares

        // Alice sells only 3 shares - should partially fill
        vm.prank(alice);
        (uint256 totalCollateralOut, uint256 poolCollateralOut, uint256 levelsFilled,) =
            router.sellWithSweep(
                marketId,
                true,
                3 ether, // Sell 3 shares
                0,
                5000,
                alice,
                0
            );

        // At 50%, 3 shares = 1.5 ETH (ceiling = 1.5 ETH)
        assertEq(levelsFilled, 1, "One level touched");
        assertEq(
            totalCollateralOut,
            poolCollateralOut,
            "All collateral from pool (no PMHookRouter needed)"
        );

        // Bid pool should have remaining collateral
        bytes32 bidPoolId = router.getBidPoolId(marketId, true, 5000);
        (uint256 remaining,,,) = router.bidPools(bidPoolId);
        assertGt(remaining, 0, "Bid pool should have remaining collateral");
    }

    /// @notice Test sellWithSweep fills pools in correct order (highest first)
    function test_sellWithSweep_fillsHighestPriceFirst() public {
        // Give Alice YES shares
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, true, alice);

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create bid pools in arbitrary order
        vm.prank(dave);
        router.createBidPool{value: 1 ether}(marketId, 1 ether, true, 5000, dave); // 50%

        vm.prank(carol);
        router.createBidPool{value: 1 ether}(marketId, 1 ether, true, 7000, carol); // 70%

        vm.prank(bob);
        router.createBidPool{value: 1 ether}(marketId, 1 ether, true, 6000, bob); // 60%

        // Alice sells enough to fill 70% and 60% pools
        // 70%: 1 ETH buys ~1.43 shares
        // 60%: 1 ETH buys ~1.67 shares
        // Total: ~3.1 shares for 2 ETH - need at least 4 to empty both
        vm.prank(alice);
        (, uint256 poolCollateralOut, uint256 levelsFilled, bytes4[] memory sources) = router.sellWithSweep(
            marketId,
            true,
            5 ether, // Sell 5 shares to ensure 70% and 60% are fully emptied
            0,
            5000, // Accept bids down to 50%
            alice,
            0
        );

        assertGe(levelsFilled, 2, "Should have filled at least 2 levels");

        // 70% and 60% pools should be emptied first (highest prices)
        bytes32 pool70 = router.getBidPoolId(marketId, true, 7000);
        bytes32 pool60 = router.getBidPoolId(marketId, true, 6000);
        bytes32 pool50 = router.getBidPoolId(marketId, true, 5000);

        (uint256 remaining70,,,) = router.bidPools(pool70);
        (uint256 remaining60,,,) = router.bidPools(pool60);
        (uint256 remaining50,,,) = router.bidPools(pool50);

        assertEq(remaining70, 0, "70% pool should be empty (highest priority)");
        assertEq(remaining60, 0, "60% pool should be empty (second priority)");
        // 50% pool may or may not be touched depending on exact fill
    }

    /// @notice Gas test for sellWithSweep
    function testGas_sellWithSweep() public {
        // Give Alice YES shares
        vm.prank(alice);
        router.mintAndVault{value: 15 ether}(marketId, 15 ether, true, alice);

        // Alice must approve router to transfer her shares
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        // Create multiple bid pools
        vm.prank(bob);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 6000, bob);
        vm.prank(carol);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 5500, carol);
        vm.prank(dave);
        router.createBidPool{value: 5 ether}(marketId, 5 ether, true, 5000, dave);

        // Measure gas for sweep
        vm.prank(alice);
        router.sellWithSweep(marketId, true, 10 ether, 0, 5000, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC20 REFUND REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression test: buy() ERC20 refund from PMHookRouter
    /// @dev Tests the fix for ERC20 refunds getting stuck in MasterRouter
    ///      PMHookRouter.buyWithBootstrap refunds unused collateral to msg.sender (MasterRouter)
    ///      MasterRouter must detect and forward this refund to the original caller
    function test_regression_buyERC20RefundFromPMHookRouter() public {
        // Use USDC as ERC20 collateral
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Create ERC20 market
        (uint256 usdcMarketId,) = pamm.createMarket(
            "USDC Refund Test Market",
            address(this), // resolver
            USDC,
            uint64(block.timestamp + 30 days),
            false
        );

        // Get USDC for alice and bob from whale
        address usdcWhale = 0x28C6c06298d514Db089934071355E5743bf21d60;
        uint256 aliceAmount = 100e6; // 100 USDC
        uint256 bobAmount = 200e6; // 200 USDC

        vm.prank(usdcWhale);
        (bool success,) =
            USDC.call(abi.encodeWithSignature("transfer(address,uint256)", alice, aliceAmount));
        require(success, "USDC transfer to alice failed");

        vm.prank(usdcWhale);
        (success,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", bob, bobAmount));
        require(success, "USDC transfer to bob failed");

        // Alice creates vault liquidity (only 50 USDC worth)
        // This limits how much OTC can fill
        vm.startPrank(alice);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success, "Alice approve failed");

        // mintAndVault with keepYes=true deposits NO shares to vault
        router.mintAndVault(usdcMarketId, 50e6, true, alice);
        vm.stopPrank();

        // Bob approves router
        vm.startPrank(bob);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success, "Bob approve failed");

        // Get Bob's USDC balance before
        (, bytes memory data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", bob));
        uint256 bobBalanceBefore = abi.decode(data, (uint256));

        // Get Router's USDC balance before (should be 0 or minimal)
        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerBalanceBefore = abi.decode(data, (uint256));

        // Bob tries to buy YES with 100 USDC
        // Mock PMHookRouter has only 50 USDC vault liquidity
        // It will do OTC for 50 USDC, refund 50 USDC back to MasterRouter
        // MasterRouter must forward that 50 USDC refund to Bob
        (uint256 sharesOut,) = router.buy(
            usdcMarketId,
            true, // buyYes
            100e6, // 100 USDC
            0, // minSharesOut
            0, // poolPriceInBps (skip pools)
            bob,
            0
        );
        vm.stopPrank();

        // Get balances after
        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", bob));
        uint256 bobBalanceAfter = abi.decode(data, (uint256));

        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerBalanceAfter = abi.decode(data, (uint256));

        // Verify: Bob should only have spent what was actually used
        // With the fix: refund is forwarded, Bob spends less
        // Without fix: refund stuck in router, Bob loses it

        // Router should NOT be holding Bob's refund
        assertLe(
            routerBalanceAfter,
            routerBalanceBefore + 1e6, // Allow 1 USDC tolerance for any dust
            "Router should not hold significant ERC20 refund - fix not working"
        );

        // Bob should have received shares
        assertGt(sharesOut, 0, "Bob should have received shares");
    }

    /// @notice Regression test: buyWithSweep() ERC20 refund from PMHookRouter
    /// @dev Same as above but for buyWithSweep path
    function test_regression_buyWithSweepERC20RefundFromPMHookRouter() public {
        // Use USDC as ERC20 collateral
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Create ERC20 market
        (uint256 usdcMarketId,) = pamm.createMarket(
            "USDC Sweep Refund Test", address(this), USDC, uint64(block.timestamp + 30 days), false
        );

        // Get USDC for test accounts
        address usdcWhale = 0x28C6c06298d514Db089934071355E5743bf21d60;

        vm.prank(usdcWhale);
        (bool success,) =
            USDC.call(abi.encodeWithSignature("transfer(address,uint256)", alice, 100e6));
        require(success);

        vm.prank(usdcWhale);
        (success,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", bob, 200e6));
        require(success);

        // Alice creates limited vault liquidity
        vm.startPrank(alice);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success);
        router.mintAndVault(usdcMarketId, 30e6, true, alice);
        vm.stopPrank();

        // Bob approves and calls buyWithSweep
        vm.startPrank(bob);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success);

        (, bytes memory data) =
            USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerBalanceBefore = abi.decode(data, (uint256));

        // Buy with sweep - no pools, will route to PMHookRouter
        router.buyWithSweep(
            usdcMarketId,
            true, // buyYes
            100e6, // 100 USDC
            0, // minSharesOut
            0, // maxPriceBps (skip pools)
            bob,
            0
        );
        vm.stopPrank();

        // Verify router doesn't hold the refund
        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerBalanceAfter = abi.decode(data, (uint256));

        assertLe(
            routerBalanceAfter,
            routerBalanceBefore + 1e6,
            "buyWithSweep: Router should not hold ERC20 refund"
        );
    }

    /// @notice Explicit test for _getBalance() correctness with ERC20 refunds
    /// @dev This test validates that the Solady-style _getBalance() assembly pattern
    ///      correctly reads ERC20 balances, which is critical for refund detection.
    ///      The pattern: mstore(0x14, account); mstore(0x00, 0x70a08231...); staticcall(0x10, 0x24, ...)
    function test_getBalance_correctlyDetectsERC20Refund() public {
        // Use USDC as ERC20 collateral
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Create ERC20 market
        (uint256 usdcMarketId,) = pamm.createMarket(
            "USDC _getBalance Test", address(this), USDC, uint64(block.timestamp + 30 days), false
        );

        // Get USDC from whale
        address usdcWhale = 0x28C6c06298d514Db089934071355E5743bf21d60;
        uint256 aliceAmount = 50e6; // 50 USDC for vault
        uint256 bobAmount = 100e6; // 100 USDC to spend

        vm.prank(usdcWhale);
        (bool success,) =
            USDC.call(abi.encodeWithSignature("transfer(address,uint256)", alice, aliceAmount));
        require(success, "USDC transfer to alice failed");

        vm.prank(usdcWhale);
        (success,) = USDC.call(abi.encodeWithSignature("transfer(address,uint256)", bob, bobAmount));
        require(success, "USDC transfer to bob failed");

        // Alice creates vault with 30 USDC (limits OTC to 30 USDC)
        vm.startPrank(alice);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success);
        router.mintAndVault(usdcMarketId, 30e6, true, alice);
        vm.stopPrank();

        // Bob approves router
        vm.startPrank(bob);
        (success,) = USDC.call(
            abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max)
        );
        require(success);

        // Record Bob's USDC balance before
        (, bytes memory data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", bob));
        uint256 bobUsdcBefore = abi.decode(data, (uint256));
        assertEq(bobUsdcBefore, bobAmount, "Bob should have 100 USDC");

        // Record router USDC balance before (should be 0)
        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerUsdcBefore = abi.decode(data, (uint256));

        // Bob buys YES with 100 USDC
        // Mock has 30 USDC OTC liquidity -> fills 30, should refund 70
        (uint256 sharesOut,) = router.buy(
            usdcMarketId,
            true, // buyYes
            100e6, // 100 USDC
            0, // minSharesOut
            0, // poolPriceInBps (skip pools, use PMHookRouter)
            bob,
            0
        );
        vm.stopPrank();

        // Record balances after
        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", bob));
        uint256 bobUsdcAfter = abi.decode(data, (uint256));

        (, data) = USDC.call(abi.encodeWithSignature("balanceOf(address)", address(router)));
        uint256 routerUsdcAfter = abi.decode(data, (uint256));

        // Verify Bob got shares
        assertGt(sharesOut, 0, "Bob should have received shares");
        assertEq(pamm.balanceOf(bob, usdcMarketId), sharesOut, "Bob should have YES tokens");

        // CRITICAL: Router should NOT be holding Bob's refund
        // If _getBalance() is broken, refund detection fails and USDC gets stuck
        assertLe(
            routerUsdcAfter,
            routerUsdcBefore,
            "CRITICAL: Router is holding ERC20 refund - _getBalance() may be broken"
        );

        // Verify Bob's net spend is reasonable (30 USDC for OTC, not 100)
        uint256 bobSpent = bobUsdcBefore - bobUsdcAfter;
        assertLe(
            bobSpent,
            35e6, // Allow some tolerance for mock behavior
            "Bob should have received refund - spent too much USDC"
        );

        // Log for debugging
        emit log_named_uint("Bob USDC before", bobUsdcBefore);
        emit log_named_uint("Bob USDC after", bobUsdcAfter);
        emit log_named_uint("Bob USDC spent", bobSpent);
        emit log_named_uint("Router USDC before", routerUsdcBefore);
        emit log_named_uint("Router USDC after", routerUsdcAfter);
        emit log_named_uint("Shares received", sharesOut);
    }
}
