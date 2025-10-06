# PredictionMarket – Minimal Parimutuel Yes/No Markets (wstETH-collateral)

A minimalist, gas-efficient prediction market for **binary (YES/NO)** questions. Traders mint and burn ERC-6909 shares at **par (1:1)** against **wstETH** up until the market’s close time. After close, a **resolver** declares the outcome and the **entire pot** is paid **pro-rata** to the winning side (minus an optional resolver fee).

Deployed to Ethereum: [`0x0000000000337f99F242D11AF1908469B0424C8D`](https://etherscan.io/address/0x0000000000337f99f242d11af1908469b0424c8d#code)

> ⚠️ **Heads-up:** This is a **parimutuel pool with free exits**, not a price-discovery AMM. “Odds” are purely **implied by deposits** and can be moved by reversible flows.

---

## Table of contents

* [Why this exists](#why-this-exists)
* [Key properties](#key-properties)
* [How it works](#how-it-works)
* [Contract layout](#contract-layout)
* [Core flows](#core-flows)
* [Programmatic API](#programmatic-api)
* [Events](#events)
* [Security & trust model](#security--trust-model)
* [Economic notes & trade-offs](#economic-notes--trade-offs)
* [UX nuances](#ux-nuances)
* [Recommendations / “nice to have”](#recommendations--nice-to-have)
* [Local development](#local-development)
* [License](#license)

---

## Why this exists

Most onchain prediction markets couple trading with pricing (AMMs, orderbooks, etc.). This repo aims for the **smallest possible surface area**: a **parimutuel mechanism** where:

* 1 wstETH in => 1 share out (YES or NO),
* 1 share in => 1 wstETH out (until close),
* At resolution, the pot goes to the winning side pro-rata.

It’s simple to integrate, easy to reason about, and cheap to use.

---

## Key properties

* **Binary markets**: Each market mints two ERC-6909 tokens:

  * YES: id = `getMarketId(description, resolver)`
  * NO: id = `getNoId(yesId)`
* **Collateral**: `wstETH` (ERC-20). Buying with `ETH` is auto-wrapped via `ZSTETH.exactETHToWSTETH`.
* **At-par trading** *(pre-close)*: Buy or sell shares **1:1** vs. wstETH — no slippage, no spread.
* **Parimutuel settlement** *(post-close)*: Entire `pot` paid to winners pro-rata after optional resolver fee.
* **Resolver permissions**:
  * Can close early if the market was created with `canClose = true`.
  * Must resolve after `close`.
  * May set a **resolver fee** (capped at 10%) via `setResolverFeeBps`.
* **Implied odds**: `yesSupply / (yesSupply + noSupply)` for display only; **not enforceable pricing**.

---

## How it works

1. **Create**

   * Anyone calls `createMarket(description, resolver, close, canClose)`.
   * Market ids are deterministic from `(description, resolver)`.
   * Trading is open immediately and ends when `block.timestamp >= close` (or earlier if resolver closes and `canClose = true`).

2. **Trade (pre-close)**

   * **Buy YES/NO (wstETH)**: `amount` transferred in ⇒ `amount` shares minted ⇒ `pot += amount`.
   * **Buy with ETH**: ETH is routed through `ZSTETH` to wstETH, then same as above.
   * **Sell YES/NO**: Burn shares at par ⇒ receive wstETH ⇒ `pot -= amount`.

3. **Resolve (post-close)**

   * Resolver calls `resolve(marketId, outcome)`.
   * If **both sides nonzero**:
     * optional resolver fee is skimmed from `pot`;
     * `payoutPerShare = pot / winningSupply` (fixed-point, 1e18 scale).
   * If **one side zero**:
     * `payoutPerShare = 0` ⇒ the market becomes **refund mode** (redeem shares 1:1).

4. **Claim**
   * Winners burn shares and receive `shares * payoutPerShare`.
   * In **refund mode**, any shares (YES or NO) redeem 1:1.

---

## Contract layout

* `ERC6909` — minimalist multi-token standard (from Solmate).
* **Constants**
  * `WSTETH`: `IERC20` (mainnet address baked in)
  * `ZSTETH`: wrapper to swap exact ETH → wstETH
* **PredictionMarket** — the market logic
  * `createMarket`, `closeMarket`, `buyYes`, `buyNo`, `sellYes`, `sellNo`, `resolve`, `claim`
  * Views for market/user pagination, odds, winners, trading status
  * Non-reentrancy via transient storage guard
* Helpers
  * `mulDiv` w/ checked overflow
  * Deterministic id helpers: `getMarketId`, `getNoId`
  * ERC-6909 metadata: `name(id)`, `symbol()`

---

## Core flows

### Create a market

```solidity
(uint256 yesId, uint256 noId) = (
    pm.getMarketId("Will X happen by 2025-12-31?", resolver),
    pm.getNoId(pm.getMarketId("Will X happen by 2025-12-31?", resolver))
);

(uint256 marketId, uint256 createdNoId) = pm.createMarket({
    description: "Will X happen by 2025-12-31?",
    resolver: resolver,
    close: uint72(block.timestamp + 7 days),
    canClose: true
});
```

### Buy YES with wstETH

```solidity
WSTETH.approve(address(pm), 10e18);
pm.buyYes(marketId, 10e18, msg.sender); // mints 10 YES, pot += 10 wstETH
```

### Buy NO with ETH (auto-wrap)

```solidity
pm.buyNo{value: 1 ether}(marketId, 0, msg.sender); // routes via ZSTETH → mints YES/NO at par
```

### Sell back (pre-close)

```solidity
pm.sellYes(marketId, 5e18, msg.sender); // burns 5 YES, returns 5 wstETH, pot -= 5
pm.sellNo(marketId, 2e18, msg.sender);  // burns 2 NO, returns 2 wstETH, pot -= 2
```

### Resolve (post-close)

```solidity
pm.resolve(marketId, /* outcome */ true); // true = YES wins, false = NO wins
```

If both sides had deposits, `payoutPerShare` becomes nonzero. Otherwise the market is in **refund mode** (`payoutPerShare == 0`).

### Claim

```solidity
pm.claim(marketId, msg.sender); // burns winning shares and pays wstETH pro-rata

// In refund mode (payoutPerShare == 0), call claim() once per token id you hold.
```

---

## Programmatic API

### Creation & control

| Function                                               | Description                                                                                                                |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `createMarket(description, resolver, close, canClose)` | Creates a new market. Reverts if `close <= now` or resolver is zero, or market exists.                                     |
| `closeMarket(marketId)`                                | **Resolver-only**, only if `canClose = true`, only **before** scheduled close; sets `close = block.timestamp`.             |
| `resolve(marketId, outcome)`                           | **Resolver-only**, only **after** close; computes fee (if any), sets `payoutPerShare`, marks resolved.                     |
| `setResolverFeeBps(bps)`                               | Sets resolver’s fee (0…1000 bps = 0%…10%). **Applies to all markets resolved by this resolver at the time of resolution.** |

### Trading & claiming

| Function                        | Description                                                                               |
| ------------------------------- | ----------------------------------------------------------------------------------------- |
| `buyYes(marketId, amount, to)`  | Mint YES for wstETH (via `amount`) or ETH (`msg.value`). Increases `pot`. Pre-close only. |
| `buyNo(marketId, amount, to)`   | Mint NO similarly. Pre-close only.                                                        |
| `sellYes(marketId, amount, to)` | Burn YES and withdraw wstETH at par. Pre-close only.                                      |
| `sellNo(marketId, amount, to)`  | Burn NO and withdraw wstETH at par. Pre-close only.                                       |
| `claim(marketId, to)`           | After resolve: pay winners `shares * payoutPerShare`. In refund mode, pays 1:1 per share. |

### Views

| Function                             | Returns                                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------------ |
| `getMarket(marketId)`                | `(yesSupply, noSupply, resolver, resolved, outcome, pot, payoutPerShare, desc)`            |
| `getMarkets(start, count)`           | Batched page across `allMarkets` with the above per-market fields.                         |
| `getUserMarkets(user, start, count)` | User balances and claimables across a page of markets.                                     |
| `tradingOpen(marketId)`              | True if resolver set, not resolved, and `now < close`.                                     |
| `impliedYesOdds(marketId)`           | `(numerator, denominator)` where `odds = num/denom = yes / (yes + no)` (**display only**). |
| `winningId(marketId)`                | Winning token id **only if** resolved and `payoutPerShare != 0`; else `0`.                 |
| `marketCount()`                      | Number of created markets.                                                                 |

---

## Events

* `Created(marketId, noId, description, resolver)`
* `Closed(marketId, closedAt, by)`
* `Bought(buyer, id, amount)`
* `Sold(seller, id, amount)`
* `Resolved(marketId, outcome)`
* `Claimed(claimer, id, shares, payout)`
* `ResolverFeeSet(resolver, bps)`
* ERC-6909: `Transfer`, `Approval`, `OperatorSet`

---

## Security & trust model

* **Collateral safety**: Uses wstETH (standard ERC-20). The ETH path depends on `ZSTETH.exactETHToWSTETH`.
* **Reentrancy**: All state-changing entrypoints that move funds are protected with a transient-storage guard.
* **Math safety**: `mulDiv` checks for overflow/invalid division; fixed-point `payoutPerShare` (1e18) keeps rounding small.
* **Resolver trust**:
  * Resolver can **early-close** if `canClose = true`.
  * Resolver sets **fee bps** globally for itself; the fee in force at *resolution time* is used.
  * Resolver decides final **outcome**; no onchain dispute process here.

> If trust minimization is required, wrap the resolver in a multisig, governance, or external oracle.

---

## Economic notes & trade-offs

* **No pricing curve**: Buy/sell at par. “Odds” are **deposit ratios**, so they’re cheap to manipulate and **not binding prices**.
* **Bank-run incentive**: Losers can exit at par right before close, shrinking the pot. Winners who don’t exit-dance can be penalized by timing risk.
* **Refund mode**: If only one side has deposits at resolution, everyone gets 1:1 back.
* **Fee dynamics**: The resolver can change fee bps up to resolution time (bounded to 10%). This is visible onchain but can be adversarial from a UX standpoint.

---

## UX nuances

* **Claiming in refund mode**: `claim()` handles one token id at a time; if a user holds both YES and NO, they’ll need two calls.
* **Odds labeling**: Always label `impliedYesOdds()` as *implied by deposits*, not *market price*.

---

## Local development

* **Solidity**: `^0.8.30`
* **Dependencies**: Solmate-style ERC-6909 is embedded here (no external import needed at runtime).
* **Tests**: Write your own Foundry/Hardhat tests targeting:
  * create/close/resolve/claim paths,
  * ETH and wstETH buy flows,
  * fee application at resolution,
  * refund mode correctness,
  * reentrancy guard.

### Example (Foundry skeleton)

```sh
forge test
```

```solidity
contract PredictionMarketTest is Test {
    PredictionMarket pm;
    address resolver = vm.addr(1);
    function setUp() public {
        pm = new PredictionMarket();
        // mock wstETH/ZSTETH if you’re on a local fork or create adapters
    }
}
```

> Mainnet constants (`WSTETH`, `ZSTETH`) are hard-coded; for local tests you’ll likely mock or fork mainnet.

---

## License

MIT — see `LICENSE`.

---

### Disclaimers

This codebase is research/educational in spirit. Use at your own risk. Nothing herein is investment advice. If deploying to production, perform a **full security review**, add **robust tests**, and consider the **resolver trust** implications for your users.
