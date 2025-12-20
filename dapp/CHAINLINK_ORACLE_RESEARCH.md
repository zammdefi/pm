# Chainlink Oracle Integration for UNI/USD Price Markets

## Oracle Details

### UNI/USD Price Feed
- **Contract Address:** `0x553303d460EE0afB37EdFf9bE42922D8FF63220e`
- **ENS Name:** `uni-usd.data.eth`
- **Network:** Ethereum Mainnet
- **Type:** EACAggregatorProxy (External Access Controlled Aggregator Proxy)

### Interface Analysis

From `EACAggregatorProxy.sol`:

```solidity
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function latestAnswer() external view returns (int256);
  function latestRoundData() external view returns (
    uint80 roundId,
    int256 answer,
    uint256 startedAt,
    uint256 updatedAt,
    uint80 answeredInRound
  );
}
```

## Key Functions

### 1. `latestAnswer()` - RECOMMENDED FOR RESOLVER
- **Signature:** `function latestAnswer() external view returns (int256)`
- **Selector:** `0x50d25bcd`
- **Returns:** Current price as int256
- **Example Return:** `619655811` (with 8 decimals = $6.19655811)

### 2. `decimals()`
- **Signature:** `function decimals() external view returns (uint8)`
- **Selector:** `0x313ce567`
- **Returns:** `8` for UNI/USD (standard for USD pairs)

### 3. `latestRoundData()` - More comprehensive but complex
- Returns round data with timestamps
- Better for production but overkill for simple price checks

## Decimal Handling

**Chainlink USD Pairs Convention:**
- USD pairs use **8 decimals**
- Example: `619655811` represents `$6.19655811`
- Formula: `actualPrice = rawValue / 10^8`

**Example Calculations:**
```
Raw Value: 619655811
Decimals: 8
Actual Price: 619655811 / 100000000 = $6.19655811

Raw Value: 1500000000
Decimals: 8
Actual Price: 1500000000 / 100000000 = $15.00

Raw Value: 500000000
Decimals: 8
Actual Price: 500000000 / 100000000 = $5.00
```

## Market Configuration for Resolver.sol

### Resolver Op Enum
```solidity
enum Op {
    LT,   // 0: <   "Price goes below X"
    GT,   // 1: >   "Price goes above X"
    LTE,  // 2: <=  "Price at or below X"
    GTE,  // 3: >=  "Price at or above X"
    EQ,   // 4: ==  "Price exactly X" (rare for oracles)
    NEQ   // 5: !=  "Price changes from X" (rare for oracles)
}
```

### Market Creation Parameters

**Target:** `0x553303d460EE0afB37EdFf9bE42922D8FF63220e` (UNI/USD Oracle)
**callData:** `0x50d25bcd` (latestAnswer() selector, no parameters)
**Operator:** User choice (GT, LT, GTE, LTE)
**Threshold:** User price in 8 decimals (e.g., `1000000000` = $10.00)

### Example Market Scenarios

#### 1. "Will UNI reach $10 by end of 2026?"
```javascript
{
  target: '0x553303d460EE0afB37EdFf9bE42922D8FF63220e',
  callData: '0x50d25bcd',
  op: 3, // GTE (>=)
  threshold: 1000000000n, // $10.00 in 8 decimals
  close: 1798761599, // Dec 31 2026
  canClose: true // Allow early resolution when price hits
}
```

#### 2. "Will UNI drop below $5 by Q2 2027?"
```javascript
{
  target: '0x553303d460EE0afB37EdFf9bE42922D8FF63220e',
  callData: '0x50d25bcd',
  op: 0, // LT (<)
  threshold: 500000000n, // $5.00 in 8 decimals
  close: 1719792000, // Jun 30 2027
  canClose: true
}
```

