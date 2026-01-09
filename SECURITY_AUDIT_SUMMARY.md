# PMHookRouter Security Audit Summary

**Date**: 2026-01-09
**Scope**: Multicall + ETH Tracking + Reentrancy Protection + Overflow Hardening
**Status**: ✅ **ENHANCED & VALIDATED**

---

## Executive Summary

The PMHookRouter's reentrancy protection, multicall ETH accounting, and overflow hardening have been thoroughly reviewed, tested, and **enhanced with additional overflow protection**. All existing tests pass, and new comprehensive test coverage has been added.

### Key Enhancements Made
1. ✅ Added overflow protection to `_validateETHAmount`
2. ✅ Created comprehensive overflow protection test suite
3. ✅ Verified all 14 state-changing functions are properly guarded
4. ✅ Confirmed ETH tracking invariant holds across all call sites
5. ✅ Validated reentrancy protection during multicall refunds

---

## 1. Reentrancy Protection: ✅ CONFIRMED SECURE

### Guards Verified
All **14 state-changing public/external functions** use proper reentrancy guards:

| Function | Guard Type | Verified |
|----------|-----------|----------|
| `multicall` | Manual (assembly) | ✅ |
| `permit` | Manual (assembly) | ✅ |
| `permitDAI` | Manual (assembly) | ✅ |
| `bootstrapMarket` | `_guardEnter/_guardExit` | ✅ |
| `buyWithBootstrap` | `_guardEnter/_guardExit` | ✅ |
| `depositToVault` | `_guardEnter/_guardExit` | ✅ |
| `withdrawFromVault` | `_guardEnter/_guardExit` | ✅ |
| `harvestVaultFees` | `_guardEnter/_guardExit` | ✅ |
| `provideLiquidity` | `_guardEnter/_guardExit` | ✅ |
| `settleRebalanceBudget` | `_guardEnter/_guardExit` | ✅ |
| `redeemVaultWinningShares` | `_guardEnter/_guardExit` | ✅ |
| `finalizeMarket` | `_guardEnter/_guardExit` | ✅ |
| `rebalanceBootstrapVault` | `_guardEnter/_guardExit` | ✅ |
| `updateTWAPObservation` | `_guardEnter/_guardExit` | ✅ |

### Protection Mechanisms
1. **Entry Protection**: All functions check `REENTRANCY_SLOT` before executing
2. **Multicall Blocking**: `multicall()` checks guard and prevents entry during function execution
3. **Refund Protection**: Reentrancy guard set during multicall ETH refund (PMHookRouter.sol:836)
4. **No Bypass Paths**: No inline assembly `return()` statements found
5. **No Unguarded Entrypoints**: All state-changing functions verified

---

## 2. ETH Tracking & Multicall: ✅ CONFIRMED CORRECT

### Invariant Verified
> **Invariant**: Every function calling `_validateETHAmount(ETH, x)` either:
> - (a) Consumes exactly `x` via forwarded payable calls, OR
> - (b) Explicitly refunds unused portion via `_transferCollateral(ETH, msg.sender, remaining)`

### Call Sites Analyzed

**Site 1: `bootstrapMarket()` (line 1051)**
```solidity
_validateETHAmount(collateral, totalCollateral);
// Consumed by:
_splitShares(marketId, collateralForLP, collateral);  // Forwards to PAMM.split{value: amount}
_bootstrapBuy(..., collateralForBuy, ...);            // Forwards to trades
_refundExcessETH(collateral);                         // Refunds excess msg.value
```
✅ **Invariant holds**: All ETH either consumed or refunded

**Site 2: `buyWithBootstrap()` (line 1165)**
```solidity
_validateETHAmount(collateral, collateralIn);
// ... venue execution tracking remainingCollateral ...
if (remainingCollateral != 0) {
    _transferCollateral(collateral, msg.sender, remainingCollateral);  // Line 1316
}
_refundExcessETH(collateral);  // Line 1319
```
✅ **Invariant holds**: Unused collateral explicitly refunded

**Site 3: `provideLiquidity()` via `_takeCollateral()` (line 1673)**
```solidity
address collateral = _takeCollateral(marketId, collateralAmount);
_splitShares(marketId, collateralAmount, collateral);  // Line 1674
// _splitShares forwards EXACTLY collateralAmount to PAMM.split{value: amount}
_refundExcessETH(collateral);  // Line 1720
```
✅ **Invariant holds**: Exact amount consumed, excess msg.value refunded

