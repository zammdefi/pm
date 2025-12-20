# uniPM.html - Uniswap V4 Prediction Markets

## Overview
A fully-featured dapp for creating and trading Uniswap-related prediction markets using the Resolver.sol singleton.

## Market Types

### 1. V4 Fee Switch Markets
**Condition:** `protocolFeeController() != 0`

Track whether Uniswap V4 activates protocol fees by monitoring the V4 PoolManager contract.

**Features:**
- Checks if `protocolFeeController()` returns non-zero address
- Default deadline: End of 2026 (customizable via Unix timestamp)
- Early close enabled by default
- Operator: `Op.NEQ` (not equal to 0)
- Threshold: `0`

**Contract Details:**
- Target: `0x000000000004444c5dc75cB358380D2e3dE08A90` (V4 PoolManager)
- Selector: `0x91d14854` (protocolFeeController())
- Market resolves YES when fee switch is activated

### 2. UNI Token Balance Markets
**Condition:** `balanceOf(address) [operator] threshold`

Track UNI token holdings of any Ethereum address over time.

**Features:**
- Target any address (EOA, multisig, DAO treasury, etc.)
- **ENS Support:** Enter ENS names (e.g., `vitalik.eth`) - automatically resolved
- Operators: `>`, `<`, `>=`, `<=`
- 18 decimal handling (enter amount in UNI, auto-converts to wei)
- Perfect for tracking treasury/multisig holdings

**Contract Details:**
- Target: `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` (UNI Token)
- Selector: `0x70a08231` (balanceOf(address))
- Threshold: User-specified amount in UNI tokens

**Use Cases:**
- Will Uniswap DAO treasury hold > 100M UNI by 2027?
- Will address X accumulate > 10K UNI by Q4 2026?
- Tracking multisig holdings over time

## Key Features

### ENS Resolution
- Automatically resolves `.eth` names to addresses
- Real-time validation and display
- Fallback to direct address input
- Visual feedback (✓ resolved, ✗ not found)

### Dual Creator Interface
- Tab-based UI for switching between market types
- Type-specific form validation
- Live preview of market description
- Separate creation functions for each type

### Market Display
- Markets tagged by type: `UNIV4` or `UNI-BAL`
- Real-time balance tracking
- Live status: "Active" / "Inactive" for fee switch
- Token balance display with proper decimal formatting

### Governance Links
Integrated links to Uniswap governance:
- [Fee Unification Blog Post](https://blog.uniswap.org/unification)
- [Snapshot Governance Proposal](https://snapshot.org/#/s:uniswapgovernance.eth/proposal/0x58d854c1f2468db6b67baab026cca1329c7bcaa5bf834146aa7563a5b45ad09f)

## Technical Implementation

### Constants
```javascript
const UNI_TOKEN_ADDRESS = '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984';
const UNIV4_ADDRESS = '0x000000000004444c5dc75cB358380D2e3dE08A90';
const PROTOCOL_FEE_CONTROLLER_SELECTOR = '0x91d14854';
const BALANCE_OF_SELECTOR = '0x70a08231';
const EOY_2026 = 1798761599; // Dec 31, 2026 23:59:59 UTC
```

### ABIs
```javascript
const UNI_TOKEN_ABI = [
    'function balanceOf(address owner) view returns (uint256)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)'
];

const UNIV4_ABI = [
    'function protocolFeeController() view returns (address)'
];
```

### Key Functions

#### `switchMarketTab(tab)`
Switches between fee switch and UNI balance creators.

#### `resolveENS(input)`
Resolves ENS names to Ethereum addresses using ethers.js provider.

#### `createFeeSwitchMarket()`
Creates V4 protocol fee controller markets:
- Observable: `Uniswap V4 protocolFeeController()`
- Operation: `Op.NEQ` (4)
- Threshold: `0`
- Target: V4 PoolManager

#### `createUniBalanceMarket()`
Creates UNI token balance markets:
- Observable: `UNI balance of [address]`
- Operation: User-selected (GT, LT, GTE, LTE)
- Threshold: User-specified in UNI (converted to wei)
- Target: UNI Token contract
- CallData: `balanceOf(targetAddress)` encoded

## Usage

### Creating a Fee Switch Market
1. Navigate to "V4 Fee Switch" tab
2. Select deadline (default: End of 2026, or custom Unix timestamp)
3. Choose early close option (recommended: Yes)
4. Enter seed liquidity (min 0.001 ETH)
5. Click "Create Fee Switch Market"

### Creating a UNI Balance Market
1. Navigate to "UNI Token Balance" tab
2. Enter target address or ENS name (e.g., `uniswap.eth`)
3. Select condition operator (>, <, >=, <=)
4. Enter target balance in UNI tokens (e.g., `1000000` for 1M UNI)
5. Select deadline
6. Choose early close option
7. Enter seed liquidity
8. Click "Create UNI Balance Market"

## Market Tagging
Markets are automatically tagged in the UI:
- **UNIV4**: V4 fee switch markets (protocolFeeController check)
- **UNI-BAL**: UNI token balance markets (balanceOf check)

## Resolution Logic

### Fee Switch Markets
- **YES**: `protocolFeeController() != address(0)` (fee switch activated)
- **NO**: Controller remains `address(0)` through deadline
- Early close: Resolves immediately when controller becomes non-zero

### UNI Balance Markets
- **YES**: Balance condition met (e.g., `balance > threshold`)
- **NO**: Balance condition not met by deadline
- Early close: Resolves immediately when condition becomes true

## Styling
- Primary color: Uniswap pink (`#FF007A`)
- Tab-based navigation with active state highlighting
- Responsive design for mobile/desktop
- Dark theme optimized for trading

## Integration
Built on:
- **Resolver.sol**: Universal numeric oracle singleton
- **PAMM**: Prediction market AMM
- **zAMM**: Underlying CFMM
- **Ethers.js v6**: Web3 interactions
- **WalletConnect v2**: Multi-wallet support

## Links
- V4 PoolManager: [0x0000...08A90](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90)
- UNI Token: [0x1f98...F984](https://etherscan.io/token/0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984)
- Resolver: [0x0000...BcFB](https://etherscan.io/address/0x00000000002205020E387b6a378c05639047BcFB)
- PAMM: [0x0000...07C0](https://etherscan.io/address/0x000000000044bfe6c2BBFeD8862973E0612f07C0)

## Example Markets

### Fee Switch Example
```
Observable: Uniswap V4 protocolFeeController()
Target: 0x000000000004444c5dc75cB358380D2e3dE08A90
Operation: != 0
Deadline: Dec 31, 2026
Early Close: Yes
```

### UNI Balance Example
```
Observable: UNI balance of 0xd8da...6045
Target: 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984
Operation: > 1000000000000000000000000 (1M UNI in wei)
Deadline: Dec 31, 2026
Early Close: Yes
```

## Testing
Open the file locally:
```bash
cd /workspaces/pm/dapp
npx http-server .
# Visit: http://localhost:8080/uniPM.html
```

Or deploy to any static hosting (GitHub Pages, Vercel, etc.)

## Security Considerations
- All contract interactions through Resolver.sol (audited)
- Read-only oracle calls (protocolFeeController, balanceOf)
- ENS resolution uses official ethers.js provider
- No direct token approvals required for market creation
- Markets use ETH as collateral (msg.value)
