# PMHOOK: Solving Prediction Market Liquidity Fragmentation

## The Problem

### Fragmented Liquidity
```
Traditional PM System:
├── USDC Markets: $500k TVL across 50 markets
├── DAI Markets:  $300k TVL across 30 markets
├── WETH Markets: $200k TVL across 20 markets
└── Total: $1M TVL BUT fragmented

User Experience:
- Want to trade across collaterals? Can't.
- Want to rebalance portfolio? Must exit each market individually.
- Want deep liquidity? Only within same collateral type.

Result: Liquidity is sharded, UX is poor, slippage is high
```

## The Solution: PMHOOK as Universal Collateral

### Core Insight
**What if all PM liquidity shared a common intermediary?**

Like how WETH unifies token trading on Ethereum:
- ETH/USDC pool
- ETH/DAI pool
- ETH/WBTC pool
- → ALL tokens effectively liquid against each other via ETH

**PMHOOK does this for prediction markets.**

### Architecture

```
                    PMHOOK Token
                (Minted when markets register)
                        |
        ┌───────────────┼───────────────┐
        │               │               │
   PMHOOK/USDC     PMHOOK/DAI      PMHOOK/WETH
    $500k liq       $300k liq        $200k liq
        │               │               │
   ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
   │         │     │         │     │         │
Market A  Market B Market C Market D Market E
(USDC)    (USDC)  (DAI)     (DAI)   (WETH)
```

**Key Property**: All markets share $1M aggregate liquidity via PMHOOK intermediary

### Implementation Phases

#### Phase 1: Hook Deployment + Token Minting
```solidity
// Deploy hook (ERC20 built-in)
PredictionMarketHook hook = new PredictionMarketHook();

// Register 100 markets
for (uint i = 0; i < 100; i++) {
    hook.registerMarket(marketIds[i]);
    // Mints 1000 PMHOOK per market
    // Total: 100,000 PMHOOK supply
}
```

#### Phase 2: Bootstrap PMHOOK/Collateral Pools
```solidity
// Create Uniswap V2/V3 pools for PMHOOK
// Use ZAMM or external DEX

// PMHOOK/USDC pool
addLiquidity(
    address(hook),    // PMHOOK token
    USDC,            // Pair
    50_000 ether,    // 50k PMHOOK
    50_000e6         // 50k USDC
);

// PMHOOK/DAI pool
addLiquidity(
    address(hook),
    DAI,
    30_000 ether,
    30_000 ether
);

// PMHOOK/WETH pool
addLiquidity(
    address(hook),
    WETH,
    20_000 ether,
    100 ether       // $200k at $2k/ETH
);

// Total liquidity: $100k PMHOOK + $100k collaterals
```

#### Phase 3: Enable Cross-Collateral Routing
```solidity
// In PMHookRouter

function swapCrossCollateral(
    uint256 fromMarketId,
    bool fromIsYes,
    uint256 fromAmount,
    uint256 toMarketId,
    bool toIsYes,
    uint256 minOut
) external returns (uint256 sharesOut) {
    // 1. Get collateral types
    address fromCollateral = PAMM.getCollateral(fromMarketId);
    address toCollateral = PAMM.getCollateral(toMarketId);

    if (fromCollateral == toCollateral) {
        // Same collateral: direct swap (existing functionality)
        return swapCrossMarket(...);
    }

    // Different collaterals: route via PMHOOK

    // 2. Sell fromMarket position → get fromCollateral
    uint256 collateralOut = PAMM.sellShares(fromMarketId, fromIsYes, fromAmount);

    // 3. Swap fromCollateral → PMHOOK (via DEX)
    uint256 pmhookOut = _swapViaPMHOOK(fromCollateral, collateralOut, address(hook));

    // 4. Swap PMHOOK → toCollateral (via DEX)
    uint256 toCollateralOut = _swapViaPMHOOK(address(hook), pmhookOut, toCollateral);

    // 5. Buy toMarket position with toCollateral
    sharesOut = PAMM.buyShares(toMarketId, toIsYes, toCollateralOut);

    require(sharesOut >= minOut, "Slippage");
}
```

### Liquidity Aggregation Effect

#### Before PMHOOK
```
Market A (USDC): Want to swap 10k
  Available liquidity: 50k USDC
  Slippage: ~20%

Market C (DAI): Want to swap 10k
  Available liquidity: 30k DAI
  Slippage: ~33%

Cross-collateral: IMPOSSIBLE (must exit, swap manually, re-enter)
```

#### After PMHOOK
```
Market A → Market C swap via PMHOOK:

Path: A(USDC) → USDC → PMHOOK → DAI → C(DAI)

Liquidity pools:
  - PMHOOK/USDC: 50k on each side
  - PMHOOK/DAI:  30k on each side
  - Effective liquidity: min(50k, 30k) = 30k

Slippage: ~33% → ~5% (6x improvement!)
Why? Aggregated liquidity across both pools
```

