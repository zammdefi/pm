// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimalist and gas efficient standard ERC6909 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)
abstract contract ERC6909 {
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

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        virtual
        returns (bool)
    {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
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

IERC20 constant WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

IZSTETH constant ZSTETH = IZSTETH(0x000000000088649055D9D23362B819A5cfF11f02);

interface IZSTETH {
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
}

contract PredictionMarket is ERC6909 {
    error MarketExists();
    error MarketClosed();
    error MarketNotFound();
    error MarketResolved();
    error MarketNotClosed();
    error MarketNotResolved();

    error OnlyResolver();
    error InvalidResolver();
    error AlreadyResolved();
    error NoWinningShares();

    error AmountZero();
    error CannotClose();
    error InvalidClose();

    struct Market {
        address resolver;
        bool resolved;
        bool outcome;
        bool canClose;
        uint72 close;
        uint256 pot;
        uint256 payoutPerShare;
    }

    uint256 constant Q = 1e18;

    uint256[] public allMarkets;
    mapping(uint256 id => uint256) public totalSupply;
    mapping(uint256 marketId => Market) public markets;
    mapping(uint256 marketId => string) public descriptions;

    event Resolved(uint256 indexed marketId, bool outcome);
    event Bought(address indexed buyer, uint256 indexed id, uint256 amount);
    event Sold(address indexed seller, uint256 indexed id, uint256 amount);
    event Claimed(address indexed claimer, uint256 indexed id, uint256 shares, uint256 payout);
    event Created(
        uint256 indexed marketId, uint256 indexed noId, string description, address resolver
    );
    event Closed(uint256 indexed marketId, uint256 closedAt, address indexed by);

    constructor() payable {}

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

    function name(uint256 id) public pure returns (string memory) {
        return string(abi.encodePacked("PM-", _toString(id)));
    }

    function symbol(uint256) public pure returns (string memory) {
        return "PM";
    }

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

    function createMarket(
        string calldata description,
        address resolver,
        uint72 close,
        bool canClose
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

        emit Created(marketId, noId, descriptions[marketId] = description, resolver);
    }

    function closeMarket(uint256 marketId) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(msg.sender == m.resolver, OnlyResolver());
        require(m.canClose, CannotClose());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        m.close = uint72(block.timestamp);

        emit Closed(marketId, block.timestamp, msg.sender);
    }

    function buyYes(uint256 marketId, uint256 amount, address to)
        public
        payable
        nonReentrant
        returns (uint256 wstIn)
    {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        if (msg.value != 0) {
            wstIn = ZSTETH.exactETHToWSTETH{value: msg.value}(address(this));
        } else {
            WSTETH.transferFrom(msg.sender, address(this), amount);
            wstIn = amount;
        }

        require(wstIn != 0, AmountZero());

        _mint(to, marketId, wstIn);
        totalSupply[marketId] += wstIn;
        m.pot += wstIn;

        emit Bought(to, marketId, wstIn);
    }

    function buyNo(uint256 marketId, uint256 amount, address to)
        public
        payable
        nonReentrant
        returns (uint256 wstIn)
    {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        if (msg.value != 0) {
            wstIn = ZSTETH.exactETHToWSTETH{value: msg.value}(address(this));
        } else {
            WSTETH.transferFrom(msg.sender, address(this), amount);
            wstIn = amount;
        }

        require(wstIn != 0, AmountZero());

        uint256 noId = getNoId(marketId);
        _mint(to, noId, wstIn);
        totalSupply[noId] += wstIn;
        m.pot += wstIn;

        emit Bought(to, noId, wstIn);
    }

    function sellYes(uint256 marketId, uint256 amount, address to) public nonReentrant {
        require(amount != 0, AmountZero());
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        _burn(msg.sender, marketId, amount);
        totalSupply[marketId] -= amount;

        m.pot -= amount;
        WSTETH.transfer(to, amount);

        emit Sold(to, marketId, amount);
    }

    function sellNo(uint256 marketId, uint256 amount, address to) public nonReentrant {
        require(amount != 0, AmountZero());
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(!m.resolved, MarketResolved());
        require(block.timestamp < m.close, MarketClosed());

        uint256 noId = getNoId(marketId);
        _burn(msg.sender, noId, amount);
        totalSupply[noId] -= amount;

        m.pot -= amount;
        WSTETH.transfer(to, amount);

        emit Sold(to, noId, amount);
    }

    function resolve(uint256 marketId, bool outcome) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(msg.sender == m.resolver, OnlyResolver());
        require(!m.resolved, AlreadyResolved());
        require(block.timestamp >= m.close, MarketNotClosed());

        uint256 yesSupply = totalSupply[marketId];
        uint256 noSupply = totalSupply[getNoId(marketId)];

        if (yesSupply == 0 || noSupply == 0) {
            m.payoutPerShare = 0;
            m.resolved = true;
            m.outcome = false;
            emit Resolved(marketId, false);
            return;
        }

        uint16 feeBps = resolverFeeBps[m.resolver];
        if (feeBps != 0) {
            uint256 fee = (m.pot * feeBps) / 10_000;
            if (fee != 0) {
                m.pot -= fee;
                WSTETH.transfer(m.resolver, fee);
            }
        }

        uint256 winningSupp = outcome ? yesSupply : noSupply;
        m.payoutPerShare = mulDiv(m.pot, Q, winningSupp);

        m.resolved = true;
        m.outcome = outcome;

        emit Resolved(marketId, outcome);
    }

    event ResolverFeeSet(address indexed resolver, uint16 bps);

    mapping(address resolver => uint16) public resolverFeeBps;

    error FeeOverflow();

    function setResolverFeeBps(uint16 bps) public {
        require(bps <= 1_000, FeeOverflow());
        resolverFeeBps[msg.sender] = bps;
        emit ResolverFeeSet(msg.sender, bps);
    }

    function claim(uint256 marketId, address to) public nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolved, MarketNotResolved());

        uint256 yesId = marketId;
        uint256 noId = getNoId(marketId);
        uint256 winId = m.outcome ? yesId : noId;

        uint256 userShares = balanceOf[msg.sender][winId];

        if (userShares == 0 && m.payoutPerShare == 0) {
            uint256 otherId = (winId == yesId) ? noId : yesId;
            userShares = balanceOf[msg.sender][otherId];
            if (userShares == 0) revert NoWinningShares();
            winId = otherId;
        } else {
            if (userShares == 0) revert NoWinningShares();
        }

        uint256 payout =
            (m.payoutPerShare == 0) ? userShares : mulDiv(userShares, m.payoutPerShare, Q);

        _burn(msg.sender, winId, userShares);
        totalSupply[winId] -= userShares;

        m.pot -= payout;
        WSTETH.transfer(to, payout);

        emit Claimed(to, winId, userShares, payout);
    }

    function marketCount() public view returns (uint256) {
        return allMarkets.length;
    }

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
            string memory desc
        )
    {
        Market storage m = markets[marketId];
        return (
            totalSupply[marketId],
            totalSupply[getNoId(marketId)],
            m.resolver,
            m.resolved,
            m.outcome,
            m.pot,
            m.payoutPerShare,
            descriptions[marketId]
        );
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
                0
            );
        }

        uint256 end = start + count;
        if (end > len) end = len;
        uint256 pageLen = end - start;

        marketIds = new uint256[](pageLen);
        yesSupplies = new uint256[](pageLen);
        noSupplies = new uint256[](pageLen);
        resolvers = new address[](pageLen);
        resolved = new bool[](pageLen);
        outcome = new bool[](pageLen);
        pot = new uint256[](pageLen);
        payoutPerShare = new uint256[](pageLen);
        descs = new string[](pageLen);
        uint256 id;

        for (uint256 j; j != pageLen; ++j) {
            id = allMarkets[start + j];
            Market storage m = markets[id];

            marketIds[j] = id;
            yesSupplies[j] = totalSupply[id];
            noSupplies[j] = totalSupply[getNoId(id)];
            resolvers[j] = m.resolver;
            resolved[j] = m.resolved;
            outcome[j] = m.outcome;
            pot[j] = m.pot;
            payoutPerShare[j] = m.payoutPerShare;
            descs[j] = descriptions[id];
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
        uint256 pageLen = end - start;

        yesIds = new uint256[](pageLen);
        noIds = new uint256[](pageLen);
        yesBalances = new uint256[](pageLen);
        noBalances = new uint256[](pageLen);
        claimables = new uint256[](pageLen);
        isResolved = new bool[](pageLen);
        tradingOpen_ = new bool[](pageLen);
        uint256 i;
        uint256 yId;
        uint256 nId;
        uint256 yBal;
        uint256 nBal;
        bool resolved_;

        for (uint256 j; j != pageLen; ++j) {
            i = start + j;
            yId = allMarkets[i];
            nId = getNoId(yId);
            Market storage m = markets[yId];

            yesIds[j] = yId;
            noIds[j] = nId;

            yBal = balanceOf[user][yId];
            nBal = balanceOf[user][nId];
            yesBalances[j] = yBal;
            noBalances[j] = nBal;

            resolved_ = m.resolved;
            isResolved[j] = resolved_;
            tradingOpen_[j] = (m.resolver != address(0) && !resolved_ && block.timestamp < m.close);

            if (resolved_) {
                uint256 pps = m.payoutPerShare;
                if (pps == 0) {
                    claimables[j] = yBal + nBal;
                } else {
                    uint256 winBal = m.outcome ? yBal : nBal;
                    claimables[j] = mulDiv(winBal, pps, Q);
                }
            }
        }

        next = (end < len) ? end : 0;
    }

    function tradingOpen(uint256 marketId) public view returns (bool) {
        Market storage m = markets[marketId];
        return m.resolver != address(0) && !m.resolved && block.timestamp < m.close;
    }

    function impliedYesOdds(uint256 marketId)
        public
        view
        returns (uint256 numerator, uint256 denominator)
    {
        uint256 y = totalSupply[marketId];
        uint256 n = totalSupply[getNoId(marketId)];
        return (y, y + n);
    }

    function winningId(uint256 marketId) public view returns (uint256 id) {
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) return 0;
        if (!m.resolved) return 0;
        if (m.payoutPerShare == 0) return 0;
        return m.outcome ? marketId : getNoId(marketId);
    }

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
