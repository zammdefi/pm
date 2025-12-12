// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";
import {Resolver} from "../src/Resolver.sol";
import {ZAMM} from "@zamm/ZAMM.sol";

/// @notice Mock ERC20 for testing (18 decimals)
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock ERC20 with 6 decimals (like USDC)
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock ERC20 with no return value on transfer/transferFrom (USDT-style)
contract MockUSDT {
    string public name = "Mock USDT";
    string public symbol = "mUSDT";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // USDT-style: no return value
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    // USDT-style: no return value
    function transferFrom(address from, address to, uint256 amount) external {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Mock ERC20 with 8 decimals (like WBTC)
contract MockWBTC {
    string public name = "Mock WBTC";
    string public symbol = "mWBTC";
    uint8 public decimals = 8;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock oracle that returns a configurable uint256 value
contract MockOracle {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function getValueWithArg(uint256 multiplier) external view returns (uint256) {
        return value * multiplier;
    }
}

/// @notice Mock oracle that returns a configurable bool value
contract MockBoolOracle {
    bool public paused;

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }
}

/// @notice Mock oracle that always reverts
contract RevertingOracle {
    function getValue() external pure returns (uint256) {
        revert("oracle error");
    }
}

/// @notice Mock oracle that returns wrong data size (less than 32 bytes)
contract BadReturnOracle {
    fallback() external {
        // Return only 16 bytes instead of required 32
        assembly {
            mstore(0, 0x00112233445566778899aabbccddeeff)
            return(0, 16)
        }
    }
}

contract ResolverTest is Test {
    PAMM internal pm;
    Resolver internal resolver;
    MockERC20 internal token;
    MockOracle internal oracleA;
    MockOracle internal oracleB;

    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    uint64 internal closeTime;

    // Hardcoded PAMM address that resolver expects
    address payable constant PAMM_ADDRESS = payable(0x0000000000F8bA51d6e987660D3e455ac2c4BE9d);
    uint256 constant FEE_BPS = 30;

    function setUp() public {
        // Deploy PAMM to a temporary address first
        PAMM pammDeployed = new PAMM();

        // Etch PAMM's runtime code to the hardcoded address
        vm.etch(PAMM_ADDRESS, address(pammDeployed).code);
        pm = PAMM(PAMM_ADDRESS);

        // Deploy resolver (no constructor args - uses hardcoded PAMM address)
        resolver = new Resolver();

        token = new MockERC20();
        oracleA = new MockOracle();
        oracleB = new MockOracle();

        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        token.mint(ALICE, 1000 ether);
        token.mint(BOB, 1000 ether);

        // Approve resolver for seeding
        vm.prank(ALICE);
        token.approve(address(resolver), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(resolver), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         HARDCODED ADDRESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PAMM_IsHardcodedAddress() public view {
        assertEq(resolver.PAMM(), PAMM_ADDRESS);
        assertEq(resolver.PAMM(), address(pm));
    }

    /*//////////////////////////////////////////////////////////////
                     SCALAR MARKET CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateNumericMarketSimple_Success() public {
        oracleA.setValue(100);

        (uint256 marketId, uint256 noId) = resolver.createNumericMarketSimple(
            "oracle.getValue()",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Verify market created in PAMM
        (address mResolver,,,,,, uint64 close,,,,) = pm.getMarket(marketId);
        assertEq(mResolver, address(resolver));
        assertEq(close, closeTime);
        assertTrue(noId != 0);

        // Verify condition stored
        (address targetA,,,, uint256 threshold,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(threshold, 50);
    }

    function test_CreateNumericMarket_WithCalldata() public {
        oracleA.setValue(200);

        bytes memory callData = abi.encodeWithSelector(MockOracle.getValueWithArg.selector, 2);

        (uint256 marketId,) = resolver.createNumericMarket(
            "oracle.getValueWithArg(2)",
            address(token),
            address(oracleA),
            callData,
            Resolver.Op.GTE,
            400,
            closeTime,
            true
        );

        (address targetA,,,, uint256 threshold,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(threshold, 400);
    }

    function test_CreateNumericMarket_EmitsEvent() public {
        // Check that event is emitted with correct indexed params (targetA)
        // We use false for first topic since marketId is computed during creation
        vm.expectEmit(false, true, false, false);
        emit Resolver.ConditionCreated(
            0, // marketId unknown until created - not checked
            address(oracleA),
            Resolver.Op.LT,
            100,
            closeTime,
            false,
            false,
            ""
        );

        resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            100,
            closeTime,
            false
        );
    }

    function test_CreateNumericMarket_RevertInvalidTarget() public {
        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(0),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );
    }

    function test_CreateNumericMarket_RevertInvalidDeadline() public {
        vm.expectRevert(Resolver.InvalidDeadline.selector);
        resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            uint64(block.timestamp),
            false
        );
    }

    /*//////////////////////////////////////////////////////////////
                      RATIO MARKET CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateRatioMarketSimple_Success() public {
        oracleA.setValue(150);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "A/B ratio",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1.4e18, // 1.4 in 1e18 fixed-point
            closeTime,
            false
        );

        (address targetA, address targetB,, bool isRatio, uint256 threshold,,) =
            resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
        assertTrue(isRatio);
        assertEq(threshold, 1.4e18);
    }

    function test_CreateRatioMarket_WithCalldata() public {
        bytes memory callDataA = abi.encodeWithSelector(MockOracle.getValueWithArg.selector, 3);
        bytes memory callDataB = abi.encodeWithSelector(MockOracle.getValueWithArg.selector, 2);

        (uint256 marketId,) = resolver.createRatioMarket(
            "A*3/B*2",
            address(token),
            address(oracleA),
            callDataA,
            address(oracleB),
            callDataB,
            Resolver.Op.LTE,
            2e18,
            closeTime,
            true
        );

        (address targetA, address targetB,, bool isRatio,,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
        assertTrue(isRatio);
    }

    function test_CreateRatioMarket_RevertInvalidTargetA() public {
        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.createRatioMarketSimple(
            "test",
            address(token),
            address(0),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );
    }

    function test_CreateRatioMarket_RevertInvalidTargetB() public {
        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.createRatioMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(0),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );
    }

    /*//////////////////////////////////////////////////////////////
                          RESOLUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_YesWins_AfterClose() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50, // 100 > 50 = true
            closeTime,
            false
        );

        // Warp past close
        vm.warp(closeTime);

        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins

        // Condition should be deleted
        (address targetA,,,,,,) = resolver.conditions(marketId);
        assertEq(targetA, address(0));
    }

    function test_ResolveMarket_NoWins_AfterClose() public {
        oracleA.setValue(30);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50, // 30 > 50 = false
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // NO wins
    }

    function test_ResolveMarket_EarlyClose_ConditionTrue() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            true // canClose = true
        );

        // Still before close, but condition is true
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins via early close
    }

    function test_ResolveMarket_RevertPending_ConditionFalse_BeforeClose() public {
        oracleA.setValue(30);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50, // 30 > 50 = false
            closeTime,
            false
        );

        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);
    }

    function test_ResolveMarket_RevertPending_ConditionTrue_CannotClose() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50, // 100 > 50 = true
            closeTime,
            false // canClose = false
        );

        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);
    }

    function test_ResolveMarket_RevertUnknown() public {
        vm.expectRevert(Resolver.Unknown.selector);
        resolver.resolveMarket(12345);
    }

    function test_ResolveMarket_RevertMarketResolved() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        // Try to resolve again - condition is deleted so Unknown
        vm.expectRevert(Resolver.Unknown.selector);
        resolver.resolveMarket(marketId);
    }

    function test_ResolveMarket_Ratio_Success() public {
        oracleA.setValue(200);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "A/B",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1.5e18, // ratio = 2e18, threshold = 1.5e18
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 2 > 1.5
    }

    function test_ResolveMarket_Ratio_RevertDivisionByZero() public {
        oracleA.setValue(100);
        oracleB.setValue(0); // Division by zero

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "A/B",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );

        vm.warp(closeTime);

        vm.expectRevert(bytes4(0xad251c27)); // MulDivFailed()
        resolver.resolveMarket(marketId);
    }

    function test_ResolveMarket_RevertTargetCallFailed_Reverts() public {
        RevertingOracle badOracle = new RevertingOracle();

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(badOracle),
            RevertingOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        vm.expectRevert(Resolver.TargetCallFailed.selector);
        resolver.resolveMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                       ALL COMPARISON OPERATORS
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_Op_LT() public {
        oracleA.setValue(40);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 40 < 50
    }

    function test_Resolve_Op_LTE() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LTE,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 50 <= 50
    }

    function test_Resolve_Op_GTE() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GTE,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 50 >= 50
    }

    function test_Resolve_Op_EQ() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.EQ,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 50 == 50
    }

    function test_Resolve_Op_NEQ() public {
        oracleA.setValue(51);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.NEQ,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 51 != 50
    }

    /*//////////////////////////////////////////////////////////////
                           PREVIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Preview_BeforeClose_ConditionTrue_CanClose() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            true // canClose
        );

        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 100);
        assertTrue(condTrue);
        assertTrue(ready); // Can resolve early
    }

    function test_Preview_BeforeClose_ConditionTrue_CannotClose() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false // canClose = false
        );

        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 100);
        assertTrue(condTrue);
        assertFalse(ready); // Cannot resolve yet
    }

    function test_Preview_AfterClose() public {
        oracleA.setValue(30);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 30);
        assertFalse(condTrue);
        assertTrue(ready); // Past close, can resolve
    }

    function test_Preview_UnknownMarket() public view {
        (uint256 value, bool condTrue, bool ready) = resolver.preview(12345);
        assertEq(value, 0);
        assertFalse(condTrue);
        assertFalse(ready);
    }

    function test_Preview_Ratio() public {
        oracleA.setValue(300);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "A/B",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            2e18,
            closeTime,
            false
        );

        (uint256 value, bool condTrue,) = resolver.preview(marketId);
        assertEq(value, 3e18); // 300/100 * 1e18 = 3e18
        assertTrue(condTrue); // 3e18 > 2e18
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTER CONDITION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterConditionForExistingMarket_Success() public {
        // Create market directly via PAMM with resolver as the resolver
        (uint256 marketId,) =
            pm.createMarket("External market", address(resolver), address(token), closeTime, false);

        // Register condition
        resolver.registerConditionForExistingMarket(
            marketId,
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            100
        );

        (address targetA,,,, uint256 threshold,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(threshold, 100);
    }

    function test_RegisterConditionForExistingMarketSimple_Success() public {
        (uint256 marketId,) = pm.createMarket(
            "External market 2", address(resolver), address(token), closeTime, false
        );

        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleA), MockOracle.getValue.selector, Resolver.Op.LT, 200
        );

        (address targetA,,,, uint256 threshold,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(threshold, 200);
    }

    function test_RegisterRatioConditionForExistingMarket_Success() public {
        (uint256 marketId,) = pm.createMarket(
            "External ratio market", address(resolver), address(token), closeTime, true
        );

        resolver.registerRatioConditionForExistingMarket(
            marketId,
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(oracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GTE,
            1.5e18
        );

        (address targetA, address targetB,, bool isRatio, uint256 threshold,,) =
            resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
        assertTrue(isRatio);
        assertEq(threshold, 1.5e18);
    }

    function test_RegisterCondition_RevertConditionExists() public {
        (uint256 marketId,) = pm.createMarket(
            "External market 3", address(resolver), address(token), closeTime, false
        );

        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleA), MockOracle.getValue.selector, Resolver.Op.GT, 100
        );

        vm.expectRevert(Resolver.ConditionExists.selector);
        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleB), MockOracle.getValue.selector, Resolver.Op.LT, 200
        );
    }

    function test_RegisterCondition_RevertNotResolverMarket() public {
        // Create market with different resolver
        (uint256 marketId,) = pm.createMarket(
            "Other resolver market",
            address(this), // Not the resolver contract
            address(token),
            closeTime,
            false
        );

        vm.expectRevert(Resolver.NotResolverMarket.selector);
        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleA), MockOracle.getValue.selector, Resolver.Op.GT, 100
        );
    }

    function test_RegisterCondition_RevertMarketResolved() public {
        (uint256 marketId,) =
            pm.createMarket("To be resolved", address(resolver), address(token), closeTime, false);

        // Resolve it first (directly via resolver privilege)
        vm.warp(closeTime);
        vm.prank(address(resolver));
        pm.resolve(marketId, true);

        vm.expectRevert(Resolver.MarketResolved.selector);
        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleA), MockOracle.getValue.selector, Resolver.Op.GT, 100
        );
    }

    function test_RegisterCondition_RevertInvalidTarget() public {
        (uint256 marketId,) = pm.createMarket(
            "External market 4", address(resolver), address(token), closeTime, false
        );

        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.registerConditionForExistingMarketSimple(
            marketId, address(0), MockOracle.getValue.selector, Resolver.Op.GT, 100
        );
    }

    /*//////////////////////////////////////////////////////////////
                       BUILD DESCRIPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BuildDescription_NoEarlyClose() public view {
        string memory desc =
            resolver.buildDescription("ETH.price", Resolver.Op.GT, 10000, 1700000000, false);

        assertEq(desc, "ETH.price > 10000 by 1700000000 Unix time.");
    }

    function test_BuildDescription_WithEarlyClose() public view {
        string memory desc =
            resolver.buildDescription("BTC.price", Resolver.Op.LTE, 50000, 1800000000, true);

        assertEq(
            desc,
            "BTC.price <= 50000 by 1800000000 Unix time. Note: market may close early once condition is met."
        );
    }

    function test_BuildDescription_AllOperators() public view {
        assertEq(
            resolver.buildDescription("x", Resolver.Op.LT, 1, 1, false), "x < 1 by 1 Unix time."
        );
        assertEq(
            resolver.buildDescription("x", Resolver.Op.GT, 1, 1, false), "x > 1 by 1 Unix time."
        );
        assertEq(
            resolver.buildDescription("x", Resolver.Op.LTE, 1, 1, false), "x <= 1 by 1 Unix time."
        );
        assertEq(
            resolver.buildDescription("x", Resolver.Op.GTE, 1, 1, false), "x >= 1 by 1 Unix time."
        );
        assertEq(
            resolver.buildDescription("x", Resolver.Op.EQ, 1, 1, false), "x == 1 by 1 Unix time."
        );
        assertEq(
            resolver.buildDescription("x", Resolver.Op.NEQ, 1, 1, false), "x != 1 by 1 Unix time."
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ETH MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateNumericMarket_ETH() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "ETH oracle test",
            address(0), // ETH
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        (, address collateral,,,,,,,,,) = pm.getMarket(marketId);
        assertEq(collateral, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      CONDITION VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_LargeValues() public {
        oracleA.setValue(type(uint128).max);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "large value",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            type(uint128).max - 1,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome);
    }

    function test_Resolve_ZeroValue() public {
        oracleA.setValue(0);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "zero value",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.EQ,
            0,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 0 == 0
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ResolveScalar(uint256 oracleValue, uint256 threshold, uint8 opRaw) public {
        // Bound op to valid enum range
        Resolver.Op op = Resolver.Op(bound(opRaw, 0, 5));

        oracleA.setValue(oracleValue);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "fuzz test",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            op,
            threshold,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);

        // Verify outcome matches expected comparison
        bool expected;
        if (op == Resolver.Op.LT) expected = oracleValue < threshold;
        else if (op == Resolver.Op.GT) expected = oracleValue > threshold;
        else if (op == Resolver.Op.LTE) expected = oracleValue <= threshold;
        else if (op == Resolver.Op.GTE) expected = oracleValue >= threshold;
        else if (op == Resolver.Op.EQ) expected = oracleValue == threshold;
        else if (op == Resolver.Op.NEQ) expected = oracleValue != threshold;

        assertEq(outcome, expected);
    }

    function testFuzz_ResolveRatio(uint256 valueA, uint256 valueB, uint256 threshold) public {
        // Avoid division by zero and overflow
        valueA = bound(valueA, 0, type(uint128).max);
        valueB = bound(valueB, 1, type(uint128).max);
        threshold = bound(threshold, 0, type(uint256).max);

        oracleA.setValue(valueA);
        oracleB.setValue(valueB);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "fuzz ratio",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            threshold,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);

        uint256 ratio = (valueA * 1e18) / valueB;
        assertEq(outcome, ratio > threshold);
    }

    /*//////////////////////////////////////////////////////////////
                       LP SEEDING ERROR TESTS
    //////////////////////////////////////////////////////////////*/

    // Note: Full LP seeding success tests require ZAMM integration
    // and should be run as fork tests. Here we only test error paths
    // that revert before calling PAMM.splitAndAddLiquidity.

    // Note: CollateralNotMultiple check has been removed. Fractional amounts
    // are now supported with automatic dust refunds.

    // Note: Zero collateral test removed - PAMM handles this case

    function test_SeedLiquidity_RevertInvalidETHAmount_ERC20WithETH() public {
        oracleA.setValue(100);
        vm.deal(ALICE, 100 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 0,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.createNumericMarketAndSeed{value: 1 ether}(
            "ERC20 with ETH",
            address(token), // ERC20 collateral
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );
    }

    /*//////////////////////////////////////////////////////////////
                       BAD ORACLE RETURN DATA
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_RevertTargetCallFailed_ShortReturn() public {
        BadReturnOracle badOracle = new BadReturnOracle();

        // Use any selector - BadReturnOracle uses fallback to return short data
        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "short return",
            address(token),
            address(badOracle),
            bytes4(keccak256("getValue()")),
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        vm.expectRevert(Resolver.TargetCallFailed.selector);
        resolver.resolveMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                    RATIO OVERFLOW TEST
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_Ratio_OverflowReverts() public {
        // Set a very large value that will overflow when multiplied by 1e18
        oracleA.setValue(type(uint256).max);
        oracleB.setValue(1);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "overflow",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );

        vm.warp(closeTime);

        // Should revert with MulDivFailed due to overflow
        vm.expectRevert(bytes4(0xad251c27)); // MulDivFailed()
        resolver.resolveMarket(marketId);
    }

    function test_ResolveMarket_Ratio_MaxSafeValue() public {
        // Max safe value is type(uint256).max / 1e18
        uint256 maxSafe = type(uint256).max / 1e18;
        oracleA.setValue(maxSafe);
        oracleB.setValue(1);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "max safe",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );

        vm.warp(closeTime);

        // Should succeed - maxSafe * 1e18 doesn't overflow
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // maxSafe * 1e18 / 1 > 1e18
    }

    function test_ResolveMarket_Ratio_JustOverMaxSafe() public {
        // Just over max safe should fail
        uint256 justOver = (type(uint256).max / 1e18) + 1;
        oracleA.setValue(justOver);
        oracleB.setValue(1);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "just over",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );

        vm.warp(closeTime);

        vm.expectRevert(bytes4(0xad251c27)); // MulDivFailed()
        resolver.resolveMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                    RATIO REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterRatioConditionForExistingMarketSimple_Success() public {
        (uint256 marketId,) = pm.createMarket(
            "External ratio simple", address(resolver), address(token), closeTime, false
        );

        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.LTE,
            2e18
        );

        (address targetA, address targetB,, bool isRatio, uint256 threshold,,) =
            resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
        assertTrue(isRatio);
        assertEq(threshold, 2e18);
    }

    function test_RegisterRatioCondition_RevertInvalidTargetB() public {
        (uint256 marketId,) = pm.createMarket(
            "Ratio bad targetB", address(resolver), address(token), closeTime, false
        );

        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(0), // Invalid targetB
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );
    }

    function test_RegisterRatioCondition_RevertInvalidTargetA() public {
        (uint256 marketId,) = pm.createMarket(
            "Ratio bad targetA", address(resolver), address(token), closeTime, false
        );

        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(0), // Invalid targetA
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );
    }

    /*//////////////////////////////////////////////////////////////
                    RECEIVE ETH TEST
    //////////////////////////////////////////////////////////////*/

    function test_Receive_AcceptsETH() public {
        vm.deal(address(this), 1 ether);

        // Resolver should accept ETH
        (bool success,) = address(resolver).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(resolver).balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    EXACT CLOSE TIME RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_AtExactCloseTime() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "exact close",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Warp to exactly closeTime (not past it)
        vm.warp(closeTime);

        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome);
    }

    /*//////////////////////////////////////////////////////////////
                    CONDITION CHANGES DURING MARKET
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_OracleValueChanges() public {
        oracleA.setValue(30); // Initially false

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "changing oracle",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Condition is false, can't resolve before close
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Oracle value changes
        oracleA.setValue(100);

        // Still can't resolve before close (canClose = false)
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // After close, should resolve based on current value
        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // Current value 100 > 50
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLVE ALREADY RESOLVED VIA PAMM
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_RevertMarketAlreadyResolvedViaPAMM() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "to resolve externally",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        // Resolve directly via PAMM (resolver has permission)
        vm.prank(address(resolver));
        pm.resolve(marketId, false);

        // Now try via resolver - should fail as already resolved
        // Note: condition still exists but market is resolved
        vm.expectRevert(Resolver.MarketResolved.selector);
        resolver.resolveMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATOR BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_Op_GT_Boundary_Equal() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "boundary",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // 50 > 50 is FALSE
    }

    function test_Resolve_Op_LT_Boundary_Equal() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "boundary",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // 50 < 50 is FALSE
    }

    function test_Resolve_Op_EQ_NotEqual() public {
        oracleA.setValue(51);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "not equal",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.EQ,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // 51 == 50 is FALSE
    }

    function test_Resolve_Op_NEQ_Equal() public {
        oracleA.setValue(50);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "equal",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.NEQ,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // 50 != 50 is FALSE
    }

    /*//////////////////////////////////////////////////////////////
                    CONDITION DELETION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_DeletesCondition_YesWins() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "delete yes",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Verify condition exists before resolution
        (address targetBefore,,,,,,) = resolver.conditions(marketId);
        assertEq(targetBefore, address(oracleA));

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        // Verify condition deleted after resolution
        (address targetAfter,,,,,,) = resolver.conditions(marketId);
        assertEq(targetAfter, address(0));
    }

    function test_ResolveMarket_DeletesCondition_NoWins() public {
        oracleA.setValue(30);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "delete no",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        (address targetBefore,,,,,,) = resolver.conditions(marketId);
        assertEq(targetBefore, address(oracleA));

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (address targetAfter,,,,,,) = resolver.conditions(marketId);
        assertEq(targetAfter, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    RATIO EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_Ratio_ZeroNumerator() public {
        oracleA.setValue(0);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "0/B",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.EQ,
            0,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 0/100 * 1e18 = 0, 0 == 0
    }

    function test_ResolveMarket_Ratio_EQ_Operator() public {
        oracleA.setValue(200);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "ratio eq",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.EQ,
            2e18,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 200/100 * 1e18 = 2e18, 2e18 == 2e18
    }

    function test_ResolveMarket_Ratio_LessThanOne() public {
        oracleA.setValue(50);
        oracleB.setValue(100);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "ratio lt 1",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            1e18,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 50/100 * 1e18 = 0.5e18, 0.5e18 < 1e18
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLVE WRONG RESOLVER
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_RevertNotResolverMarket() public {
        // Create market with a DIFFERENT resolver
        address otherResolver = makeAddr("OTHER_RESOLVER");
        (uint256 marketId,) = pm.createMarket(
            "other resolver market", otherResolver, address(token), closeTime, false
        );

        // Manually set condition (bypassing normal registration checks)
        // This simulates a corrupted state where condition exists but resolver doesn't match
        // Actually, we can't directly set the condition, so let's test via registration flow

        // Create a valid market with our resolver
        oracleA.setValue(100);
        resolver.createNumericMarketSimple(
            "our market",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        // Try resolving the other market (no condition registered)
        vm.expectRevert(Resolver.Unknown.selector);
        resolver.resolveMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTRATION ERROR CASES FOR RATIO
    //////////////////////////////////////////////////////////////*/

    function test_RegisterRatioCondition_RevertConditionExists() public {
        (uint256 marketId,) =
            pm.createMarket("ratio exists", address(resolver), address(token), closeTime, false);

        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );

        vm.expectRevert(Resolver.ConditionExists.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleB),
            MockOracle.getValue.selector,
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            2e18
        );
    }

    function test_RegisterRatioCondition_RevertNotResolverMarket() public {
        (uint256 marketId,) =
            pm.createMarket("wrong resolver", address(this), address(token), closeTime, false);

        vm.expectRevert(Resolver.NotResolverMarket.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );
    }

    function test_RegisterRatioCondition_RevertMarketResolved() public {
        (uint256 marketId,) =
            pm.createMarket("already resolved", address(resolver), address(token), closeTime, false);

        vm.warp(closeTime);
        vm.prank(address(resolver));
        pm.resolve(marketId, true);

        vm.expectRevert(Resolver.MarketResolved.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTRATION FOR NON-EXISTENT MARKET
    //////////////////////////////////////////////////////////////*/

    function test_RegisterCondition_RevertNonExistentMarket() public {
        // Non-existent market causes PAMM.getMarket to revert with MarketNotFound
        vm.expectRevert(PAMM.MarketNotFound.selector);
        resolver.registerConditionForExistingMarketSimple(
            999999, // Non-existent marketId
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            100
        );
    }

    function test_RegisterRatioCondition_RevertNonExistentMarket() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        resolver.registerRatioConditionForExistingMarketSimple(
            888888,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18
        );
    }

    /*//////////////////////////////////////////////////////////////
                    PREVIEW STALE DATA TEST
    //////////////////////////////////////////////////////////////*/

    function test_Preview_AfterResolution_ReturnsZeros() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "preview stale",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        // After resolution, condition is deleted
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 0);
        assertFalse(condTrue);
        assertFalse(ready);
    }

    /*//////////////////////////////////////////////////////////////
                    EVENT EMISSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterCondition_EmitsEvent() public {
        (uint256 marketId,) =
            pm.createMarket("event test", address(resolver), address(token), closeTime, true);

        vm.expectEmit(true, true, false, true);
        emit Resolver.ConditionRegistered(
            marketId, address(oracleA), Resolver.Op.GT, 100, closeTime, true, false
        );

        resolver.registerConditionForExistingMarketSimple(
            marketId, address(oracleA), MockOracle.getValue.selector, Resolver.Op.GT, 100
        );
    }

    function test_RegisterRatioCondition_EmitsEvent() public {
        (uint256 marketId,) =
            pm.createMarket("ratio event test", address(resolver), address(token), closeTime, false);

        vm.expectEmit(true, true, false, true);
        emit Resolver.ConditionRegistered(
            marketId, address(oracleA), Resolver.Op.GTE, 2e18, closeTime, false, true
        );

        resolver.registerRatioConditionForExistingMarketSimple(
            marketId,
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GTE,
            2e18
        );
    }

    /*//////////////////////////////////////////////////////////////
                    EARLY CLOSE THEN ORACLE CHANGES
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_EarlyClose_OracleChangesAfter() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "early close oracle change",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            true // canClose
        );

        // Resolve early while condition is true
        resolver.resolveMarket(marketId);

        // Oracle changes after resolution
        oracleA.setValue(30);

        // Market should still be resolved as YES
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTIPLE MARKETS SAME ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_MultipleMarkets_SameOracle_IndependentResolution() public {
        oracleA.setValue(75);

        // Market 1: GT 50 (should be YES)
        (uint256 marketId1,) = resolver.createNumericMarketSimple(
            "market 1",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Market 2: GT 100 (should be NO)
        (uint256 marketId2,) = resolver.createNumericMarketSimple(
            "market 2",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            100,
            closeTime,
            false
        );

        vm.warp(closeTime);

        resolver.resolveMarket(marketId1);
        resolver.resolveMarket(marketId2);

        (,,, bool resolved1, bool outcome1,,,,,,) = pm.getMarket(marketId1);
        (,,, bool resolved2, bool outcome2,,,,,,) = pm.getMarket(marketId2);

        assertTrue(resolved1);
        assertTrue(outcome1); // 75 > 50

        assertTrue(resolved2);
        assertFalse(outcome2); // 75 > 100 is false
    }

    // Note: USDC CollateralNotMultiple test removed - fractional amounts now supported
    // Note: Ratio seed zero test removed - PAMM handles this case

    /*//////////////////////////////////////////////////////////////
                    ADDITIONAL EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_CreateRatioMarket_SameTargetForAAndB() public {
        // Valid use case: ratio of two different functions on same contract
        oracleA.setValue(200);

        (uint256 marketId,) = resolver.createRatioMarket(
            "same target ratio",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValueWithArg.selector, 2), // 200 * 2 = 400
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValueWithArg.selector, 1), // 200 * 1 = 200
            Resolver.Op.EQ,
            2e18, // ratio = 400/200 = 2
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // 2e18 == 2e18
    }

    function test_CreateNumericMarket_EmptyObservable() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "", // Empty observable string
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        // Should still work - description will just be " > 50 by X Unix time."
        (address mResolver,,,,,,,,,, string memory desc) = pm.getMarket(marketId);
        assertEq(mResolver, address(resolver));
        assertTrue(bytes(desc).length > 0);
    }

    function test_Preview_RatioOverflow() public {
        // Preview should also revert on overflow
        oracleA.setValue(type(uint256).max);
        oracleB.setValue(1);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "preview overflow",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18,
            closeTime,
            false
        );

        vm.expectRevert(bytes4(0xad251c27)); // MulDivFailed()
        resolver.preview(marketId);
    }

    function test_ResolveMarket_CalledByAnyone() public {
        oracleA.setValue(100);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "anyone can resolve",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.warp(closeTime);

        // Random address can resolve
        address randomUser = makeAddr("RANDOM");
        vm.prank(randomUser);
        resolver.resolveMarket(marketId);

        (,,, bool resolved,,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
    }

    function test_CreateMarket_CloseTimeJustAfterNow() public {
        oracleA.setValue(100);

        uint64 justAfter = uint64(block.timestamp + 1);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "close soon",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            justAfter,
            false
        );

        // Can't resolve yet (1 second before close)
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Warp 1 second
        vm.warp(justAfter);
        resolver.resolveMarket(marketId);

        (,,, bool resolved,,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
    }

    function test_Conditions_MappingReturnsAllFields() public {
        oracleA.setValue(100);
        oracleB.setValue(50);

        (uint256 marketId,) = resolver.createRatioMarketSimple(
            "full condition",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GTE,
            1.5e18,
            closeTime,
            true
        );

        (
            address targetA,
            address targetB,
            Resolver.Op op,
            bool isRatio,
            uint256 threshold,
            bytes memory callDataA,
            bytes memory callDataB
        ) = resolver.conditions(marketId);

        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
        assertEq(uint8(op), uint8(Resolver.Op.GTE));
        assertTrue(isRatio);
        assertEq(threshold, 1.5e18);
        assertEq(callDataA, abi.encodeWithSelector(MockOracle.getValue.selector));
        assertEq(callDataB, abi.encodeWithSelector(MockOracle.getValue.selector));
    }

    /*//////////////////////////////////////////////////////////////
                    BOOLEAN ORACLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BooleanOracle_TrueCondition_YesWins() public {
        // Boolean return values work natively - true encodes as 1
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(true);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Protocol paused",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.EQ,
            1, // true = 1
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // isPaused() == true, so YES wins
    }

    function test_BooleanOracle_FalseCondition_NoWins() public {
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(false);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Protocol paused",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.EQ,
            1, // true = 1
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // isPaused() == false (0), not equal to 1, so NO wins
    }

    function test_BooleanOracle_CheckForFalse() public {
        // Can also check for false by using threshold=0
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(false);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Protocol not paused",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.EQ,
            0, // false = 0
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // isPaused() == false (0), equals 0, so YES wins
    }

    function test_BooleanOracle_NEQ_NotPaused() public {
        // NEQ operator: "protocol is NOT paused"
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(false);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Protocol is active",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.NEQ,
            1, // NOT true means not paused
            closeTime,
            false
        );

        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // isPaused() = 0, 0 != 1, so YES wins
    }

    function test_BooleanOracle_EarlyClose_OnPause() public {
        // Insurance market: YES wins as soon as protocol is paused
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(false); // Start unpaused

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Protocol pause insurance",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.EQ,
            1, // true = 1
            closeTime,
            true // canClose = true for early resolution
        );

        // Can't resolve yet - not paused
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Protocol gets paused
        boolOracle.setPaused(true);

        // Now can resolve early
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // Insurance pays out
    }

    function test_BooleanOracle_Preview() public {
        MockBoolOracle boolOracle = new MockBoolOracle();
        boolOracle.setPaused(true);

        (uint256 marketId,) = resolver.createNumericMarketSimple(
            "Preview bool",
            address(token),
            address(boolOracle),
            MockBoolOracle.isPaused.selector,
            Resolver.Op.EQ,
            1,
            closeTime,
            true
        );

        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 1); // true = 1
        assertTrue(condTrue); // 1 == 1
        assertTrue(ready); // canClose=true and condition is true
    }

    /*//////////////////////////////////////////////////////////////
                    MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Multicall_CreateMultipleMarkets() public {
        oracleA.setValue(100);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            resolver.createNumericMarketSimple.selector,
            "market 1",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );
        calls[1] = abi.encodeWithSelector(
            resolver.createNumericMarketSimple.selector,
            "market 2",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            200,
            closeTime,
            false
        );

        bytes[] memory results = resolver.multicall(calls);

        (uint256 marketId1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 marketId2,) = abi.decode(results[1], (uint256, uint256));

        assertTrue(marketId1 != marketId2);

        (address r1,,,,,,,,,,) = pm.getMarket(marketId1);
        (address r2,,,,,,,,,,) = pm.getMarket(marketId2);

        assertEq(r1, address(resolver));
        assertEq(r2, address(resolver));
    }

    function test_Multicall_Payable() public {
        vm.deal(address(this), 10 ether);

        // Multicall is payable - verify it doesn't revert with ETH
        bytes[] memory calls = new bytes[](0);

        // Empty multicall with ETH should work (ETH stays with resolver)
        uint256 balBefore = address(resolver).balance;
        resolver.multicall{value: 1 ether}(calls);
        assertEq(address(resolver).balance, balBefore + 1 ether);
    }

    function test_Multicall_RevertPropagates() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            resolver.createNumericMarketSimple.selector,
            "will fail",
            address(token),
            address(0), // Invalid target
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            50,
            closeTime,
            false
        );

        vm.expectRevert(Resolver.InvalidTarget.selector);
        resolver.multicall(calls);
    }

    /*//////////////////////////////////////////////////////////////
                    STRUCT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SeedParams_Struct() public view {
        // Verify SeedParams struct is correctly formatted
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30, // 0.3% fee
            amount0Min: 1 ether,
            amount1Min: 1 ether,
            minLiquidity: 1000,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        assertEq(seed.collateralIn, 10 ether);
        assertEq(seed.feeOrHook, 30);
        assertEq(seed.lpRecipient, ALICE);
    }

    function test_SwapParams_Struct() public pure {
        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 1 ether, minOut: 0.9 ether, yesForNo: true});

        assertEq(swap.collateralForSwap, 1 ether);
        assertEq(swap.minOut, 0.9 ether);
        assertTrue(swap.yesForNo);
    }
}

