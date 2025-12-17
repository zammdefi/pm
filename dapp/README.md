# PM Dapps

Single-file HTML dapps for prediction markets.

## Quick Start

```bash
cd dapp && npx live-server --port=8080 --open=/pnkPM.html
```

## Files

- `GasPM.html` - Ethereum gas price prediction markets
- `pnkPM.html` - PNKSTR CryptoPunks treasury prediction markets

## How It Works

### Trading
- **Buy/Sell**: Trade YES/NO shares via AMM or limit orders
- **Swap**: Exchange YES ↔ NO shares directly on ZAMM
- **LP**: Provide liquidity to earn trading fees
- **Smart Routing**: Orders automatically route through orderbook or AMM for best price

### Resolution
Markets can resolve in two ways:

1. **Early Resolution**: If a market has "early close" enabled, it can be resolved as soon as the condition is met. Anyone can trigger resolution once the condition passes.

2. **Deadline Resolution**: At the market's close time, the condition is checked and the market resolves based on whether the condition is met.

**Outcome**: If the condition is met (e.g., PNKSTR treasury balance >= 40 punks), YES wins. Otherwise, NO wins.

### Claiming
- **Traders**: Click "Claim Winnings" on resolved markets to redeem winning shares
- **LPs**: Withdraw liquidity via the trade modal - automatically claims any winning shares

## Contracts

- PAMM: `0x000000000044bfe6c2BBFeD8862973E0612f07C0`
- PMRouter: `0x000000000055fF709f26efB262fba8B0AE8c35Dc`
- ZAMM: `0x000000000000040470635EB91b7CE4D132D616eD`
- Resolver: `0x00000000002205020E387b6a378c05639047BcFB`
