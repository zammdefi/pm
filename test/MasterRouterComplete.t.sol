// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouterComplete.sol";

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

contract MasterRouterCompleteTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter public pmHookRouter = IPMHookRouter(0x000000000050D5716568008f83854D67c7ab3D22);

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public taker = address(0x4);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = new MasterRouter();

        (marketId, noId) = pamm.createMarket(
            "Test Market", address(this), address(0), uint64(block.timestamp + 30 days), false
        );

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(taker, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       POOLED ORDERBOOK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_pooledOrderbook_basicFlow() public {
        // Alice pools NO at 0.40
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, alice);

        // Check Alice got YES
        assertEq(pamm.balanceOf(alice, marketId), 1 ether, "Alice should have YES");

        // Taker fills from pool
        vm.prank(taker);
        (uint256 bought, uint256 paid) =
            router.fillFromPool{value: 0.4 ether}(marketId, false, 4000, 1 ether, taker);

        assertEq(bought, 1 ether, "Should buy 1 share");
        assertEq(paid, 0.4 ether, "Should pay 0.4 ETH");

        // Alice claims
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 4000, alice);
        assertEq(claimed, 0.4 ether, "Alice should get 0.4 ETH");
    }

    function test_pooledOrderbook_multipleUsers() public {
        // Multiple users pool at 0.50
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, bob);

        // Taker fills 2 shares
        vm.prank(taker);
        router.fillFromPool{value: 1 ether}(marketId, false, 5000, 2 ether, taker);

        // Check proportional earnings
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);
        assertApproxEqAbs(aliceClaimed, 0.333333333333333333 ether, 1e9, "Alice gets 1/3");

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);
        assertApproxEqAbs(bobClaimed, 0.666666666666666666 ether, 1e9, "Bob gets 2/3");
    }

    function test_pooledOrderbook_withdraw() public {
        vm.prank(alice);
        router.mintAndPool{value: 2 ether}(marketId, 2 ether, true, 5000, alice);

        // Partial fill
        vm.prank(taker);
        router.fillFromPool{value: 0.5 ether}(marketId, false, 5000, 1 ether, taker);

        // Withdraw unfilled
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromPool(marketId, false, 5000, 0, alice);
        assertEq(withdrawn, 1 ether, "Should withdraw 1 unfilled share");
    }

    /*//////////////////////////////////////////////////////////////
                       VAULT INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_vault_mintAndVault() public {
        vm.prank(alice);
        (uint256 sharesKept, uint256 vaultShares) =
            router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, alice);

        assertEq(sharesKept, 1 ether, "Alice should keep YES shares");
        assertGt(vaultShares, 0, "Alice should get vault shares");

        // Alice got YES directly
        assertEq(pamm.balanceOf(alice, marketId), 1 ether, "Alice has YES");
    }

    function test_vault_buy() public {
        // Setup: Alice provides vault liquidity first
        vm.prank(alice);
        router.mintAndVault{value: 2 ether}(marketId, 2 ether, false, alice);

        // Bob buys YES (should route through vault OTC or AMM)
        vm.prank(bob);
        (uint256 sharesOut, bytes4[] memory sources) =
            router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, bob, 0);

        assertGt(sharesOut, 0, "Bob should get shares");
        assertGt(sources.length, 0, "Should have sources");
    }

    function test_vault_sell() public {
        // Setup: Alice has YES shares
        vm.prank(alice);
        router.mintAndVault{value: 2 ether}(marketId, 2 ether, true, alice);

        // Alice sells her YES (should route through vault OTC or AMM)
        vm.prank(alice);
        pamm.setOperator(address(router), true);

        vm.prank(alice);
        (uint256 collateralOut, bytes4[] memory sources) =
            router.sell(marketId, true, 1 ether, 0, 0, alice, 0);

        assertGt(collateralOut, 0, "Alice should get collateral");
    }

    /*//////////////////////////////////////////////////////////////
                       COMBINED USAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_combined_bothSystemsWork() public {
        // Alice uses pooled orderbook
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, alice);

        // Bob uses vault
        vm.prank(bob);
        router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, bob);

        // Both should work independently
        assertEq(pamm.balanceOf(alice, marketId), 1 ether, "Alice has YES from pool");
        assertEq(pamm.balanceOf(bob, marketId), 1 ether, "Bob has YES from vault");
    }

    function test_combined_fillPoolThenBuyVault() public {
        // Setup pool
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 4000, alice);

        // Setup vault
        vm.prank(bob);
        router.mintAndVault{value: 2 ether}(marketId, 2 ether, false, bob);

        // Taker 1 fills from pool
        vm.prank(taker);
        router.fillFromPool{value: 0.4 ether}(marketId, false, 4000, 1 ether, taker);

        // Taker 2 buys from vault
        vm.prank(carol);
        router.buy{value: 1 ether}(marketId, true, 1 ether, 0, 0, 0, carol, 0);

        // Both should have worked
        assertGt(pamm.balanceOf(taker, noId), 0, "Taker got NO from pool");
        assertGt(pamm.balanceOf(carol, marketId), 0, "Carol got YES from vault");
    }

    /*//////////////////////////////////////////////////////////////
                           EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_poolInsufficientLiquidity() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);

        vm.prank(taker);
        vm.expectRevert();
        router.fillFromPool{value: 1 ether}(marketId, false, 5000, 2 ether, taker);
    }

    function test_revert_invalidPrice() public {
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 10000, alice); // Price = 100%
    }

    function test_revert_wrongETHAmount() public {
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 2 ether}(marketId, 1 ether, true, 5000, alice); // Sent 2, need 1
    }

    /*//////////////////////////////////////////////////////////////
                         GAS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function testGas_mintAndPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);
    }

    function testGas_mintAndVault() public {
        vm.prank(alice);
        router.mintAndVault{value: 1 ether}(marketId, 1 ether, true, alice);
    }

    function testGas_fillFromPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);

        vm.prank(taker);
        router.fillFromPool{value: 0.5 ether}(marketId, false, 5000, 1 ether, taker);
    }

    function testGas_claimProceeds() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);

        vm.prank(taker);
        router.fillFromPool{value: 0.5 ether}(marketId, false, 5000, 1 ether, taker);

        vm.prank(alice);
        router.claimProceeds(marketId, false, 5000, alice);
    }

    /*//////////////////////////////////////////////////////////////
                         USER SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_scenario_bobWantsYESAtDiscount() public {
        // Bob wants YES exposure at a discount
        vm.startPrank(bob);

        // Bob mints and pools NO at 0.40
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 4000, bob);

        // Bob immediately has 10 YES
        assertEq(pamm.balanceOf(bob, marketId), 10 ether, "Bob has 10 YES");

        vm.stopPrank();

        // Market taker comes in
        vm.prank(taker);
        router.fillFromPool{value: 4 ether}(marketId, false, 4000, 10 ether, taker);

        // Bob claims his 4 ETH
        vm.prank(bob);
        uint256 claimed = router.claimProceeds(marketId, false, 4000, bob);

        // Bob's effective YES cost: 10 - 4 = 6 ETH (40% discount!)
        assertEq(claimed, 4 ether, "Bob gets 4 ETH back");
        uint256 effectiveCost = 10 ether - claimed;
        assertEq(effectiveCost, 6 ether, "Effective YES cost is 6 ETH");
    }

    function test_scenario_marketBootstrapping() public {
        // 3 users bootstrap a new market with pooled liquidity

        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 200 ether}(marketId, 200 ether, true, 5000, bob);

        vm.prank(carol);
        router.mintAndPool{value: 150 ether}(marketId, 150 ether, true, 5000, carol);

        // Market now has 450 NO shares at 0.50 - instant liquidity!

        // Takers start filling
        vm.prank(taker);
        router.fillFromPool{value: 100 ether}(marketId, false, 5000, 200 ether, taker);

        // LPs claim proportionally
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);
        assertApproxEqAbs(aliceClaimed, 22.222222222222222222 ether, 1e9, "Alice earns");

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);
        assertApproxEqAbs(bobClaimed, 44.444444444444444444 ether, 1e9, "Bob earns");

        vm.prank(carol);
        uint256 carolClaimed = router.claimProceeds(marketId, false, 5000, carol);
        assertApproxEqAbs(carolClaimed, 33.333333333333333333 ether, 1e9, "Carol earns");
    }
}
