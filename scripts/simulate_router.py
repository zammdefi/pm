#!/usr/bin/env python3
"""
Simulate PMHookRouter + PMFeeHook behavior under various liquidity conditions.

Models:
- AMM constant product with dynamic fees
- Hook price impact limits (12% max)
- Vault OTC spread (1% base + imbalance + time boosts, capped at 5%)
- 30% vault depletion cap per fill
"""

from dataclasses import dataclass
from typing import Tuple, Optional
import math

# =============================================================================
# PMFeeHook Default Config
# =============================================================================
MIN_FEE_BPS = 10          # 0.10% steady-state
MAX_FEE_BPS = 75          # 0.75% bootstrap start
BOOTSTRAP_WINDOW = 2 * 24 * 3600  # 2 days in seconds
MAX_PRICE_IMPACT_BPS = 1200       # 12%
MAX_SKEW_FEE_BPS = 80     # 0.80%
SKEW_REF_BPS = 4000       # 90/10 triggers max
ASYMMETRIC_FEE_BPS = 20   # 0.20%
FEE_CAP_BPS = 300         # 3%

# =============================================================================
# PMHookRouter Default Config
# =============================================================================
MIN_ABSOLUTE_SPREAD_BPS = 20   # 0.2%
MAX_SPREAD_BPS = 500           # 5% cap
BASE_RELATIVE_SPREAD_BPS = 100 # 1%
MAX_IMBALANCE_BOOST_BPS = 400  # 4%
MAX_TIME_BOOST_BPS = 200       # 2%
MAX_VAULT_DEPLETION_PCT = 30   # 30%

# =============================================================================
# Simulation Classes
# =============================================================================

@dataclass
class PoolState:
    """AMM pool state (YES/NO reserves)"""
    yes_reserve: float
    no_reserve: float

    @property
    def total(self) -> float:
        return self.yes_reserve + self.no_reserve

    @property
    def p_yes(self) -> float:
        """P(YES) = NO / (YES + NO)"""
        if self.total == 0:
            return 0.5
        return self.no_reserve / self.total

    @property
    def p_yes_bps(self) -> int:
        return int(self.p_yes * 10000)


@dataclass
class VaultState:
    """Vault inventory state"""
    yes_shares: float
    no_shares: float

    @property
    def total(self) -> float:
        return self.yes_shares + self.no_shares

    @property
    def imbalance_bps(self) -> int:
        """Imbalance as bps (5000 = balanced, 10000 = fully one-sided)"""
        if self.total == 0:
            return 5000
        larger = max(self.yes_shares, self.no_shares)
        return int((larger / self.total) * 10000)


@dataclass
class TradeResult:
    """Result of a simulated trade"""
    venue: str  # "amm", "otc", "mint", "mult", "rejected"
    shares_out: float
    collateral_in: float
    effective_price_bps: int  # Price paid in bps
    price_impact_bps: int     # Probability change in bps
    fee_bps: int              # Fee charged
    rejected_reason: Optional[str] = None

    @property
    def succeeded(self) -> bool:
        return self.venue != "rejected"


# =============================================================================
# Fee Calculation (PMFeeHook logic)
# =============================================================================

def calculate_hook_fee(pool: PoolState, elapsed_seconds: int = 0) -> int:
    """Calculate dynamic AMM fee based on hook config"""
    # Bootstrap fee (linear decay)
    if elapsed_seconds < BOOTSTRAP_WINDOW:
        progress = elapsed_seconds / BOOTSTRAP_WINDOW
        base_fee = MAX_FEE_BPS - int((MAX_FEE_BPS - MIN_FEE_BPS) * progress)
    else:
        base_fee = MIN_FEE_BPS

    # Skew fee (quadratic curve)
    p_bps = pool.p_yes_bps
    skew = abs(p_bps - 5000)
    if skew >= SKEW_REF_BPS:
        skew_fee = MAX_SKEW_FEE_BPS
    else:
        ratio = skew / SKEW_REF_BPS
        skew_fee = int(MAX_SKEW_FEE_BPS * ratio * ratio)  # Quadratic

    # Asymmetric fee (linear)
    deviation = abs(p_bps - 5000)
    asymmetric_fee = int(ASYMMETRIC_FEE_BPS * deviation / 5000)

    total = base_fee + skew_fee + asymmetric_fee
    return min(total, FEE_CAP_BPS)