#### 3. "Will UNI stay above $8 until end of year?"
```javascript
{
  target: '0x553303d460EE0afB37EdFf9bE42922D8FF63220e',
  callData: '0x50d25bcd',
  op: 3, // GTE (>=)
  threshold: 800000000n, // $8.00 in 8 decimals
  close: 1735689599, // Dec 31 2025
  canClose: false // Must wait until deadline (price needs to STAY above)
}
```

## Market Type Detection

Add new market type:
```javascript
const MARKET_TYPE = {
    V4_FEE_SWITCH: 'V4_FEE_SWITCH',
    UNI_BALANCE: 'UNI_BALANCE',
    UNI_VOTES: 'UNI_VOTES',
    TOTAL_SUPPLY: 'TOTAL_SUPPLY',
    UNI_PRICE_USD: 'UNI_PRICE_USD', // NEW
    UNKNOWN: 'UNKNOWN'
};
```

**Detection Logic:**
```javascript
const CHAINLINK_UNI_USD_ORACLE = '0x553303d460EE0afB37EdFf9bE42922D8FF63220e';
const LATEST_ANSWER_SELECTOR = '0x50d25bcd';

function detectMarketType(condition) {
    const { targetA, callDataA } = condition;

    // Chainlink UNI/USD Oracle
    if (targetA.toLowerCase() === CHAINLINK_UNI_USD_ORACLE.toLowerCase()) {
        const selector = callDataA.toLowerCase().slice(0, 10);
        if (selector === LATEST_ANSWER_SELECTOR.toLowerCase()) {
            return MARKET_TYPE.UNI_PRICE_USD;
        }
    }

    // ... other checks
}
```

## UI Display

### Price Formatting
```javascript
// Convert threshold from 8 decimals to display
function formatOraclePrice(threshold) {
    // threshold is BigInt with 8 decimals
    return (Number(threshold) / 1e8).toFixed(2);
}

// Example: 1500000000n => "$15.00"
```

### Market Card Display
```
UNI-PRICE | $10.50 | 45% YES
Will UNI reach $10.50 by Dec 2026?
Current: $6.20 | Target: $10.50 | Upside: 69%
```

### Creator Form
```
[UNI Price Market]

Current UNI Price: $6.20 (live from oracle)

Target Price: [____] USD
Condition: [>= ▼]
  Options: >= (at or above), > (above), <= (at or below), < (below)

Deadline: [End of 2026 ▼]
Early Close: [Yes ✓] Allow resolution when price hits

Preview: "UNI price >= $10.00 by Dec 31, 2026"
```

## Access Control Note

The oracle has `checkAccess()` modifier but typically allows public reads for pricing data. Resolver.sol calls are view-only so should work without special permissions.

## Security Considerations

1. **Oracle Updates:** Chainlink oracles update based on deviation threshold (typically 0.5-1% for major pairs)
2. **Stale Data:** Check `updatedAt` timestamp if using `latestRoundData()`
3. **Negative Prices:** `latestAnswer()` returns `int256` (can be negative theoretically)
4. **Decimal Consistency:** Always use 8 decimals for USD pairs

## Testing Checklist

- [x] Verify oracle address on Etherscan
- [ ] Query current price via RPC
- [ ] Verify decimals = 8
- [ ] Test function selector calculation
- [ ] Create test market on-chain
- [ ] Verify price display formatting
- [ ] Test all operator types (GT, LT, GTE, LTE)
- [ ] Verify market filtering by oracle address

## References

- [Chainlink UNI/USD Feed](https://data.chain.link/ethereum/mainnet/crypto-usd/uni-usd)
- [Chainlink Docs - Price Feeds](https://docs.chain.link/data-feeds/price-feeds)
- [EACAggregatorProxy Source](./EACAggregatorProxy.sol)
- [Function Selector Calculator](https://emn178.github.io/online-tools/keccak_256.html)

## Implementation Status

- [ ] Add constants to uniPM.html
- [ ] Update market type detection
- [ ] Create UNI Price market creator UI
- [ ] Add price formatting utilities
- [ ] Update market rendering for price markets
- [ ] Create comprehensive test suite
- [ ] Document user guide
