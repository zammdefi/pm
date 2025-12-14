// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";
import {Orderbook} from "../src/Orderbook.sol";

contract MockERC20OB is Test {
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

/// @notice Mock ZAMM for testing - simulates AMM and orderbook operations
contract MockZAMM {
    // Pool state
    struct Pool {
        uint112 reserve0;
        uint112 reserve1;
        uint256 supply;
    }

    // Order state
    struct Order {
        bool partialFill;
        uint56 deadline;
        uint96 inDone;
        uint96 outDone;
        // Additional fields for fill tracking
        address maker;
        address tokenIn;
        uint256 idIn;
        uint96 amtIn;
        address tokenOut;
        uint256 idOut;
        uint96 amtOut;
    }

    mapping(uint256 => Pool) public poolState;
    mapping(bytes32 => Order) public orderState;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    // Transient deposits
    mapping(address => mapping(uint256 => uint256)) public transientDeposits;

    uint256 private orderNonce;

    receive() external payable {}

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
        )
    {
        Pool storage p = poolState[poolId];
        return (p.reserve0, p.reserve1, 0, 0, 0, 0, p.supply);
    }

    function orders(bytes32 orderHash)
        external
        view
        returns (bool partialFill, uint56 deadline, uint96 inDone, uint96 outDone)
    {
        Order storage o = orderState[orderHash];
        return (o.partialFill, o.deadline, o.inDone, o.outDone);
    }

    function deposit(address token, uint256 id, uint256 amount) external payable {
        transientDeposits[token][id] += amount;
        // Pull tokens from sender
        if (token != address(0)) {
            PAMM(payable(token)).transferFrom(msg.sender, address(this), id, amount);
        }
    }

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount)
    {
        amount = transientDeposits[token][id];
        if (amount > 0) {
            transientDeposits[token][id] = 0;
            if (token != address(0)) {
                PAMM(payable(token)).transfer(to, id, amount);
            }
        }
    }

    function addLiquidity(
        IZAMM.PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256,
        address to,
        uint256
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        // Use deposited amounts
        amount0 = transientDeposits[poolKey.token0][poolKey.id0];
        amount1 = transientDeposits[poolKey.token1][poolKey.id1];
        if (amount0 > amount0Desired) amount0 = amount0Desired;
        if (amount1 > amount1Desired) amount1 = amount1Desired;

        // Clear transient deposits
        transientDeposits[poolKey.token0][poolKey.id0] -= amount0;
        transientDeposits[poolKey.token1][poolKey.id1] -= amount1;

        // Calculate pool ID
        uint256 poolId = uint256(
            keccak256(
                abi.encode(
                    poolKey.id0, poolKey.id1, poolKey.token0, poolKey.token1, poolKey.feeOrHook
                )
            )
        );

        Pool storage p = poolState[poolId];

        // Simple liquidity calculation
        if (p.supply == 0) {
            liquidity = sqrt(amount0 * amount1);
        } else {
            liquidity = min((amount0 * p.supply) / p.reserve0, (amount1 * p.supply) / p.reserve1);
        }

        p.reserve0 += uint112(amount0);
        p.reserve1 += uint112(amount1);
        p.supply += liquidity;

        // Mint LP tokens
        balanceOf[to][poolId] += liquidity;
    }

    function removeLiquidity(
        IZAMM.PoolKey calldata poolKey,
        uint256 liquidity,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amount0, uint256 amount1) {
        uint256 poolId = uint256(
            keccak256(
                abi.encode(
                    poolKey.id0, poolKey.id1, poolKey.token0, poolKey.token1, poolKey.feeOrHook
                )
            )
        );

        Pool storage p = poolState[poolId];

        amount0 = (liquidity * p.reserve0) / p.supply;
        amount1 = (liquidity * p.reserve1) / p.supply;

        p.reserve0 -= uint112(amount0);
        p.reserve1 -= uint112(amount1);
        p.supply -= liquidity;

        // Transfer tokens to recipient
        PAMM(payable(poolKey.token0)).transfer(to, poolKey.id0, amount0);
        PAMM(payable(poolKey.token1)).transfer(to, poolKey.id1, amount1);
    }

    function swapExactIn(
        IZAMM.PoolKey calldata poolKey,
        uint256 amountIn,
        uint256,
        bool zeroForOne,
        address to,
        uint256
    ) external returns (uint256 amountOut) {
        uint256 poolId = uint256(
            keccak256(
                abi.encode(
                    poolKey.id0, poolKey.id1, poolKey.token0, poolKey.token1, poolKey.feeOrHook
                )
            )
        );

        Pool storage p = poolState[poolId];

        // Use deposited amount
        (uint256 rIn, uint256 rOut) = zeroForOne
            ? (uint256(p.reserve0), uint256(p.reserve1))
            : (uint256(p.reserve1), uint256(p.reserve0));

        // Get amount from transient deposits
        (address tokenIn, uint256 idIn) =
            zeroForOne ? (poolKey.token0, poolKey.id0) : (poolKey.token1, poolKey.id1);
        (address tokenOut, uint256 idOut) =
            zeroForOne ? (poolKey.token1, poolKey.id1) : (poolKey.token0, poolKey.id0);

        uint256 deposited = transientDeposits[tokenIn][idIn];
        if (deposited < amountIn) amountIn = deposited;
        transientDeposits[tokenIn][idIn] -= amountIn;

        // AMM formula with fee
        uint256 feeBps = poolKey.feeOrHook <= 10000 ? poolKey.feeOrHook : 0;
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        amountOut = (amountInWithFee * rOut) / (rIn * 10000 + amountInWithFee);

        // Update reserves
        if (zeroForOne) {
            p.reserve0 += uint112(amountIn);
            p.reserve1 -= uint112(amountOut);
        } else {
            p.reserve1 += uint112(amountIn);
            p.reserve0 -= uint112(amountOut);
        }

        // Transfer output
        PAMM(payable(tokenOut)).transfer(to, idOut, amountOut);
    }

    function swapExactOut(
        IZAMM.PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256
    ) external returns (uint256 amountIn) {
        uint256 poolId = uint256(
            keccak256(
                abi.encode(
                    poolKey.id0, poolKey.id1, poolKey.token0, poolKey.token1, poolKey.feeOrHook
                )
            )
        );

        Pool storage p = poolState[poolId];

        (uint256 rIn, uint256 rOut) = zeroForOne
            ? (uint256(p.reserve0), uint256(p.reserve1))
            : (uint256(p.reserve1), uint256(p.reserve0));

        (address tokenIn, uint256 idIn) =
            zeroForOne ? (poolKey.token0, poolKey.id0) : (poolKey.token1, poolKey.id1);
        (address tokenOut, uint256 idOut) =
            zeroForOne ? (poolKey.token1, poolKey.id1) : (poolKey.token0, poolKey.id0);

        // AMM formula for exact out
        uint256 feeBps = poolKey.feeOrHook <= 10000 ? poolKey.feeOrHook : 0;
        amountIn = (rIn * amountOut * 10000) / ((rOut - amountOut) * (10000 - feeBps)) + 1;

        require(amountIn <= amountInMax, "EXCESSIVE_INPUT");

        // Consume from transient deposits
        transientDeposits[tokenIn][idIn] -= amountIn;

        // Update reserves
        if (zeroForOne) {
            p.reserve0 += uint112(amountIn);
            p.reserve1 -= uint112(amountOut);
        } else {
            p.reserve1 += uint112(amountIn);
            p.reserve0 -= uint112(amountOut);
        }

        // Transfer output
        PAMM(payable(tokenOut)).transfer(to, idOut, amountOut);
    }

    function makeOrder(
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill
    ) external payable returns (bytes32 orderHash) {
        orderHash = keccak256(abi.encodePacked(msg.sender, block.timestamp, orderNonce++));
        orderState[orderHash] = Order({
            partialFill: partialFill,
            deadline: deadline,
            inDone: 0,
            outDone: 0,
            maker: msg.sender,
            tokenIn: tokenIn,
            idIn: idIn,
            amtIn: amtIn,
            tokenOut: tokenOut,
            idOut: idOut,
            amtOut: amtOut
        });
    }

    function cancelOrder(address, uint256, uint96, address, uint256, uint96, uint56, bool)
        external {
        // Mock cancel - in real implementation would return escrowed funds
    }

    function fillOrder(
        address maker,
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill,
        uint96 amountToFill
    ) external payable returns (uint96 filled) {
        // Compute order hash to find the order
        bytes32 orderHash = _findOrderHash(
            maker, tokenIn, idIn, amtIn, tokenOut, idOut, amtOut, deadline, partialFill
        );
        Order storage order = orderState[orderHash];

        require(order.deadline != 0 && block.timestamp <= order.deadline, "Order inactive");

        // For simplicity in mock, just update fill amounts
        if (partialFill) {
            filled = amountToFill;
        } else {
            filled = amtOut; // Fill all
        }

        // Update fill tracking based on order direction
        // outDone tracks shares filled, inDone tracks collateral used
        uint96 collateralUsed = uint96(uint256(amtIn) * filled / amtOut);
        order.inDone += collateralUsed;
        order.outDone += filled;

        return filled;
    }

    function _findOrderHash(
        address maker,
        address tokenIn,
        uint256 idIn,
        uint96 amtIn,
        address tokenOut,
        uint256 idOut,
        uint96 amtOut,
        uint56 deadline,
        bool partialFill
    ) internal view returns (bytes32) {
        // In real ZAMM this would be deterministic, for mock we search
        // This is a simplified mock - in tests we track order hashes
        return bytes32(0);
    }

    function transferFrom(address from, address to, uint256 id, uint256 amount)
        external
        returns (bool)
    {
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        return true;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract OrderbookTest is Test {
    PAMM pm;
    Orderbook orderbook;
    MockERC20OB collateral;
    MockZAMM mockZamm;

    address RESOLVER = makeAddr("RESOLVER");
    address ALICE = makeAddr("ALICE");
    address BOB = makeAddr("BOB");
    address CHARLIE = makeAddr("CHARLIE");
    address constant ZAMM_ADDR = 0x000000000000040470635EB91b7CE4D132D616eD;

    uint256 marketId;
    uint256 noId;
    uint256 constant FEE_BPS = 30;

    function setUp() public {
        // Deploy MockZAMM and etch at expected address
        mockZamm = new MockZAMM();
        vm.etch(ZAMM_ADDR, address(mockZamm).code);

        // Deploy PAMM
        pm = new PAMM();

        // Deploy orderbook
        orderbook = new Orderbook(address(pm));

        // Deploy collateral token
        collateral = new MockERC20OB("USDC", "USDC");

        // Fund users
        collateral.mint(ALICE, 100_000 ether);
        collateral.mint(BOB, 100_000 ether);
        collateral.mint(CHARLIE, 100_000 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CHARLIE, 100 ether);

        // Create market
        uint64 closeTime = uint64(block.timestamp + 7 days);
        (marketId, noId) =
            pm.createMarket("Test Market", RESOLVER, address(collateral), closeTime, false);

        // Seed liquidity
        collateral.mint(address(this), 10_000 ether);
        collateral.approve(address(pm), type(uint256).max);
        pm.splitAndAddLiquidity(marketId, 10_000 ether, FEE_BPS, 0, 0, 0, address(this), 0);

        // Approvals for all users
        _setupUserApprovals(ALICE);
        _setupUserApprovals(BOB);
        _setupUserApprovals(CHARLIE);
    }

    function _setupUserApprovals(address user) internal {
        vm.startPrank(user);
        collateral.approve(address(orderbook), type(uint256).max);
        collateral.approve(address(pm), type(uint256).max);
        pm.setOperator(address(orderbook), true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         LIMIT ORDER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PlaceBuyOrder() public {
        vm.startPrank(ALICE);

        uint96 shares = 100 ether;
        uint96 collateralAmt = 60 ether; // price = 0.6
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId,
            true, // isYes
            true, // isBuy
            shares,
            collateralAmt,
            deadline,
            true // partialFill
        );

        vm.stopPrank();

        // Verify order was placed
        assertTrue(orderHash != bytes32(0), "Order hash should not be zero");

        // Check order details
        (
            Orderbook.LimitOrder memory order,
            uint96 sharesFilled,
            uint96 sharesRemaining,,,
            bool isActive
        ) = orderbook.getOrderDetails(orderHash);

        assertEq(order.owner, ALICE, "Owner should be ALICE");
        assertEq(order.marketId, marketId, "Market ID should match");
        assertTrue(order.isYes, "Should be YES order");
        assertTrue(order.isBuy, "Should be BUY order");
        assertEq(order.shares, shares, "Shares should match");
        assertEq(order.collateral, collateralAmt, "Collateral should match");
        assertEq(sharesFilled, 0, "No shares filled yet");
        assertEq(sharesRemaining, shares, "All shares remaining");
        assertTrue(isActive, "Order should be active");
    }

    function test_PlaceSellOrder() public {
        // First give ALICE some YES shares
        vm.startPrank(ALICE);
        collateral.approve(address(pm), type(uint256).max);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, ALICE, 0);

        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        assertTrue(aliceYes > 0, "ALICE should have YES shares");

        uint96 shares = uint96(aliceYes / 2);
        uint96 collateralWanted = 40 ether; // price = 0.8 per share roughly
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId,
            true, // isYes
            false, // isBuy = false means SELL
            shares,
            collateralWanted,
            deadline,
            true // partialFill
        );

        vm.stopPrank();

        // Verify order was placed
        assertTrue(orderHash != bytes32(0), "Order hash should not be zero");

        // Check order was tracked
        bytes32[] memory orders = orderbook.getMarketOrders(marketId);
        assertEq(orders.length, 1, "Should have 1 order");
        assertEq(orders[0], orderHash, "Order hash should match");
    }

    function test_CancelBuyOrder() public {
        vm.startPrank(ALICE);

        uint256 balanceBefore = collateral.balanceOf(ALICE);

        uint96 shares = 100 ether;
        uint96 collateralAmt = 60 ether;
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash =
            orderbook.placeLimitOrder(marketId, true, true, shares, collateralAmt, deadline, true);

        // Collateral should be escrowed
        uint256 balanceAfterPlace = collateral.balanceOf(ALICE);
        assertEq(balanceBefore - balanceAfterPlace, collateralAmt, "Collateral should be escrowed");

        // Cancel order
        orderbook.cancelLimitOrder(orderHash);

        vm.stopPrank();

        // Order should be inactive
        (,,,,, bool isActive) = orderbook.getOrderDetails(orderHash);
        assertFalse(isActive, "Order should be inactive after cancel");
    }

    function test_CancelSellOrder() public {
        // Give ALICE YES shares
        vm.startPrank(ALICE);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, ALICE, 0);

        uint256 yesBefore = pm.balanceOf(ALICE, marketId);
        uint96 shares = uint96(yesBefore / 2);
        uint96 collateralWanted = 40 ether;
        uint56 deadline = uint56(block.timestamp + 1 days);

        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId, true, false, shares, collateralWanted, deadline, true
        );

        // Shares should be escrowed (transferred to orderbook)
        uint256 yesAfterPlace = pm.balanceOf(ALICE, marketId);
        assertEq(yesBefore - yesAfterPlace, shares, "Shares should be escrowed");

        // Cancel order
        orderbook.cancelLimitOrder(orderHash);

        vm.stopPrank();

        // Shares should be returned
        uint256 yesAfterCancel = pm.balanceOf(ALICE, marketId);
        assertEq(yesAfterCancel, yesBefore, "Shares should be returned after cancel");
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BatchPlaceLimitOrders() public {
        vm.startPrank(ALICE);

        Orderbook.PlaceOrderParams[] memory params = new Orderbook.PlaceOrderParams[](3);
        params[0] = Orderbook.PlaceOrderParams({
            marketId: marketId,
            isYes: true,
            isBuy: true,
            shares: 100 ether,
            collateral: 50 ether,
            deadline: uint56(block.timestamp + 1 days),
            partialFill: true
        });
        params[1] = Orderbook.PlaceOrderParams({
            marketId: marketId,
            isYes: true,
            isBuy: true,
            shares: 100 ether,
            collateral: 55 ether,
            deadline: uint56(block.timestamp + 1 days),
            partialFill: true
        });
        params[2] = Orderbook.PlaceOrderParams({
            marketId: marketId,
            isYes: true,
            isBuy: true,
            shares: 100 ether,
            collateral: 60 ether,
            deadline: uint56(block.timestamp + 1 days),
            partialFill: true
        });

        bytes32[] memory orderHashes = orderbook.batchPlaceLimitOrders(params);

        vm.stopPrank();

        assertEq(orderHashes.length, 3, "Should have 3 order hashes");
        for (uint256 i; i < 3; ++i) {
            assertTrue(orderHashes[i] != bytes32(0), "Order hash should not be zero");
        }

        bytes32[] memory marketOrders = orderbook.getMarketOrders(marketId);
        assertEq(marketOrders.length, 3, "Market should have 3 orders");
    }

    function test_BatchCancelLimitOrders() public {
        vm.startPrank(ALICE);

        // Place 3 orders
        bytes32[] memory orderHashes = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            orderHashes[i] = orderbook.placeLimitOrder(
                marketId,
                true,
                true,
                100 ether,
                uint96(50 ether + i * 5 ether),
                uint56(block.timestamp + 1 days),
                true
            );
        }

        // Cancel all
        orderbook.batchCancelLimitOrders(orderHashes);

        vm.stopPrank();

        // All should be inactive
        for (uint256 i; i < 3; ++i) {
            (,,,,, bool isActive) = orderbook.getOrderDetails(orderHashes[i]);
            assertFalse(isActive, "Order should be inactive");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DISCOVERABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetUserOrders() public {
        // ALICE places orders
        vm.startPrank(ALICE);
        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash2 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // BOB places order
        vm.prank(BOB);
        bytes32 hash3 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Check user orders
        bytes32[] memory aliceOrders = orderbook.getUserOrders(ALICE);
        assertEq(aliceOrders.length, 2, "ALICE should have 2 orders");
        assertEq(aliceOrders[0], hash1);
        assertEq(aliceOrders[1], hash2);

        bytes32[] memory bobOrders = orderbook.getUserOrders(BOB);
        assertEq(bobOrders.length, 1, "BOB should have 1 order");
        assertEq(bobOrders[0], hash3);
    }

    function test_GetActiveMarketOrders() public {
        vm.startPrank(ALICE);

        // Place 3 orders
        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash2 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash3 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Cancel one
        orderbook.cancelLimitOrder(hash2);

        vm.stopPrank();

        // Get active orders
        bytes32[] memory activeOrders = orderbook.getActiveMarketOrders(marketId);
        assertEq(activeOrders.length, 2, "Should have 2 active orders");
    }

    function test_GetActiveUserOrders() public {
        vm.startPrank(ALICE);

        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash2 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );

        // Cancel one
        orderbook.cancelLimitOrder(hash1);

        vm.stopPrank();

        bytes32[] memory activeOrders = orderbook.getActiveUserOrders(ALICE);
        assertEq(activeOrders.length, 1, "ALICE should have 1 active order");
        assertEq(activeOrders[0], hash2);
    }

    function test_GetOrderbook() public {
        // Place a buy YES order (bid)
        vm.prank(ALICE);
        orderbook.placeLimitOrder(
            marketId,
            true,
            true, // YES buy = bid
            100 ether,
            50 ether, // price = 0.5
            uint56(block.timestamp + 1 days),
            true
        );

        // Give BOB YES shares and place sell order (ask)
        vm.startPrank(BOB);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);
        uint256 bobYes = pm.balanceOf(BOB, marketId);

        orderbook.placeLimitOrder(
            marketId,
            true,
            false, // YES sell = ask
            uint96(bobYes / 2),
            40 ether, // price = 0.8
            uint56(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();

        // Get orderbook
        (
            bytes32[] memory bidHashes,
            uint256[] memory bidPrices,
            uint256[] memory bidSizes,
            bytes32[] memory askHashes,
            uint256[] memory askPrices,
            uint256[] memory askSizes
        ) = orderbook.getOrderbook(marketId, 10);

        assertEq(bidHashes.length, 1, "Should have 1 bid");
        assertEq(askHashes.length, 1, "Should have 1 ask");

        // Bid price should be ~0.5e18
        assertApproxEqRel(bidPrices[0], 0.5e18, 0.01e18, "Bid price should be ~0.5");

        // Ask price should be ~0.8e18 (based on collateral/shares)
        assertTrue(askPrices[0] > 0, "Ask price should be positive");
    }

    function test_GetOrderbookSorted() public {
        // Place multiple orders at different prices
        vm.startPrank(ALICE);
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 40 ether, uint56(block.timestamp + 1 days), true
        );
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        vm.stopPrank();

        // Get sorted orderbook
        Orderbook.OrderbookState memory state = orderbook.getOrderbookSorted(marketId, 10);

        assertEq(state.bids.length, 3, "Should have 3 bids");

        // Verify descending order (highest price first)
        assertTrue(state.bids[0].price >= state.bids[1].price, "Bids should be sorted descending");
        assertTrue(state.bids[1].price >= state.bids[2].price, "Bids should be sorted descending");

        // Best bid should be 0.6
        assertApproxEqRel(state.bestBid, 0.6e18, 0.01e18, "Best bid should be 0.6");
    }

    function test_GetBestBidAsk() public {
        // Place bid
        vm.prank(ALICE);
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );

        // Place ask
        vm.startPrank(BOB);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);
        uint256 bobYes = pm.balanceOf(BOB, marketId);
        orderbook.placeLimitOrder(
            marketId,
            true,
            false,
            uint96(bobYes / 2),
            40 ether,
            uint56(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();

        (uint256 bestBid, uint256 bestAsk, bytes32 bestBidHash, bytes32 bestAskHash) =
            orderbook.getBestBidAsk(marketId);

        assertTrue(bestBid > 0, "Best bid should be positive");
        assertTrue(bestAsk > 0, "Best ask should be positive");
        assertTrue(bestBidHash != bytes32(0), "Best bid hash should exist");
        assertTrue(bestAskHash != bytes32(0), "Best ask hash should exist");
    }

    function test_QuoteOrder() public {
        vm.prank(ALICE);
        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        (uint256 pricePerShare, uint256 totalCollateral, uint96 sharesAvailable) =
            orderbook.quoteOrder(orderHash, 50 ether);

        // Price should be 0.6e18 (60/100)
        assertEq(pricePerShare, 0.6e18, "Price per share should be 0.6");

        // Total collateral for 50 shares at 0.6 = 30
        assertEq(totalCollateral, 30 ether, "Total collateral should be 30");

        // Shares available should be full 100
        assertEq(sharesAvailable, 100 ether, "Shares available should be 100");
    }

    function test_GetFillParams() public {
        vm.prank(ALICE);
        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        (
            address maker,
            address tokenIn,
            uint256 idIn,
            uint96 amtIn,
            address tokenOut,
            uint256 idOut,
            uint96 amtOut,
            uint56 deadline,
            bool partialFill
        ) = orderbook.getFillParams(orderHash);

        assertEq(maker, address(orderbook), "Maker should be orderbook");
        assertEq(tokenIn, address(collateral), "TokenIn should be collateral");
        assertEq(amtIn, 60 ether, "AmtIn should be 60");
        assertEq(tokenOut, address(pm), "TokenOut should be PAMM");
        assertEq(idOut, marketId, "IdOut should be marketId");
        assertEq(amtOut, 100 ether, "AmtOut should be 100");
        assertTrue(deadline > block.timestamp, "Deadline should be in future");
        assertTrue(partialFill, "PartialFill should be true");
    }

    /*//////////////////////////////////////////////////////////////
                          PRUNING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PruneMarketOrders() public {
        vm.startPrank(ALICE);

        // Place 3 orders
        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash2 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // Cancel 2 orders
        orderbook.cancelLimitOrder(hash1);
        orderbook.cancelLimitOrder(hash2);

        vm.stopPrank();

        // Before pruning
        bytes32[] memory ordersBefore = orderbook.getMarketOrders(marketId);
        assertEq(ordersBefore.length, 3, "Should have 3 orders before prune");

        // Prune
        uint256 pruned = orderbook.pruneMarketOrders(marketId, 10);
        assertEq(pruned, 2, "Should have pruned 2 orders");

        // After pruning
        bytes32[] memory ordersAfter = orderbook.getMarketOrders(marketId);
        assertEq(ordersAfter.length, 1, "Should have 1 order after prune");
    }

    function test_PruneUserOrders() public {
        vm.startPrank(ALICE);

        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );

        orderbook.cancelLimitOrder(hash1);

        vm.stopPrank();

        uint256 pruned = orderbook.pruneUserOrders(ALICE, 10);
        assertEq(pruned, 1, "Should have pruned 1 order");

        bytes32[] memory userOrders = orderbook.getUserOrders(ALICE);
        assertEq(userOrders.length, 1, "Should have 1 order after prune");
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OnlyOwnerCanCancel() public {
        vm.prank(ALICE);
        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );

        // BOB tries to cancel ALICE's order
        vm.prank(BOB);
        vm.expectRevert(Orderbook.NotOrderOwner.selector);
        orderbook.cancelLimitOrder(orderHash);
    }

    function test_CannotPlaceZeroOrder() public {
        vm.startPrank(ALICE);

        vm.expectRevert(Orderbook.AmountZero.selector);
        orderbook.placeLimitOrder(
            marketId,
            true,
            true,
            0, // zero shares
            60 ether,
            uint56(block.timestamp + 1 days),
            true
        );

        vm.expectRevert(Orderbook.AmountZero.selector);
        orderbook.placeLimitOrder(
            marketId,
            true,
            true,
            100 ether,
            0, // zero collateral
            uint56(block.timestamp + 1 days),
            true
        );

        vm.stopPrank();
    }

    function test_CannotPlaceExpiredOrder() public {
        vm.prank(ALICE);

        vm.expectRevert(Orderbook.DeadlineExpired.selector);
        orderbook.placeLimitOrder(
            marketId,
            true,
            true,
            100 ether,
            60 ether,
            uint56(block.timestamp - 1), // past deadline
            true
        );
    }

    function test_OrderDeadlineClampedToMarketClose() public {
        (,,,, uint64 close,,) = pm.markets(marketId);

        vm.prank(ALICE);
        bytes32 orderHash = orderbook.placeLimitOrder(
            marketId,
            true,
            true,
            100 ether,
            60 ether,
            uint56(close + 1 days), // beyond market close
            true
        );

        (Orderbook.LimitOrder memory order,,,,,) = orderbook.getOrderDetails(orderHash);

        // Deadline should be clamped to market close
        assertEq(order.deadline, close, "Deadline should be clamped to market close");
    }

    function test_MultipleOrdersTracking() public {
        vm.startPrank(ALICE);

        // Place multiple orders
        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash2 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 60 ether, uint56(block.timestamp + 1 days), true
        );
        bytes32 hash3 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 70 ether, uint56(block.timestamp + 1 days), true
        );

        vm.stopPrank();

        bytes32[] memory orders = orderbook.getMarketOrders(marketId);
        assertEq(orders.length, 3, "Should have 3 orders");
        assertEq(orders[0], hash1);
        assertEq(orders[1], hash2);
        assertEq(orders[2], hash3);
    }

    function test_ActiveOrderCount() public {
        assertEq(orderbook.activeOrderCount(marketId), 0, "Should start with 0 active orders");

        vm.startPrank(ALICE);

        bytes32 hash1 = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );
        assertEq(orderbook.activeOrderCount(marketId), 1, "Should have 1 active order");

        orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true
        );
        assertEq(orderbook.activeOrderCount(marketId), 2, "Should have 2 active orders");

        orderbook.cancelLimitOrder(hash1);
        assertEq(orderbook.activeOrderCount(marketId), 1, "Should have 1 active order after cancel");

        vm.stopPrank();
    }

    function test_IsOrderActive() public {
        vm.startPrank(ALICE);

        bytes32 hash = orderbook.placeLimitOrder(
            marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true
        );

        assertTrue(orderbook.isOrderActive(hash), "Order should be active");

        orderbook.cancelLimitOrder(hash);

        assertFalse(orderbook.isOrderActive(hash), "Order should be inactive after cancel");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Multicall() public {
        vm.startPrank(ALICE);

        // Prepare multiple calls
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            orderbook.placeLimitOrder,
            (marketId, true, true, 100 ether, 50 ether, uint56(block.timestamp + 1 days), true)
        );
        calls[1] = abi.encodeCall(
            orderbook.placeLimitOrder,
            (marketId, true, true, 100 ether, 55 ether, uint56(block.timestamp + 1 days), true)
        );

        bytes[] memory results = orderbook.multicall(calls);

        vm.stopPrank();

        assertEq(results.length, 2, "Should have 2 results");

        bytes32 hash1 = abi.decode(results[0], (bytes32));
        bytes32 hash2 = abi.decode(results[1], (bytes32));

        assertTrue(hash1 != bytes32(0), "First order hash should not be zero");
        assertTrue(hash2 != bytes32(0), "Second order hash should not be zero");
        assertTrue(hash1 != hash2, "Order hashes should be different");
    }
}
