# Uniswap V4 Fee Switch Prediction Market

## Overview

This implements a prediction market for when Uniswap V4 will activate protocol fees, using the existing `Resolver.sol` singleton to bet on whether `protocolFeeController()` returns a non-zero address.

## How It Works

### The Oracle Pattern

The UniV4 PoolManager contract at `0x000000000004444c5dc75cB358380D2e3dE08A90` has a `protocolFeeController()` function that returns an `address`:

```solidity
function protocolFeeController() external view returns (address);
```

Currently, this returns `address(0)`. When Uniswap activates protocol fees, it will return a non-zero address.

### Address as uint256

Here's the key insight: When `Resolver._readUint()` performs a staticcall and decodes the result as `uint256`:
- `address(0)` → decodes to `0`
- `address(0x1234...)` → decodes to `uint160(address)`, which is **always > 0**

This means we can use Resolver's numeric conditions to check if an address is non-zero!

### Market Setup

```solidity
resolver.createNumericMarketSimple(
    "Uniswap V4 protocolFeeController()",
    address(0),                                 // ETH collateral
    0x000000000004444c5dc75cB358380D2e3dE08A90, // UNIV4
    bytes4(keccak256("protocolFeeController()")),
    Resolver.Op.NEQ,                            // != 0
    0,                                          // threshold
    1767225599,                                 // deadline (end of 2025)
    true                                        // canClose early
);
```

### Resolution Logic

- **YES (true)**: `protocolFeeController() != 0` (fee switch activated)
- **NO (false)**: Controller remains `address(0)` through deadline
- **Early resolution**: If `canClose = true`, market can resolve as soon as condition becomes true

## Test Results

All tests pass on mainnet fork:

```
✅ Current state: protocolFeeController() = address(0) (uint256: 0)
✅ Condition evaluates correctly: false (since 0 != 0 is false)
✅ Market creation works with and without liquidity seeding
✅ Both Op.NEQ and Op.GT work identically for zero checks
✅ Fee switch simulation: When controller changes, value = uint160(address)
✅ Early resolution works when condition becomes true
✅ Normal resolution works after deadline
```

## Usage Examples

### Create Simple Market (No Liquidity)

```solidity
(uint256 marketId, uint256 noId) = resolver.createNumericMarketSimple(
    "Uniswap V4 protocolFeeController()",
    address(0),
    0x000000000004444c5dc75cB358380D2e3dE08A90,
    bytes4(0x91d14854), // protocolFeeController()
    Resolver.Op.NEQ,
    0,
    1767225599,
    true
);
```

### Create Market With Liquidity Seed

```solidity
Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 0.1 ether,
    feeOrHook: 0,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createNumericMarketAndSeedSimple{value: 0.1 ether}(
    "Uniswap V4 protocolFeeController()",
    address(0),
    0x000000000004444c5dc75cB358380D2e3dE08A90,
    bytes4(0x91d14854),
    Resolver.Op.NEQ,
    0,
    1767225599,
    true,
    seed
);
```

### Check Current State

```solidity
(uint256 value, bool conditionTrue, bool canResolve) = resolver.preview(marketId);

// value = 0 if controller is address(0)
// value = uint160(controller) if controller is non-zero
// conditionTrue = whether controller != 0
// canResolve = whether market can be resolved now
```

### Resolve Market

```solidity
// Anyone can call this once ready
resolver.resolveMarket(marketId);
```

## Why This Pattern is Powerful

This demonstrates that **any Solidity function returning an address can be used as a boolean condition** in Resolver.sol:

1. **ERC20 Ownership**: `token.owner() != address(0)`
2. **Governance Changes**: `dao.pendingAdmin() != address(0)`
3. **Upgradeable Contracts**: `proxy.implementation() != oldImplementation`
4. **Multi-sig Threshold**: `safe.owner(index) != address(0)` (checking if owner slot is filled)

The numeric Resolver isn't just for numbers - it works for **any data type that ABI-encodes to uint256**, including:
- `address` (uint160, zero-padded)
- `bool` (0 or 1)
- `enum` (uint8 values)
- `bytes32` (if you want to check specific values)

## Comparison to UniV4FeeSwitchPM

Original pattern (src/UniV4FeeSwitchPM.sol):
```solidity
// Custom contract per market type
contract UniV4FeeSwitchPM {
    function resolveBet(uint256 marketId) public {
        if (protocolFeeController() != address(0)) {
            IPAMM(PAMM).resolve(marketId, true);
        }
    }
}
```

Resolver pattern:
```solidity
// Singleton handles everything
resolver.createNumericMarketSimple(..., Op.NEQ, 0, ...)
// No custom contract needed!
```

## Files

- **Tests**: `/workspaces/pm/test/UniV4FeeSwitch.t.sol`
- **Deployment Script**: `/workspaces/pm/script/CreateUniV4Market.s.sol`
- **Core Contract**: `/workspaces/pm/src/Resolver.sol`

## Running Tests

```bash
# All tests
forge test --match-contract UniV4FeeSwitchTest -vv

# Specific test
forge test --match-test test_SimulateFeeSwitch -vvv

# With gas reporting
forge test --match-contract UniV4FeeSwitchTest --gas-report
```

## Deployment

```bash
# Dry run
forge script script/CreateUniV4Market.s.sol --rpc-url $RPC_URL

# Deploy
forge script script/CreateUniV4Market.s.sol --rpc-url $RPC_URL --broadcast --verify
```

## Key Insights

1. **Address → uint256 conversion works natively** in ABI encoding
2. **Zero address always equals zero** as uint256
3. **Any non-zero address is > 0** as uint256
4. **Resolver.sol is more flexible than initially obvious** - not just for numeric values!
5. **No custom resolver contracts needed** for simple address checks

This opens up a whole new class of prediction markets that can be created using the existing Resolver singleton! 🚀
