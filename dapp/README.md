# PM Dapps

Single-file HTML dapps for prediction markets.

## Quick Start

Start a local server from the repository root:

```bash
# Using npx serve (recommended)
npx serve .

# Or using Python
python3 -m http.server 3000

# Or using Node's http-server
npx http-server .
```

Then open in your browser:
- **Gas PM**: http://localhost:3000/dapp/gasPM.html
- **PNK PM**: http://localhost:3000/dapp/pnkPM.html
- **UNI PM**: http://localhost:3000/dapp/uniPM.html

### Browser Console

Once the page is loaded, you can interact with the contracts via the browser console:

```javascript
// Get the ethers provider
const provider = new ethers.BrowserProvider(window.ethereum);

// Get a signer (requires wallet connection)
const signer = await provider.getSigner();

// Core contract addresses
const PAMM = '0x000000000044bfe6c2BBFeD8862973E0612f07C0';
const ZAMM = '0x000000000000040470635EB91b7CE4D132D616eD';
const Resolver = '0x00000000002205020E387b6a378c05639047BcFB';

// Router contracts
const MasterRouter = '0x000000000055CdB14b66f37B96a571108FFEeA5C';
const PMHookRouter = '0x0000000000BADa259Cb860c12ccD9500d9496B3e';
const PMHookQuoter = '0x0000000000f0bf4ea3a43560324376e62fe390bc';

// Example: Read market data
const pamm = new ethers.Contract(PAMM, ['function getMarket(bytes32) view returns (tuple)'], provider);
```

## Files

- `gasPM.html` - Ethereum gas price prediction markets
- `pnkPM.html` - PNKSTR CryptoPunks treasury prediction markets
- `uniPM.html` - UNI-collateralized prediction markets

## Architecture

### Routing System

All dapps use a unified routing system:

- **MasterRouter**: Primary router for trading and limit orders
  - `buyWithSweep`: Sweeps pooled orderbook asks, then falls back to AMM
  - `sellWithSweep`: Sweeps pooled orderbook bids, then falls back to AMM
  - `mintAndPool` / `depositSharesToPool`: Create limit orders in pooled orderbook
  - `withdrawFromPool` / `withdrawFromBidPool`: Cancel limit orders

- **PMHookRouter**: Vault-based liquidity provision
  - `provideLiquidity`: Split collateral between vault bootstrap and AMM LP

- **PMHookQuoter**: View contract for quotes and orderbook data
  - `getActiveLevels`: Get active price levels in the pooled orderbook
  - `getUserActivePositions`: Get user's limit order positions
  - `getQuote`: Get expected output for a trade

### Pooled Orderbook

Limit orders use a pooled orderbook model:
- Orders at the same price level are aggregated into pools
- No individual order hashes - positions tracked by (market, side, price)
- Efficient sweeping during market orders

## How It Works

### Trading
- **Buy/Sell**: Trade YES/NO shares via pooled orderbook + AMM with smart routing
- **Limit Orders**: Place bids/asks at specific prices in pooled orderbook
- **Swap**: Exchange YES ↔ NO shares directly on ZAMM
- **LP**: Provide liquidity to vault + AMM via PMHookRouter

### Resolution
Markets can resolve in two ways:

1. **Early Resolution**: If a market has "early close" enabled, it can be resolved as soon as the condition is met. Anyone can trigger resolution once the condition passes.

2. **Deadline Resolution**: At the market's close time, the condition is checked and the market resolves based on whether the condition is met.

**Outcome**: If the condition is met (e.g., PNKSTR treasury balance >= 40 punks), YES wins. Otherwise, NO wins.

### Claiming
- **Traders**: Click "Claim Winnings" on resolved markets to redeem winning shares
- **LPs**: Withdraw liquidity via the trade modal - automatically claims any winning shares

## Contracts

**Core:**
- PAMM: `0x000000000044bfe6c2BBFeD8862973E0612f07C0`
- ZAMM: `0x000000000000040470635EB91b7CE4D132D616eD`
- Resolver: `0x00000000002205020E387b6a378c05639047BcFB`

**Routers:**
- MasterRouter: `0x000000000055CdB14b66f37B96a571108FFEeA5C`
- PMHookRouter: `0x0000000000BADa259Cb860c12ccD9500d9496B3e`
- PMHookQuoter: `0x0000000000f0bf4ea3a43560324376e62fe390bc`
- Bootstrapper: `0x000000000011Cc5e626DAA3077B655057B37E8bb`
