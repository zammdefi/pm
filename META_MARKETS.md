# Meta-Markets: Hook as ERC20 Collateral

## Concept

The PredictionMarketHook itself is an ERC20 token, creating a self-referential system where:
1. Hook mints tokens when markets register (adoption metric)
2. Tokens can be PAMM collateral for meta-markets
3. Meta-markets predict hook performance/adoption

## Token Economics

### Minting
- **Per Market Registration**: 1,000 PMHOOK tokens
- **Recipient**: Market creator (resolver address)
- **Supply**: Unbounded (grows with adoption)

### Token Properties
- **Name**: "Prediction Market Hook Token"
- **Symbol**: PMHOOK
- **Decimals**: 18
- **Standard**: ERC20 (transfer, transferFrom, approve)

## Use Cases

### 1. Adoption Markets
**Market**: "Will PredictionMarketHook have >500 active markets by Q4 2025?"

- **Collateral**: PMHOOK tokens
- **YES shares**: Bullish on hook adoption
- **NO shares**: Bearish on hook adoption
- **Resolution**: Query `hook.totalSupply() / 1000e18 >= 500` at deadline

**Meta-Property**: Token supply directly measures adoption!

### 2. Volume Markets
**Market**: "Will total hook swap volume exceed $1B in 2025?"

- **Collateral**: PMHOOK tokens
- **Data Source**: Index hook swap events
- **Resolution**: Indexer confirms cumulative volume

**Meta-Property**: High trading volume = high hook usage = more tokens minted

### 3. TVL Markets
**Market**: "Will aggregated TVL across all hook markets exceed $10M?"

- **Collateral**: PMHOOK tokens
- **Measurement**: Sum of `tvl[poolId]` for all registered pools
- **Resolution**: `sum(tvl[poolId]) >= 10_000_000e18`

**Meta-Property**: TVL correlates with token supply (more markets = more TVL)

### 4. Meta-Governance Markets
**Market**: "Will max fee be reduced to 0.8% by community vote?"

- **Collateral**: PMHOOK tokens
- **Voting Weight**: PMHOOK balance
- **Resolution**: Governance proposal execution

**Future**: PMHOOK holders vote on global defaults

### 5. Competitive Markets
**Market**: "Will PredictionMarketHook process more volume than CompetitorHook in Q3?"

- **Collateral**: PMHOOK tokens
- **Resolution**: Compare indexed volumes
- **Competitive Metric**: Direct hook-vs-hook comparison

## Implementation Example

```solidity
// 1. Deploy hook (becomes ERC20 automatically)
PredictionMarketHook hook = new PredictionMarketHook();

// 2. Creator registers a market
uint256 marketId = resolver.createMarket(...);
uint256 poolId = hook.registerMarket(marketId);
// Creator receives 1000 PMHOOK tokens

// 3. Create meta-market using PMHOOK as collateral
uint256 metaMarketId = resolver.createMarket(
  address(hook),        // collateral = PMHOOK token
  "Will hook have >500 markets by Q4 2025?",
  Q4_2025_DEADLINE,
  bytes("hook.totalSupply() / 1000e18 >= 500")
);

// 4. Traders buy YES/NO shares with PMHOOK
// - Lock PMHOOK tokens
// - Get YES/NO exposure to hook adoption
// - Self-fulfilling: More adoption = more tokens = higher PMHOOK value

// 5. Resolution
// - If hook.totalSupply() / 1000e18 >= 500: YES wins
// - If not: NO wins
// - PMHOOK collateral distributed to winners
```

## Self-Fulfilling Prophecy Mechanics

### Positive Feedback Loop
```
More markets register
  ↓
More PMHOOK minted
  ↓
Higher PMHOOK supply
  ↓
Meta-markets show bullish signals
  ↓
More interest in using hook
  ↓
More markets register (loop)
```

### Negative Feedback Loop
```
Low market registration
  ↓
Low PMHOOK supply growth
  ↓
Meta-markets bearish
  ↓
PMHOOK price drops
  ↓
Less incentive to create markets
  ↓
Lower registration (loop)
```

## Economic Properties

### Supply Dynamics
- **Initial**: 0 tokens
- **Per Market**: +1,000 tokens
- **100 Markets**: 100,000 tokens
- **1,000 Markets**: 1,000,000 tokens

### Market Cap Estimation
```
Market Cap = totalSupply * PMHOOK_price
PMHOOK_price = f(adoption, volume, TVL, sentiment)

Example at 500 markets:
  Supply: 500,000 tokens
  Price: $10/token (if successful hook)
  Market Cap: $5M
```

### Collateral Utility
- **Bootstrap liquidity** for meta-markets
- **Circular economy**: Hook success → token value → more usage
- **Speculation vehicle**: Trade hook adoption directly

## Advanced: Revenue-Sharing Extension

```solidity
// Future enhancement: Distribute fees to PMHOOK holders

mapping(address => uint256) public lastClaimTime;
uint256 public totalFeesCollected;

function claimFeeShare() external {
    uint256 share = (balanceOf[msg.sender] * totalFeesCollected) / totalSupply;
    uint256 elapsed = block.timestamp - lastClaimTime[msg.sender];
    uint256 payout = (share * elapsed) / 365 days; // Pro-rata annual

    lastClaimTime[msg.sender] = block.timestamp;
    // Transfer fee share to holder
}
```

## Governance Extension