# =============================================================================
# AMM Simulation
# =============================================================================

def simulate_amm_buy(pool: PoolState, collateral_in: float, buy_yes: bool,
                     fee_bps: int) -> Tuple[float, int, bool]:
    """
    Simulate AMM buy: split collateral, swap opposite side for desired.

    Returns: (shares_out, price_impact_bps, would_succeed)
    """
    if pool.yes_reserve == 0 or pool.no_reserve == 0:
        return 0, 0, False

    # Record pre-trade probability
    p_before = pool.p_yes_bps

    # Split collateral into YES + NO
    split_yes = collateral_in
    split_no = collateral_in

    # Swap the opposite side for desired
    # If buying YES: swap NO for YES
    if buy_yes:
        reserve_in = pool.no_reserve
        reserve_out = pool.yes_reserve
    else:
        reserve_in = pool.yes_reserve
        reserve_out = pool.no_reserve

    # Constant product with fee
    amount_in = collateral_in
    amount_in_with_fee = amount_in * (10000 - fee_bps)
    numerator = amount_in_with_fee * reserve_out
    denominator = (reserve_in * 10000) + amount_in_with_fee
    swap_out = numerator / denominator

    if swap_out >= reserve_out:
        return 0, 0, False  # Would drain pool

    # Total shares received
    shares_out = collateral_in + swap_out

    # Calculate post-trade reserves and price impact
    if buy_yes:
        new_yes = pool.yes_reserve - swap_out
        new_no = pool.no_reserve + amount_in
    else:
        new_yes = pool.yes_reserve + amount_in
        new_no = pool.no_reserve - swap_out

    new_pool = PoolState(new_yes, new_no)
    p_after = new_pool.p_yes_bps

    price_impact = abs(p_after - p_before)

    # Check price impact limit
    would_succeed = price_impact <= MAX_PRICE_IMPACT_BPS

    return shares_out, price_impact, would_succeed


# =============================================================================
# Vault OTC Simulation
# =============================================================================

def calculate_vault_spread(vault: VaultState, buy_yes: bool,
                          hours_to_close: float = 168) -> int:
    """Calculate vault OTC spread based on inventory and time"""
    spread = BASE_RELATIVE_SPREAD_BPS

    # Imbalance boost (only when consuming scarce side)
    yes_scarce = vault.yes_shares < vault.no_shares
    consuming_scarce = (buy_yes and yes_scarce) or (not buy_yes and not yes_scarce)

    if consuming_scarce and vault.total > 0:
        imbalance = vault.imbalance_bps
        if imbalance > 5000:
            excess = imbalance - 5000
            boost = int(MAX_IMBALANCE_BOOST_BPS * excess / 5000)
            spread += boost

    # Time boost (last 24 hours)
    if hours_to_close < 24:
        time_boost = int(MAX_TIME_BOOST_BPS * (24 - hours_to_close) / 24)
        spread += time_boost

    return min(spread, MAX_SPREAD_BPS)


def simulate_vault_otc(vault: VaultState, collateral_in: float, buy_yes: bool,
                       twap_p_yes_bps: int, hours_to_close: float = 168) -> Tuple[float, float, bool]:
    """
    Simulate vault OTC fill.

    Returns: (shares_out, collateral_used, filled)
    """
    available = vault.yes_shares if buy_yes else vault.no_shares
    if available == 0:
        return 0, 0, False

    # Get spread
    relative_spread_bps = calculate_vault_spread(vault, buy_yes, hours_to_close)

    # Share price based on TWAP
    if buy_yes:
        share_price_bps = twap_p_yes_bps
    else:
        share_price_bps = 10000 - twap_p_yes_bps

    # Apply spread (hybrid: max of relative and absolute minimum)
    relative_spread = share_price_bps * relative_spread_bps // 10000
    spread_bps = max(relative_spread, MIN_ABSOLUTE_SPREAD_BPS)

    effective_price_bps = min(share_price_bps + spread_bps, 10000)

    # Calculate shares
    raw_shares = collateral_in * 10000 / effective_price_bps

    # 30% depletion cap
    max_from_vault = available * MAX_VAULT_DEPLETION_PCT / 100
    if max_from_vault < 1 and available > 0 and raw_shares > 0:
        max_from_vault = 1

    shares_out = min(raw_shares, max_from_vault, available)

    if shares_out == raw_shares:
        collateral_used = collateral_in
    else:
        collateral_used = math.ceil(shares_out * effective_price_bps / 10000)

    return shares_out, collateral_used, shares_out > 0


