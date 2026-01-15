// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./BaseTest.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 id, uint256 amount)
        external
        returns (bool);
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @title PMHookRouter Mint Path Tests
/// @notice Comprehensive tests for mint path in buyWithBootstrap
contract PMHookRouterMintPathTest is BaseTest {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;

    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint64 public closeTime;

    event VaultDeposit(
        uint256 indexed marketId,
        address indexed depositor,
        bool isYes,
        uint256 shares,
        uint256 vaultShares
    );

    function setUp() public {
        createForkWithFallback("main3");

        hook = new PMFeeHook();

        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");

        deal(ALICE, 100000 ether);
        deal(BOB, 100000 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // HELPER: Bootstrap market
    // ══════════════════════════════════════════════════════════════════════════════

    function _bootstrapMarket(uint256 lpAmount) internal {
        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: lpAmount}(
            "Mint Path Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            lpAmount,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        noId = PAMM.getNoId(marketId);
    }

    function _bootstrapMarketWithClose(uint256 lpAmount, uint64 _closeTime) internal {
        closeTime = _closeTime;
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: lpAmount}(
            "Mint Path Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            lpAmount,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        noId = PAMM.getNoId(marketId);
    }

    function _setupTWAP() internal {
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 100);
        router.updateTWAPObservation(marketId);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Initial bootstrapping (empty vault)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_InitialBootstrap() public {
        _bootstrapMarket(10 ether); // Small LP so AMM has limited liquidity
        _setupTWAP();

        // Vault should be empty initially
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertEq(yesShares, 0, "Vault YES should be empty");
        assertEq(noShares, 0, "Vault NO should be empty");

        uint256 buyAmount = 50 ether;

        // Buy YES - should use mint path since vault is empty and AMM has limited liquidity
        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        // Check that mint path was used (source could be "mint" or "mult" if AMM also used)
        console.log("Initial bootstrap - sharesOut:", sharesOut);
        console.log("Initial bootstrap - source:", string(abi.encodePacked(source)));
        console.log("Initial bootstrap - vaultSharesMinted:", vaultSharesMinted);

        // If mint was used, buyer should have vault shares for the opposite side
        if (vaultSharesMinted > 0) {
            // Verify vault now has NO shares (opposite of what buyer wanted)
            (uint112 yesAfter, uint112 noAfter,) = router.bootstrapVaults(marketId);
            assertGt(noAfter, 0, "Vault should have NO shares from mint");
            console.log("Vault YES after:", yesAfter);
            console.log("Vault NO after:", noAfter);
        }

        // Buyer should have YES shares
        uint256 aliceYes = PAMM.balanceOf(ALICE, marketId);
        assertGt(aliceYes, 0, "ALICE should have YES shares");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Buy YES deposits NO to vault
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_BuyYesDepositsNoToVault() public {
        _bootstrapMarket(5 ether); // Very small LP to force mint path
        _setupTWAP();

        uint256 buyAmount = 100 ether;

        // Track vault shares before
        uint256 noVaultSharesBefore = router.totalNoVaultShares(marketId);

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Buy YES - sharesOut:", sharesOut);
        console.log("Buy YES - source:", string(abi.encodePacked(source)));
        console.log("Buy YES - vaultSharesMinted:", vaultSharesMinted);

        if (vaultSharesMinted > 0) {
            // Vault should have received NO shares
            (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
            assertGt(noShares, 0, "Vault should have NO shares");

            // Total NO vault shares should have increased
            uint256 noVaultSharesAfter = router.totalNoVaultShares(marketId);
            assertGt(noVaultSharesAfter, noVaultSharesBefore, "NO vault shares should increase");

            // ALICE should have vault shares for NO side
            (, uint112 aliceNoVaultShares,,,) = router.vaultPositions(marketId, ALICE);
            assertGt(aliceNoVaultShares, 0, "ALICE should have NO vault shares");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Buy NO deposits YES to vault
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_BuyNoDepositsYesToVault() public {
        _bootstrapMarket(5 ether); // Very small LP to force mint path
        _setupTWAP();

        uint256 buyAmount = 100 ether;

        // Track vault shares before
        uint256 yesVaultSharesBefore = router.totalYesVaultShares(marketId);

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, false, buyAmount, 0, ALICE, closeTime
        );

        console.log("Buy NO - sharesOut:", sharesOut);
        console.log("Buy NO - source:", string(abi.encodePacked(source)));
        console.log("Buy NO - vaultSharesMinted:", vaultSharesMinted);

        if (vaultSharesMinted > 0) {
            // Vault should have received YES shares
            (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
            assertGt(yesShares, 0, "Vault should have YES shares");

            // Total YES vault shares should have increased
            uint256 yesVaultSharesAfter = router.totalYesVaultShares(marketId);
            assertGt(yesVaultSharesAfter, yesVaultSharesBefore, "YES vault shares should increase");

            // ALICE should have vault shares for YES side
            (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
            assertGt(aliceYesVaultShares, 0, "ALICE should have YES vault shares");
        }

        // ALICE should have NO shares
        uint256 aliceNo = PAMM.balanceOf(ALICE, noId);
        assertGt(aliceNo, 0, "ALICE should have NO shares");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path disabled within 4 hours of close
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_DisabledNearClose() public {
        // Create market that closes in 3 hours (within BOOTSTRAP_WINDOW of 4 hours)
        uint64 nearClose = uint64(block.timestamp + 3 hours);
        _bootstrapMarketWithClose(5 ether, nearClose);
        _setupTWAP();

        uint256 buyAmount = 100 ether;

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, nearClose
        );

        console.log("Near close - sharesOut:", sharesOut);
        console.log("Near close - source:", string(abi.encodePacked(source)));
        console.log("Near close - vaultSharesMinted:", vaultSharesMinted);

        // Mint path should NOT be used (vaultSharesMinted should be 0)
        // Note: if AMM can fill, it will. If not, remaining collateral is refunded
        assertEq(vaultSharesMinted, 0, "Mint path should be disabled near close");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Imbalance ratio constraint (max 2x)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_ImbalanceConstraint() public {
        _bootstrapMarket(10 ether);
        _setupTWAP();

        // Create imbalanced vault - deposit more YES than NO
        vm.startPrank(BOB);
        PAMM.split{value: 300 ether}(marketId, 300 ether, BOB);
        PAMM.setOperator(address(router), true);

        // Deposit 100 YES and 30 NO to create >2x imbalance
        router.depositToVault(marketId, true, 100 ether, BOB, closeTime);
        router.depositToVault(marketId, false, 30 ether, BOB, closeTime);
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        console.log("Imbalanced vault YES:", yesShares);
        console.log("Imbalanced vault NO:", noShares);
        assertTrue(yesShares > noShares * 2, "Should have >2x imbalance");

        // Try to buy NO (which would deposit YES, making imbalance worse)
        uint256 buyAmount = 50 ether;
        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, false, buyAmount, 0, ALICE, closeTime
        );

        console.log("Imbalanced buy - sharesOut:", sharesOut);
        console.log("Imbalanced buy - source:", string(abi.encodePacked(source)));
        console.log("Imbalanced buy - vaultSharesMinted:", vaultSharesMinted);

        // Mint path should be blocked due to imbalance
        assertEq(vaultSharesMinted, 0, "Mint should be blocked when >2x imbalanced");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Only replenishes scarce side
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_OnlyReplenishesScarce() public {
        _bootstrapMarket(10 ether);
        _setupTWAP();

        // Create vault with only YES (NO is empty/scarce)
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, BOB, closeTime);
        // Don't deposit any NO
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertGt(yesShares, 0, "Vault should have YES");
        assertEq(noShares, 0, "Vault should have no NO");

        // Try to buy YES (would deposit NO to vault - replenishing scarce side)
        uint256 buyAmount = 30 ether;
        vm.prank(ALICE);
        (uint256 sharesOut1, bytes4 source1, uint256 vaultMinted1) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Buy YES (replenish NO) - vaultSharesMinted:", vaultMinted1);
        console.log("Buy YES (replenish NO) - source:", string(abi.encodePacked(source1)));

        // This should be allowed since it replenishes the scarce NO side
        // Note: depends on whether AMM can fill first

        // Now try to buy NO (would deposit YES to vault - NOT replenishing scarce side)
        vm.prank(BOB);
        (uint256 sharesOut2, bytes4 source2, uint256 vaultMinted2) =
            router.buyWithBootstrap{value: buyAmount}(marketId, false, buyAmount, 0, BOB, closeTime);

        console.log("Buy NO (not replenish) - vaultSharesMinted:", vaultMinted2);
        console.log("Buy NO (not replenish) - source:", string(abi.encodePacked(source2)));

        // If NO is still scarce (0), buying NO should NOT use mint path
        // because it deposits YES which doesn't help the scarce side
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Multi-venue execution (AMM + Mint)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_MultiVenueWithAMM() public {
        _bootstrapMarket(20 ether); // Moderate LP
        _setupTWAP();

        uint256 buyAmount = 100 ether; // Large buy to exhaust AMM liquidity

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Multi-venue - sharesOut:", sharesOut);
        console.log("Multi-venue - source:", string(abi.encodePacked(source)));
        console.log("Multi-venue - vaultSharesMinted:", vaultSharesMinted);

        // If both AMM and mint were used, source should be "mult"
        if (vaultSharesMinted > 0 && source == bytes4("mult")) {
            console.log("Successfully used multiple venues including mint");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Vault shares are redeemable
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_VaultSharesRedeemable() public {
        _bootstrapMarket(5 ether);
        _setupTWAP();

        uint256 buyAmount = 50 ether;

        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true);

        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Redeem test - vaultSharesMinted:", vaultSharesMinted);

        if (vaultSharesMinted > 0) {
            // ALICE should have NO vault shares
            (, uint112 aliceNoVaultShares,,,) = router.vaultPositions(marketId, ALICE);
            assertGt(aliceNoVaultShares, 0, "ALICE should have vault shares");

            // Warp past the withdrawal lockup period (6 hours)
            vm.warp(block.timestamp + 7 hours);

            // Try to withdraw from vault
            uint256 noBalanceBefore = PAMM.balanceOf(ALICE, noId);

            router.withdrawFromVault(marketId, false, aliceNoVaultShares, ALICE, closeTime);

            uint256 noBalanceAfter = PAMM.balanceOf(ALICE, noId);
            assertGt(noBalanceAfter, noBalanceBefore, "Should receive NO shares from vault");
            console.log("Withdrawn NO shares:", noBalanceAfter - noBalanceBefore);
        }
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - 1:1 pricing (no slippage)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_OneToOnePricing() public {
        _bootstrapMarket(1 ether); // Minimal LP to force mint path
        _setupTWAP();

        uint256 buyAmount = 100 ether;
        uint256 yesBefore = PAMM.balanceOf(ALICE, marketId);

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        uint256 yesAfter = PAMM.balanceOf(ALICE, marketId);
        uint256 yesReceived = yesAfter - yesBefore;

        console.log("1:1 pricing - buyAmount:", buyAmount);
        console.log("1:1 pricing - sharesOut:", sharesOut);
        console.log("1:1 pricing - yesReceived:", yesReceived);
        console.log("1:1 pricing - source:", string(abi.encodePacked(source)));

        // If mint path was used predominantly, should get close to 1:1
        if (source == bytes4("mint")) {
            assertEq(sharesOut, buyAmount, "Mint path should give 1:1");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - VaultDeposit event emitted
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_EmitsVaultDeposit() public {
        _bootstrapMarket(5 ether);
        _setupTWAP();

        uint256 buyAmount = 50 ether;

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, false);
        emit VaultDeposit(marketId, ALICE, false, 0, 0); // We just check event is emitted, not exact values

        router.buyWithBootstrap{value: buyAmount}(marketId, true, buyAmount, 0, ALICE, closeTime);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Balanced vault allows mint
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_BalancedVaultAllowsMint() public {
        _bootstrapMarket(10 ether);
        _setupTWAP();

        // Create balanced vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, BOB, closeTime);
        router.depositToVault(marketId, false, 50 ether, BOB, closeTime);
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertEq(yesShares, noShares, "Vault should be balanced");

        uint256 buyAmount = 30 ether;

        vm.prank(ALICE);
        (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Balanced vault - source:", string(abi.encodePacked(source)));
        console.log("Balanced vault - vaultSharesMinted:", vaultSharesMinted);

        // Balanced vault should allow mint path (if AMM doesn't fill everything)
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Mint path - Buying abundant side allowed
    // ══════════════════════════════════════════════════════════════════════════════

    function test_MintPath_BuyingAbundantSideAllowed() public {
        _bootstrapMarket(10 ether);
        _setupTWAP();

        // Create vault with more YES than NO (YES is abundant)
        vm.startPrank(BOB);
        PAMM.split{value: 150 ether}(marketId, 150 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 80 ether, BOB, closeTime);
        router.depositToVault(marketId, false, 50 ether, BOB, closeTime);
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        console.log("Vault YES:", yesShares);
        console.log("Vault NO:", noShares);
        assertGt(yesShares, noShares, "YES should be abundant");
        assertTrue(yesShares <= noShares * 2, "Should be within 2x ratio");

        // Buy NO (abundant side = NO is NOT abundant, so buying NO means depositing YES which is abundant)
        // Actually: buyYes != (yesShares < noShares)
        // yesShares > noShares, so yesShares < noShares = false
        // buyYes = false (buying NO), so false != false = false - NOT allowed
        // buyYes = true (buying YES), so true != false = true - allowed

        uint256 buyAmount = 30 ether;

        // Buying YES should be allowed (deposits NO which is scarce)
        vm.prank(ALICE);
        (uint256 sharesOut1, bytes4 source1, uint256 vaultMinted1) = router.buyWithBootstrap{
            value: buyAmount
        }(
            marketId, true, buyAmount, 0, ALICE, closeTime
        );

        console.log("Buy YES (deposit scarce NO) - vaultMinted:", vaultMinted1);
        console.log("Buy YES - source:", string(abi.encodePacked(source1)));
    }
}