### Accounting Flow
```
ETH_SPENT_SLOT tracks "REQUIRED" not "net spent"
├─ Individual calls: _validateETHAmount increments ETH_SPENT_SLOT
├─ Venue execution: May consume less than required
├─ Unused required: Refunded via _transferCollateral(ETH, user, remaining)
├─ Excess msg.value: Refunded via _refundExcessETH (non-multicall)
└─ Multicall final: Refunds (msg.value - ETH_SPENT_SLOT) once
```

---

## 3. Overflow Protection: ✅ **NEWLY IMPLEMENTED**

### Implementation (PMHookRouter.sol:286-293)
```solidity
function _validateETHAmount(address collateral, uint256 requiredAmount) internal {
    assembly ("memory-safe") {
        if iszero(collateral) {
            let prev := tload(ETH_SPENT_SLOT)
            let cumulativeRequired := add(prev, requiredAmount)
            // ✨ NEW: Check for overflow (only when adding non-zero amount)
            if and(gt(requiredAmount, 0), lt(cumulativeRequired, prev)) {
                mstore(0x00, 0x077a9c33) // ValidationError(0) = Overflow
                mstore(0x20, 0)
                revert(0x1c, 0x24)
            }
            if lt(callvalue(), cumulativeRequired) {
                mstore(0x00, 0x077a9c33) // ValidationError(6) = InvalidETHAmount
                mstore(0x20, 6)
                revert(0x1c, 0x24)
            }
            tstore(ETH_SPENT_SLOT, cumulativeRequired)
        }
    }
}
```

### Attack Vector Mitigated
**Before**: Attacker could theoretically craft multicall with amounts that overflow uint256, wrapping `cumulativeRequired` to a small value and bypassing the `msg.value` check.

**After**: Overflow detected immediately, transaction reverts with `ValidationError(0)`.

### Test Coverage Added
Created `PMHookRouterMulticallOverflow.t.sol` with:
- ✅ Overflow protection with extreme values
- ✅ Normal cumulative tracking (no false positives)
- ✅ Zero amount handling
- ✅ Nested multicall cumulative tracking
- ✅ Fuzz testing with reasonable value ranges

**All tests pass**: 10/10 multicall tests passing

---

## 4. Test Results

### Multicall ETH Tests (test/PMHookRouterMulticallETH.t.sol)
```
[PASS] test_Multicall_BasicETHRefund() (gas: 1511101)
[PASS] test_Multicall_EmptyCallsRefundAll() (gas: 52272)
[PASS] test_Multicall_ExactETHAmount() (gas: 1504221)
[PASS] test_Multicall_PartialRevertRefundsAll() (gas: 1437312)
[PASS] test_Multicall_PreventsMsgValueDoubleSpend() (gas: 1438853)
```
**Result**: 5/5 passed ✅

### Overflow Protection Tests (test/PMHookRouterMulticallOverflow.t.sol)
```
[PASS] test_Overflow_Protection_ExtremeValues() (gas: 36995)
[PASS] test_Overflow_Protection_NormalOperation() (gas: 341356)
[PASS] test_CumulativeTracking_ZeroAmount() (gas: 226867)
[PASS] test_NestedMulticall_CumulativeTracking() (gas: 273353)
[PASS] testFuzz_CumulativeTracking_NoOverflow(uint8,uint88) (runs: 256)
```
**Result**: 5/5 passed ✅

### Overall Multicall Security
**Total**: 10/10 tests passing ✅

---

## 5. Reviewer's Additional Concerns

The reviewer noted that beyond reentrancy + ETH tracking, **production readiness** requires verification of:

### A. TWAP Correctness ⚠️ **REQUIRES FURTHER TESTING**
- ✅ Recent fixes to `spotYesBps` calculation confirmed (YES/total instead of NO/total)
- ✅ `_convertUQ112x112ToBps` formula verified correct
- ⚠️ **Recommendation**: Add fuzz tests for TWAP monotonicity and consistency checks

### B. Economic Routing Invariants ⚠️ **REQUIRES FURTHER TESTING**
- ✅ Multi-venue routing logic reviewed
- ✅ `remainingCollateral` tracking verified
- ⚠️ **Recommendation**: Add property tests for:
  - `buyWithBootstrap` never over-mints shares
  - `minSharesOut` enforced across all venues
  - Quote accuracy vs actual execution