# =============================================================================
# Full Trade Simulation
# =============================================================================

def simulate_trade(pool: PoolState, vault: VaultState, collateral_in: float,
                   buy_yes: bool, elapsed_seconds: int = 3600,
                   hours_to_close: float = 168) -> TradeResult:
    """
    Simulate full trade through router logic.
    """
    fee_bps = calculate_hook_fee(pool, elapsed_seconds)
    twap_p_yes = pool.p_yes_bps  # Assume TWAP ~ spot for simulation

    # Try AMM
    amm_shares, amm_impact, amm_ok = simulate_amm_buy(pool, collateral_in, buy_yes, fee_bps)

    # Try Vault OTC
    otc_shares, otc_collateral, otc_ok = simulate_vault_otc(
        vault, collateral_in, buy_yes, twap_p_yes, hours_to_close
    )

    # Determine best execution
    if not amm_ok and not otc_ok:
        return TradeResult(
            venue="rejected",
            shares_out=0,
            collateral_in=collateral_in,
            effective_price_bps=0,
            price_impact_bps=amm_impact if amm_shares > 0 else 0,
            fee_bps=fee_bps,
            rejected_reason=f"AMM impact {amm_impact}bps > {MAX_PRICE_IMPACT_BPS}bps limit"
                           if amm_impact > MAX_PRICE_IMPACT_BPS else "No liquidity"
        )

    # Compare execution quality
    if otc_ok and amm_ok:
        # Check which gives more shares
        if otc_shares >= amm_shares and otc_collateral <= collateral_in:
            # Vault is better or equal
            remaining = collateral_in - otc_collateral
            if remaining > 0:
                # Fill remainder with AMM
                amm2_shares, amm2_impact, amm2_ok = simulate_amm_buy(
                    pool, remaining, buy_yes, fee_bps
                )
                if amm2_ok:
                    total_shares = otc_shares + amm2_shares
                    return TradeResult(
                        venue="mult",
                        shares_out=total_shares,
                        collateral_in=collateral_in,
                        effective_price_bps=int(collateral_in * 10000 / total_shares),
                        price_impact_bps=amm2_impact,
                        fee_bps=fee_bps
                    )

            return TradeResult(
                venue="otc",
                shares_out=otc_shares,
                collateral_in=otc_collateral,
                effective_price_bps=int(otc_collateral * 10000 / otc_shares) if otc_shares > 0 else 0,
                price_impact_bps=0,
                fee_bps=0
            )
        else:
            # AMM is better
            return TradeResult(
                venue="amm",
                shares_out=amm_shares,
                collateral_in=collateral_in,
                effective_price_bps=int(collateral_in * 10000 / amm_shares) if amm_shares > 0 else 0,
                price_impact_bps=amm_impact,
                fee_bps=fee_bps
            )
    elif otc_ok:
        return TradeResult(
            venue="otc",
            shares_out=otc_shares,
            collateral_in=otc_collateral,
            effective_price_bps=int(otc_collateral * 10000 / otc_shares) if otc_shares > 0 else 0,
            price_impact_bps=0,
            fee_bps=0
        )
    else:  # amm_ok
        return TradeResult(
            venue="amm",
            shares_out=amm_shares,
            collateral_in=collateral_in,
            effective_price_bps=int(collateral_in * 10000 / amm_shares) if amm_shares > 0 else 0,
            price_impact_bps=amm_impact,
            fee_bps=fee_bps
        )


# =============================================================================
# Run Simulations
# =============================================================================

def print_header(title: str):
    print(f"\n{'='*80}")
    print(f" {title}")
    print('='*80)


