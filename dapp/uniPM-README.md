# uniPM - Uniswap V4 Prediction Markets

A comprehensive dapp for creating and trading prediction markets related to Uniswap V4 fee activation and UNI token balances.

## Quick Start

### Local Development
```bash
cd /workspaces/pm/dapp
npx http-server .
```
Visit: `http://localhost:8080/uniPM.html`

### Deploy to Production
Upload `uniPM.html` to any static hosting:
- GitHub Pages
- Vercel
- Netlify
- IPFS

## Features

### 🔄 V4 Fee Switch Markets
Create markets betting on when Uniswap V4 will activate protocol fees.

**How it works:**
- Monitors `protocolFeeController()` on V4 PoolManager
- Resolves YES when controller address becomes non-zero
- Default deadline: End of 2026 (customizable)

**Example:**
> "Will Uniswap V4 activate protocol fees by Dec 31, 2026?"

### 💰 UNI Token Balance Markets
Track UNI holdings of any address with ENS support.

**How it works:**
- Monitors `balanceOf(address)` on UNI token contract
- Supports `>`, `<`, `>=`, `<=` operators
- ENS name resolution (e.g., `vitalik.eth`)
- Handles 18 decimals automatically

**Examples:**
> "Will uniswap.eth hold > 100M UNI by 2027?"
> "Will 0xd8da...6045 accumulate >= 50K UNI by Q4 2026?"

## Creating Markets

### V4 Fee Switch Market

1. **Connect Wallet** - Click "Connect" button
2. **Navigate to Tab** - Select "V4 Fee Switch"
3. **Configure:**
   - Condition: `protocolFeeController() != 0` (fixed)
   - Deadline: Choose preset or custom Unix timestamp
   - Early Close: Recommended "Yes"
   - Seed Liquidity: Minimum 0.001 ETH
4. **Create** - Confirm transaction in wallet

**Transaction Details:**
- Target: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- Selector: `0x91d14854`
- Operation: Not Equal (`Op.NEQ = 4`)
- Threshold: `0`

### UNI Balance Market

1. **Connect Wallet**
2. **Navigate to Tab** - Select "UNI Token Balance"
3. **Configure:**
   - Target Address: Enter address or ENS (e.g., `uniswap.eth`)
   - Condition: Select `>`, `<`, `>=`, or `<=`
   - Target Balance: Enter amount in UNI tokens
   - Deadline: Choose preset or custom
   - Early Close: Recommended "Yes"
   - Seed Liquidity: Minimum 0.001 ETH
4. **Create** - Confirm transaction

**Transaction Details:**
- Target: `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984`
- Selector: `0x70a08231`
- Operation: User-selected (GT=1, LT=2, GTE=3, LTE=4)
- Threshold: User amount converted to wei (18 decimals)
- CallData: `balanceOf(targetAddress)` encoded

## ENS Support

The UNI balance creator supports ENS names:

```
Input: vitalik.eth
Resolved: ✓ Resolved to 0xd8da...6045
```

- Automatic resolution on blur/submit
- Visual feedback (green ✓ or red ✗)
- Fallback to direct address input
- Works with any `.eth` name

## Resolution

### When Markets Resolve

**Fee Switch Markets:**
- ✅ YES: When `protocolFeeController()` returns non-zero address
- ❌ NO: If controller remains `address(0)` through deadline
- Early close enabled: Resolves immediately on activation

**UNI Balance Markets:**
- ✅ YES: When balance meets condition
- ❌ NO: If condition not met by deadline
- Early close enabled: Resolves immediately when condition met

### Who Can Resolve?

Anyone can call `resolveMarket(marketId)` once:
- Condition is met (for early close markets), OR
- Deadline has passed

Markets automatically close and resolve through Resolver.sol.

## Technical Details

### Contracts
- **Resolver**: `0x00000000002205020E387b6a378c05639047BcFB`
- **PAMM**: `0x000000000044bfe6c2BBFeD8862973E0612f07C0`
- **V4 PoolManager**: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- **UNI Token**: `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984`

### Network
- Ethereum Mainnet (Chain ID: 1)
- Requires ETH for market creation (seed liquidity)

### Wallet Support
- MetaMask
- WalletConnect v2 (Coinbase Wallet, Rainbow, Trust, etc.)
- Any injected Web3 provider

## UI Reference

### Header Stats
- **V4 Fee Switch**: "Active" or "Inactive" status
- **Markets**: Total number of markets created
- **Pool TVL**: Total value in liquidity pools
- **Book TVL**: Total value in limit order books

### Market Cards
Each market displays:
- Type badge: `UNIV4` or `UNI-BAL`
- Status: Active, Pending, Resolved
- Condition: Human-readable description
- Deadline: Formatted date/time
- Current value: Real-time oracle read
- Trading interface: Buy YES/NO shares
- Orderbook: Live limit orders

### Create Section
- Tab navigation between market types
- Form validation with error messages
- Live preview of market description
- Gas estimation before submission
- Transaction monitoring with Etherscan links

## Governance References

### Uniswap Fee Activation
- **Blog Post**: [Uniswap Fee Unification](https://blog.uniswap.org/unification)
- **Proposal**: [Snapshot Vote](https://snapshot.org/#/s:uniswapgovernance.eth/proposal/0x58d854c1f2468db6b67baab026cca1329c7bcaa5bf834146aa7563a5b45ad09f)

These links are embedded in the "How It Works" section for context on V4 fee markets.

## Advanced Usage

### Custom Deadlines
Use Unix timestamp converter: https://www.unixtimestamp.com/

Example timestamps:
- End of 2026: `1798761599`
- End of 2027: `1830297599`
- End of 2030: `1924991999`

### Multiple Markets
Create multiple markets with different:
- Deadlines (Q1 2027, Q2 2027, etc.)
- Thresholds (>1M UNI, >10M UNI, etc.)
- Addresses (compare different treasuries)

### Liquidity Management
After creation:
- Add more liquidity via "Add Liquidity" button
- Remove liquidity via "Remove Liquidity"
- Trade directly through market interface
- Place limit orders in orderbook

## Troubleshooting

### "Invalid Address or ENS name"
- Ensure address is checksummed or ENS is valid
- Wait for ENS resolution to complete
- Try direct address instead of ENS

### "Deadline must be in the future"
- Check Unix timestamp is > current time
- Use timestamp converter to verify date

### "Insufficient ETH"
- Ensure wallet has enough ETH for:
  - Seed liquidity amount
  - Gas fees (~0.01-0.05 ETH)

### "Transaction Failed"
- Check Etherscan link in toast notification
- Common issues:
  - Insufficient gas
  - Slippage too low
  - Network congestion

## Support

For issues or questions:
- GitHub: [anthropics/claude-code](https://github.com/anthropics/claude-code/issues)
- Docs: See `/docs/uniPM-Features.md`
- Tests: See `/test/UniV4FeeSwitch.t.sol`

## License

MIT License - See project root for details
