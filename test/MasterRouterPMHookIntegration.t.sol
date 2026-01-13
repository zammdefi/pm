// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouter.sol";

interface IPMHookRouterBootstrap {
    function bootstrapMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut);
}

interface IPAMMExtended is IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @title MasterRouter PMHookRouter Integration Tests
/// @notice Comprehensive tests for MasterRouter <-> PMHookRouter integration
/// @dev These tests use properly bootstrapped markets via PMHookRouter
contract MasterRouterPMHookIntegrationTest is Test {
    MasterRouter public router;
    IPMHookRouterBootstrap public pmHookRouter;
    address public hook;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0xa11ce);
    address public bob = address(0xb0b);
    address public carol = address(0xca201);
    address public dave = address(0xda4e);

    uint256 public marketId;
    uint256 public poolId;
    uint256 public noId;

    function setUp() public {
        // Fork mainnet - PMHookRouter requires existing ZAMM deployment
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy contracts
        router = new MasterRouter();
        pmHookRouter = IPMHookRouterBootstrap(0x0000000000BADa259Cb860c12ccD9500d9496B3e);
        hook = 0x00000000009D87BA1450F6E8c598bFDC76B1d851;

        // Bootstrap a market via PMHookRouter so it's properly registered
        (marketId, poolId,,) = pmHookRouter.bootstrapMarket{value: 10 ether}(
            "Test Market - MasterRouter Integration",
            address(this), // resolver
            address(0), // ETH
            uint64(block.timestamp + 30 days), // close
            false, // canClose
            address(hook), // hook
            10 ether, // collateralForLP
            true, // buyYes (dummy buy)
            0, // collateralForBuy (no initial trade)
            0, // minSharesOut
            address(this), // to
            type(uint256).max // deadline
        );

        noId = _getNoId(marketId);

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

    /// @notice Helper to bootstrap a market with PMHookRouter and optionally add MasterRouter orderbook liquidity
    /// @param description Market description
    /// @param collateralForLP Amount to add to AMM pool via PMHookRouter
    /// @param addOrderbook Whether to add orderbook liquidity via MasterRouter
    /// @param orderbookCollateral Amount to add to orderbook (if addOrderbook=true)
    /// @param orderbookKeepYes Side to keep when adding to orderbook
    /// @param orderbookPrice Price in bps for orderbook liquidity
    /// @return _marketId The created market ID
    /// @return _poolId The ZAMM pool ID
    /// @return _noId The NO token ID
    function bootstrapMarketWithOrderbook(
        string memory description,
        uint256 collateralForLP,
        bool addOrderbook,
        uint256 orderbookCollateral,
        bool orderbookKeepYes,
        uint256 orderbookPrice
    ) internal returns (uint256 _marketId, uint256 _poolId, uint256 _noId) {
        // Bootstrap market via PMHookRouter (creates market + AMM pool)
        (_marketId, _poolId,,) = pmHookRouter.bootstrapMarket{value: collateralForLP}(
            description,
            address(this), // resolver
            address(0), // ETH
            uint64(block.timestamp + 30 days), // close
            false, // canClose
            hook, // hook
            collateralForLP, // collateralForLP
            true, // buyYes (dummy)
            0, // collateralForBuy (no initial trade)
            0, // minSharesOut
            address(this), // to
            type(uint256).max // deadline
        );

        _noId = _getNoId(_marketId);

        // Optionally add orderbook liquidity via MasterRouter
        if (addOrderbook && orderbookCollateral > 0) {
            router.mintAndPool{value: orderbookCollateral}(
                _marketId, orderbookCollateral, orderbookKeepYes, orderbookPrice, address(this)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_helper_bootstrapMarketWithOrderbook() public {
        // Create a market with AMM liquidity + orderbook liquidity
        (uint256 newMarketId, uint256 newPoolId, uint256 newNoId) = bootstrapMarketWithOrderbook(
            "Orderbook Test Market",
            5 ether, // AMM liquidity
            true, // add orderbook
            3 ether, // orderbook collateral
            true, // keep YES (pool NO at 0.40)
            4000 // price = 40%
        );

        // Verify market was created
        assertGt(newMarketId, 0, "Market ID should be set");
        assertGt(newPoolId, 0, "Pool ID should be set");
        assertGt(newNoId, 0, "NO ID should be set");

        // Verify orderbook has liquidity
        bytes32 orderbookPoolId = router.getPoolId(newMarketId, false, 4000);
        (uint256 totalShares,,,) = router.pools(orderbookPoolId);
        assertEq(totalShares, 3 ether, "Orderbook should have 3 ETH of NO shares");

        // Test buying from orderbook
        vm.prank(alice);
        (uint256 bought, uint256 paid) =
            router.fillFromPool{value: 1.2 ether}(newMarketId, false, 4000, 3 ether, alice);

        assertEq(bought, 3 ether, "Should buy 3 NO shares");
        assertEq(paid, 1.2 ether, "Should pay 1.2 ETH (3 * 0.40)");
    }

    /*//////////////////////////////////////////////////////////////
                        MINT AND VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mintAndVault_depositYES() public {
        vm.prank(alice);
        (uint256 sharesKept, uint256 vaultShares) =
            router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, alice);

        assertEq(sharesKept, 1 ether, "Should keep 1 YES share");
        assertGt(vaultShares, 0, "Should receive vault shares");
        assertEq(pamm.balanceOf(alice, marketId), 1 ether, "Alice should have YES tokens");
    }

    function test_mintAndVault_depositNO() public {
        vm.prank(alice);
        (uint256 sharesKept, uint256 vaultShares) =
            router.mintAndVault{value: 1 ether}(marketId, 1 ether, false, alice);

        assertEq(sharesKept, 1 ether, "Should keep 1 NO share");
        assertGt(vaultShares, 0, "Should receive vault shares");
        assertEq(pamm.balanceOf(alice, noId), 1 ether, "Alice should have NO tokens");
    }

    function test_mintAndVault_multipleUsers() public {
        // Alice deposits YES side
        vm.prank(alice);
        (uint256 aliceShares, uint256 aliceVault) =
            router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        // Bob deposits NO side
        vm.prank(bob);
        (uint256 bobShares, uint256 bobVault) =
            router.mintAndVault{value: 3 ether}(marketId, 3 ether, false, bob);

        assertEq(aliceShares, 5 ether, "Alice keeps 5 YES");
        assertEq(bobShares, 3 ether, "Bob keeps 3 NO");
        assertGt(aliceVault, 0, "Alice has vault shares");
        assertGt(bobVault, 0, "Bob has vault shares");
    }

    /*//////////////////////////////////////////////////////////////
                            BUY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_buy_throughVault() public {
        // Setup: Alice provides vault liquidity
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        // Bob buys YES through the vault
        vm.prank(bob);
        (uint256 sharesOut, bytes4[] memory sources) =
            router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, 0);

        assertGt(sharesOut, 0, "Bob should get YES shares");
        assertGt(sources.length, 0, "Should have execution sources");
        assertGt(pamm.balanceOf(bob, marketId), 0, "Bob should have YES tokens");
    }

    function test_buy_withPoolFirst() public {
        // Setup pool liquidity at 40% (Alice keeps YES, pools NO)
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 4000, alice);

        // Setup vault liquidity
        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        // Carol buys NO - should fill from pool first, then vault if needed
        vm.prank(carol);
        (uint256 sharesOut, bytes4[] memory sources) =
            router.buy{value: 3 ether}(marketId, false, 3 ether, 0, 4000, 0, carol, 0);

        assertGt(sharesOut, 0, "Carol should get NO shares");

        // Check if pool was used by checking if totalShares decreased
        bytes32 poolId = router.getPoolId(marketId, false, 4000);
        (uint256 totalShares,,,) = router.pools(poolId);
        assertLt(totalShares, 5 ether, "Pool should have been partially filled");
    }

    function test_buy_poolExhaustedThenVault() public {
        // Setup small pool
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, alice);

        // Setup vault
        vm.prank(bob);
        router.mintAndVault{value: 20 ether}(marketId, 20 ether, false, bob);

        // Carol buys more than pool can provide
        vm.prank(carol);
        (uint256 sharesOut, bytes4[] memory sources) =
            router.buy{value: 5 ether}(marketId, false, 5 ether, 0, 4000, 0, carol, 0);

        assertGt(sharesOut, 0, "Carol should get shares");
        assertEq(sources.length, 2, "Should have used both pool and vault");
        assertEq(sources[0], bytes4(keccak256("POOL")), "First source should be POOL");
    }

    function test_buy_minSharesOut() public {
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 1 ether}(marketId, true, 1 ether, 100 ether, 0, 0, bob, 0);
    }

    function test_buy_deadline() public {
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, block.timestamp - 1);
    }

    /*//////////////////////////////////////////////////////////////
                            SELL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_sell_throughVault() public {
        // Alice gets YES shares
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        // Bob provides NO vault liquidity
        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        // Alice sells YES
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        (uint256 collateralOut, bytes4[] memory sources) =
            router.sell(marketId, true, 1 ether, 0, 0, alice, 0);

        assertGt(collateralOut, 0, "Alice should get collateral");
        assertGt(sources.length, 0, "Should have execution sources");
    }

    function test_sell_minCollateralOut() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 1 ether, 100 ether, 0, alice, 0);
    }

    function test_sell_deadline() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 1 ether, 0, 0, alice, block.timestamp - 1);
    }

    /*//////////////////////////////////////////////////////////////
                        COMBINED SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_scenario_fullRoundTrip() public {
        // Alice: mint and vault (provides NO liquidity)
        vm.prank(alice);
        (uint256 aliceShares, uint256 aliceVault) =
            router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        // Bob: buys YES through vault
        vm.prank(bob);
        (uint256 bobShares,) = router.buy{value: 2 ether}(marketId, true, 2 ether, 0, 0, 0, bob, 0);

        // Bob: sells some YES back
        vm.prank(bob);
        pamm.setOperator(address(router), true);

        vm.prank(bob);
        (uint256 bobCollateral,) = router.sell(marketId, true, 1 ether, 0, 0, bob, 0);

        assertGt(bobShares, 0, "Bob got YES shares");
        assertGt(bobCollateral, 0, "Bob got collateral back");
        assertGt(pamm.balanceOf(bob, marketId), 0, "Bob still has some YES");
    }

    function test_scenario_poolAndVaultTogether() public {
        // Alice: creates pool at 45%
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 4500, alice);

        // Bob: provides vault liquidity
        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        // Carol: buys from pool (cheaper)
        vm.prank(carol);
        (uint256 carolShares1,) =
            router.buy{value: 2 ether}(marketId, false, 2 ether, 0, 4500, 0, carol, 0);

        // Dave: buys more than pool has, uses both pool and vault
        vm.prank(dave);
        (uint256 daveShares, bytes4[] memory daveSources) =
            router.buy{value: 10 ether}(marketId, false, 10 ether, 0, 4500, 0, dave, 0);

        assertGt(carolShares1, 0, "Carol got shares from pool");
        assertGt(daveShares, 0, "Dave got shares");

        // Dave should have used both sources if pool was partially filled
        bytes32 davePoolId = router.getPoolId(marketId, false, 4500);
        (uint256 remainingShares,,,) = router.pools(davePoolId);
        if (remainingShares < 5 ether) {
            // Pool was used (some shares consumed)
            assertGt(daveSources.length, 0, "Dave used at least one source");
        }
    }

    function test_scenario_multipleUsersLiquidity() public {
        // Multiple users provide liquidity
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        vm.prank(carol);
        router.mintAndVault{value: 3 ether}(marketId, 3 ether, true, carol);

        // Dave trades
        vm.prank(dave);
        (uint256 daveYES,) = router.buy{value: 2 ether}(marketId, true, 2 ether, 0, 0, 0, dave, 0);

        assertGt(daveYES, 0, "Dave got YES shares");

        // Dave sells back
        vm.prank(dave);
        pamm.setOperator(address(router), true);

        vm.prank(dave);
        (uint256 daveCollateral,) = router.sell(marketId, true, 1 ether, 0, 0, dave, 0);

        assertGt(daveCollateral, 0, "Dave got collateral");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_buy_zeroCollateral() public {
        vm.prank(alice);
        vm.expectRevert();
        router.buy{value: 0}(marketId, true, 0, 0, 0, 0, alice, 0);
    }

    function test_sell_zeroShares() public {
        vm.prank(alice);
        router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, alice);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 0, 0, 0, alice, 0);
    }

    function test_buy_withoutApproval() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, false, alice);

        // Bob tries to buy - should work because buy doesn't need operator approval
        vm.prank(bob);
        (uint256 shares,) = router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, 0);

        assertGt(shares, 0, "Buy should work without operator approval");
    }

    function test_sell_withoutApproval() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        // Alice tries to sell without operator approval - should fail
        vm.prank(alice);
        vm.expectRevert();
        router.sell(marketId, true, 1 ether, 0, 0, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function testGas_mintAndVault() public {
        vm.prank(alice);
        router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, alice);
    }

    function testGas_buy() public {
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        vm.prank(bob);
        router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, 0);
    }

    function testGas_sell() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        router.sell(marketId, true, 1 ether, 0, 0, alice, 0);
    }

    function testGas_buyWithPoolFirst() public {
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 4000, alice);

        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        vm.prank(carol);
        router.buy{value: 3 ether}(marketId, false, 3 ether, 0, 4000, 0, carol, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        RETURN VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_buy_returnsCorrectSources() public {
        vm.prank(alice);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, alice);

        vm.prank(bob);
        (uint256 sharesOut, bytes4[] memory sources) =
            router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, 0);

        assertGt(sharesOut, 0, "Should get shares");
        assertEq(sources.length, 1, "Should have one source");
        // Source should be from PMHookRouter (otc, amm, or mint)
        assertTrue(
            sources[0] == bytes4(0x6f746300) // "otc\0"
                || sources[0] == bytes4(0x616d6d00) // "amm\0"
                || sources[0] == bytes4(0x6d696e74), // "mint"
            "Source should be otc, amm, or mint"
        );
    }

    function test_sell_returnsCorrectSources() public {
        vm.prank(alice);
        router.mintAndVault{value: 5 ether}(marketId, 5 ether, true, alice);

        vm.prank(bob);
        router.mintAndVault{value: 10 ether}(marketId, 10 ether, false, bob);

        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        (uint256 collateralOut, bytes4[] memory sources) =
            router.sell(marketId, true, 1 ether, 0, 0, alice, 0);

        assertGt(collateralOut, 0, "Should get collateral");
        assertEq(sources.length, 1, "Should have one source");
    }
}