def run_simulations():
    print("\n" + "="*80)
    print(" PMHookRouter + PMFeeHook Simulation")
    print(" Default Settings Analysis")
    print("="*80)

    # Liquidity levels to test (total collateral -> 50/50 split)
    liquidity_levels = [100, 500, 1000, 5000, 10000]

    # Trade sizes to test
    trade_sizes = [10, 25, 50, 100, 150, 200, 300, 500]

    # =========================================================================
    # Simulation 1: AMM-only (price impact analysis)
    # =========================================================================
    print_header("1. AMM Price Impact Analysis (50/50 Pool, 1 hour elapsed)")
    print(f"\n{'Pool $':<10} | {'Trade $':<10} | {'Impact':<10} | {'Status':<12} | {'Fee':<8} | {'Shares Out':<12}")
    print("-" * 75)

    for liq in liquidity_levels:
        pool = PoolState(liq/2, liq/2)  # 50/50 split
        vault = VaultState(0, 0)  # No vault for AMM-only test

        for size in trade_sizes:
            if size > liq * 2:  # Skip unreasonable sizes
                continue

            result = simulate_trade(pool, vault, size, buy_yes=True, elapsed_seconds=3600)

            status = "OK" if result.succeeded else f"REJECTED"
            impact_str = f"{result.price_impact_bps}bps"
            fee_str = f"{result.fee_bps}bps"
            shares_str = f"{result.shares_out:.1f}" if result.succeeded else "-"

            # Highlight rejections
            if not result.succeeded:
                status = f">{MAX_PRICE_IMPACT_BPS}bps"

            print(f"${liq:<9} | ${size:<9} | {impact_str:<10} | {status:<12} | {fee_str:<8} | {shares_str:<12}")

    # =========================================================================
    # Simulation 2: Max trade size before rejection
    # =========================================================================
    print_header("2. Maximum Trade Size Before Price Impact Rejection")
    print(f"\n{'Pool Size':<12} | {'Max Trade':<12} | {'Max as % of Pool':<18} | {'Impact at Max':<15}")
    print("-" * 65)

    for liq in liquidity_levels:
        pool = PoolState(liq/2, liq/2)

        # Binary search for max trade size
        lo, hi = 1, liq * 3
        max_trade = 0
        max_impact = 0

        while lo <= hi:
            mid = (lo + hi) // 2
            _, impact, ok = simulate_amm_buy(pool, mid, True, MIN_FEE_BPS)
            if ok:
                max_trade = mid
                max_impact = impact
                lo = mid + 1
            else:
                hi = mid - 1

        pct = (max_trade / liq) * 100 if liq > 0 else 0
        print(f"${liq:<11} | ${max_trade:<11} | {pct:.1f}%{'':<14} | {max_impact}bps")

    # =========================================================================
    # Simulation 3: Vault OTC vs AMM comparison
    # =========================================================================
    print_header("3. Vault OTC vs AMM Execution Comparison")
    print("   (Pool: $1000 50/50, Vault: $500 YES + $500 NO, balanced)")
    print(f"\n{'Trade $':<10} | {'AMM Shares':<12} | {'OTC Shares':<12} | {'OTC Used':<10} | {'Winner':<8} | {'Savings':<10}")
    print("-" * 75)

    pool = PoolState(500, 500)
    vault = VaultState(500, 500)

    for size in [10, 25, 50, 100, 200]:
        fee = calculate_hook_fee(pool, 3600)
        amm_shares, amm_impact, amm_ok = simulate_amm_buy(pool, size, True, fee)
        otc_shares, otc_coll, otc_ok = simulate_vault_otc(vault, size, True, 5000)

        if amm_ok and otc_ok:
            winner = "OTC" if otc_shares > amm_shares else "AMM"
            savings = abs(otc_shares - amm_shares)
            savings_pct = (savings / max(amm_shares, otc_shares)) * 100 if max(amm_shares, otc_shares) > 0 else 0
        elif otc_ok:
            winner = "OTC"
            savings = otc_shares
            savings_pct = 100
        elif amm_ok:
            winner = "AMM"
            savings = amm_shares
            savings_pct = 100
        else:
            winner = "NONE"
            savings = 0
            savings_pct = 0

        amm_str = f"{amm_shares:.2f}" if amm_ok else "rejected"
        otc_str = f"{otc_shares:.2f}" if otc_ok else "-"
        coll_str = f"${otc_coll:.2f}" if otc_ok else "-"

        print(f"${size:<9} | {amm_str:<12} | {otc_str:<12} | {coll_str:<10} | {winner:<8} | {savings_pct:.1f}%")

    # =========================================================================
    # Simulation 4: Vault spread under different imbalance
    # =========================================================================
    print_header("4. Vault OTC Spread by Inventory Imbalance")
    print("   (Buying YES, 168 hours to close)")
    print(f"\n{'YES:NO Ratio':<15} | {'Imbalance':<12} | {'Spread':<10} | {'Effective Price':<18}")
    print("-" * 60)

    ratios = [(500, 500), (400, 600), (300, 700), (200, 800), (100, 900)]
    twap = 5000  # 50% probability

    for yes, no in ratios:
        vault = VaultState(yes, no)
        spread = calculate_vault_spread(vault, buy_yes=True)

        # Effective price = TWAP + spread
        share_price = twap
        relative_spread = share_price * spread // 10000
        actual_spread = max(relative_spread, MIN_ABSOLUTE_SPREAD_BPS)
        effective_price = share_price + actual_spread

        ratio_str = f"{yes}:{no}"
        imb_str = f"{vault.imbalance_bps}bps"
        spread_str = f"{spread}bps"
        price_str = f"{effective_price}bps ({effective_price/100:.2f}%)"

        print(f"{ratio_str:<15} | {imb_str:<12} | {spread_str:<10} | {price_str:<18}")

    # =========================================================================
    # Simulation 5: Time-based spread increase
    # =========================================================================
    print_header("5. Vault OTC Spread by Time to Close")
    print("   (Balanced vault, buying YES)")
    print(f"\n{'Hours to Close':<18} | {'Time Boost':<12} | {'Total Spread':<14}")
    print("-" * 50)

    vault = VaultState(500, 500)
    hours_list = [168, 48, 24, 12, 6, 1]

    for hours in hours_list:
        spread = calculate_vault_spread(vault, buy_yes=True, hours_to_close=hours)
        time_boost = spread - BASE_RELATIVE_SPREAD_BPS

        hours_str = f"{hours}h" if hours > 1 else "1h (close window)"
        boost_str = f"+{time_boost}bps" if time_boost > 0 else "0"
        spread_str = f"{spread}bps ({spread/100:.2f}%)"

        print(f"{hours_str:<18} | {boost_str:<12} | {spread_str:<14}")

    # =========================================================================
    # Simulation 6: Bootstrap fee decay
    # =========================================================================
    print_header("6. AMM Fee Decay During Bootstrap Period")
    print("   (50/50 pool)")
    print(f"\n{'Time Elapsed':<15} | {'Base Fee':<10} | {'+ Skew':<10} | {'+ Asym':<10} | {'Total':<10}")
    print("-" * 60)

    pool = PoolState(500, 500)
    times = [0, 3600, 12*3600, 24*3600, 36*3600, 48*3600, 72*3600]

    for elapsed in times:
        # Calculate components
        if elapsed < BOOTSTRAP_WINDOW:
            progress = elapsed / BOOTSTRAP_WINDOW
            base = MAX_FEE_BPS - int((MAX_FEE_BPS - MIN_FEE_BPS) * progress)
        else:
            base = MIN_FEE_BPS

        total = calculate_hook_fee(pool, elapsed)
        skew = 0  # 50/50 pool has no skew
        asym = 0  # 50/50 pool has no asymmetry

        hours = elapsed // 3600
        time_str = f"{hours}h"
        base_str = f"{base}bps"
        skew_str = f"{skew}bps"
        asym_str = f"{asym}bps"
        total_str = f"{total}bps ({total/100:.2f}%)"

        print(f"{time_str:<15} | {base_str:<10} | {skew_str:<10} | {asym_str:<10} | {total_str:<10}")

    # =========================================================================
    # Simulation 7: Skewed pool fee escalation
    # =========================================================================
    print_header("7. AMM Fee at Different Pool Skews (Post-Bootstrap)")
    print(f"\n{'P(YES)':<12} | {'Skew from 50%':<15} | {'Skew Fee':<12} | {'Asym Fee':<12} | {'Total':<10}")
    print("-" * 65)

    probs = [5000, 6000, 7000, 8000, 9000, 9500]

    for p_yes_bps in probs:
        # Reverse engineer reserves from probability
        # P(YES) = NO / (YES + NO), so if total=1000: NO = P*1000, YES = 1000-NO
        total = 1000
        no_res = p_yes_bps * total // 10000
        yes_res = total - no_res
        pool = PoolState(yes_res, no_res)

        skew = abs(p_yes_bps - 5000)

        # Quadratic skew fee
        if skew >= SKEW_REF_BPS:
            skew_fee = MAX_SKEW_FEE_BPS
        else:
            ratio = skew / SKEW_REF_BPS
            skew_fee = int(MAX_SKEW_FEE_BPS * ratio * ratio)

        # Asymmetric fee
        asym_fee = int(ASYMMETRIC_FEE_BPS * skew / 5000)

        total_fee = calculate_hook_fee(pool, BOOTSTRAP_WINDOW + 1)

        p_str = f"{p_yes_bps/100:.0f}%"
        skew_str = f"{skew}bps"
        skew_fee_str = f"{skew_fee}bps"
        asym_str = f"{asym_fee}bps"
        total_str = f"{total_fee}bps"

        print(f"{p_str:<12} | {skew_str:<15} | {skew_fee_str:<12} | {asym_str:<12} | {total_str:<10}")

    # =========================================================================
    # Summary
    # =========================================================================
    print_header("Summary: Key Thresholds")
    print("""
    AMM Price Impact Limit: 12% (1200 bps)

    Approximate max single-trade sizes before rejection:
    - $100 pool  -> ~$14 trades
    - $500 pool  -> ~$70 trades
    - $1000 pool -> ~$140 trades
    - $5000 pool -> ~$700 trades
    - $10000 pool -> ~$1400 trades

    Vault OTC Spread Range:
    - Minimum: 1% (balanced inventory, >24h to close)
    - Maximum: 5% (heavy imbalance + near close)

    AMM Fee Range:
    - Bootstrap (0-2 days): 0.75% -> 0.10%
    - Steady state: 0.10% base + up to 1.0% skew/asymmetric
    - Cap: 3%

    Vault vs AMM:
    - Small trades: Vault OTC often wins (no slippage)
    - Large trades: AMM wins (vault 30% depletion cap limits fill)
    - Very large trades: May require multiple venues or rejection
    """)


