#!/usr/bin/env python3
"""
Simulate the new partial AMM fill + mint fallback logic.

Shows how large trades now succeed across all three venues:
1. Vault OTC (up to 30% depletion cap)
2. AMM (up to price impact limit)
3. Mint (remainder)
"""

from dataclasses import dataclass
from typing import Tuple
import math

# =============================================================================
# Config (matches PMFeeHook and PMHookRouter defaults)
# =============================================================================
MIN_FEE_BPS = 10
MAX_FEE_BPS = 75
MAX_PRICE_IMPACT_BPS = 1200  # 12%
MAX_VAULT_DEPLETION_PCT = 30
BASE_SPREAD_BPS = 100  # 1%
MAX_SPREAD_BPS = 500   # 5%
MIN_ABSOLUTE_SPREAD_BPS = 20


@dataclass
class PoolState:
    yes_reserve: float
    no_reserve: float

    @property
    def total(self) -> float:
        return self.yes_reserve + self.no_reserve

    @property
    def p_yes_bps(self) -> int:
        if self.total == 0:
            return 5000
        return int((self.no_reserve / self.total) * 10000)


@dataclass
class VaultState:
    yes_shares: float
    no_shares: float


def calculate_swap_output(amount_in: float, reserve_in: float, reserve_out: float, fee_bps: int) -> float:
    """Constant product AMM swap output"""
    if reserve_in == 0 or reserve_out == 0:
        return 0
    amount_in_with_fee = amount_in * (10000 - fee_bps)
    numerator = amount_in_with_fee * reserve_out
    denominator = reserve_in * 10000 + amount_in_with_fee
    return numerator / denominator


def calculate_price_impact(pool: PoolState, buy_yes: bool, collateral_in: float, fee_bps: int) -> int:
    """Calculate price impact in bps"""
    p_before = pool.p_yes_bps

    if buy_yes:
        reserve_in, reserve_out = pool.no_reserve, pool.yes_reserve
    else:
        reserve_in, reserve_out = pool.yes_reserve, pool.no_reserve

    swap_out = calculate_swap_output(collateral_in, reserve_in, reserve_out, fee_bps)

    if swap_out >= reserve_out:
        return 10001  # Would drain pool

    if buy_yes:
        yes_after = pool.yes_reserve - swap_out
        no_after = pool.no_reserve + collateral_in
    else:
        yes_after = pool.yes_reserve + collateral_in
        no_after = pool.no_reserve - swap_out

    total_after = yes_after + no_after
    p_after = int((no_after / total_after) * 10000)

    return abs(p_after - p_before)


def find_max_amm_under_impact(pool: PoolState, buy_yes: bool, max_collateral: float,
                               fee_bps: int, max_impact_bps: int) -> float:
    """Binary search for max collateral under impact limit (matches router logic)"""
    if max_impact_bps == 0:
        return 0

    # Quick check: if full amount is under limit
    impact = calculate_price_impact(pool, buy_yes, max_collateral, fee_bps)
    if impact <= max_impact_bps:
        return max_collateral

    if max_collateral <= 1:
        return 0

    # Binary search
    lo, hi = 1, max_collateral
    for _ in range(16):
        mid = (lo + hi) / 2
        if mid == lo:
            break
        impact = calculate_price_impact(pool, buy_yes, mid, fee_bps)
        if impact <= max_impact_bps:
            lo = mid
        else:
            hi = mid

    return lo


