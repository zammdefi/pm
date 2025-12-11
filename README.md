# Prediction Markets — YES/NO Binary Markets

Minimal onchain mechanisms for binary prediction markets:

- **PAMM** — Collateral vault minting fully-collateralized YES/NO conditional tokens (ERC6909). Prices via ZAMM.
- **PM** — Pure parimutuel: buy/sell at par (1 wstETH = 1 share), winners split the pot.
- **Resolver** — On-chain oracle resolver for PAMM markets using arbitrary `staticcall` reads.
- **GasPM** — Gas price TWAP oracle with prediction market factory for "will gas exceed X gwei?" markets.

---

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| [PAMM](https://contractscan.xyz/contract/0x0000000000f8ba51d6e987660d3e455ac2c4be9d) | `0x0000000000f8ba51d6e987660d3e455ac2c4be9d` |
| [PM](https://contractscan.xyz/contract/0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e) | `0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e` |
| [Resolver](https://contractscan.xyz/contract/0x0000000000b0ba1b2bb3af96fbb893d835970ec4) | `0x0000000000b0ba1b2bb3af96fbb893d835970ec4` |
| [ZAMM](https://contractscan.xyz/contract/0x000000000000040470635EB91b7CE4D132D616eD) | `0x000000000000040470635EB91b7CE4D132D616eD` |
| [GasPM](https://contractscan.xyz/contract/0x0000000000faee9fee5d4d7255361c27ff2b3d1a) | `0x0000000000faee9fee5d4d7255361c27ff2b3d1a` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| ZSTETH | `0x000000000077B216105413Dc45Dc6F6256577c7B` |

---

## PAMM — Collateral Vault

A simple vault that locks collateral and mints conditional tokens.

### System Architecture

```
+----------------------------------------------------------------------+
|                      PAMM SYSTEM (Prediction AMM)                    |
|         Collateral vault for YES/NO tokens with AMM pricing          |
+----------------------------------------------------------------------+
|                                                                      |
|  +-------------+    +------------------------------------------+     |
|  |             |    |                  PAMM                    |     |
|  | COLLATERAL  |    |  +------------------------------------+  |     |
|  |   ETH or    |    |  |        Collateral Vault            |  |     |
|  |   ERC20     |    |  |  - Lock on split                   |  |     |
|  |             |    |  |  - Unlock on merge                 |  |     |
|  +------+------+    |  |  - Release on claim                |  |     |
|         |           |  +------------------------------------+  |     |
|         |   lock    |                   |                      |     |
|         +---------->|                   v                      |     |
|         |   unlock  |  +------------------------------------+  |     |
|         |<----------+  |       ERC6909 Token Registry       |  |     |
|         |           |  |  - YES tokens (marketId)           |  |     |
|  +------+------+    |  |  - NO tokens (noId)                |  |     |
|  |             |    |  |  - Transferable shares             |  |     |
|  |    USERS    |    |  +------------------------------------+  |     |
|  |  - Split    |    |                   |                      |     |
|  |  - Merge    |    +-------------------|----------------------+     |
|  |  - Buy/Sell |                        |                            |
|  |  - Claim    |                        v                            |
|  +-------------+    +------------------------------------------+     |
|                     |                  ZAMM                    |     |
|  +-------------+    |  +------------------------------------+  |     |
|  |  RESOLVERS  |    |  |        Liquidity Pools             |  |     |
|  |  - Resolve  |    |  |  - YES/NO pairs per market         |  |     |
|  |  - Set fee  |    |  |  - Price discovery via x*y=k       |  |     |
|  |  - Close    |    |  |  - Onchain orderbook               |  |     |
|  +-------------+    |  +------------------------------------+  |     |
|                     +------------------------------------------+     |
|                                                                      |
+----------------------------------------------------------------------+
```

### Market Lifecycle

```
    CREATE                    TRADING                     RESOLVE              CLAIM
       │                         │                           │                   │
       ▼                         ▼                           ▼                   ▼
┌─────────────┐    ┌─────────────────────────┐    ┌─────────────────┐    ┌─────────────┐
│  resolver   │    │   block.timestamp       │    │    resolver     │    │   winners   │
│  creates    │───►│   < close               │───►│    calls        │───►│   burn      │
│  market     │    │                         │    │    resolve()    │    │   tokens    │
└─────────────┘    │  • split/merge          │    │                 │    │   for       │
                   │  • buy/sell             │    │  outcome =      │    │   collateral│
                   │  • add/remove liquidity │    │  YES or NO      │    └─────────────┘
                   └─────────────────────────┘    └─────────────────┘
```

### Mechanics

| Action | What happens |
|--------|--------------|
| **Split** | Lock `N * 10^decimals` collateral → mint `N` YES + `N` NO |
| **Merge** | Burn `N` YES + `N` NO → unlock `N * 10^decimals` collateral |
| **Claim** | After resolution: burn `N` winning tokens → receive `N * 10^decimals` collateral (minus resolver fee if set) |

Shares are whole units. Collateral conversion uses the token's decimals (18 for ETH).

### Operation Flows

#### Split Flow
```
┌──────────┐     1 ETH      ┌──────────┐
│   User   │ ──────────────►│   PAMM   │
└──────────┘                └──────────┘
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
              ┌──────────┐              ┌──────────┐
              │  1 YES   │              │  1 NO    │
              │  token   │              │  token   │
              └──────────┘              └──────────┘
                    │                         │
                    └────────────┬────────────┘
                                 ▼
                           ┌──────────┐
                           │   User   │
                           └──────────┘
```

#### Merge Flow
```
              ┌──────────┐              ┌──────────┐
              │  1 YES   │              │  1 NO    │
              │  token   │              │  token   │
              └──────────┘              └──────────┘
                    │                         │
                    └────────────┬────────────┘
                                 ▼
┌──────────┐                ┌──────────┐
│   User   │ ◄──────────────│   PAMM   │
└──────────┘     1 ETH      └──────────┘
```

#### Buy YES Flow (split + swap)
```
┌──────────┐     1 ETH      ┌──────────┐                ┌──────────┐
│   User   │ ──────────────►│   PAMM   │ ── 1 NO ─────► │   ZAMM   │
└──────────┘                └──────────┘                └──────────┘
                                 │                           │
                              1 YES                      ~1 YES
                              (from                      (from
                              split)                     swap)
                                 │                           │
                                 └───────────┬───────────────┘
                                             ▼
                                       ┌──────────┐
                                       │  ~2 YES  │
                                       │  to User │
                                       └──────────┘
```

#### Sell YES Flow (swap + merge)
```
┌──────────┐    2 YES       ┌──────────┐                ┌──────────┐
│   User   │ ──────────────►│   PAMM   │ ── 1 YES ────► │   ZAMM   │
└──────────┘                └──────────┘                └──────────┘
                                 │                           │
                              1 YES                       ~1 NO
                              (kept)                      (from
                                 │                        swap)
                                 │                           │
                                 └───────────┬───────────────┘
                                             ▼
                                    ┌────────────────┐
                                    │ merge 1 YES +  │
                                    │ 1 NO → 1 ETH   │
                                    │ to User        │
                                    └────────────────┘
```

#### Claim Flow (after resolution)
```
                            Market resolved: YES wins

┌──────────┐   10 YES       ┌──────────┐
│  Winner  │ ──────────────►│   PAMM   │
└──────────┘   (burn)       └──────────┘
                                 │
                                 ▼
                            ┌──────────┐
                            │ 10 ETH   │
                            │ (minus   │
                            │  fee)    │
                            └──────────┘
                                 │
                                 ▼
                            ┌──────────┐
                            │  Winner  │
                            └──────────┘
```

#### Add Liquidity Flow
```
┌──────────┐     2 ETH      ┌──────────┐   2 YES + 2 NO  ┌──────────┐
│   User   │ ──────────────►│   PAMM   │ ──────────────► │   ZAMM   │
└──────────┘                └──────────┘    (deposit)    └──────────┘
                                                              │
                                                         LP tokens
                                                              │
                                                              ▼
                                                        ┌──────────┐
                                                        │   User   │
                                                        └──────────┘
```

### Collateral

Supports ETH (`address(0)`) or any ERC20. Decimals are read from the token at market creation.

### Trading

PAMM has no internal pricing—prices are determined by ZAMM pool reserves. Use:
- `buyYes()`/`buyNo()` to buy shares with collateral (splits + swaps)
- `sellYes()`/`sellNo()` to sell shares for collateral (swaps + merges)
- `splitAndAddLiquidity()` to seed a new ZAMM pool atomically

### Functions

```solidity
// Lifecycle
createMarket(description, resolver, collateral, close, canClose) → (marketId, noId)
createMarketAndSeed(description, resolver, collateral, close, canClose,
                    collateralIn, feeOrHook, minLiquidity, to, deadline) → (marketId, noId, liquidity)
closeMarket(marketId)                    // resolver early-close (if canClose)
resolve(marketId, outcome)               // resolver sets winner

// Core
split(marketId, collateralIn, to)        → (shares, used)
merge(marketId, shares, to)              → (merged, collateralOut)
claim(marketId, to)                      → (shares, payout)
claimMany(marketIds[], to)               → totalPayout

// Buy/Sell (split+swap or swap+merge via ZAMM)
buyYes(marketId, collateralIn, minYesOut, minSwapOut, feeOrHook, to, deadline) → yesOut
buyNo(marketId, collateralIn, minNoOut, minSwapOut, feeOrHook, to, deadline) → noOut
sellYes(marketId, yesAmount, swapAmount, minCollateralOut, minSwapOut, feeOrHook, to, deadline) → collateralOut
sellNo(marketId, noAmount, swapAmount, minCollateralOut, minSwapOut, feeOrHook, to, deadline) → collateralOut
sellYesForExactCollateral(marketId, collateralOut, maxYesIn, maxSwapIn, feeOrHook, to, deadline) → yesSpent
sellNoForExactCollateral(marketId, collateralOut, maxNoIn, maxSwapIn, feeOrHook, to, deadline) → noSpent

// ZAMM LP helpers
splitAndAddLiquidity(marketId, collateralIn, feeOrHook, amount0Min, amount1Min,
                     minLiquidity, to, deadline) → (shares, liquidity)
removeLiquidityToCollateral(marketId, feeOrHook, liquidity, amount0Min, amount1Min,
                            minCollateralOut, to, deadline) → (collateralOut, leftoverYes, leftoverNo)
poolKey(marketId, feeOrHook)             // returns ZAMM PoolKey struct

// Resolver
setResolverFeeBps(bps)                   // max 1000 (10%)

// Utility
multicall(bytes[] data)                  // batch multiple calls
permit(token, owner, value, deadline, v, r, s)       // EIP-2612 permit
permitDAI(token, owner, nonce, deadline, allowed, v, r, s)  // DAI-style permit

// Views
getMarket(marketId)
getMarkets(start, count)
getUserPositions(user, start, count)
getPoolState(marketId, feeOrHook)        // ZAMM pool reserves + implied prob
tradingOpen(marketId)
winningId(marketId)
collateralPerShare(marketId)
marketCount()
tokenURI(id)                             // NFT-compatible metadata URI
```

### ID Derivation

```
marketId (YES) = keccak256("PMARKET:YES", description, resolver, collateral)
noId           = keccak256("PMARKET:NO", marketId)
```

---

## PM — Pure Parimutuel

Classic parimutuel betting with wstETH.

### Mechanics

**Before close:**
- Buy: deposit wstETH (or ETH) → mint shares 1:1
- Sell: burn shares → withdraw wstETH 1:1

**After resolution:**
- Winners split the pot: `payout = shares * pot / winningSupply`
- If either side has zero supply → **refund mode** (all shares redeem 1:1)

### Resolver Fee

Resolvers can set a fee (max 10%) via `setResolverFeeBps(bps)`. Fee is deducted from pot at resolution.

### Functions

```solidity
// Lifecycle
createMarket(description, resolver, close, canClose) → (marketId, noId)
closeMarket(marketId)                    // resolver early-close (if canClose)
resolve(marketId, outcome)               // sets winner, calculates payoutPerShare

// Trading (before close)
buyYes(marketId, amount, to)             // accepts ETH or wstETH
buyNo(marketId, amount, to)
sellYes(marketId, amount, to)
sellNo(marketId, amount, to)

// Settlement
claim(marketId, to)

// Resolver
setResolverFeeBps(bps)                   // max 1000 (10%)

// Views
getMarket(marketId)
getMarkets(start, count)
getUserMarkets(user, start, count)
tradingOpen(marketId)
impliedYesOdds(marketId)                 → (yesSupply, total)  // YES prob ≈ yesSupply/total
winningId(marketId)
marketCount()
```

### ID Derivation

```
marketId (YES) = keccak256("PMARKET:YES", description, resolver)
noId           = keccak256("PMARKET:NO", marketId)
```

---

## Comparison

| | PAMM | PM |
|-|------|-----|
| Collateral | Any ERC20 or ETH | wstETH only |
| Payout | 1 winning share = 10^decimals collateral | Winners split pot pro-rata |
| Price discovery | AMM (ZAMM pools) | None (shares trade at par) |
| Resolver fee | Up to 10% (deducted at claim) | Up to 10% (deducted at resolution) |
| Refund mode | N/A (fully collateralized) | If one side has 0 supply |

---

## Resolver Contract

An on-chain oracle resolver for PAMM markets based on arbitrary `staticcall` reads.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         RESOLVER + PAMM INTEGRATION                         │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐                                        ┌──────────────────┐
  │   ORACLES    │                                        │      USERS       │
  │              │                                        │                  │
  │ • Chainlink  │                                        │ • Trade YES/NO   │
  │ • Uniswap    │                                        │ • Add liquidity  │
  │ • Custom     │                                        │ • Claim winnings │
  └──────┬───────┘                                        └────────┬─────────┘
         │ staticcall                                              │
         │ (read price)                                            │
         ▼                                                         ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                              RESOLVER                                   │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                        CONDITIONS                               │    │
  │  │  marketId → { target, callData, op, threshold, isRatio }        │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  │                                                                         │
  │  CREATE MARKET:                      RESOLVE MARKET:                    │
  │  1. Build description                1. Read oracle value               │
  │  2. Call PAMM.createMarket()         2. Compare to threshold            │
  │  3. Store condition                  3. Delete condition                │
  │  4. Optionally seed LP               4. Call PAMM.resolve(outcome)      │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  │ createMarket / resolve / closeMarket
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                PAMM                                     │
  │  ┌───────────────────┐    ┌───────────────────┐    ┌─────────────────┐  │
  │  │  Collateral Vault │    │   ERC6909 Tokens  │    │   Market State  │  │
  │  │  • Lock on split  │    │   • YES (marketId)│    │   • resolver    │  │
  │  │  • Unlock on merge│    │   • NO  (noId)    │    │   • resolved    │  │
  │  │  • Release claim  │    │   • Transferable  │    │   • outcome     │  │
  │  └───────────────────┘    └───────────────────┘    └─────────────────┘  │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
                                  │ swap / addLiquidity / removeLiquidity
                                  ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                ZAMM                                     │
  │                      YES/NO Liquidity Pools                             │
  │                      Price discovery via x*y=k                          │
  └─────────────────────────────────────────────────────────────────────────┘
```

### Lifecycle Flow

```
    CREATE                    TRADING                   RESOLVE              CLAIM
       │                         │                         │                   │
       ▼                         ▼                         ▼                   ▼
┌─────────────┐    ┌─────────────────────────┐    ┌─────────────────┐   ┌───────────┐
│  Resolver   │    │   Anyone can trade      │    │    Anyone       │   │  Winners  │
│  creates    │───►│   YES/NO via PAMM       │───►│    calls        │──►│  claim    │
│  market +   │    │                         │    │    Resolver     │   │  from     │
│  condition  │    │  • buyYes / buyNo       │    │    .resolve()   │   │  PAMM     │
└─────────────┘    │  • sellYes / sellNo     │    │                 │   └───────────┘
      │            │  • add/remove liquidity │    │  Oracle check:  │
      │            └─────────────────────────┘    │  value OP thres │
      │                                           └─────────────────┘
      │  Optional: Seed LP
      │  ┌─────────────────────────────────┐
      └─►│ splitAndAddLiquidity via PAMM   │
         │ + optional buyYes/buyNo skew    │
         └─────────────────────────────────┘
```

### Condition Types

| Type | Formula | Threshold |
|------|---------|-----------|
| **Scalar** | `value = staticcall(target, callData)` | Raw uint256 |
| **Ratio** | `value = (A * 1e18) / B` | 1e18-scaled (e.g., 1.5x = 1.5e18) |
| **ETH Balance** | `value = target.balance` | Wei (pass empty `callData`) |

> **Boolean Support:** Functions returning `bool` work natively—the EVM encodes `false` as `0` and `true` as `1`. Use `Op.EQ` with `threshold=1` for "is true" or `threshold=0` for "is false".

### Resolution Semantics

- **YES wins**: condition is true at resolution time
- **NO wins**: condition is false at/after close time
- `canClose=true`: allows early resolution when condition becomes true
- `canClose=false`: must wait until close time regardless

### Operators

| Op | Symbol | Meaning |
|----|--------|---------|
| `LT` | `<` | Less than |
| `GT` | `>` | Greater than |
| `LTE` | `<=` | Less than or equal |
| `GTE` | `>=` | Greater than or equal |
| `EQ` | `==` | Equal |
| `NEQ` | `!=` | Not equal |

### Functions

```solidity
// Create markets (scalar conditions)
createNumericMarket(observable, collateral, target, callData, op, threshold, close, canClose)
createNumericMarketSimple(observable, collateral, target, selector, op, threshold, close, canClose)
createNumericMarketAndSeed(..., SeedParams)      // + LP seeding
createNumericMarketSeedAndBuy(..., SeedParams, SwapParams)  // + initial position

// Create markets (ratio conditions)
createRatioMarket(observable, collateral, targetA, callDataA, targetB, callDataB, op, threshold, close, canClose)
createRatioMarketSimple(...)   // with bytes4 selectors
createRatioMarketAndSeed(...)  // + LP seeding
createRatioMarketSeedAndBuy(...)  // + initial position

// Register conditions for existing PAMM markets
registerConditionForExistingMarket(marketId, target, callData, op, threshold)
registerConditionForExistingMarketSimple(marketId, target, selector, op, threshold)
registerRatioConditionForExistingMarket(marketId, targetA, callDataA, targetB, callDataB, op, threshold)
registerRatioConditionForExistingMarketSimple(marketId, targetA, selectorA, targetB, selectorB, op, threshold)

// Resolution
resolveMarket(marketId)   // Anyone can call when ready
preview(marketId) → (value, condTrue, ready)  // Check resolution status

// Utility
multicall(bytes[] data)   // Batch operations
permit(token, owner, value, deadline, v, r, s)  // EIP-2612 permit
permitDAI(token, owner, nonce, deadline, allowed, v, r, s)  // DAI-style permit
buildDescription(...)     // Preview auto-generated description
```

### Structs

```solidity
struct SeedParams {
    uint256 collateralIn;   // Must be divisible by 10^decimals
    uint256 feeOrHook;      // ZAMM fee tier or hook address
    uint256 amount0Min;     // Slippage protection
    uint256 amount1Min;
    uint256 minLiquidity;
    address lpRecipient;
    uint256 deadline;
}

struct SwapParams {
    uint256 collateralForSwap;  // Amount for buyYes/buyNo
    uint256 minOut;             // Minimum tokens out
    bool yesForNo;              // true = buyNo, false = buyYes
}
```

### Collateral

| Type | Usage |
|------|-------|
| **ETH** | Pass `address(0)`, send exact `msg.value` |
| **ERC20** | Approve resolver first, `msg.value` must be 0 |

For `SeedAndBuy` with ETH: `msg.value = seed.collateralIn + swap.collateralForSwap`

### Complete Examples

#### SeedParams Setup (used in all seeded examples)

```solidity
Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 10 ether,       // Must be divisible by 10^decimals
    feeOrHook: 30,                // ZAMM fee tier (30 = 0.3%)
    amount0Min: 0,                // Slippage protection
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,      // Who receives LP tokens
    deadline: block.timestamp + 1 hours
});
```

#### 1. Price Prediction with ETH Collateral (Chainlink)

```solidity
// "ETH > $5000 by Dec 31, 2025"
// YES wins if price exceeds $5000 at any point (canClose=true)

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 10 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createNumericMarketAndSeed{value: 10 ether}(
    "ETH/USD price",
    address(0),                                    // ETH collateral
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,    // Chainlink ETH/USD
    abi.encodeWithSignature("latestAnswer()"),     // returns int256 (works as uint256 for prices)
    Resolver.Op.GT,
    5000e8,                                        // $5000 (Chainlink uses 8 decimals)
    1735689600,                                    // Dec 31, 2025 Unix timestamp
    true,                                          // early close allowed
    seed
);
```

#### 2. Token Supply with ERC20 Collateral (USDC)

```solidity
// "USDC supply > 50B by June 2025"

address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
IERC20(USDC).approve(address(resolver), 10000e6);

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 10000e6,        // 10,000 USDC (6 decimals)
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createNumericMarketAndSeed(              // No {value} for ERC20
    "USDC total supply",
    USDC,                                          // USDC as collateral
    USDC,                                          // target = USDC contract
    abi.encodeWithSignature("totalSupply()"),
    Resolver.Op.GT,
    50_000_000_000e6,                              // 50B (6 decimals)
    1719792000,                                    // June 30, 2025
    true,
    seed
);
```

#### 3. Create + Seed + Take Position (SeedAndBuy)

```solidity
// Create market, seed LP, and immediately buy YES in one transaction

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 10 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

Resolver.SwapParams memory swap = Resolver.SwapParams({
    collateralForSwap: 2 ether,   // Buy tokens with 2 ETH
    minOut: 0,                    // Minimum tokens out (slippage)
    yesForNo: false               // false = buyYes, true = buyNo
});

// msg.value = seed.collateralIn + swap.collateralForSwap
resolver.createNumericMarketSeedAndBuy{value: 12 ether}(
    "ETH/USD price",
    address(0),
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
    abi.encodeWithSignature("latestAnswer()"),
    Resolver.Op.GT,
    4000e8,
    1735689600,
    true,
    seed,
    swap
);
```

#### 4. ETH Balance Prediction (Empty callData)

```solidity
// "Vitalik holds > 100k ETH"
// Pass empty callData ("") to check target's ETH balance

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 5 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createNumericMarketAndSeed{value: 5 ether}(
    "vitalik.eth ETH balance",
    address(0),
    0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045,    // vitalik.eth
    "",                                            // empty = ETH balance check
    Resolver.Op.GT,
    100_000 ether,                                 // 100k ETH in wei
    1735689600,
    true,
    seed
);
```

#### 5. Ratio Market (Governance Vote)

```solidity
// "Proposal passes (forVotes > againstVotes)"
// Ratio = forVotes / againstVotes, threshold 1e18 = 1.0

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 10 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createRatioMarketAndSeed{value: 10 ether}(
    "Proposal 42 vote ratio",
    address(0),
    GOVERNOR,                                      // targetA: forVotes
    abi.encodeWithSignature("proposalVotes(uint256)", 42),
    GOVERNOR,                                      // targetB: againstVotes
    abi.encodeWithSignature("proposalAgainst(uint256)", 42),
    Resolver.Op.GT,
    1e18,                                          // ratio > 1.0 means forVotes > againstVotes
    1704067200,                                    // voting end timestamp
    false,                                         // must wait for vote to end
    seed
);
```

#### 6. Boolean Condition (Protocol Paused)

```solidity
// "Protocol gets paused"
// bool paused() returns true (1) or false (0)

Resolver.SeedParams memory seed = Resolver.SeedParams({
    collateralIn: 5 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

resolver.createNumericMarketAndSeed{value: 5 ether}(
    "Protocol paused status",
    address(0),
    PROTOCOL_ADDRESS,
    abi.encodeWithSignature("paused()"),           // returns bool
    Resolver.Op.EQ,
    1,                                             // true == 1
    1735689600,
    true,                                          // YES wins immediately when paused
    seed
);
```

#### 7. Market Without LP (No Seed)

```solidity
// Create market only, no liquidity seeding
// Anyone can add liquidity later via PAMM.splitAndAddLiquidity()

(uint256 marketId, uint256 noId) = resolver.createNumericMarket(
    "ETH/USD price",
    address(0),                                    // ETH collateral
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
    abi.encodeWithSignature("latestAnswer()"),
    Resolver.Op.GT,
    5000e8,
    1735689600,
    true
);
```

#### 8. Simple Selector Version (bytes4)

```solidity
// Use bytes4 selector instead of full calldata (for no-argument functions)

resolver.createNumericMarketAndSeedSimple{value: 10 ether}(
    "ETH/USD price",
    address(0),
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
    bytes4(keccak256("latestAnswer()")),           // just 4-byte selector
    Resolver.Op.GT,
    5000e8,
    1735689600,
    true,
    seed
);
```

### User Stories

| User | Goal | Configuration |
|------|------|---------------|
| **Trader** | Bet on ETH reaching $10k | Scalar, GT, canClose=true |
| **Hedger** | Insure against stablecoin depeg | Scalar, LT, canClose=true |
| **DAO** | Prediction market for governance | Ratio (for/against), canClose=false |
| **Protocol** | TVL milestone incentive | Scalar, GTE, canClose=true |
| **Analyst** | Compare protocol metrics | Ratio, any operator |
| **Insurance** | Payout if protocol pauses | Boolean (EQ 1), canClose=true |
| **Whale watcher** | Bet on wallet accumulation | ETH Balance, GTE, canClose=true |

### Configuration Guide

| Scenario | `canClose` | Why |
|----------|------------|-----|
| Price target | `true` | Resolve immediately when hit |
| End-of-period snapshot | `false` | Must check value at deadline |
| Race condition | `true` | First to threshold wins |
| Governance vote | `false` | Wait for voting period to end |
| Insurance/hedge | `true` | Trigger payout on bad event |

### Notes

- `SeedAndBuy` does NOT set target odds—it takes an initial position that skews the pool
- Multicall with multiple ETH seeds is not supported (use separate txs or ERC20)
- Leftover YES/NO shares from seeding are flushed back to caller

---

## GasPM — Gas Price Oracle & Market Factory

A TWAP (Time-Weighted Average Price) oracle for Ethereum's `block.basefee` with integrated prediction market creation. Supports both bullish ("gas will spike") and bearish ("gas will stay low") markets.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GasPM SYSTEM                                  │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐                                        ┌──────────────────┐
  │   KEEPERS    │                                        │      USERS       │
  │              │                                        │                  │
  │ • Call       │                                        │ • Create markets │
  │   update()   │                                        │ • Trade YES/NO   │
  │ • Earn       │                                        │ • Claim winnings │
  │   rewards    │                                        │                  │
  └──────┬───────┘                                        └────────┬─────────┘
         │ update()                                                │
         │ (record basefee)                                        │
         ▼                                                         ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                              GasPM                                    │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                    TWAP ORACLE                                  │    │
  │  │  • cumulativeBaseFee  (running sum of fee*time)                 │    │
  │  │  • baseFeeAverage()   (cumulative / totalTime)                  │    │
  │  │  • trackingDuration() (seconds since deploy)                    │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  │                                                                         │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                   MARKET FACTORY                                │    │
  │  │  • createMarket() → Resolver → PAMM                             │    │
  │  │  • Tracks all markets in _markets[]                             │    │
  │  │  • getMarketInfos() for dapp display                            │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  └───────────────────────────────────────┬─────────────────────────────────┘
                                          │
                                          │ createNumericMarketAndSeedSimple
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                              RESOLVER                                   │
  │  • Stores condition: baseFeeAverage() >= threshold                      │
  │  • Anyone can resolve when ready                                        │
  └───────────────────────────────────────┬─────────────────────────────────┘
                                          │
                                          ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                                PAMM                                     │
  │  • YES/NO tokens • Liquidity pools via ZAMM • Claims                    │
  └─────────────────────────────────────────────────────────────────────────┘
```

### How TWAP Works

```
Time ─────────────────────────────────────────────►
     │         │              │              │
     T0        T1             T2             T3
     │         │              │              │
     └─ Deploy └─ update()    └─ update()    └─ Query
        50gwei    (100gwei)      (75gwei)       baseFeeAverage()

cumulativeBaseFee = 50*(T1-T0) + 100*(T2-T1) + 75*(T3-T2)
baseFeeAverage    = cumulativeBaseFee / (T3 - T0)
```

The TWAP includes **pending time** even without updates—it uses `lastBaseFee` for unrecorded periods.

### Reward System

Incentivizes regular oracle updates:

```solidity
// Owner configures rewards
oracle.setReward(0.001 ether, 1 hours);  // Pay 0.001 ETH per update, min 1hr cooldown
oracle.receive{value: 10 ether}();       // Fund the contract

// Keepers call update() and receive rewards
// - Reward paid only if elapsed >= cooldown
// - Cooldown prevents rapid draining
```

### Market Creation

Create prediction markets with two directions:
- **GTE (>=)**: "Will average gas exceed X gwei?" — Bullish on congestion
- **LTE (<=)**: "Will average gas stay below X gwei?" — Bearish on gas / bullish on scaling

#### Bullish Market: "Gas will spike above 50 gwei"

```solidity
// op=3 (GTE): YES wins if baseFeeAverage >= 50 gwei
oracle.createMarket{value: 10 ether}(
    50 gwei,                      // threshold in wei (50 gwei target)
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp (Dec 31, 2025)
    true,                         // canClose (early resolution if condition met)
    3,                            // op: 3=GTE (>=), 2=LTE (<=)
    10 ether,                     // collateralIn (liquidity to seed)
    30,                           // feeOrHook (30 bps = 0.3% ZAMM fee)
    0,                            // minLiquidity (slippage protection)
    msg.sender                    // lpRecipient
);
// Observable: "Avg Ethereum base fee >= 50 gwei"
```

#### Bearish Market: "Gas will stay below 30 gwei"

```solidity
// op=2 (LTE): YES wins if baseFeeAverage <= 30 gwei
oracle.createMarket{value: 10 ether}(
    30 gwei,                      // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    false,                        // canClose=false (check at deadline only)
    2,                            // op: 2=LTE (<=)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Avg Ethereum base fee <= 30 gwei"
```

#### With Skewed Odds (SeedAndBuy)

```solidity
// Create market + take position to set initial odds away from 50/50
GasPM.SeedParams memory seed = GasPM.SeedParams({
    collateralIn: 10 ether,
    feeOrHook: 30,
    amount0Min: 0,
    amount1Min: 0,
    minLiquidity: 0,
    lpRecipient: msg.sender,
    deadline: block.timestamp + 1 hours
});

GasPM.SwapParams memory swap = GasPM.SwapParams({
    collateralForSwap: 2 ether,   // Additional collateral to buy position
    minOut: 0,
    yesForNo: false               // false = buyYes, true = buyNo
});

// msg.value = seed.collateralIn + swap.collateralForSwap = 12 ether
oracle.createMarketAndBuy{value: 12 ether}(
    50 gwei,                      // threshold in wei
    address(0),                   // ETH collateral
    uint64(1735689600),
    true,                         // canClose
    3,                            // op: GTE
    seed,
    swap
);
```

#### Range Market: "Gas will stay between 30-70 gwei"

```solidity
// Range market: YES wins if 30 <= baseFeeAverage <= 70 gwei
oracle.createRangeMarket{value: 10 ether}(
    30 gwei,                      // lower bound in wei (inclusive)
    70 gwei,                      // upper bound in wei (inclusive)
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    false,                        // canClose=false (check at deadline)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Avg Ethereum base fee between 30-70 gwei"
```

#### Breakout Market: "Gas will leave the 30-70 gwei range"

```solidity
// Breakout market: YES wins if baseFeeAverage < 30 OR > 70 gwei
// Use canClose=true to get early payout when breakout occurs
oracle.createBreakoutMarket{value: 10 ether}(
    30 gwei,                      // lower bound in wei
    70 gwei,                      // upper bound in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    true,                         // canClose=true (early close on breakout!)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Avg Ethereum base fee outside 30-70 gwei"
```

#### Peak Market: "Gas will spike to 100 gwei (since oracle deployment)"

```solidity
// Peak market: YES wins if baseFeeMax >= 100 gwei at any point since deployment
// Uses historical max, not TWAP — captures extreme spikes
oracle.createPeakMarket{value: 10 ether}(
    100 gwei,                     // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    true,                         // canClose=true (instant payout when peak hit!)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee spikes to 100 gwei"
```

#### Trough Market: "Gas will dip to 10 gwei (since oracle deployment)"

```solidity
// Trough market: YES wins if baseFeeMin <= 10 gwei at any point since deployment
// Uses historical min — captures extreme dips
oracle.createTroughMarket{value: 10 ether}(
    10 gwei,                      // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    true,                         // canClose=true (instant payout when dip occurs!)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee dips to 10 gwei"
```

#### Volatility Market: "Gas will swing by 50 gwei"

```solidity
// Volatility market: YES wins if baseFeeSpread (max - min) >= 50 gwei
// Bets on high volatility - gas swings between extremes
oracle.createVolatilityMarket{value: 10 ether}(
    50 gwei,                      // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    true,                         // canClose=true (instant payout when volatility hits!)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee swings 50 gwei"
```

#### Stability Market: "Gas will stay calm (less than 20 gwei swing)"

```solidity
// Stability market: YES wins if baseFeeSpread (max - min) <= 20 gwei
// Opposite of volatility - bets on calm, stable gas prices
oracle.createStabilityMarket{value: 10 ether}(
    20 gwei,                      // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    false,                        // canClose=false (check at deadline only)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee stays within 20 gwei spread"
```

#### Spot Market: "Will gas be high at resolution?"

```solidity
// Spot market: YES wins if baseFeeCurrent >= 100 gwei at resolution
// Uses live block.basefee, not TWAP - best for high thresholds
oracle.createSpotMarket{value: 10 ether}(
    100 gwei,                     // threshold in wei
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    true,                         // canClose=true (instant payout when threshold hit!)
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee spot price reaches 100 gwei"
```

#### Comparison Market: "Will gas be higher at close than now?"

```solidity
// Comparison market: YES wins if TWAP at close > TWAP at creation
// Snapshots current TWAP, compares at resolution
oracle.createComparisonMarket{value: 10 ether}(
    address(0),                   // collateral (ETH)
    uint64(1735689600),          // close timestamp
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Ethereum base fee TWAP higher than 50 gwei start"
```

#### ERC20 Collateral

```solidity
// With USDC as collateral
IERC20(USDC).approve(address(oracle), 10000e6);
oracle.createMarket(
    50 gwei,                      // threshold in wei
    USDC,                         // collateral (ERC20)
    uint64(1735689600),
    true,
    3,                            // op: GTE
    10000e6,                      // 10,000 USDC
    30,
    0,
    msg.sender
);
```

#### Window Markets: "What happens DURING this market?"

Window markets track TWAP from market creation, not from oracle deployment. This makes them useful for betting on gas behavior during a specific time period.

```solidity
// Window Market: "Gas average will exceed 50 gwei DURING THIS MARKET"
// TWAP calculated from market creation, not oracle deploy
oracle.createWindowMarket{value: 10 ether}(
    50 gwei,                      // threshold
    address(0),
    uint64(block.timestamp + 7 days),  // 1 week market
    true,                         // canClose on condition
    3,                            // op: GTE
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Avg gas during market >= 50 gwei"

// Window Peak: "Will gas hit 100 gwei DURING THIS MARKET?"
// Reverts if maxBaseFee >= 100 gwei (threshold already hit)
oracle.createWindowPeakMarket{value: 10 ether}(
    100 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
    true,                         // instant payout on spike
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas spikes to 100 gwei during market"

// Window Trough: "Will gas dip to 10 gwei DURING THIS MARKET?"
// Reverts if minBaseFee <= 10 gwei (threshold already hit)
oracle.createWindowTroughMarket{value: 10 ether}(
    10 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
    true,                         // instant payout on dip
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas dips to 10 gwei during market"

// Window Volatility: "Will gas spread exceed 30 gwei DURING THIS MARKET?"
// Tracks absolute spread (max - min) during the market window
// Call pokeWindowVolatility(marketId) periodically to capture extremes
oracle.createWindowVolatilityMarket{value: 10 ether}(
    30 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
    true,                         // instant payout when spread hits threshold
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas spread exceeds 30 gwei during market"

// Window Stability: "Will gas spread stay below 10 gwei DURING THIS MARKET?"
// Tracks absolute spread (max - min) during the market window
oracle.createWindowStabilityMarket{value: 10 ether}(
    10 gwei,                      // max 10 gwei spread allowed
    address(0),
    uint64(block.timestamp + 7 days),
    false,                        // check at deadline only
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas spread stays below 10 gwei during market"
```

#### Permit + Multicall (Gasless Approvals)

```solidity
// Use permit to approve + create market in one tx
bytes[] memory calls = new bytes[](2);
calls[0] = abi.encodeCall(oracle.permit, (token, msg.sender, amount, deadline, v, r, s));
calls[1] = abi.encodeCall(oracle.createMarket, (...));
oracle.multicall(calls);
```

### Functions

```solidity
// TWAP Oracle (Lifetime)
update()                          // Record current basefee, earn reward if eligible
baseFeeAverage() → uint256        // TWAP in wei (since deploy)
baseFeeAverageGwei() → uint256    // TWAP in gwei
baseFeeInRange(lower, upper) → uint256     // Returns 1 if TWAP in range (bounds in wei)
baseFeeOutOfRange(lower, upper) → uint256  // Returns 1 if TWAP outside range (bounds in wei)
baseFeeCurrent() → uint256        // Spot basefee in wei
baseFeeCurrentGwei() → uint256    // Spot basefee in gwei
baseFeeMax() → uint256            // Highest basefee ever recorded (wei)
baseFeeMin() → uint256            // Lowest basefee ever recorded (wei)
baseFeeSpread() → uint256         // Volatility: max - min (wei)
trackingDuration() → uint256      // Seconds since oracle deployed

// TWAP Oracle (Window / Market-Specific)
baseFeeAverageSince(marketId) → uint256    // TWAP since market creation (wei)
baseFeeInRangeSince(marketId, lower, upper) → uint256     // Returns 1 if window TWAP in range
baseFeeOutOfRangeSince(marketId, lower, upper) → uint256  // Returns 1 if window TWAP outside range
baseFeeSpreadSince(marketId) → uint256     // Absolute spread (max - min) during market window
baseFeeHigherThanStart(marketId) → uint256 // Returns 1 if TWAP > start (comparison markets)
pokeWindowVolatility(marketId)             // Update window market's max/min to current basefee
pokeWindowVolatilityBatch(marketIds[])     // Batch update multiple window markets

// Lifetime Market Creation (all thresholds/bounds in wei)
createMarket(threshold, collateral, close, canClose, op,
             collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createMarketAndBuy(threshold, collateral, close, canClose, op,
                   SeedParams, SwapParams) → (marketId, swapOut)
createRangeMarket(lower, upper, collateral, close, canClose,
                  collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createRangeMarketAndBuy(lower, upper, collateral, close, canClose,
                        SeedParams, SwapParams) → (marketId, swapOut)
createBreakoutMarket(lower, upper, collateral, close, canClose,
                     collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createPeakMarket(threshold, collateral, close, canClose,
                 collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createTroughMarket(threshold, collateral, close, canClose,
                   collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createVolatilityMarket(threshold, collateral, close, canClose,
                       collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createStabilityMarket(threshold, collateral, close, canClose,
                      collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createSpotMarket(threshold, collateral, close, canClose,
                 collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createComparisonMarket(collateral, close,
                       collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId

// Window Market Creation (TWAP calculated from market creation)
createWindowMarket(threshold, collateral, close, canClose, op,
                   collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowMarketAndBuy(threshold, collateral, close, canClose, op,
                         SeedParams, SwapParams) → (marketId, swapOut)
createWindowRangeMarket(lower, upper, collateral, close, canClose,
                        collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowRangeMarketAndBuy(lower, upper, collateral, close, canClose,
                              SeedParams, SwapParams) → (marketId, swapOut)
createWindowBreakoutMarket(lower, upper, collateral, close, canClose,
                           collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowPeakMarket(threshold, collateral, close, canClose,
                       collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowTroughMarket(threshold, collateral, close, canClose,
                         collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowVolatilityMarket(threshold, collateral, close, canClose,
                             collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId
createWindowStabilityMarket(threshold, collateral, close, canClose,
                            collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId

// Market Views (for dapp)
marketCount() → uint256
getMarkets(start, count) → uint256[]
getMarketInfos(start, count) → MarketInfo[]
isOurMarket(marketId) → bool
marketSnapshots(marketId) → (cumulative, timestamp)  // Window market snapshot

// Owner Functions
setReward(rewardAmount, cooldown)
setPublicCreation(enabled)        // Allow anyone to create markets
withdraw(to, amount)
transferOwnership(newOwner)

// Utility
multicall(bytes[] data)           // Batch multiple calls
permit(token, owner, value, deadline, v, r, s)       // EIP-2612 permit
permitDAI(token, owner, nonce, deadline, allowed, v, r, s)  // DAI-style permit
```

### Resolver Operators

The Resolver uses 3 comparison operators:

| Op Value | Symbol | Meaning |
|----------|--------|---------|
| `2` | `<=` (LTE) | Less than or equal |
| `3` | `>=` (GTE) | Greater than or equal |
| `4` | `==` (EQ) | Equal (for boolean returns) |

### Market Type Identifiers (Event `op` field)

The `MarketCreated` event emits a market type identifier for UI indexing:

| Type | Value | Description |
|------|-------|-------------|
| Directional LTE | `2` | TWAP <= threshold |
| Directional GTE | `3` | TWAP >= threshold |
| Range | `4` | TWAP in [lower, upper] |
| Breakout | `5` | TWAP outside (lower, upper) |
| Peak | `6` | Max basefee >= threshold |
| Trough | `7` | Min basefee <= threshold |
| Volatility | `8` | Spread (max-min) >= threshold |
| Stability | `9` | Spread (max-min) <= threshold |
| Spot | `10` | Current basefee >= threshold |
| Comparison | `11` | TWAP higher than start |

### Structs

```solidity
struct SeedParams {
    uint256 collateralIn;   // Liquidity to seed
    uint256 feeOrHook;      // ZAMM fee tier (30 = 0.3%)
    uint256 amount0Min;     // Slippage protection
    uint256 amount1Min;
    uint256 minLiquidity;
    address lpRecipient;
    uint256 deadline;
}

struct SwapParams {
    uint256 collateralForSwap;  // Additional collateral for position
    uint256 minOut;             // Minimum tokens out
    bool yesForNo;              // true = buyNo (swap yes for no), false = buyYes (swap no for yes)
}
```

### MarketInfo Struct

```solidity
struct MarketInfo {
    uint256 marketId;
    uint64 close;           // Market close timestamp
    bool resolved;          // Has market been resolved
    bool outcome;           // YES (true) or NO (false)
    uint256 currentValue;   // Current baseFeeAverage()
    bool conditionMet;      // Is threshold currently exceeded
    bool ready;             // Can be resolved now
}
```

### User Stories

| Role | Goal | Action |
|------|------|--------|
| **Gas Bull** | Bet lifetime TWAP will spike | `createMarket(50, ..., op=3)` — GTE market |
| **Gas Bear** | Bet lifetime TWAP stays low | `createMarket(20, ..., op=2)` — LTE market |
| **Range Trader** | Bet TWAP stays in normal range | `createRangeMarket(30, 70, ...)` — stability bet |
| **Breakout Hedger** | Insure against TWAP volatility | `createBreakoutMarket(30, 70, ..., canClose=true)` |
| **Peak Speculator** | Bet gas will ever spike to 100 gwei | `createPeakMarket(100, ..., canClose=true)` — touch market |
| **Trough Hunter** | Bet gas will ever dip to 10 gwei | `createTroughMarket(10, ..., canClose=true)` — dip market |
| **Volatility Trader** | Bet gas will swing by 50 gwei | `createVolatilityMarket(50, ..., canClose=true)` — spread bet |
| **Stability Trader** | Bet gas stays calm (< 20 gwei swing) | `createStabilityMarket(20, ..., canClose=false)` — calm bet |
| **Window Trader** | Bet gas avg DURING market exceeds 50 | `createWindowMarket(50, ..., op=3)` — fresh TWAP |
| **Window Peak** | Bet gas spikes to 100 DURING market | `createWindowPeakMarket(100, ...)` — local spike bet |
| **Window Trough** | Bet gas dips to 10 DURING market | `createWindowTroughMarket(10, ...)` — local dip bet |
| **Window Vol** | Bet gas spread exceeds 30 gwei DURING market | `createWindowVolatilityMarket(30, ...)` — window volatility bet |
| **Window Calm** | Bet gas spread stays < 10 gwei DURING market | `createWindowStabilityMarket(10, ...)` — window stability bet |
| **Spot Trader** | Bet gas >= 100 gwei at resolution | `createSpotMarket(100, ..., canClose=true)` — instant spot |
| **Trend Trader** | Bet TWAP will be higher at close | `createComparisonMarket(...)` — relative bet |
| **Odds Skewer** | Create market with non-50/50 odds | `createMarketAndBuy(...)` — buy position at creation |
| **Keeper** | Earn rewards for oracle upkeep | Call `update()` regularly |
| **LP Provider** | Earn fees from gas market trading | Seed liquidity via `createMarket` |
| **Dapp** | Display gas prediction markets | Query `getMarketInfos()` |

### Resolution Flow

```
1. Anyone calls Resolver.resolveMarket(marketId)
2. Resolver calls GasPM oracle function based on stored callData:
   - Directional: baseFeeAverage()
   - Range: baseFeeInRange(lower, upper)
   - Breakout: baseFeeOutOfRange(lower, upper)
   - Peak: baseFeeMax()
   - Trough: baseFeeMin()
   - Volatility/Stability (lifetime): baseFeeSpread()
   - Volatility/Stability (window): baseFeeSpreadSince(marketId)
   - Spot: baseFeeCurrent()
   - Comparison: baseFeeHigherThanStart(marketId)
   - Window directional: baseFeeAverageSince(marketId)
   - Window range: baseFeeInRangeSince(marketId, lower, upper)
   - Window breakout: baseFeeOutOfRangeSince(marketId, lower, upper)
3. Compare result against threshold using stored operator:
   - GTE (op=3): value >= threshold
   - LTE (op=2): value <= threshold
   - EQ (op=4): value == threshold (used for boolean functions returning 1/0)
4. If condition TRUE: YES shareholders win
   If condition FALSE: NO shareholders win
5. Winners claim collateral via PAMM
```

### Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `publicCreation` | `false` | Only owner can create markets |
| `rewardAmount` | `0` | ETH paid per `update()` call |
| `cooldown` | `0` | Minimum seconds between rewards |

### Notes

- **Wei precision**: All thresholds accept wei values, supporting up to 3 decimal places of gwei (e.g., `0.127 gwei = 127000000 wei`). Observable strings display user-friendly gwei format.
- **Lifetime vs Window markets**: Lifetime markets use TWAP since oracle deploy; Window markets use TWAP since market creation (fresh slate for each market)
- **Window Peak/Trough**: These revert if threshold already met, ensuring market is about future events
- TWAP starts from contract deployment timestamp (not resettable — manipulation-resistant)
- Peak/Trough track historical max/min since deployment (also manipulation-resistant)
- Collateral can be ETH or any ERC20 (USDC, USDT, WBTC, etc.)
- Markets support directional, range, breakout, peak, trough, volatility, stability, spot, and comparison types
- **Volatility/Stability (lifetime)**: Use `baseFeeSpread()` (max - min) to bet on price swings vs calm markets
- **Volatility/Stability (window)**: Use `baseFeeSpreadSince()` which tracks absolute spread (max - min) during the market window. Call `pokeWindowVolatility(marketId)` periodically to capture extremes between blocks.
- **Spot markets**: Use `baseFeeCurrent()` for live price at resolution - best for high thresholds
- **Comparison markets**: Snapshot TWAP at creation, bet on whether it increases by close
- `canClose=true` allows early resolution when condition is met
- `canClose=false` waits until close timestamp to check condition
- Peak/Trough markets with `canClose=true` provide instant payout when threshold is touched
- **AndBuy variants**: Use `createMarketAndBuy`, `createRangeMarketAndBuy`, etc. to seed liquidity and take an initial position to skew odds
- **Permit support**: Use `permit()` or `permitDAI()` for gasless ERC20 approvals
- **Multicall**: Batch multiple calls (e.g., permit + createMarket) in one transaction
- ETH multicall with multiple markets is NOT supported (strict msg.value)
- Event `MarketCreated` includes `op` for easy indexing by market type

---

## Collateral Support

Both PAMM and Resolver support multiple collateral types:

| Decimals | Token Examples | Notes |
|----------|----------------|-------|
| 18 | ETH, wstETH, DAI | 1 share = 1e18 collateral units |
| 6 | USDC, USDT | 1 share = 1e6 collateral units |
| 8 | WBTC | 1 share = 1e8 collateral units |

**Important:** ZAMM requires `MINIMUM_LIQUIDITY` (1000 shares) to be locked when creating a pool. For tokens with fewer decimals, this means higher collateral requirements:
- 18 decimals: ~0.002 ETH minimum to seed
- 6 decimals: ~0.002 USDC minimum to seed
- 8 decimals: ~0.00002 BTC minimum to seed

The system also supports non-standard ERC20s:
- **USDT-style** (no return value on transfer)
- **Fee-on-transfer tokens** (not recommended, may cause accounting issues)

---

## Error Reference

### PAMM Errors

| Error | Description |
|-------|-------------|
| `AmountZero` | Zero amount provided |
| `FeeOverflow` | Resolver fee > 10000 bps (100%) |
| `NotClosable` | closeMarket called but canClose=false |
| `InvalidClose` | Close time in the past |
| `MarketClosed` | Trading attempted after close time or resolution |
| `MarketExists` | Market with same parameters already exists |
| `OnlyResolver` | Caller is not the market's resolver |
| `ExcessiveInput` | Input exceeds allowed maximum |
| `MarketNotFound` | Invalid marketId |
| `DeadlineExpired` | Transaction deadline passed |
| `InvalidReceiver` | Receiver is address(0) |
| `InvalidResolver` | Resolver address is zero |
| `AlreadyResolved` | Market already resolved |
| `InvalidDecimals` | Token has 0 or invalid decimals |
| `MarketNotClosed` | Claim attempted before close/resolution |
| `InvalidETHAmount` | msg.value doesn't match required amount |
| `InvalidCollateral` | Invalid collateral address |
| `InvalidSwapAmount` | Swap amount exceeds available |
| `InsufficientOutput` | Slippage protection triggered |
| `CollateralTooSmall` | Collateral doesn't convert to at least 1 share |
| `WrongCollateralType` | ETH sent for ERC20 market or vice versa |

### Resolver Errors

| Error | Description |
|-------|-------------|
| `Unknown` | Condition not found for marketId |
| `Pending` | Resolution attempted before ready |
| `InvalidTarget` | Target address is zero |
| `MarketResolved` | Market already resolved |
| `ConditionExists` | Condition already registered for market |
| `InvalidDeadline` | Close time in the past |
| `InvalidETHAmount` | msg.value doesn't match required amount |
| `TargetCallFailed` | staticcall to oracle failed |
| `NotResolverMarket` | Market's resolver is not this contract |
| `CollateralNotMultiple` | Collateral not divisible by perShare |

### GasPM Errors

| Error | Description |
|-------|-------------|
| `InvalidOp` | Operator not 2 (LTE) or 3 (GTE) |
| `AlreadyBelowThreshold` | Window trough market: threshold already reached |
| `InvalidClose` | Close timestamp in the past |
| `Unauthorized` | Caller is not owner (or not allowed for public creation) |
| `AlreadyExceeded` | Window peak market: threshold already reached |
| `InvalidCooldown` | Reward set with zero cooldown |
| `InvalidThreshold` | Threshold is zero (or lower >= upper for range) |
| `InvalidETHAmount` | msg.value doesn't match collateral amount |
| `ResolverCallFailed` | Call to Resolver contract failed or returned empty |

---

## Resolver Role (General)

Any address can be a resolver for PAMM/PM markets. Resolvers can:
- Call `resolve(marketId, outcome)` after `close` timestamp
- Call `closeMarket(marketId)` early (if `canClose` was set at creation)
- Set a fee via `setResolverFeeBps(bps)` (max 10%, applies to all their markets)

**Fee timing:**
- PAMM: fee deducted per-claim (each winner pays fee on their collateral)
- PM: fee deducted once at resolution (from the pot before splitting)

**Options for resolver addresses:**
- EOA (trusted individual)
- Multisig (e.g., Gnosis Safe)
- The `Resolver` contract (trustless on-chain oracle)
- Custom oracle contract

---

## Development

```bash
forge build
forge test
forge test -vvv  # verbose output
```

### Testing Different Collaterals

The test suite includes coverage for:
- 18-decimal tokens (ETH, wstETH-style)
- 6-decimal tokens (USDC-style)
- 8-decimal tokens (WBTC-style)
- USDT-style tokens (no return value)

### Gas Snapshots

```bash
forge snapshot
```

Solidity `^0.8.30`. Mainnet addresses are hardcoded; fork mainnet for testing.

---

## Security Considerations

- **Resolver trust:** Markets trust their resolver to resolve honestly. For trustless resolution, use the Resolver contract with on-chain oracle checks.
- **Oracle manipulation:** Markets using AMM prices (Uniswap TWAP, etc.) may be vulnerable to manipulation. Use time-weighted averages or multiple oracle sources.
- **Decimal handling:** Always verify collateral decimals. Mismatched decimals can cause loss of funds.
- **Reentrancy:** All state-changing functions use `nonReentrant` guards.
- **Permit support:** Both EIP-2612 and DAI-style permits are supported for gasless approvals.

---

## License

MIT

---

*This code is experimental. No warranties. Use at your own risk.*