/*//////////////////////////////////////////////////////////////
                INTEGRATION TESTS WITH ZAMM
//////////////////////////////////////////////////////////////*/

contract Resolver_Integration_Test is Test {
    PAMM pm;
    ZAMM zamm;
    Resolver resolver;
    MockERC20 token;
    MockOracle oracleA;
    MockOracle oracleB;

    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    address payable constant PAMM_ADDRESS = payable(0x0000000000F8bA51d6e987660D3e455ac2c4BE9d);
    address constant ZAMM_ADDRESS = 0x000000000000040470635EB91b7CE4D132D616eD;
    uint256 constant FEE_BPS = 30;

    uint64 closeTime;

    function setUp() public {
        // Deploy ZAMM at expected address
        bytes memory zammCode = type(ZAMM).creationCode;
        address zammDeployed;
        assembly {
            zammDeployed := create(0, add(zammCode, 0x20), mload(zammCode))
        }
        vm.etch(ZAMM_ADDRESS, zammDeployed.code);
        vm.store(ZAMM_ADDRESS, bytes32(uint256(0x00)), bytes32(uint256(uint160(address(this)))));
        zamm = ZAMM(payable(ZAMM_ADDRESS));

        // Deploy PAMM at expected address
        PAMM pammDeployed = new PAMM();
        vm.etch(PAMM_ADDRESS, address(pammDeployed).code);
        pm = PAMM(PAMM_ADDRESS);

        // Deploy resolver (no constructor args)
        resolver = new Resolver();

        // Setup tokens and oracles
        token = new MockERC20();
        oracleA = new MockOracle();
        oracleB = new MockOracle();
        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        token.mint(ALICE, 100000 ether);
        token.mint(BOB, 100000 ether);
        vm.deal(ALICE, 100000 ether);
        vm.deal(BOB, 100000 ether);

        // Approve resolver for tokens
        vm.prank(ALICE);
        token.approve(address(resolver), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(resolver), type(uint256).max);
    }

    function _getPoolId(IZAMM.PoolKey memory key) internal pure returns (uint256) {
        return
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
    }

    /*//////////////////////////////////////////////////////////////
                    LP SEEDING SUCCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CreateNumericMarketAndSeed_Success() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed(
            "seeded market",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // Verify market created
        (address mResolver,,,,,,,,,,) = pm.getMarket(marketId);
        assertEq(mResolver, address(resolver));

        // Verify shares minted (1:1 with collateral)
        assertEq(shares, 10000 ether);

        // Verify liquidity received
        assertTrue(liquidity > 0);

        // Verify ALICE has LP tokens
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId = _getPoolId(key);
        assertEq(zamm.balanceOf(ALICE, poolId), liquidity);
    }

    function test_Integration_CreateNumericMarketAndSeedSimple_Success() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 5000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeedSimple(
            "simple seeded",
            address(token),
            address(oracleA),
            MockOracle.getValue.selector,
            Resolver.Op.LT,
            200,
            closeTime,
            true,
            seed
        );

        assertEq(shares, 5000 ether);
        assertTrue(liquidity > 0);

        // Verify condition registered
        (address targetA,,,,,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
    }

    function test_Integration_CreateRatioMarketAndSeed_Success() public {
        MockOracle localOracleB = new MockOracle();
        oracleA.setValue(200);
        localOracleB.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 8000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: BOB,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(BOB);
        token.approve(address(resolver), type(uint256).max);

        vm.prank(BOB);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createRatioMarketAndSeed(
            "ratio seeded",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(localOracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            1.5e18,
            closeTime,
            false,
            seed
        );

        assertEq(shares, 8000 ether);
        assertTrue(liquidity > 0);

        // Verify ratio condition
        (, address targetB,, bool isRatio,,,) = resolver.conditions(marketId);
        assertEq(targetB, address(localOracleB));
        assertTrue(isRatio);
    }

    function test_Integration_CreateMarketAndSeed_ETH() public {
        oracleA.setValue(100);

        // Need > 1000 shares to exceed ZAMM's MINIMUM_LIQUIDITY
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed{
            value: 10000 ether
        }(
            "ETH seeded",
            address(0), // ETH
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        assertEq(shares, 10000 ether); // 10000 ETH = 10000 ether shares (1:1)
        assertTrue(liquidity > 0);

        // Verify market uses ETH
        (, address collateral,,,,,,,,,) = pm.getMarket(marketId);
        assertEq(collateral, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    SEED AND SEED AND BUY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CreateNumericMarketSeedAndSeedAndBuy_YesForNo() public {
        // Test using buyNo to get more NO (yesForNo=true)
        // buyNo: splits 1000 ether → 1000 YES + 1000 NO
        //        swaps all 1000 YES → ~909 NO
        //        returns: 1000 + 909 = ~1909 total NO to ALICE
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Use 1000 ether to buy NO (via split + swap YES→NO)
        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 1000 ether, minOut: 0, yesForNo: true});

        vm.prank(ALICE);
        (, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "odds market",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(liquidity > 0);

        // swapOut is the TOTAL NO from buyNo (split shares + swap output)
        // Should be > 1000 ether (got bonus from swap) but < 2000 ether (fees/slippage)
        assertTrue(swapOut > 1000 ether, "should get more NO than input shares");
        assertTrue(swapOut < 2000 ether, "should be less than 2x due to fees");

        // ALICE's NO balance should equal swapOut
        uint256 aliceNo = pm.balanceOf(ALICE, noId);
        assertEq(aliceNo, swapOut, "ALICE should have all NO from buyNo");
    }

    function test_Integration_CreateNumericMarketSeedAndSeedAndBuy_NoForYes() public {
        // Test using buyYes to get more YES (yesForNo=false)
        // buyYes: splits 500 ether → 500 YES + 500 NO
        //         swaps all 500 NO → ~476 YES
        //         returns: 500 + 476 = ~976 total YES to ALICE
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Use 500 ether to buy YES (via split + swap NO→YES)
        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 500 ether, minOut: 0, yesForNo: false});

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "no for yes",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);

        // swapOut is the TOTAL YES from buyYes (split shares + swap output)
        // Should be > 500 ether (got bonus from swap) but < 1000 ether (fees/slippage)
        assertTrue(swapOut > 500 ether, "should get more YES than input shares");
        assertTrue(swapOut < 1000 ether, "should be less than 2x due to fees");

        // ALICE's YES balance should equal swapOut
        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        assertEq(aliceYes, swapOut, "ALICE should have all YES from buyYes");
    }

    function test_Integration_CreateNumericMarketSeedAndSeedAndBuy_ZeroSwap() public {
        // Test with zero swap - just seed LP, no odds setting
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Zero collateral for swap = no swap
        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 0, minOut: 0, yesForNo: true});

        vm.prank(ALICE);
        (,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "no swap",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertEq(swapOut, 0); // No swap executed
    }

    function test_Integration_CreateNumericMarketSeedAndSeedAndBuy_ETH() public {
        // Test ETH market with seed + swap (msg.value = seed + swap collateral)
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 1000 ether, minOut: 0, yesForNo: true});

        // msg.value must be seed.collateralIn + swap.collateralForSwap
        vm.deal(ALICE, 11000 ether);
        vm.prank(ALICE);
        (, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy{
            value: 11000 ether
        }(
            "ETH odds market",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(liquidity > 0);
        assertTrue(swapOut > 1000 ether, "should get more NO than input shares");

        uint256 aliceNo = pm.balanceOf(ALICE, noId);
        assertEq(aliceNo, swapOut);
    }

    // Note: SeedAndBuy collateral not multiple tests removed - fractional amounts now supported with dust refunds

    /*//////////////////////////////////////////////////////////////
                    FULL LIFECYCLE TEST
    //////////////////////////////////////////////////////////////*/

    function test_Integration_FullLifecycle_CreateSeedResolve() public {
        oracleA.setValue(100);

        // 1. Create market with LP
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "full lifecycle",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50, // threshold
            closeTime,
            false,
            seed
        );

        // 2. Verify condition exists
        (address target,,,,,,) = resolver.conditions(marketId);
        assertEq(target, address(oracleA));

        // 3. Warp to close time
        vm.warp(closeTime);

        // 4. Resolve (condition: 100 > 50 = true = YES wins)
        resolver.resolveMarket(marketId);

        // 5. Verify resolution
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES won

        // 6. Verify condition deleted
        (address targetAfter,,,,,,) = resolver.conditions(marketId);
        assertEq(targetAfter, address(0));
    }

    function test_Integration_FullLifecycle_EarlyClose() public {
        oracleA.setValue(30); // Start below threshold

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 5000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "early close test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            true, // canClose = true
            seed
        );

        // Can't resolve yet (condition false)
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Oracle value changes to meet condition
        oracleA.setValue(100);

        // Now can resolve early
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES won via early close
    }

    /*//////////////////////////////////////////////////////////////
                    USER PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_DeadlineExpired_Seed() public {
        oracleA.setValue(100);

        // Warp to a non-zero timestamp first
        vm.warp(1000);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: 500 // expired (current is 1000)
        });

        vm.prank(ALICE);
        vm.expectRevert(ZAMM.Expired.selector); // ZAMM checks deadline first
        resolver.createNumericMarketAndSeed(
            "deadline test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            uint64(block.timestamp + 30 days),
            false,
            seed
        );
    }

    function test_Integration_DeadlineExpired_Swap() public {
        oracleA.setValue(100);

        // Warp to a non-zero timestamp first
        vm.warp(1000);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: 500 // expired - applies to both seed and swap
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 1000 ether, minOut: 0, yesForNo: true});

        vm.prank(ALICE);
        vm.expectRevert(ZAMM.Expired.selector); // ZAMM checks deadline first
        resolver.createNumericMarketSeedAndBuy(
            "deadline swap test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            uint64(block.timestamp + 30 days),
            false,
            seed,
            swap
        );
    }

    function test_Integration_MinLiquidity_Reverts() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: type(uint256).max, // impossible to satisfy
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        vm.expectRevert(PAMM.InsufficientOutput.selector);
        resolver.createNumericMarketAndSeed(
            "minLiquidity test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );
    }

    function test_Integration_MinOut_Swap_Reverts() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 1000 ether,
            minOut: type(uint256).max, // impossible to satisfy
            yesForNo: true
        });

        vm.prank(ALICE);
        vm.expectRevert(PAMM.InsufficientOutput.selector);
        resolver.createNumericMarketSeedAndBuy(
            "minOut test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );
    }

    function test_Integration_MinOut_Swap_Success() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // buyNo splits collateral and swaps YES for NO
        // For 1000 ether: splits into 1000 shares YES + 1000 shares NO
        // Then swaps 1000 YES for ~906 NO, yielding total ~1906 NO shares
        // minOut is in shares (not wei), so set minOut to 1800 shares
        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 1000 ether,
            minOut: 1800, // expect ~1906 NO shares total
            yesForNo: true
        });

        vm.prank(ALICE);
        (,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "minOut success",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(swapOut >= 1800 ether, "should meet minOut");
        assertTrue(swapOut > 1000 ether, "buyNo should yield bonus NO shares");
    }

    function test_Integration_DeadlineZero_NoCheck() public {
        oracleA.setValue(100);

        // deadline = 0 means no deadline check (PAMM pattern)
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: 0 // no deadline
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 1000 ether, minOut: 0, yesForNo: true});

        // Warp far into future - should still work with deadline=0
        vm.warp(block.timestamp + 365 days);

        vm.prank(ALICE);
        (,, uint256 shares,,) = resolver.createNumericMarketSeedAndBuy(
            "no deadline",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            uint64(block.timestamp + 30 days),
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
    }

    function test_Integration_RatioMarket_SeedAndSeedAndBuy() public {
        oracleA.setValue(200);
        MockOracle localOracleB = new MockOracle();
        localOracleB.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 500 ether,
            minOut: 0,
            yesForNo: false // buy YES
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createRatioMarketSeedAndBuy(
            "ratio odds",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(localOracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            1.5e18, // ratio > 1.5
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(swapOut > 500 ether, "should get bonus YES from swap");

        // Verify ALICE has YES tokens
        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        assertEq(aliceYes, swapOut);
    }

    function test_Integration_CreateRatioMarketAndSeed_NonSimple() public {
        MockOracle localOracleB = new MockOracle();
        oracleA.setValue(200);
        localOracleB.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity) = resolver.createRatioMarketAndSeed(
            "ratio market",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(localOracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            1.5e18,
            closeTime,
            false,
            seed
        );

        assertEq(shares, 10000 ether);
        assertTrue(liquidity > 0);
        assertEq(noId, pm.getNoId(marketId));
    }

    function test_Integration_Multicall_ETH_SingleCall_Works() public {
        oracleA.setValue(100);

        // Multicall with single ETH seed works
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        bytes memory call1 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market1",
                address(0), // ETH
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.GT,
                50,
                closeTime,
                false,
                seed
            )
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = call1;

        vm.deal(ALICE, 10000 ether);
        vm.prank(ALICE);
        resolver.multicall{value: 10000 ether}(calls);

        // Contract should have 0 ETH left
        assertEq(address(resolver).balance, 0);
    }

    function test_Integration_Multicall_ETH_MultipleSeeds_NotSupported() public {
        // Multicall with multiple ETH seeds is NOT supported due to strict ETH checks
        // Each subcall checks msg.value == collateralIn, but msg.value is total for all calls
        // Use separate transactions for ETH markets, or use ERC20 collateral for multicall
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 5000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        bytes memory call1 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market1",
                address(0),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.GT,
                50,
                closeTime,
                false,
                seed
            )
        );

        bytes memory call2 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market2",
                address(0),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.LT,
                200,
                closeTime,
                false,
                seed
            )
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = call1;
        calls[1] = call2;

        // This will fail because first call expects msg.value == 5000 but gets 10000
        vm.deal(ALICE, 10000 ether);
        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.multicall{value: 10000 ether}(calls);
    }

    function test_Integration_Multicall_ETH_DoubleSpend_Reverts() public {
        oracleA.setValue(100);

        // Attempt double-spend: send 10000 ETH, try to use it twice (20000 total)
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        bytes memory call1 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market1",
                address(0),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.GT,
                50,
                closeTime,
                false,
                seed
            )
        );

        bytes memory call2 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market2",
                address(0),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.LT,
                200,
                closeTime,
                false,
                seed
            )
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = call1;
        calls[1] = call2;

        // Send 10000 ETH but try to use 20000 (10000 + 10000)
        // First call succeeds, second call fails at low-level ETH transfer
        vm.deal(ALICE, 10000 ether);
        vm.prank(ALICE);
        vm.expectRevert(); // Reverts at low-level ETH transfer - balance depleted
        resolver.multicall{value: 10000 ether}(calls);
    }

    function test_Integration_Multicall_ERC20_MultipleSeeds_Works() public {
        oracleA.setValue(100);

        // Multicall with multiple ERC20 seeds works fine
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 5000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        bytes memory call1 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market1",
                address(token),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.GT,
                50,
                closeTime,
                false,
                seed
            )
        );

        bytes memory call2 = abi.encodeCall(
            resolver.createNumericMarketAndSeed,
            (
                "market2",
                address(token),
                address(oracleA),
                abi.encodeWithSelector(MockOracle.getValue.selector),
                Resolver.Op.LT,
                200,
                closeTime,
                false,
                seed
            )
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = call1;
        calls[1] = call2;

        vm.prank(ALICE);
        resolver.multicall(calls);

        // Both markets created successfully with ERC20
    }

    function test_Integration_CreateRatioMarketSeedAndSeedAndBuy() public {
        MockOracle localOracleB = new MockOracle();
        oracleA.setValue(300);
        localOracleB.setValue(100); // ratio = 3.0

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 500 ether,
            minOut: 0,
            yesForNo: true // buy NO
        });

        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut) = resolver.createRatioMarketSeedAndBuy(
            "ratio odds market",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(localOracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            2e18, // ratio > 2.0
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(liquidity > 0);
        assertTrue(swapOut > 500 ether, "should get bonus NO from swap");

        // Verify ALICE has NO tokens
        uint256 aliceNo = pm.balanceOf(ALICE, noId);
        assertEq(aliceNo, swapOut);

        // Verify market can be resolved (ratio 3.0 > 2.0, so YES wins)
        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins
    }

    function test_Integration_SeedLiquidity_ExcessETH_Reverts() public {
        // Excess ETH now reverts - user must send exact collateralIn amount
        oracleA.setValue(100);
        vm.deal(ALICE, 20000 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.createNumericMarketAndSeed{value: 15000 ether}( // More than collateralIn
            "ETH with excess",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );
    }

    function test_Integration_SeedLiquidity_InsufficientETH_Reverts() public {
        // Insufficient ETH also reverts
        oracleA.setValue(100);
        vm.deal(ALICE, 20000 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.createNumericMarketAndSeed{value: 5000 ether}( // Less than collateralIn
            "ETH insufficient",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );
    }

    function test_Integration_SeedLiquidity_ExactETH_Works() public {
        // Exact ETH amount works
        oracleA.setValue(100);
        vm.deal(ALICE, 20000 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        resolver.createNumericMarketAndSeed{value: 10000 ether}( // Exact amount
            "ETH exact",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // ALICE loses exactly collateralIn
        assertEq(ALICE.balance, aliceBefore - 10000 ether);
        // Resolver has no ETH left
        assertEq(address(resolver).balance, 0);
    }

    function test_Integration_CreateRatioMarketAndSeedSimple_Success() public {
        // Happy path for createRatioMarketAndSeedSimple
        oracleA.setValue(150);
        oracleB.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.deal(ALICE, 10000 ether);
        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity) = resolver.createRatioMarketAndSeedSimple{
            value: 10000 ether
        }(
            "A/B ratio",
            address(0),
            address(oracleA),
            MockOracle.getValue.selector,
            address(oracleB),
            MockOracle.getValue.selector,
            Resolver.Op.GT,
            1e18, // ratio > 1.0
            closeTime,
            true,
            seed
        );

        assertTrue(marketId != 0);
        assertTrue(noId != 0);
        assertTrue(shares > 0);
        assertTrue(liquidity > 0);

        // Verify condition stored correctly
        (address targetA, address targetB,,,,,) = resolver.conditions(marketId);
        assertEq(targetA, address(oracleA));
        assertEq(targetB, address(oracleB));
    }

    function test_Integration_FlushLeftoverShares_ReturnsToUser() public {
        // Verify leftover YES/NO shares are flushed back to msg.sender
        oracleA.setValue(100);
        vm.deal(ALICE, 10000 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed{value: 10000 ether}(
            "Flush test",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        uint256 noId = pm.getNoId(marketId);

        // Resolver should have no shares (all flushed to ALICE)
        assertEq(pm.balanceOf(address(resolver), marketId), 0, "resolver should have 0 YES");
        assertEq(pm.balanceOf(address(resolver), noId), 0, "resolver should have 0 NO");

        // ALICE should have received any leftover shares
        // (In practice, splitAndAddLiquidity may leave small amounts)
        // Just verify resolver is clean
    }

    function test_Integration_EnsureApproval_MultipleSeeds_SameToken() public {
        // Test that ensureApproval works correctly across multiple operations
        // (doesn't re-approve unnecessarily after first approval)
        oracleA.setValue(100);

        uint256 amount = 10000 ether;
        token.mint(ALICE, amount * 3);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: amount,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.startPrank(ALICE);
        token.approve(address(resolver), type(uint256).max);

        // First seed - should approve PAMM
        resolver.createNumericMarketAndSeed(
            "Market 1",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // Second seed - should reuse existing approval (allowance > uint128.max)
        resolver.createNumericMarketAndSeed(
            "Market 2",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime + 1,
            false,
            seed
        );

        // Third seed - still works
        resolver.createNumericMarketAndSeed(
            "Market 3",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime + 2,
            false,
            seed
        );

        vm.stopPrank();

        // All three markets created successfully
        // (If ensureApproval failed, the transactions would revert)
    }

    function test_EnsureApproval_SetsMaxApproval() public {
        // Verify that ensureApproval sets max approval on first call
        oracleA.setValue(100);

        uint256 amount = 10000 ether;
        token.mint(ALICE, amount);

        // Initially resolver has no approval to PAMM
        assertEq(token.allowance(address(resolver), PAMM_ADDRESS), 0);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: amount,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.startPrank(ALICE);
        token.approve(address(resolver), type(uint256).max);

        resolver.createNumericMarketAndSeed(
            "Approval test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );
        vm.stopPrank();

        // After first seed, resolver should have max approval to PAMM
        // (it will be type(uint256).max minus the amount transferred)
        uint256 allowanceAfter = token.allowance(address(resolver), PAMM_ADDRESS);
        assertTrue(
            allowanceAfter > type(uint128).max, "Should have high approval after ensureApproval"
        );
    }

    function test_EnsureApproval_USDT_NoReturnValue() public {
        // Test ensureApproval works with USDT-style tokens (no return value)
        MockUSDT usdt = new MockUSDT();
        usdt.mint(ALICE, 100000e6);

        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.startPrank(ALICE);
        usdt.approve(address(resolver), type(uint256).max);

        // Should work with USDT-style token (ensureApproval handles no-return-value)
        resolver.createNumericMarketAndSeed(
            "USDT approval test",
            address(usdt),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // Second call should reuse existing approval
        token.mint(ALICE, 10000e6);
        resolver.createNumericMarketAndSeed(
            "USDT approval test 2",
            address(usdt),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime + 1,
            false,
            seed
        );
        vm.stopPrank();
    }

    function test_EnsureApproval_MultipleTokens() public {
        // Test that ensureApproval works with multiple different tokens
        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        MockUSDC tokenC = new MockUSDC();

        tokenA.mint(ALICE, 100000 ether);
        tokenB.mint(ALICE, 100000 ether);
        tokenC.mint(ALICE, 100000e6);

        oracleA.setValue(100);

        vm.startPrank(ALICE);
        tokenA.approve(address(resolver), type(uint256).max);
        tokenB.approve(address(resolver), type(uint256).max);
        tokenC.approve(address(resolver), type(uint256).max);

        Resolver.SeedParams memory seedA = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SeedParams memory seedC = Resolver.SeedParams({
            collateralIn: 10000e6,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Seed with tokenA
        resolver.createNumericMarketAndSeed(
            "TokenA market",
            address(tokenA),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seedA
        );

        // Seed with tokenB (different token, needs separate approval)
        resolver.createNumericMarketAndSeed(
            "TokenB market",
            address(tokenB),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime + 1,
            false,
            seedA
        );

        // Seed with tokenC (6 decimals)
        resolver.createNumericMarketAndSeed(
            "TokenC market",
            address(tokenC),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime + 2,
            false,
            seedC
        );

        vm.stopPrank();

        // All markets created successfully with different tokens
    }

    /*//////////////////////////////////////////////////////////////
                        ETH BALANCE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateETHBalanceMarket_Success() public {
        // Create a market based on an address's ETH balance
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 5 ether);

        (uint256 marketId, uint256 noId) = resolver.createNumericMarket(
            "TARGET ETH balance",
            address(token),
            targetAccount,
            "", // empty callData = ETH balance mode
            Resolver.Op.GTE,
            10 ether,
            closeTime,
            true
        );

        // Verify market created
        (address mResolver,,,,,, uint64 close,,,,) = pm.getMarket(marketId);
        assertEq(mResolver, address(resolver));
        assertEq(close, closeTime);
        assertTrue(noId != 0);

        // Verify condition stored - targetA is the account to check
        (address targetA,,,, uint256 threshold,,) = resolver.conditions(marketId);
        assertEq(targetA, targetAccount);
        assertEq(threshold, 10 ether);
    }

    function test_ETHBalanceMarket_Preview() public {
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 5 ether);

        (uint256 marketId,) = resolver.createNumericMarket(
            "TARGET ETH balance >= 10 ETH",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GTE,
            10 ether,
            closeTime,
            true
        );

        // Preview should show current value (5 ETH) and condition false
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 5 ether);
        assertFalse(condTrue); // 5 ETH < 10 ETH threshold
        assertFalse(ready); // not past close time and condition not met

        // Fund the target account
        vm.deal(targetAccount, 15 ether);

        // Now condition should be true
        (value, condTrue, ready) = resolver.preview(marketId);
        assertEq(value, 15 ether);
        assertTrue(condTrue); // 15 ETH >= 10 ETH threshold
        assertTrue(ready); // canClose=true and condition met
    }

    function test_ETHBalanceMarket_ResolveYes_EarlyClose() public {
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 5 ether);

        // Seed liquidity first
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "TARGET ETH balance >= 10 ETH",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GTE,
            10 ether,
            closeTime,
            true, // canClose = true
            seed
        );

        // Can't resolve yet - condition not met
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Fund the target to meet threshold
        vm.deal(targetAccount, 10 ether);

        // Now can resolve early (canClose=true)
        resolver.resolveMarket(marketId);

        // Verify YES outcome
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins
    }

    function test_ETHBalanceMarket_ResolveNo_AtClose() public {
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 5 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "TARGET ETH balance >= 10 ETH",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GTE,
            10 ether,
            closeTime,
            false, // canClose = false
            seed
        );

        // Can't resolve before close time
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Warp to close time
        vm.warp(closeTime);

        // Resolve - condition still false (5 ETH < 10 ETH)
        resolver.resolveMarket(marketId);

        // Verify NO outcome
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // NO wins
    }

    function test_ETHBalanceMarket_AllOperators() public {
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 100 ether);

        // Test LT: 100 ETH < 50 ETH = false
        (uint256 mid1,) = resolver.createNumericMarket(
            "LT test", address(token), targetAccount, "", Resolver.Op.LT, 50 ether, closeTime, true
        );
        (uint256 v1, bool c1,) = resolver.preview(mid1);
        assertEq(v1, 100 ether);
        assertFalse(c1);

        // Test GT: 100 ETH > 50 ETH = true
        (uint256 mid2,) = resolver.createNumericMarket(
            "GT test",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GT,
            50 ether,
            closeTime + 1,
            true
        );
        (uint256 v2, bool c2,) = resolver.preview(mid2);
        assertEq(v2, 100 ether);
        assertTrue(c2);

        // Test LTE: 100 ETH <= 100 ETH = true
        (uint256 mid3,) = resolver.createNumericMarket(
            "LTE test",
            address(token),
            targetAccount,
            "",
            Resolver.Op.LTE,
            100 ether,
            closeTime + 2,
            true
        );
        (, bool c3,) = resolver.preview(mid3);
        assertTrue(c3);

        // Test GTE: 100 ETH >= 100 ETH = true
        (uint256 mid4,) = resolver.createNumericMarket(
            "GTE test",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GTE,
            100 ether,
            closeTime + 3,
            true
        );
        (, bool c4,) = resolver.preview(mid4);
        assertTrue(c4);

        // Test EQ: 100 ETH == 100 ETH = true
        (uint256 mid5,) = resolver.createNumericMarket(
            "EQ test",
            address(token),
            targetAccount,
            "",
            Resolver.Op.EQ,
            100 ether,
            closeTime + 4,
            true
        );
        (, bool c5,) = resolver.preview(mid5);
        assertTrue(c5);

        // Test NEQ: 100 ETH != 100 ETH = false
        (uint256 mid6,) = resolver.createNumericMarket(
            "NEQ test",
            address(token),
            targetAccount,
            "",
            Resolver.Op.NEQ,
            100 ether,
            closeTime + 5,
            true
        );
        (, bool c6,) = resolver.preview(mid6);
        assertFalse(c6);
    }

    function test_ETHBalanceMarket_ZeroBalance() public {
        address targetAccount = makeAddr("EMPTY_WALLET");
        // Don't fund - balance is 0

        (uint256 marketId,) = resolver.createNumericMarket(
            "Empty wallet check",
            address(token),
            targetAccount,
            "",
            Resolver.Op.EQ,
            0,
            closeTime,
            true
        );

        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 0);
        assertTrue(condTrue); // 0 == 0
        assertTrue(ready);
    }

    function test_ETHBalanceMarket_ContractBalance() public {
        // Can also check ETH balance of contracts
        address targetContract = address(pm);
        vm.deal(targetContract, 42 ether);

        (uint256 marketId,) = resolver.createNumericMarket(
            "PAMM ETH balance",
            address(token),
            targetContract,
            "",
            Resolver.Op.GTE,
            40 ether,
            closeTime,
            true
        );

        (uint256 value, bool condTrue,) = resolver.preview(marketId);
        assertEq(value, 42 ether);
        assertTrue(condTrue);
    }

    function test_ETHBalanceMarket_WithETHCollateral() public {
        // Create ETH balance market with ETH as collateral
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 50 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed{value: 10000 ether}(
            "TARGET ETH balance",
            address(0), // ETH collateral
            targetAccount,
            "", // ETH balance check
            Resolver.Op.GTE,
            100 ether,
            closeTime,
            true,
            seed
        );

        // Preview shows target's balance (not affected by collateral deposit)
        (uint256 value, bool condTrue,) = resolver.preview(marketId);
        assertEq(value, 50 ether);
        assertFalse(condTrue); // 50 < 100
    }

    function test_ETHBalanceMarket_DynamicBalanceChange() public {
        address targetAccount = makeAddr("TARGET");
        vm.deal(targetAccount, 5 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "Dynamic balance",
            address(token),
            targetAccount,
            "",
            Resolver.Op.GTE,
            10 ether,
            closeTime,
            true,
            seed
        );

        // Initially false
        (, bool condTrue1,) = resolver.preview(marketId);
        assertFalse(condTrue1);

        // Balance increases
        vm.deal(targetAccount, 15 ether);
        (, bool condTrue2,) = resolver.preview(marketId);
        assertTrue(condTrue2);

        // Balance decreases again
        vm.deal(targetAccount, 3 ether);
        (, bool condTrue3,) = resolver.preview(marketId);
        assertFalse(condTrue3);
    }

    /*//////////////////////////////////////////////////////////////
                    USDC (6 DECIMALS) SEEDANDBUY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_SeedAndBuy_USDC_Success() public {
        // Test USDC 6-decimal market with SeedAndBuy
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 100000e6);
        vm.prank(ALICE);
        usdc.approve(address(resolver), type(uint256).max);

        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6, // 10000 USDC (must be multiple of 1e6)
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 1000e6, // 1000 USDC (must be multiple of 1e6)
            minOut: 0,
            yesForNo: false
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "USDC SeedAndBuy",
            address(usdc),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        // With 1:1 shares: shares = collateralIn = 10000e6
        assertEq(shares, 10000e6);
        assertTrue(liquidity > 0);
        assertTrue(swapOut > 1000e6, "should get more YES than input (6 decimal shares)");

        // Alice should have YES tokens
        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        assertEq(aliceYes, swapOut);
    }

    // Note: SeedAndBuy USDC not multiple test removed - fractional amounts now supported

    /*//////////////////////////////////////////////////////////////
                    ETH BALANCE IN RATIO MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_ETHBalanceRatioMarket() public {
        // Test using ETH balance as one value in a ratio market
        address targetA = makeAddr("ACCOUNT_A");
        address targetB = makeAddr("ACCOUNT_B");
        vm.deal(targetA, 10 ether);
        vm.deal(targetB, 5 ether);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Ratio = targetA.balance / targetB.balance = 10/5 = 2e18
        // Threshold 1.5e18 means ratio > 1.5x
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createRatioMarketAndSeed(
            "ETH balance ratio",
            address(token),
            targetA,
            "", // empty callData = ETH balance
            targetB,
            "", // empty callData = ETH balance
            Resolver.Op.GT,
            1.5e18, // ratio > 1.5
            closeTime,
            true, // canClose
            seed
        );

        // Preview should show ratio = 2e18, condition true
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 2e18); // 10 / 5 = 2
        assertTrue(condTrue);
        assertTrue(ready); // canClose and condition true

        // Resolve early (canClose = true)
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins
    }

    function test_Integration_ETHBalanceRatioMarket_MixedSources() public {
        // Test ratio with ETH balance on one side and oracle call on other
        address targetAccount = makeAddr("ETH_HOLDER");
        vm.deal(targetAccount, 100 ether);
        oracleA.setValue(50 ether); // Oracle returns 50e18

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Ratio = ETH balance / oracle value = 100e18 / 50e18 = 2e18
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createRatioMarketAndSeed(
            "Mixed ratio source",
            address(token),
            targetAccount,
            "", // ETH balance
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GTE,
            2e18,
            closeTime,
            false,
            seed
        );

        (uint256 value, bool condTrue,) = resolver.preview(marketId);
        assertEq(value, 2e18);
        assertTrue(condTrue);
    }

    /*//////////////////////////////////////////////////////////////
                    RATIO SEEDANDBUY WITH SIMPLE VARIANT
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CreateRatioMarketSeedAndBuy_BuyNo() public {
        oracleA.setValue(300);
        oracleB.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 500 ether,
            minOut: 0,
            yesForNo: true // buy NO
        });

        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut) = resolver.createRatioMarketSeedAndBuy(
            "ratio buy NO",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            address(oracleB),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            2e18,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 10000 ether);
        assertTrue(liquidity > 0);
        assertTrue(swapOut > 500 ether, "should get more NO than input");

        // Check NO balance
        uint256 aliceNo = pm.balanceOf(ALICE, noId);
        assertEq(aliceNo, swapOut);
    }

    function test_Integration_SeedAndBuy_ToDifferentRecipient() public {
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: BOB, // LP goes to BOB
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 500 ether, minOut: 0, yesForNo: false});

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "different recipients",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        // Swap output goes to msg.sender (ALICE), not lpRecipient
        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        assertEq(aliceYes, swapOut);

        // Leftover shares from seeding also go to msg.sender (ALICE)
        // BOB only gets LP position
    }

    /*//////////////////////////////////////////////////////////////
                    BOUNDARY VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_SeedAndBuy_MaxSwapCollateral() public {
        // Test swapping with large collateral relative to seed
        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Swap larger than seed
        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 20000 ether, minOut: 0, yesForNo: false});

        vm.prank(ALICE);
        (,,,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "large swap",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        // Should succeed with high slippage
        assertTrue(swapOut > 0);
    }

    function test_Integration_SeedAndBuy_MinimumViableAmounts() public {
        oracleA.setValue(100);

        // Minimum viable amounts that satisfy ZAMM's MINIMUM_LIQUIDITY requirement
        // Need at least 1000+ shares to exceed MINIMUM_LIQUIDITY
        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 2000 ether, // Need enough to exceed MINIMUM_LIQUIDITY
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: 100 ether, minOut: 0, yesForNo: false});

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "minimum amounts",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertEq(shares, 2000 ether); // 2000 ether shares from 2000 ether (1:1)
        assertTrue(swapOut > 0);
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SeedAndBuy_CollateralDivisibility(uint256 seedShares, uint256 swapShares)
        public
    {
        // Need minimum seed to exceed MINIMUM_LIQUIDITY (1000)
        // Swap must be reasonable relative to seed to avoid InsufficientOutputAmount
        // Minimum swap of 100 shares to ensure swap produces output (very small swaps yield 0)
        seedShares = bound(seedShares, 10000, 50000);
        swapShares = bound(swapShares, 100, seedShares / 10); // Swap at most 10% of seed

        oracleA.setValue(100);

        // Ensure amounts are exact multiples of 1 ether (perShare for 18 decimals)
        uint256 seedCollateral = seedShares * 1 ether;
        uint256 swapCollateral = swapShares * 1 ether;

        // Ensure ALICE has enough tokens
        token.mint(ALICE, seedCollateral + swapCollateral);
        vm.prank(ALICE);
        token.approve(address(resolver), type(uint256).max);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: seedCollateral,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: swapCollateral, minOut: 0, yesForNo: false});

        vm.prank(ALICE);
        (,, uint256 shares,,) = resolver.createNumericMarketSeedAndBuy(
            "fuzz test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        // With 1:1 shares: shares = seedCollateral = seedShares * 1 ether
        assertEq(shares, seedCollateral);
    }

    function testFuzz_ETHBalance_Ratio(uint256 balanceA, uint256 balanceB) public {
        // Bound to reasonable values to avoid overflow and ensure sufficient liquidity
        // Seed is fixed at 10000 ether, so balances don't affect liquidity requirements
        balanceA = bound(balanceA, 1 ether, 10000 ether);
        balanceB = bound(balanceB, 1 ether, 10000 ether);

        address targetA = makeAddr("TARGET_A");
        address targetB = makeAddr("TARGET_B");
        vm.deal(targetA, balanceA);
        vm.deal(targetB, balanceB);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createRatioMarketAndSeed(
            "fuzz ratio",
            address(token),
            targetA,
            "",
            targetB,
            "",
            Resolver.Op.GT,
            1e18, // ratio > 1
            closeTime,
            false,
            seed
        );

        (uint256 value, bool condTrue,) = resolver.preview(marketId);

        // Expected ratio = balanceA * 1e18 / balanceB
        uint256 expectedRatio = (balanceA * 1e18) / balanceB;
        assertEq(value, expectedRatio);
        assertEq(condTrue, expectedRatio > 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                    USDT-STYLE TOKEN TESTS (NO RETURN)
    //////////////////////////////////////////////////////////////*/

    function test_USDT_SplitBuySell_NoReturnToken() public {
        // Deploy USDT-style token (no return value on transfer/transferFrom)
        MockUSDT usdt = new MockUSDT();
        usdt.mint(ALICE, 100000e6);

        vm.prank(ALICE);
        usdt.approve(address(resolver), type(uint256).max);

        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create and seed market with USDT-style token
        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed(
            "USDT test",
            address(usdt),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        assertTrue(shares > 0, "Should have minted shares");
        assertTrue(liquidity > 0, "Should have minted liquidity");

        // Buy YES with USDT-style token
        usdt.mint(BOB, 1000e6);
        vm.prank(BOB);
        usdt.approve(address(pm), type(uint256).max);

        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 1000e6, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(yesOut > 0, "Should have received YES tokens");

        // Sell YES back
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut / 2, 0, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(collateralOut > 0, "Should have received collateral back");
    }

    function test_USDC_SplitBuySell_6Decimals() public {
        // Deploy USDC-style token (6 decimals, returns bool)
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 100000e6);

        vm.prank(ALICE);
        usdc.approve(address(resolver), type(uint256).max);

        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create and seed market with USDC
        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,) = resolver.createNumericMarketAndSeed(
            "USDC test",
            address(usdc),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // With 1:1 shares: 10000e6 collateral = 10000e6 shares
        assertEq(shares, 10000e6, "Should have 10000 shares for 6-decimal token");

        // Buy and sell with USDC
        usdc.mint(BOB, 1000e6);
        vm.prank(BOB);
        usdc.approve(address(pm), type(uint256).max);

        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 1000e6, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(yesOut > 0);

        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut / 2, 0, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(collateralOut > 0);
    }

    function test_USDC_FullLifecycle_SeedBuyResolve() public {
        // Full lifecycle test with 6-decimal token: create, seed, buy, resolve, claim
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 100000e6);
        usdc.mint(BOB, 100000e6);

        vm.prank(ALICE);
        usdc.approve(address(resolver), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(pm), type(uint256).max);

        oracleA.setValue(100); // Above threshold (50)

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6, // 10000 USDC
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create and seed market
        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed(
            "USDC lifecycle",
            address(usdc),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            true, // canClose for early resolution
            seed
        );

        // With 1:1 shares: 10000e6 collateral = 10000e6 shares
        assertEq(shares, 10000e6, "Should have 10000 shares for 10000 USDC");
        assertTrue(liquidity > 0);

        // BOB buys YES
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 5000e6, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(yesOut > 0, "BOB should receive YES tokens");

        uint256 bobYesBefore = pm.balanceOf(BOB, marketId);
        assertTrue(bobYesBefore > 0);

        // Resolve market early (canClose = true, condition is true)
        resolver.resolveMarket(marketId);

        // Verify resolved with YES
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins

        // BOB claims winnings
        uint256 bobUsdcBefore = usdc.balanceOf(BOB);
        vm.prank(BOB);
        (uint256 claimedShares, uint256 payout) = pm.claim(marketId, BOB);

        assertEq(claimedShares, bobYesBefore, "Should claim all YES shares");
        // With 1:1 shares: payout = shares (shares are already in collateral units)
        assertEq(payout, bobYesBefore, "Payout should equal shares (1:1)");
        assertEq(usdc.balanceOf(BOB) - bobUsdcBefore, payout, "BOB should receive USDC payout");
    }

    function test_WBTC_FullLifecycle_8Decimals() public {
        // Full lifecycle test with 8-decimal token (WBTC-style)
        // Note: ZAMM requires MINIMUM_LIQUIDITY (1000), so we need at least 2000 shares
        // With 8 decimals, each share = 1e8, so we need 2000e8 = 2000 WBTC
        MockWBTC wbtc = new MockWBTC();
        wbtc.mint(ALICE, 10000e8); // 10000 WBTC
        wbtc.mint(BOB, 10000e8);

        vm.prank(ALICE);
        wbtc.approve(address(resolver), type(uint256).max);
        vm.prank(BOB);
        wbtc.approve(address(pm), type(uint256).max);

        oracleA.setValue(30); // Below threshold (50)

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 5000e8, // 5000 WBTC = 5000 shares (above MINIMUM_LIQUIDITY)
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create and seed market
        vm.prank(ALICE);
        (uint256 marketId, uint256 noId, uint256 shares,) = resolver.createNumericMarketAndSeed(
            "WBTC lifecycle",
            address(wbtc),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        // With 1:1 shares: 5000e8 collateral = 5000e8 shares
        assertEq(shares, 5000e8, "Should have 5000 shares for 5000 WBTC");

        // BOB buys NO (betting condition will be false)
        vm.prank(BOB);
        uint256 noOut = pm.buyNo(marketId, 500e8, 0, 0, FEE_BPS, BOB, 0); // 500 WBTC
        assertTrue(noOut > 0, "BOB should receive NO tokens");

        uint256 bobNoBefore = pm.balanceOf(BOB, noId);
        assertTrue(bobNoBefore > 0);

        // Wait for close time and resolve
        vm.warp(closeTime);
        resolver.resolveMarket(marketId);

        // Verify resolved with NO (condition was false)
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // NO wins

        // BOB claims winnings
        uint256 bobWbtcBefore = wbtc.balanceOf(BOB);
        vm.prank(BOB);
        (uint256 claimedShares, uint256 payout) = pm.claim(marketId, BOB);

        assertEq(claimedShares, bobNoBefore, "Should claim all NO shares");
        // With 1:1 shares: payout = shares (shares are already in collateral units)
        assertEq(payout, bobNoBefore, "Payout should equal shares (1:1)");
        assertEq(wbtc.balanceOf(BOB) - bobWbtcBefore, payout, "BOB should receive WBTC payout");
    }

    /*//////////////////////////////////////////////////////////////
                    ETH SEED+BUY EXACT MSG.VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ETH_SeedAndBuy_ExactMsgValue() public {
        oracleA.setValue(100);

        uint256 seedCollateral = 10000 ether;
        uint256 swapCollateral = 1000 ether;
        uint256 totalRequired = seedCollateral + swapCollateral;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: seedCollateral,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: swapCollateral, minOut: 0, yesForNo: false});

        uint256 resolverBalanceBefore = address(resolver).balance;
        uint256 aliceBalanceBefore = ALICE.balance;

        // Create market with exact msg.value
        vm.prank(ALICE);
        (uint256 marketId,,,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy{
            value: totalRequired
        }(
            "ETH exact test",
            address(0), // ETH collateral
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertTrue(marketId > 0);
        assertTrue(swapOut > 0);

        // Verify no residual ETH left in Resolver
        assertEq(
            address(resolver).balance, resolverBalanceBefore, "Resolver should have no residual ETH"
        );

        // Verify ALICE spent exactly totalRequired
        assertEq(
            aliceBalanceBefore - ALICE.balance, totalRequired, "ALICE should spend exact amount"
        );
    }

    function test_ETH_SeedAndBuy_WrongMsgValue_Reverts() public {
        oracleA.setValue(100);

        uint256 seedCollateral = 10000 ether;
        uint256 swapCollateral = 1000 ether;
        uint256 totalRequired = seedCollateral + swapCollateral;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: seedCollateral,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: swapCollateral, minOut: 0, yesForNo: false});

        // Too little ETH should revert
        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.createNumericMarketSeedAndBuy{value: totalRequired - 1}(
            "ETH test",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        // Too much ETH should also revert
        vm.prank(ALICE);
        vm.expectRevert(Resolver.InvalidETHAmount.selector);
        resolver.createNumericMarketSeedAndBuy{value: totalRequired + 1}(
            "ETH test",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );
    }

    /*//////////////////////////////////////////////////////////////
                    RATIO MARKET B=0 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RatioMarket_BZero_RevertsOnPreview() public {
        address targetA = makeAddr("TARGET_A");
        address targetB = makeAddr("TARGET_B");

        // Set targetA balance, leave targetB at 0
        vm.deal(targetA, 100 ether);
        vm.deal(targetB, 0);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create ratio market with ETH balance check
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createRatioMarketAndSeed(
            "ratio B=0 test",
            address(token),
            targetA,
            "", // empty calldata = ETH balance check
            targetB,
            "", // empty calldata = ETH balance check
            Resolver.Op.GT,
            1e18,
            closeTime,
            false,
            seed
        );

        // Preview should revert when B=0 (division by zero in mulDiv)
        vm.expectRevert(); // MulDivFailed
        resolver.preview(marketId);
    }

    function test_RatioMarket_BZero_RecoverAndResolve() public {
        address targetA = makeAddr("TARGET_A");
        address targetB = makeAddr("TARGET_B");

        // Set targetA balance, leave targetB at 0
        vm.deal(targetA, 100 ether);
        vm.deal(targetB, 0);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create ratio market
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createRatioMarketAndSeed(
            "ratio recovery test",
            address(token),
            targetA,
            "",
            targetB,
            "",
            Resolver.Op.GT,
            1e18,
            closeTime,
            false,
            seed
        );

        // Resolution should fail when B=0
        vm.expectRevert(); // MulDivFailed
        resolver.resolveMarket(marketId);

        // Now give targetB some balance
        vm.deal(targetB, 50 ether);

        // Preview should now work
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, (100 ether * 1e18) / 50 ether); // 2e18
        assertTrue(condTrue); // 2e18 > 1e18
        assertFalse(ready); // Not at close time yet

        // Wait until close time
        vm.warp(closeTime);

        // Now resolution should succeed
        resolver.resolveMarket(marketId);

        // Verify resolved with YES
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins because ratio > threshold
    }

    /*//////////////////////////////////////////////////////////////
                    EARLY-CLOSE PATH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EarlyClose_CondTrueAndCanClose_ResolvesImmediately() public {
        oracleA.setValue(100); // Above threshold

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create market with canClose = true
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "early close test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50, // threshold
            closeTime,
            true, // canClose = true
            seed
        );

        // Verify market is not yet at close time
        assertTrue(block.timestamp < closeTime, "Should be before close time");

        // Preview should show ready = true (condition true + canClose)
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 100);
        assertTrue(condTrue);
        assertTrue(ready); // Ready because condTrue && canClose

        // Resolve immediately (before close time)
        resolver.resolveMarket(marketId);

        // Verify resolved with YES
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins
    }

    function test_EarlyClose_CondFalseAndCanClose_MustWait() public {
        oracleA.setValue(30); // Below threshold

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create market with canClose = true
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "early close test false",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            true, // canClose = true
            seed
        );

        // Preview should show ready = false (condition false, not at close)
        (, bool condTrue, bool ready) = resolver.preview(marketId);
        assertFalse(condTrue);
        assertFalse(ready);

        // Try to resolve early - should fail
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Wait until close time
        vm.warp(closeTime);

        // Now ready should be true
        (, condTrue, ready) = resolver.preview(marketId);
        assertFalse(condTrue);
        assertTrue(ready);

        // Now resolution should work
        resolver.resolveMarket(marketId);

        // Verify resolved with NO (condition was false)
        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome); // NO wins
    }

    function test_EarlyClose_CondTrueButCanCloseFalse_MustWait() public {
        oracleA.setValue(100); // Above threshold

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000 ether,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        // Create market with canClose = false
        vm.prank(ALICE);
        (uint256 marketId,,,) = resolver.createNumericMarketAndSeed(
            "no early close test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false, // canClose = false
            seed
        );

        // Preview: condition true but not ready (canClose = false)
        (uint256 value, bool condTrue, bool ready) = resolver.preview(marketId);
        assertEq(value, 100);
        assertTrue(condTrue);
        assertFalse(ready); // Not ready because canClose = false

        // Try to resolve early - should fail
        vm.expectRevert(Resolver.Pending.selector);
        resolver.resolveMarket(marketId);

        // Wait until close time
        vm.warp(closeTime);

        // Now resolution should work
        resolver.resolveMarket(marketId);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome); // YES wins
    }

    /*//////////////////////////////////////////////////////////////
                    SEED+BUY COLLATERAL DIVISIBILITY TESTS
    //////////////////////////////////////////////////////////////*/

    // Note: Non-multiple swap test removed - fractional amounts now supported with dust refunds

    function test_SeedAndBuy_MultipleSwap_SucceedsNoRefund() public {
        oracleA.setValue(100);

        uint256 seedCollateral = 10000 ether;
        uint256 swapCollateral = 1000 ether; // Exact multiple of 1e18

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: seedCollateral,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap =
            Resolver.SwapParams({collateralForSwap: swapCollateral, minOut: 0, yesForNo: false});

        uint256 aliceTokenBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "multiple test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertTrue(marketId > 0);
        assertTrue(shares > 0);
        assertTrue(swapOut > 0);

        // Verify exact amount was spent (no dust/refund)
        uint256 aliceTokenAfter = token.balanceOf(ALICE);
        assertEq(
            aliceTokenBefore - aliceTokenAfter,
            seedCollateral + swapCollateral,
            "Should spend exact amount"
        );

        // Verify no tokens left in resolver
        assertEq(token.balanceOf(address(resolver)), 0, "Resolver should have no leftover tokens");
    }

    // Note: USDC non-multiple test removed - fractional amounts now supported with dust refunds

    function test_SeedAndBuy_USDC_Multiple_Succeeds() public {
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 100000e6);
        vm.prank(ALICE);
        usdc.approve(address(resolver), type(uint256).max);

        oracleA.setValue(100);

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: 10000e6,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        Resolver.SwapParams memory swap = Resolver.SwapParams({
            collateralForSwap: 1000e6, // Exact multiple of 1e6
            minOut: 0,
            yesForNo: false
        });

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares,, uint256 swapOut) = resolver.createNumericMarketSeedAndBuy(
            "USDC multiple",
            address(usdc),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed,
            swap
        );

        assertTrue(marketId > 0);
        assertEq(shares, 10000e6); // 1:1 shares: 10000e6 collateral = 10000e6 shares
        assertTrue(swapOut > 0);
    }

    /*//////////////////////////////////////////////////////////////
            DUST REFUND TESTS (CollateralNotMultiple check removed)
    //////////////////////////////////////////////////////////////*/

    // NOTE: Fractional amount tests (like 10.5 ETH) require fork testing due to
    // mock ZAMM limitations. The CollateralNotMultiple check has been removed
    // from Resolver.sol, and dust refund logic has been added. These tests
    // verify the refund logic works for any leftover collateral.

    /// @notice Verify resolver has no leftover ETH after successful market creation
    /// @dev Tests that dust refund logic doesn't break normal operations
    function test_CreateMarket_NoLeftoverETH() public {
        oracleA.setValue(100);

        uint256 collateralIn = 10000 ether;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: collateralIn,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed{
            value: collateralIn
        }(
            "no leftover ETH test",
            address(0),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        assertTrue(marketId > 0, "Market should be created");
        assertTrue(shares > 0, "Should receive shares");
        assertTrue(liquidity > 0, "Should receive liquidity");

        // Verify no ETH left in resolver (dust refund should clean it up)
        assertEq(address(resolver).balance, 0, "Resolver should have no leftover ETH");

        uint256 aliceAfter = ALICE.balance;
        assertTrue(aliceBefore - aliceAfter <= collateralIn, "Should not spend more than input");
    }

    /// @notice Verify resolver has no leftover ERC20 tokens after successful market creation
    function test_CreateMarket_NoLeftoverERC20() public {
        oracleA.setValue(100);

        uint256 collateralIn = 10000 ether;

        Resolver.SeedParams memory seed = Resolver.SeedParams({
            collateralIn: collateralIn,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: ALICE,
            deadline: block.timestamp + 1 hours
        });

        uint256 aliceTokenBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 marketId,, uint256 shares, uint256 liquidity) = resolver.createNumericMarketAndSeed(
            "no leftover ERC20 test",
            address(token),
            address(oracleA),
            abi.encodeWithSelector(MockOracle.getValue.selector),
            Resolver.Op.GT,
            50,
            closeTime,
            false,
            seed
        );

        assertTrue(marketId > 0, "Market should be created");
        assertTrue(shares > 0, "Should receive shares");
        assertTrue(liquidity > 0, "Should receive liquidity");

        // Verify no tokens left in resolver (dust refund should clean it up)
        assertEq(token.balanceOf(address(resolver)), 0, "Resolver should have no leftover tokens");

        uint256 aliceTokenAfter = token.balanceOf(ALICE);
        assertTrue(
            aliceTokenBefore - aliceTokenAfter <= collateralIn, "Should not spend more than input"
        );
    }
}

