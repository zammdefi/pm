# Prediction Markets — YES/NO Binary Markets

Minimal onchain mechanisms for binary prediction markets:

- **PAMM** — Collateral vault minting fully-collateralized YES/NO conditional tokens (ERC6909). Prices via ZAMM.
- **PMRouter** — Limit order router for PAMM markets. CEX-style orderbook trading via ZAMM + market orders via PAMM.
- **PM** — Pure parimutuel: buy/sell at par (1 wstETH = 1 share), winners split the pot.
- **Resolver** — On-chain oracle resolver for PAMM markets using arbitrary `staticcall` reads.
- **GasPM** — Gas price TWAP oracle with prediction market factory for "will gas exceed X gwei?" markets.

---

## Contract Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| [PAMM](https://contractscan.xyz/contract/0x000000000044bfe6c2BBFeD8862973E0612f07C0) | `0x000000000044bfe6c2BBFeD8862973E0612f07C0` |
| [PMRouter](https://contractscan.xyz/contract/0x000000000055ff709f26efb262fba8b0ae8c35dc) | `0x000000000055ff709f26efb262fba8b0ae8c35dc` |
| [PM](https://contractscan.xyz/contract/0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e) | `0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e` |
| [Resolver](https://contractscan.xyz/contract/0x00000000002205020E387b6a378c05639047BcFB) | `0x00000000002205020E387b6a378c05639047BcFB` |
| [ZAMM](https://contractscan.xyz/contract/0x000000000000040470635EB91b7CE4D132D616eD) | `0x000000000000040470635EB91b7CE4D132D616eD` |
| [GasPM](https://contractscan.xyz/contract/0x0000000000ee3d4294438093EaA34308f47Bc0b4) | `0x0000000000ee3d4294438093EaA34308f47Bc0b4` |
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
| **Split** | Lock `N` collateral → mint `N` YES + `N` NO |
| **Merge** | Burn `N` YES + `N` NO → unlock `N` collateral |
| **Claim** | After resolution: burn `N` winning tokens → receive `N` collateral (minus resolver fee if set) |

Shares are 1:1 with collateral (1 share = 1 wei of collateral). Any amount works, dust is refunded.

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

Supports ETH (`address(0)`) or any ERC20. Shares are 1:1 with collateral wei.

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
marketCount()
tokenURI(id)                             // NFT-compatible metadata URI
```

### ID Derivation

```
marketId (YES) = keccak256("PMARKET:YES", description, resolver, collateral)
noId           = keccak256("PMARKET:NO", marketId)
```

---

## PMRouter — Limit Order & Trading Router

A limit order router for PAMM prediction markets. Enables CEX-style orderbook trading via ZAMM, market orders via PAMM AMM, and convenient collateral operations.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            PMRouter SYSTEM                                  │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────┐                                  ┌──────────────────┐
  │     TRADERS      │                                  │    MARKET MAKERS │
  │                  │                                  │                  │
  │ • Market orders  │                                  │ • Place limits   │
  │ • Fill limits    │                                  │ • Cancel orders  │
  │ • Split/merge    │                                  │ • Provide depth  │
  │ • Claim wins     │                                  │                  │
  └────────┬─────────┘                                  └────────┬─────────┘
           │                                                     │
           │                                                     │
           ▼                                                     ▼
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                              PMRouter                                   │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                    ORDER MANAGEMENT                             │    │
  │  │  • placeOrder() - create limit orders                           │    │
  │  │  • cancelOrder() - reclaim escrowed tokens                      │    │
  │  │  • fillOrder() - fill existing orders                           │    │
  │  │  • fillOrdersThenSwap() - fill orders + route remainder to AMM  │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                    MARKET OPERATIONS                            │    │
  │  │  • buy() / sell() - market orders via PAMM AMM                  │    │
  │  │  • swapShares() - swap YES<->NO via ZAMM                        │    │
  │  │  • split() / merge() / claim() - collateral operations          │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  │  ┌─────────────────────────────────────────────────────────────────┐    │
  │  │                    ORDERBOOK VIEWS                              │    │
  │  │  • getOrderbook() - full bid/ask depth                          │    │
  │  │  • getBidAsk() - best prices + order counts                     │    │
  │  │  • getBestOrders() - sorted orders for filling                  │    │
  │  └─────────────────────────────────────────────────────────────────┘    │
  └───────────────────────────────┬─────────────────────────────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
              ▼                   ▼                   ▼
  ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐
  │       ZAMM        │  │       PAMM        │  │    COLLATERAL     │
  │  • Order escrow   │  │  • Split/merge    │  │  • ETH            │
  │  • Order fills    │  │  • YES/NO tokens  │  │  • ERC20          │
  │  • AMM swaps      │  │  • Market orders  │  │  • Permits        │
  └───────────────────┘  └───────────────────┘  └───────────────────┘
```

### Order Types

| Type | Description | Use Case |
|------|-------------|----------|
| **Limit Buy** | Escrow collateral, receive shares when filled | "Buy YES at 0.60 or better" |
| **Limit Sell** | Escrow shares, receive collateral when filled | "Sell NO at 0.45 or better" |
| **Market Buy** | Instant buy via PAMM AMM | "Buy YES now at market price" |
| **Market Sell** | Instant sell via PAMM AMM | "Sell NO now at market price" |

### Order Lifecycle

```
    PLACE                        FILL                         SETTLE
       │                           │                             │
       ▼                           ▼                             ▼
┌─────────────┐         ┌─────────────────────┐         ┌─────────────────┐
│   Maker     │         │      Taker          │         │    ZAMM         │
│   calls     │────────►│      calls          │────────►│    settles      │
│   place     │         │      fillOrder()    │         │    atomically   │
│   Order()   │         │                     │         │                 │
└─────────────┘         │  OR fillOrders      │         │  maker gets     │
      │                 │     ThenSwap()      │         │  counterparty   │
      │  escrow         │                     │         │  taker gets     │
      ▼                 └─────────────────────┘         │  their side     │
┌─────────────┐                                         └─────────────────┘
│   Tokens    │
│   held in   │
│   ZAMM      │
└─────────────┘
```

### Limit Orders

#### Place Order

```solidity
// Place a limit order to buy YES at 0.60 collateral per share
router.placeOrder{value: 6 ether}(
    marketId,         // PAMM market ID
    true,             // isYes: YES shares
    true,             // isBuy: buying (escrowing collateral)
    10 ether,         // shares: want 10 shares
    6 ether,          // collateral: paying 6 ETH (0.60 per share)
    uint56(block.timestamp + 1 days),  // deadline
    true              // partialFill: allow partial fills
);

// Place a limit order to sell NO at 0.45 collateral per share
router.placeOrder(
    marketId,
    false,            // isYes: NO shares
    false,            // isBuy: selling (escrowing shares)
    10 ether,         // shares: selling 10 shares
    4.5 ether,        // collateral: want 4.5 ETH (0.45 per share)
    uint56(block.timestamp + 1 days),
    true
);
```

#### Fill Order

```solidity
// Fill an existing sell order (buy from maker)
router.fillOrder{value: expectedCollateral}(
    orderHash,        // Order to fill
    5 ether,          // sharesToFill (0 = fill all)
    recipient         // Who receives the shares
);

// Fill then route remainder to AMM
router.fillOrdersThenSwap{value: 10 ether}(
    marketId,
    true,             // isYes
    true,             // isBuy
    10 ether,         // totalCollateral
    9 ether,          // minSharesOut (slippage)
    orderHashes,      // Orders to try first
    30,               // feeOrHook for AMM remainder
    recipient
);
```

#### Cancel Order

```solidity
// Cancel and reclaim escrowed tokens
router.cancelOrder(orderHash);

// Batch cancel multiple orders
router.batchCancelOrders(orderHashes);
```

### Market Orders

```solidity
// Buy YES shares via PAMM AMM
router.buy{value: 1 ether}(
    marketId,
    true,             // isYes
    1 ether,          // collateralIn
    0.9 ether,        // minSharesOut (slippage)
    30,               // feeOrHook
    recipient
);

// Sell NO shares via PAMM AMM
router.sell(
    marketId,
    false,            // isYes (NO)
    1 ether,          // sharesIn
    0.4 ether,        // minCollateralOut
    30,               // feeOrHook
    recipient
);
```

### Share Swaps (via ZAMM)

```solidity
// Swap YES -> NO directly via ZAMM pool
router.swapShares(
    marketId,
    true,             // yesForNo: YES -> NO
    1 ether,          // amountIn
    0.9 ether,        // minOut
    30,               // feeOrHook
    recipient
);

// Swap shares directly to collateral (if ZAMM pool exists)
router.swapSharesToCollateral(marketId, true, 1 ether, 0.5 ether, 30, recipient);

// Swap collateral directly to shares (if ZAMM pool exists)
router.swapCollateralToShares{value: 1 ether}(marketId, true, 1 ether, 1.5 ether, 30, recipient);
```

### Collateral Operations

```solidity
// Split collateral into YES + NO shares
router.split{value: 1 ether}(marketId, 1 ether, recipient);

// Merge YES + NO shares back into collateral
router.merge(marketId, 1 ether, recipient);

// Claim winnings from resolved market
router.claim(marketId, recipient);
```

### Functions

```solidity
// Limit Orders
placeOrder(marketId, isYes, isBuy, shares, collateral, deadline, partialFill) → orderHash
cancelOrder(orderHash)
fillOrder(orderHash, sharesToFill, to) → (sharesFilled, collateralFilled)
fillOrdersThenSwap(marketId, isYes, isBuy, totalAmount, minOutput,
                   orderHashes[], feeOrHook, to) → totalOutput
batchCancelOrders(orderHashes[]) → cancelled

// Market Orders (via PAMM AMM)
buy(marketId, isYes, collateralIn, minSharesOut, feeOrHook, to) → sharesOut
sell(marketId, isYes, sharesIn, minCollateralOut, feeOrHook, to) → collateralOut

// Share Swaps (via ZAMM)
swapShares(marketId, yesForNo, amountIn, minOut, feeOrHook, to) → amountOut
swapSharesToCollateral(marketId, isYes, sharesIn, minCollateralOut, feeOrHook, to) → collateralOut
swapCollateralToShares(marketId, isYes, collateralIn, minSharesOut, feeOrHook, to) → sharesOut

// Collateral Operations
split(marketId, amount, to)
merge(marketId, amount, to)
claim(marketId, to) → payout

// Order Views
getOrder(orderHash) → (order, sharesFilled, sharesRemaining, collateralFilled, collateralRemaining, active)
isOrderActive(orderHash) → bool
getMarketOrderCount(marketId) → count
getUserOrderCount(user) → count
getMarketOrderHashes(marketId, offset, limit) → orderHashes[]
getUserOrderHashes(user, offset, limit) → orderHashes[]
getActiveOrders(marketId, isYes, isBuy, limit) → (orderHashes[], orderDetails[])
getBestOrders(marketId, isYes, isBuy, limit) → orderHashes[]

// UX Helpers
getBidAsk(marketId, isYes) → (bidPrice, askPrice, bidCount, askCount)
getOrderbook(marketId, isYes, depth) → (bidHashes[], bidPrices[], bidSizes[],
                                        askHashes[], askPrices[], askSizes[])
getUserPositions(user, marketIds[]) → (yesBalances[], noBalances[])
getUserActiveOrders(user, marketId, limit) → (orderHashes[], orderDetails[])

// Utility
multicall(bytes[] data) → results[]
permit(token, owner, value, deadline, v, r, s)
```

### Order Struct

```solidity
struct Order {
    address owner;      // Order creator
    uint56 deadline;    // Expiration timestamp
    bool isYes;         // YES or NO shares
    bool isBuy;         // Buying or selling shares
    bool partialFill;   // Allow partial fills
    uint96 shares;      // Share amount
    uint96 collateral;  // Collateral amount
    uint256 marketId;   // PAMM market ID
}
```

### Price Calculation

Prices are represented as 18-decimal fixed-point numbers:
- `price = collateral * 1e18 / shares`
- Example: 0.60 price = 6e17 (0.6 * 1e18)

For a buy order at 0.60:
- `shares = 10 ether`, `collateral = 6 ether`
- `price = 6e18 * 1e18 / 10e18 = 6e17` (0.60)

### Orderbook Example

```solidity
// Get full orderbook for YES shares
(
    bytes32[] memory bidHashes,
    uint256[] memory bidPrices,
    uint256[] memory bidSizes,
    bytes32[] memory askHashes,
    uint256[] memory askPrices,
    uint256[] memory askSizes
) = router.getOrderbook(marketId, true, 10);

// Result (example):
// Bids (buy orders, highest first):
//   0.65 - 5 shares
//   0.60 - 10 shares
//   0.55 - 3 shares
//
// Asks (sell orders, lowest first):
//   0.70 - 8 shares
//   0.75 - 4 shares
//   0.80 - 12 shares
```

### User Stories

| Role | Goal | Action |
|------|------|--------|
| **Limit Buyer** | Buy YES at specific price | `placeOrder(isYes=true, isBuy=true)` |
| **Limit Seller** | Sell NO at specific price | `placeOrder(isYes=false, isBuy=false)` |
| **Market Buyer** | Buy instantly at market | `buy(isYes, collateralIn, minOut)` |
| **Market Seller** | Sell instantly at market | `sell(isYes, sharesIn, minOut)` |
| **Arbitrageur** | Fill orders + AMM in one tx | `fillOrdersThenSwap()` |
| **Market Maker** | Provide liquidity on both sides | Multiple `placeOrder()` calls |
| **Dapp** | Display orderbook | `getOrderbook()` + `getBidAsk()` |
| **Portfolio View** | Show user positions | `getUserPositions()` + `getUserActiveOrders()` |

### Notes

- Orders are escrowed in ZAMM (not the router) for trustless settlement
- Partial fills are optional per order (set `partialFill=true` to allow)
- Order deadlines are capped to market close time
- Prices are always `collateral/shares` (18 decimals)
- `getBestOrders` returns orders sorted by price (best first)
- `getOrderbook` returns remaining sizes (after partial fills), not original sizes
- Supports ETH and ERC20 collateral
- Permits available for gasless ERC20 approvals
- Multicall for batching multiple operations

### Operational Requirements

- **Collateral tokens** must have >= 6 decimals (ETH, USDC, DAI, etc.)
- **Fee-on-transfer** and **rebasing tokens** are NOT supported
- **Tokens requiring approve(0)** before approve(n) (e.g., USDT) are NOT supported as collateral
- Markets with unsupported collateral should be marked unsafe in UIs/indexers

### Trust Model

- ZAMM is trusted infrastructure with operator privileges over router-held PAMM shares
- Orders can be filled directly on ZAMM (bypassing router); makers should cancel promptly on market resolution to avoid stale order exploitation

### Behavioral Notes

- **Deadline semantics:** Swap functions treat `deadline == 0` as `block.timestamp`
- **Partial fill rounding:** ZAMM uses floor division, max dust is N units for N fills
- **fillOrder()** checks `tradingOpen` to prevent fills after early market resolution

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
| Payout | 1:1 (1 share = 1 collateral wei) | Winners split pot pro-rata |
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
    uint256 collateralIn;   // Any amount (1:1 shares, dust refunded)
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
    address recipient;          // Recipient of swapped shares (address(0) = msg.sender)
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
    collateralIn: 10 ether,       // Any amount (1:1 shares)
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
    yesForNo: false,              // false = buyYes, true = buyNo
    recipient: address(0)         // address(0) = msg.sender
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
    yesForNo: false,              // false = buyYes, true = buyNo
    recipient: address(0)         // address(0) = msg.sender
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
// Reverts if current basefee >= 100 gwei (threshold already hit)
// Always enables early close (resolves when spike occurs)
oracle.createWindowPeakMarket{value: 10 ether}(
    100 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas spikes to 100 gwei during market"

// Window Trough: "Will gas dip to 10 gwei DURING THIS MARKET?"
// Reverts if current basefee <= 10 gwei (threshold already hit)
// Always enables early close (resolves when dip occurs)
oracle.createWindowTroughMarket{value: 10 ether}(
    10 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
    10 ether,
    30,
    0,
    msg.sender
);
// Observable: "Gas dips to 10 gwei during market"

// Window Volatility: "Will gas spread exceed 30 gwei DURING THIS MARKET?"
// Tracks absolute spread (max - min) during the market window
// Call pokeWindowVolatility(marketId) periodically to capture extremes
// Always enables early close (resolves when spread threshold hit)
oracle.createWindowVolatilityMarket{value: 10 ether}(
    30 gwei,
    address(0),
    uint64(block.timestamp + 7 days),
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
baseFeeMaxSince(marketId) → uint256        // Max basefee during market window (wei)
baseFeeMinSince(marketId) → uint256        // Min basefee during market window (wei)
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
createWindowPeakMarket(threshold, collateral, close,
                       collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId  // always canClose=true
createWindowTroughMarket(threshold, collateral, close,
                         collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId  // always canClose=true
createWindowVolatilityMarket(threshold, collateral, close,
                             collateralIn, feeOrHook, minLiquidity, lpRecipient) → marketId  // always canClose=true
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
    address recipient;          // Recipient of swapped shares (address(0) = msg.sender)
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

Both PAMM and Resolver support multiple collateral types with 1:1 shares (1 share = 1 wei of collateral):

| Decimals | Token Examples | 1000 shares (ZAMM minimum) |
|----------|----------------|---------------------------|
| 18 | ETH, wstETH, DAI | 1000 wei (~0) |
| 6 | USDC, USDT | 1000 wei = 0.001 USDC |
| 8 | WBTC | 1000 wei = 0.00001 WBTC |

**Note:** ZAMM requires `MINIMUM_LIQUIDITY` (1000 shares) to be locked when creating a pool. With 1:1 shares, this is 1000 wei of collateral—negligible for all token types.

**Non-standard ERC20 support:**
- **No return value** (e.g., USDT transfer) — handled by safe transfer wrappers
- **Fee-on-transfer tokens** — NOT supported (causes accounting issues)
- **Rebasing tokens** — NOT supported
- **Tokens requiring approve(0)** (e.g., USDT) — NOT supported as collateral for PMRouter (approval fails)
- **Collateral decimals** — recommend >= 6 decimals (ETH, USDC, DAI, etc.)

---

## Error Reference

### PAMM Errors

| Error | Description |
|-------|-------------|
| `AmountZero` | Zero amount provided |
| `FeeOverflow` | Resolver fee > 1000 bps (10%) |
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
| `MarketNotClosed` | Claim attempted before close/resolution |
| `InvalidETHAmount` | msg.value doesn't match required amount |
| `InvalidSwapAmount` | Swap amount exceeds available |
| `InsufficientOutput` | Slippage protection triggered |
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

### PMRouter Errors

| Error | Description |
|-------|-------------|
| `Reentrancy` | Reentrant call detected |
| `AmountZero` | Zero shares or collateral provided |
| `MustFillAll` | Partial fill not allowed for this order |
| `MarketClosed` | Market close time has passed |
| `OrderInactive` | Order expired or fully filled |
| `NotOrderOwner` | Caller is not the order owner |
| `OrderNotFound` | Order hash not found |
| `MarketNotFound` | Invalid marketId |
| `TradingNotOpen` | Market not open for trading |
| `DeadlineExpired` | Order deadline in the past |
| `SlippageExceeded` | Output below minimum specified |
| `InvalidETHAmount` | msg.value doesn't match required amount |

### GasPM Errors

| Error | Description |
|-------|-------------|
| `InvalidOp` | Operator not 2 (LTE) or 3 (GTE) |
| `Reentrancy` | Reentrant call detected |
| `InvalidClose` | Close timestamp in the past |
| `Unauthorized` | Caller is not owner (or not allowed for public creation) |
| `ApproveFailed` | ERC20 approval failed |
| `AlreadyExceeded` | Window peak market: threshold already reached |
| `TransferFailed` | ERC20 transfer failed |
| `InvalidCooldown` | Reward set with zero cooldown |
| `InvalidThreshold` | Threshold is zero (or lower >= upper for range) |
| `InvalidETHAmount` | msg.value doesn't match collateral amount |
| `MarketIdMismatch` | Returned marketId from Resolver doesn't match expected |
| `ETHTransferFailed` | ETH transfer failed |
| `ResolverCallFailed` | Call to Resolver contract failed or returned empty |
| `TransferFromFailed` | ERC20 transferFrom failed |
| `AlreadyBelowThreshold` | Window trough market: threshold already reached |

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

## GasPM Dapp

A single-page web application for trading Ethereum gas price prediction markets. Located at `dapp/GasPM.html`.

### Features

#### Real-Time Gas Oracle Dashboard
- **Live TWAP** — Time-weighted average gas price since oracle deployment
- **Current Gas** — Real-time `block.basefee` display
- **Min/Max Tracking** — Historical extremes with spread calculation
- **Visual Chart** — 24-hour gas price history with threshold overlays

#### Market Discovery
- **Active Markets Grid** — Browse all GasPM markets with live prices
- **Market Types** — Support for all GasPM market types:
  - Below/Above (directional bets)
  - Range/Breakout (bounded bets)
  - Peak/Trough (extreme value bets)
  - Volatility/Stability (spread bets)
  - Spot/Comparison (point-in-time bets)
- **Resolution Status** — Visual indicators for resolved vs active markets
- **Win Probability** — Implied odds from AMM pool reserves

#### Trading Interface

**Instant (AMM) Trading:**
- Buy/Sell YES or NO shares via PAMM AMM
- Real-time price impact preview
- Position display with current holdings
- Max button for full balance trades

**Limit Orders (via PMRouter):**
- Place limit orders at specific prices
- Partial fill support
- 7-day default expiration
- Order management (view/cancel)

**Smart Trade (Hybrid Routing):**
- Automatically fills best orderbook prices first
- Routes remainder through AMM
- Single transaction for optimal execution
- Visual liquidity breakdown showing orderbook vs AMM fill

#### Orderbook Display
- **Depth Visualization** — Color-coded bars showing order sizes
- **Bid/Ask Spread** — Real-time spread calculation
- **Take Buttons** — One-click order filling
- **Price Levels** — Sorted by best price (bids high→low, asks low→high)

#### Wallet Integration
- MetaMask, Coinbase, Rabby, Rainbow support
- EIP-6963 wallet detection
- Network validation (Ethereum mainnet only)
- Balance display for ETH and tokens

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           GasPM.html                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐  │
│  │   Header    │   │  Gas Stats  │   │   Markets   │   │ Trade Modal │  │
│  │  + Wallet   │   │  + Chart    │   │    Grid     │   │  + Orders   │  │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘  │
│         │                 │                 │                 │         │
│         └─────────────────┴─────────────────┴─────────────────┘         │
│                                   │                                     │
│                    ┌──────────────┴──────────────┐                      │
│                    │       ethers.js v6          │                      │
│                    └──────────────┬──────────────┘                      │
│                                   │                                     │
└───────────────────────────────────┼─────────────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌───────────────┐         ┌───────────────┐         ┌───────────────┐
│    GasPM      │         │     PAMM      │         │   PMRouter    │
│   (Oracle)    │         │  (Markets)    │         │ (Orderbook)   │
│               │         │               │         │               │
│ • TWAP data   │         │ • Buy/Sell    │         │ • Limit orders│
│ • Market list │         │ • Positions   │         │ • Fill orders │
│ • Resolution  │         │ • Pool state  │         │ • Smart route │
└───────────────┘         └───────────────┘         └───────────────┘
        │                           │                           │
        └───────────────────────────┼───────────────────────────┘
                                    │
                                    ▼
                            ┌───────────────┐
                            │     ZAMM      │
                            │   (Liquidity) │
                            │               │
                            │ • AMM pools   │
                            │ • Order escrow│
                            └───────────────┘
```

### User Flows

#### View Markets
```
1. Page loads → Fetches GasPM.getMarketInfos()
2. For each market → Fetches PAMM pool state (prices)
3. Displays market cards with:
   - Threshold and market type
   - Current YES/NO prices
   - Resolution status
   - Time remaining
```

#### AMM Trade (Instant)
```
1. Click market card → Opens trade modal
2. Select Buy/Sell and YES/NO
3. Enter amount → See price impact preview
4. Click Confirm → Signs transaction
5. Receives shares (or ETH if selling)
```

#### Limit Order
```
1. Click "Limit Orders" tab in trade modal
2. Select Buy/Sell and YES/NO token
3. Enter price (0.01-0.99) and shares
4. View liquidity breakdown preview
5. Click "Place Order" → Escrows funds in ZAMM
6. Order appears in "Your Orders" section
```

#### Smart Trade (Best Execution)
```
1. Enter shares amount in limit order form
2. Optional: Set max price
3. View liquidity breakdown:
   - Green bar = fills from orderbook
   - Cyan bar = routes to AMM
4. Click "Smart Trade"
5. Single transaction:
   a. Fills best orderbook orders
   b. Swaps remainder via AMM
   c. Receives all shares
```

#### Take Order (Direct Fill)
```
1. View orderbook in trade modal
2. Click "Buy" on ask row (to buy shares)
   or "Sell" on bid row (to sell shares)
3. Transaction fills that specific order
4. Counterparty receives their side
```

### Contract Addresses

| Contract | Address | Status |
|----------|---------|--------|
| GasPM | `0x0000000000ee3d4294438093EaA34308f47Bc0b4` | Deployed |
| PAMM | `0x000000000044bfe6c2BBFeD8862973E0612f07C0` | Deployed |
| ZAMM | `0x000000000000040470635EB91b7CE4D132D616eD` | Deployed |
| Resolver | `0x00000000002205020E387b6a378c05639047BcFB` | Deployed |
| PMRouter | `0x0000000000000000000000000000000000000001` | **Placeholder** |

> **Note:** Deploy PMRouter.sol and update `PMROUTER_ADDRESS` in GasPM.html to enable orderbook functionality.

### Deployment

#### Deploy PMRouter
```bash
forge create src/PMRouter.sol:PMRouter \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

#### Update Dapp
Edit `dapp/GasPM.html` line ~2202:
```javascript
const PMROUTER_ADDRESS = '0x<deployed_address>';
```

### Mobile Support

The dapp is fully responsive:

| Breakpoint | Optimizations |
|------------|---------------|
| **768px** | Stacked inputs, smaller fonts, condensed orderbook |
| **400px** | Hidden total column, ultra-compact buttons, simplified layout |

Touch-friendly with appropriate tap targets and no hover-dependent interactions.

### Technical Details

#### Dependencies
- **ethers.js v6** — Loaded from CDN (unpkg.com)
- **No build step** — Single HTML file, runs directly in browser

#### RPC Fallback
```javascript
// Uses wallet provider if connected, otherwise public RPC
const rpcProvider = provider || new ethers.JsonRpcProvider('https://1rpc.io/eth');
```

#### Multicall Optimization
Batches multiple contract reads into single RPC call using Multicall3:
```javascript
const results = await multicall.aggregate3([
  { target: GASPM_ADDRESS, callData: gaspmIface.encodeFunctionData('baseFeeAverage') },
  { target: GASPM_ADDRESS, callData: gaspmIface.encodeFunctionData('baseFeeCurrent') },
  // ... more calls
]);
```

#### Gas Price Chart
- Queries last 100 blocks for `block.basefee`
- Renders SVG with price line and threshold overlays
- Updates on new block headers

### Security Notes

- **Client-side only** — No backend, all interactions directly with contracts
- **Wallet signing** — All transactions require explicit user approval
- **Slippage protection** — AMM trades use `minOut` parameter (currently set to 0, can be improved)
- **No token approvals stored** — PMRouter uses `setOperator` pattern from ERC6909

---

## License

MIT

---

*This code is experimental. No warranties. Use at your own risk.*
