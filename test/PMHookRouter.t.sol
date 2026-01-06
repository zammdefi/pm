// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
}

/**
 * @title PMHookRouter Tests
 * @notice Tests for prediction market routing with hooks
 */
contract PMHookRouterTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHookV1 public hook;
    address public ALICE;
    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address using vm.etch so hook.registerMarket accepts calls
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Manually initialize router (constructor logic doesn't run with vm.etch)
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router so it can register markets
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        deal(ALICE, 10000 ether);

        console.log("=== PMHookRouter Test Suite ===");
        console.log("Router:", address(router));
        console.log("Hook:", address(hook));
        console.log("");
    }

    function test_BootstrapMarket() public {
        console.log("=== BOOTSTRAP MARKET ===");

        vm.startPrank(ALICE);

        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Test Market 2026",
            ALICE, // resolver
            ETH, // collateral
            DEADLINE_2028, // close
            false, // canClose
            address(hook),
            1000 ether, // collateralForLP
            true, // buyYes
            0, // collateralForBuy
            0, // minSharesOut
            ALICE,
            block.timestamp + 1 hours
        );

        console.log("Market ID:", marketId);
        console.log("Pool ID:", poolId);
        console.log("");

        assertGt(marketId, 0, "Should create market");
        assertGt(poolId, 0, "Should create pool");

        vm.stopPrank();
    }

    function test_BuyWithBootstrap() public {
        _bootstrapMarket();

        console.log("=== BUY WITH BOOTSTRAP ===");

        vm.startPrank(ALICE);

        uint256 sharesBefore = PAMM.balanceOf(ALICE, marketId);

        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 10 ether}(
            marketId,
            true, // buyYes
            10 ether,
            0, // minSharesOut
            ALICE,
            block.timestamp + 1 hours
        );

        uint256 sharesAfter = PAMM.balanceOf(ALICE, marketId);

        console.log("Collateral in: 10 ETH");
        console.log("YES shares received:", sharesOut);
        console.log("Source:", uint32(source));
        console.log("");

        assertGt(sharesOut, 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, sharesOut, "Balance should match output");

        vm.stopPrank();
    }

    function test_DepositToVault() public {
        _bootstrapMarket();

        console.log("=== DEPOSIT TO VAULT ===");

        vm.startPrank(ALICE);

        // First split ETH into shares
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);

        // Approve router to transfer shares
        PAMM.setOperator(address(router), true);

        (uint112 sharesBefore,,,,) = router.vaultPositions(marketId, ALICE);

        // Deposit shares to vault
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);

        (uint112 sharesAfter,,,,) = router.vaultPositions(marketId, ALICE);

        console.log("Deposited: 50 ETH worth of YES shares to vault");
        console.log("Vault shares before:", sharesBefore);
        console.log("Vault shares after:", sharesAfter);
        console.log("");

        assertGt(sharesAfter, sharesBefore, "Should receive vault shares");

        vm.stopPrank();
    }

    function test_WithdrawFromVault() public {
        _bootstrapMarket();

        vm.startPrank(ALICE);

        // Split and deposit
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);

        console.log("=== WITHDRAW FROM VAULT ===");
        console.log("Vault shares:", shares);

        // Wait for withdrawal cooldown (6 hours)
        vm.warp(block.timestamp + 6 hours + 1);

        // Withdraw (deadline must be after warp)
        (uint256 sharesWithdrawn, uint256 fees) =
            router.withdrawFromVault(marketId, true, shares, ALICE, block.timestamp + 7 hours);

        console.log("Shares withdrawn:", sharesWithdrawn);
        console.log("Fees earned:", fees);
        console.log("");

        assertGt(sharesWithdrawn, 0, "Should withdraw shares");

        vm.stopPrank();
    }

    function test_HookIntegration() public {
        _bootstrapMarket();

        console.log("=== HOOK INTEGRATION ===");

        // Check that hook is properly registered
        uint256 canonical = router.canonicalPoolId(marketId);
        assertEq(canonical, poolId, "Canonical pool should match");

        // Get fee from hook
        uint256 feeBps = hook.getCurrentFeeBps(poolId);
        console.log("Current fee (bps):", feeBps);
        console.log("");

        assertGt(feeBps, 0, "Hook should return non-zero fee");
    }

    function test_Multicall() public {
        _bootstrapMarket();

        console.log("=== MULTICALL ===");

        vm.startPrank(ALICE);

        // Split shares first
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            router.depositToVault, (marketId, true, 25 ether, ALICE, block.timestamp + 7 hours)
        );
        calls[1] = abi.encodeCall(
            router.depositToVault, (marketId, false, 25 ether, ALICE, block.timestamp + 7 hours)
        );

        bytes[] memory results = router.multicall(calls);

        console.log("Executed", results.length, "calls in one transaction");
        console.log("");

        assertEq(results.length, 2, "Should execute both calls");

        vm.stopPrank();
    }

    function test_FinalizeMarket_RevertIfNotResolved() public {
        _bootstrapMarket();

        console.log("=== FINALIZE MARKET - REVERT IF NOT RESOLVED ===");

        // Try to finalize before market is resolved
        vm.expectRevert();
        router.finalizeMarket(marketId);

        console.log("Correctly reverted on unresolved market");
        console.log("");
    }

    function test_FinalizeMarket_WithNoLPs() public {
        _bootstrapMarket();

        console.log("=== FINALIZE MARKET - NO LPs ===");

        // Buy some shares to generate fees
        vm.startPrank(ALICE);
        router.buyWithBootstrap{value: 100 ether}(
            marketId,
            true, // buyYes
            100 ether,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Wait for withdrawal cooldown period (30 minutes)
        vm.warp(block.timestamp + 6 hours + 1);

        // Withdraw Alice's vault shares before market closes to ensure no LPs remain
        vm.startPrank(ALICE);
        (uint112 aliceYesVaultShares, uint112 aliceNoVaultShares,,,) =
            router.vaultPositions(marketId, ALICE);
        if (aliceYesVaultShares > 0) {
            router.withdrawFromVault(
                marketId, true, aliceYesVaultShares, ALICE, block.timestamp + 1 hours
            );
        }
        if (aliceNoVaultShares > 0) {
            router.withdrawFromVault(
                marketId, false, aliceNoVaultShares, ALICE, block.timestamp + 1 hours
            );
        }
        vm.stopPrank();

        // Warp to after market close time
        vm.warp(DEADLINE_2028);

        // Resolve market as YES (outcome = true)
        vm.prank(ALICE); // ALICE is the resolver
        PAMM.resolve(marketId, true);

        // Finalize market (no LPs, so all value goes to DAO)
        uint256 totalToDAO = router.finalizeMarket(marketId);

        console.log("Total sent to DAO:", totalToDAO);
        console.log("");

        // Verify vault shares are cleared
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertEq(yesShares, 0, "YES shares should be cleared");
        assertEq(noShares, 0, "NO shares should be cleared");
        assertEq(router.totalYesVaultShares(marketId), 0, "Total YES vault shares should be 0");
        assertEq(router.totalNoVaultShares(marketId), 0, "Total NO vault shares should be 0");
    }

    function test_FinalizeMarket_ReturnsZeroIfLPsExist() public {
        _bootstrapMarket();

        console.log("=== FINALIZE MARKET - WITH LPs ===");

        vm.startPrank(ALICE);

        // Create LP position by depositing to vault
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);

        vm.stopPrank();

        // Warp to after market close time
        vm.warp(DEADLINE_2028);

        // Resolve market
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // Finalize should return 0 because LPs still exist
        uint256 totalToDAO = router.finalizeMarket(marketId);

        console.log("Total sent to DAO (should be 0):", totalToDAO);
        console.log("");

        assertEq(totalToDAO, 0, "Should return 0 when LPs exist");
    }

    function test_UpdateTWAPObservation() public {
        _bootstrapMarket();

        console.log("=== UPDATE TWAP OBSERVATION ===");

        // Make a trade to move the TWAP
        vm.startPrank(ALICE);
        router.buyWithBootstrap{value: 50 ether}(
            marketId,
            true, // buyYes
            50 ether,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 7 hours);

        // Get TWAP observation before update
        (uint32 ts0Before, uint32 ts1Before,,,, uint256 c0Before, uint256 c1Before) =
            router.twapObservations(marketId);

        // Update TWAP
        router.updateTWAPObservation(marketId);

        // Get TWAP observation after update
        (uint32 ts0After, uint32 ts1After,,,, uint256 c0After, uint256 c1After) =
            router.twapObservations(marketId);

        console.log("Timestamp0 before:", ts0Before, "after:", ts0After);
        console.log("Timestamp1 before:", ts1Before, "after:", ts1After);
        console.log("");

        // After update, one of the observations should change
        assertTrue(
            ts0After != ts0Before || ts1After != ts1Before || c0After != c0Before
                || c1After != c1Before,
            "TWAP observation should update"
        );
    }

    function test_BuyWithBootstrap_MinSharesOut() public {
        _bootstrapMarket();

        console.log("=== BUY WITH BOOTSTRAP - MIN SHARES OUT ===");

        vm.startPrank(ALICE);

        // Try to buy with unrealistic minSharesOut (should revert)
        vm.expectRevert();
        router.buyWithBootstrap{value: 10 ether}(
            marketId,
            true, // buyYes
            10 ether,
            1000 ether, // Unrealistic minSharesOut
            ALICE,
            block.timestamp + 1 hours
        );

        console.log("Correctly reverted with insufficient output");
        console.log("");

        vm.stopPrank();
    }

    function test_BuyWithBootstrap_Deadline() public {
        _bootstrapMarket();

        console.log("=== BUY WITH BOOTSTRAP - DEADLINE ===");

        vm.startPrank(ALICE);

        // Advance time past deadline
        vm.warp(block.timestamp + 2 hours);

        // Try to buy with expired deadline
        vm.expectRevert();
        router.buyWithBootstrap{value: 10 ether}(
            marketId,
            true,
            10 ether,
            0,
            ALICE,
            block.timestamp - 1 // Expired deadline
        );

        console.log("Correctly reverted with expired deadline");
        console.log("");

        vm.stopPrank();
    }

    function test_DepositToVault_ZeroShares() public {
        _bootstrapMarket();

        console.log("=== DEPOSIT TO VAULT - ZERO SHARES ===");

        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true);

        // Try to deposit 0 shares
        vm.expectRevert();
        router.depositToVault(marketId, true, 0, ALICE, block.timestamp + 7 hours);

        console.log("Correctly reverted with zero shares");
        console.log("");

        vm.stopPrank();
    }

    function test_WithdrawFromVault_BeforeCooldown() public {
        _bootstrapMarket();

        console.log("=== WITHDRAW FROM VAULT - BEFORE COOLDOWN ===");

        vm.startPrank(ALICE);

        // Split and deposit
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);

        (uint112 shares,,,,) = router.vaultPositions(marketId, ALICE);

        // Try to withdraw immediately (before cooldown expires)
        vm.expectRevert();
        router.withdrawFromVault(marketId, true, shares, ALICE, block.timestamp + 7 hours);

        console.log("Correctly reverted before cooldown");
        console.log("");

        vm.stopPrank();
    }

    function test_WithdrawFromVault_ZeroVaultShares() public {
        _bootstrapMarket();

        console.log("=== WITHDRAW FROM VAULT - ZERO VAULT SHARES ===");

        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true);

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Try to withdraw 0 shares
        vm.expectRevert();
        router.withdrawFromVault(marketId, true, 0, ALICE, block.timestamp + 7 hours);

        console.log("Correctly reverted with zero vault shares");
        console.log("");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);

        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Test Market 2026",
            ALICE, // resolver
            ETH, // collateral
            DEADLINE_2028,
            false, // canClose
            address(hook),
            1000 ether, // collateralForLP
            true, // buyYes
            0, // collateralForBuy
            0, // minSharesOut
            ALICE,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("Bootstrapped Market ID:", marketId);
        console.log("Pool ID:", poolId);
        console.log("");
    }
}
