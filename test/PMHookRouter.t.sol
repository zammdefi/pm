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
}

/**
 * @title PMHookRouter Tests
 * @notice Tests for prediction market routing with hooks
 */
contract PMHookRouterTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address constant ETH = address(0);
    uint64 constant DEADLINE_2026 = 1798761599;

    PMHookRouter public router;
    PMFeeHookV1 public hook;
    address public ALICE;
    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();
        router = new PMHookRouter();

        // Transfer hook ownership to router so it can register markets
        // (In production, router will be deployed at REGISTRAR address)
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
            DEADLINE_2026, // close
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

        (uint112 sharesBefore,,,) = router.vaultPositions(marketId, ALICE);

        // Deposit shares to vault
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 1 hours);

        (uint112 sharesAfter,,,) = router.vaultPositions(marketId, ALICE);

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
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 1 hours);

        (uint112 shares,,,) = router.vaultPositions(marketId, ALICE);

        console.log("=== WITHDRAW FROM VAULT ===");
        console.log("Vault shares:", shares);

        // Withdraw
        (uint256 sharesWithdrawn, uint256 fees) =
            router.withdrawFromVault(marketId, true, shares, ALICE, block.timestamp + 1 hours);

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
            router.depositToVault, (marketId, true, 25 ether, ALICE, block.timestamp + 1 hours)
        );
        calls[1] = abi.encodeCall(
            router.depositToVault, (marketId, false, 25 ether, ALICE, block.timestamp + 1 hours)
        );

        bytes[] memory results = router.multicall(calls);

        console.log("Executed", results.length, "calls in one transaction");
        console.log("");

        assertEq(results.length, 2, "Should execute both calls");

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
            DEADLINE_2026,
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