if __name__ == "__main__":
    run_simulations()


def run_multivenue_demo():
    """Demonstrate multi-venue execution in detail"""
    print_header("8. Multi-Venue Execution Deep Dive")
    
    pool = PoolState(500, 500)  # $1000 pool
    vault = VaultState(500, 500)  # $1000 vault inventory
    
    print("\n   Initial State:")
    print(f"   Pool:  {pool.yes_reserve} YES / {pool.no_reserve} NO (P(YES) = {pool.p_yes_bps/100:.0f}%)")
    print(f"   Vault: {vault.yes_shares} YES / {vault.no_shares} NO")
    print(f"   30% depletion cap = {vault.yes_shares * 0.3:.0f} max shares per OTC fill")
    
    trade_sizes = [50, 100, 150, 200, 300]
    
    print(f"\n{'Trade $':<10} | {'Vault Fill':<20} | {'AMM Fill':<20} | {'Total':<12} | {'Source':<8}")
    print("-" * 85)
    
    for size in trade_sizes:
        fee_bps = calculate_hook_fee(pool, 3600)
        twap = pool.p_yes_bps
        
        # Step 1: Try vault OTC
        otc_shares, otc_coll, otc_ok = simulate_vault_otc(vault, size, True, twap)
        
        remaining = size - otc_coll if otc_ok else size
        
        # Step 2: Try AMM on remainder
        amm_shares = 0
        amm_impact = 0
        if remaining > 0:
            amm_shares, amm_impact, amm_ok = simulate_amm_buy(pool, remaining, True, fee_bps)
            if not amm_ok:
                amm_shares = 0
        
        total = (otc_shares if otc_ok else 0) + amm_shares
        
        # Determine source
        if otc_ok and amm_shares > 0:
            source = "mult"
        elif otc_ok:
            source = "otc"
        elif amm_shares > 0:
            source = "amm"
        else:
            source = "rejected"
        
        vault_str = f"{otc_shares:.1f} for ${otc_coll:.1f}" if otc_ok else "-"
        amm_str = f"{amm_shares:.1f} ({amm_impact}bps)" if amm_shares > 0 else "-"
        total_str = f"{total:.1f}" if total > 0 else "-"
        
        print(f"${size:<9} | {vault_str:<20} | {amm_str:<20} | {total_str:<12} | {source:<8}")
    
    print("\n   Explanation:")
    print("   - $50 trade: Vault can fill entirely (under 30% cap)")
    print("   - $100 trade: Vault fills 150 shares (30% of 500), AMM fills remainder")
    print("   - $200+ trades: Vault hits cap, AMM takes remainder")
    print("   - Very large trades: AMM may reject due to price impact")


if __name__ == "__main__":
    run_multivenue_demo()
