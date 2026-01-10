// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";
import {Resolver} from "../src/Resolver.sol";

/// @notice Interface for Uniswap V4 PoolManager
interface IUniswapV4 {
    function protocolFeeController() external view returns (address);
}

/// @title UniV4FeeSwitch Fork Tests
/// @notice Tests betting on Uniswap V4 fee switch using Resolver.sol
contract UniV4FeeSwitchTest is Test {
    // Mainnet addresses
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));
    Resolver constant resolver = Resolver(payable(0x00000000002205020E387b6a378c05639047BcFB));
    IUniswapV4 constant UNIV4 = IUniswapV4(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Test deadline: Year end 2027 (1830297599)
    uint64 constant DEADLINE_2025 = 1830297599;

    // Test actors
    address internal ALICE;
    address internal BOB;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.rpcUrl("main7"));

        // Create test actors with ETH
        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          CONDITION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that protocolFeeController() can be read as uint256
    function test_ProtocolFeeControllerReadsAsUint() public view {
        address controller = UNIV4.protocolFeeController();

        // Staticcall and decode as uint256 (mimics Resolver._readUint)
        (bool ok, bytes memory data) = address(UNIV4)
            .staticcall(abi.encodeWithSelector(IUniswapV4.protocolFeeController.selector));

        require(ok, "staticcall failed");
        require(data.length >= 32, "insufficient return data");

        uint256 asUint = abi.decode(data, (uint256));

        // If controller is address(0), asUint should be 0
        // Otherwise, asUint should equal uint160(controller)
        if (controller == address(0)) {
            assertEq(asUint, 0, "address(0) should decode to 0");
        } else {
            assertEq(asUint, uint160(controller), "non-zero address should decode to uint160 value");
            assertGt(asUint, 0, "non-zero address should be > 0");
        }

        console.log("Current protocolFeeController:", controller);
        console.log("Decoded as uint256:", asUint);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test creating a market for UniV4 fee switch
    function test_CreateUniV4FeeSwitchMarket() public {
        vm.startPrank(ALICE);

        (uint256 marketId, uint256 noId) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0), // ETH collateral
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ, // != 0
            0, // threshold
            DEADLINE_2025,
            true // canClose early when condition met
        );

        vm.stopPrank();

        // Verify market was created
        assertGt(marketId, 0, "marketId should be non-zero");
        assertGt(noId, 0, "noId should be non-zero");

        // Check market details
        (
            address resolverAddr,
            address collateral,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,,,,
            string memory description
        ) = pamm.getMarket(marketId);

        assertEq(resolverAddr, address(resolver), "resolver should be Resolver contract");
        assertEq(collateral, address(0), "collateral should be ETH");
        assertFalse(resolved, "market should not be resolved yet");
        assertTrue(canClose, "market should allow early close");
        assertEq(close, DEADLINE_2025, "close time should match deadline");

        console.log("Market created with ID:", marketId);
        console.log("Description:", description);
        console.log("NoId:", noId);
    }

    /// @notice Test creating market with liquidity seed
    function test_CreateUniV4FeeSwitchMarketWithSeed() public {
        vm.startPrank(ALICE);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 1 ether,
            feeOrHook: 0, // no fee/hook
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeedSimple{
            value: 1 ether
        }(
            "Uniswap V4 protocolFeeController()",
            address(0), // ETH collateral
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true,
            seed
        );

        vm.stopPrank();

        // Verify market and liquidity
        assertGt(marketId, 0, "marketId should be non-zero");
        assertGt(shares, 0, "shares should be non-zero");
        assertGt(liquidity, 0, "liquidity should be non-zero");

        console.log("Market with liquidity created. ID:", marketId);
        console.log("Shares:", shares);
        console.log("Liquidity:", liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                        CONDITION EVALUATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test preview() to check current condition state
    function test_PreviewCondition() public {
        // Create market
        vm.prank(ALICE);
        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true
        );

        // Preview the condition
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);

        address currentController = UNIV4.protocolFeeController();

        console.log("Current controller address:", currentController);
        console.log("Decoded value:", value);
        console.log("Condition true (controller != 0):", condTrue);
        console.log("Ready to resolve:", ready);

        // Verify the condition logic
        if (currentController == address(0)) {
            assertEq(value, 0, "value should be 0 when controller is address(0)");
            assertFalse(condTrue, "condition should be false when controller is address(0)");
        } else {
            assertEq(
                value, uint160(currentController), "value should match controller address as uint"
            );
            assertTrue(condTrue, "condition should be true when controller != address(0)");
        }

        // Ready to resolve only if condition is true (canClose=true)
        // or if we're past the deadline
        if (condTrue || block.timestamp >= DEADLINE_2025) {
            assertTrue(ready, "should be ready to resolve");
        } else {
            assertFalse(ready, "should not be ready to resolve yet");
        }
    }

    /// @notice Test with different operators (GT vs NEQ)
    function test_OperatorComparison() public {
        vm.startPrank(ALICE);

        // Create market with Op.GT (> 0)
        (uint256 marketId1,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController() [GT]",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.GT, // > 0
            0,
            DEADLINE_2025,
            true
        );

        // Create market with Op.NEQ (!= 0)
        (uint256 marketId2,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController() [NEQ]",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ, // != 0
            0,
            DEADLINE_2025,
            true
        );

        vm.stopPrank();

        // Preview both
        (uint256 value1, bool condTrue1,) = resolver.preview(marketId1);
        (uint256 value2, bool condTrue2,) = resolver.preview(marketId2);

        // Both should evaluate the same when checking non-zero
        assertEq(value1, value2, "both should read same value");
        assertEq(condTrue1, condTrue2, "both operators should give same result for != 0 vs > 0");

        console.log("Op.GT result:", condTrue1);
        console.log("Op.NEQ result:", condTrue2);
    }

    /*//////////////////////////////////////////////////////////////
                      RESOLUTION SIMULATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test early resolution if condition becomes true
    /// @dev This assumes fee switch hasn't happened yet. If it has, this tests normal resolution.
    function test_ResolutionWhenConditionTrue() public {
        address currentController = UNIV4.protocolFeeController();

        if (currentController != address(0)) {
            console.log("Fee switch already activated on mainnet, testing normal resolution");
        }

        vm.startPrank(ALICE);

        // Create market with seed
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 1 ether,
            feeOrHook: 0,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        (uint256 marketId,,,) = resolver.createNumericMarketAndSeedSimple{value: 1 ether}(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true,
            seed
        );

        vm.stopPrank();

        // Check if we can resolve
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);

        console.log("Value:", value);
        console.log("Condition true:", condTrue);
        console.log("Ready:", ready);

        if (ready && condTrue) {
            // If condition is true and canClose=true, we can resolve early
            vm.prank(BOB); // Anyone can call resolve
            resolver.resolveMarket(marketId);

            // Verify resolution
            (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(marketId);
            assertTrue(resolved, "market should be resolved");
            assertTrue(outcome, "outcome should be YES (true)");

            console.log("Market resolved early with YES outcome");
        } else {
            console.log("Condition not yet met, cannot resolve early");
            console.log("Would need to wait until:", DEADLINE_2025);
        }
    }

    /// @notice Test that resolution fails if not ready
    function test_ResolutionFailsWhenNotReady() public {
        address currentController = UNIV4.protocolFeeController();

        // Skip this test if fee switch already happened
        if (currentController != address(0)) {
            console.log("Skipping: fee switch already active");
            return;
        }

        vm.prank(ALICE);
        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true
        );

        // Check condition
        (, bool condTrue, bool ready) = resolver.preview(marketId);

        if (!ready) {
            // Should revert with Pending()
            vm.expectRevert(Resolver.Pending.selector);
            resolver.resolveMarket(marketId);

            console.log("Correctly reverted when not ready");
        }
    }

    /// @notice Test resolution after deadline with NO outcome
    function test_ResolutionAfterDeadlineNoOutcome() public {
        address currentController = UNIV4.protocolFeeController();

        // Only test this if fee switch hasn't happened
        if (currentController != address(0)) {
            console.log("Skipping: fee switch already active");
            return;
        }

        vm.prank(ALICE);
        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true
        );

        // Warp to after deadline
        vm.warp(DEADLINE_2025 + 1);

        // Resolve
        resolver.resolveMarket(marketId);

        // Verify resolution
        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(marketId);
        assertTrue(resolved, "market should be resolved");
        assertFalse(outcome, "outcome should be NO (false) since condition not met");

        console.log("Market resolved after deadline with NO outcome");
    }

    /*//////////////////////////////////////////////////////////////
                      FEE SWITCH SIMULATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate fee switch activation and test early resolution
    /// @dev Uses vm.etch to mock the protocolFeeController return value
    function test_SimulateFeeSwitch() public {
        vm.startPrank(ALICE);

        // Create market with seed
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 1 ether,
            feeOrHook: 0,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        (uint256 marketId,,,) = resolver.createNumericMarketAndSeedSimple{value: 1 ether}(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true,
            seed
        );

        vm.stopPrank();

        // Before fee switch
        (uint256 valueBefore, bool condBefore, bool readyBefore) = resolver.preview(marketId);
        assertEq(valueBefore, 0, "value should be 0 before fee switch");
        assertFalse(condBefore, "condition should be false before fee switch");
        assertFalse(readyBefore, "should not be ready before fee switch");

        console.log("Before fee switch - Value:", valueBefore, "Condition:", condBefore);

        // SIMULATE FEE SWITCH: Deploy a mock contract that returns a non-zero address
        // Create bytecode that returns a specific address when protocolFeeController() is called
        address mockController = address(0x1234567890123456789012345678901234567890);

        // Create minimal bytecode that returns mockController for any call
        // PUSH20 address, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
        bytes memory code = abi.encodePacked(
            hex"73", // PUSH20
            mockController,
            hex"60005260206000f3" // PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
        );

        vm.etch(address(UNIV4), code);

        // After fee switch
        (uint256 valueAfter, bool condAfter, bool readyAfter) = resolver.preview(marketId);
        assertEq(
            valueAfter, uint160(mockController), "value should equal controller address as uint"
        );
        assertTrue(condAfter, "condition should be true after fee switch");
        assertTrue(readyAfter, "should be ready to resolve early (canClose=true)");

        console.log("After fee switch - Value:", valueAfter, "Condition:", condAfter);

        // Verify we can resolve early with YES outcome
        vm.prank(BOB);
        resolver.resolveMarket(marketId);

        (,, bool resolved, bool outcome,,,,,,) = pamm.getMarket(marketId);
        assertTrue(resolved, "market should be resolved");
        assertTrue(outcome, "outcome should be YES");

        console.log("Market resolved early with YES outcome after fee switch");
    }

    /*//////////////////////////////////////////////////////////////
                          UTILITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test description building
    function test_BuildDescription() public pure {
        string memory desc = resolver.buildDescription(
            "Uniswap V4 protocolFeeController()", Resolver.Op.NEQ, 0, DEADLINE_2025, true
        );

        console.log("Generated description:");
        console.log(desc);

        // Should contain the observable, operator, threshold, deadline, and early close notice
        assertTrue(bytes(desc).length > 0, "description should not be empty");
    }

    /// @notice Verify condition storage
    function test_ConditionStorage() public {
        vm.prank(ALICE);
        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Uniswap V4 protocolFeeController()",
            address(0),
            address(UNIV4),
            IUniswapV4.protocolFeeController.selector,
            Resolver.Op.NEQ,
            0,
            DEADLINE_2025,
            true
        );

        // Read condition from storage
        (
            address targetA,
            address targetB,
            Resolver.Op op,
            bool isRatio,
            uint256 threshold,
            bytes memory callDataA,
            bytes memory callDataB
        ) = resolver.conditions(marketId);

        assertEq(targetA, address(UNIV4), "targetA should be UNIV4");
        assertEq(targetB, address(0), "targetB should be zero (scalar condition)");
        assertTrue(op == Resolver.Op.NEQ, "op should be NEQ");
        assertFalse(isRatio, "should not be a ratio condition");
        assertEq(threshold, 0, "threshold should be 0");
        assertEq(
            callDataA,
            abi.encodeWithSelector(IUniswapV4.protocolFeeController.selector),
            "callData should match selector"
        );
        assertEq(callDataB.length, 0, "callDataB should be empty");

        console.log("Condition storage verified");
    }
}
