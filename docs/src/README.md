# Prediction Markets — YES/NO Binary Markets

Minimal onchain mechanisms for binary prediction markets:

- **PAMM** — Collateral vault minting fully-collateralized YES/NO conditional tokens (ERC6909). Prices via ZAMM.
- **PM** — Pure parimutuel: buy/sell at par (1 wstETH = 1 share), winners split the pot.
- **Resolver** — On-chain oracle resolver for PAMM markets using arbitrary `staticcall` reads.

---

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| PAMM | `0x0000000000f8ba51d6e987660d3e455ac2c4be9d` |
| PM | `0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e` |
| Resolver | `0x0000000000d804b3d5e9e176c35b62b6235a11ad` |
| ZAMM | `0x000000000000040470635EB91b7CE4D132D616eD` |
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
  │  3. Store condition                  3. Call PAMM.resolve(outcome)      │
  │  4. Optionally seed LP               4. Delete condition                │
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
registerRatioConditionForExistingMarket(marketId, targetA, callDataA, targetB, callDataB, op, threshold)

// Resolution
resolveMarket(marketId)   // Anyone can call when ready
preview(marketId) → (value, condTrue, ready)  // Check resolution status

// Utility
multicall(bytes[] data)   // Batch operations
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

### Example Markets

#### 1. Price Prediction (Chainlink)

```solidity
// "ETH > $5000 by Dec 31, 2025"
// YES wins if ETH price exceeds $5000 at any point (canClose=true)
// NO wins if price is still <= $5000 at deadline

resolver.createNumericMarketAndSeed(
    "ETH/USD price",
    address(0),                    // ETH collateral
    0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,  // Chainlink ETH/USD
    abi.encodeWithSelector(bytes4(keccak256("latestAnswer()"))),
    Resolver.Op.GT,
    5000e8,                        // $5000 (8 decimals)
    1735689600,                    // Dec 31, 2025
    true,                          // early close allowed
    seedParams
);
```

#### 2. Token Supply Milestone

```solidity
// "USDC supply > 50B by Q2 2025"
// Tracks totalSupply() of USDC contract

resolver.createNumericMarketSimple(
    "USDC total supply",
    USDC,                          // USDC as collateral
    USDC,                          // target = USDC contract
    bytes4(keccak256("totalSupply()")),
    Resolver.Op.GT,
    50_000_000_000e6,              // 50B (6 decimals)
    1719792000,                    // June 30, 2025
    true
);
```

#### 3. DeFi TVL Target

```solidity
// "Aave V3 TVL > $20B"
// Reads total collateral from Aave pool

resolver.createNumericMarket(
    "Aave V3 TVL",
    address(0),                    // ETH collateral
    AAVE_POOL,
    abi.encodeWithSelector(bytes4(keccak256("getTotalCollateral()"))),
    Resolver.Op.GTE,
    20_000_000_000e18,             // $20B
    1735689600,
    true,
    seedParams
);
```

#### 4. Governance Outcome

```solidity
// "Proposal #42 passes (forVotes > againstVotes)"
// Uses ratio condition to compare two values

resolver.createRatioMarketSimple(
    "Proposal 42 passes",
    address(0),
    GOVERNOR,                      // forVotes source
    bytes4(keccak256("proposalVotes(uint256)")),  // returns forVotes
    GOVERNOR,                      // againstVotes source
    bytes4(keccak256("proposalAgainstVotes(uint256)")),
    Resolver.Op.GT,
    1e18,                          // ratio > 1.0 means forVotes > againstVotes
    1704067200,                    // voting end
    false                          // must wait for voting to end
);
```

#### 5. Collateralization Ratio

```solidity
// "DAI collateralization ratio stays above 150%"
// Compares collateral value to debt

resolver.createRatioMarket(
    "DAI CR > 150%",
    DAI,
    MAKER_VAT,
    abi.encodeCall(Vat.ink, (ilk)),   // collateral amount
    MAKER_VAT,
    abi.encodeCall(Vat.art, (ilk)),   // debt amount
    Resolver.Op.GTE,
    1.5e18,                        // 150% = 1.5
    1735689600,
    false                          // NO wins if CR drops below 150% at deadline
);
```

#### 6. Staking APY Prediction

```solidity
// "Lido stETH APY > 5%"
// Reads from Lido oracle

resolver.createNumericMarketAndSeed(
    "stETH APY",
    WSTETH,                        // wstETH collateral
    LIDO_ORACLE,
    abi.encodeWithSelector(bytes4(keccak256("getAPY()"))),
    Resolver.Op.GT,
    500,                           // 5% = 500 basis points
    1735689600,
    true,
    seedParams
);
```

#### 7. Block Number Race

```solidity
// "Ethereum block 20M before July 2025"
// Uses block.number from any contract

resolver.createNumericMarketSimple(
    "Block 20M milestone",
    address(0),
    TARGET_CONTRACT,               // any contract works
    bytes4(keccak256("getBlockNumber()")),  // or custom view
    Resolver.Op.GTE,
    20_000_000,
    1719792000,                    // July 1, 2025
    true                           // YES wins as soon as block 20M hit
);
```

#### 8. DEX Price Comparison (Ratio)

```solidity
// "ETH/USDC on Uniswap > ETH/USDC on Sushiswap"
// Compares prices across DEXes

resolver.createRatioMarket(
    "Uniswap ETH premium over Sushi",
    address(0),
    UNISWAP_POOL,
    abi.encodeCall(IPool.slot0, ()),   // returns sqrtPriceX96
    SUSHI_POOL,
    abi.encodeCall(IPool.slot0, ()),
    Resolver.Op.GT,
    1e18,                          // Uni price > Sushi price
    1735689600,
    false
);
```

#### 9. Boolean Condition (Protocol Status)

```solidity
// "Protocol is paused"
// Functions returning bool work natively (false=0, true=1)

resolver.createNumericMarketSimple(
    "Protocol paused",
    address(0),
    PROTOCOL_CONTRACT,
    bytes4(keccak256("paused()")),  // returns bool
    Resolver.Op.EQ,
    1,                             // true = 1
    1735689600,
    true                           // YES wins as soon as paused
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

## Resolver Role (General)

Any resolver address can:
- Call `resolve(marketId, outcome)` after `close` timestamp
- Call `closeMarket(marketId)` early (if `canClose` was set at creation)
- Set a fee via `setResolverFeeBps(bps)` (max 10%, applies to all their markets)

**Fee timing:**
- PAMM: fee deducted per-claim (each winner pays fee on their collateral)
- PM: fee deducted once at resolution (from the pot before splitting)

For decentralized resolution, use a multisig, oracle contract, or the Resolver contract above.

---

## Development

```bash
forge build
forge test
```

Solidity `^0.8.30`. Mainnet addresses are hardcoded; fork mainnet for testing.

---

## License

MIT

---

*This code is experimental. No warranties. DYOR.*
