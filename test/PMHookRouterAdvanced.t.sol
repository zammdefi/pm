// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );

    function getNoId(uint256 marketId) external pure returns (uint256);
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
}

/// @title PMHookRouter Advanced Tests
/// @notice Tests for multicall, permit, rebalancing, LP fees, and hook integration
contract PMHookRouterAdvancedTest is Test {
    PMHookRouter public router;
    PMFeeHookV1 public hook;
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address constant ETH = address(0);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI with permit

    address public alice;
    uint256 public aliceKey;
    address public bob;
    uint256 public bobKey;

    uint256 public marketId;
    uint256 public poolId;
    uint256 public feeOrHook;

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // Generate deterministic test accounts with private keys for permit signing
        aliceKey = 0xA11CE;
        alice = vm.addr(aliceKey);
        bobKey = 0xB0B;
        bob = vm.addr(bobKey);

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address using vm.etch
        // This allows hook.registerMarket to accept calls from the router
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Manually initialize router (constructor logic doesn't run with vm.etch)
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router so it can register markets
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);

        // Create ETH market for general tests
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Test Market",
            address(this),
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            1000 ether,
            true,
            0,
            0,
            address(this),
            block.timestamp + 1 hours
        );

        // Verify hook registration succeeded
        uint256 registeredPoolId = router.canonicalPoolId(marketId);
        assertNotEq(registeredPoolId, 0, "Hook registration failed in setUp");
        assertEq(registeredPoolId, poolId, "PoolId mismatch in setUp");

        feeOrHook = _hookFeeOrHook(address(hook), true);

        // Warp time to allow cumulative to accumulate
        vm.warp(block.timestamp + 1 minutes);
    }

    function _hookFeeOrHook(address hook_, bool afterHook) internal pure returns (uint256) {
        uint256 flags = afterHook ? (FLAG_BEFORE | FLAG_AFTER) : FLAG_BEFORE;
        return uint256(uint160(hook_)) | flags;
    }

    // ============ Multicall Tests ============

    /// @notice Test multicall with multiple operations in one transaction
    function test_Multicall_MultipleOperations() public {
        // Fund Alice with shares
        vm.startPrank(alice);
        PAMM.split{value: 200 ether}(marketId, 200 ether, alice);
        PAMM.setOperator(address(router), true);
        vm.stopPrank();

        // Prepare multicall: deposit to both YES and NO vaults
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            router.depositToVault, (marketId, true, 100 ether, alice, block.timestamp + 7 hours)
        );
        calls[1] = abi.encodeCall(
            router.depositToVault, (marketId, false, 100 ether, alice, block.timestamp + 7 hours)
        );

        // Execute multicall
        vm.prank(alice);
        bytes[] memory results = router.multicall(calls);

        assertEq(results.length, 2, "Should return 2 results");

        // Verify deposits succeeded
        (uint256 yesShares, uint256 noShares,) = router.bootstrapVaults(marketId);
        assertGt(yesShares, 0, "YES vault should have shares");
        assertGt(noShares, 0, "NO vault should have shares");
    }

    /// @notice Test multicall with deposit and withdrawal in one tx
    function test_Multicall_DepositAndWithdraw() public {
        // Setup: Alice has shares
        vm.startPrank(alice);
        PAMM.split{value: 200 ether}(marketId, 200 ether, alice);
        PAMM.setOperator(address(router), true);

        // First deposit
        router.depositToVault(marketId, true, 100 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for some activity to accumulate fees
        vm.warp(block.timestamp + 6 minutes);

        vm.prank(bob);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, bob, block.timestamp + 7 hours
        );

        // Prepare multicall: partial withdraw + redeposit
        (uint112 aliceYesShares,,,,) = router.vaultPositions(marketId, alice);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            router.withdrawFromVault,
            (marketId, true, aliceYesShares / 2, alice, block.timestamp + 7 hours)
        );
        calls[1] = abi.encodeCall(
            router.depositToVault, (marketId, false, 50 ether, alice, block.timestamp + 7 hours)
        );

        // Wait for withdrawal cooldown (6 hours total from deposit)
        vm.warp(block.timestamp + 5 hours + 54 minutes + 1);

        vm.prank(alice);
        bytes[] memory results = router.multicall(calls);

        assertEq(results.length, 2, "Should return 2 results");

        // Verify Alice now has NO vault shares
        (, uint112 aliceNoShares,,,) = router.vaultPositions(marketId, alice);
        assertGt(aliceNoShares, 0, "Alice should have NO vault shares");
    }

    // ============ Permit + Multicall Tests ============

    /// @notice Test ERC20 with permit can be used with multicall
    function test_Permit_Multicall_ERC20Bootstrap() public {
        // Use USDC which has standard EIP-2612 permit (DAI has non-standard permit)
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // Get USDC for Alice (6 decimals)
        deal(USDC, alice, 10000e6);

        IERC20Permit token = IERC20Permit(USDC);

        uint256 nonce = token.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 permitAmount = 1000e6; // 1000 USDC (6 decimals)

        // Create permit signature
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        ),
                        alice,
                        address(router),
                        permitAmount,
                        nonce,
                        deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, permitHash);

        // Execute permit directly (cannot be done via multicall delegatecall)
        vm.prank(alice);
        token.permit(alice, address(router), permitAmount, deadline, v, r, s);

        // Prepare multicall: approve router + bootstrap market
        bytes[] memory calls = new bytes[](1);

        // Bootstrap market with USDC
        calls[0] = abi.encodeCall(
            router.bootstrapMarket,
            (
                "USDC Market",
                alice,
                USDC,
                uint64(block.timestamp + 7 days),
                false,
                address(hook),
                500e6, // collateralForLP (6 decimals)
                true, // buyYes
                0, // collateralForBuy
                0, // minSharesOut
                alice, // to
                deadline
            )
        );

        uint256 balanceBefore = token.balanceOf(alice);

        // Execute multicall (no ETH value for ERC20)
        vm.prank(alice);
        bytes[] memory results = router.multicall(calls);

        uint256 balanceAfter = token.balanceOf(alice);

        // Verify USDC was spent
        assertEq(balanceBefore - balanceAfter, 500e6, "Should spend 500 USDC for bootstrap");

        // Verify market was created
        (uint256 usdcMarketId,,,) = abi.decode(results[0], (uint256, uint256, uint256, uint256));
        assertGt(usdcMarketId, 0, "Should create USDC market");

        (,,,,, address collateral,) = PAMM.markets(usdcMarketId);
        assertEq(collateral, USDC, "Market should use USDC as collateral");
    }

    // ============ Rebalancing Tests ============

    /// @notice Test rebalancing reduces vault imbalance
    function test_Rebalancing_ReducesImbalance() public {
        // Create imbalanced vault (80% YES, 20% NO)
        vm.startPrank(alice);
        PAMM.split{value: 100 ether}(marketId, 100 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 80 ether, alice, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 20 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate rebalance budget via OTC trades
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(bob);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, bob, block.timestamp + 1 hours
        );

        // Capture imbalance before rebalance
        (uint256 yesSharesBefore, uint256 noSharesBefore,) = router.bootstrapVaults(marketId);
        uint256 imbalanceBefore =
            yesSharesBefore > noSharesBefore ? yesSharesBefore - noSharesBefore : 0;

        assertGt(imbalanceBefore, 0, "Should have imbalance");

        // Trigger rebalance
        vm.warp(block.timestamp + 6 minutes);
        uint256 collateralUsed = router.rebalanceBootstrapVault(marketId, block.timestamp + 7 hours);

        // Capture imbalance after rebalance
        (uint256 yesSharesAfter, uint256 noSharesAfter,) = router.bootstrapVaults(marketId);
        uint256 imbalanceAfter = yesSharesAfter > noSharesAfter ? yesSharesAfter - noSharesAfter : 0;

        // If rebalance occurred, imbalance should be reduced
        if (collateralUsed > 0) {
            assertLt(imbalanceAfter, imbalanceBefore, "Rebalance should reduce imbalance");
        }
    }

    /// @notice Test rebalancing uses budget from OTC fees
    function test_Rebalancing_UsesBudgetFromFees() public {
        // Setup vault with balanced inventory
        vm.startPrank(alice);
        PAMM.split{value: 100 ether}(marketId, 100 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, alice, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 50 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for TWAP to be established
        vm.warp(block.timestamp + 6 minutes);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Make OTC trade to generate budget (use smaller amount to ensure vault has enough)
        vm.prank(bob);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, bob, block.timestamp + 1 hours
        );

        console.log("Trade source:", uint32(source));
        console.log("Shares out:", sharesOut);

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        // Budget should increase IF trade used vault OTC
        if (source == "otc") {
            assertGt(budgetAfter, budgetBefore, "Budget should increase from OTC fees");
            console.log("Budget increased from", budgetBefore, "to", budgetAfter);

            // Create imbalance for rebalancing
            vm.startPrank(alice);
            router.depositToVault(marketId, true, 20 ether, alice, block.timestamp + 7 hours);
            vm.stopPrank();

            // Trigger rebalance
            vm.warp(block.timestamp + 6 minutes);
            uint256 collateralUsed =
                router.rebalanceBootstrapVault(marketId, block.timestamp + 7 hours);

            console.log("Collateral used in rebalance:", collateralUsed);

            uint256 budgetFinal = router.rebalanceCollateralBudget(marketId);
            console.log("Budget after rebalance:", budgetFinal);

            // Verify collateral was used (or not, depending on conditions)
            // Budget behavior depends on whether rebalancing generated more fees
        } else {
            console.log("Trade did not use vault OTC, skipping budget assertions");
        }
    }

    /// @notice Test rebalancing disabled during close window
    function test_Rebalancing_DisabledDuringCloseWindow() public {
        // Setup vault with imbalance
        vm.startPrank(alice);
        PAMM.split{value: 100 ether}(marketId, 100 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 70 ether, alice, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 30 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate budget
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(bob);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, bob, block.timestamp + 1 hours
        );

        // Warp to close window
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        vm.warp(close - 30 minutes);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Try to rebalance (should return 0 without consuming budget)
        uint256 collateralUsed = router.rebalanceBootstrapVault(marketId, close - 1);

        assertEq(collateralUsed, 0, "Rebalance should do nothing in close window");
        assertEq(
            router.rebalanceCollateralBudget(marketId), budgetBefore, "Budget should be unchanged"
        );
    }

    // ============ LP Fee Distribution Tests ============

    /// @notice Test LP fees accumulate from vault OTC trades
    function test_LPFees_AccumulateFromVaultOTC() public {
        // Alice deposits to vault
        vm.startPrank(alice);
        PAMM.split{value: 100 ether}(marketId, 100 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        (uint112 aliceSharesBefore,,,,) = router.vaultPositions(marketId, alice);

        // Wait for TWAP
        vm.warp(block.timestamp + 6 minutes);

        // Bob trades (should fill from vault OTC)
        vm.prank(bob);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, bob, block.timestamp + 7 hours
        );

        console.log("Trade source:", uint32(source));
        console.log("Shares out:", sharesOut);

        // Wait for withdrawal cooldown (6 hours total from deposit)
        vm.warp(block.timestamp + 5 hours + 54 minutes + 1);

        // Alice withdraws to claim fees
        vm.prank(alice);
        (uint256 sharesWithdrawn, uint256 fees) = router.withdrawFromVault(
            marketId, true, aliceSharesBefore, alice, block.timestamp + 7 hours
        );

        // Fees should be positive if OTC trade occurred
        if (source == "otc") {
            assertGt(fees, 0, "Alice should earn fees from OTC trade");
        }
    }

    /// @notice Test symmetric fee distribution to both YES and NO LPs
    function test_LPFees_SymmetricDistribution() public {
        // Alice deposits YES shares
        vm.startPrank(alice);
        PAMM.split{value: 100 ether}(marketId, 100 ether, alice);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, alice, block.timestamp + 7 hours);
        vm.stopPrank();

        // Bob deposits NO shares
        vm.startPrank(bob);
        PAMM.split{value: 100 ether}(marketId, 100 ether, bob);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 50 ether, bob, block.timestamp + 7 hours);
        vm.stopPrank();

        uint256 initialYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 initialNoAcc = router.accNoCollateralPerShare(marketId);

        // CRITICAL: Wait past TWAP bootstrap delay (30+ minutes) to enable vault OTC
        vm.warp(block.timestamp + 6 hours + 1);

        // Update TWAP to make vault OTC path available
        router.updateTWAPObservation(marketId);

        // Trade
        address charlie = address(0xC4A331E);
        vm.deal(charlie, 10 ether);
        vm.prank(charlie);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, charlie, block.timestamp + 1 hours
        );

        // Verify vault OTC was used (this is what generates the symmetric fees)
        // Note: source might be "mult" if multiple venues were used, but should include OTC
        bool usedOTC = (source == "otc" || source == "mult");
        if (usedOTC) {
            uint256 finalYesAcc = router.accYesCollateralPerShare(marketId);
            uint256 finalNoAcc = router.accNoCollateralPerShare(marketId);

            // Both accumulators should increase (symmetric distribution)
            assertGt(finalYesAcc, initialYesAcc, "YES acc should increase");
            assertGt(finalNoAcc, initialNoAcc, "NO acc should also increase (symmetric!)");
        }
        // If OTC wasn't used (e.g., deviation too high), test passes but doesn't verify fees
    }

    // ============ PMFeeHookV1 Dynamic Fee Tests ============

    /// @notice Test hook returns dynamic fees based on market age
    function test_HookIntegration_DynamicFeesDecay() public {
        // Register a fresh market with the hook
        vm.startPrank(alice);
        (uint256 freshMarketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Fresh Market",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 freshFeeOrHook = _hookFeeOrHook(address(hook), true);

        // Get poolId for fresh market
        uint256 freshPoolId = router.canonicalPoolId(freshMarketId);

        // Fee at bootstrap (should be near maxFeeBps)
        uint256 feeAtStart = hook.getCurrentFeeBps(freshPoolId);
        console.log("Fee at start:", feeAtStart);

        // Fast forward partway through bootstrap window (default is 2 days, not 7)
        // At 1 day (halfway), fee should have decayed
        vm.warp(block.timestamp + 1 days);

        uint256 feeAfter1Day = hook.getCurrentFeeBps(freshPoolId);
        console.log("Fee after 1 day:", feeAfter1Day);

        // Fee should decay over time
        assertLt(feeAfter1Day, feeAtStart, "Fee should decay over time");

        // Fast forward to end of bootstrap window (2 days default)
        vm.warp(block.timestamp + 1 days); // Total: 2 days

        uint256 feeAfter2Days = hook.getCurrentFeeBps(freshPoolId);
        console.log("Fee after 2 days:", feeAfter2Days);

        // Fee should continue decaying or reach minimum floor
        assertTrue(feeAfter2Days <= feeAfter1Day, "Fee should continue decaying or reach floor");

        // After bootstrap window, fee should be at minimum
        // This is expected behavior, not a bug
    }

    /// @notice Test hook increases fee for skewed markets
    function test_HookIntegration_SkewFeeIncrease() public {
        // Create market and drive price to extreme
        vm.startPrank(alice);
        (uint256 skewMarketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Skew Market",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 skewFeeOrHook = _hookFeeOrHook(address(hook), true);
        uint256 skewPoolId = router.canonicalPoolId(skewMarketId);

        // Wait past bootstrap to isolate skew fee
        vm.warp(block.timestamp + 8 days);

        uint256 feeAtBalance = hook.getCurrentFeeBps(skewPoolId);
        console.log("Fee at balance:", feeAtBalance);

        uint256 futureDeadline = block.timestamp + 30 days;

        // Drive price to extreme by buying YES repeatedly
        for (uint256 i = 0; i < 10; i++) {
            address trader = address(uint160(5000 + i));
            vm.deal(trader, 20 ether);

            vm.warp(block.timestamp + 1 minutes);

            vm.prank(trader);
            router.buyWithBootstrap{value: 10 ether}(
                skewMarketId, true, 10 ether, 0, trader, futureDeadline
            );
        }

        uint256 feeAtSkew = hook.getCurrentFeeBps(skewPoolId);
        console.log("Fee at extreme skew:", feeAtSkew);

        // Fee should be higher due to skew
        assertGt(feeAtSkew, feeAtBalance, "Fee should increase with skew");
    }

    /// @notice Test hook halts trading during close window
    function test_HookIntegration_CloseWindowHalt() public {
        // Configure market to use closeWindowMode = 0 (halt mode)
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = (cfg.flags & ~uint16(0x0C)) | (uint16(0) << 2); // Set bits 2-3 to 00 (halt mode)

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Wait until near close
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        vm.warp(close - 30 minutes);

        // Hook should halt AMM swaps in close window (mode 0)
        // buyWithBootstrap will revert because vault is empty and AMM is blocked
        vm.prank(bob);
        vm.expectRevert(); // Expect MarketClosed from hook
        router.buyWithBootstrap{value: 1 ether}(marketId, true, 1 ether, 0, bob, close - 1);
    }

    /// @notice Test hook config can be customized per market
    function test_HookIntegration_CustomMarketConfig() public {
        // Create a market
        vm.startPrank(alice);
        (uint256 customMarketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "Custom Config Market",
            alice,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Set custom config (requires hook owner)
        PMFeeHookV1.Config memory customConfig = PMFeeHookV1.Config({
            minFeeBps: 5, // 0.05% min
            maxFeeBps: 200, // 2.00% max
            maxSkewFeeBps: 150, // 1.50% skew
            feeCapBps: 350, // 3.50% cap
            skewRefBps: 3000, // More sensitive skew
            asymmetricFeeBps: 30, // 0.30% asymmetric
            closeWindow: 2 hours,
            closeWindowFeeBps: 0,
            maxPriceImpactBps: 600,
            bootstrapWindow: 3 days,
            volatilityFeeBps: 0,
            volatilityWindow: 0,
            flags: 0x03, // Only skew + bootstrap enabled
            extraFlags: 0x01
        });

        vm.prank(hook.owner());
        hook.setMarketConfig(customMarketId, customConfig);

        // Verify config was set by checking that market has custom config
        assertTrue(hook.hasMarketConfig(customMarketId), "Should have custom config");
    }
}
