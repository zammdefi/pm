// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

interface IZAMM {
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

interface IPAMMView {
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
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IPMFeeHook {
    function getCurrentFeeBps(uint256 poolId) external view returns (uint256);
    function getCloseWindow(uint256 marketId) external view returns (uint256);
    function getMaxPriceImpactBps(uint256 marketId) external view returns (uint256);
}

interface IPMHookRouterView {
    function canonicalPoolId(uint256 marketId) external view returns (uint256);
    function canonicalFeeOrHook(uint256 marketId) external view returns (uint256);
    function bootstrapVaults(uint256 marketId) external view returns (uint112, uint112, uint32);
    function twapObservations(uint256 marketId)
        external
        view
        returns (uint32, uint32, uint32, uint32, uint256, uint256);
    function totalYesVaultShares(uint256 marketId) external view returns (uint256);
    function totalNoVaultShares(uint256 marketId) external view returns (uint256);
    function rebalanceCollateralBudget(uint256 marketId) external view returns (uint256);
    function vaultPositions(uint256 marketId, address user)
        external
        view
        returns (
            uint112 yesVaultShares,
            uint112 noVaultShares,
            uint32 lastDepositTime,
            uint256 yesRewardDebt,
            uint256 noRewardDebt
        );
    function accYesCollateralPerShare(uint256 marketId) external view returns (uint256);
    function accNoCollateralPerShare(uint256 marketId) external view returns (uint256);
}

/// @notice MasterRouter interface for pool data access
interface IMasterRouter {
    function pools(bytes32 poolId) external view returns (uint256, uint256, uint256, uint256);
    function bidPools(bytes32 bidPoolId) external view returns (uint256, uint256, uint256, uint256);
    function priceBitmap(bytes32 key, uint256 bucket) external view returns (uint256);
    function getPoolId(uint256 marketId, bool isYes, uint256 priceInBps)
        external
        pure
        returns (bytes32);
    function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
        external
        pure
        returns (bytes32);
    function positions(bytes32 poolId, address user)
        external
        view
        returns (uint256 scaled, uint256 collDebt);
    function bidPositions(bytes32 bidPoolId, address user)
        external
        view
        returns (uint256 scaled, uint256 sharesDebt);
}

/// @title PMHookQuoter
/// @notice View-only quoter for PMHookRouter and MasterRouter buy/sell operations
/// @dev Separate contract to keep routers under bytecode limit
contract PMHookQuoter {
    uint256 constant FLAGS = (1 << 255) | (1 << 254);
    uint256 constant DEFAULT_FEE_BPS = 30;
    uint256 constant MIN_TWAP_UPDATE_INTERVAL = 30 minutes;
    uint256 constant BOOTSTRAP_WINDOW = 4 hours;
    uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 20;
    uint256 constant MAX_SPREAD_BPS = 500;
    uint256 constant MAX_COLLATERAL_IN = type(uint256).max / 10_000;

    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMMView constant PAMM = IPAMMView(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouterView constant ROUTER =
        IPMHookRouterView(0x0000000000BADa259Cb860c12ccD9500d9496B3e);
    IMasterRouter constant MASTER_ROUTER =
        IMasterRouter(0x000000000055CdB14b66f37B96a571108FFEeA5C);

    /// @notice Get TWAP price for a market (pYes in bps)
    function getTWAPPrice(uint256 marketId) external view returns (uint256 twapBps) {
        return _getTWAPPrice(marketId);
    }

    /// @notice Get consolidated market summary
    function getMarketSummary(uint256 marketId)
        external
        view
        returns (
            uint112 ammYesReserve,
            uint112 ammNoReserve,
            uint256 ammPriceYesBps,
            uint256 feeBps,
            uint112 vaultYesShares,
            uint112 vaultNoShares,
            uint256 totalYesVaultLP,
            uint256 totalNoVaultLP,
            uint256 vaultBudget,
            uint256 twapPriceYesBps,
            uint64 closeTime,
            bool resolved,
            bool inCloseWindow
        )
    {
        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId != 0) {
            (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
            if ((r0 | r1) != 0) {
                uint256 noId = _getNoId(marketId);
                assembly ("memory-safe") {
                    let yesIsId0 := lt(marketId, noId)
                    ammYesReserve := xor(r1, mul(xor(r1, r0), yesIsId0))
                    ammNoReserve := xor(r0, mul(xor(r0, r1), yesIsId0))
                    ammPriceYesBps := div(mul(ammNoReserve, 10000), add(r0, r1))
                }
            }
            feeBps = _getPoolFeeBps(ROUTER.canonicalFeeOrHook(marketId), poolId);
        }
        (vaultYesShares, vaultNoShares,) = ROUTER.bootstrapVaults(marketId);
        totalYesVaultLP = ROUTER.totalYesVaultShares(marketId);
        totalNoVaultLP = ROUTER.totalNoVaultShares(marketId);
        vaultBudget = ROUTER.rebalanceCollateralBudget(marketId);
        twapPriceYesBps = _getTWAPPrice(marketId);
        (, resolved,,, closeTime,,) = PAMM.markets(marketId);
        inCloseWindow = _isInCloseWindow(marketId);
    }

    /// @notice Get all user positions for a market in a single call
    /// @dev Consolidates share balances, vault LP, and pending rewards
    /// @param marketId The market to query
    /// @param user The user address
    function getUserFullPosition(uint256 marketId, address user)
        external
        view
        returns (
            uint256 yesShareBalance,
            uint256 noShareBalance,
            uint112 yesVaultLP,
            uint112 noVaultLP,
            uint256 pendingYesCollateral,
            uint256 pendingNoCollateral
        )
    {
        // Share balances from PAMM
        uint256 noId = _getNoId(marketId);
        yesShareBalance = PAMM.balanceOf(user, marketId);
        noShareBalance = PAMM.balanceOf(user, noId);

        // Vault LP positions and pending rewards
        (uint112 yesLP, uint112 noLP,, uint256 yesDebt, uint256 noDebt) =
            ROUTER.vaultPositions(marketId, user);
        yesVaultLP = yesLP;
        noVaultLP = noLP;

        // Calculate pending collateral rewards from vault
        if (yesLP > 0) {
            uint256 accYes = ROUTER.accYesCollateralPerShare(marketId);
            uint256 accumulated = (uint256(yesLP) * accYes) / 1e18;
            pendingYesCollateral = accumulated > yesDebt ? accumulated - yesDebt : 0;
        }
        if (noLP > 0) {
            uint256 accNo = ROUTER.accNoCollateralPerShare(marketId);
            uint256 accumulated = (uint256(noLP) * accNo) / 1e18;
            pendingNoCollateral = accumulated > noDebt ? accumulated - noDebt : 0;
        }
    }

    /// @notice Get liquidity breakdown across all venues for visualization
    /// @dev Shows available liquidity at vault OTC, AMM, and pools for waterfall display
    /// @param marketId The market to query
    /// @param buyYes True if buying YES, false if buying NO
    function getLiquidityBreakdown(uint256 marketId, bool buyYes)
        external
        view
        returns (
            // Vault OTC
            uint256 vaultOtcShares, // Shares available via OTC (30% of same side)
            uint256 vaultOtcPriceBps, // Effective price after spread
            bool vaultOtcAvailable, // Whether OTC is currently available
            // AMM
            uint112 ammYesReserve,
            uint112 ammNoReserve,
            uint256 ammSpotPriceBps, // Current spot price
            uint256 ammMaxImpactBps, // Max allowed price impact
            // Pools (top 5 levels summary)
            uint256 poolAskDepth, // Total shares in ask pools up to 5 levels
            uint256 poolBestAskBps, // Best ask price
            uint256 poolBidDepth, // Total collateral in bid pools up to 5 levels
            uint256 poolBestBidBps // Best bid price
        )
    {
        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        if (poolId == 0) return (0, 0, false, 0, 0, 0, 0, 0, 0, 0, 0);

        (uint112 vaultYes, uint112 vaultNo,) = ROUTER.bootstrapVaults(marketId);
        uint256 twap;

        // Vault OTC: same-side shares, not in close window, TWAP available
        assembly ("memory-safe") {
            let avail := xor(vaultNo, mul(xor(vaultNo, vaultYes), buyYes))
            if avail {
                vaultOtcShares := div(mul(avail, 3000), 10000)
            }
        }
        if (vaultOtcShares > 0 && !_isInCloseWindow(marketId)) {
            twap = _getTWAPPrice(marketId);
            if (twap > 0) {
                vaultOtcAvailable = true;
                (,,,, uint64 close,,) = PAMM.markets(marketId);
                uint256 rel = _calculateDynamicSpread(vaultYes, vaultNo, buyYes, close);
                assembly ("memory-safe") {
                    let base := xor(sub(10000, twap), mul(xor(sub(10000, twap), twap), buyYes))
                    let abs := div(mul(base, rel), 10000)
                    if lt(abs, 20) { abs := 20 }
                    vaultOtcPriceBps := add(base, abs)
                    if gt(vaultOtcPriceBps, 9999) { vaultOtcPriceBps := 9999 }
                }
            }
        }
        if (!vaultOtcAvailable) vaultOtcShares = 0;

        // AMM state with correct YES/NO ordering
        {
            (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
            uint256 noId = _getNoId(marketId);
            assembly ("memory-safe") {
                let yesIsId0 := lt(marketId, noId)
                ammYesReserve := xor(r1, mul(xor(r1, r0), yesIsId0))
                ammNoReserve := xor(r0, mul(xor(r0, r1), yesIsId0))
            }
            if (ammYesReserve > 0 && ammNoReserve > 0) {
                assembly ("memory-safe") {
                    let total := add(ammYesReserve, ammNoReserve)
                    let pYes := div(mul(ammNoReserve, 10000), total)
                    ammSpotPriceBps := xor(
                        sub(10000, pYes),
                        mul(xor(sub(10000, pYes), pYes), buyYes)
                    )
                }
            }
        }
        ammMaxImpactBps = _getMaxPriceImpactBps(marketId);

        // Pool depths
        (uint256[] memory ap, uint256[] memory ad, uint256[] memory bp, uint256[] memory bd) =
            this.getActiveLevels(marketId, buyYes, 5);
        for (uint256 i; i < ad.length;) {
            poolAskDepth += ad[i];
            if (poolBestAskBps == 0) poolBestAskBps = ap[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < bd.length;) {
            poolBidDepth += bd[i];
            if (poolBestBidBps == 0 || bp[i] > poolBestBidBps) poolBestBidBps = bp[i];
            unchecked {
                ++i;
            }
        }
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

            if ((tvs == 0) == (ta == 0)) {
                vaultSharesMinted = (tvs == 0) ? remaining : (remaining * tvs) / ta;
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

        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        if (resolved || block.timestamp >= close) return (0, bytes4(0));

        uint256 remaining = sharesIn;
        uint8 venueCount;

        // Quote vault OTC (if scarce side AND all conditions met)
        (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
        if (sellYes == (yesShares < noShares) && !_isInCloseWindow(marketId)) {
            // Check budget constraint
            uint256 budget = ROUTER.rebalanceCollateralBudget(marketId);
            uint256 pYes = budget != 0 ? _getTWAPPrice(marketId) : 0;

            // Block vault OTC if market halted (feeBps >= 10000 signals halt)
            if (pYes != 0) {
                uint256 feeBps = _getPoolFeeBps(ROUTER.canonicalFeeOrHook(marketId), poolId);
                if (feeBps >= 10000) pYes = 0;
            }

            if (pYes != 0) {
                uint256 price = sellYes ? pYes : (10000 - pYes);
                uint256 spread = price / 50; // 2% spread for sells
                if (spread < 10) spread = 10; // 10 bps minimum for sells (matches router)
                price = price > spread ? price - spread : 0;

                if (price != 0) {
                    uint256 maxShares = (sellYes ? noShares : yesShares) * 3 / 10;
                    uint256 filled = remaining < maxShares ? remaining : maxShares;
                    uint256 otcCollateral = filled * price / 10000;

                    // Cap by budget
                    if (otcCollateral > budget) {
                        filled = (budget * 10000) / price;
                        otcCollateral = filled * price / 10000;
                    }

                    // Safety: prevent 0-collateral fills
                    if (otcCollateral == 0) filled = 0;

                    // Safety: prevent OrphanedAssets - require LP shares on vault's buying side
                    if (filled != 0) {
                        uint256 vaultLPShares = sellYes
                            ? ROUTER.totalYesVaultShares(marketId)
                            : ROUTER.totalNoVaultShares(marketId);
                        if (vaultLPShares == 0) {
                            filled = 0;
                            otcCollateral = 0;
                        }
                    }

                    if (filled != 0) {
                        collateralOut = otcCollateral;
                        remaining -= filled;
                        source = bytes4("otc");
                        unchecked {
                            ++venueCount;
                        }
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

        uint256 swapAmount = _calcSwapAmountForMerge(sharesIn, rIn, rOut, feeBps);
        if (swapAmount == 0 || swapAmount >= sharesIn) return 0;

        unchecked {
            uint256 amountInWithFee = swapAmount * (10000 - feeBps);
            uint256 swapOut = (amountInWithFee * rOut) / (rIn * 10000 + amountInWithFee);
            uint256 keptShares = sharesIn - swapAmount;
            collateralOut = keptShares < swapOut ? keptShares : swapOut;
        }
    }

    /// @dev Calculate optimal swap amount to balance shares for merge
    function _calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
        internal
        pure
        returns (uint256 swapAmount)
    {
        if (
            sharesIn == 0 || sharesIn > type(uint112).max || rIn == 0 || rOut == 0
                || feeBps >= 10000
        ) {
            return 0;
        }

        uint256 fm;
        uint256 rIn10k;
        unchecked {
            fm = 10000 - feeBps;
            rIn10k = rIn * 10000;
        }

        bool bPositive;
        uint256 b;
        unchecked {
            if (rOut > sharesIn) {
                b = rIn10k + fm * (rOut - sharesIn);
                bPositive = true;
            } else {
                uint256 fmDiff = fm * (sharesIn - rOut);
                if (fmDiff > rIn10k) {
                    b = fmDiff - rIn10k;
                    bPositive = false;
                } else {
                    b = rIn10k - fmDiff;
                    bPositive = true;
                }
            }
        }

        uint256 absC = sharesIn * rIn10k;
        uint256 discriminant = b * b + 4 * fm * absC;
        uint256 sqrtD = _sqrt(discriminant);

        uint256 numerator;
        unchecked {
            if (bPositive) {
                numerator = sqrtD > b ? sqrtD - b : 0;
            } else {
                numerator = sqrtD + b;
            }
        }

        uint256 denominator;
        unchecked {
            denominator = 2 * fm;
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

    /// @dev Compute noId from marketId
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1) {
        (r0, r1,,,,,) = ZAMM.pools(poolId);
    }

    function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
        internal
        view
        returns (uint256 feeBps)
    {
        bool isHook = (feeOrHook & FLAGS) != 0;
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
        if ((feeOrHook & FLAGS) == 0) return 0;
        try IPMFeeHook(address(uint160(feeOrHook))).getMaxPriceImpactBps(marketId) returns (
            uint256 maxImpact
        ) {
            return maxImpact;
        } catch {
            return 0;
        }
    }

    /// @dev Check if market is within close window (blocks vault OTC near market close)
    function _isInCloseWindow(uint256 marketId) internal view returns (bool inWindow) {
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        if (block.timestamp >= close) return false;

        uint256 closeWindow = 3600; // Default 1 hour
        uint256 feeOrHook = ROUTER.canonicalFeeOrHook(marketId);
        if ((feeOrHook & FLAGS) != 0) {
            try IPMFeeHook(address(uint160(feeOrHook))).getCloseWindow(marketId) returns (
                uint256 w
            ) {
                if (w != 0) closeWindow = w;
            } catch {}
        }

        unchecked {
            inWindow = (close - block.timestamp) < closeWindow;
        }
    }

    /// @dev Calculate dynamic spread based on vault imbalance and time to close
    function _calculateDynamicSpread(uint256 yesShares, uint256 noShares, bool buyYes, uint64 close)
        internal
        view
        returns (uint256 relativeSpreadBps)
    {
        relativeSpreadBps = 100; // 1% base relative spread

        uint256 totalShares = yesShares + noShares;
        if (totalShares != 0) {
            bool yesScarce = yesShares < noShares;
            bool consumingScarce = (buyYes && yesScarce) || (!buyYes && !yesScarce);

            if (consumingScarce) {
                uint256 larger = yesShares > noShares ? yesShares : noShares;
                uint256 imbalanceBps = (larger * 10000) / totalShares;

                uint256 midpoint = 5000; // 50% balance point
                if (imbalanceBps > midpoint) {
                    uint256 maxSpread = 400; // 4% max imbalance spread
                    uint256 excessImbalance = imbalanceBps - midpoint;
                    uint256 imbalanceBoost = (maxSpread * excessImbalance) / midpoint;
                    relativeSpreadBps += imbalanceBoost;
                }
            }
        }

        if (block.timestamp < close) {
            uint256 timeToClose = close - block.timestamp;
            if (timeToClose < 86400) {
                uint256 timeBoost = (200 * (86400 - timeToClose)) / 86400; // 2% max time boost
                relativeSpreadBps += timeBoost;
            }
        }

        if (relativeSpreadBps > MAX_SPREAD_BPS) {
            relativeSpreadBps = MAX_SPREAD_BPS;
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

            if (uint32(block.timestamp) < lastTs) return 0;
            uint32 elapsed = uint32(block.timestamp) - lastTs;
            if (elapsed > 0) {
                uint256 yesRes = yesIsId0 ? r0 : r1;
                uint256 noRes = yesIsId0 ? r1 : r0;
                uint256 currentPrice = (noRes << 112) / yesRes;
                unchecked {
                    poolCum += currentPrice * elapsed;
                }
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
        if (collateralIn == 0 || pYesTwapBps == 0 || _isInCloseWindow(marketId)) {
            return (0, 0, false);
        }

        (uint112 yesShares, uint112 noShares,) = ROUTER.bootstrapVaults(marketId);
        uint256 availableShares;
        assembly ("memory-safe") {
            availableShares := xor(noShares, mul(xor(noShares, yesShares), buyYes))
        }
        if (availableShares == 0) return (0, 0, false);

        uint256 poolId = ROUTER.canonicalPoolId(marketId);
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (uint256(r0) * r1 == 0) return (0, 0, false);

        uint256 noId = _getNoId(marketId);
        bool ok;
        assembly ("memory-safe") {
            let yesIsId0 := lt(marketId, noId)
            let yesRes := xor(r1, mul(xor(r1, r0), yesIsId0))
            let noRes := xor(r0, mul(xor(r0, r1), yesIsId0))
            let spot := div(mul(noRes, 10000), add(yesRes, noRes))
            if iszero(spot) { spot := 1 }
            let dev := sub(spot, pYesTwapBps)
            if gt(pYesTwapBps, spot) { dev := sub(pYesTwapBps, spot) }
            ok := lt(dev, 501)
        }
        if (!ok) return (0, 0, false);

        (,,,, uint64 close,,) = PAMM.markets(marketId);
        uint256 rel = _calculateDynamicSpread(yesShares, noShares, buyYes, close);
        uint256 effectivePriceBps;
        assembly ("memory-safe") {
            let base :=
                xor(sub(10000, pYesTwapBps), mul(xor(sub(10000, pYesTwapBps), pYesTwapBps), buyYes))
            let spread := div(mul(base, rel), 10000)
            if lt(spread, 20) { spread := 20 }
            effectivePriceBps := add(base, spread)
            if gt(effectivePriceBps, 10000) { effectivePriceBps := 10000 }
        }

        uint256 rawShares = (collateralIn * 10000) / effectivePriceBps;
        uint256 maxFromVault = (availableShares * 3000) / 10000;
        sharesOut = rawShares;
        if (sharesOut > maxFromVault) sharesOut = maxFromVault;
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
        uint256 rIn = zeroForOne ? r0 : r1;
        uint256 rOut = zeroForOne ? r1 : r0;
        uint256 swapped = (amountInWithFee * rOut) / (rIn * 10000 + amountInWithFee);
        if (swapped != 0 && swapped < rOut) {
            totalShares = collateralIn + swapped;
        }
    }

    function _shouldUseVaultMint(uint256 marketId, bool buyYes) internal view returns (bool) {
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        if (close < block.timestamp + BOOTSTRAP_WINDOW) return false;

        (uint112 y, uint112 n,) = ROUTER.bootstrapVaults(marketId);
        if ((y | n) == 0) return true;
        if (y == 0) return !buyYes;
        if (n == 0) return buyYes;
        if ((y > n ? y : n) > (y > n ? n : y) * 2) return false;
        return y == n || buyYes != (y < n);
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
        uint256 lo;
        uint256 hi = maxCollateral;

        for (uint256 i; i < 10; ++i) {
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

        uint256 yAfter = buyYes ? yesRes - swapOut : yesRes + coll;
        uint256 nAfter = buyYes ? noRes + coll : noRes - swapOut;
        uint256 pAfter = (nAfter * 10000) / (yAfter + nAfter);

        return pAfter > pBefore ? pAfter - pBefore : pBefore - pAfter;
    }

    // ============ MasterRouter Sweep Quote Functions ============

    /// @notice Quote expected output for MasterRouter.buyWithSweep (pools + PMHookRouter)
    /// @param marketId Market to buy in
    /// @param buyYes True to buy YES shares, false for NO
    /// @param collateralIn Amount of collateral to spend
    /// @param maxPriceBps Maximum price for pool fills (0 = skip pools)
    /// @return totalSharesOut Total shares expected across all venues
    /// @return poolSharesOut Shares from pool fills
    /// @return poolLevelsFilled Number of pool price levels touched
    /// @return pmSharesOut Shares from PMHookRouter
    /// @return pmSource PMHookRouter source ("otc", "amm", "mint", "mult")
    function quoteBuyWithSweep(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 maxPriceBps
    )
        external
        view
        returns (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 poolLevelsFilled,
            uint256 pmSharesOut,
            bytes4 pmSource
        )
    {
        if (collateralIn == 0 || collateralIn > MAX_COLLATERAL_IN) {
            return (0, 0, 0, 0, bytes4(0));
        }

        uint256 remainingCollateral = collateralIn;

        // Step 1: Quote pool fills from lowest price up to maxPriceBps
        if (maxPriceBps > 0 && maxPriceBps < 10000) {
            bytes32 bitmapKey = _getBitmapKey(marketId, buyYes, true);

            for (uint256 bucket; bucket < 40 && remainingCollateral > 0; ++bucket) {
                uint256 word = MASTER_ROUTER.priceBitmap(bitmapKey, bucket);
                while (word != 0 && remainingCollateral > 0) {
                    uint256 bit = _lowestSetBit(word);
                    uint256 price = (bucket << 8) | bit;
                    word &= ~(1 << bit);

                    if (price == 0 || price > maxPriceBps) continue;

                    bytes32 poolId = MASTER_ROUTER.getPoolId(marketId, buyYes, price);
                    (uint256 depth,,,) = MASTER_ROUTER.pools(poolId);
                    if (depth == 0) continue;

                    uint256 costToFill = (depth * price + 9999) / 10000;
                    uint256 sharesToBuy;
                    uint256 collateralNeeded;

                    if (remainingCollateral >= costToFill) {
                        sharesToBuy = depth;
                        collateralNeeded = costToFill;
                    } else {
                        sharesToBuy = (remainingCollateral * 10000) / price;
                        if (sharesToBuy == 0) continue;
                        collateralNeeded = (sharesToBuy * price + 9999) / 10000;
                    }

                    poolSharesOut += sharesToBuy;
                    remainingCollateral -= collateralNeeded;
                    ++poolLevelsFilled;
                }
            }
        }

        totalSharesOut = poolSharesOut;

        // Step 2: Quote PMHookRouter for remainder
        if (remainingCollateral > 0) {
            (uint256 pmShares,, bytes4 source,) =
                quoteBootstrapBuy(marketId, buyYes, remainingCollateral, 0);
            pmSharesOut = pmShares;
            pmSource = source;
            totalSharesOut += pmShares;
        }
    }

    /// @notice Quote expected output for MasterRouter.sellWithSweep (pools + PMHookRouter)
    /// @param marketId Market to sell in
    /// @param sellYes True to sell YES shares, false for NO
    /// @param sharesIn Amount of shares to sell
    /// @param minPriceBps Minimum price for pool fills (0 = skip pools)
    /// @return totalCollateralOut Total collateral expected across all venues
    /// @return poolCollateralOut Collateral from pool fills
    /// @return poolLevelsFilled Number of pool price levels touched
    /// @return pmCollateralOut Collateral from PMHookRouter
    /// @return pmSource PMHookRouter source ("otc", "amm", "mult")
    function quoteSellWithSweep(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minPriceBps
    )
        external
        view
        returns (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 poolLevelsFilled,
            uint256 pmCollateralOut,
            bytes4 pmSource
        )
    {
        if (sharesIn == 0 || sharesIn > MAX_COLLATERAL_IN) {
            return (0, 0, 0, 0, bytes4(0));
        }

        uint256 remainingShares = sharesIn;

        // Step 1: Quote pool fills from highest price down to minPriceBps
        if (minPriceBps > 0 && minPriceBps < 10000) {
            bytes32 bitmapKey = _getBitmapKey(marketId, sellYes, false);

            for (uint256 b; b < 40 && remainingShares > 0; ++b) {
                uint256 bucket = 39 - b;
                uint256 word = MASTER_ROUTER.priceBitmap(bitmapKey, bucket);
                while (word != 0 && remainingShares > 0) {
                    uint256 bit = _highestSetBit(word);
                    uint256 price = (bucket << 8) | bit;
                    word &= ~(1 << bit);

                    if (price == 0 || price < minPriceBps) continue;

                    bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(marketId, sellYes, price);
                    (uint256 collateralDepth,,,) = MASTER_ROUTER.bidPools(bidPoolId);
                    if (collateralDepth == 0) continue;

                    uint256 maxShares = (collateralDepth * 10000) / price;
                    uint256 sharesToSell;
                    uint256 collateralReceived;

                    if (remainingShares >= maxShares) {
                        sharesToSell = maxShares;
                        collateralReceived = collateralDepth;
                    } else {
                        sharesToSell = remainingShares;
                        collateralReceived = (remainingShares * price) / 10000; // floor for sells
                    }

                    poolCollateralOut += collateralReceived;
                    remainingShares -= sharesToSell;
                    ++poolLevelsFilled;
                }
            }
        }

        totalCollateralOut = poolCollateralOut;

        // Step 2: Quote PMHookRouter for remainder
        if (remainingShares > 0) {
            (uint256 pmCollateral, bytes4 source) =
                quoteSellWithBootstrap(marketId, sellYes, remainingShares);
            pmCollateralOut = pmCollateral;
            pmSource = source;
            totalCollateralOut += pmCollateral;
        }
    }

    /// @dev Find lowest set bit position (isolate lowest bit, then find its position)
    function _lowestSetBit(uint256 x) internal pure returns (uint256) {
        return _highestSetBit(x & (~x + 1));
    }

    /// @dev Find position of highest set bit (0-255), returns 256 for x=0
    function _highestSetBit(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 256;
        assembly ("memory-safe") {
            if gt(x, 0xffffffffffffffffffffffffffffffff) {
                x := shr(128, x)
                r := 128
            }
            if gt(x, 0xffffffffffffffff) {
                x := shr(64, x)
                r := or(r, 64)
            }
            if gt(x, 0xffffffff) {
                x := shr(32, x)
                r := or(r, 32)
            }
            if gt(x, 0xffff) {
                x := shr(16, x)
                r := or(r, 16)
            }
            if gt(x, 0xff) {
                x := shr(8, x)
                r := or(r, 8)
            }
            if gt(x, 0xf) {
                x := shr(4, x)
                r := or(r, 4)
            }
            if gt(x, 0x3) {
                x := shr(2, x)
                r := or(r, 2)
            }
            if gt(x, 0x1) { r := or(r, 1) }
        }
    }

    // ============ MasterRouter View Functions (moved for bytecode savings) ============

    /// @notice Get all active price levels with depth (for orderbook UI)
    function getActiveLevels(uint256 marketId, bool isYes, uint256 maxLevels)
        public
        view
        returns (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        )
    {
        if (maxLevels > 50) maxLevels = 50;

        askPrices = new uint256[](maxLevels);
        askDepths = new uint256[](maxLevels);
        bidPrices = new uint256[](maxLevels);
        bidDepths = new uint256[](maxLevels);

        uint256 askCount;
        uint256 bidCount;

        bytes32 askKey = _getBitmapKey(marketId, isYes, true);
        for (uint256 bucket; bucket < 40 && askCount < maxLevels; ++bucket) {
            uint256 bits = MASTER_ROUTER.priceBitmap(askKey, bucket);
            while (bits != 0 && askCount < maxLevels) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                bytes32 poolId = MASTER_ROUTER.getPoolId(marketId, isYes, price);
                (uint256 totalShares,,,) = MASTER_ROUTER.pools(poolId);
                if (totalShares > 0) {
                    askPrices[askCount] = price;
                    askDepths[askCount] = totalShares;
                    ++askCount;
                }
                bits &= bits - 1;
            }
        }

        bytes32 bidKey = _getBitmapKey(marketId, isYes, false);
        for (uint256 i = 40; i > 0 && bidCount < maxLevels; --i) {
            uint256 bucket = i - 1;
            uint256 bits = MASTER_ROUTER.priceBitmap(bidKey, bucket);
            while (bits != 0 && bidCount < maxLevels) {
                uint256 bit = _highestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(marketId, isYes, price);
                (uint256 totalCollateral,,,) = MASTER_ROUTER.bidPools(bidPoolId);
                if (totalCollateral > 0) {
                    bidPrices[bidCount] = price;
                    bidDepths[bidCount] = totalCollateral;
                    ++bidCount;
                }
                bits &= ~(1 << bit);
            }
        }

        assembly ("memory-safe") {
            mstore(askPrices, askCount)
            mstore(askDepths, askCount)
            mstore(bidPrices, bidCount)
            mstore(bidDepths, bidCount)
        }
    }

    /// @notice Get all active positions for a user on a market side
    function getUserActivePositions(uint256 marketId, bool isYes, address user)
        public
        view
        returns (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
            uint256[] memory bidPendingShares
        )
    {
        uint256 maxPositions = 50;

        askPrices = new uint256[](maxPositions);
        askShares = new uint256[](maxPositions);
        askPendingColl = new uint256[](maxPositions);
        bidPrices = new uint256[](maxPositions);
        bidCollateral = new uint256[](maxPositions);
        bidPendingShares = new uint256[](maxPositions);

        uint256 askCount;
        uint256 bidCount;

        bytes32 askKey = _getBitmapKey(marketId, isYes, true);
        for (uint256 bucket; bucket < 40 && askCount < maxPositions; ++bucket) {
            uint256 bits = MASTER_ROUTER.priceBitmap(askKey, bucket);
            while (bits != 0 && askCount < maxPositions) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;

                bytes32 poolId = MASTER_ROUTER.getPoolId(marketId, isYes, price);
                (uint256 scaled, uint256 collDebt) = MASTER_ROUTER.positions(poolId, user);

                if (scaled > 0) {
                    (uint256 totalShares, uint256 totalScaled, uint256 accCollPerScaled,) =
                        MASTER_ROUTER.pools(poolId);
                    uint256 withdrawable =
                        totalScaled > 0 ? fullMulDiv(scaled, totalShares, totalScaled) : 0;
                    uint256 acc = fullMulDiv(scaled, accCollPerScaled, 1e18);
                    uint256 pending = acc > collDebt ? acc - collDebt : 0;

                    askPrices[askCount] = price;
                    askShares[askCount] = withdrawable;
                    askPendingColl[askCount] = pending;
                    ++askCount;
                }
                bits &= bits - 1;
            }
        }

        bytes32 bidKey = _getBitmapKey(marketId, isYes, false);
        for (uint256 bucket; bucket < 40 && bidCount < maxPositions; ++bucket) {
            uint256 bits = MASTER_ROUTER.priceBitmap(bidKey, bucket);
            while (bits != 0 && bidCount < maxPositions) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;

                bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(marketId, isYes, price);
                (uint256 scaled, uint256 sharesDebt) = MASTER_ROUTER.bidPositions(bidPoolId, user);

                if (scaled > 0) {
                    (uint256 totalCollateral, uint256 totalScaled, uint256 accSharesPerScaled,) =
                        MASTER_ROUTER.bidPools(bidPoolId);
                    uint256 withdrawable =
                        totalScaled > 0 ? fullMulDiv(scaled, totalCollateral, totalScaled) : 0;
                    uint256 acc = fullMulDiv(scaled, accSharesPerScaled, 1e18);
                    uint256 pending = acc > sharesDebt ? acc - sharesDebt : 0;

                    bidPrices[bidCount] = price;
                    bidCollateral[bidCount] = withdrawable;
                    bidPendingShares[bidCount] = pending;
                    ++bidCount;
                }
                bits &= bits - 1;
            }
        }

        assembly ("memory-safe") {
            mstore(askPrices, askCount)
            mstore(askShares, askCount)
            mstore(askPendingColl, askCount)
            mstore(bidPrices, bidCount)
            mstore(bidCollateral, bidCount)
            mstore(bidPendingShares, bidCount)
        }
    }

    /// @notice Get all limit orders for a user across both YES and NO sides
    function getUserAllLimitOrders(uint256 marketId, address user)
        external
        view
        returns (
            uint256[] memory yesAskPrices,
            uint256[] memory yesAskShares,
            uint256[] memory yesAskPending,
            uint256[] memory yesBidPrices,
            uint256[] memory yesBidCollateral,
            uint256[] memory yesBidPending,
            uint256[] memory noAskPrices,
            uint256[] memory noAskShares,
            uint256[] memory noAskPending,
            uint256[] memory noBidPrices,
            uint256[] memory noBidCollateral,
            uint256[] memory noBidPending
        )
    {
        (
            yesAskPrices, yesAskShares, yesAskPending, yesBidPrices, yesBidCollateral, yesBidPending
        ) = getUserActivePositions(marketId, true, user);
        (noAskPrices, noAskShares, noAskPending, noBidPrices, noBidCollateral, noBidPending) =
            getUserActivePositions(marketId, false, user);
    }

    /// @notice Batch query user positions at specific prices
    function getUserPositionsBatch(
        uint256 marketId,
        bool isYes,
        address user,
        uint256[] calldata prices
    )
        public
        view
        returns (
            uint256[] memory askShares,
            uint256[] memory askPending,
            uint256[] memory bidCollateral,
            uint256[] memory bidPending
        )
    {
        uint256 len = prices.length;
        askShares = new uint256[](len);
        askPending = new uint256[](len);
        bidCollateral = new uint256[](len);
        bidPending = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            uint256 price = prices[i];

            bytes32 poolId = MASTER_ROUTER.getPoolId(marketId, isYes, price);
            (uint256 askScaled, uint256 collDebt) = MASTER_ROUTER.positions(poolId, user);
            if (askScaled > 0) {
                (uint256 totalShares, uint256 totalScaled, uint256 accCollPerScaled,) =
                    MASTER_ROUTER.pools(poolId);
                askShares[i] = totalScaled > 0 ? fullMulDiv(askScaled, totalShares, totalScaled) : 0;
                uint256 acc = fullMulDiv(askScaled, accCollPerScaled, 1e18);
                askPending[i] = acc > collDebt ? acc - collDebt : 0;
            }

            bytes32 bidPoolId = MASTER_ROUTER.getBidPoolId(marketId, isYes, price);
            (uint256 bidScaled, uint256 sharesDebt) = MASTER_ROUTER.bidPositions(bidPoolId, user);
            if (bidScaled > 0) {
                (uint256 totalColl, uint256 totalScaled, uint256 accSharesPerScaled,) =
                    MASTER_ROUTER.bidPools(bidPoolId);
                bidCollateral[i] =
                    totalScaled > 0 ? fullMulDiv(bidScaled, totalColl, totalScaled) : 0;
                uint256 acc = fullMulDiv(bidScaled, accSharesPerScaled, 1e18);
                bidPending[i] = acc > sharesDebt ? acc - sharesDebt : 0;
            }
        }
    }

    /// @dev Compute bitmap key for a market/side/type
    function _getBitmapKey(uint256 marketId, bool isYes, bool isAsk)
        internal
        pure
        returns (bytes32 key)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, marketId)
            mstore(add(p, 0x20), isYes)
            mstore(add(p, 0x40), isAsk)
            key := keccak256(p, 0x60)
        }
    }

    function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := mul(x, y)
            for {} 1 {} {
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    let mm := mulmod(x, y, not(0))
                    let p1 := sub(mm, add(z, lt(mm, z)))
                    let r := mulmod(x, y, d)
                    let t := and(d, sub(0, d))
                    if iszero(gt(d, p1)) { revert(0, 0) }
                    d := div(d, t)
                    let inv := xor(2, mul(3, d))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    inv := mul(inv, sub(2, mul(d, inv)))
                    z := mul(
                        or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                        mul(sub(2, mul(d, inv)), inv)
                    )
                    break
                }
                z := div(z, d)
                break
            }
        }
    }
}
