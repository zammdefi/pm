// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );
}

interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );

    function getNoId(uint256 marketId) external pure returns (uint256);
}

interface IPMFeeHook {
    function getCurrentFeeBps(uint256 poolId) external view returns (uint256);
    function getCloseWindow(uint256 marketId) external view returns (uint256);
}

interface IPMHookRouter {
    struct BootstrapVault {
        uint112 yesShares;
        uint112 noShares;
        uint32 lastActivity;
    }

    struct TWAPObservations {
        uint32 timestamp0;
        uint32 timestamp1;
        uint32 cacheBlockNum;
        uint32 cachedTwapBps;
        uint256 cumulative0;
        uint256 cumulative1;
    }

    function canonicalPoolId(uint256 marketId) external view returns (uint256);
    function canonicalFeeOrHook(uint256 marketId) external view returns (uint256);
    function bootstrapVaults(uint256 marketId) external view returns (uint112, uint112, uint32);
    function twapObservations(uint256 marketId)
        external
        view
        returns (uint32, uint32, uint32, uint32, uint256, uint256);
    function totalYesVaultShares(uint256 marketId) external view returns (uint256);
    function totalNoVaultShares(uint256 marketId) external view returns (uint256);
}

/// @title PMHookQuoter
/// @notice View-only quoter for PMHookRouter buy/sell operations
/// @dev Separate contract to keep router under bytecode limit
contract PMHookQuoter {
    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    uint256 constant DEFAULT_FEE_BPS = 30;
    uint256 constant MIN_TWAP_UPDATE_INTERVAL = 5 minutes;
    uint256 constant BOOTSTRAP_WINDOW = 7 days;
    uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 10;
    uint256 constant MAX_SPREAD_BPS = 500;
    uint256 constant MAX_COLLATERAL_IN = type(uint256).max / 10_000;
    uint256 constant MAX_UINT112 = 0xffffffffffffffffffffffffffff;

    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter public immutable ROUTER;

    constructor(address router) {
        ROUTER = IPMHookRouter(router);
    }

    // ============ Quote Functions ============

    /// @notice Quote expected output for buyWithBootstrap
    /// @dev Mirrors execution waterfall: compares vault+AMM vs AMM-only, applies price impact limits
    /// @return totalSharesOut Estimated shares across venues
    /// @return usesVault Whether vault OTC or mint will be used
    /// @return source Primary source ("otc", "mint", "amm", or "mult")
    /// @return vaultSharesMinted Estimated vault shares if mint path used
    function quoteBootstrapBuy(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut
    )
        public
        view
        returns (uint256 totalSharesOut, bool usesVault, bytes4 source, uint256 vaultSharesMinted)
    {
        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId == 0) return (0, false, bytes4(0), 0);

        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        if (resolved || block.timestamp >= close) return (0, false, bytes4(0), 0);
        if (collateralIn == 0 || collateralIn > MAX_COLLATERAL_IN) return (0, false, bytes4(0), 0);

        uint256 remaining = collateralIn;
        uint256 pYes = _getTWAPPrice(marketId);

        // Get quotes from both venues
        (uint256 vaultQuoteShares, uint256 vaultQuoteCollateral, bool vaultFillable) =
            _tryVaultOTCFill(marketId, buyYes, remaining, pYes);
        uint256 ammQuoteShares = _quoteAMMBuy(marketId, buyYes, remaining);

        // Determine venue priority
        bool tryVaultFirst = false;
        if (vaultFillable && vaultQuoteShares != 0) {
            if (ammQuoteShares == 0) {
                tryVaultFirst = true;
            } else {
                uint256 ammAfterVault = (vaultQuoteCollateral < remaining)
                    ? _quoteAMMBuy(marketId, buyYes, remaining - vaultQuoteCollateral)
                    : 0;
                tryVaultFirst = (vaultQuoteShares + ammAfterVault >= ammQuoteShares);
            }
        }

        // Get fee and impact params
        uint256 feeOrHook = ROUTER.canonicalFeeOrHook(marketId);
        uint256 feeBps = _getPoolFeeBps(feeOrHook, poolId);
        uint256 maxImpactBps = _getMaxPriceImpactBps(marketId);

        uint8 venueCount;

        // Execute waterfall based on priority
        if (tryVaultFirst) {
            // Vault OTC first
            if (vaultFillable && vaultQuoteShares != 0) {
                totalSharesOut = vaultQuoteShares;
                remaining -= vaultQuoteCollateral;
                usesVault = true;
                source = bytes4("otc");
                unchecked {
                    ++venueCount;
                }
            }

            // AMM after vault
            if (remaining != 0 && ammQuoteShares != 0) {
                uint256 safeAMMCollateral = maxImpactBps != 0
                    ? _findMaxAMMUnderImpact(marketId, buyYes, remaining, feeBps, maxImpactBps)
                    : remaining;

                if (safeAMMCollateral != 0) {
                    uint256 ammShares = _quoteAMMBuy(marketId, buyYes, safeAMMCollateral);
                    if (ammShares != 0) {
                        totalSharesOut += ammShares;
                        remaining -= safeAMMCollateral;
                        unchecked {
                            ++venueCount;
                        }
                        if (source == bytes4(0)) source = bytes4("amm");
                    }
                }
            }
        } else {
            // AMM first
            if (remaining != 0 && ammQuoteShares != 0) {
                uint256 safeAMMCollateral = maxImpactBps != 0
                    ? _findMaxAMMUnderImpact(marketId, buyYes, remaining, feeBps, maxImpactBps)
                    : remaining;

                if (safeAMMCollateral != 0) {
                    uint256 ammShares = _quoteAMMBuy(marketId, buyYes, safeAMMCollateral);
                    if (ammShares != 0) {
                        totalSharesOut += ammShares;
                        remaining -= safeAMMCollateral;
                        unchecked {
                            ++venueCount;
                        }
                        source = bytes4("amm");
                    }
                }
            }

            // Vault OTC after AMM
            if (remaining != 0 && vaultFillable) {
                (uint256 otcShares, uint256 otcColl, bool otcOk) =
                    _tryVaultOTCFill(marketId, buyYes, remaining, pYes);
                if (otcOk && otcShares != 0) {
                    totalSharesOut += otcShares;
                    remaining -= otcColl;
                    usesVault = true;
                    unchecked {
                        ++venueCount;
                    }
                    if (source == bytes4(0)) source = bytes4("otc");
                }
            }
        }

        // Mint fallback
        bool mintCanSatisfyMin = (minSharesOut <= totalSharesOut + remaining);
        if (remaining != 0 && mintCanSatisfyMin && _shouldUseVaultMint(marketId, buyYes)) {
            (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
            uint256 tvs =
                buyYes ? ROUTER.totalNoVaultShares(marketId) : ROUTER.totalYesVaultShares(marketId);
            uint256 ta = buyYes ? noShares : yesShares;

            if (tvs == 0 || ta != 0) {
                vaultSharesMinted = (tvs == 0 || ta == 0) ? remaining : (remaining * tvs) / ta;
                if (vaultSharesMinted != 0) {
                    totalSharesOut += remaining;
                    usesVault = true;
                    unchecked {
                        ++venueCount;
                    }
                    if (source == bytes4(0)) source = bytes4("mint");
                }
            }
        }

        if (venueCount > 1) source = bytes4("mult");
        if (totalSharesOut < minSharesOut) totalSharesOut = 0;
    }

    /// @notice Quote expected output for sellWithBootstrap (vault OTC + AMM fallback)
    /// @return collateralOut Total collateral from sale
    /// @return source Primary source ("otc", "amm", or "mult")
    function quoteSellWithBootstrap(uint256 marketId, bool sellYes, uint256 sharesIn)
        public
        view
        returns (uint256 collateralOut, bytes4 source)
    {
        if (sharesIn == 0) return (0, bytes4(0));

        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId == 0) return (0, bytes4(0));

        uint256 remaining = sharesIn;
        uint8 venueCount;

        // Quote vault OTC (if scarce side)
        (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
        if (sellYes == (yesShares < noShares)) {
            uint256 pYes = _getTWAPPrice(marketId);
            if (pYes != 0) {
                uint256 price = sellYes ? pYes : (10000 - pYes);
                uint256 spread = price / 50;
                if (spread < MIN_ABSOLUTE_SPREAD_BPS) spread = MIN_ABSOLUTE_SPREAD_BPS;
                price = price > spread ? price - spread : 0;
                if (price != 0) {
                    uint256 maxShares = (sellYes ? noShares : yesShares) * 3 / 10;
                    uint256 filled = remaining < maxShares ? remaining : maxShares;
                    collateralOut = filled * price / 10000;
                    remaining -= filled;
                    source = bytes4("otc");
                    unchecked {
                        ++venueCount;
                    }
                }
            }
        }

        // Quote AMM fallback
        if (remaining != 0) {
            uint256 ammOut = _quoteAMMSell(marketId, sellYes, remaining);
            if (ammOut != 0) {
                collateralOut += ammOut;
                if (source == bytes4(0)) source = bytes4("amm");
                unchecked {
                    ++venueCount;
                }
            }
        }

        if (venueCount > 1) source = bytes4("mult");
    }

    /// @dev Quote AMM sell: swap partial shares to balance, then merge to collateral
    /// Mirrors the router's fixed implementation that swaps only enough to balance for merge
    function _quoteAMMSell(uint256 marketId, bool sellYes, uint256 sharesIn)
        internal
        view
        returns (uint256 collateralOut)
    {
        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId == 0) return 0;
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (r0 == 0 || r1 == 0) return 0;

        uint256 feeBps = _getPoolFeeBps(ROUTER.canonicalFeeOrHook(marketId), poolId);
        if (feeBps >= 10000) return 0;

        uint256 noId = _getNoId(marketId);
        bool yesIsId0 = marketId < noId;
        bool zeroForOne = yesIsId0 == sellYes;
        uint256 rIn = zeroForOne ? uint256(r0) : uint256(r1);
        uint256 rOut = zeroForOne ? uint256(r1) : uint256(r0);

        // Calculate optimal swap amount to balance for merge
        uint256 swapAmount = _calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);
        if (swapAmount == 0 || swapAmount >= sharesIn) return 0;

        unchecked {
            // Quote the swap output
            // Safe: feeBps < 10000 checked in _calcSwapAmountForMerge
            uint256 amountInWithFee = swapAmount * (10000 - feeBps);
            uint256 swapOut = (amountInWithFee * rOut) / (rIn * 10000 + amountInWithFee);

            // Kept shares after swap
            // Safe: swapAmount < sharesIn checked above
            uint256 keptShares = sharesIn - swapAmount;

            // Merge min(keptShares, swapOut) to collateral
            collateralOut = keptShares < swapOut ? keptShares : swapOut;
        }
    }

    /// @dev Calculate optimal swap amount to balance shares for merge
    /// Solves: sharesIn - X = X * rOut * fm / (rIn * 10000 + X * fm)
    /// where fm = 10000 - feeBps
    function _calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
        internal
        pure
        returns (uint256 swapAmount)
    {
        if (sharesIn == 0 || rIn == 0 || rOut == 0 || feeBps >= 10000) return 0;

        // Quadratic formula solution for optimal swap amount
        // a*X^2 + b*X + c = 0 where:
        // a = fm, b = rIn*10000 + fm*(rOut - sharesIn), c = -sharesIn*rIn*10000
        uint256 fm;
        uint256 rIn10k;
        unchecked {
            fm = 10000 - feeBps; // Safe: feeBps < 10000 checked above
            rIn10k = rIn * 10000;
        }

        // Calculate b (can be negative if sharesIn > rOut)
        bool bPositive;
        uint256 b;
        unchecked {
            if (rOut > sharesIn) {
                b = rIn10k + fm * (rOut - sharesIn); // Safe: rOut > sharesIn
                bPositive = true;
            } else {
                uint256 fmDiff = fm * (sharesIn - rOut); // Safe: sharesIn >= rOut
                if (fmDiff > rIn10k) {
                    b = fmDiff - rIn10k; // Safe: fmDiff > rIn10k
                    bPositive = false;
                } else {
                    b = rIn10k - fmDiff; // Safe: rIn10k >= fmDiff
                    bPositive = true;
                }
            }
        }

        // discriminant = b^2 + 4*fm*sharesIn*rIn*10000
        uint256 absC = sharesIn * rIn10k;
        uint256 discriminant = b * b + 4 * fm * absC;

        // sqrt via Newton's method
        uint256 sqrtD = _sqrt(discriminant);

        // X = (-b + sqrtD) / (2*fm)
        uint256 numerator;
        unchecked {
            if (bPositive) {
                numerator = sqrtD > b ? sqrtD - b : 0; // Safe: sqrtD > b checked
            } else {
                numerator = sqrtD + b; // Safe: bounded by discriminant
            }
        }

        uint256 denominator;
        unchecked {
            denominator = 2 * fm; // Safe: fm <= 10000, so 2*fm <= 20000
        }
        if (denominator == 0) return 0;

        swapAmount = numerator / denominator;
        if (swapAmount > sharesIn) swapAmount = sharesIn;
    }

    /// @dev Integer square root via Newton's method
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // ============ Internal Helpers ============

    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly { noId := or(marketId, shl(255, 1)) }
    }

    function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1) {
        (r0, r1,,,,,) = ZAMM.pools(poolId);
    }

    function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
        internal
        view
        returns (uint256 feeBps)
    {
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            try IPMFeeHook(address(uint160(feeOrHook))).getCurrentFeeBps(canonical) returns (
                uint256 fee
            ) {
                feeBps = fee;
            } catch {
                feeBps = DEFAULT_FEE_BPS;
            }
        } else {
            feeBps = feeOrHook;
        }
        if (feeBps > 10001) feeBps = DEFAULT_FEE_BPS;
    }

    function _getMaxPriceImpactBps(uint256 marketId) internal view returns (uint256) {
        uint256 feeOrHook = ROUTER.canonicalFeeOrHook(marketId);
        if ((feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) == 0) return 0;
        try IPMFeeHook(address(uint160(feeOrHook))).getCloseWindow(marketId) returns (uint256 w) {
            return w > 0 ? 200 : 0; // 2% max impact if close window active
        } catch {
            return 0;
        }
    }

    function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps) {
        (uint32 t0, uint32 t1, uint32 cacheBlock, uint32 cached, uint256 c0, uint256 c1) =
            ROUTER.twapObservations(marketId);

        if (cacheBlock == uint32(block.number) && cached != 0) return cached;
        if (t1 == 0) return 0;
        if (block.timestamp < t1 || t1 < t0) return 0;

        uint256 timeElapsed;
        uint256 twapUQ112x112;

        if (block.timestamp - t1 < MIN_TWAP_UPDATE_INTERVAL) {
            unchecked {
                timeElapsed = t1 - t0;
            }
            if (timeElapsed == 0 || c1 < c0) return 0;
            unchecked {
                twapUQ112x112 = (c1 - c0) / timeElapsed;
            }
        } else {
            uint256 poolId = ROUTER.canonicalPoolId(marketId);
            (uint112 r0, uint112 r1, uint32 lastTs, uint256 p0Cum, uint256 p1Cum,,) =
                ZAMM.pools(poolId);
            if (r0 == 0 || r1 == 0) return 0;

            uint256 noId = _getNoId(marketId);
            bool yesIsId0 = marketId < noId;
            uint256 poolCum = yesIsId0 ? p0Cum : p1Cum;

            uint32 elapsed = uint32(block.timestamp) - lastTs;
            if (elapsed > 0) {
                uint256 yesRes = yesIsId0 ? r0 : r1;
                uint256 noRes = yesIsId0 ? r1 : r0;
                uint256 currentPrice = (noRes << 112) / yesRes;
                poolCum += currentPrice * elapsed;
            }

            if (poolCum < c1) return 0;
            unchecked {
                timeElapsed = block.timestamp - t1;
            }
            if (timeElapsed == 0) return 0;
            unchecked {
                twapUQ112x112 = (poolCum - c1) / timeElapsed;
            }
        }

        // Convert UQ112x112 to bps
        uint256 denom = (1 << 112) + twapUQ112x112;
        twapBps = (10000 * twapUQ112x112) / denom;
        if (twapBps == 0) twapBps = 1;
        if (twapBps >= 10000) twapBps = 9999;
    }

    function _tryVaultOTCFill(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 pYesTwapBps
    ) internal view returns (uint256 sharesOut, uint256 collateralUsed, bool filled) {
        if (collateralIn == 0 || pYesTwapBps == 0) return (0, 0, false);

        (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
        uint256 availableShares = buyYes ? yesShares : noShares;
        if (availableShares == 0) return (0, 0, false);

        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (r0 == 0 || r1 == 0) return (0, 0, false);

        // Check spot deviation from TWAP
        uint256 noId = _getNoId(marketId);
        bool yesIsId0 = marketId < noId;
        uint256 yesRes = yesIsId0 ? r0 : r1;
        uint256 noRes = yesIsId0 ? r1 : r0;
        uint256 spotPYesBps = (noRes * 10000) / (yesRes + noRes);
        if (spotPYesBps == 0) spotPYesBps = 1;

        uint256 deviation =
            spotPYesBps > pYesTwapBps ? spotPYesBps - pYesTwapBps : pYesTwapBps - spotPYesBps;
        if (deviation > 500) return (0, 0, false);

        // Calculate spread
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        uint256 relativeSpreadBps = 100; // 1% base

        // Simplified spread calculation
        uint256 sharePriceBps = buyYes ? pYesTwapBps : (10000 - pYesTwapBps);
        uint256 spreadBps = (sharePriceBps * relativeSpreadBps) / 10000;
        if (spreadBps < MIN_ABSOLUTE_SPREAD_BPS) spreadBps = MIN_ABSOLUTE_SPREAD_BPS;

        uint256 effectivePriceBps = sharePriceBps + spreadBps;
        if (effectivePriceBps > 10000) effectivePriceBps = 10000;

        uint256 rawShares = (collateralIn * 10000) / effectivePriceBps;
        uint256 maxSharesFromVault = (availableShares * 3000) / 10000; // 30% max

        sharesOut = rawShares;
        if (sharesOut > maxSharesFromVault) sharesOut = maxSharesFromVault;
        if (sharesOut > availableShares) sharesOut = availableShares;

        collateralUsed = collateralIn;
        if (sharesOut != rawShares) {
            collateralUsed = (sharesOut * effectivePriceBps + 9999) / 10000;
        }

        filled = sharesOut > 0;
    }

    function _quoteAMMBuy(uint256 marketId, bool buyYes, uint256 collateralIn)
        internal
        view
        returns (uint256 totalShares)
    {
        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId == 0) return 0;
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (r0 == 0 || r1 == 0) return 0;

        uint256 feeBps = _getPoolFeeBps(ROUTER.canonicalFeeOrHook(marketId), poolId);
        if (feeBps >= 10000) return 0;
        uint256 noId = _getNoId(marketId);

        bool zeroForOne = (marketId < noId) != buyYes;
        uint256 amountInWithFee = collateralIn * (10000 - feeBps);
        uint256 rIn = zeroForOne ? r1 : r0;
        uint256 rOut = zeroForOne ? r0 : r1;
        uint256 swapped = (amountInWithFee * rOut) / (rIn * 10000 + amountInWithFee);
        // Only return non-zero if swap actually produces output
        if (swapped != 0 && swapped < rOut) {
            totalShares = collateralIn + swapped;
        }
    }

    function _shouldUseVaultMint(uint256 marketId, bool buyYes) internal view returns (bool) {
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        if (close < block.timestamp + BOOTSTRAP_WINDOW) return false;

        (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
        if ((yesShares | noShares) == 0) return true;
        if (yesShares == 0) return !buyYes;
        if (noShares == 0) return buyYes;

        uint256 larger = yesShares > noShares ? yesShares : noShares;
        uint256 smaller = yesShares > noShares ? noShares : yesShares;
        if (larger > smaller * 2) return false;
        if (yesShares == noShares) return true;
        return buyYes != (yesShares < noShares);
    }

    function _findMaxAMMUnderImpact(
        uint256 marketId,
        bool buyYes,
        uint256 maxCollateral,
        uint256 feeBps,
        uint256 maxImpactBps
    ) internal view returns (uint256 safeCollateral) {
        if (maxImpactBps == 0) return 0;

        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (r0 == 0 || r1 == 0) return 0;

        uint256 noId = _getNoId(marketId);
        bool yesIsId0 = marketId < noId;
        uint256 yesRes = yesIsId0 ? r0 : r1;
        uint256 noRes = yesIsId0 ? r1 : r0;
        uint256 pBefore = (noRes * 10000) / (yesRes + noRes);
        uint256 feeMult = 10000 - feeBps;

        // Binary search for max collateral under impact limit
        uint256 lo = 0;
        uint256 hi = maxCollateral;

        for (uint256 i = 0; i < 16; ++i) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 impact = _calcPriceImpact(mid, buyYes, yesRes, noRes, pBefore, feeMult);
            if (impact <= maxImpactBps) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        safeCollateral = lo;
    }

    function _calcPriceImpact(
        uint256 coll,
        bool buyYes,
        uint256 yesRes,
        uint256 noRes,
        uint256 pBefore,
        uint256 feeMult
    ) internal pure returns (uint256) {
        uint256 rIn = buyYes ? noRes : yesRes;
        uint256 rOut = buyYes ? yesRes : noRes;
        uint256 amtWithFee = coll * feeMult;
        uint256 swapOut = (amtWithFee * rOut) / (rIn * 10000 + amtWithFee);

        if (swapOut >= rOut) return 10001;

        uint256 yAfter = buyYes ? yesRes - swapOut + coll : yesRes + coll;
        uint256 nAfter = buyYes ? noRes + coll : noRes - swapOut + coll;
        uint256 pAfter = (nAfter * 10000) / (yAfter + nAfter);

        return pAfter > pBefore ? pAfter - pBefore : pBefore - pAfter;
    }
}
