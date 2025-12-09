# Prediction Markets — YES/NO Binary Markets

Two minimal onchain mechanisms for binary prediction markets:

- **PAMM** — Collateral vault minting fully-collateralized YES/NO conditional tokens (ERC6909). Prices via ZAMM.
- **PM** — Pure parimutuel: buy/sell at par (1 wstETH = 1 share), winners split the pot.

---

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| PAMM | `0x0000000000f8ba51d6e987660d3e455ac2c4be9d` |
| PM | `0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e` |
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

## Resolver

The resolver address can:
- Call `resolve(marketId, outcome)` after `close` timestamp
- Call `closeMarket(marketId)` early (if `canClose` was set at creation)
- Set a fee via `setResolverFeeBps(bps)` (max 10%, applies to all their markets)

**Fee timing:**
- PAMM: fee deducted per-claim (each winner pays fee on their collateral)
- PM: fee deducted once at resolution (from the pot before splitting)

For decentralized resolution, use a multisig or oracle contract as the resolver.

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
