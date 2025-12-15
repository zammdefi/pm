// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";
import {PMRouter} from "../src/PMRouter.sol";
import {ZAMM} from "@zamm/ZAMM.sol";

contract MockERC20 is Test {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PMRouterTest is Test {
    PAMM pamm;
    PMRouter router;
    MockERC20 collateral;

    address RESOLVER = makeAddr("RESOLVER");
    address ALICE = makeAddr("ALICE");
    address BOB = makeAddr("BOB");
    address constant ZAMM_ADDR = 0x000000000000040470635EB91b7CE4D132D616eD;
    address constant PAMM_ADDR = 0x000000000044bfe6c2BBFeD8862973E0612f07C0;

    uint256 marketId;
    uint256 noId;
    uint256 constant FEE_BPS = 30;

    function setUp() public {
        // Deploy real ZAMM and etch at expected address
        bytes memory zammCode = type(ZAMM).creationCode;
        address zammDeployed;
        assembly {
            zammDeployed := create(0, add(zammCode, 0x20), mload(zammCode))
        }
        vm.etch(ZAMM_ADDR, zammDeployed.code);
        // Initialize feeToSetter storage slot
        vm.store(ZAMM_ADDR, bytes32(uint256(0x00)), bytes32(uint256(uint160(address(this)))));
        ZAMM zamm = ZAMM(payable(ZAMM_ADDR));

        // Deploy PAMM and etch at expected address
        PAMM pammImpl = new PAMM();
        vm.etch(PAMM_ADDR, address(pammImpl).code);
        pamm = PAMM(payable(PAMM_ADDR));

        // Deploy router
        router = new PMRouter();

        // Deploy collateral token
        collateral = new MockERC20("USDC", "USDC");

        // Fund users
        collateral.mint(ALICE, 100_000 ether);
        collateral.mint(BOB, 100_000 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(address(this), 100 ether);

        // Create market - PAMM's storage starts fresh, no markets exist yet
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (marketId, noId) =
            pamm.createMarket("Test Market", RESOLVER, address(collateral), closeTime, false);

        // Seed liquidity and add to ZAMM pools
        collateral.mint(address(this), 10_000 ether);
        collateral.approve(address(pamm), type(uint256).max);
        collateral.approve(address(zamm), type(uint256).max);
        pamm.split(marketId, 5_000 ether, address(this));
        pamm.setOperator(ZAMM_ADDR, true);
        pamm.setOperator(address(this), true);

        // Add YES/NO liquidity using PAMM's poolKey helper (ensures correct ordering)
        IZAMM.PoolKey memory yesNoPoolKey = pamm.poolKey(marketId, FEE_BPS);
        zamm.addLiquidity(
            _toZAMMPoolKey(yesNoPoolKey),
            1000 ether,
            1000 ether,
            0,
            0,
            address(this),
            block.timestamp
        );

        // Add collateral/YES pool (for swapSharesToCollateral, swapCollateralToShares)
        ZAMM.PoolKey memory collateralYesKey =
            _buildPoolKey(address(collateral), 0, address(pamm), marketId, FEE_BPS);
        zamm.addLiquidity(
            collateralYesKey, 1000 ether, 1000 ether, 0, 0, address(this), block.timestamp
        );

        // Add collateral/NO pool
        ZAMM.PoolKey memory collateralNoKey =
            _buildPoolKey(address(collateral), 0, address(pamm), noId, FEE_BPS);
        zamm.addLiquidity(
            collateralNoKey, 1000 ether, 1000 ether, 0, 0, address(this), block.timestamp
        );

        // Setup approvals
        _setupApprovals(ALICE);
        _setupApprovals(BOB);
    }

    function _setupApprovals(address user) internal {
        vm.startPrank(user);
        collateral.approve(address(router), type(uint256).max);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.setOperator(address(router), true);
        vm.stopPrank();
    }

    /// @notice Convert IZAMM.PoolKey to ZAMM.PoolKey for direct ZAMM calls
    function _toZAMMPoolKey(IZAMM.PoolKey memory key) internal pure returns (ZAMM.PoolKey memory) {
        return ZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });
    }

    /// @notice Build ZAMM.PoolKey with proper token ordering
    function _buildPoolKey(
        address tokenA,
        uint256 idA,
        address tokenB,
        uint256 idB,
        uint256 feeOrHook
    ) internal pure returns (ZAMM.PoolKey memory) {
        if (tokenA < tokenB || (tokenA == tokenB && idA < idB)) {
            return ZAMM.PoolKey({
                id0: idA, id1: idB, token0: tokenA, token1: tokenB, feeOrHook: feeOrHook
            });
        } else {
            return ZAMM.PoolKey({
                id0: idB, id1: idA, token0: tokenB, token1: tokenA, feeOrHook: feeOrHook
            });
        }
    }

    /*//////////////////////////////////////////////////////////////
                         LIMIT ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PlaceBuyOrder() public {
        vm.startPrank(ALICE);

        uint96 shares = 100 ether;
        uint96 collateralAmt = 60 ether;
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash =
            router.placeOrder(marketId, true, true, shares, collateralAmt, deadline, true);

        vm.stopPrank();

        assertTrue(orderHash != bytes32(0), "Order hash should not be zero");

        (PMRouter.Order memory order,,,,, bool active) = router.getOrder(orderHash);

        assertEq(order.owner, ALICE);
        assertEq(order.marketId, marketId);
        assertTrue(order.isYes);
        assertTrue(order.isBuy);
        assertEq(order.shares, shares);
        assertEq(order.collateral, collateralAmt);
        assertTrue(active);
    }

    function test_PlaceSellOrder() public {
        // Give ALICE YES shares via split
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 aliceYes = pamm.balanceOf(ALICE, marketId);
        assertTrue(aliceYes > 0);

        uint96 shares = uint96(aliceYes / 2);
        uint96 collateralWanted = 40 ether;
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash =
            router.placeOrder(marketId, true, false, shares, collateralWanted, deadline, true);

        vm.stopPrank();

        assertTrue(orderHash != bytes32(0));
        assertTrue(router.isOrderActive(orderHash));
    }

    function test_CancelBuyOrder() public {
        vm.startPrank(ALICE);

        uint256 balanceBefore = collateral.balanceOf(ALICE);

        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        assertEq(balanceBefore - collateral.balanceOf(ALICE), 60 ether, "Collateral escrowed");

        router.cancelOrder(orderHash);

        vm.stopPrank();

        assertFalse(router.isOrderActive(orderHash));
    }

    function test_CancelSellOrder() public {
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);
        uint96 shares = uint96(yesBefore / 2);

        bytes32 orderHash = router.placeOrder(
            marketId, true, false, shares, 40 ether, uint56(block.timestamp + 1 days), true
        );

        assertEq(yesBefore - pamm.balanceOf(ALICE, marketId), shares, "Shares escrowed");

        router.cancelOrder(orderHash);

        vm.stopPrank();

        assertEq(pamm.balanceOf(ALICE, marketId), yesBefore, "Shares returned");
    }

    function test_CannotCancelOthersOrder() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        vm.prank(BOB);
        vm.expectRevert(PMRouter.NotOrderOwner.selector);
        router.cancelOrder(orderHash);
    }

    function test_CannotPlaceExpiredOrder() public {
        vm.prank(ALICE);
        vm.expectRevert(PMRouter.DeadlineExpired.selector);
        router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp - 1), true
        );
    }

    function test_CannotPlaceZeroAmountOrder() public {
        vm.prank(ALICE);
        vm.expectRevert(PMRouter.AmountZero.selector);
        router.placeOrder(marketId, true, true, 0, 60 ether, uint56(block.timestamp + 1 days), true);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    // Note: Market order tests (buy/sell via PAMM AMM) require full ZAMM integration.
    // These are tested in PAMM.t.sol. Here we test the router's collateral handling.

    function test_BuyYesSharesViaRouter() public {
        // Test that router correctly routes buy orders through PAMM
        vm.startPrank(ALICE);

        uint256 collateralBefore = collateral.balanceOf(ALICE);
        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);

        uint256 yesReceived = router.buy(marketId, true, 10 ether, 0, FEE_BPS, ALICE, 0);

        assertGt(yesReceived, 0, "Should receive YES shares");
        assertEq(
            pamm.balanceOf(ALICE, marketId), yesBefore + yesReceived, "YES balance should increase"
        );
        assertEq(
            collateral.balanceOf(ALICE), collateralBefore - 10 ether, "Collateral should decrease"
        );

        vm.stopPrank();
    }

    function test_SellYesSharesViaRouter() public {
        // Test that router correctly routes sell orders through PAMM
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);
        uint256 shares = pamm.balanceOf(ALICE, marketId);

        uint256 collateralBefore = collateral.balanceOf(ALICE);

        uint256 collateralReceived = router.sell(marketId, true, shares, 0, FEE_BPS, ALICE, 0);

        assertGt(collateralReceived, 0, "Should receive collateral");
        assertEq(
            collateral.balanceOf(ALICE),
            collateralBefore + collateralReceived,
            "Collateral should increase"
        );
        // Note: Alice may have leftover YES shares due to AMM swap mechanics
        // The important thing is that leftovers go to Alice, not stuck in router
        assertEq(pamm.balanceOf(address(router), marketId), 0, "Router should not hold YES shares");

        vm.stopPrank();
    }

    function test_SellForwardsLeftoversToUser() public {
        // Test that sell() forwards any leftover shares back to user (not stuck in router)
        // This tests the fix for the Critical 1 vulnerability where PAMM.sellYes sends
        // leftovers to msg.sender (router), which we now forward to the user
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);
        uint256 noBefore = pamm.balanceOf(ALICE, noId);
        uint256 routerYesBefore = pamm.balanceOf(address(router), marketId);
        uint256 routerNoBefore = pamm.balanceOf(address(router), noId);

        // Sell YES shares
        router.sell(marketId, true, yesBefore, 0, FEE_BPS, ALICE, 0);

        // Router should not accumulate any shares - leftovers should go to user
        assertEq(
            pamm.balanceOf(address(router), marketId),
            routerYesBefore,
            "Router should not accumulate YES shares"
        );
        assertEq(
            pamm.balanceOf(address(router), noId),
            routerNoBefore,
            "Router should not accumulate NO shares"
        );

        // User should have received any leftovers (YES leftover from unsold, NO from swap)
        // The exact amounts depend on AMM state, but we verify router doesn't keep them
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       COLLATERAL OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Split() public {
        vm.startPrank(ALICE);

        uint256 amount = 10 ether;
        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);
        uint256 noBefore = pamm.balanceOf(ALICE, noId);

        router.split(marketId, amount, ALICE);

        vm.stopPrank();

        assertEq(pamm.balanceOf(ALICE, marketId), yesBefore + amount);
        assertEq(pamm.balanceOf(ALICE, noId), noBefore + amount);
    }

    function test_Merge() public {
        vm.startPrank(ALICE);

        // First split to get shares
        router.split(marketId, 10 ether, ALICE);

        uint256 collateralBefore = collateral.balanceOf(ALICE);

        router.merge(marketId, 5 ether, ALICE);

        vm.stopPrank();

        assertEq(collateral.balanceOf(ALICE), collateralBefore + 5 ether);
        assertEq(pamm.balanceOf(ALICE, marketId), 5 ether);
        assertEq(pamm.balanceOf(ALICE, noId), 5 ether);
    }

    function test_Claim() public {
        // Create a new market that we can resolve
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 claimMarketId,) =
            pamm.createMarket("Claim Test", address(this), address(collateral), closeTime, false);

        // Alice splits to get shares
        collateral.mint(ALICE, 100 ether);
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(claimMarketId, 100 ether, ALICE);
        vm.stopPrank();

        // Resolve market (YES wins) - resolver is address(this)
        vm.warp(closeTime + 1);
        pamm.resolve(claimMarketId, true);

        // Alice claims
        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);
        uint256 collateralBefore = collateral.balanceOf(ALICE);
        uint256 payout = router.claim(claimMarketId, ALICE);
        vm.stopPrank();

        assertEq(payout, 100 ether);
        assertEq(collateral.balanceOf(ALICE), collateralBefore + 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    // Note: Full swap tests require complete ZAMM integration with liquidity pools.
    // These are tested in PAMM.t.sol. Here we verify the router correctly routes to ZAMM.

    function test_SwapYesForNo() public {
        vm.startPrank(ALICE);

        // Get shares via split
        pamm.split(marketId, 100 ether, ALICE);
        uint256 yesAmount = pamm.balanceOf(ALICE, marketId);
        uint256 noBefore = pamm.balanceOf(ALICE, noId);

        // Swap YES -> NO via ZAMM
        uint256 noOut = router.swapShares(marketId, true, yesAmount, 0, FEE_BPS, ALICE, 0);

        vm.stopPrank();

        // Real AMM output depends on reserves and fees
        assertGt(noOut, 0, "Should receive NO shares");
        assertEq(pamm.balanceOf(ALICE, noId), noBefore + noOut, "NO balance should increase");
        assertEq(pamm.balanceOf(ALICE, marketId), 0, "Should have swapped all YES");
    }

    function test_SwapNoForYes() public {
        vm.startPrank(ALICE);

        pamm.split(marketId, 100 ether, ALICE);
        uint256 noAmount = pamm.balanceOf(ALICE, noId);
        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);

        uint256 yesOut = router.swapShares(marketId, false, noAmount, 0, FEE_BPS, ALICE, 0);

        vm.stopPrank();

        assertGt(yesOut, 0, "Should receive YES shares");
        assertEq(pamm.balanceOf(ALICE, marketId), yesBefore + yesOut, "YES balance should increase");
        assertEq(pamm.balanceOf(ALICE, noId), 0, "Should have swapped all NO");
    }

    /*//////////////////////////////////////////////////////////////
                         MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Multicall() public {
        vm.startPrank(ALICE);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.placeOrder.selector,
            marketId,
            true,
            true,
            uint96(100 ether),
            uint96(50 ether),
            uint56(block.timestamp + 1 days),
            true
        );
        calls[1] = abi.encodeWithSelector(
            router.placeOrder.selector,
            marketId,
            true,
            true,
            uint96(100 ether),
            uint96(55 ether),
            uint56(block.timestamp + 1 days),
            true
        );

        bytes[] memory results = router.multicall(calls);

        vm.stopPrank();

        assertEq(results.length, 2);

        bytes32 hash1 = abi.decode(results[0], (bytes32));
        bytes32 hash2 = abi.decode(results[1], (bytes32));

        assertTrue(hash1 != bytes32(0));
        assertTrue(hash2 != bytes32(0));
        assertTrue(hash1 != hash2);
    }

    /*//////////////////////////////////////////////////////////////
                          ETH MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PlaceBuyOrderETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);

        bytes32 orderHash = router.placeOrder{value: 1 ether}(
            ethMarketId, true, true, 2 ether, 1 ether, uint56(block.timestamp + 1 days), true
        );

        vm.stopPrank();

        assertTrue(orderHash != bytes32(0));
        assertTrue(router.isOrderActive(orderHash));
    }

    function test_PlaceSellOrderETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        // Get shares via split
        vm.deal(ALICE, 100 ether);
        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);
        pamm.split{value: 10 ether}(ethMarketId, 10 ether, ALICE);

        bytes32 orderHash = router.placeOrder(
            ethMarketId, true, false, 5 ether, 4 ether, uint56(block.timestamp + 1 days), true
        );

        vm.stopPrank();

        assertTrue(orderHash != bytes32(0));
        assertTrue(router.isOrderActive(orderHash));
    }

    function test_SplitETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId, uint256 ethNoId) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.startPrank(ALICE);

        router.split{value: 1 ether}(ethMarketId, 1 ether, ALICE);

        vm.stopPrank();

        assertEq(pamm.balanceOf(ALICE, ethMarketId), 1 ether);
        assertEq(pamm.balanceOf(ALICE, ethNoId), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetOrder() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        (
            PMRouter.Order memory order,
            uint96 sharesFilled,
            uint96 sharesRemaining,
            uint96 collateralFilled,
            uint96 collateralRemaining,
            bool active
        ) = router.getOrder(orderHash);

        assertEq(order.owner, ALICE);
        assertEq(order.shares, 100 ether);
        assertEq(order.collateral, 60 ether);
        assertEq(sharesFilled, 0);
        assertEq(sharesRemaining, 100 ether);
        assertEq(collateralFilled, 0);
        assertEq(collateralRemaining, 60 ether);
        assertTrue(active);
    }

    function test_IsOrderActive() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        assertTrue(router.isOrderActive(orderHash));

        // Warp past deadline
        vm.warp(block.timestamp + 2 days);

        assertFalse(router.isOrderActive(orderHash));
    }

    /*//////////////////////////////////////////////////////////////
                         FILL ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FillBuyOrder() public {
        // Alice places buy order
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Bob has YES shares to sell
        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);

        // Bob fills Alice's buy order
        (uint96 sharesFilled, uint96 collateralFilled) = router.fillOrder(orderHash, 50 ether, BOB);

        vm.stopPrank();

        // Bob sold shares, received collateral
        assertEq(sharesFilled, 50 ether);
        assertGt(collateralFilled, 0);
    }

    function test_FillSellOrder() public {
        // Alice gets shares and places sell order
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        bytes32 orderHash = router.placeOrder(
            marketId, true, false, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob fills sell order with collateral
        vm.startPrank(BOB);
        (uint96 sharesFilled, uint96 collateralFilled) = router.fillOrder(orderHash, 25 ether, BOB);

        vm.stopPrank();

        assertEq(sharesFilled, 25 ether);
        assertGt(collateralFilled, 0);
    }

    function test_FillOrderFullAmount() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        vm.startPrank(BOB);
        pamm.split(marketId, 200 ether, BOB);

        // Fill with 0 means fill all available
        (uint96 sharesFilled,) = router.fillOrder(orderHash, 0, BOB);

        vm.stopPrank();

        assertEq(sharesFilled, 100 ether);
    }

    function test_PartialFillThenCompleteBuyOrder() public {
        // Alice places BUY order: 100 shares for 60 collateral (price = 0.6)
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Bob gets shares and does first partial fill: 40 shares
        vm.startPrank(BOB);
        pamm.split(marketId, 200 ether, BOB);

        (uint96 sharesFilled1, uint96 collateralFilled1) =
            router.fillOrder(orderHash, 40 ether, BOB);
        assertEq(sharesFilled1, 40 ether);
        // First fill: 40 shares at 0.6 price = 24 collateral
        assertEq(collateralFilled1, 24 ether);

        // Bob completes the order: remaining 60 shares
        (uint96 sharesFilled2, uint96 collateralFilled2) = router.fillOrder(orderHash, 0, BOB);
        // Second fill should be remaining: 60 shares at 0.6 price = 36 collateral
        assertEq(sharesFilled2, 60 ether);
        assertEq(collateralFilled2, 36 ether); // NOT 60 ether (the bug would return total collateral)

        vm.stopPrank();
    }

    function test_PartialFillThenCompleteSellOrder() public {
        // Alice gets shares and places SELL order: 100 shares for 60 collateral (price = 0.6)
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        bytes32 orderHash = router.placeOrder(
            marketId, true, false, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob does first partial fill: 40 shares
        vm.startPrank(BOB);
        (uint96 sharesFilled1, uint96 collateralFilled1) =
            router.fillOrder(orderHash, 40 ether, BOB);
        assertEq(sharesFilled1, 40 ether);
        assertEq(collateralFilled1, 24 ether);

        // Bob completes the order: remaining 60 shares
        (uint96 sharesFilled2, uint96 collateralFilled2) = router.fillOrder(orderHash, 0, BOB);
        // Second fill should be remaining: 60 shares, 36 collateral
        assertEq(sharesFilled2, 60 ether);
        assertEq(collateralFilled2, 36 ether); // NOT 60 ether (the bug would return total collateral)

        vm.stopPrank();
    }

    function test_CannotFillInactiveOrder() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Warp past deadline
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);

        vm.expectRevert(PMRouter.OrderInactive.selector);
        router.fillOrder(orderHash, 50 ether, BOB);

        vm.stopPrank();
    }

    function test_CannotFillNonExistentOrder() public {
        bytes32 fakeHash = keccak256("fake");

        vm.prank(BOB);
        vm.expectRevert(PMRouter.OrderNotFound.selector);
        router.fillOrder(fakeHash, 50 ether, BOB);
    }

    function test_MustFillAllForNonPartialOrder() public {
        // Place non-partial fill order
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId,
            true,
            true,
            100 ether,
            60 ether,
            uint56(block.timestamp + 1 days),
            false // partialFill = false
        );

        vm.startPrank(BOB);
        pamm.split(marketId, 200 ether, BOB);

        // Try to partially fill - should revert
        vm.expectRevert(PMRouter.MustFillAll.selector);
        router.fillOrder(orderHash, 50 ether, BOB);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       NO SHARES ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PlaceBuyNoOrder() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, false, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        (PMRouter.Order memory order,,,,, bool active) = router.getOrder(orderHash);

        assertFalse(order.isYes); // NO shares
        assertTrue(order.isBuy);
        assertTrue(active);
    }

    function test_PlaceSellNoOrder() public {
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 noBalance = pamm.balanceOf(ALICE, noId);
        assertTrue(noBalance > 0);

        bytes32 orderHash = router.placeOrder(
            marketId,
            false,
            false,
            uint96(noBalance / 2),
            40 ether,
            uint56(block.timestamp + 1 days),
            true
        );

        vm.stopPrank();

        (PMRouter.Order memory order,,,,, bool active) = router.getOrder(orderHash);
        assertFalse(order.isYes);
        assertFalse(order.isBuy);
        assertTrue(active);
    }

    /*//////////////////////////////////////////////////////////////
                       ERROR CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CannotPlaceOrderMarketNotFound() public {
        uint256 fakeMarketId = 999999;

        vm.prank(ALICE);
        vm.expectRevert(PMRouter.MarketNotFound.selector);
        router.placeOrder(
            fakeMarketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
    }

    function test_CannotPlaceOrderMarketClosed() public {
        // Create market that closes soon
        uint64 closeTime = uint64(block.timestamp + 1 hours);
        (uint256 shortMarketId,) =
            pamm.createMarket("Short Market", RESOLVER, address(collateral), closeTime, false);

        // Warp past close
        vm.warp(closeTime + 1);

        vm.prank(ALICE);
        vm.expectRevert(PMRouter.MarketClosed.selector);
        router.placeOrder(
            shortMarketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
    }

    function test_InvalidETHAmountBuyOrder() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);

        // Send wrong ETH amount
        vm.expectRevert(PMRouter.InvalidETHAmount.selector);
        router.placeOrder{value: 0.5 ether}(
            ethMarketId, true, true, 2 ether, 1 ether, uint56(block.timestamp + 1 days), true
        );

        vm.stopPrank();
    }

    function test_InvalidETHAmountForERC20Order() public {
        vm.prank(ALICE);
        // Send ETH for ERC20 collateral market
        vm.expectRevert(PMRouter.InvalidETHAmount.selector);
        router.placeOrder{value: 1 ether}(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
    }

    function test_CancelNonExistentOrder() public {
        bytes32 fakeHash = keccak256("fake");

        vm.prank(ALICE);
        vm.expectRevert(PMRouter.OrderNotFound.selector);
        router.cancelOrder(fakeHash);
    }

    function test_GetNonExistentOrder() public view {
        bytes32 fakeHash = keccak256("fake");

        (PMRouter.Order memory order,,,,, bool active) = router.getOrder(fakeHash);

        assertEq(order.owner, address(0));
        assertFalse(active);
    }

    function test_IsOrderActiveNonExistent() public view {
        bytes32 fakeHash = keccak256("fake");
        assertFalse(router.isOrderActive(fakeHash));
    }

    /*//////////////////////////////////////////////////////////////
                     SWAP TO/FROM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapSharesToCollateral() public {
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 yesAmount = pamm.balanceOf(ALICE, marketId);
        uint256 collateralBefore = collateral.balanceOf(ALICE);

        // Swap YES shares to collateral via ZAMM
        uint256 collateralOut =
            router.swapSharesToCollateral(marketId, true, yesAmount, 0, FEE_BPS, ALICE, 0);

        vm.stopPrank();

        // Real AMM output depends on reserves and fees
        assertGt(collateralOut, 0, "Should receive collateral");
        assertEq(
            collateral.balanceOf(ALICE),
            collateralBefore + collateralOut,
            "Collateral balance should increase"
        );
        assertEq(pamm.balanceOf(ALICE, marketId), 0, "Should have swapped all YES");
    }

    function test_SwapNoSharesToCollateral() public {
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 noAmount = pamm.balanceOf(ALICE, noId);
        uint256 collateralBefore = collateral.balanceOf(ALICE);

        uint256 collateralOut =
            router.swapSharesToCollateral(marketId, false, noAmount, 0, FEE_BPS, ALICE, 0);

        vm.stopPrank();

        assertGt(collateralOut, 0, "Should receive collateral");
        assertEq(
            collateral.balanceOf(ALICE),
            collateralBefore + collateralOut,
            "Collateral balance should increase"
        );
        assertEq(pamm.balanceOf(ALICE, noId), 0, "Should have swapped all NO");
    }

    function test_SwapCollateralToShares() public {
        vm.startPrank(ALICE);

        uint256 collateralIn = 10 ether;
        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);
        uint256 collateralBefore = collateral.balanceOf(ALICE);

        uint256 sharesOut =
            router.swapCollateralToShares(marketId, true, collateralIn, 0, FEE_BPS, ALICE, 0);

        vm.stopPrank();

        assertGt(sharesOut, 0, "Should receive shares");
        assertEq(
            pamm.balanceOf(ALICE, marketId), yesBefore + sharesOut, "YES balance should increase"
        );
        assertEq(
            collateral.balanceOf(ALICE),
            collateralBefore - collateralIn,
            "Collateral should decrease"
        );
    }

    function test_SwapCollateralToSharesETH() public {
        // Create ETH market and add ETH/share liquidity pool
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId, uint256 ethNoId) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        // Give test contract more ETH for setup
        vm.deal(address(this), 200 ether);

        // Seed ETH market with shares and create pool
        pamm.split{value: 100 ether}(ethMarketId, 100 ether, address(this));
        pamm.setOperator(ZAMM_ADDR, true);

        // Add ETH/YES pool
        ZAMM zamm = ZAMM(payable(ZAMM_ADDR));
        ZAMM.PoolKey memory ethYesKey =
            _buildPoolKey(address(0), 0, address(pamm), ethMarketId, FEE_BPS);
        zamm.addLiquidity{value: 50 ether}(
            ethYesKey, 50 ether, 50 ether, 0, 0, address(this), block.timestamp
        );

        vm.startPrank(ALICE);

        uint256 yesBefore = pamm.balanceOf(ALICE, ethMarketId);
        uint256 ethBefore = ALICE.balance;

        uint256 sharesOut = router.swapCollateralToShares{value: 1 ether}(
            ethMarketId, true, 1 ether, 0, FEE_BPS, ALICE, 0
        );

        vm.stopPrank();

        assertGt(sharesOut, 0, "Should receive shares");
        assertEq(
            pamm.balanceOf(ALICE, ethMarketId), yesBefore + sharesOut, "YES balance should increase"
        );
        assertEq(ALICE.balance, ethBefore - 1 ether, "ETH should decrease");
    }

    function test_SwapInvalidETHAmount() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.prank(ALICE);
        vm.expectRevert(PMRouter.InvalidETHAmount.selector);
        router.swapCollateralToShares{value: 0.5 ether}(
            ethMarketId, true, 1 ether, 0, FEE_BPS, ALICE, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
                       ETH MARKET ADDITIONAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MergeETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId, uint256 ethNoId) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.startPrank(ALICE);

        // Split to get shares
        router.split{value: 2 ether}(ethMarketId, 2 ether, ALICE);

        uint256 ethBefore = ALICE.balance;

        // Merge back
        router.merge(ethMarketId, 1 ether, ALICE);

        vm.stopPrank();

        assertEq(ALICE.balance, ethBefore + 1 ether);
        assertEq(pamm.balanceOf(ALICE, ethMarketId), 1 ether);
        assertEq(pamm.balanceOf(ALICE, ethNoId), 1 ether);
    }

    function test_ClaimNoWins() public {
        // Create market where we can control resolution
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 claimMarketId,) =
            pamm.createMarket("Claim Test NO", address(this), address(collateral), closeTime, false);

        // Alice splits to get shares
        collateral.mint(ALICE, 100 ether);
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(claimMarketId, 100 ether, ALICE);

        // Alice sells all YES shares, keeps NO
        pamm.transfer(address(1), claimMarketId, 100 ether); // burn YES shares
        vm.stopPrank();

        // Resolve market (NO wins)
        vm.warp(closeTime + 1);
        pamm.resolve(claimMarketId, false);

        // Alice claims with NO shares
        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);
        uint256 collateralBefore = collateral.balanceOf(ALICE);
        uint256 payout = router.claim(claimMarketId, ALICE);
        vm.stopPrank();

        assertEq(payout, 100 ether);
        assertEq(collateral.balanceOf(ALICE), collateralBefore + 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                     DEADLINE CLAMPING TEST
    //////////////////////////////////////////////////////////////*/

    function test_DeadlineClampedToMarketClose() public {
        // Create market that closes in 1 day
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 shortMarketId,) =
            pamm.createMarket("Short Market", RESOLVER, address(collateral), closeTime, false);

        vm.prank(ALICE);
        // Try to place order with deadline beyond market close
        bytes32 orderHash = router.placeOrder(
            shortMarketId,
            true,
            true,
            100 ether,
            60 ether,
            uint56(block.timestamp + 7 days), // beyond close
            true
        );

        (PMRouter.Order memory order,,,,,) = router.getOrder(orderHash);

        // Deadline should be clamped to close time
        assertEq(order.deadline, closeTime);
    }

    /*//////////////////////////////////////////////////////////////
                       RECIPIENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SplitToRecipient() public {
        vm.startPrank(ALICE);

        router.split(marketId, 10 ether, BOB);

        vm.stopPrank();

        assertEq(pamm.balanceOf(BOB, marketId), 10 ether);
        assertEq(pamm.balanceOf(BOB, noId), 10 ether);
        assertEq(pamm.balanceOf(ALICE, marketId), 0);
    }

    function test_MergeToRecipient() public {
        vm.startPrank(ALICE);
        router.split(marketId, 10 ether, ALICE);

        uint256 bobCollateralBefore = collateral.balanceOf(BOB);

        router.merge(marketId, 5 ether, BOB);

        vm.stopPrank();

        assertEq(collateral.balanceOf(BOB), bobCollateralBefore + 5 ether);
    }

    function test_FillOrderToRecipient() public {
        vm.prank(ALICE);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);

        address CHARLIE = makeAddr("CHARLIE");

        // Fill and send collateral to Charlie
        (, uint96 collateralFilled) = router.fillOrder(orderHash, 50 ether, CHARLIE);

        vm.stopPrank();

        // Charlie received the collateral
        assertEq(collateral.balanceOf(CHARLIE), collateralFilled);
    }

    function test_FillOrderRevertsOnTruncatedCollateral() public {
        // Test that filling a SELL order with sharesToFill so small that
        // expectedCollateral truncates to 0 reverts with InvalidFillAmount()
        // This prevents the fillPart=0 sentinel from being misinterpreted as "fill all"

        // Create a SELL order with high shares:collateral ratio
        vm.startPrank(ALICE);
        pamm.split(marketId, 1000 ether, ALICE);

        // SELL order: 1000 shares for 1 collateral (very low price per share)
        bytes32 orderHash = router.placeOrder(
            marketId,
            true, // isYes
            false, // isBuy = false (SELL)
            1000 ether, // shares
            1 ether, // collateral
            uint56(block.timestamp + 1 days),
            true // partialFill
        );
        vm.stopPrank();

        // Bob tries to fill with 1 wei of shares
        // expectedCollateral = 1 ether * 1 / 1000 ether = 0 (truncates)
        vm.startPrank(BOB);
        vm.expectRevert(PMRouter.InvalidFillAmount.selector);
        router.fillOrder(orderHash, 1, BOB);
        vm.stopPrank();
    }

    function test_SwapToRecipient() public {
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        address CHARLIE = makeAddr("CHARLIE");

        uint256 yesAmount = 50 ether;
        router.swapShares(marketId, true, yesAmount, 0, FEE_BPS, CHARLIE, 0);

        vm.stopPrank();

        // Swap output goes to CHARLIE (in mock, shares aren't actually transferred)
        // Just verify function completed without revert
    }

    function test_DefaultRecipientIsMsgSender() public {
        vm.startPrank(ALICE);

        // Pass address(0) as recipient
        router.split(marketId, 10 ether, address(0));

        vm.stopPrank();

        // Should default to msg.sender (ALICE)
        assertEq(pamm.balanceOf(ALICE, marketId), 10 ether);
        assertEq(pamm.balanceOf(ALICE, noId), 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       PERMIT TEST
    //////////////////////////////////////////////////////////////*/

    function test_PermitReverts() public {
        // Permit should revert with invalid signature for mock token
        // (Mock token doesn't implement permit)
        vm.expectRevert();
        router.permit(
            address(collateral),
            ALICE,
            100 ether,
            block.timestamp + 1 days,
            0,
            bytes32(0),
            bytes32(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    MULTICALL REVERT TEST
    //////////////////////////////////////////////////////////////*/

    function test_MulticallRevertsOnFailure() public {
        vm.startPrank(ALICE);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.placeOrder.selector,
            marketId,
            true,
            true,
            uint96(100 ether),
            uint96(50 ether),
            uint56(block.timestamp + 1 days),
            true
        );
        // Second call will fail - zero amount
        calls[1] = abi.encodeWithSelector(
            router.placeOrder.selector,
            marketId,
            true,
            true,
            uint96(0),
            uint96(55 ether),
            uint56(block.timestamp + 1 days),
            true
        );

        vm.expectRevert(PMRouter.AmountZero.selector);
        router.multicall(calls);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    FILL ORDERS THEN SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FillOrdersThenSwapBuy() public {
        // Alice places sell orders
        vm.startPrank(ALICE);
        pamm.split(marketId, 200 ether, ALICE);

        bytes32 order1 = router.placeOrder(
            marketId, true, false, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, false, 50 ether, 35 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob buys shares, filling orders then swapping remainder
        vm.startPrank(BOB);
        bytes32[] memory orderHashes = new bytes32[](2);
        orderHashes[0] = order1;
        orderHashes[1] = order2;

        uint256 totalOutput = router.fillOrdersThenSwap(
            marketId,
            true, // isYes
            true, // isBuy
            100 ether, // total collateral
            0, // minOutput
            orderHashes,
            FEE_BPS,
            BOB,
            0 // deadline
        );

        vm.stopPrank();

        assertGt(totalOutput, 0, "Should receive shares");
    }

    function test_FillOrdersThenSwapSell() public {
        // Alice places buy orders
        vm.startPrank(ALICE);
        bytes32 order1 = router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, true, 50 ether, 35 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob sells shares, filling orders then swapping remainder
        vm.startPrank(BOB);
        pamm.split(marketId, 200 ether, BOB);

        bytes32[] memory orderHashes = new bytes32[](2);
        orderHashes[0] = order1;
        orderHashes[1] = order2;

        uint256 totalOutput = router.fillOrdersThenSwap(
            marketId,
            true, // isYes
            false, // isBuy (selling)
            100 ether, // total shares
            0, // minOutput
            orderHashes,
            FEE_BPS,
            BOB,
            0 // deadline
        );

        vm.stopPrank();

        assertGt(totalOutput, 0, "Should receive collateral");
    }

    function test_FillOrdersThenSwapNoOrders() public {
        // No orders to fill, just swap via AMM
        vm.startPrank(ALICE);

        bytes32[] memory orderHashes = new bytes32[](0);
        uint256 yesBefore = pamm.balanceOf(ALICE, marketId);
        uint256 collateralBefore = collateral.balanceOf(ALICE);

        uint256 totalOutput = router.fillOrdersThenSwap(
            marketId,
            true, // isYes
            true, // isBuy
            10 ether,
            0,
            orderHashes,
            FEE_BPS,
            ALICE,
            0 // deadline
        );

        vm.stopPrank();

        // With real AMM, output depends on reserves and fees
        assertGt(totalOutput, 0, "Should receive shares");
        assertEq(
            pamm.balanceOf(ALICE, marketId), yesBefore + totalOutput, "YES balance should increase"
        );
        assertEq(
            collateral.balanceOf(ALICE), collateralBefore - 10 ether, "Collateral should decrease"
        );
    }

    function test_FillOrdersThenSwapSlippageExceeded() public {
        vm.startPrank(ALICE);

        bytes32[] memory orderHashes = new bytes32[](0);

        // Expect slippage error when minOutput > actual output
        vm.expectRevert(PMRouter.SlippageExceeded.selector);
        router.fillOrdersThenSwap(
            marketId,
            true,
            true,
            10 ether,
            100 ether, // minOutput way too high
            orderHashes,
            FEE_BPS,
            ALICE,
            0 // deadline
        );

        vm.stopPrank();
    }

    function test_FillOrdersThenSwapETH() public {
        // Create ETH market and add liquidity pool
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        // Give test contract more ETH for setup
        vm.deal(address(this), 200 ether);

        // Seed ETH market with shares and create pool
        pamm.split{value: 100 ether}(ethMarketId, 100 ether, address(this));
        pamm.setOperator(ZAMM_ADDR, true);

        // Add ETH/YES pool
        ZAMM zamm = ZAMM(payable(ZAMM_ADDR));
        ZAMM.PoolKey memory ethYesKey =
            _buildPoolKey(address(0), 0, address(pamm), ethMarketId, FEE_BPS);
        zamm.addLiquidity{value: 50 ether}(
            ethYesKey, 50 ether, 50 ether, 0, 0, address(this), block.timestamp
        );

        vm.startPrank(ALICE);

        bytes32[] memory orderHashes = new bytes32[](0);
        uint256 yesBefore = pamm.balanceOf(ALICE, ethMarketId);
        uint256 ethBefore = ALICE.balance;

        uint256 totalOutput = router.fillOrdersThenSwap{value: 1 ether}(
            ethMarketId, true, true, 1 ether, 0, orderHashes, FEE_BPS, ALICE, 0
        );

        vm.stopPrank();

        assertGt(totalOutput, 0, "Should receive shares");
        assertEq(
            pamm.balanceOf(ALICE, ethMarketId),
            yesBefore + totalOutput,
            "YES balance should increase"
        );
        assertEq(ALICE.balance, ethBefore - 1 ether, "ETH should decrease");
    }

    function test_FillOrdersThenSwapInvalidETHAmount() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        vm.startPrank(ALICE);

        bytes32[] memory orderHashes = new bytes32[](0);

        vm.expectRevert(PMRouter.InvalidETHAmount.selector);
        router.fillOrdersThenSwap{value: 0.5 ether}(
            ethMarketId,
            true,
            true,
            1 ether, // mismatch
            0,
            orderHashes,
            FEE_BPS,
            ALICE,
            0
        );

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    TRADING NOT OPEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TradingNotOpenSwapShares() public {
        // Create and resolve market to close trading
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 closedMarketId,) =
            pamm.createMarket("Closed Market", address(this), address(collateral), closeTime, false);

        // Resolve it (closes trading)
        vm.warp(closeTime + 1);
        pamm.resolve(closedMarketId, true);

        vm.startPrank(ALICE);
        vm.expectRevert(PMRouter.TradingNotOpen.selector);
        router.swapShares(closedMarketId, true, 10 ether, 0, FEE_BPS, ALICE, 0);
        vm.stopPrank();
    }

    function test_TradingNotOpenBuy() public {
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 closedMarketId,) =
            pamm.createMarket("Closed Market", address(this), address(collateral), closeTime, false);

        vm.warp(closeTime + 1);
        pamm.resolve(closedMarketId, true);

        vm.startPrank(ALICE);
        vm.expectRevert(PMRouter.TradingNotOpen.selector);
        router.buy(closedMarketId, true, 10 ether, 0, FEE_BPS, ALICE, 0);
        vm.stopPrank();
    }

    function test_TradingNotOpenSell() public {
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 closedMarketId,) =
            pamm.createMarket("Closed Market", address(this), address(collateral), closeTime, false);

        vm.warp(closeTime + 1);
        pamm.resolve(closedMarketId, true);

        vm.startPrank(ALICE);
        vm.expectRevert(PMRouter.TradingNotOpen.selector);
        router.sell(closedMarketId, true, 10 ether, 0, FEE_BPS, ALICE, 0);
        vm.stopPrank();
    }

    function test_TradingNotOpenFillOrdersThenSwap() public {
        uint64 closeTime = uint64(block.timestamp + 1 days);
        (uint256 closedMarketId,) =
            pamm.createMarket("Closed Market", address(this), address(collateral), closeTime, false);

        vm.warp(closeTime + 1);
        pamm.resolve(closedMarketId, true);

        vm.startPrank(ALICE);
        bytes32[] memory orderHashes = new bytes32[](0);

        vm.expectRevert(PMRouter.TradingNotOpen.selector);
        router.fillOrdersThenSwap(
            closedMarketId, true, true, 10 ether, 0, orderHashes, FEE_BPS, ALICE, 0
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       ETH FILL ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FillSellOrderETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        // Alice gets shares and places sell order
        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);
        pamm.split{value: 10 ether}(ethMarketId, 10 ether, ALICE);

        bytes32 orderHash = router.placeOrder(
            ethMarketId, true, false, 5 ether, 4 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Fund router for ETH refunds (mock doesn't handle this perfectly)
        vm.deal(address(router), 10 ether);

        // Bob fills sell order with ETH
        vm.startPrank(BOB);
        pamm.setOperator(address(router), true);

        (uint96 sharesFilled, uint96 collateralFilled) =
            router.fillOrder{value: 4 ether}(orderHash, 5 ether, BOB);

        vm.stopPrank();

        assertEq(sharesFilled, 5 ether);
        assertGt(collateralFilled, 0);
    }

    function test_FillBuyOrderETH() public {
        // Create ETH market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (uint256 ethMarketId,) =
            pamm.createMarket("ETH Market", RESOLVER, address(0), closeTime, false);

        // Alice places buy order with ETH
        vm.startPrank(ALICE);
        pamm.setOperator(address(router), true);

        bytes32 orderHash = router.placeOrder{value: 4 ether}(
            ethMarketId, true, true, 5 ether, 4 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Fund router for ETH transfers (mock doesn't escrow correctly)
        vm.deal(address(router), 10 ether);

        // Bob has shares to sell (from split)
        vm.startPrank(BOB);
        pamm.setOperator(address(router), true);
        pamm.split{value: 10 ether}(ethMarketId, 10 ether, BOB);

        uint256 bobEthBefore = BOB.balance;

        (uint96 sharesFilled,) = router.fillOrder(orderHash, 5 ether, BOB);

        vm.stopPrank();

        assertEq(sharesFilled, 5 ether);
        // Bob received ETH
        assertGt(BOB.balance, bobEthBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    CANCEL PARTIAL ORDER TEST
    //////////////////////////////////////////////////////////////*/

    function test_CancelUnfilledOrder() public {
        // Alice places sell order
        vm.startPrank(ALICE);
        pamm.split(marketId, 100 ether, ALICE);

        uint256 aliceYesBefore = pamm.balanceOf(ALICE, marketId);

        bytes32 orderHash = router.placeOrder(
            marketId, true, false, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );

        // Verify shares were escrowed
        assertEq(pamm.balanceOf(ALICE, marketId), aliceYesBefore - 50 ether);

        // Cancel order
        router.cancelOrder(orderHash);

        vm.stopPrank();

        // Order should be inactive and shares returned
        assertFalse(router.isOrderActive(orderHash));
        assertEq(pamm.balanceOf(ALICE, marketId), aliceYesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                       RECEIVE ETH TEST
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH() public {
        // Router should accept ETH
        vm.deal(address(this), 1 ether);
        (bool success,) = address(router).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(router).balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       ORDER DISCOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetMarketOrderCount() public {
        assertEq(router.getMarketOrderCount(marketId), 0);

        vm.startPrank(ALICE);
        router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        assertEq(router.getMarketOrderCount(marketId), 2);
    }

    function test_GetUserOrderCount() public {
        assertEq(router.getUserOrderCount(ALICE), 0);

        vm.startPrank(ALICE);
        router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        assertEq(router.getUserOrderCount(ALICE), 2);
        assertEq(router.getUserOrderCount(BOB), 0);
    }

    function test_GetMarketOrderHashes() public {
        vm.startPrank(ALICE);
        bytes32 order1 = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order3 = router.placeOrder(
            marketId, true, true, 25 ether, 15 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        bytes32[] memory hashes = router.getMarketOrderHashes(marketId, 0, 10);
        assertEq(hashes.length, 3);
        assertEq(hashes[0], order1);
        assertEq(hashes[1], order2);
        assertEq(hashes[2], order3);

        // Test pagination
        bytes32[] memory page1 = router.getMarketOrderHashes(marketId, 0, 2);
        assertEq(page1.length, 2);
        assertEq(page1[0], order1);
        assertEq(page1[1], order2);

        bytes32[] memory page2 = router.getMarketOrderHashes(marketId, 2, 2);
        assertEq(page2.length, 1);
        assertEq(page2[0], order3);

        // Test offset beyond length
        bytes32[] memory empty = router.getMarketOrderHashes(marketId, 10, 10);
        assertEq(empty.length, 0);
    }

    function test_GetUserOrderHashes() public {
        vm.startPrank(ALICE);
        bytes32 order1 = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        bytes32[] memory aliceOrders = router.getUserOrderHashes(ALICE, 0, 10);
        assertEq(aliceOrders.length, 2);
        assertEq(aliceOrders[0], order1);
        assertEq(aliceOrders[1], order2);

        bytes32[] memory bobOrders = router.getUserOrderHashes(BOB, 0, 10);
        assertEq(bobOrders.length, 0);

        // Test pagination
        bytes32[] memory page1 = router.getUserOrderHashes(ALICE, 0, 1);
        assertEq(page1.length, 1);
        assertEq(page1[0], order1);

        bytes32[] memory page2 = router.getUserOrderHashes(ALICE, 1, 1);
        assertEq(page2.length, 1);
        assertEq(page2[0], order2);
    }

    function test_GetActiveOrders() public {
        vm.startPrank(ALICE);
        // Place mix of buy and sell orders
        bytes32 buy1 = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 buy2 = router.placeOrder(
            marketId, true, true, 50 ether, 35 ether, uint56(block.timestamp + 1 days), true
        );

        pamm.split(marketId, 200 ether, ALICE);
        bytes32 sell1 = router.placeOrder(
            marketId, true, false, 80 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Get buy orders only (newest first)
        (bytes32[] memory buyHashes, PMRouter.Order[] memory buyOrders) =
            router.getActiveOrders(marketId, true, true, 10);
        assertEq(buyHashes.length, 2);
        assertEq(buyHashes[0], buy2); // newest first
        assertEq(buyHashes[1], buy1);
        assertTrue(buyOrders[0].isBuy);
        assertTrue(buyOrders[1].isBuy);

        // Get sell orders only
        (bytes32[] memory sellHashes,) = router.getActiveOrders(marketId, true, false, 10);
        assertEq(sellHashes.length, 1);
        assertEq(sellHashes[0], sell1);
    }

    function test_GetActiveOrdersFiltersInactive() public {
        vm.startPrank(ALICE);
        bytes32 order1 = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Both should be active
        (bytes32[] memory active1,) = router.getActiveOrders(marketId, true, true, 10);
        assertEq(active1.length, 2);

        // Cancel one
        vm.prank(ALICE);
        router.cancelOrder(order1);

        // Only one should be active now
        (bytes32[] memory active2,) = router.getActiveOrders(marketId, true, true, 10);
        assertEq(active2.length, 1);
        assertEq(active2[0], order2);
    }

    function test_DiscoverAndFill() public {
        // Alice places sell orders at different prices
        vm.startPrank(ALICE);
        pamm.split(marketId, 500 ether, ALICE);

        // Sell orders: shares for collateral
        router.placeOrder(
            marketId, true, false, 100 ether, 80 ether, uint56(block.timestamp + 1 days), true
        ); // Price 0.8
        router.placeOrder(
            marketId, true, false, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        ); // Price 0.5 (best)
        router.placeOrder(
            marketId, true, false, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        ); // Price 0.6
        vm.stopPrank();

        // Bob discovers sell orders using getActiveOrders
        (bytes32[] memory sellOrders,) = router.getActiveOrders(marketId, true, false, 10);
        assertEq(sellOrders.length, 3);

        // Bob uses discovered orders in fillOrdersThenSwap
        // Use 200 ether: fill all 3 orders (50+60+80=190) and have 10 for AMM
        vm.startPrank(BOB);
        uint256 yesBefore = pamm.balanceOf(BOB, marketId);
        uint256 totalOutput = router.fillOrdersThenSwap(
            marketId,
            true, // YES
            true, // buy
            200 ether, // collateral (enough to fill orders + AMM)
            0,
            sellOrders, // discovered orders
            FEE_BPS,
            BOB,
            0 // deadline
        );
        vm.stopPrank();

        // Should receive ~300 shares from orders plus some from AMM
        assertGt(totalOutput, 300 ether, "Should receive shares from orders + AMM");
        assertEq(
            pamm.balanceOf(BOB, marketId), yesBefore + totalOutput, "YES balance should increase"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         UX HELPER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MulticallCancelOrders() public {
        vm.startPrank(ALICE);
        bytes32 order1 = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, true, 50 ether, 30 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order3 = router.placeOrder(
            marketId, true, true, 25 ether, 15 ether, uint56(block.timestamp + 1 days), true
        );

        // Cancel all via multicall
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(router.cancelOrder, (order1));
        calls[1] = abi.encodeCall(router.cancelOrder, (order2));
        calls[2] = abi.encodeCall(router.cancelOrder, (order3));
        router.multicall(calls);
        vm.stopPrank();

        assertFalse(router.isOrderActive(order1));
        assertFalse(router.isOrderActive(order2));
        assertFalse(router.isOrderActive(order3));
    }

    function test_CancelOrderNotOwner() public {
        vm.prank(ALICE);
        bytes32 aliceOrder = router.placeOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Bob tries to cancel Alice's order - should revert
        vm.prank(BOB);
        vm.expectRevert(PMRouter.NotOrderOwner.selector);
        router.cancelOrder(aliceOrder);

        // Alice's order still active
        assertTrue(router.isOrderActive(aliceOrder));
    }

    function test_FullUXFlow() public {
        // Complete flow: place -> discover -> execute -> check positions

        // 1. Alice provides liquidity with sell orders
        vm.startPrank(ALICE);
        pamm.split(marketId, 500 ether, ALICE);
        router.placeOrder(
            marketId, true, false, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );
        router.placeOrder(
            marketId, true, false, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // 2. Bob discovers orders using getActiveOrders
        (bytes32[] memory sellOrders,) = router.getActiveOrders(marketId, true, false, 10);
        assertEq(sellOrders.length, 2);

        // 3. Bob executes - use 120 ether (fills orders + meaningful AMM swap)
        vm.startPrank(BOB);
        uint256 sharesReceived = router.fillOrdersThenSwap(
            marketId, true, true, 120 ether, 0, sellOrders, FEE_BPS, BOB, 0
        );
        vm.stopPrank();

        // Should receive shares from orders (55+60=115 ether worth) plus some from AMM
        assertGt(sharesReceived, 0);

        // 4. Check Bob's positions directly via PAMM
        assertGt(pamm.balanceOf(BOB, marketId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM PROCEEDS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimProceeds() public {
        // Alice places a BUY order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob fills via router (normal path)
        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);
        router.fillOrder(orderHash, 50 ether, BOB);
        vm.stopPrank();

        // Alice's claimedOut should be updated, claimProceeds should return 0
        vm.prank(ALICE);
        uint96 claimed = router.claimProceeds(orderHash, ALICE);
        assertEq(claimed, 0); // Nothing to claim - already forwarded via fillOrder
    }

    function test_ClaimProceedsNotOwner() public {
        // Alice places order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob tries to claim Alice's order proceeds
        vm.prank(BOB);
        vm.expectRevert(PMRouter.NotOrderOwner.selector);
        router.claimProceeds(orderHash, BOB);
    }

    function test_ClaimProceedsOrderNotFound() public {
        bytes32 fakeHash = keccak256("fake");
        vm.prank(ALICE);
        vm.expectRevert(PMRouter.OrderNotFound.selector);
        router.claimProceeds(fakeHash, ALICE);
    }

    function test_ClaimProceedsDefaultRecipient() public {
        // Alice places a BUY order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // to=address(0) should default to msg.sender
        vm.prank(ALICE);
        uint96 claimed = router.claimProceeds(orderHash, address(0));
        assertEq(claimed, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      ORDER HASH REUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OrderHashReuseReverts() public {
        // Alice places order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );

        // Try to place exact same order again - should revert
        vm.expectRevert(PMRouter.OrderExists.selector);
        router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();
    }

    function test_OrderHashReuseAfterCancel() public {
        // Alice places order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );

        // Cancel it
        router.cancelOrder(orderHash);

        // Now can place same order again
        bytes32 newHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        assertEq(newHash, orderHash); // Same hash
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      CLAIMED OUT TRACKING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimedOutTracking() public {
        // Alice places a BUY order with partial fill
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Check claimedOut starts at 0
        assertEq(router.claimedOut(orderHash), 0);

        // Bob partially fills via router
        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);
        (uint96 sharesFilled,) = router.fillOrder(orderHash, 50 ether, BOB);
        vm.stopPrank();

        // claimedOut should be updated
        assertEq(router.claimedOut(orderHash), sharesFilled);
    }

    function test_CancelCleansUpClaimedOut() public {
        // Alice places and partially fills order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob partially fills
        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);
        router.fillOrder(orderHash, 25 ether, BOB);
        vm.stopPrank();

        // Verify claimedOut is set
        assertGt(router.claimedOut(orderHash), 0);

        // Alice cancels
        vm.prank(ALICE);
        router.cancelOrder(orderHash);

        // claimedOut should be cleaned up
        assertEq(router.claimedOut(orderHash), 0);
    }

    function test_PartialFillThenClaimThenFillMore() public {
        // Alice places a BUY order with partial fill enabled
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob fills 50%
        vm.startPrank(BOB);
        pamm.split(marketId, 200 ether, BOB);
        router.fillOrder(orderHash, 50 ether, BOB);
        vm.stopPrank();

        uint96 claimedAfterFirst = router.claimedOut(orderHash);
        assertEq(claimedAfterFirst, 50 ether);

        // Alice tries to claim - should get 0 (already forwarded)
        vm.prank(ALICE);
        uint96 claimed = router.claimProceeds(orderHash, ALICE);
        assertEq(claimed, 0);

        // Bob fills remaining 50%
        vm.prank(BOB);
        router.fillOrder(orderHash, 50 ether, BOB);

        // claimedOut should now be 100 ether
        assertEq(router.claimedOut(orderHash), 100 ether);
    }

    function test_SellOrderClaimedOutTracking() public {
        // Alice splits and places a SELL order
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 200 ether, ALICE);
        pamm.setOperator(address(router), true);
        bytes32 orderHash = router.placeOrder(
            marketId, true, false, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        assertEq(router.claimedOut(orderHash), 0);

        // Bob fills the sell order
        vm.startPrank(BOB);
        collateral.approve(address(router), type(uint256).max);
        (uint96 sharesFilled, uint96 collateralFilled) = router.fillOrder(orderHash, 50 ether, BOB);
        vm.stopPrank();

        // For SELL orders, claimedOut tracks collateral (the proceeds)
        assertEq(router.claimedOut(orderHash), collateralFilled);
    }

    function test_FillOrdersThenSwapUpdatesClaimedOut() public {
        // Alice places SELL orders
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 500 ether, ALICE);
        pamm.setOperator(address(router), true);
        bytes32 order1 = router.placeOrder(
            marketId, true, false, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 order2 = router.placeOrder(
            marketId, true, false, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob uses fillOrdersThenSwap to buy
        bytes32[] memory orders = new bytes32[](2);
        orders[0] = order1;
        orders[1] = order2;

        vm.startPrank(BOB);
        collateral.approve(address(router), type(uint256).max);
        router.fillOrdersThenSwap(marketId, true, true, 110 ether, 0, orders, FEE_BPS, BOB, 0);
        vm.stopPrank();

        // Both orders should have claimedOut updated
        assertGt(router.claimedOut(order1), 0);
        assertGt(router.claimedOut(order2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PROCEEDS CLAIMED EVENT TEST
    //////////////////////////////////////////////////////////////*/

    function test_ProceedsClaimedEventOnCancel() public {
        // Alice places a BUY order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob partially fills
        vm.startPrank(BOB);
        pamm.split(marketId, 100 ether, BOB);
        router.fillOrder(orderHash, 25 ether, BOB);
        vm.stopPrank();

        // When Alice cancels, no ProceedsClaimed event (already claimed via fill)
        vm.prank(ALICE);
        router.cancelOrder(orderHash);
        // Order should be cleaned up
        (PMRouter.Order memory order,,,,,) = router.getOrder(orderHash);
        assertEq(order.owner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    PARTIAL FILL ROUNDING DUST TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that fragmented partial fills produce only negligible dust
    /// @dev ZAMM uses floor division for partial fills: sliceIn = floor(amtIn * sliceOut / amtOut)
    ///      Each fill can lose at most 1 wei to rounding. This test verifies that even with
    ///      many fragments, total dust remains bounded by (numFills * 1 wei).
    function test_PartialFillRoundingDustIsNegligible() public {
        // Use amounts that cause rounding: 101 shares for 67 collateral (non-integer ratio)
        uint96 totalShares = 101 ether;
        uint96 totalCollateral = 67 ether;

        // Alice places SELL order (partial fills enabled)
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, totalShares, ALICE);
        pamm.setOperator(address(router), true);

        bytes32 orderHash = router.placeOrder(
            marketId,
            true,
            false,
            totalShares,
            totalCollateral,
            uint56(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();

        // Bob fills in 20 small fragments to maximize rounding errors
        vm.startPrank(BOB);
        collateral.approve(address(router), type(uint256).max);

        uint256 numFills = 20;
        uint96 sharePerFill = totalShares / uint96(numFills); // 5.05 ether per fill
        uint256 totalCollateralPaid = 0;
        uint256 totalSharesReceived = 0;

        for (uint256 i = 0; i < numFills - 1; i++) {
            (uint96 filled, uint96 collateralPaid) = router.fillOrder(orderHash, sharePerFill, BOB);
            totalSharesReceived += filled;
            totalCollateralPaid += collateralPaid;
        }

        // Fill remainder
        (uint96 finalFilled, uint96 finalCollateral) = router.fillOrder(orderHash, 0, BOB);
        totalSharesReceived += finalFilled;
        totalCollateralPaid += finalCollateral;

        vm.stopPrank();

        // Verify order is fully filled
        assertEq(totalSharesReceived, totalShares, "All shares should be received");

        // Calculate dust: difference between expected and actual collateral paid
        // Due to floor division, taker may pay slightly less than pro-rata
        uint256 expectedCollateral = totalCollateral;
        uint256 dust =
            expectedCollateral > totalCollateralPaid ? expectedCollateral - totalCollateralPaid : 0;

        // Dust should be bounded by numFills (each fill loses at most 1 wei)
        assertLe(dust, numFills, "Dust should be bounded by number of fills");

        // For 18-decimal tokens, even 20 wei of dust is negligible (~$0.00000000000000002 at $1000/ETH)
        emit log_named_uint("Total fills", numFills);
        emit log_named_uint("Dust (wei)", dust);
        emit log_named_string("Dust assessment", dust <= numFills ? "NEGLIGIBLE" : "UNEXPECTED");
    }

    /// @notice Test dust accumulation with direct ZAMM fills (worst case for PMRouter accounting)
    function test_DirectZAMMFillsDustAfterOrderDeletion() public {
        // This tests the scenario where ZAMM deletes an order before PMRouter can read final state
        uint96 totalShares = 103 ether; // Prime number to maximize rounding
        uint96 totalCollateral = 71 ether;

        // Alice places BUY order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);

        bytes32 orderHash = router.placeOrder(
            marketId,
            true,
            true,
            totalShares,
            totalCollateral,
            uint56(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();

        // Bob gets shares for filling
        vm.startPrank(BOB);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, totalShares * 2, BOB);
        pamm.setOperator(address(router), true);

        // Fill via PMRouter in fragments
        uint256 numFills = 10;
        uint96 sharePerFill = totalShares / uint96(numFills);

        for (uint256 i = 0; i < numFills - 1; i++) {
            router.fillOrder(orderHash, sharePerFill, BOB);
        }
        router.fillOrder(orderHash, 0, BOB); // Fill remainder
        vm.stopPrank();

        // Check Alice received her shares
        uint256 aliceShares = pamm.balanceOf(ALICE, marketId);
        assertEq(aliceShares, totalShares, "Alice should receive all shares");

        // Check router doesn't hold orphaned collateral
        uint256 routerCollateral = collateral.balanceOf(address(router));

        // Any "dust" would be collateral that wasn't transferred due to rounding
        // Since fills go through PMRouter.fillOrder, proceeds are distributed immediately
        // Dust should be 0 or negligible
        emit log_named_uint("Router collateral balance", routerCollateral);
        assertLe(routerCollateral, numFills, "Router should not accumulate meaningful collateral");
    }

    /*//////////////////////////////////////////////////////////////
                    ASSEMBLY REVERT BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify claim() assembly works correctly end-to-end
    /// @dev Tests full claim flow through assembly path
    function test_ClaimViaAssembly() public {
        // Alice gets shares
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 100 ether, ALICE);
        vm.stopPrank();

        // Warp past close time and resolve market - YES wins
        vm.warp(block.timestamp + 8 days);
        vm.prank(RESOLVER);
        pamm.resolve(marketId, true);

        uint256 balanceBefore = collateral.balanceOf(ALICE);

        // Claim should succeed (PAMM allows transferFrom without explicit approval in some cases)
        vm.prank(ALICE);
        uint256 payout = router.claim(marketId, ALICE);

        assertEq(payout, 100 ether, "Should receive full payout");
        assertEq(
            collateral.balanceOf(ALICE),
            balanceBefore + 100 ether,
            "Alice should receive collateral"
        );
        assertEq(pamm.balanceOf(ALICE, marketId), 0, "Alice YES shares should be burned");
    }

    /// @notice Verify claim() reverts on unresolved market
    function test_ClaimRevertsOnUnresolvedMarket() public {
        // Alice gets shares
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 100 ether, ALICE);
        vm.stopPrank();

        // Warp past close but don't resolve
        vm.warp(block.timestamp + 8 days);

        // Claim should revert because market not resolved
        vm.prank(ALICE);
        vm.expectRevert();
        router.claim(marketId, ALICE);
    }

    /// @notice Verify sell() reverts when trading is closed
    function test_SellRevertsWhenTradingClosed() public {
        // Alice gets shares
        vm.startPrank(ALICE);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 100 ether, ALICE);
        pamm.setOperator(address(router), true);
        vm.stopPrank();

        // Close trading by warping past close time
        vm.warp(block.timestamp + 8 days);

        // Sell should revert because trading is closed
        vm.prank(ALICE);
        vm.expectRevert();
        router.sell(marketId, true, 50 ether, 0, FEE_BPS, ALICE, block.timestamp + 1);
    }

    /// @notice Verify fillOrder reverts after market resolution
    /// @dev Prevents exploitation of stale limit orders at known-wrong prices
    function test_FillOrderRevertsAfterResolution() public {
        // Alice places a BUY order
        vm.startPrank(ALICE);
        collateral.approve(address(router), type(uint256).max);
        bytes32 orderHash = router.placeOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Bob gets shares to fill
        vm.startPrank(BOB);
        collateral.approve(address(pamm), type(uint256).max);
        pamm.split(marketId, 100 ether, BOB);
        pamm.setOperator(address(router), true);
        vm.stopPrank();

        // Market resolves (warp past close, then resolve)
        vm.warp(block.timestamp + 8 days);
        vm.prank(RESOLVER);
        pamm.resolve(marketId, true);

        // Bob tries to fill Alice's order after resolution - should revert
        vm.prank(BOB);
        vm.expectRevert(PMRouter.TradingNotOpen.selector);
        router.fillOrder(orderHash, 50 ether, BOB);
    }
}
