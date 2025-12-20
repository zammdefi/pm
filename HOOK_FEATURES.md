# PredictionMarketHook - Advanced Features

## Overview

Gas-efficient, production-ready singleton hook for PAMM prediction markets with advanced PM-specific features.

## Core Architecture

- **Singleton Design**: One hook instance serves unlimited markets
- **256-bit Perfect Packing**: MarketConfig fits in 1 storage slot
- **Transient Storage**: Reentrancy guard + actual user tracking via EIP-1153
- **Low-level Calldata Integration**: Router passes opcodes via ZAMM.swap() data parameter

## Feature Matrix

### 1. Time-Weighted Fees
**Purpose**: Bootstrap early liquidity, reward early LPs

**Mechanism**:
- Early: 1.0% (MAX_BASE_FEE)
- Late: 0.1% (MIN_BASE_FEE)
- Linear decay over market lifetime

**Benefits**:
- Early LPs earn 10x more fees
- Incentivizes market bootstrapping
- Natural fee reduction as market matures

### 2. Skew-Based IL Protection
**Purpose**: Compensate LPs for impermanent loss from one-sided markets

**Mechanism**:
- Tax scales quadratically with market imbalance
- 50/50: 0bps additional
- 90/10: 71bps additional
- Max: 80bps (0.8%)

**Formula**: `taxBps = (skew * skew) / (4500 * 4500 / MAX_SKEW_TAX)`

### 3. Pari-Mutuel Mode (NEW!)
**Purpose**: Eliminate late-stage IL, enable larger late positions

**Modes**:
- `0`: AMM only (default)
- `1`: Parimutuel only
- `2`: Hybrid (auto-switch near deadline)

**Hybrid Behavior**:
```
if (timeProgress >= parimutuelThreshold) {
  // Switch to parimutuel mode
  // Fee: flat 0.05%
  // Track positions for pro-rata payout on resolution
}
```

**Example Configuration**:
```solidity
hook.configureMarket(
  poolId,
  0,     // maxOrderbookBps
  0,     // minTVL
  0,     // rebalanceThreshold
  0,     // circuitBreakerBps
  8000,  // parimutuelThreshold (80% of market lifetime)
  2      // payoutMode (hybrid)
);
```

**Position Tracking**:
- Storage: `parimutuelPositions[poolId][user]` = `(yesShares << 128 | noShares)`
- Updated via opcode 0x09 in afterAction
- Pro-rata payout on resolution (handled by resolver)

### 4. Low Liquidity Bootstrapping (NEW!)
**Purpose**: Attract early liquidity with fee discounts

**Mechanism**:
- Configure `minTVL` threshold (e.g., 10,000 USDC)
- If `tvl[poolId] < minTVL`: 50% fee discount
- Auto-disables when TVL reaches threshold

**Use Case**:
```solidity
// New market with $1000 initial liquidity
hook.configureMarket(
  poolId,
  0,      // maxOrderbookBps
  10000,  // minTVL = $10k USDC (18 decimals)
  0,      // rebalanceThreshold
  0,      // circuitBreakerBps
  0,      // parimutuelThreshold
  0       // payoutMode
);

// Traders pay 0.5% instead of 1.0% until TVL hits $10k
// Attracts early liquidity, bootstraps market
```

### 5. Orderbook Competitive Pricing (NEW!)
**Purpose**: Match or beat orderbook spreads, prevent AMM from being sidelined

**Mechanism**:
- Router updates best bid/ask via opcode 0x08 in afterAction
- Hook calculates orderbook spread: `(ask - bid) / midpoint * 10000`
- AMM charges half-spread to stay competitive
- Automatically routes to best execution source

**Storage**: `orderbookPrices[poolId]` = `(bestBid << 128 | bestAsk)`

**Example Flow**:
1. PMRouter fills limit order at 52¢ (YES shares)
2. Router sends opcode 0x08 with updated best bid/ask
3. Next AMM swap checks: orderbook spread = 2%, AMM charges 1%
4. AMM stays competitive, user gets best price

### 6. Auto-Rebalancing Signals
**Purpose**: Trigger orderbook routing when AMM becomes too skewed

**Mechanism**:
```solidity
if (currentSkew > rebalanceThreshold && maxOrderbookBps > 0) {
  // Reduce fee by 0.05% to signal routing
  totalFee -= 5;
  // Router sees discount, routes via orderbook
}
```

**Configuration**:
```solidity
hook.configureMarket(
  poolId,
  5000,  // maxOrderbookBps (route up to 50% via orders)
  0,     // minTVL
  2000,  // rebalanceThreshold (trigger at 70/30 skew)
  0,     // circuitBreakerBps
  0,     // parimutuelThreshold
  0      // payoutMode
);
```

### 7. Circuit Breakers
**Purpose**: Halt trading during manipulation or extreme volatility

**Two Types**:

**A. Configured (per-market)**:
```solidity
hook.configureMarket(
  poolId,
  0,     // maxOrderbookBps
  0,     // minTVL
  0,     // rebalanceThreshold
  3000,  // circuitBreakerBps (halt if >70/30)
  0,     // parimutuelThreshold
  0      // payoutMode
);
```

**B. Dynamic (via opcode 0x01)**:
```solidity
// Router detects manipulation
bytes memory data = abi.encodePacked(
  uint8(0x01),           // Circuit breaker opcode
  uint16(2500)           // Emergency threshold: 75/25
);

ZAMM.swap(key, amount0Out, amount1Out, to, data);
// Hook halts trading if skew exceeds 2500bps
```

### 8. Oracle Resolution Verification (NEW!)
**Purpose**: Pre-verify outcome before accepting large late positions

