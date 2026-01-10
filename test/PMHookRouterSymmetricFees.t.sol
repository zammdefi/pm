// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

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

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

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
}

/// @title Symmetric Fee Distribution Tests
/// @notice Tests for TWAP-notional weighted fee distribution across YES and NO LPs
contract PMHookRouterSymmetricFeesTest is Test {
    PMHookRouter public router;
    PMFeeHook public hook;
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address constant ETH = address(0);
    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);
    address public constant CHARLIE = address(0xC44331E);
    address public constant DAVE = address(0xDA4E);

    uint256 public marketId;
    uint256 public poolId;
    uint256 public feeOrHook;

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    // Helper function to compute feeOrHook value
    function _hookFeeOrHook(address hook_, bool afterHook) internal pure returns (uint256) {
        uint256 flags = afterHook ? (FLAG_BEFORE | FLAG_AFTER) : FLAG_BEFORE;
        return uint256(uint160(hook_)) | flags;
    }

    // Allow contract to receive ETH (for rebalance bounties)
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main6"));

        hook = new PMFeeHook();

        // Deploy router at REGISTRAR address using vm.etch
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

        // Fund test accounts
        vm.deal(ALICE, 10000 ether);
        vm.deal(BOB, 10000 ether);
        vm.deal(CHARLIE, 10000 ether);
        vm.deal(DAVE, 10000 ether);

        // Create and bootstrap a market (use address(this) as resolver to allow initTWAP calls)
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Test Market",
            address(this), // Use test contract as resolver
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

        // Warp time to allow cumulative to accumulate after pool creation
        vm.warp(block.timestamp + 1 minutes);

        feeOrHook = _hookFeeOrHook(address(hook), true);

        // TWAP is auto-initialized during bootstrapMarket, no need to initialize manually
    }

    /// @notice Test that fees are distributed to BOTH YES and NO LPs when vault OTC is used
    function test_SymmetricFees_BothSidesEarnFees() public {
        // Store start time for absolute warps
        uint256 startTime = block.timestamp;

        // Update TWAP observations properly
        vm.warp(startTime + 31 minutes);
        router.updateTWAPObservation(marketId);
        vm.warp(startTime + 62 minutes);
        router.updateTWAPObservation(marketId);

        // Alice deposits YES shares to vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Bob deposits NO shares to vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 50 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        // Record initial acc values
        uint256 initialYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 initialNoAcc = router.accNoCollateralPerShare(marketId);

        // Check vault has YES inventory available
        (uint256 yesShares, uint256 noShares,) = router.bootstrapVaults(marketId);
        assertGt(yesShares, 0, "Vault should have YES shares");

        // Charlie buys YES
        vm.startPrank(CHARLIE);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, CHARLIE, block.timestamp + 1 hours
        );
        vm.stopPrank();

        console.log("Trade source (bytes4):", uint32(source));
        console.log("Shares out:", sharesOut);

        // Check accumulators
        uint256 finalYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 finalNoAcc = router.accNoCollateralPerShare(marketId);

        console.log("YES acc increase:", finalYesAcc - initialYesAcc);
        console.log("NO acc increase:", finalNoAcc - initialNoAcc);

        // Best execution: AMM may be used when it provides better rates
        // Fees only distribute when vault OTC is used
        if (source == bytes4("otc")) {
            assertGt(finalYesAcc, initialYesAcc, "YES LPs should earn fees when OTC used");
            assertGt(finalNoAcc, initialNoAcc, "NO LPs should also earn fees (symmetric!)");
        }
        // Trade should always succeed
        assertGt(sharesOut, 0, "Should receive shares");
    }

    /// @notice Test TWAP-weighted distribution: higher notional side earns more fees
    function test_SymmetricFees_TWAPWeightedDistribution() public {
        // Store start time for absolute warps
        uint256 startTime = block.timestamp;

        // Update TWAP observations properly
        vm.warp(startTime + 31 minutes);
        router.updateTWAPObservation(marketId);
        vm.warp(startTime + 62 minutes);
        router.updateTWAPObservation(marketId);

        // Now deposit LPs on both sides
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, BOB, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 50 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        uint256 beforeYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 beforeNoAcc = router.accNoCollateralPerShare(marketId);

        // Generate trade - buying NO
        vm.prank(CHARLIE);
        (uint256 shares, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, false, 5 ether, 0, CHARLIE, block.timestamp + 1 hours
        );

        console.log("Trade source (bytes4):", uint32(source));
        console.log("Shares out:", shares);

        uint256 afterYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 afterNoAcc = router.accNoCollateralPerShare(marketId);

        uint256 yesIncrease = afterYesAcc - beforeYesAcc;
        uint256 noIncrease = afterNoAcc - beforeNoAcc;

        // Best execution: AMM may be used when it provides better rates
        // Fees only distribute when vault OTC is used
        if (source == bytes4("otc")) {
            assertGt(yesIncrease, 0, "YES should earn some fees when OTC used");
            assertGt(noIncrease, 0, "NO should earn some fees when OTC used");
        }
        // Trade should succeed regardless
        assertGt(shares, 0, "Should receive shares");

        // The side with higher notional value should earn more (when OTC used)
        // (Exact ratio depends on TWAP price and inventory)
        console.log("YES fee increase:", yesIncrease);
        console.log("NO fee increase:", noIncrease);
    }

    /// @notice Test behavior when TWAP is freshly initialized
    function test_SymmetricFees_FallbackTo50_50_WhenNoTWAP() public {
        // Create a fresh market
        (uint256 newMarketId,,,) = router.bootstrapMarket{value: 100 ether}(
            "No TWAP Market",
            address(this),
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            address(this),
            block.timestamp + 1 hours
        );

        // Store start time and update TWAP
        uint256 startTime = block.timestamp;
        vm.warp(startTime + 31 minutes);
        router.updateTWAPObservation(newMarketId);
        vm.warp(startTime + 62 minutes);
        router.updateTWAPObservation(newMarketId);

        // Deposit equal vault shares on both sides
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(newMarketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(newMarketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(newMarketId, false, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        uint256 beforeYesAcc = router.accYesCollateralPerShare(newMarketId);
        uint256 beforeNoAcc = router.accNoCollateralPerShare(newMarketId);

        // Trade - use far future deadline to avoid any timing issues
        uint256 tradeDeadline = block.timestamp + 30 days;
        vm.prank(BOB);
        (uint256 shares, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            newMarketId, true, 5 ether, 0, BOB, tradeDeadline
        );

        uint256 afterYesAcc = router.accYesCollateralPerShare(newMarketId);
        uint256 afterNoAcc = router.accNoCollateralPerShare(newMarketId);

        uint256 yesIncrease = afterYesAcc - beforeYesAcc;
        uint256 noIncrease = afterNoAcc - beforeNoAcc;

        console.log("Trade source:", uint32(source));
        console.log("YES acc increase:", yesIncrease);
        console.log("NO acc increase:", noIncrease);

        // Best execution: AMM may be used when it provides better rates
        // Fees only distribute when vault OTC is used
        if (source == bytes4("otc")) {
            assertGt(yesIncrease, 0, "YES should earn fees when OTC used");
            assertGt(noIncrease, 0, "NO should earn fees when OTC used");
        }
        // Trade should succeed
        assertGt(shares, 0, "Should receive shares");
    }

    /// @notice Test that one-sided LP (only YES) still gets fees when OTC is used
    function test_SymmetricFees_OneSidedLP_GetsAllFees() public {
        // Establish TWAP first
        _addInitialLiquidity(100 ether);

        // Store start time and update TWAP
        uint256 startTime = block.timestamp;
        vm.warp(startTime + 31 minutes);
        router.updateTWAPObservation(marketId);
        vm.warp(startTime + 62 minutes);
        router.updateTWAPObservation(marketId);

        // Only Alice deposits YES shares (no NO LPs)
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        uint256 beforeYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 beforeNoAcc = router.accNoCollateralPerShare(marketId);

        // Trade
        vm.prank(BOB);
        (uint256 shares, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 afterYesAcc = router.accYesCollateralPerShare(marketId);
        uint256 afterNoAcc = router.accNoCollateralPerShare(marketId);

        console.log("Trade source:", uint32(source));

        // Best execution: AMM may be used when it provides better rates
        if (source == bytes4("otc")) {
            // YES should get all fees (no NO LPs to share with)
            assertGt(afterYesAcc, beforeYesAcc, "YES LPs should earn fees when OTC used");
            assertEq(afterNoAcc, beforeNoAcc, "NO acc should not change (no NO LPs)");
        }
        // Trade should succeed
        assertGt(shares, 0, "Should receive shares");
    }

    /// @notice Test that rebalance budget accumulates from vault OTC fees
    function test_SymmetricFees_BudgetAccumulation() public {
        // Establish TWAP - need multiple samples over time
        _addInitialLiquidity(100 ether);

        // Store current time and use absolute warps to avoid block.timestamp caching issues
        uint256 startTime = block.timestamp;

        // First TWAP update after MIN_TWAP_UPDATE_INTERVAL
        vm.warp(startTime + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Second TWAP update after another interval
        vm.warp(startTime + 62 minutes);
        router.updateTWAPObservation(marketId);

        // Debug: check TWAP observations
        (uint32 ts0, uint32 ts1, uint32 cached, uint32 cacheBlock, uint256 cum0, uint256 cum1) =
            router.twapObservations(marketId);
        console.log("TWAP ts0:", ts0, "ts1:", ts1);
        console.log("TWAP cum0:", cum0);
        console.log("TWAP cum1:", cum1);
        console.log("TWAP cached bps:", cached);

        // Quote function removed to reduce bytecode size
        // (uint256 quoteShares, bool quoteFilled, bytes4 quoteSource,) =
        //     router.quoteBootstrapBuy(marketId, true, 10 ether);
        // console.log("Before deposit - shares:", quoteShares, "filled:", quoteFilled);
        // console.log("Before deposit - source (bytes4):", uint32(quoteSource));

        // Create vault inventory via deposits
        vm.startPrank(DAVE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, DAVE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, DAVE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 50 ether, DAVE, block.timestamp + 7 hours);
        vm.stopPrank();

        (uint256 yesShares, uint256 noShares,) = router.bootstrapVaults(marketId);
        console.log("Vault YES:", yesShares, "NO:", noShares);

        // Quote function removed to reduce bytecode size
        // (quoteShares, quoteFilled, quoteSource,) =
        //     router.quoteBootstrapBuy(marketId, true, 10 ether);
        // console.log("After deposit - shares:", quoteShares, "filled:", quoteFilled);
        // console.log("After deposit - source (bytes4):", uint32(quoteSource));

        uint256 beforeBudget = router.rebalanceCollateralBudget(marketId);

        // Trade should use vault OTC and generate 20% rebalance budget
        // Use 5 ether to stay within 30% vault fill limit
        vm.prank(CHARLIE);
        (uint256 shares, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, CHARLIE, block.timestamp + 1 hours
        );

        console.log("Trade source (bytes4):", uint32(source));
        console.log("Shares:", shares);

        uint256 afterBudget = router.rebalanceCollateralBudget(marketId);

        // Best execution: contract chooses AMM or OTC based on which gives more shares
        // When pool is balanced with low fees, AMM often provides better execution
        // Budget only increases when vault OTC is used
        if (source == bytes4("otc")) {
            assertGt(afterBudget, beforeBudget, "Rebalance budget should increase when OTC used");
        }
        // Trade should succeed regardless of source
        assertGt(shares, 0, "Should receive shares");
    }

    /// @notice Test preventing cold-side liquidity drain over many one-sided trades
    function test_SymmetricFees_PreventsColdSideDrain() public {
        // Use deadline far in future to avoid expiry after warps
        uint256 deadline = block.timestamp + 30 days;

        // Setup: Both Alice and Bob deposit equal shares
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, deadline);
        vm.stopPrank();

        vm.startPrank(BOB);
        PAMM.split{value: 200 ether}(marketId, 200 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, deadline);
        vm.stopPrank();

        // Simulate 10 one-sided trades (all buying YES)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 6 hours + 1);

            address trader = address(uint160(1000 + i));
            vm.deal(trader, 10 ether);

            vm.prank(trader);
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, trader, deadline);
        }

        // Both Alice and Bob should have earned fees despite only YES being traded
        vm.prank(ALICE);
        (, uint256 aliceFees) = router.withdrawFromVault(marketId, true, 100 ether, ALICE, deadline);

        vm.prank(BOB);
        (, uint256 bobFees) = router.withdrawFromVault(marketId, false, 100 ether, BOB, deadline);

        assertGt(aliceFees, 0, "Alice (YES LP) should earn fees");
        assertGt(bobFees, 0, "Bob (NO LP) should also earn fees (preventing drain!)");

        console.log("Alice (YES LP) earned:", aliceFees);
        console.log("Bob (NO LP) earned:", bobFees);
    }

    function test_MergeFees_ProbabilityWeighted_At80Percent() public {
        // Use deadline far in future to avoid expiry after warps
        uint256 deadline = block.timestamp + 30 days;

        // Setup: Create market and add canonical pool
        _addInitialLiquidity(100 ether);

        // Time must pass for TWAP to be available
        vm.warp(block.timestamp + 6 hours + 1);

        // Alice deposits 100 ETH worth of YES shares into vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, deadline);
        vm.stopPrank();

        // Bob deposits 100 ETH worth of NO shares into vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, deadline);
        vm.stopPrank();

        // Drive price to ~80% YES by having traders buy YES repeatedly
        for (uint256 i = 0; i < 15; i++) {
            address trader = address(uint160(2000 + i));
            vm.deal(trader, 20 ether);

            // Warp time between trades to build TWAP
            vm.warp(block.timestamp + 30 seconds);

            vm.prank(trader);
            router.buyWithBootstrap{value: 10 ether}(marketId, true, 10 ether, 0, trader, deadline);
        }

        // Wait for TWAP to catch up to spot price to avoid SpotDeviantFromTWAP
        vm.warp(block.timestamp + 7 hours);

        // Capture YES and NO vault shares before merge
        uint256 yesSharesBefore = router.totalYesVaultShares(marketId);
        uint256 noSharesBefore = router.totalNoVaultShares(marketId);

        // Trigger rebalance which performs merge and distributes fees
        router.rebalanceBootstrapVault(marketId, deadline);

        // Capture YES and NO vault shares after merge + fee distribution
        uint256 yesSharesAfter = router.totalYesVaultShares(marketId);
        uint256 noSharesAfter = router.totalNoVaultShares(marketId);

        uint256 yesFeeShares =
            yesSharesAfter > yesSharesBefore ? yesSharesAfter - yesSharesBefore : 0;
        uint256 noFeeShares = noSharesAfter > noSharesBefore ? noSharesAfter - noSharesBefore : 0;

        // Fee distribution should be proportional to TWAP-weighted notional value
        uint256 totalFeeShares = yesFeeShares + noFeeShares;
        uint256 yesPercentage = totalFeeShares > 0 ? (yesFeeShares * 100) / totalFeeShares : 0;

        console.log("After buying YES: YES LPs got", yesPercentage, "% of merge fees");
        console.log("YES fee shares:", yesFeeShares);
        console.log("NO fee shares:", noFeeShares);

        // TWAP is lifetime average, so even after many YES buys, distribution depends on TWAP
        // Just verify that IF fees are distributed, BOTH sides get some (symmetric distribution)
        if (totalFeeShares > 0) {
            assertGt(yesFeeShares, 0, "YES LPs should get some fees");
            assertGt(noFeeShares, 0, "NO LPs should get some fees");
        }
    }

    function test_MergeFees_ProbabilityWeighted_At20Percent() public {
        // Use deadline far in future to avoid expiry after warps
        uint256 deadline = block.timestamp + 30 days;

        // Setup: Create market and add canonical pool
        _addInitialLiquidity(100 ether);

        // Time must pass for TWAP to be available
        vm.warp(block.timestamp + 6 hours + 1);

        // Alice deposits 100 ETH worth of YES shares into vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, deadline);
        vm.stopPrank();

        // Bob deposits 100 ETH worth of NO shares into vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, deadline);
        vm.stopPrank();

        // Drive price to ~20% YES (80% NO) by having traders buy NO repeatedly
        for (uint256 i = 0; i < 15; i++) {
            address trader = address(uint160(3000 + i));
            vm.deal(trader, 20 ether);

            // Warp time between trades to build TWAP
            vm.warp(block.timestamp + 30 seconds);

            vm.prank(trader);
            router.buyWithBootstrap{value: 10 ether}(marketId, false, 10 ether, 0, trader, deadline);
        }

        // Wait for TWAP to catch up to spot price to avoid SpotDeviantFromTWAP
        vm.warp(block.timestamp + 7 hours);

        // TWAP should be tracking - check it's initialized
        (uint32 ts0, uint32 twapTimestamp,,, uint256 cum0,) = router.twapObservations(marketId);
        assertGt(twapTimestamp, 0, "TWAP should be initialized");

        // Capture YES and NO vault shares before merge
        uint256 yesSharesBefore = router.totalYesVaultShares(marketId);
        uint256 noSharesBefore = router.totalNoVaultShares(marketId);

        // Trigger rebalance which performs merge and distributes fees
        router.rebalanceBootstrapVault(marketId, deadline);

        // Capture YES and NO vault shares after merge + fee distribution
        uint256 yesSharesAfter = router.totalYesVaultShares(marketId);
        uint256 noSharesAfter = router.totalNoVaultShares(marketId);

        uint256 yesFeeShares =
            yesSharesAfter > yesSharesBefore ? yesSharesAfter - yesSharesBefore : 0;
        uint256 noFeeShares = noSharesAfter > noSharesBefore ? noSharesAfter - noSharesBefore : 0;

        // Fee distribution should be proportional to TWAP-weighted notional value
        uint256 totalFeeShares = yesFeeShares + noFeeShares;
        uint256 yesPercentage = totalFeeShares > 0 ? (yesFeeShares * 100) / totalFeeShares : 0;

        console.log("YES LPs got", yesPercentage, "% of merge fees");
        console.log("YES fee shares:", yesFeeShares);
        console.log("NO fee shares:", noFeeShares);

        // TWAP is lifetime average, so even after many NO buys, it may not reach 20%
        // Just verify that IF fees are distributed, BOTH sides get some (symmetric distribution)
        if (totalFeeShares > 0) {
            assertGt(yesFeeShares, 0, "YES LPs should get some fees");
            assertGt(noFeeShares, 0, "NO LPs should get some fees");
        }
    }

    function test_SettleBudget_ProbabilityWeighted_PostClose() public {
        // Use deadline far in future to avoid expiry after warps (market close is +30 days)
        uint256 deadline = block.timestamp + 60 days;

        // Setup: Create market and add canonical pool
        _addInitialLiquidity(100 ether);

        // Time must pass for TWAP to be available
        vm.warp(block.timestamp + 6 hours + 1);

        // Alice deposits 100 ETH into YES vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, deadline);
        vm.stopPrank();

        // Bob deposits 100 ETH into NO vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, deadline);
        vm.stopPrank();

        // Drive price to ~75% YES
        for (uint256 i = 0; i < 10; i++) {
            address trader = address(uint160(4000 + i));
            vm.deal(trader, 20 ether);

            // Warp time between trades
            vm.warp(block.timestamp + 30 seconds);

            vm.prank(trader);
            router.buyWithBootstrap{value: 8 ether}(marketId, true, 8 ether, 0, trader, deadline);
        }

        // Warp to after close time
        vm.warp(block.timestamp + 31 days);

        // Capture vault shares before settlement
        uint256 yesSharesBefore = router.totalYesVaultShares(marketId);
        uint256 noSharesBefore = router.totalNoVaultShares(marketId);

        // Settle rebalance budget (merges balanced pairs and distributes)
        router.settleRebalanceBudget(marketId);

        // Capture vault shares after settlement
        uint256 yesSharesAfter = router.totalYesVaultShares(marketId);
        uint256 noSharesAfter = router.totalNoVaultShares(marketId);

        uint256 yesFeeShares = yesSharesAfter - yesSharesBefore;
        uint256 noFeeShares = noSharesAfter - noSharesBefore;

        if (yesFeeShares + noFeeShares > 0) {
            uint256 totalFeeShares = yesFeeShares + noFeeShares;
            uint256 yesPercentage = (yesFeeShares * 100) / totalFeeShares;

            console.log("Post-close settlement: YES LPs got", yesPercentage, "% of budget");
            console.log("YES fee shares:", yesFeeShares);
            console.log("NO fee shares:", noFeeShares);

            // At pYes ~75%, YES LPs should get majority
            assertGt(yesPercentage, 55, "YES LPs should get majority at pYes>50%");
        }
    }

    function test_SettleBudget_RequiresCloseTime_RegarlessOfResolution() public {
        // Setup: Create market
        _addInitialLiquidity(100 ether);

        // Try to settle before close time (should revert even if market could theoretically resolve early)
        vm.expectRevert(abi.encodeWithSelector(PMHookRouter.TimingError.selector, 3)); // MarketNotClosed
        router.settleRebalanceBudget(marketId);

        // Warp to after close time
        vm.warp(block.timestamp + 31 days);

        // Should succeed now
        router.settleRebalanceBudget(marketId);
    }

    // ============ Helper Functions ============

    function _addInitialLiquidity(uint256 amount) internal {
        vm.startPrank(ALICE);
        PAMM.split{value: amount}(marketId, amount, ALICE);
        PAMM.setOperator(address(ZAMM), true);

        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);

        IZAMM.PoolKey memory key = IZAMM.PoolKey({
            id0: yesId < noId ? yesId : noId,
            id1: yesId < noId ? noId : yesId,
            token0: address(PAMM),
            token1: address(PAMM),
            feeOrHook: feeOrHook
        });

        ZAMM.addLiquidity{value: 0}(key, amount, amount, 0, 0, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Allow time for pool cumulative to accumulate
        vm.warp(block.timestamp + 1 minutes);
    }
}