### Recursive Collateral: Markets Using PMHOOK

**Most Powerful Feature**: Create PM markets with PMHOOK as collateral

```solidity
// Market: "Will ETH hit $5k by Q4?"
// Collateral: PMHOOK (not USDC/DAI/WETH)

resolver.createMarket(
    address(hook),              // PMHOOK collateral
    "Will ETH hit $5k by Q4?",
    Q4_DEADLINE,
    bytes("eth_price >= 5000e18")
);

// Benefits:
// 1. Instant deep liquidity (PMHOOK/USDC,DAI,WETH pools)
// 2. Users can enter with ANY collateral (route via PMHOOK)
// 3. No fragmentation - all PMHOOK markets share liquidity
// 4. Recursive: PMHOOK becomes THE PM collateral
```

### The Flywheel

```
More markets register
  ↓
More PMHOOK minted
  ↓
Deeper PMHOOK pools
  ↓
Better cross-collateral swaps
  ↓
Better UX
  ↓
More users
  ↓
More markets register (loop)
```

### Economic Properties

#### PMHOOK Value Drivers
1. **Network Effects**: More markets → More minted → Higher supply → More liquidity pools needed
2. **Utility Value**: Required for cross-collateral swaps
3. **Speculation**: Token price reflects PM ecosystem health
4. **Governance**: Token-weighted voting (future)

#### Supply/Demand Balance
```
Supply: 1000 PMHOOK per market registered
Demand:
  - Liquidity pools (need PMHOOK paired with USDC/DAI/WETH)
  - Cross-collateral swaps (buy PMHOOK to route)
  - Recursive markets (use PMHOOK as collateral)
  - Speculation (trade PMHOOK directly)

Equilibrium: PMHOOK price = f(adoption, volume, utility)
```

### Comparison: Before vs After

| Metric | Before PMHOOK | After PMHOOK |
|--------|---------------|--------------|
| **Cross-collateral swaps** | Manual, 3-5 txs | Auto, 1 tx |
| **Effective liquidity** | Fragmented | Aggregated |
| **Slippage (cross-collateral)** | 50-100% | 5-10% |
| **Bootstrap new markets** | Hard (no liquidity) | Easy (PMHOOK pools) |
| **Collateral types** | Limited (USDC/DAI/WETH) | Unlimited (via PMHOOK) |
| **Portfolio rebalancing** | Manual per market | Atomic cross-market |

### Implementation Example: Complete Flow

```solidity
// Setup: User has 1000 YES shares in Market A (USDC collateral)
//        Wants NO shares in Market B (DAI collateral)

// Prepare DEX swap paths for Uniswap V2
address UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address PMHOOK_TOKEN = address(hook); // Hook contract IS the ERC20

// Path: USDC → PMHOOK
bytes memory pathUSDCtoPMHOOK = abi.encodeWithSignature(
    "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
    950e6,                           // amountIn (USDC has 6 decimals)
    900 ether,                       // amountOutMin
    [USDC, PMHOOK_TOKEN],           // path
    address(router),                 // to
    block.timestamp + 15 minutes     // deadline
);

// Path: PMHOOK → DAI
bytes memory pathPMHOOKtoDAI = abi.encodeWithSignature(
    "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
    940 ether,                       // amountIn (940 PMHOOK from previous swap)
    900 ether,                       // amountOutMin
    [PMHOOK_TOKEN, DAI],            // path
    address(router),                 // to
    block.timestamp + 15 minutes     // deadline
);

// Execute cross-collateral swap
uint256 sharesOut = router.swapCrossCollateral(
    marketA,                // fromMarketId (USDC market)
    true,                   // fromIsYes (selling YES)
    1000 ether,             // amount
    marketB,                // toMarketId (DAI market)
    false,                  // toIsYes (buying NO)
    PMHOOK_TOKEN,           // pmhookToken
    UNISWAP_V2_ROUTER,      // dexRouter
    pathUSDCtoPMHOOK,       // pathFromToPMHOOK
    pathPMHOOKtoDAI,        // pathPMHOOKToTo
    900 ether,              // minOut
    msg.sender              // to
);

// Execution Flow (4 atomic steps):
// STEP 1: Sell 1000 YES shares in Market A → 950 USDC (5% PM slippage)
// STEP 2: Swap 950 USDC → 940 PMHOOK (via PMHOOK/USDC pool, 1% DEX slippage)
// STEP 3: Swap 940 PMHOOK → 930 DAI (via PMHOOK/DAI pool, 1% DEX slippage)
// STEP 4: Buy NO shares with 930 DAI → 920 NO shares (1% PM slippage)

// Result:
// Total slippage: ~8% (vs 50%+ without PMHOOK routing!)
// User receives: 920 NO shares in one atomic transaction
// Before: Impossible without 3-5 manual transactions
// After: One call, atomic, optimal execution
```