```solidity
// Future: Token-weighted voting on global defaults

function proposeConfigChange(
    uint32 newMinTVL,
    uint16 newCircuitBreaker
) external {
    require(balanceOf[msg.sender] >= 10000 ether, "Need 10k tokens to propose");
    // Create governance proposal
}

function vote(uint256 proposalId, bool support) external {
    votes[proposalId][msg.sender] = balanceOf[msg.sender]; // Token-weighted
}
```

## Meta-Market Resolution Helpers

```solidity
// On-chain verifiable resolution conditions

/// @notice Check if adoption target met
/// @param targetMarkets Minimum market count
/// @return met True if target met
function checkAdoptionTarget(uint256 targetMarkets) external view returns (bool met) {
    return (totalSupply / 1000 ether) >= targetMarkets;
}

/// @notice Check if aggregate TVL target met
/// @param targetTVL Minimum aggregate TVL
/// @return met True if target met
function checkTVLTarget(uint256 targetTVL) external view returns (bool met) {
    // Sum all pool TVLs
    uint256 aggregateTVL = 0;
    // Note: Would need registry of poolIds or event indexing
    return aggregateTVL >= targetTVL;
}

/// @notice Get current hook statistics
/// @return markets Total markets registered
/// @return tokens Total PMHOOK supply
function getHookStats() external view returns (uint256 markets, uint256 tokens) {
    markets = totalSupply / 1000 ether; // Each market = 1000 tokens
    tokens = totalSupply;
}
```

## Gas Costs

**Additional cost per registration**: ~48,000 gas (minting + events)

Breakdown:
- SSTORE totalSupply: ~20,000 gas
- SSTORE balanceOf: ~20,000 gas
- Transfer event: ~8,000 gas

**Trade-off**: Minimal overhead for massive meta-market possibilities

## Security Considerations

### 1. Manipulation Resistance
- **Sybil Attack**: Creating fake markets to mint tokens
  - **Mitigation**: Market creation costs (registration fees)
  - **Future**: Require TVL threshold for token minting

### 2. Oracle Reliability
- Meta-markets need reliable on-chain data
- Use indexed events + on-chain verification

### 3. Circular Dependency
- PMHOOK value depends on hook usage
- Hook usage may depend on PMHOOK value
- **Feature, not bug**: Creates alignment

## Deployment Strategy

1. **Phase 1: Hook Launch**
   - Deploy hook without token awareness
   - Build initial adoption

2. **Phase 2: Token Discovery**
   - Community discovers hook is ERC20
   - Early markets use PMHOOK collateral
   - Price discovery begins

3. **Phase 3: Meta-Market Ecosystem**
   - Dedicated meta-markets for hook metrics
   - PMHOOK trading on DEXs
   - Liquidity incentives

4. **Phase 4: Governance**
   - Token-weighted voting
   - Protocol parameter upgrades
   - Fee distribution

## Example Meta-Markets

### Q1 2026
```
1. "Will hook process >$100M volume in Q1?"
   - Collateral: PMHOOK
   - Resolution: Indexed volume

2. "Will hook have >200 active markets?"
   - Collateral: PMHOOK
   - Resolution: totalSupply / 1000e18 >= 200

3. "Will average market TVL exceed $50k?"
   - Collateral: PMHOOK
   - Resolution: sum(tvl) / markets >= 50000e18
```

### Annual (2026)
```
4. "Will PMHOOK market cap exceed $10M?"
   - Collateral: PMHOOK
   - Resolution: totalSupply * PMHOOK_price >= 10e6

5. "Will hook become #1 PM hook by volume?"
   - Collateral: PMHOOK
   - Resolution: Indexed competitive analysis
```

## Reflexivity Analysis

**Positive Spiral**:
```
Meta-market → Hook awareness → More usage → Token value ↑ → More meta-markets
```

**Negative Spiral**:
```
Low adoption → Token value ↓ → Bearish meta-markets → Less usage → Lower adoption
```

**Equilibrium**:
- Market finds natural adoption level
- PMHOOK price reflects true hook utility
- Meta-markets provide price discovery

## Comparison: Hook Token vs Traditional Metrics

| Metric | Traditional | PMHOOK |
|--------|-------------|--------|
| **Adoption** | Off-chain tracking | On-chain supply |
| **Value** | Subjective | Market-determined |
| **Incentives** | None | Token holders benefit |
| **Governance** | Centralized | Token-weighted |
| **Liquidity** | N/A | DEX-tradeable |

## Killer Feature

**Meta-markets ARE the adoption signal**

- Bullish meta-market → Attracts users → Increases adoption → Validates prediction
- Self-fulfilling prophecy becomes the product
- Token price = hook success index

This turns a hook into a **tradeable prediction about its own success**.

## Integration with Resolver.sol

```solidity
// Resolver can create meta-markets automatically

function createHookAdoptionMarket(
    address hook,
    uint256 targetMarkets,
    uint64 deadline
) external returns (uint256 marketId) {
    // Use hook token as collateral
    marketId = _createMarket(
        hook, // PMHOOK is collateral
        deadline,
        bytes(abi.encodePacked(
            "adoption>=",
            targetMarkets
        ))
    );

    // Resolution: Check if hook.totalSupply() / 1000e18 >= targetMarkets
}
```

## Summary

The hook-as-ERC20 creates:
1. **Tokenized adoption metric** (supply = markets)
2. **Meta-market collateral** (PMHOOK-denominated)
3. **Reflexive economics** (usage → value → usage)
4. **Governance substrate** (token-weighted voting)
5. **Speculation vehicle** (trade hook success directly)

**The hook becomes a market predicting its own adoption.**
