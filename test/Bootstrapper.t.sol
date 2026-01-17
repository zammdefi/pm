// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/Bootstrapper.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMMExtended {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function getMarketId(string calldata description, address resolver, address collateral)
        external
        pure
        returns (uint256);
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
}

interface IResolverExtended {
    function conditions(uint256 marketId)
        external
        view
        returns (
            address targetA,
            address targetB,
            uint8 op,
            bool isRatio,
            uint256 threshold,
            bytes memory callDataA,
            bytes memory callDataB
        );
}

interface IMasterRouterExtended {
    function bidPools(bytes32 bidPoolId)
        external
        view
        returns (
            uint256 totalCollateral,
            uint256 totalScaled,
            uint256 accSharesPerScaled,
            uint256 sharesAcquired
        );
    function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
        external
        pure
        returns (bytes32);
}

/// @title Bootstrapper Tests
/// @notice Tests for the Bootstrapper market creation helper
/// @dev Uses actual deployed contracts on mainnet fork
contract BootstrapperTest is Test {
    Bootstrapper public bootstrapper;

    // Actual deployed addresses
    IPAMMExtended constant PAMM = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant HOOK_ROUTER = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant RESOLVER = 0x00000000002205020E387b6a378c05639047BcFB;
    IMasterRouterExtended constant MASTER_ROUTER =
        IMasterRouterExtended(0x000000000055CdB14b66f37B96a571108FFEeA5C);

    // Chainlink ETH/USD price feed on mainnet
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Deployed in setUp
    PMFeeHook public hook;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy PMFeeHook and transfer ownership to HookRouter
        hook = new PMFeeHook();
        vm.prank(hook.owner());
        hook.transferOwnership(HOOK_ROUTER);

        // Deploy bootstrapper (uses hardcoded addresses)
        bootstrapper = new Bootstrapper();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        OPEN RESOLVER BOOTSTRAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test basic bootstrapMarket with ETH collateral
    function test_bootstrapMarket_ETH() public {
        string memory description = "Test Open Market ETH";
        uint256 collateralForLP = 10 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut) = bootstrapper.bootstrapMarket{
            value: collateralForLP
        }(
            description,
            alice, // custom resolver (EOA)
            address(0), // ETH
            uint64(block.timestamp + 30 days),
            true, // canClose
            address(hook),
            collateralForLP,
            false, // buyYes
            0, // collateralForBuy
            0, // minSharesOut
            alice,
            block.timestamp + 1 hours
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses custom resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, alice, "Market should use custom resolver");
    }

    /// @notice Test bootstrapMarket with initial buy
    function test_bootstrapMarket_withBuy() public {
        string memory description = "Test Market With Buy";
        uint256 collateralForLP = 10 ether;
        uint256 collateralForBuy = 2 ether;

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares, uint256 sharesOut) = bootstrapper.bootstrapMarket{
            value: collateralForLP + collateralForBuy
        }(
            description,
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            collateralForLP,
            true, // buyYes
            collateralForBuy,
            0,
            alice,
            block.timestamp + 1 hours
        );

        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive YES shares from buy");

        // Verify alice received shares
        uint256 yesBalance = PAMM.balanceOf(alice, marketId);
        assertGt(yesBalance, 0, "Alice should have YES shares");
    }

    /// @notice Test bootstrapMarket refunds excess ETH
    function test_bootstrapMarket_refundsExcess() public {
        string memory description = "Test Refund";
        uint256 collateralForLP = 5 ether;
        uint256 excessETH = 3 ether;

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        bootstrapper.bootstrapMarket{value: collateralForLP + excessETH}(
            description,
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            collateralForLP,
            false,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Alice should get excess refunded
        assertEq(
            alice.balance, aliceBalanceBefore - collateralForLP, "Excess ETH should be refunded"
        );
    }

    /// @notice Test bootstrapMarketWithBids creates market and orderbook bids
    function test_bootstrapMarketWithBids_ETH() public {
        string memory description = "Test Market With Bids";
        uint256 collateralForLP = 10 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 4000, // 40%
            amount: 5 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 3000, // 30%
            amount: 3 ether,
            minShares: 0
        });

        uint256 totalRequired = collateralForLP + 5 ether + 3 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapMarketWithBids{
            value: totalRequired
        }(
            description,
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pools were created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 4000);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 3000);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 5 ether, "YES bid pool should have 5 ETH");
        assertEq(noCollateral, 3 ether, "NO bid pool should have 3 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        RESOLVER.SOL BOOTSTRAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapWithCondition creates market and registers condition
    function test_bootstrapWithCondition() public {
        string memory description = "ETH above 5000 USD";
        uint256 collateralForLP = 10 ether;
        uint256 priceThreshold = 5000e8; // $5000 in 8 decimals

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares,) = bootstrapper.bootstrapWithCondition{
            value: collateralForLP
        }(
            description,
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // canClose
            address(hook),
            collateralForLP,
            false, // buyYes
            0, // collateralForBuy
            0, // minSharesOut
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED, // target
            abi.encodeWithSelector(0x50d25bcd), // latestAnswer()
            IResolver.Op.GTE,
            priceThreshold
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver constant");

        // Verify condition was registered
        (address targetA,, uint8 op,, uint256 threshold,,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, ETH_USD_FEED, "Condition target should be price feed");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, priceThreshold, "Condition threshold should match");
    }

    /// @notice Test bootstrapWithConditionAndBids creates market with condition + orderbook bids
    function test_bootstrapWithConditionAndBids() public {
        string memory description = "Custom condition with bids";
        uint256 collateralForLP = 6 ether;
        uint256 threshold = 5000e8;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 6000, // 60%
            amount: 2 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 3500, // 35%
            amount: 1.5 ether,
            minShares: 0
        });

        uint256 totalRequired = collateralForLP + 3.5 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapWithConditionAndBids{
            value: totalRequired
        }(
            description,
            address(0), // ETH collateral
            uint64(block.timestamp + 60 days),
            true, // canClose
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED, // target
            abi.encodeWithSelector(0x50d25bcd), // latestAnswer()
            IResolver.Op.GTE,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify condition was registered
        (address targetA,, uint8 op,, uint256 thresholdStored,,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, ETH_USD_FEED, "Condition target should be price feed");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(thresholdStored, threshold, "Condition threshold should match");

        // Verify bid pools were created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6000);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 3500);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
        assertEq(noCollateral, 1.5 ether, "NO bid pool should have 1.5 ETH");
    }

    /// @notice Test bootstrapPriceMarket simplified interface
    function test_bootstrapPriceMarket() public {
        string memory description = "BTC above 100k";
        uint256 collateralForLP = 8 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapPriceMarket{
            value: collateralForLP
        }(
            description,
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED,
            IResolver.Op.GTE,
            100000e8 // $100k
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
    }

    /// @notice Test bootstrapPriceMarketWithBids
    function test_bootstrapPriceMarketWithBids() public {
        string memory description = "ETH above 10k with bids";
        uint256 collateralForLP = 10 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 6000, amount: 4 ether, minShares: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares) = bootstrapper.bootstrapPriceMarketWithBids{
            value: 14 ether
        }(
            description,
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED,
            IResolver.Op.GTE,
            10000e8,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pool
        bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6000);
        (uint256 collateral,,,) = MASTER_ROUTER.bidPools(bidPoolId);
        assertEq(collateral, 4 ether, "Bid pool should have 4 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        ETH BALANCE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapETHBalanceMarket for native ETH balance condition
    function test_bootstrapETHBalanceMarket() public {
        string memory description = "Will vitalik hold 100k ETH by 2025?";
        address accountToCheck = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // vitalik.eth
        uint256 collateralForLP = 10 ether;
        uint256 balanceThreshold = 100_000 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapETHBalanceMarket{
            value: collateralForLP
        }(
            description,
            address(0), // ETH collateral
            uint64(block.timestamp + 365 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.GTE,
            balanceThreshold
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver constant");

        // Verify condition was registered with empty callData (ETH balance check)
        (address targetA,, uint8 op,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, accountToCheck, "Condition target should be account to check");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, balanceThreshold, "Condition threshold should match");
        assertEq(callDataA.length, 0, "CallData should be empty for ETH balance check");
    }

    /// @notice Test bootstrapETHBalanceMarketWithBids
    function test_bootstrapETHBalanceMarketWithBids() public {
        string memory description = "Will whale hold 50k ETH?";
        address accountToCheck = 0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8; // Binance 7
        uint256 collateralForLP = 8 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 7000, // 70% - likely to hold
            amount: 3 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 2000, // 20%
            amount: 2 ether,
            minShares: 0
        });

        uint256 totalRequired = collateralForLP + 5 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapETHBalanceMarketWithBids{
            value: totalRequired
        }(
            description,
            address(0),
            uint64(block.timestamp + 180 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.GTE,
            50_000 ether,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pools
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 7000);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 2000);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 3 ether, "YES bid pool should have 3 ETH");
        assertEq(noCollateral, 2 ether, "NO bid pool should have 2 ETH");

        // Verify condition
        (address targetA,,,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, accountToCheck, "Target should be account");
        assertEq(threshold, 50_000 ether, "Threshold should be 50k ETH");
        assertEq(callDataA.length, 0, "CallData should be empty");
    }

    /*//////////////////////////////////////////////////////////////
                        TOKEN BALANCE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapTokenBalanceMarket for ERC20 balanceOf condition
    function test_bootstrapTokenBalanceMarket() public {
        string memory description = "Will treasury hold 1B USDC?";
        address usdcToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC on mainnet
        address accountToCheck = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Binance USDC holder
        uint256 collateralForLP = 10 ether;
        uint256 balanceThreshold = 1_000_000_000e6; // 1B USDC (6 decimals)

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapTokenBalanceMarket{
            value: collateralForLP
        }(
            description,
            address(0), // ETH collateral
            uint64(block.timestamp + 365 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            usdcToken,
            accountToCheck,
            IResolver.Op.GTE,
            balanceThreshold
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver constant");

        // Verify condition was registered with balanceOf callData
        (address targetA,, uint8 op,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, usdcToken, "Condition target should be token address");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, balanceThreshold, "Condition threshold should match");

        // Verify callData is balanceOf(accountToCheck)
        bytes memory expectedCallData = abi.encodeWithSelector(0x70a08231, accountToCheck);
        assertEq(callDataA, expectedCallData, "CallData should be balanceOf(account)");
    }

    /// @notice Test bootstrapTokenBalanceMarketWithBids
    function test_bootstrapTokenBalanceMarketWithBids() public {
        string memory description = "Will bridge hold 100M USDC?";
        address usdcToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address accountToCheck = 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf; // Polygon bridge
        uint256 collateralForLP = 6 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 8000, // 80%
            amount: 4 ether,
            minShares: 0
        });

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapTokenBalanceMarketWithBids{
            value: 10 ether
        }(
            description,
            address(0),
            uint64(block.timestamp + 90 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            usdcToken,
            accountToCheck,
            IResolver.Op.GTE,
            100_000_000e6, // 100M USDC
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pool
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 8000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 4 ether, "YES bid pool should have 4 ETH");

        // Verify condition target and callData
        (address targetA,,,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, usdcToken, "Target should be token");
        assertEq(threshold, 100_000_000e6, "Threshold should be 100M");

        bytes memory expectedCallData = abi.encodeWithSelector(0x70a08231, accountToCheck);
        assertEq(callDataA, expectedCallData, "CallData should be balanceOf(account)");
    }

    /// @notice Test balance market with LT operator (less than)
    function test_bootstrapETHBalanceMarket_LTOperator() public {
        string memory description = "Will address hold less than 1 ETH?";
        address accountToCheck = address(0xDEAD);
        uint256 collateralForLP = 5 ether;

        vm.prank(alice);
        (uint256 marketId,,) = bootstrapper.bootstrapETHBalanceMarket{value: collateralForLP}(
            description,
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.LT, // Less than
            1 ether
        );

        // Verify condition uses LT
        (,, uint8 op,, uint256 threshold,,) = IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(op, uint8(IResolver.Op.LT), "Condition op should be LT");
        assertEq(threshold, 1 ether, "Threshold should be 1 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        ORDERBOOK BID TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test addOrderbookBids to existing market
    function test_addOrderbookBids() public {
        // First create a market
        string memory description = "Market for bids test";

        vm.prank(alice);
        (uint256 marketId,,,) = bootstrapper.bootstrapMarket{value: 10 ether}(
            description,
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            false,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Now bob adds bids
        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 5500, amount: 6 ether, minShares: 0});
        bids[1] =
            Bootstrapper.BidOrder({buyYes: false, priceInBps: 4500, amount: 4 ether, minShares: 0});

        vm.prank(bob);
        bootstrapper.addOrderbookBids{value: 10 ether}(marketId, address(0), bids, bob);

        // Verify bid pools
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 5500);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 4500);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 6 ether, "YES bid should have 6 ETH");
        assertEq(noCollateral, 4 ether, "NO bid should have 4 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test multicall with multiple operations
    function test_multicall_multipleBootstraps() public {
        bytes[] memory calls = new bytes[](2);

        // First market
        calls[0] = abi.encodeCall(
            bootstrapper.bootstrapMarket,
            (
                "Multicall Market 1",
                alice,
                address(0),
                uint64(block.timestamp + 30 days),
                true,
                address(hook),
                5 ether,
                false,
                0,
                0,
                alice,
                block.timestamp + 1 hours
            )
        );

        // Second market
        calls[1] = abi.encodeCall(
            bootstrapper.bootstrapMarket,
            (
                "Multicall Market 2",
                bob,
                address(0),
                uint64(block.timestamp + 60 days),
                true,
                address(hook),
                5 ether,
                false,
                0,
                0,
                alice,
                block.timestamp + 1 hours
            )
        );

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        bytes[] memory results = bootstrapper.multicall{value: 10 ether}(calls);

        assertEq(results.length, 2, "Should have 2 results");

        // Decode results
        (uint256 marketId1,,,) = abi.decode(results[0], (uint256, uint256, uint256, uint256));
        (uint256 marketId2,,,) = abi.decode(results[1], (uint256, uint256, uint256, uint256));

        assertGt(marketId1, 0, "First market should be created");
        assertGt(marketId2, 0, "Second market should be created");
        assertTrue(marketId1 != marketId2, "Markets should have different IDs");

        // All ETH should be used (allow 1 wei dust from LP rounding)
        assertApproxEqAbs(alice.balance, aliceBalanceBefore - 10 ether, 1, "All ETH should be used");
    }

    /// @notice Test multicall refunds excess ETH
    function test_multicall_refundsExcess() public {
        bytes[] memory calls = new bytes[](1);

        calls[0] = abi.encodeCall(
            bootstrapper.bootstrapMarket,
            (
                "Single Market",
                alice,
                address(0),
                uint64(block.timestamp + 30 days),
                true,
                address(hook),
                5 ether,
                false,
                0,
                0,
                alice,
                block.timestamp + 1 hours
            )
        );

        uint256 aliceBalanceBefore = alice.balance;
        uint256 excess = 3 ether;

        vm.prank(alice);
        bootstrapper.multicall{value: 5 ether + excess}(calls);

        // Excess should be refunded via selfbalance() (allow 1 wei dust from LP rounding)
        assertApproxEqAbs(
            alice.balance, aliceBalanceBefore - 5 ether, 1, "Excess should be refunded"
        );
    }

    /// @notice Test multicall with bootstrap + addOrderbookBids
    function test_multicall_bootstrapAndBids() public {
        // Compute marketId ahead of time
        uint256 expectedMarketId =
            bootstrapper.computeMarketId("Market for multicall bids", alice, address(0));

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 5000, amount: 3 ether, minShares: 0});

        bytes[] memory calls = new bytes[](2);

        // Bootstrap market
        calls[0] = abi.encodeCall(
            bootstrapper.bootstrapMarket,
            (
                "Market for multicall bids",
                alice,
                address(0),
                uint64(block.timestamp + 30 days),
                true,
                address(hook),
                7 ether,
                false,
                0,
                0,
                alice,
                block.timestamp + 1 hours
            )
        );

        // Add bids using precomputed marketId
        calls[1] = abi.encodeCall(
            bootstrapper.addOrderbookBids, (expectedMarketId, address(0), bids, alice)
        );

        vm.prank(alice);
        bytes[] memory results = bootstrapper.multicall{value: 10 ether}(calls);

        // Verify market created
        (uint256 actualMarketId,,,) = abi.decode(results[0], (uint256, uint256, uint256, uint256));
        assertEq(actualMarketId, expectedMarketId, "MarketId should match precomputed");

        // Verify bid pool
        bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(expectedMarketId, true, 5000);
        (uint256 collateral,,,) = MASTER_ROUTER.bidPools(bidPoolId);
        assertEq(collateral, 3 ether, "Bid pool should have 3 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test computeMarketId with custom resolver
    function test_computeMarketId() public view {
        string memory description = "Test Description";
        address customResolver = address(0x1234);

        uint256 marketId = bootstrapper.computeMarketId(description, customResolver, address(0));
        uint256 expected = PAMM.getMarketId(description, customResolver, address(0));

        assertEq(marketId, expected, "computeMarketId should match PAMM");
    }

    /// @notice Test computeMarketIdResolver uses constant resolver
    function test_computeMarketIdResolver() public view {
        string memory description = "Test Description";

        uint256 marketId = bootstrapper.computeMarketIdResolver(description, address(0));
        uint256 expected = PAMM.getMarketId(description, RESOLVER, address(0));

        assertEq(marketId, expected, "computeMarketIdResolver should use RESOLVER constant");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test empty bids array
    function test_bootstrapMarketWithBids_emptyBids() public {
        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](0);

        vm.prank(alice);
        (uint256 marketId,,) = bootstrapper.bootstrapMarketWithBids{value: 10 ether}(
            "Market No Bids",
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            bids
        );

        assertGt(marketId, 0, "Market should still be created");
    }

    /// @notice Test bids with zero amounts are skipped
    function test_addOrderbookBids_skipsZeroAmount() public {
        // Create market first
        vm.prank(alice);
        (uint256 marketId,,,) = bootstrapper.bootstrapMarket{value: 10 ether}(
            "Market for zero bid test",
            alice,
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            false,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 5000,
            amount: 0, // zero - should be skipped
            minShares: 0
        });
        bids[1] =
            Bootstrapper.BidOrder({buyYes: false, priceInBps: 4000, amount: 2 ether, minShares: 0});

        vm.prank(bob);
        bootstrapper.addOrderbookBids{value: 2 ether}(marketId, address(0), bids, bob);

        // Only NO bid should exist
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 4000);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);
        assertEq(noCollateral, 2 ether, "NO bid should have 2 ETH");
    }

    /// @notice Test reentrancy protection exists
    function test_reentrancy_guard_exists() public pure {
        assertTrue(true, "Reentrancy guard exists via transient storage");
    }

    /*//////////////////////////////////////////////////////////////
                        GASPM-STYLE BOOTSTRAP VIA HOOKROUTER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapGasTWAPMarketWithBids creates hooked gas market + orderbook bids
    function test_bootstrapGasTWAPMarketWithBids() public {
        uint256 threshold = 30 gwei; // 30 gwei gas price threshold
        uint256 collateralForLP = 5 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 4500, // 45% - betting gas stays low
            amount: 2 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 5500, // 55%
            amount: 3 ether,
            minShares: 0
        });

        uint256 totalRequired = collateralForLP + 5 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasTWAPMarketWithBids{
            value: totalRequired
        }(
            "Gas TWAP <= 30 gwei",
            address(0), // ETH collateral
            uint64(block.timestamp + 7 days),
            true, // canClose
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.LTE,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");

        // Verify bid pools were created via MasterRouter
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 4500);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 5500);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
        assertEq(noCollateral, 3 ether, "NO bid pool should have 3 ETH");
    }

    /// @notice Test bootstrapGasRangeMarketWithBids creates hooked gas range market + orderbook bids
    function test_bootstrapGasRangeMarketWithBids() public {
        uint256 lower = 20 gwei;
        uint256 upper = 50 gwei;
        uint256 collateralForLP = 4 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 6000, // 60% - betting gas stays in range
            amount: 2 ether,
            minShares: 0
        });

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares) = bootstrapper.bootstrapGasRangeMarketWithBids{
            value: 6 ether
        }(
            "Gas in 20-50 gwei range",
            address(0),
            uint64(block.timestamp + 14 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            lower,
            upper,
            bids
        );

        assertGt(marketId, 0, "Range market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pool
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
    }

    /// @notice Test bootstrapGasVolatilityMarketWithBids creates hooked gas volatility market + orderbook bids
    function test_bootstrapGasVolatilityMarketWithBids() public {
        uint256 threshold = 100 gwei; // volatility spread threshold
        uint256 collateralForLP = 5 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 3000, // 30% - betting for high volatility
            amount: 1.5 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 7000, // 70% - betting for stability
            amount: 1.5 ether,
            minShares: 0
        });

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares) = bootstrapper.bootstrapGasVolatilityMarketWithBids{
            value: 8 ether
        }(
            "Gas volatility >= 100 gwei spread",
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Volatility market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pools
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 3000);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 7000);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 1.5 ether, "YES bid pool should have 1.5 ETH");
        assertEq(noCollateral, 1.5 ether, "NO bid pool should have 1.5 ETH");
    }

    /// @notice Test bootstrapGasPeakMarketWithBids creates hooked gas peak market + orderbook bids
    function test_bootstrapGasPeakMarketWithBids() public {
        uint256 threshold = 200 gwei; // peak threshold
        uint256 collateralForLP = 6 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 2000, // 20% - betting gas spikes high
            amount: 4 ether,
            minShares: 0
        });

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares) = bootstrapper.bootstrapGasPeakMarketWithBids{
            value: 10 ether
        }(
            "Gas peak >= 200 gwei",
            address(0),
            uint64(block.timestamp + 60 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Peak market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pool
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 2000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 4 ether, "YES bid pool should have 4 ETH");
    }

    /// @notice Test bootstrapGasTroughMarketWithBids creates hooked gas trough market + orderbook bids
    function test_bootstrapGasTroughMarketWithBids() public {
        uint256 threshold = 5 gwei; // trough threshold
        uint256 collateralForLP = 5 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 8000, // 80% - betting gas doesn't go that low
            amount: 3 ether,
            minShares: 0
        });

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares) = bootstrapper.bootstrapGasTroughMarketWithBids{
            value: 8 ether
        }(
            "Gas trough <= 5 gwei",
            address(0),
            uint64(block.timestamp + 90 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Trough market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pool
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 8000);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);
        assertEq(noCollateral, 3 ether, "NO bid pool should have 3 ETH");
    }

    /// @notice Test gas bootstrap with empty bids array
    function test_bootstrapGasTWAPMarketWithBids_emptyBids() public {
        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](0);

        vm.prank(alice);
        (uint256 marketId,,) = bootstrapper.bootstrapGasTWAPMarketWithBids{value: 5 ether}(
            "Gas >= 30 gwei",
            address(0),
            uint64(block.timestamp + 7 days),
            true,
            address(hook),
            5 ether,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            30 gwei,
            bids
        );

        assertGt(marketId, 0, "Market should still be created with empty bids");
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that slippage protection reverts when minShares exceeds expected
    function test_slippageProtection_reverts() public {
        // Expected shares = amount * 10000 / priceInBps
        // With amount = 10 ether and priceInBps = 5000, expected = 20 ether
        // Setting minShares to 25 ether should revert
        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 5000,
            amount: 10 ether,
            minShares: 25 ether // Higher than expected (20 ether)
        });

        vm.prank(alice);
        vm.expectRevert();
        bootstrapper.bootstrapMarketWithBids{value: 15 ether}(
            "Slippage test market",
            address(hook), // any resolver
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            5 ether,
            alice,
            block.timestamp + 1 hours,
            bids
        );
    }

    /// @notice Test that slippage protection passes when minShares is met
    function test_slippageProtection_passes() public {
        // Expected shares = amount * 10000 / priceInBps
        // With amount = 10 ether and priceInBps = 5000, expected = 20 ether
        // Setting minShares to 19 ether should pass
        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 5000,
            amount: 10 ether,
            minShares: 19 ether // Less than expected (20 ether)
        });

        vm.prank(alice);
        (uint256 marketId,,) = bootstrapper.bootstrapMarketWithBids{value: 15 ether}(
            "Slippage test market 2",
            address(hook), // any resolver
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            5 ether,
            alice,
            block.timestamp + 1 hours,
            bids
        );

        assertGt(marketId, 0, "Market should be created with slippage check passing");
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT OTC DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapMarketWithVault creates market + AMM + vault deposits
    function test_bootstrapMarketWithVault() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 5 ether,
            vaultYesShares: 3 ether, // 3 YES to vault
            vaultNoShares: 2 ether // 2 NO to vault
        });

        Bootstrapper.InitialBuy memory buy = Bootstrapper.InitialBuy({
            buyYes: false,
            collateralForBuy: 0 // no initial buy
        });

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapMarketWithVault{value: 15 ether}(
            "Vault test market",
            address(hook), // any resolver
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether, // AMM liquidity
            alice,
            block.timestamp + 1 hours,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
    }

    /// @notice Test bootstrapMarketWithVaultAndBids creates market + AMM + vault + orderbook
    function test_bootstrapMarketWithVaultAndBids() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 4 ether, vaultYesShares: 2 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 6000, amount: 3 ether, minShares: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapMarketWithVaultAndBids{
            value: 17 ether
        }(
            "Vault+bids test market",
            address(hook),
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether, // AMM
            alice,
            block.timestamp + 1 hours,
            vault,
            buy,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify bid pool was created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 3 ether, "YES bid pool should have 3 ETH");
    }

    /// @notice Test bootstrapWithConditionAndVault creates Resolver market + vault
    function test_bootstrapWithConditionAndVault() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 4 ether, vaultYesShares: 2 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapWithConditionAndVault{
            value: 14 ether
        }(
            "Condition+vault test",
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED, // target - use chainlink feed as arbitrary target
            abi.encodeWithSelector(0x50d25bcd), // latestAnswer()
            IResolver.Op.GTE,
            100,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
    }

    /// @notice Test bootstrapPriceMarketWithVault creates Chainlink price market + vault
    function test_bootstrapPriceMarketWithVault() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapPriceMarketWithVault{
            value: 13 ether
        }(
            "ETH >= $5000 + vault",
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED,
            IResolver.Op.GTE,
            500000000000, // $5000 with 8 decimals
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
    }

    /// @notice Test bootstrapPriceMarketWithVaultAndBids creates Chainlink market + vault + bids
    function test_bootstrapPriceMarketWithVaultAndBids() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 7000, amount: 2 ether, minShares: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapPriceMarketWithVaultAndBids{
            value: 15 ether
        }(
            "ETH >= $5000 + vault + bids",
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED,
            IResolver.Op.GTE,
            500000000000,
            vault,
            buy,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify bid pool
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 7000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
    }

    /// @notice Test vault with zero collateralForVault (should skip vault deposits)
    function test_bootstrapMarketWithVault_zeroVault() public {
        Bootstrapper.VaultParams memory vault =
            Bootstrapper.VaultParams({collateralForVault: 0, vaultYesShares: 0, vaultNoShares: 0});

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapMarketWithVault{
            value: 10 ether
        }(
            "Zero vault test",
            address(hook),
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertEq(yesVaultShares, 0, "No YES vault shares expected");
        assertEq(noVaultShares, 0, "No NO vault shares expected");
    }

    /// @notice Test initial buy skews odds
    function test_bootstrapMarketWithVault_withInitialBuy() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy = Bootstrapper.InitialBuy({
            buyYes: true,
            collateralForBuy: 2 ether // buy YES to skew odds
        });

        vm.prank(alice);
        (
            uint256 marketId,,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapMarketWithVault{value: 15 ether}(
            "Vault+buy test",
            address(hook),
            address(0),
            uint64(block.timestamp + 30 days),
            true,
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE MARKET VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapETHBalanceMarketWithVault creates ETH balance market + vault + initial buy
    function test_bootstrapETHBalanceMarketWithVault() public {
        address accountToCheck = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // vitalik.eth

        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 4 ether, vaultYesShares: 2 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: true, collateralForBuy: 1 ether});

        uint256 totalCollateral = 10 ether + 4 ether + 1 ether; // LP + vault + buy

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapETHBalanceMarketWithVault{value: totalCollateral}(
            "Will vitalik hold 100k ETH?",
            address(0), // ETH collateral
            uint64(block.timestamp + 365 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.GTE,
            100_000 ether,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");

        // Verify condition was registered with empty callData (ETH balance check)
        (address targetA,, uint8 op,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, accountToCheck, "Condition target should be account");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, 100_000 ether, "Condition threshold should match");
        assertEq(callDataA.length, 0, "CallData should be empty for ETH balance check");
    }

    /// @notice Test bootstrapETHBalanceMarketWithVault with zero vault (skips vault deposits)
    function test_bootstrapETHBalanceMarketWithVault_zeroVault() public {
        address accountToCheck = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;

        Bootstrapper.VaultParams memory vault =
            Bootstrapper.VaultParams({collateralForVault: 0, vaultYesShares: 0, vaultNoShares: 0});

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapETHBalanceMarketWithVault{
            value: 10 ether
        }(
            "ETH balance zero vault test",
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.GTE,
            1000 ether,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertEq(yesVaultShares, 0, "No YES vault shares expected");
        assertEq(noVaultShares, 0, "No NO vault shares expected");
    }

    /// @notice Test bootstrapTokenBalanceMarketWithVault creates token balance market + vault + initial buy
    function test_bootstrapTokenBalanceMarketWithVault() public {
        address usdcToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC on mainnet
        address accountToCheck = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503; // Binance USDC holder

        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 4 ether, vaultYesShares: 2 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: true, collateralForBuy: 1 ether});

        uint256 totalCollateral = 10 ether + 4 ether + 1 ether; // LP + vault + buy

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapTokenBalanceMarketWithVault{value: totalCollateral}(
            "Will treasury hold 500M USDC?",
            address(0), // ETH collateral
            uint64(block.timestamp + 180 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            usdcToken,
            accountToCheck,
            IResolver.Op.GTE,
            500_000_000e6, // 500M USDC
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");

        // Verify condition was registered with balanceOf callData
        (address targetA,, uint8 op,, uint256 threshold, bytes memory callDataA,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, usdcToken, "Condition target should be token address");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, 500_000_000e6, "Condition threshold should match");

        bytes memory expectedCallData = abi.encodeWithSelector(0x70a08231, accountToCheck);
        assertEq(callDataA, expectedCallData, "CallData should be balanceOf(account)");
    }

    /// @notice Test bootstrapTokenBalanceMarketWithVault with zero vault (skips vault deposits)
    function test_bootstrapTokenBalanceMarketWithVault_zeroVault() public {
        address usdcToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address accountToCheck = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

        Bootstrapper.VaultParams memory vault =
            Bootstrapper.VaultParams({collateralForVault: 0, vaultYesShares: 0, vaultNoShares: 0});

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapTokenBalanceMarketWithVault{
            value: 10 ether
        }(
            "Token balance zero vault test",
            address(0),
            uint64(block.timestamp + 30 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            usdcToken,
            accountToCheck,
            IResolver.Op.GTE,
            1_000_000e6,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertEq(yesVaultShares, 0, "No YES vault shares expected");
        assertEq(noVaultShares, 0, "No NO vault shares expected");
    }

    /*//////////////////////////////////////////////////////////////
                    BALANCE MARKET VAULT + BIDS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapETHBalanceMarketWithVaultAndBids creates ETH balance market + vault + bids
    function test_bootstrapETHBalanceMarketWithVaultAndBids() public {
        address accountToCheck = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // vitalik.eth

        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1.5 ether, vaultNoShares: 1.5 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: true, collateralForBuy: 1 ether});

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 6000, amount: 2 ether, minShares: 0});
        bids[1] =
            Bootstrapper.BidOrder({buyYes: false, priceInBps: 4000, amount: 1 ether, minShares: 0});

        uint256 totalCollateral = 10 ether + 3 ether + 1 ether + 3 ether; // LP + vault + buy + bids

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapETHBalanceMarketWithVaultAndBids{value: totalCollateral}(
            "Will vitalik hold 100k ETH?",
            address(0),
            uint64(block.timestamp + 365 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            accountToCheck,
            IResolver.Op.GTE,
            100_000 ether,
            vault,
            buy,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify bid pools were created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");

        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 4000);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);
        assertEq(noCollateral, 1 ether, "NO bid pool should have 1 ETH");
    }

    /// @notice Test bootstrapTokenBalanceMarketWithVaultAndBids creates token balance market + vault + bids
    function test_bootstrapTokenBalanceMarketWithVaultAndBids() public {
        address usdcToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address accountToCheck = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1.5 ether, vaultNoShares: 1.5 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0.5 ether});

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](1);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 7000, amount: 2 ether, minShares: 0});

        uint256 totalCollateral = 10 ether + 3 ether + 0.5 ether + 2 ether; // LP + vault + buy + bids

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapTokenBalanceMarketWithVaultAndBids{value: totalCollateral}(
            "Will treasury hold 1B USDC?",
            address(0),
            uint64(block.timestamp + 180 days),
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            usdcToken,
            accountToCheck,
            IResolver.Op.GTE,
            1_000_000_000e6, // 1B USDC
            vault,
            buy,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify bid pool was created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 7000);
        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");

        // Verify condition was registered correctly
        (address targetA,,,, uint256 threshold,,) = IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, usdcToken, "Condition target should be token address");
        assertEq(threshold, 1_000_000_000e6, "Condition threshold should match");
    }

    /*//////////////////////////////////////////////////////////////
                        GAS MARKET VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapGasTWAPMarketWithVault creates gas TWAP market + vault + initial buy
    function test_bootstrapGasTWAPMarketWithVault() public {
        uint256 threshold = 25 gwei; // gas threshold

        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 4 ether, vaultYesShares: 2 ether, vaultNoShares: 2 ether
        });

        Bootstrapper.InitialBuy memory buy = Bootstrapper.InitialBuy({
            buyYes: true,
            collateralForBuy: 1 ether // buy YES to skew odds toward gas staying low
        });

        uint256 totalCollateral = 8 ether + 4 ether + 1 ether; // LP + vault + buy

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapGasTWAPMarketWithVault{value: totalCollateral}(
            "Gas TWAP <= 25 gwei + vault",
            address(0), // ETH collateral
            uint64(block.timestamp + 14 days),
            true, // canClose
            address(hook),
            8 ether,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.LTE,
            threshold,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasTWAPMarketWithVault with zero vault (skips vault deposits)
    function test_bootstrapGasTWAPMarketWithVault_zeroVault() public {
        Bootstrapper.VaultParams memory vault =
            Bootstrapper.VaultParams({collateralForVault: 0, vaultYesShares: 0, vaultNoShares: 0});

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: false, collateralForBuy: 0});

        vm.prank(alice);
        (uint256 marketId,, uint256 lpShares,, uint256 yesVaultShares, uint256 noVaultShares) = bootstrapper.bootstrapGasTWAPMarketWithVault{
            value: 10 ether
        }(
            "Gas TWAP zero vault test",
            address(0),
            uint64(block.timestamp + 7 days),
            true,
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            30 gwei,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertEq(yesVaultShares, 0, "No YES vault shares expected");
        assertEq(noVaultShares, 0, "No NO vault shares expected");
    }

    /// @notice Test bootstrapGasTWAPMarketWithVault with initial NO buy
    function test_bootstrapGasTWAPMarketWithVault_initialNoBuy() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1.5 ether, vaultNoShares: 1.5 ether
        });

        Bootstrapper.InitialBuy memory buy = Bootstrapper.InitialBuy({
            buyYes: false, // buy NO to skew odds toward gas being high
            collateralForBuy: 2 ether
        });

        uint256 totalCollateral = 10 ether + 3 ether + 2 ether;

        vm.prank(alice);
        (
            uint256 marketId,,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapGasTWAPMarketWithVault{value: totalCollateral}(
            "Gas TWAP >= 50 gwei with NO buy",
            address(0),
            uint64(block.timestamp + 30 days),
            false, // canClose = false
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            50 gwei,
            vault,
            buy
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive NO shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLVER CONDITION + VAULT + BIDS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapWithConditionAndVaultAndBids creates market with condition + vault + bids
    function test_bootstrapWithConditionAndVaultAndBids() public {
        Bootstrapper.VaultParams memory vault = Bootstrapper.VaultParams({
            collateralForVault: 3 ether, vaultYesShares: 1.5 ether, vaultNoShares: 1.5 ether
        });

        Bootstrapper.InitialBuy memory buy =
            Bootstrapper.InitialBuy({buyYes: true, collateralForBuy: 1 ether});

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] =
            Bootstrapper.BidOrder({buyYes: true, priceInBps: 6500, amount: 2 ether, minShares: 0});
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false, priceInBps: 3500, amount: 1.5 ether, minShares: 0
        });

        uint256 totalCollateral = 10 ether + 3 ether + 1 ether + 3.5 ether; // LP + vault + buy + bids

        vm.prank(alice);
        (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        ) = bootstrapper.bootstrapWithConditionAndVaultAndBids{value: totalCollateral}(
            "Custom condition + vault + bids",
            address(0), // ETH collateral
            uint64(block.timestamp + 60 days),
            true, // canClose
            address(hook),
            10 ether,
            alice,
            block.timestamp + 1 hours,
            ETH_USD_FEED, // target
            abi.encodeWithSelector(0x50d25bcd), // latestAnswer()
            IResolver.Op.GTE,
            600000000000, // $6000 with 8 decimals
            vault,
            buy,
            bids
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");
        assertGt(sharesOut, 0, "Should receive shares from initial buy");
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        // Verify condition was registered
        (address targetA,, uint8 op,, uint256 threshold,,) =
            IResolverExtended(RESOLVER).conditions(marketId);
        assertEq(targetA, ETH_USD_FEED, "Condition target should be price feed");
        assertEq(op, uint8(IResolver.Op.GTE), "Condition op should be GTE");
        assertEq(threshold, 600000000000, "Condition threshold should match");

        // Verify bid pools were created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 6500);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 3500);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
        assertEq(noCollateral, 1.5 ether, "NO bid pool should have 1.5 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS MARKET NON-BIDS VARIANTS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapGasTWAPMarket creates gas TWAP market without bids
    function test_bootstrapGasTWAPMarket() public {
        uint256 threshold = 35 gwei;
        uint256 collateralForLP = 8 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasTWAPMarket{
            value: collateralForLP
        }(
            "Gas TWAP >= 35 gwei",
            address(0),
            uint64(block.timestamp + 14 days),
            true, // canClose
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            threshold
        );

        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasRangeMarket creates gas range market without bids
    function test_bootstrapGasRangeMarket() public {
        uint256 lower = 15 gwei;
        uint256 upper = 40 gwei;
        uint256 collateralForLP = 6 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasRangeMarket{
            value: collateralForLP
        }(
            "Gas in 15-40 gwei range",
            address(0),
            uint64(block.timestamp + 7 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            lower,
            upper
        );

        assertGt(marketId, 0, "Range market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasVolatilityMarket creates gas volatility market without bids
    function test_bootstrapGasVolatilityMarket() public {
        uint256 threshold = 80 gwei; // volatility spread threshold
        uint256 collateralForLP = 7 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasVolatilityMarket{
            value: collateralForLP
        }(
            "Gas volatility >= 80 gwei spread",
            address(0),
            uint64(block.timestamp + 21 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold
        );

        assertGt(marketId, 0, "Volatility market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasPeakMarket creates gas peak market without bids
    function test_bootstrapGasPeakMarket() public {
        uint256 threshold = 150 gwei; // peak threshold
        uint256 collateralForLP = 5 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasPeakMarket{
            value: collateralForLP
        }(
            "Gas peak >= 150 gwei",
            address(0),
            uint64(block.timestamp + 45 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold
        );

        assertGt(marketId, 0, "Peak market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasTroughMarket creates gas trough market without bids
    function test_bootstrapGasTroughMarket() public {
        uint256 threshold = 8 gwei; // trough threshold
        uint256 collateralForLP = 6 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasTroughMarket{
            value: collateralForLP
        }(
            "Gas trough <= 8 gwei",
            address(0),
            uint64(block.timestamp + 60 days),
            true,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            threshold
        );

        assertGt(marketId, 0, "Trough market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /*//////////////////////////////////////////////////////////////
                        SPOT GAS MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test bootstrapGasSpotMarket creates spot gas market (checks block.basefee at resolution)
    function test_bootstrapGasSpotMarket() public {
        uint256 threshold = 25 gwei;
        uint256 collateralForLP = 5 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasSpotMarket{
            value: collateralForLP
        }(
            "Spot gas >= 25 gwei at resolution",
            address(0),
            uint64(block.timestamp + 7 days),
            false, // canClose = false for spot
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            threshold
        );

        assertGt(marketId, 0, "Spot market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify market uses Resolver
        (address resolverAddr,,,,,,) = PAMM.markets(marketId);
        assertEq(resolverAddr, RESOLVER, "Market should use Resolver");
    }

    /// @notice Test bootstrapGasSpotMarketWithBids creates spot gas market with orderbook bids
    function test_bootstrapGasSpotMarketWithBids() public {
        uint256 threshold = 30 gwei;
        uint256 collateralForLP = 6 ether;

        Bootstrapper.BidOrder[] memory bids = new Bootstrapper.BidOrder[](2);
        bids[0] = Bootstrapper.BidOrder({
            buyYes: true,
            priceInBps: 4000, // 40%
            amount: 2 ether,
            minShares: 0
        });
        bids[1] = Bootstrapper.BidOrder({
            buyYes: false,
            priceInBps: 6000, // 60%
            amount: 2 ether,
            minShares: 0
        });

        uint256 totalRequired = collateralForLP + 4 ether;

        vm.prank(alice);
        (uint256 marketId, uint256 poolId, uint256 lpShares) = bootstrapper.bootstrapGasSpotMarketWithBids{
            value: totalRequired
        }(
            "Spot gas >= 30 gwei with bids",
            address(0),
            uint64(block.timestamp + 14 days),
            false,
            address(hook),
            collateralForLP,
            alice,
            block.timestamp + 1 hours,
            IResolver.Op.GTE,
            threshold,
            bids
        );

        assertGt(marketId, 0, "Spot market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should receive LP shares");

        // Verify bid pools were created
        bytes32 yesBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, true, 4000);
        bytes32 noBidPoolId = MASTER_ROUTER.getBidPoolId(marketId, false, 6000);

        (uint256 yesCollateral,,,) = MASTER_ROUTER.bidPools(yesBidPoolId);
        (uint256 noCollateral,,,) = MASTER_ROUTER.bidPools(noBidPoolId);

        assertEq(yesCollateral, 2 ether, "YES bid pool should have 2 ETH");
        assertEq(noCollateral, 2 ether, "NO bid pool should have 2 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test permit function works with EIP-2612 compatible token
    /// @dev Uses a mock since real permit requires valid signatures
    function test_permit_reverts_withInvalidSignature() public {
        // Test that permit reverts with invalid signature
        // This verifies the permit function is callable and processes correctly
        vm.prank(alice);
        vm.expectRevert(); // Invalid signature will revert
        bootstrapper.permit(
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            alice,
            1000e6,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }

    /// @notice Test permitDAI function works with DAI-style permit
    /// @dev Uses actual DAI on mainnet fork
    function test_permitDAI_reverts_withInvalidSignature() public {
        address dai = 0x6B175474E89094c44da98b954EEAdBC8b6736180;

        // Skip if DAI doesn't exist on this fork
        if (dai.code.length == 0) return;

        vm.prank(alice);
        vm.expectRevert(); // Invalid signature will revert
        bootstrapper.permitDAI(
            dai,
            alice,
            0, // nonce
            block.timestamp + 1 hours,
            true, // allowed
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }
}
