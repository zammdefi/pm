// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*────────────────────────────────────────────────────────
| Minimal ERC6909 (Modified from Solmate)
|────────────────────────────────────────────────────────*/
abstract contract ERC6909Minimal {
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event Approval(
        address indexed owner, address indexed spender, uint256 indexed id, uint256 amount
    );
    event Transfer(
        address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
    );

    mapping(address => mapping(address => bool)) public isOperator;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address operator, bool approved) public virtual returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x0f632fb3;
    }

    function _mint(address receiver, uint256 id, uint256 amount) internal virtual {
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal virtual {
        balanceOf[sender][id] -= amount;
        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}

/*────────────────────────────────────────────────────────
| External tokens / Lido zap
|────────────────────────────────────────────────────────*/
IERC20 constant WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

IZSTETH constant ZSTETH = IZSTETH(0x000000000088649055D9D23362B819A5cfF11f02);

interface IZSTETH {
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
}

/*────────────────────────────────────────────────────────
| Minimal ZAMM interface (constant product ERC6909)
|────────────────────────────────────────────────────────*/
interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook; // bps fee or flags|hookAddr
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

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    // Transient balance helpers
    function deposit(address token, uint256 id, uint256 amount) external payable;
    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);
}

/*────────────────────────────────────────────────────────
| PredictionAMM — CPMM-backed YES/NO markets
|  • Pool fee = 10 bps (paid to ZAMM with fee switch on)
|  • Pot in wstETH; PM+ZAMM excluded from payout denominator
|  • Path-fair EV charging via Simpson’s rule (fee-aware)
|────────────────────────────────────────────────────────*/
contract PredictionAMM is ERC6909Minimal {
    /*──────── errors ───────*/
    error MarketExists();
    error MarketNotFound();
    error MarketClosed();
    error MarketNotClosed();
    error MarketResolved();
    error MarketNotResolved();
    error OnlyResolver();
    error InvalidResolver();
    error AlreadyResolved();
    error NoWinningShares();
    error AmountZero();
    error InvalidClose();
    error FeeOverflow();
    error PoolNotSeeded();
    error InsufficientLiquidity();
    error SlippageOppIn();
    error InsufficientZap();
    error InsufficientWst();
    error NoEth();
    error EthNotAllowed();
    error NoCirculating();
    error NotClosable();
    error SeedBothSides();

    /*──────── storage ──────*/
    struct Market {
        address resolver;
        bool resolved;
        bool outcome; // true=YES wins, false=NO wins
        bool canClose; // resolver can early-close
        uint72 close; // trading close timestamp
        uint256 pot; // wstETH collateral pool
        uint256 payoutPerShare; // Q-scaled
    }

    uint256 constant Q = 1e18;
    uint256 constant FEE_BPS = 10; // 0.10% pool fee

    // ZAMM singleton
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    uint256[] public allMarkets;
    mapping(uint256 id => Market) public markets;
    mapping(uint256 id => uint256) public totalSupply;
    mapping(uint256 id => string) public descriptions;
    mapping(address resolver => uint16) public resolverFeeBps;

    /*──────── events ───────*/
    event Created(
        uint256 indexed marketId, uint256 indexed noId, string description, address resolver
    );
    event Seeded(uint256 indexed marketId, uint256 yesSeed, uint256 noSeed, uint256 liquidity);
    event Bought(address indexed buyer, uint256 indexed id, uint256 sharesOut, uint256 wstIn);
    event Resolved(uint256 indexed marketId, bool outcome);
    event Claimed(address indexed claimer, uint256 indexed id, uint256 shares, uint256 payout);
    event Closed(uint256 indexed marketId, uint256 ts, address indexed by);
    event ResolverFeeSet(address indexed resolver, uint16 bps);

    constructor() payable {}

    /*──────── id helpers ───*/
    function getMarketId(string calldata description, address resolver)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked("PMARKET:YES", description, resolver)));
    }

    function getNoId(uint256 marketId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("PMARKET:NO", marketId)));
    }

    function _poolKey(uint256 yesId, uint256 noId) internal view returns (IZAMM.PoolKey memory k) {
        (uint256 id0, uint256 id1) = (yesId < noId) ? (yesId, noId) : (noId, yesId);
        k = IZAMM.PoolKey({
            id0: id0,
            id1: id1,
            token0: address(this),
            token1: address(this),
            feeOrHook: FEE_BPS
        });
    }

    function _poolId(IZAMM.PoolKey memory k) internal pure returns (uint256 id) {
        id = uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));
    }

    function name(uint256 id) public pure returns (string memory) {
        return string(abi.encodePacked("PM-", _toString(id)));
    }

    function symbol(uint256) public pure returns (string memory) {
        return "PM";
    }

    /*──────── lifecycle ───*/
    function createMarket(
        string calldata description,
        address resolver,
        uint72 close,
        bool canClose,
        uint256 seedYes,
        uint256 seedNo
    ) public returns (uint256 marketId, uint256 noId) {
        require(close > block.timestamp, InvalidClose());
        require(resolver != address(0), InvalidResolver());

        marketId = getMarketId(description, resolver);
        noId = getNoId(marketId);
        require(markets[marketId].resolver == address(0), MarketExists());

        markets[marketId] = Market({
            resolver: resolver,
            resolved: false,
            outcome: false,
            canClose: canClose,
            close: close,
            pot: 0,
            payoutPerShare: 0
        });

        allMarkets.push(marketId);
        descriptions[marketId] = description;

        emit Created(marketId, noId, description, resolver);

        if (seedYes != 0 || seedNo != 0) {
            require(seedYes != 0 && seedNo != 0, SeedBothSides());
            _seedYesNoPool(marketId, seedYes, seedNo);
        }
    }

    function _seedYesNoPool(uint256 marketId, uint256 seedYes, uint256 seedNo) internal {
        uint256 yesId = marketId;
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(yesId, noId);

        // Mint seeds to PM (non-circulating; will be held by ZAMM as LP position):
        _mint(address(this), yesId, seedYes);
        totalSupply[yesId] += seedYes;
        _mint(address(this), noId, seedNo);
        totalSupply[noId] += seedNo;

        (uint256 a0, uint256 a1) = (key.id0 == yesId) ? (seedYes, seedNo) : (seedNo, seedYes);
        ZAMM.deposit(address(this), key.id0, a0);
        ZAMM.deposit(address(this), key.id1, a1);

        (uint256 used0, uint256 used1, uint256 liq) =
            ZAMM.addLiquidity(key, a0, a1, 0, 0, address(this), block.timestamp);

        if (used0 < a0) {
            uint256 ret = ZAMM.recoverTransientBalance(address(this), key.id0, address(this));
            _burn(address(this), key.id0, ret);
            totalSupply[key.id0] -= ret;
        }
        if (used1 < a1) {
            uint256 ret = ZAMM.recoverTransientBalance(address(this), key.id1, address(this));
            _burn(address(this), key.id1, ret);
            totalSupply[key.id1] -= ret;
        }

        (uint256 usedYes, uint256 usedNo) = (key.id0 == yesId) ? (used0, used1) : (used1, used0);
        emit Seeded(marketId, usedYes, usedNo, liq);
    }

    function closeMarket(uint256 marketId) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(msg.sender == m.resolver, OnlyResolver());
        require(m.canClose, NotClosable());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        m.close = uint72(block.timestamp);
        emit Closed(marketId, block.timestamp, msg.sender);
    }

    /*──────── path-fair pricing helpers (fee-aware) ─────*/
    function _price1e18(uint256 num, uint256 den) internal pure returns (uint256) {
        return mulDiv(num, Q, den); // floor(num/den * 1e18)
    }

    // YES buy (NO -> YES)
    function _fairChargeYesWithFee(uint256 rYes, uint256 rNo, uint256 yesOut, uint256 feeBps)
        internal
        pure
        returns (uint256 charge)
    {
        uint256 p0 = _price1e18(rNo, rYes + rNo);

        // midpoint (simulate half the output):
        uint256 outHalf = yesOut / 2;
        uint256 inHalf = _getAmountIn(outHalf, rNo, rYes, feeBps);
        uint256 rYesMid = rYes - outHalf;
        uint256 rNoMid = rNo + inHalf;
        uint256 pMid = _price1e18(rNoMid, rYesMid + rNoMid);

        // end (simulate full output):
        uint256 inAll = _getAmountIn(yesOut, rNo, rYes, feeBps);
        uint256 rYesEnd = rYes - yesOut;
        uint256 rNoEnd = rNo + inAll;
        uint256 p1 = _price1e18(rNoEnd, rYesEnd + rNoEnd);

        // Simpson: Δq * (p0 + 4*pMid + p1) / 6:
        uint256 sum = p0 + (pMid << 2) + p1;
        charge = mulDiv(yesOut, sum, 6 * Q);
    }

    // NO buy (YES -> NO)
    function _fairChargeNoWithFee(uint256 rYes, uint256 rNo, uint256 noOut, uint256 feeBps)
        internal
        pure
        returns (uint256 charge)
    {
        // p0 (EV of NO share = 1 - pYES = rYes/(rYes+rNo))
        uint256 p0 = _price1e18(rYes, rYes + rNo);

        // midpoint:
        uint256 outHalf = noOut / 2;
        uint256 inHalf = _getAmountIn(outHalf, rYes, rNo, feeBps);
        uint256 rNoMid = rNo - outHalf;
        uint256 rYesMid = rYes + inHalf;
        uint256 pMid = _price1e18(rYesMid, rYesMid + rNoMid);

        // end:
        uint256 inAll = _getAmountIn(noOut, rYes, rNo, feeBps);
        uint256 rNoEnd = rNo - noOut;
        uint256 rYesEnd = rYes + inAll;
        uint256 p1 = _price1e18(rYesEnd, rYesEnd + rNoEnd);

        uint256 sum = p0 + (pMid << 2) + p1;
        charge = mulDiv(noOut, sum, 6 * Q);
    }

    /*──────── primary buys (path-fair EV; pot grows) ────*/
    function buyYesViaPool(
        uint256 marketId,
        uint256 yesOut,
        bool inIsETH,
        uint256 wstInMax,
        uint256 oppInMax,
        address to
    ) public payable nonReentrant returns (uint256 wstIn, uint256 oppIn) {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved && block.timestamp < m.close, MarketClosed());
        require(yesOut != 0, AmountZero());

        if (inIsETH) {
            if (msg.value == 0) revert NoEth();
        } else {
            if (msg.value != 0) revert EthNotAllowed();
        }

        uint256 yesId = marketId;
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(yesId, noId);

        (uint256 rYes, uint256 rNo) = _poolReserves(key, yesId);
        require(rYes > 0 && rNo > 0, PoolNotSeeded());
        require(yesOut < rYes, InsufficientLiquidity());

        bool zeroForOne = (key.id0 == noId); // NO -> YES if id0 is NO

        // CPMM input (opposite side minted by PM), fee-aware:
        oppIn = _getAmountIn(yesOut, zeroForOne ? rNo : rYes, zeroForOne ? rYes : rNo, FEE_BPS);
        require(oppIn <= oppInMax, SlippageOppIn());

        // Path-fair EV charge into pot (fee-aware Simpson):
        wstIn = _fairChargeYesWithFee(rYes, rNo, yesOut, FEE_BPS);
        require(wstIn != 0, InsufficientWst());

        // Collect wstETH
        if (inIsETH) {
            uint256 z = ZSTETH.exactETHToWSTETH{value: msg.value}(address(this));
            require(z >= wstIn, InsufficientZap());
            m.pot += wstIn;
            if (z > wstIn) WSTETH.transfer(msg.sender, z - wstIn);
        } else {
            require(wstInMax >= wstIn, InsufficientWst());
            WSTETH.transferFrom(msg.sender, address(this), wstIn);
            m.pot += wstIn;
        }

        // Swap via transient balance:
        _mint(address(this), noId, oppIn);
        totalSupply[noId] += oppIn;
        ZAMM.deposit(address(this), noId, oppIn);
        ZAMM.swapExactOut(key, yesOut, oppIn, zeroForOne, to, block.timestamp);
        uint256 ret = ZAMM.recoverTransientBalance(address(this), noId, address(this));
        if (ret != 0) {
            _burn(address(this), noId, ret);
            totalSupply[noId] -= ret;
        }

        emit Bought(to, yesId, yesOut, wstIn);
    }

    function buyNoViaPool(
        uint256 marketId,
        uint256 noOut,
        bool inIsETH,
        uint256 wstInMax,
        uint256 oppInMax,
        address to
    ) public payable nonReentrant returns (uint256 wstIn, uint256 oppIn) {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved && block.timestamp < m.close, MarketClosed());
        require(noOut != 0, AmountZero());

        if (inIsETH) {
            if (msg.value == 0) revert NoEth();
        } else {
            if (msg.value != 0) revert EthNotAllowed();
        }

        uint256 yesId = marketId;
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(yesId, noId);

        (uint256 rYes, uint256 rNo) = _poolReserves(key, yesId);
        require(rYes > 0 && rNo > 0, PoolNotSeeded());
        require(noOut < rNo, InsufficientLiquidity());

        bool zeroForOne = (key.id0 == yesId); // YES -> NO if id0 is YES

        oppIn = _getAmountIn(noOut, zeroForOne ? rYes : rNo, zeroForOne ? rNo : rYes, FEE_BPS);
        require(oppIn <= oppInMax, SlippageOppIn());

        wstIn = _fairChargeNoWithFee(rYes, rNo, noOut, FEE_BPS);
        require(wstIn != 0, InsufficientWst());

        if (inIsETH) {
            uint256 z = ZSTETH.exactETHToWSTETH{value: msg.value}(address(this));
            require(z >= wstIn, InsufficientZap());
            m.pot += wstIn;
            if (z > wstIn) WSTETH.transfer(msg.sender, z - wstIn);
        } else {
            require(wstInMax >= wstIn, InsufficientWst());
            WSTETH.transferFrom(msg.sender, address(this), wstIn);
            m.pot += wstIn;
        }

        _mint(address(this), yesId, oppIn);
        totalSupply[yesId] += oppIn;
        ZAMM.deposit(address(this), yesId, oppIn);
        ZAMM.swapExactOut(key, noOut, oppIn, zeroForOne, to, block.timestamp);
        uint256 ret = ZAMM.recoverTransientBalance(address(this), yesId, address(this));
        if (ret != 0) {
            _burn(address(this), yesId, ret);
            totalSupply[yesId] -= ret;
        }

        emit Bought(to, noId, noOut, wstIn);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        returns (bool)
    {
        if (msg.sender != sender) {
            // Fast path: allow ZAMM to pull PM-owned balances without any SLOADs:
            if (sender == address(this) && msg.sender == address(ZAMM)) {
                // no-op: authorized
            } else if (!isOperator[sender][msg.sender]) {
                uint256 allowed = allowance[sender][msg.sender][id];
                if (allowed != type(uint256).max) {
                    allowance[sender][msg.sender][id] = allowed - amount;
                }
            }
        }

        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /*──────── resolution / claims ───────*/
    function setResolverFeeBps(uint16 bps) public {
        require(bps <= 1_000, FeeOverflow());
        resolverFeeBps[msg.sender] = bps;
        emit ResolverFeeSet(msg.sender, bps);
    }

    function resolve(uint256 marketId, bool outcome) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(msg.sender == m.resolver, OnlyResolver());
        require(!m.resolved, AlreadyResolved());
        require(block.timestamp >= m.close, MarketNotClosed());

        // optional resolver fee:
        uint16 feeBps = resolverFeeBps[m.resolver];
        if (feeBps != 0) {
            uint256 fee = (m.pot * feeBps) / 10_000;
            if (fee != 0) {
                m.pot -= fee;
                WSTETH.transfer(m.resolver, fee);
            }
        }

        uint256 yesId = marketId;
        uint256 noId = getNoId(marketId);
        uint256 yesCirc = _circulating(yesId);
        uint256 noCirc = _circulating(noId);

        // ── auto-flip semantics ──
        if (outcome) {
            // resolver chose YES
            if (yesCirc == 0 && noCirc > 0) outcome = false; // flip to NO
        } else {
            // resolver chose NO
            if (noCirc == 0 && yesCirc > 0) outcome = true; // flip to YES
        }

        // If both are zero, we still can't resolve (no winners exist):
        uint256 winningCirc = outcome ? yesCirc : noCirc;
        require(winningCirc != 0, NoCirculating());

        m.payoutPerShare = mulDiv(m.pot, Q, winningCirc);
        m.resolved = true;
        m.outcome = outcome;

        emit Resolved(marketId, outcome);
    }

    function claim(uint256 marketId, address to) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolved, MarketNotResolved());

        uint256 winId = m.outcome ? marketId : getNoId(marketId);
        uint256 userShares = balanceOf[msg.sender][winId];
        require(userShares != 0, NoWinningShares());

        uint256 payout = mulDiv(userShares, m.payoutPerShare, Q);

        _burn(msg.sender, winId, userShares);
        totalSupply[winId] -= userShares;

        m.pot -= payout;
        WSTETH.transfer(to, payout);

        emit Claimed(to, winId, userShares, payout);
    }

    /*──────── views & quotes (UX) ───────*/
    function marketCount() public view returns (uint256) {
        return allMarkets.length;
    }

    function tradingOpen(uint256 marketId) public view returns (bool) {
        Market storage m = markets[marketId];
        return m.resolver != address(0) && !m.resolved && block.timestamp < m.close;
    }

    /// Implied YES probability p ≈ rNO / (rYES + rNO)
    function impliedYesProb(uint256 marketId) public view returns (uint256 num, uint256 den) {
        IZAMM.PoolKey memory key = _poolKey(marketId, getNoId(marketId));
        (uint256 rYes, uint256 rNo) = _poolReserves(key, marketId);
        return (rNo, rYes + rNo);
    }

    /// Quote helpers for frontends (fee-aware, path-fair)
    function quoteBuyYes(uint256 marketId, uint256 yesOut)
        public
        view
        returns (
            uint256 oppIn,
            uint256 wstInFair,
            uint256 p0_num,
            uint256 p0_den,
            uint256 p1_num,
            uint256 p1_den
        )
    {
        IZAMM.PoolKey memory key = _poolKey(marketId, getNoId(marketId));
        (uint256 rYes, uint256 rNo) = _poolReserves(key, marketId);
        require(yesOut < rYes && rYes > 0 && rNo > 0, InsufficientLiquidity());

        bool zeroForOne = (key.id0 == getNoId(marketId));
        oppIn = _getAmountIn(yesOut, zeroForOne ? rNo : rYes, zeroForOne ? rYes : rNo, FEE_BPS);

        // p0 and p1 for display
        p0_num = rNo;
        p0_den = rYes + rNo;
        uint256 rYesEnd = rYes - yesOut;
        uint256 rNoEnd = rNo + oppIn;
        p1_num = rNoEnd;
        p1_den = rYesEnd + rNoEnd;

        wstInFair = _fairChargeYesWithFee(rYes, rNo, yesOut, FEE_BPS);
    }

    function quoteBuyNo(uint256 marketId, uint256 noOut)
        public
        view
        returns (
            uint256 oppIn,
            uint256 wstInFair,
            uint256 p0_num,
            uint256 p0_den,
            uint256 p1_num,
            uint256 p1_den
        )
    {
        IZAMM.PoolKey memory key = _poolKey(marketId, getNoId(marketId));
        (uint256 rYes, uint256 rNo) = _poolReserves(key, marketId);
        require(noOut < rNo && rYes > 0 && rNo > 0, InsufficientLiquidity());

        bool zeroForOne = (key.id0 == marketId);
        oppIn = _getAmountIn(noOut, zeroForOne ? rYes : rNo, zeroForOne ? rNo : rYes, FEE_BPS);

        p0_num = rYes;
        p0_den = rYes + rNo;
        uint256 rNoEnd = rNo - noOut;
        uint256 rYesEnd = rYes + oppIn;
        p1_num = rYesEnd;
        p1_den = rYesEnd + rNoEnd;

        wstInFair = _fairChargeNoWithFee(rYes, rNo, noOut, FEE_BPS);
    }

    /*──────── view getters (UI & indexing) ───*/
    function getMarket(uint256 marketId)
        public
        view
        returns (
            uint256 yesSupply,
            uint256 noSupply,
            address resolver,
            bool resolved,
            bool outcome,
            uint256 pot,
            uint256 payoutPerShare,
            string memory desc,
            uint72 closeTs,
            bool canClose,
            // AMM extras:
            uint256 rYes,
            uint256 rNo,
            uint256 pYes_num,
            uint256 pYes_den
        )
    {
        Market storage m = markets[marketId];
        resolver = m.resolver;
        resolved = m.resolved;
        outcome = m.outcome;
        pot = m.pot;
        payoutPerShare = m.payoutPerShare;
        desc = descriptions[marketId];
        closeTs = m.close;
        canClose = m.canClose;

        yesSupply = totalSupply[marketId];
        noSupply = totalSupply[getNoId(marketId)];

        if (resolver != address(0)) {
            IZAMM.PoolKey memory key = _poolKey(marketId, getNoId(marketId));
            (rYes, rNo) = _poolReserves(key, marketId);
            pYes_num = rNo;
            pYes_den = rYes + rNo;
        }
    }

    function getMarkets(uint256 start, uint256 count)
        public
        view
        returns (
            uint256[] memory marketIds,
            uint256[] memory yesSupplies,
            uint256[] memory noSupplies,
            address[] memory resolvers,
            bool[] memory resolved,
            bool[] memory outcome,
            uint256[] memory pot,
            uint256[] memory payoutPerShare,
            string[] memory descs,
            uint72[] memory closes,
            bool[] memory canCloses,
            // AMM extras:
            uint256[] memory rYesArr,
            uint256[] memory rNoArr,
            uint256[] memory pYesNumArr,
            uint256[] memory pYesDenArr,
            uint256 next
        )
    {
        uint256 len = allMarkets.length;
        if (start >= len) {
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new address[](0),
                new bool[](0),
                new bool[](0),
                new uint256[](0),
                new uint256[](0),
                new string[](0),
                new uint72[](0),
                new bool[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                0
            );
        }

        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;

        marketIds = new uint256[](n);
        yesSupplies = new uint256[](n);
        noSupplies = new uint256[](n);
        resolvers = new address[](n);
        resolved = new bool[](n);
        outcome = new bool[](n);
        pot = new uint256[](n);
        payoutPerShare = new uint256[](n);
        descs = new string[](n);
        closes = new uint72[](n);
        canCloses = new bool[](n);
        rYesArr = new uint256[](n);
        rNoArr = new uint256[](n);
        pYesNumArr = new uint256[](n);
        pYesDenArr = new uint256[](n);

        uint256 id;
        uint256 noId;

        for (uint256 j; j != n; ++j) {
            id = allMarkets[start + j];
            Market storage m = markets[id];
            marketIds[j] = id;
            yesSupplies[j] = totalSupply[id];
            noId = getNoId(id);
            noSupplies[j] = totalSupply[noId];
            resolvers[j] = m.resolver;
            resolved[j] = m.resolved;
            outcome[j] = m.outcome;
            pot[j] = m.pot;
            payoutPerShare[j] = m.payoutPerShare;
            descs[j] = descriptions[id];
            closes[j] = m.close;
            canCloses[j] = m.canClose;

            if (m.resolver != address(0)) {
                IZAMM.PoolKey memory key = _poolKey(id, noId);
                (rYesArr[j], rNoArr[j]) = _poolReserves(key, id);
                pYesNumArr[j] = rNoArr[j];
                pYesDenArr[j] = rYesArr[j] + rNoArr[j];
            }
        }

        next = (end < len) ? end : 0;
    }

    function getUserMarkets(address user, uint256 start, uint256 count)
        public
        view
        returns (
            uint256[] memory yesIds,
            uint256[] memory noIds,
            uint256[] memory yesBalances,
            uint256[] memory noBalances,
            uint256[] memory claimables,
            bool[] memory isResolved,
            bool[] memory tradingOpen_,
            uint256 next
        )
    {
        uint256 len = allMarkets.length;
        if (start >= len) {
            return (
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0),
                new bool[](0),
                0
            );
        }

        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;

        yesIds = new uint256[](n);
        noIds = new uint256[](n);
        yesBalances = new uint256[](n);
        noBalances = new uint256[](n);
        claimables = new uint256[](n);
        isResolved = new bool[](n);
        tradingOpen_ = new bool[](n);

        uint256 yId;
        uint256 nId;
        uint256 yBal;
        uint256 nBal;
        bool res;

        for (uint256 j; j != n; ++j) {
            yId = allMarkets[start + j];
            nId = getNoId(yId);
            Market storage m = markets[yId];

            yesIds[j] = yId;
            noIds[j] = nId;

            yBal = balanceOf[user][yId];
            nBal = balanceOf[user][nId];
            yesBalances[j] = yBal;
            noBalances[j] = nBal;

            res = m.resolved;
            isResolved[j] = res;
            tradingOpen_[j] = (m.resolver != address(0) && !res && block.timestamp < m.close);

            if (res) {
                uint256 pps = m.payoutPerShare; // Q-scaled
                uint256 winBal = m.outcome ? yBal : nBal;
                claimables[j] = (pps == 0) ? 0 : mulDiv(winBal, pps, Q);
            }
        }

        next = (end < len) ? end : 0;
    }

    function winningId(uint256 marketId) public view returns (uint256 id) {
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) return 0;
        if (!m.resolved) return 0;
        if (m.payoutPerShare == 0) return 0;
        return m.outcome ? marketId : getNoId(marketId);
    }

    function getPool(uint256 marketId)
        public
        view
        returns (
            uint256 poolId,
            uint256 rYes,
            uint256 rNo,
            uint32 tsLast,
            uint256 kLast,
            uint256 lpSupply
        )
    {
        IZAMM.PoolKey memory key = _poolKey(marketId, getNoId(marketId));
        poolId = _poolId(key);
        (uint112 r0, uint112 r1, uint32 t,,, uint256 k, uint256 s) = ZAMM.pools(poolId);
        if (key.id0 == marketId) {
            rYes = r0;
            rNo = r1;
        } else {
            rYes = r1;
            rNo = r0;
        }
        tsLast = t;
        kLast = k;
        lpSupply = s;
    }

    /*──────── internals ───*/
    function _circulating(uint256 id) internal view returns (uint256 c) {
        c = totalSupply[id];
        unchecked {
            c -= balanceOf[address(this)][id]; // exclude PM
            c -= balanceOf[address(ZAMM)][id]; // exclude ZAMM
        }
    }

    function _poolReserves(IZAMM.PoolKey memory key, uint256 yesId)
        internal
        view
        returns (uint256 rYes, uint256 rNo)
    {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(_poolId(key));
        if (key.id0 == yesId) {
            rYes = uint256(r0);
            rNo = uint256(r1);
        } else {
            rYes = uint256(r1);
            rNo = uint256(r0);
        }
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        // amountIn = floor( reserveIn * amountOut * 10000 / ((reserveOut - amountOut) * (10000 - feeBps)) ) + 1
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * (10000 - feeBps);
        amountIn = (numerator / denominator) + 1;
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountOut)
    {
        // amountOut = floor( amountIn*(10000 - feeBps)*reserveOut / (reserveIn*10000 + amountIn*(10000 - feeBps)) )
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /*──────── utils ───────*/
    function _toString(uint256 value) internal pure returns (string memory result) {
        assembly ("memory-safe") {
            result := add(mload(0x40), 0x80)
            mstore(0x40, add(result, 0x20))
            mstore(result, 0)
            let end := result
            let w := not(0)
            for { let temp := value } 1 {} {
                result := add(result, w)
                mstore8(result, add(48, mod(temp, 10)))
                temp := div(temp, 10)
                if iszero(temp) { break }
            }
            let n := sub(end, result)
            result := sub(result, 0x20)
            mstore(result, n)
        }
    }

    /*──────── reentrancy ─*/
    error Reentrancy();

    uint256 constant REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }
}

/*────────────────────────────────────────────────────────
| mulDiv helper (Solady)
|────────────────────────────────────────────────────────*/
error MulDivFailed();

function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, 0xad251c27)
            revert(0x1c, 0x04)
        }
        z := div(z, d)
    }
}