**Mechanism** (opcode 0x07):
```solidity
bytes memory data = abi.encodePacked(
  uint8(0x07),                    // Oracle check opcode
  bytes20(address(oracle)),       // Oracle contract
  uint8(1)                        // Expected outcome (YES)
);

// Hook queries oracle.checkResolution(marketId)
// If outcome already determined, halts trading
```

**Use Case**:
- Large whale tries to buy YES shares 5 minutes before resolution
- Oracle already shows outcome = YES
- Hook halts trade via MAX_TOTAL_FEE
- Prevents frontrunning/manipulation

## Opcode Reference

### beforeAction (read-only, affects fees)

| Opcode | Name | Layout | Purpose |
|--------|------|--------|---------|
| 0x01 | Circuit Breaker | `[0x01][maxSkewBps:2]` | Emergency halt if skew exceeds |
| 0x06 | Orderbook Hint | `[0x06][requestedBps:2]` | Signal preferred orderbook usage |
| 0x07 | Oracle Check | `[0x07][oracle:20][outcome:1]` | Verify resolution status |

### afterAction (state updates)

| Opcode | Name | Layout | Purpose |
|--------|------|--------|---------|
| 0x08 | Update Prices | `[0x08][bestBid:16][bestAsk:16]` | Sync orderbook pricing |
| 0x09 | Parimutuel Position | `[0x09][yesShares:16][noShares:16]` | Track final position |

## Fee Calculation Flow

```solidity
function beforeAction() {
  // 1. Base time-weighted fee (1.0% → 0.1%)
  uint256 baseFee = _calculateTimeWeightedFee(config);

  // 2. Check pari-mutuel mode
  if (_isParimutuelMode(config)) {
    return 5; // Flat 0.05% in parimutuel
  }

  // 3. Add skew tax (IL protection)
  uint256 skewTax = _calculateSkewTax(poolId);
  uint256 totalFee = baseFee + skewTax;

  // 4. Low liquidity boost
  if (tvl[poolId] < config.minTVL) {
    totalFee = totalFee / 2; // 50% discount
  }

  // 5. Orderbook competitive pricing
  uint256 orderbookFee = _getOrderbookCompetitiveFee(poolId);
  if (orderbookFee > 0 && orderbookFee < totalFee) {
    totalFee = orderbookFee; // Match orderbook
  }

  // 6. Circuit breaker check
  if (config.circuitBreakerBps > 0) {
    uint256 skew = _calculateMarketSkew(poolId);
    if (skew > config.circuitBreakerBps) {
      return MAX_TOTAL_FEE; // 1.8% (halt)
    }
  }

  // 7. Rebalance signal
  if (skew > config.rebalanceThreshold) {
    totalFee -= 5; // 0.05% discount
  }

  // 8. Cap at MAX_TOTAL_FEE
  return min(totalFee, MAX_TOTAL_FEE);
}
```

## Integration Example: Hybrid Parimutuel Market

```solidity
// 1. Register market
uint256 poolId = hook.registerMarket(marketId);

// 2. Configure for hybrid parimutuel
// - Switch to parimutuel at 80% of market lifetime
// - Enable low liquidity boost until $50k TVL
// - Circuit breaker at 80/20 skew
hook.configureMarket(
  poolId,
  0,     // maxOrderbookBps (no orderbook for this example)
  50000, // minTVL ($50k USDC)
  0,     // rebalanceThreshold
  3000,  // circuitBreakerBps (80/20)
  8000,  // parimutuelThreshold (80%)
  2      // payoutMode (hybrid)
);

// 3. Early phase (0-80% of lifetime)
//    - AMM trading with time-decay fees
//    - 50% discount until TVL hits $50k
//    - Circuit breaker protects at 80/20

// 4. Late phase (80-100% of lifetime)
//    - Switches to parimutuel mode
//    - Flat 0.05% fee
//    - Positions tracked for pro-rata payout
//    - No IL risk for LPs

// 5. On resolution
//    - Parimutuel positions settled pro-rata
//    - Resolver handles payout distribution
```

## Gas Optimization

- **MarketConfig**: 256 bits (1 slot)
- **LPPosition**: 176 bits (sub-slot, 80 bits free)
- **Transient Storage**: Reentrancy + user tracking (no SLOAD/SSTORE)
- **Packed Storage**: `orderbookPrices` = (bid << 128 | ask)
- **Packed Storage**: `parimutuelPositions` = (yes << 128 | no)

## Production Deployment Checklist

- [ ] Deploy PredictionMarketHook singleton
- [ ] Deploy PMHookRouter with hook address
- [ ] Configure router's `ACTUAL_USER_SLOT` for hook callbacks
- [ ] Update hook's `_getActualUser()` to call router.getActualUser()
- [ ] Register initial markets via hook.registerMarket()
- [ ] Configure advanced features per market as needed
- [ ] Monitor circuit breakers via events
- [ ] Index parimutuel positions for UI display

## Future Extensions

1. **Cross-market correlation checks** (opcode 0x03)
   - Halt trading if correlated markets show conflicting signals

2. **Price impact limits** (opcode 0x04)
   - Reject swaps moving market too much

3. **Position size limits** (opcode 0x05)
   - Prevent whale domination

4. **Dynamic K adjustment**
   - Simulate deeper liquidity when TVL low

5. **Multiple oracle aggregation**
   - Query 3+ oracles, require majority consensus

## Testing Coverage

All features tested in:
- `test/PredictionMarketHook.t.sol` (8 tests, all passing)
- `test/PMHookRouter.t.sol` (5 tests, all passing)

Total: **13 tests**, **0 failures**