def simulate_vault_otc(vault: VaultState, collateral_in: float, buy_yes: bool,
                       twap_p_yes_bps: int) -> Tuple[float, float]:
    """Returns (shares_out, collateral_used)"""
    available = vault.yes_shares if buy_yes else vault.no_shares
    if available == 0:
        return 0, 0

    # 1% spread (simplified)
    share_price_bps = twap_p_yes_bps if buy_yes else (10000 - twap_p_yes_bps)
    spread_bps = max(share_price_bps * BASE_SPREAD_BPS // 10000, MIN_ABSOLUTE_SPREAD_BPS)
    effective_price_bps = min(share_price_bps + spread_bps, 10000)

    raw_shares = collateral_in * 10000 / effective_price_bps

    # 30% depletion cap
    max_from_vault = available * MAX_VAULT_DEPLETION_PCT / 100

    shares_out = min(raw_shares, max_from_vault, available)
    collateral_used = math.ceil(shares_out * effective_price_bps / 10000) if shares_out < raw_shares else collateral_in

    return shares_out, collateral_used


def simulate_amm_buy(pool: PoolState, collateral_in: float, buy_yes: bool, fee_bps: int) -> float:
    """Returns shares_out (collateral + swap output)"""
    if pool.yes_reserve == 0 or pool.no_reserve == 0:
        return 0

    if buy_yes:
        reserve_in, reserve_out = pool.no_reserve, pool.yes_reserve
    else:
        reserve_in, reserve_out = pool.yes_reserve, pool.no_reserve

    swap_out = calculate_swap_output(collateral_in, reserve_in, reserve_out, fee_bps)
    if swap_out >= reserve_out:
        return 0

    return collateral_in + swap_out


def simulate_trade_with_partial_fill(pool: PoolState, vault: VaultState, collateral_in: float,
                                     buy_yes: bool, fee_bps: int = 74) -> dict:
    """
    Simulate full routing with partial AMM fills.

    Returns detailed breakdown of each venue.
    """
    result = {
        'otc_shares': 0,
        'otc_collateral': 0,
        'amm_shares': 0,
        'amm_collateral': 0,
        'mint_shares': 0,
        'mint_collateral': 0,
        'total_shares': 0,
        'remaining': 0,
        'venues': []
    }

    remaining = collateral_in
    twap = pool.p_yes_bps

    # VENUE 1: Vault OTC
    otc_shares, otc_coll = simulate_vault_otc(vault, remaining, buy_yes, twap)
    if otc_shares > 0:
        result['otc_shares'] = otc_shares
        result['otc_collateral'] = otc_coll
        result['venues'].append('OTC')
        remaining -= otc_coll

    # VENUE 2: AMM (partial fill up to impact limit)
    if remaining > 0:
        safe_amm = find_max_amm_under_impact(pool, buy_yes, remaining, fee_bps, MAX_PRICE_IMPACT_BPS)
        if safe_amm > 0:
            amm_shares = simulate_amm_buy(pool, safe_amm, buy_yes, fee_bps)
            if amm_shares > 0:
                result['amm_shares'] = amm_shares
                result['amm_collateral'] = safe_amm
                result['venues'].append('AMM')
                remaining -= safe_amm

    # VENUE 3: Mint (fallback for remainder)
    if remaining > 0:
        # Mint gives 1:1 shares (simplified - actual logic checks imbalance)
        result['mint_shares'] = remaining
        result['mint_collateral'] = remaining
        result['venues'].append('MINT')
        remaining = 0

    result['total_shares'] = result['otc_shares'] + result['amm_shares'] + result['mint_shares']
    result['remaining'] = remaining

    return result


def main():
    print("=" * 80)
    print(" Partial AMM Fill + Mint Fallback Simulation")
    print(" New Router Logic Demonstration")
    print("=" * 80)

    # Setup: $1000 pool, $1000 vault
    pool = PoolState(500, 500)
    vault = VaultState(500, 500)

    print(f"\n Initial State:")
    print(f"   Pool:  {pool.yes_reserve} YES / {pool.no_reserve} NO ($1000 total)")
    print(f"   Vault: {vault.yes_shares} YES / {vault.no_shares} NO")
    print(f"   Price Impact Limit: {MAX_PRICE_IMPACT_BPS}bps (12%)")
    print(f"   Vault Depletion Cap: {MAX_VAULT_DEPLETION_PCT}%")

    print("\n" + "=" * 80)
    print(" Before: Large trades would REVERT due to price impact")
    print(" After:  Large trades SUCCEED with partial AMM + mint fallback")
    print("=" * 80)

    trade_sizes = [50, 100, 150, 200, 300, 500]

    print(f"\n{'Trade':<8} | {'OTC':<18} | {'AMM':<18} | {'MINT':<18} | {'Total':<10} | {'Venues':<12}")
    print("-" * 95)

    for size in trade_sizes:
        result = simulate_trade_with_partial_fill(pool, vault, size, buy_yes=True)

        otc_str = f"{result['otc_shares']:.1f} (${result['otc_collateral']:.0f})" if result['otc_shares'] > 0 else "-"
        amm_str = f"{result['amm_shares']:.1f} (${result['amm_collateral']:.0f})" if result['amm_shares'] > 0 else "-"
        mint_str = f"{result['mint_shares']:.1f} (${result['mint_collateral']:.0f})" if result['mint_shares'] > 0 else "-"
        venues_str = "+".join(result['venues'])

        print(f"${size:<7} | {otc_str:<18} | {amm_str:<18} | {mint_str:<18} | {result['total_shares']:<10.1f} | {venues_str:<12}")

    print("\n" + "=" * 80)
    print(" Key Insight: $300 trade now succeeds!")
    print("=" * 80)

    result = simulate_trade_with_partial_fill(pool, vault, 300, buy_yes=True)
    print(f"""
   Trade: $300 Buy YES

   1. Vault OTC fills {result['otc_shares']:.0f} shares for ${result['otc_collateral']:.0f}
      (30% of 500 = 150 max, at ~50.5% price)

   2. AMM fills {result['amm_shares']:.0f} shares for ${result['amm_collateral']:.0f}
      (max under 12% impact limit)

   3. Mint fills {result['mint_shares']:.0f} shares for ${result['mint_collateral']:.0f}
      (remainder goes to mint, deposits NO to vault)

   Total: {result['total_shares']:.0f} shares from {len(result['venues'])} venues
   Source: {'+'.join(result['venues'])} = "mult"

   OLD BEHAVIOR: Transaction would REVERT
   NEW BEHAVIOR: Transaction SUCCEEDS with full fill
""")

    print("=" * 80)
    print(" Impact on Different Pool Sizes")
    print("=" * 80)

    pools = [
        (PoolState(50, 50), VaultState(50, 50), "$100"),
        (PoolState(250, 250), VaultState(250, 250), "$500"),
        (PoolState(500, 500), VaultState(500, 500), "$1000"),
        (PoolState(2500, 2500), VaultState(2500, 2500), "$5000"),
    ]

    print(f"\n{'Pool':<10} | {'$100 Trade':<35} | {'$500 Trade':<35}")
    print("-" * 85)

    for pool, vault, label in pools:
        r100 = simulate_trade_with_partial_fill(pool, vault, 100, buy_yes=True)
        r500 = simulate_trade_with_partial_fill(pool, vault, 500, buy_yes=True)

        v100 = "+".join(r100['venues']) if r100['venues'] else "none"
        v500 = "+".join(r500['venues']) if r500['venues'] else "none"

        t100 = f"{r100['total_shares']:.0f} shares ({v100})"
        t500 = f"{r500['total_shares']:.0f} shares ({v500})"

        print(f"{label:<10} | {t100:<35} | {t500:<35}")


if __name__ == "__main__":
    main()