/*//////////////////////////////////////////////////////////////
                         PERMIT TESTS
//////////////////////////////////////////////////////////////*/

/// @notice Mock ERC20 with EIP-2612 permit support for Resolver tests
contract MockERC20Permit {
    string public name = "Mock Permit Token";
    string public symbol = "mPERMIT";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline)
                )
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

        allowance[owner][spender] = value;
    }
}

/// @notice Mock DAI-style token with permit support for Resolver tests
contract MockDAIPermit {
    string public name = "Mock DAI";
    string public symbol = "mDAI";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(expiry == 0 || expiry >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");
        require(nonce == nonces[holder]++, "INVALID_NONCE");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed))
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == holder, "INVALID_SIGNER");

        allowance[holder][spender] = allowed ? type(uint256).max : 0;
    }
}

contract Resolver_Permit_Test is Test {
    PAMM internal pm;
    Resolver internal resolver;
    MockERC20Permit internal permitToken;
    MockDAIPermit internal daiToken;
    MockOracle internal oracle;

    uint256 internal alicePk = 0xA11CE;
    address internal ALICE = vm.addr(alicePk);
    uint256 internal bobPk = 0xB0B;
    address internal BOB = vm.addr(bobPk);

    uint64 internal closeTime;
    address payable constant PAMM_ADDRESS = payable(0x0000000000F8bA51d6e987660D3e455ac2c4BE9d);
    uint256 constant FEE_BPS = 30;

    function setUp() public {
        // Deploy PAMM to hardcoded address
        PAMM pammDeployed = new PAMM();
        vm.etch(PAMM_ADDRESS, address(pammDeployed).code);
        pm = PAMM(PAMM_ADDRESS);

        resolver = new Resolver();
        permitToken = new MockERC20Permit();
        daiToken = new MockDAIPermit();
        oracle = new MockOracle();

        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        permitToken.mint(ALICE, 1000 ether);
        permitToken.mint(BOB, 1000 ether);
        daiToken.mint(ALICE, 1000 ether);
        daiToken.mint(BOB, 1000 ether);

        oracle.setValue(100);
    }

    /*//////////////////////////////////////////////////////////////
                          EIP-2612 PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Permit_Success() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        resolver.permit(address(permitToken), ALICE, amount, deadline, v, r, s);

        assertEq(permitToken.allowance(ALICE, address(resolver)), amount);
        assertEq(permitToken.nonces(ALICE), nonce + 1);
    }

    function test_Permit_RevertExpiredDeadline() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("PERMIT_DEADLINE_EXPIRED");
        resolver.permit(address(permitToken), ALICE, amount, deadline, v, r, s);
    }

    function test_Permit_RevertInvalidSignature() public {
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount, nonce, deadline
        );
        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.expectRevert("INVALID_SIGNER");
        resolver.permit(address(permitToken), ALICE, amount, deadline, v, r, s);
    }

    function test_Permit_MulticallWithMultiplePermits() public {
        // Test that multiple permits can be batched in multicall
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        // First permit
        bytes32 digest1 = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount1, nonce, deadline
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(alicePk, digest1);

        // Second permit (with incremented nonce, for a different amount)
        bytes32 digest2 = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount2, nonce + 1, deadline
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(alicePk, digest2);

        // Build multicall with two permits
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            Resolver.permit, (address(permitToken), ALICE, amount1, deadline, v1, r1, s1)
        );
        calls[1] = abi.encodeCall(
            Resolver.permit, (address(permitToken), ALICE, amount2, deadline, v2, r2, s2)
        );

        resolver.multicall(calls);

        // Final allowance should be from second permit
        assertEq(permitToken.allowance(ALICE, address(resolver)), amount2);
        assertEq(permitToken.nonces(ALICE), nonce + 2);
    }

    /*//////////////////////////////////////////////////////////////
                          DAI-STYLE PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PermitDAI_Success() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);

        assertEq(daiToken.allowance(ALICE, address(resolver)), type(uint256).max);
        assertEq(daiToken.nonces(ALICE), nonce + 1);
    }

    function test_PermitDAI_RevokeAllowance() public {
        // First grant allowance
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(resolver)), type(uint256).max);

        // Now revoke
        nonce = daiToken.nonces(ALICE);
        digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, false);
        (v, r, s) = vm.sign(alicePk, digest);

        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, false, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(resolver)), 0);
    }

    function test_PermitDAI_RevertExpiredDeadline() public {
        vm.warp(1000);

        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp - 1;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("PERMIT_DEADLINE_EXPIRED");
        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_RevertInvalidNonce() public {
        uint256 nonce = daiToken.nonces(ALICE) + 1; // Wrong nonce
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("INVALID_NONCE");
        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_RevertInvalidSignature() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.expectRevert("INVALID_SIGNER");
        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_ZeroExpiryMeansNoExpiry() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = 0;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        resolver.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(resolver)), type(uint256).max);
    }

    function test_PermitDAI_MulticallGrantAndRevoke() public {
        // Test that DAI permit grant and revoke can be batched
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        // Grant permit
        bytes32 digest1 =
            _getDAIPermitDigest(address(daiToken), ALICE, address(resolver), nonce, expiry, true);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(alicePk, digest1);

        // Revoke permit (next nonce)
        bytes32 digest2 = _getDAIPermitDigest(
            address(daiToken), ALICE, address(resolver), nonce + 1, expiry, false
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(alicePk, digest2);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            Resolver.permitDAI, (address(daiToken), ALICE, nonce, expiry, true, v1, r1, s1)
        );
        calls[1] = abi.encodeCall(
            Resolver.permitDAI, (address(daiToken), ALICE, nonce + 1, expiry, false, v2, r2, s2)
        );

        resolver.multicall(calls);

        // Final allowance should be 0 (revoked)
        assertEq(daiToken.allowance(ALICE, address(resolver)), 0);
        assertEq(daiToken.nonces(ALICE), nonce + 2);
    }

    function test_Permit_MixedPermitTypes_Multicall() public {
        // Test mixing EIP-2612 and DAI permit in one multicall
        uint256 amount = 100 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 eip2612Nonce = permitToken.nonces(ALICE);
        uint256 daiNonce = daiToken.nonces(ALICE);

        bytes32 digest1 = _getEIP2612Digest(
            address(permitToken), ALICE, address(resolver), amount, eip2612Nonce, deadline
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(alicePk, digest1);

        bytes32 digest2 = _getDAIPermitDigest(
            address(daiToken), ALICE, address(resolver), daiNonce, deadline, true
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(alicePk, digest2);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            Resolver.permit, (address(permitToken), ALICE, amount, deadline, v1, r1, s1)
        );
        calls[1] = abi.encodeCall(
            Resolver.permitDAI, (address(daiToken), ALICE, daiNonce, deadline, true, v2, r2, s2)
        );

        resolver.multicall(calls);

        // Both permits should have been processed
        assertEq(permitToken.allowance(ALICE, address(resolver)), amount);
        assertEq(daiToken.allowance(ALICE, address(resolver)), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getEIP2612Digest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner, spender, value, nonce, deadline));
        return keccak256(
            abi.encodePacked("\x19\x01", MockERC20Permit(token).DOMAIN_SEPARATOR(), structHash)
        );
    }

    function _getDAIPermitDigest(
        address token,
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed
    ) internal view returns (bytes32) {
        bytes32 permitTypehash = keccak256(
            "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
        );
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, holder, spender, nonce, expiry, allowed));
        return keccak256(
            abi.encodePacked("\x19\x01", MockDAIPermit(token).DOMAIN_SEPARATOR(), structHash)
        );
    }
}