### Liquidity Mining Incentives

**Bootstrap PMHOOK pools with incentives:**

```solidity
// Incentivize PMHOOK/USDC LPs
// Distribute PMHOOK tokens (from fees or treasury)

contract PMHOOKLiquidityMining {
    // Stake PMHOOK/USDC LP tokens
    // Earn PMHOOK rewards
    // Deepens liquidity, enables cross-collateral swaps
}

Benefits:
- Deeper pools → Lower slippage
- More PMHOOK locked → Higher token value
- Better UX → More adoption → More markets → More PMHOOK
```

### Meta-Markets on Liquidity

**Create markets about PMHOOK liquidity itself:**

```
Market: "Will PMHOOK/USDC pool TVL exceed $1M?"
Collateral: PMHOOK
Resolution: Query pool.totalSupply() * 2 >= 1e6

Market: "Will PMHOOK 30-day volume exceed $10M?"
Collateral: PMHOOK
Resolution: Indexed swap volume
```

**Self-fulfilling**: Betting on liquidity growth → Locking PMHOOK → Increasing scarcity → Higher price → More liquidity needed

### Advanced: Virtual Liquidity via PMHOOK

**Concept**: Hook can "simulate" deeper liquidity by routing via PMHOOK

```solidity
// In hook beforeAction
if (tvl[poolId] < config.minTVL) {
    // Low liquidity market
    // Signal router to use PMHOOK intermediary
    // Virtually aggregate liquidity from PMHOOK pools
}

// In router
if (hook signals virtual liquidity) {
    // Route: Market A → USDC → PMHOOK → USDC → Market A
    // Effectively "borrow" liquidity from PMHOOK pools
    // Even single-market swaps benefit from PMHOOK aggregation
}
```

### Security: Preventing PMHOOK Manipulation

**Risk**: Attacker creates 1000 fake markets to mint 1M PMHOOK

**Mitigations**:
1. **Market creation cost**: Require deposit/fee to create market
2. **TVL threshold**: Only mint PMHOOK if market hits minimum TVL
3. **Time delay**: Mint PMHOOK gradually over market lifetime
4. **Governance**: Token holders vote on minting rules

**Example**:
```solidity
function registerMarket(uint256 marketId) external {
    // ... existing registration

    // Don't mint immediately
    // Mint 100 PMHOOK now, 900 PMHOOK over 90 days
    // If market doesn't reach minTVL, stop minting
}
```

### Implementation Roadmap

**Phase 1: Foundation** (Week 1-2)
- ✅ Deploy hook with ERC20
- ✅ Mint PMHOOK on registration
- ✅ Create PMHOOK/USDC pool

**Phase 2: Routing** (Week 3-4)
- Add cross-collateral swap to router
- Integrate PMHOOK DEX pools
- Test single-hop routes

**Phase 3: Aggregation** (Week 5-6)
- Add PMHOOK/DAI, PMHOOK/WETH pools
- Multi-hop routing optimization
- Virtual liquidity signaling

**Phase 4: Recursive** (Week 7-8)
- Enable PMHOOK as PM collateral
- Meta-markets on PMHOOK metrics
- Liquidity mining launch

**Phase 5: Governance** (Week 9+)
- Token-weighted voting
- Minting parameter control
- Fee distribution to holders

### Success Metrics

**After 6 months**:
- 500+ markets registered
- 500k PMHOOK supply
- $1M+ PMHOOK pool liquidity
- 80%+ cross-collateral swaps use PMHOOK routing
- <10% average slippage for cross-collateral
- 50+ PMHOOK-denominated markets

### The Ultimate Vision

**PMHOOK becomes the "stablecoin" of prediction markets**

Just like USDC/DAI dominate DeFi collateral:
- Most PM trading uses PMHOOK
- Most liquidity pools pair with PMHOOK
- Most cross-collateral routes via PMHOOK
- Token price stabilizes as utility grows

**Result**: Unified PM liquidity layer, powered by hook-as-token

---

## TL;DR

**Problem**: PM liquidity fragmented across USDC/DAI/WETH markets

**Solution**: PMHOOK token as universal PM intermediary
- All markets route cross-collateral swaps via PMHOOK
- PMHOOK pools aggregate liquidity (like WETH for tokens)
- Recursive: Use PMHOOK as PM collateral itself
- Flywheel: More markets → More PMHOOK → Deeper pools → Better UX → More markets

**Innovation**: Hook-as-ERC20 solves fragmented liquidity problem elegantly
