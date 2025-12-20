# uniPM.html Dynamic Market Discovery & Delegation Support

## Overview
This update removes hardcoded pnkPM market IDs and adds:
1. **Dynamic market discovery** - Scan ConditionCreated events, filter by target
2. **3 market types** - V4 Fee Switch, UNI Balance, UNI Voting Power
3. **Delegation support** - getCurrentVotes() tracking for governance
4. **Dynamic chart** - Hide until first market created, show first market's pool

## Research: UNI Token Delegation

The UNI token implements Compound-style governance with these functions:
- `getCurrentVotes(address)` - Returns current voting power (delegated balance)
- `getPriorVotes(address, uint256)` - Returns historical voting power at block
- `delegates(address)` - Returns who an address has delegated to

**Sources:**
- [Uniswap Governance Overview](https://docs.uniswap.org/contracts/v3/reference/governance/overview)
- [UNI Token Contract](https://github.com/Uniswap/governance/blob/master/contracts/Uni.sol)
- [Voting Guide](https://docs.uniswap.org/concepts/governance/guide-to-voting)

## Market Type Configurations

### 1. V4 Fee Switch
```javascript
Target: UNIV4_ADDRESS (0x000000000004444c5dc75cB358380D2e3dE08A90)
Selector: 0x91d14854 (protocolFeeController())
Operation: NEQ (4)
Threshold: 0
Filter: targetA === UNIV4_ADDRESS && callDataA === PROTOCOL_FEE_CONTROLLER_SELECTOR
```

### 2. UNI Balance
```javascript
Target: UNI_TOKEN_ADDRESS (0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984)
Selector: 0x70a08231 (balanceOf(address))
Operation: GT/LT/GTE/LTE
Threshold: user wei amount
Filter: targetA === UNI_TOKEN_ADDRESS && callDataA.startsWith(BALANCE_OF_SELECTOR)
```

### 3. UNI Voting Power (NEW)
```javascript
Target: UNI_TOKEN_ADDRESS (0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984)
Selector: 0x9ab24eb0 (getCurrentVotes(address))
Operation: GT/LT/GTE/LTE
Threshold: user wei amount
Filter: targetA === UNI_TOKEN_ADDRESS && callDataA.startsWith(GET_CURRENT_VOTES_SELECTOR)
```

## Code Changes Required

### 1. Add New Constants (after line 1468)

```javascript
// Add these lines after PROTOCOL_FEE_CONTROLLER_SELECTOR:
        const GET_CURRENT_VOTES_SELECTOR = '0x9ab24eb0'; // getCurrentVotes(address)
        const GET_PRIOR_VOTES_SELECTOR = '0x782d6fe1'; // getPriorVotes(address,uint256)

        // Market type identifiers
        const MARKET_TYPE = {
            V4_FEE_SWITCH: 'V4_FEE_SWITCH',
            UNI_BALANCE: 'UNI_BALANCE',
            UNI_VOTES: 'UNI_VOTES',
            UNKNOWN: 'UNKNOWN'
        };
```

### 2. Update UNI_TOKEN_ABI (around line 1481)

```javascript
        const UNI_TOKEN_ABI = [
            'function balanceOf(address owner) view returns (uint256)',
            'function decimals() view returns (uint8)',
            'function symbol() view returns (string)',
            'function getCurrentVotes(address account) view returns (uint256)',
            'function getPriorVotes(address account, uint256 blockNumber) view returns (uint256)',
            'function delegates(address delegator) view returns (address)'
        ];
```

### 3. Add Market Type Detection Functions (after ABIs)

Insert the code from `/tmp/market_type_detector.js`

### 4. Replace loadUniv4Markets Function (around line 1679)

Replace entire `loadUniv4Markets` function with code from `/tmp/dynamic_market_loader.js`

Key changes:
- Remove `KNOWN_UNIV4_MARKETS` constant
- Scan ConditionCreated events (last 50k blocks)
- Filter markets by target (UNIV4 or UNI_TOKEN)
- Detect market type using `detectMarketType()`
- Hide chart if no markets, show first market's pool if markets exist

### 5. Add Third Tab to Creator (around line 972)

```html
            <!-- Market Type Tabs -->
            <div style="display:flex;gap:0.5rem;margin-bottom:1.5rem;border-bottom:1px solid var(--border);">
                <button id="tabFeeSwitch" class="market-tab active" onclick="switchMarketTab('feeSwitch')">
                    V4 Fee Switch
                </button>
                <button id="tabUniBalance" class="market-tab" onclick="switchMarketTab('uniBalance')">
                    UNI Balance
                </button>
                <button id="tabUniVotes" class="market-tab" onclick="switchMarketTab('uniVotes')">
                    UNI Voting Power
                </button>
            </div>
```

### 6. Add UNI Votes Creator HTML

Insert code from `/tmp/delegation_creator.html` after the UNI Balance creator div

### 7. Update switchMarketTab Function

```javascript
        function switchMarketTab(tab) {
            const tabs = document.querySelectorAll('.market-tab');
            const creators = {
                feeSwitch: document.getElementById('creatorFeeSwitch'),
                uniBalance: document.getElementById('creatorUniBalance'),
                uniVotes: document.getElementById('creatorUniVotes')
            };

            tabs.forEach(t => t.classList.remove('active'));
            Object.values(creators).forEach(c => c && (c.style.display = 'none'));

            if (tab === 'feeSwitch') {
                document.getElementById('tabFeeSwitch').classList.add('active');
                creators.feeSwitch.style.display = 'block';
            } else if (tab === 'uniBalance') {
                document.getElementById('tabUniBalance').classList.add('active');
                creators.uniBalance.style.display = 'block';
                updateUniBalancePreview();
            } else if (tab === 'uniVotes') {
                document.getElementById('tabUniVotes').classList.add('active');
                creators.uniVotes.style.display = 'block';
                updateUniVotesPreview();
            }
        }
```

### 8. Add Delegation Creator JS Functions

Insert code from `/tmp/delegation_creator.js` after the `createUniBalanceMarket` function

### 9. Update Chart Section (around line 931-940)

```html
        <!-- Chart Section -->
        <section class="bets-section" id="chartSection" style="padding-bottom:0;display:none;">
            <h2 class="section-title">Odds <span id="featuredOdds" style="font-weight:400;color:var(--text-muted);font-size:var(--font-sm);">--</span></h2>
            <div class="chart-container">
                <iframe
                    id="chartIframe"
                    src=""
                    title="Market Odds"
                    loading="lazy"
                ></iframe>
            </div>
        </section>
```

Changes:
- Add `id="chartSection"` and `style="display:none;"`
- Add `id="chartIframe"` to iframe
- Clear default src (will be set dynamically)

### 10. Update Info Section

```html
                <strong>V4 Fee Switch Markets:</strong> Track whether Uniswap V4 activates protocol fees...<br><br>
                <strong>UNI Balance Markets:</strong> Track UNI token holdings...<br><br>
                <strong>UNI Voting Power Markets:</strong> Track delegated UNI voting power using getCurrentVotes(). Perfect for monitoring governance influence. <a href="https://docs.uniswap.org/concepts/governance/guide-to-voting" target="_blank" style="color:var(--pink);">Learn about delegation ↗</a><br><br>
```

## Testing Checklist

After applying changes:

1. **Verify Constants**
   ```bash
   grep "GET_CURRENT_VOTES_SELECTOR" uniPM.html
   # Should find the constant
   ```

2. **Verify Tabs**
   ```bash
   grep "tabUniVotes" uniPM.html | wc -l
   # Should be > 0
   ```

3. **Test in Browser**
   ```bash
   cd /workspaces/pm/dapp
   npx http-server .
   ```

   Visit: http://localhost:8080/uniPM.html

   - Chart section should be hidden initially
   - Create section should have 3 tabs
   - Click through all 3 tabs - should switch properly
   - Try creating each market type
   - After first market created, chart should appear

4. **Verify Market Discovery**
   - Open browser console
   - Should see: "Found X ConditionCreated events"
   - Should see: "Found X Uniswap-related markets"
   - Markets should be filtered by target address

## Benefits

1. **No Hardcoded IDs** - Markets discovered dynamically
2. **Proper Filtering** - Only show Uniswap ecosystem markets
3. **3 Market Types** - Fee switch, balance, voting power
4. **Clean UX** - Chart hidden until markets exist
5. **Governance Support** - Track delegation/voting power over time

## Example Markets Users Can Create

### V4 Fee Switch
"Will Uniswap V4 activate protocol fees by end of 2026?"

### UNI Balance
"Will Uniswap DAO treasury hold > 100M UNI by Q1 2027?"

### UNI Voting Power (NEW!)
"Will vitalik.eth have > 10M UNI voting power by end of 2026?"
"Will Uniswap Foundation have >= 500M UNI votes by 2027?"

## Files Created

- `/tmp/updated_constants.js` - New constants
- `/tmp/updated_abis.js` - Updated ABIs
- `/tmp/market_type_detector.js` - Type detection logic
- `/tmp/dynamic_market_loader.js` - Event scanning & filtering
- `/tmp/delegation_creator.html` - UI for voting power markets
- `/tmp/delegation_creator.js` - JS for voting power creation

## Next Steps

Apply these changes to `uniPM.html` either:
1. Manually using the code snippets above, OR
2. Using targeted Read/Edit commands for each section

Would you like me to proceed with applying these changes automatically?
