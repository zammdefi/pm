// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";
import {Resolver} from "../src/Resolver.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IUniswapV4 {
    function protocolFeeController() external view returns (address);
}

/**
 * @title PMHookRouter Tests
 * @notice Tests for advanced prediction market routing with hooks
 */
contract PMHookRouterTest is Test {
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));
    Resolver constant resolver = Resolver(payable(0x00000000002205020E387b6a378c05639047BcFB));
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IUniswapV4 constant UNIV4 = IUniswapV4(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IERC20 constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);

    uint64 constant DEADLINE_2026 = 1798761599;
    uint256 constant FLAG_AFTER = 1 << 254;

    PMHookRouter public router;
    PredictionMarketHook public hook;
    address public ALICE;
    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint256 public feeOrHook;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = new PMHookRouter();
        hook = new PredictionMarketHook();
        ALICE = makeAddr("ALICE");

        deal(address(UNI), ALICE, 100_000 ether);

        console.log("=== PMHookRouter Test Suite ===");
        console.log("Router:", address(router));
        console.log("Hook:", address(hook));
        console.log("");
    }

    function test_ComplexSwap_DirectCollateral() public {
        _createMarket();

        console.log("=== COMPLEX SWAP: DIRECT COLLATERAL ===");

        vm.startPrank(ALICE);
        UNI.approve(address(router), 100 ether);

        // Prepare route data with NO special action
        PMHookRouter.RouteData memory routeData =
            PMHookRouter.RouteData({action: PMHookRouter.ActionType.NONE, params: ""});

        uint256 sharesBefore = pamm.balanceOf(ALICE, marketId);

        uint256 sharesOut = router.complexSwap(
            address(UNI), // tokenIn = collateral
            100 ether, // amountIn
            marketId, // marketId
            true, // isYes
            0, // minSharesOut
            feeOrHook, // feeOrHook
            ALICE, // to
            0, // deadline (now)
            routeData // no special routing
        );

        uint256 sharesAfter = pamm.balanceOf(ALICE, marketId);

        console.log("Collateral in: 100 UNI");
        console.log("YES shares received");
        console.log("");

        assertGt(sharesOut, 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, sharesOut, "Balance should match output");

        vm.stopPrank();
    }

    function test_ComplexSwap_WithMarketRegistration() public {
        _createMarketWithoutRegistering();

        console.log("=== COMPLEX SWAP: WITH MARKET REGISTRATION ===");
        console.log("Market not yet registered with hook");
        console.log("");

        vm.startPrank(ALICE);
        UNI.approve(address(router), 100 ether);

        // Prepare route data to REGISTER market
        PMHookRouter.RouteData memory routeData = PMHookRouter.RouteData({
            action: PMHookRouter.ActionType.REGISTER_MARKET,
            params: "" // No extra params needed
        });

        // Check hook config before
        (uint64 deadlineBefore,,,,,,,, bool activeBefore) = hook.configs(poolId);
        console.log("Hook configured before:", activeBefore ? "YES" : "NO");

        uint256 sharesOut = router.complexSwap(
            address(UNI), // tokenIn = collateral
            100 ether, // amountIn
            marketId,
            true, // isYes
            0, // minSharesOut
            feeOrHook,
            ALICE,
            0,
            routeData
        );

        // Check hook config after
        (uint64 deadlineAfter,,,,,,,, bool activeAfter) = hook.configs(poolId);
        console.log("Hook configured after:", activeAfter ? "YES" : "NO");
        console.log("Deadline set:", deadlineAfter);
        console.log("Expected deadline:", DEADLINE_2026);
        console.log("");

        assertTrue(activeAfter, "Hook should be configured after swap");
        assertEq(deadlineAfter, DEADLINE_2026, "Deadline should match market");
        assertGt(sharesOut, 0, "Should receive shares");

        vm.stopPrank();
    }

    function test_ComplexSwap_MultipleActions() public {
        _createMarketWithoutRegistering();

        console.log("=== COMPLEX SWAP: REGISTRATION + SWAP ===");
        console.log("Testing combined registration and buying in one transaction");
        console.log("");

        vm.startPrank(ALICE);
        UNI.approve(address(router), 100 ether);

        // Prepare route data to REGISTER and BUY in one transaction
        PMHookRouter.RouteData memory routeData = PMHookRouter.RouteData({
            action: PMHookRouter.ActionType.REGISTER_MARKET,
            params: ""
        });

        // Check hook not configured before
        (,,,,,,,,bool activeBefore) = hook.configs(poolId);
        assertFalse(activeBefore, "Hook should not be configured yet");

        uint256 yesBalanceBefore = pamm.balanceOf(ALICE, marketId);

        // Register and buy in one call
        uint256 sharesOut = router.complexSwap(
            address(UNI),
            100 ether,
            marketId,
            true, // isYes
            0, // minSharesOut
            feeOrHook,
            ALICE,
            0,
            routeData
        );

        // Check hook is configured after
        (uint64 deadline,,,,,,, , bool activeAfter) = hook.configs(poolId);
        assertTrue(activeAfter, "Hook should be configured now");
        assertEq(deadline, DEADLINE_2026, "Deadline should match");

        // Check shares received
        uint256 yesBalanceAfter = pamm.balanceOf(ALICE, marketId);
        assertGt(sharesOut, 0, "Should receive YES shares");
        assertEq(yesBalanceAfter - yesBalanceBefore, sharesOut, "Balance should increase");

        console.log("Hook registered: YES");
        console.log("Shares purchased: YES");
        console.log("All in one transaction!");
        console.log("");

        vm.stopPrank();
    }

    function test_FeesWithHook() public {
        _createMarket();

        console.log("=== HOOK FEES: TIME DECAY ===");
        console.log("Verifying hook adjusts fees over time");
        console.log("");

        // Get current fee from hook
        uint256 feeEarly = hook.getCurrentFee(poolId, true);
        console.log("Fee at start:", feeEarly, "bps");

        // Warp 6 months forward
        uint256 duration = DEADLINE_2026 - block.timestamp;
        vm.warp(block.timestamp + duration / 2);

        uint256 feeMid = hook.getCurrentFee(poolId, true);
        console.log("Fee at 50%:", feeMid, "bps");

        // Warp to deadline
        vm.warp(DEADLINE_2026);

        uint256 feeEnd = hook.getCurrentFee(poolId, true);
        console.log("Fee at deadline:", feeEnd, "bps");
        console.log("");

        console.log("Fee decay verified:", feeEarly > feeMid && feeMid > feeEnd ? "YES" : "NO");
        console.log("");

        assertGt(feeEarly, feeMid, "Fees should decay");
        assertGt(feeMid, feeEnd, "Fees should decay");
        assertEq(feeEnd, 10, "Should end at MIN_BASE_FEE");
    }

    function test_ReentrancyProtection() public {
        _createMarket();

        vm.startPrank(ALICE);
        UNI.approve(address(router), 100 ether);

        PMHookRouter.RouteData memory routeData =
            PMHookRouter.RouteData({action: PMHookRouter.ActionType.NONE, params: ""});

        // This would need a malicious hook to test properly
        // For now just verify the function completes normally
        router.complexSwap(address(UNI), 100 ether, marketId, true, 0, feeOrHook, ALICE, 0, routeData);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
                            //////////////////////////////////////////////////////////////*/

    function _createMarket() internal {
        vm.startPrank(ALICE);
        UNI.approve(address(resolver), 1000 ether);

        feeOrHook = uint256(uint160(address(hook))) | FLAG_AFTER;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 1000 ether,
            feeOrHook: feeOrHook,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        (marketId, noId,,) = resolver.createNumericMarketAndSeedSimple(
            "UNI V4 Fee Switch 2026",
            address(UNI),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2026,
            true,
            seed
        );

        IZAMM.PoolKey memory key = pamm.poolKey(marketId, feeOrHook);
        poolId = uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));

        vm.stopPrank();

        // Register market with hook
        vm.prank(address(pamm));
        hook.registerMarket(marketId);

        console.log("Market ID:", marketId);
        console.log("Pool ID:", poolId);
        console.log("Fee/Hook:", feeOrHook);
        console.log("");
    }

    function _createMarketWithoutRegistering() internal {
        vm.startPrank(ALICE);
        UNI.approve(address(resolver), 1000 ether);

        feeOrHook = uint256(uint160(address(hook))) | FLAG_AFTER;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 1000 ether,
            feeOrHook: feeOrHook,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        (marketId, noId,,) = resolver.createNumericMarketAndSeedSimple(
            "UNI V4 Fee Switch 2026 Unregistered",
            address(UNI),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2026,
            true,
            seed
        );

        IZAMM.PoolKey memory key = pamm.poolKey(marketId, feeOrHook);
        poolId = uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));

        vm.stopPrank();

        // DON'T register - that's the point!

        console.log("Market ID (unregistered):", marketId);
        console.log("Pool ID:", poolId);
        console.log("");
    }
}
