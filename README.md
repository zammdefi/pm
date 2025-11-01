# Prediction AMM & Parimutuel — **YES/NO** Markets (wstETH collateral)

Two minimal onchain mechanisms for binary questions:

* **PAMM** — a **pot-split, CPMM-priced** prediction AMM (no orderbook, no external LPs).
* **PM** — a **pure parimutuel**: trade at par until close, then winners split the pot.

Both use **wstETH** as collateral and mint **ERC-6909** YES/NO shares.

---

## TL;DR for traders

* **These are *not* fixed-$1 claims.** At resolution, **winners split a pot**.
* In **PAMM**, your PnL depends on:
  **(A)** what you effectively paid (**average EV per share**), and
  **(B)** the **final payout per winning share = pot ÷ circulating winning shares**
  *(“circulating” excludes protocol & pool balances).*
* In **PM**, you buy/sell **1:1 vs wstETH** until close; then winners split the pot.
* You can **profit by trading** before resolution if the price (implied probability) moves in your favor.
* Longer trading windows usually reduce surprises at resolution.

---

## Contract addresses (Ethereum mainnet)

* **PAMM** (AMM variant): `0x000000000071176401AdA1f2CD7748e28E173FCa`
* **PM** (pure parimutuel): `0x0000000000F8d9F51f0765a9dAd6a9487ba85f1e`
* Collateral: **wstETH** `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
* ETH→wstETH helper (**ZSTETH**): `0x000000000077B216105413Dc45Dc6F6256577c7B`
* PAMM backend (**ZAMM** singleton CPMM): `0x000000000000040470635EB91b7CE4D132D616eD`

---

## What’s the difference?

### PAMM — **Pot-split AMM (pari-mutuel–style)**

* **Pricing/liquidity:** Constant-product pool of **protocol-minted YES/NO** shares (CPMM).
  No orderbook, no **external** LPs; trades are bounded by pool reserves & slippage.
* **Cashflows during trading:**

  * **Buys** pay an **EV charge** (fee-aware path integral) into the **pot**.
  * **Sells** receive a **refund** from the pot (fee-aware), **capped by the pot**.
* **Resolution:** Winners get
  `payout/share = pot ÷ circulating winning shares`
  where “circulating” **excludes** PAMM & ZAMM balances.
  Optional **resolver fee** (≤10%) is skimmed before payouts.
* **Fees & tuning:** CPMM fee = **10 bps** (paid to ZAMM). PAMM supports optional **time/extreme bps** that can increase buy charges and decrease sell refunds.

**Key implication:** Holding the winning side **does not automatically mean profit**. If the side was crowded (many paid high EV), the final payout/share can be below what late buyers paid.

---

### PM — **Pure parimutuel (at-par until close)**

* **Before close:** Buy/sell YES or NO **1:1 vs wstETH**. No slippage, no spread.
  (Buying with ETH auto-wraps through ZSTETH.)
* **After close:** Resolver sets outcome; winners split the pot pro-rata
  (optional resolver fee ≤10% first).
  If **one side is zero** at resolution, contract enters **refund mode** (all shares redeem 1:1).

---

## Quick trader guide (PAMM)

### Reading the price

* Implied **p(YES)** comes from CPMM reserves. UI shows it; it moves when people trade.

### What you pay / receive

* **Buy YES (size = `q`) at price path `p`:** pay roughly the **area under `p`** for `q` (your **EV charge**, fee-aware).
* **Sell YES (`q`):** receive the mirrored **EV refund** (fee-aware), **capped by `pot`**.

Small, instant buy→sell round-trips lose a little to the fee/tuning/rounding wedge.

### Profit conditions

* **At resolution:** profit if
  `your avg EV paid/share < payout/share`
* **Before resolution (swing-trading):** profit if the **sell refund per share** (after fee/tuning) exceeds your **avg EV paid/share**. Pot must be sufficient.

### Payout math (at resolution)

```
payout/share = pot ÷ circulating_winning_shares
circulating_winning_shares = totalSupply[winner]
                             − balanceOf[PAMM][winner]
                             − balanceOf[ZAMM][winner]