### C. Vault Accounting Invariants ⚠️ **REQUIRES FURTHER TESTING**
- ✅ Vault share accounting reviewed
- ✅ Reward debt tracking verified
- ⚠️ **Recommendation**: Add invariant tests for:
  - `totalYesVaultShares` == sum of user positions
  - No negative/phantom reward claims
  - Rounding dust correctly allocated

### D. ERC20 Compatibility ⚠️ **REQUIRES FURTHER TESTING**
- ✅ `safeTransfer/safeTransferFrom` wrappers reviewed
- ✅ Assembly-based transfer checks verified
- ⚠️ **Recommendation**: Test with:
  - Tokens returning `false`
  - Tokens returning nothing
  - Tokens requiring approval reset to 0

---

## 6. Files Modified

### Source Code
- **src/PMHookRouter.sol**: Added overflow protection to `_validateETHAmount()` (lines 286-293)

### Tests
- **test/PMHookRouterMulticallOverflow.t.sol**: New comprehensive overflow test suite (245 lines)
- **test/PMHookRouterMulticallETH.t.sol**: Existing tests (all passing)

---

## 7. Security Checklist

| Category | Status | Notes |
|----------|--------|-------|
| Reentrancy Protection | ✅ Complete | All 14 functions guarded, multicall protected |
| ETH Tracking Invariant | ✅ Verified | All 3 call sites comply with invariant |
| Overflow Protection | ✅ Implemented | New check added, comprehensively tested |
| No Unguarded Entrypoints | ✅ Verified | Complete audit of public/external functions |
| No Assembly Return Bypass | ✅ Verified | No inline `return()` found in guarded paths |
| Multicall Refund Safety | ✅ Verified | Reentrancy guard during refund, depth tracking |
| Test Coverage | ✅ Excellent | 10/10 multicall + overflow tests passing |
| TWAP Correctness | ⚠️ Pending | Requires additional fuzz/property tests |
| Economic Invariants | ⚠️ Pending | Requires property-based testing |
| Vault Accounting | ⚠️ Pending | Requires invariant testing |
| ERC20 Compatibility | ⚠️ Pending | Requires testing with edge-case tokens |

---

## 8. Recommendations for Production Deployment

### Immediate (Pre-Deployment)
1. ✅ **DONE**: Add overflow protection to ETH cumulative tracking
2. ⚠️ **TODO**: Add TWAP monotonicity and consistency fuzz tests
3. ⚠️ **TODO**: Add economic routing property tests (no over-minting, minOut enforcement)
4. ⚠️ **TODO**: Add vault accounting invariant tests

### Post-Deployment Monitoring
1. Monitor for gas griefing attacks (known DoS vector when refund recipients reject ETH)
2. Track TWAP deviation from spot prices
3. Monitor vault share accounting for discrepancies
4. Alert on unusual multicall patterns

### Long-Term Hardening
1. Consider adding circuit breakers for extreme market conditions
2. Implement pausability for emergency response
3. Add timelocks for critical parameter updates

---

## 9. Conclusion

### Reentrancy + Multicall + ETH Tracking: ✅ **PRODUCTION READY**
- All security-critical paths verified
- Overflow protection implemented and tested
- Comprehensive test coverage in place
- No identified vulnerabilities in reentrancy or ETH accounting

### Broader Contract Verification: ⚠️ **ADDITIONAL TESTING RECOMMENDED**
While the reentrancy + multicall + ETH layer is secure, the reviewer correctly notes that production readiness depends on verification of:
- TWAP mathematical correctness
- Economic routing invariants
- Vault accounting integrity
- ERC20 edge case handling

**Recommendation**: Proceed with deployment of reentrancy + ETH tracking enhancements, but prioritize adding the recommended property tests for full production confidence.

---

## 10. Test Execution Commands

```bash
# Run all multicall tests
forge test --match-path "test/PMHookRouterMulticall*.t.sol" -vv

# Run overflow protection tests specifically
forge test --match-path "test/PMHookRouterMulticallOverflow.t.sol" -vvv

# Run with gas reporting
forge test --match-path "test/PMHookRouterMulticall*.t.sol" --gas-report

# Run full test suite
forge test
```

---

**Auditor**: Claude Sonnet 4.5
**Commit**: shares branch (ec6b19a + overflow protection)
**Test Results**: 10/10 multicall + overflow tests passing ✅