```

* Shares **sold back** before close are burned and **don’t** count as circulating.
* Optional resolver fee is taken **before** computing `payout/share`.

### Mini examples

**A) Crowded winner (late buyers can lose)**

* A buys 100 YES around 0.40 → pot ≈ 40; circYES = 100
* B buys 100 YES around 0.70 → pot ≈ 110; circYES = 200
* YES wins ⇒ `payout/share = 110/200 = 0.55`
  A profits (paid ~0.40), B loses (paid ~0.70), despite being right.

**B) Profit by selling before resolution**

* After A’s 0.40 buy, price rises to 0.65; A sells 100 ⇒ refund ≈ 65 (from pot); those 100 YES burn.
* New pot ≈ 45; circYES = 100. If YES wins, `payout/share = 0.45`.
  A realized PnL on the trade; B (still holding) gets 0.45 per share at close.

---

## Quick trader guide (PM)

* **Buy/sell at par** until close: 1 wstETH ↔ 1 YES/NO share.
* **Resolve:** Winners split pot; payout/share = `pot ÷ winningSupply`.
* **Refund mode:** If a side had zero supply at resolve, everyone redeems **1:1**.

---

## For integrators / power users

### PAMM: core flows (names may differ slightly on your client)

* **Create:** `createMarket(description, resolver, close, canClose, seedYes, seedNo [, tuning])`
  Seeds the CPMM with protocol-minted YES/NO (both sides required).
* **Buy YES/NO via pool:**
  `buyYesViaPool(marketId, yesOut, inIsETH, wstInMax, oppInMax, to)`
  `buyNoViaPool(marketId,  noOut, inIsETH, wstInMax, oppInMax, to)`
  Emits `Bought(..., wstIn)`; pot increases by `wstIn`.
* **Sell YES/NO via pool:**
  `sellYesViaPool(marketId, yesIn, wstOutMin, oppOutMin, to)`
  `sellNoViaPool(marketId,  noIn,  wstOutMin, oppOutMin, to)`
  Emits `Sold(..., wstOut)`; pot decreases by `wstOut`.
  *Refunds are floored to current `pot`.*
* **Resolve & claim:**
  `resolve(marketId, outcome)` (optional resolver fee applied)
  `claim(marketId, to)` pays `shares * payoutPerShare` (Q-scaled 1e18 fixed-point).

**Handy views (quotes & state):**

* `quoteBuyYes/quoteBuyNo` → `(oppIn, wstInFair, p0, p1)` fee-aware, path-fair.
* `quoteSellYes/quoteSellNo` → `(oppOut, wstOutFair, p0, p1)` with pot floor.
* `impliedYesProb`, `getMarket`, `getMarkets`, `getUserMarkets`, `winningId`, `getPool`.

**Fees & tuning:**

* CPMM fee: **10 bps** (to ZAMM).
* **PM tuning bps** (optional): late-time ramp and extremes multiplier.
* **Resolver fee**: per-resolver setting, capped at **10%**.

**Edge semantics:**

* **Auto-flip at resolve:** if resolver picks a side with **zero circulating** while the other side **> 0**, the outcome **flips** to the side that actually has circulating winners. If **both** sides have zero circulating, resolution reverts (no winners).

### PM: core flows

* `createMarket(description, resolver, close, canClose)`
* `buyYes/buyNo(amount, to)` — par mint; supports ETH via ZSTETH.
* `sellYes/sellNo(amount, to)` — par burn (pre-close).
* `resolve(marketId, outcome)` — optional resolver fee ≤10%; if one side’s supply is zero, enters **refund mode** (`payoutPerShare = 0`).
* `claim(marketId, to)` — winners get `shares * payoutPerShare`. In refund mode, **any** shares redeem **1:1**.

**Views:** `getMarket`, `getMarkets`, `getUserMarkets`, `tradingOpen`, `impliedYesOdds`, `winningId`.

---

## Key properties & trade-offs (honest mode)

* **No orderbook, no external LPs.** Liquidity is **protocol-owned** (PAMM) or par at mint/burn (PM).
* **PAMM is path-dependent:** buys add to the pot; sells withdraw; late flow can change payout/share.
* **Winning ≠ guaranteed profit (PAMM):** crowded winners can push payout/share below what late buyers paid.
* **Refunds are pot-capped (PAMM):** large sells may be limited by pot balance.
* **Resolver trust:** the resolver picks the outcome and sets an optional fee (≤10%). Consider a multisig/oracle wrapper if needed.

---

## UX tips we surface in the app

* Show **“Est. payout/share now”** = `pot ÷ current circulating winning shares` *(subject to change)*.
* Show each trader’s **avg EV paid/share**.
* Call out **profit condition**: profit only if `avg EV paid/share < payout/share`.
* Flag **reserve/slippage limits** and **pot-floor** on sells.

---

## Local development

* Solidity `^0.8.30`.
* Mainnet constants are in the contracts; for local tests, mock or fork mainnet.
* Suggested testing: create/close/resolve/claim, ETH & wstETH paths, resolver fee, refund mode (PM), Simpson-based quotes (PAMM), reentrancy guard.

---

## License

MIT — see `LICENSE`.

---

### Disclaimers

This code is experimental. No warranties. **Do your own research**, review the code, and consider a full third-party audit before production use. Nothing herein is investment advice.
