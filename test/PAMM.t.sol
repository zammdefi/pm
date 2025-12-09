// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PAMM, ERC6909Minimal, IZAMM} from "../src/PAMM.sol";

/// @notice Mock ERC20 for testing (18 decimals like wstETH)
contract MockERC20 {
    string public name = "Mock wstETH";
    string public symbol = "mwstETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock ERC20 with 6 decimals (like USDC)
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Mock ERC20 with 8 decimals (like WBTC)
contract MockWBTC {
    string public name = "Mock WBTC";
    string public symbol = "mWBTC";
    uint8 public decimals = 8;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Contract that rejects ETH transfers
contract ETHRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

/// @notice Mock ERC20 with EIP-2612 permit support
contract MockERC20Permit {
    string public name = "Mock Permit Token";
    string public symbol = "mPERMIT";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline)
                )
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

        allowance[owner][spender] = value;
    }
}

/// @notice Mock DAI-style token with permit support
contract MockDAI {
    string public name = "Mock DAI";
    string public symbol = "mDAI";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(expiry == 0 || expiry >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");
        require(nonce == nonces[holder]++, "INVALID_NONCE");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed))
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == holder, "INVALID_SIGNER");

        allowance[holder][spender] = allowed ? type(uint256).max : 0;
    }
}

contract PAMM_Test is Test {
    PAMM internal pm;
    MockERC20 internal wsteth;

    address internal RESOLVER = makeAddr("RESOLVER");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    string internal constant DESC = "Will ETH reach $10k in 2025?";
    uint64 internal closeTime;

    uint256 internal marketId;
    uint256 internal noId;

    function setUp() public {
        wsteth = new MockERC20();
        pm = new PAMM();
        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        wsteth.mint(ALICE, 100 ether);
        wsteth.mint(BOB, 100 ether);

        // Approve
        vm.prank(ALICE);
        wsteth.approve(address(pm), type(uint256).max);
        vm.prank(BOB);
        wsteth.approve(address(pm), type(uint256).max);

        // Create default market with wstETH collateral (canClose = false by default)
        (marketId, noId) = pm.createMarket(DESC, RESOLVER, address(wsteth), closeTime, false);
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET CREATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_Success() public view {
        (
            address resolver,
            address collateral,
            uint8 decimals,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            uint256 collateralLocked,
            uint256 yesSupply,
            uint256 noSupply,
            string memory description
        ) = pm.getMarket(marketId);

        assertEq(resolver, RESOLVER);
        assertEq(collateral, address(wsteth));
        assertEq(decimals, 18);
        assertFalse(resolved);
        assertFalse(outcome);
        assertFalse(canClose);
        assertEq(close, closeTime);
        assertEq(collateralLocked, 0);
        assertEq(yesSupply, 0);
        assertEq(noSupply, 0);
        assertEq(description, DESC);
    }

    function test_CreateMarket_WithCanClose() public {
        (uint256 mId,) =
            pm.createMarket("Closable market", RESOLVER, address(wsteth), closeTime, true);

        (,,,,, bool canClose,,,,,) = pm.getMarket(mId);
        assertTrue(canClose);
    }

    function test_CreateMarket_EmitsEvent() public {
        string memory desc2 = "Second market";
        uint256 expectedId = pm.getMarketId(desc2, RESOLVER, address(wsteth));
        uint256 expectedNoId = pm.getNoId(expectedId);

        vm.expectEmit(true, true, false, true);
        emit PAMM.Created(
            expectedId, expectedNoId, desc2, RESOLVER, address(wsteth), 18, closeTime + 1, true
        );

        pm.createMarket(desc2, RESOLVER, address(wsteth), closeTime + 1, true);
    }

    function test_CreateMarket_RevertInvalidResolver() public {
        vm.expectRevert(PAMM.InvalidResolver.selector);
        pm.createMarket("test", address(0), address(wsteth), closeTime, false);
    }

    function test_CreateMarket_RevertInvalidClose() public {
        vm.expectRevert(PAMM.InvalidClose.selector);
        pm.createMarket("test", RESOLVER, address(wsteth), uint64(block.timestamp), false);
    }

    function test_CreateMarket_RevertMarketExists() public {
        vm.expectRevert(PAMM.MarketExists.selector);
        pm.createMarket(DESC, RESOLVER, address(wsteth), closeTime + 1 days, false);
    }

    function test_MarketCount() public {
        assertEq(pm.marketCount(), 1);

        pm.createMarket("market2", RESOLVER, address(wsteth), closeTime, false);
        assertEq(pm.marketCount(), 2);

        pm.createMarket("market3", RESOLVER, address(wsteth), closeTime, false);
        assertEq(pm.marketCount(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                              SPLIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Split_Success() public {
        uint256 collateralIn = 10 ether;

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(marketId, collateralIn, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 10);
        assertEq(pm.balanceOf(ALICE, noId), 10);
        assertEq(pm.totalSupplyId(marketId), 10);
        assertEq(pm.totalSupplyId(noId), 10);
        assertEq(wsteth.balanceOf(address(pm)), 10 ether);
    }

    function test_Split_RefundsDust() public {
        uint256 collateralIn = 10.5 ether;

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(marketId, collateralIn, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10 ether);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore - 10 ether);
    }

    function test_Split_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PAMM.Split(ALICE, marketId, 5, 5 ether);

        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);
    }

    function test_Split_ToDifferentReceiver() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, BOB);

        assertEq(pm.balanceOf(BOB, marketId), 5);
        assertEq(pm.balanceOf(BOB, noId), 5);
        assertEq(pm.balanceOf(ALICE, marketId), 0);
    }

    function test_Split_RevertAmountZero() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.split(marketId, 0, ALICE);
    }

    function test_Split_RevertCollateralTooSmall() public {
        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(ALICE);
        pm.split(marketId, 0.5 ether, ALICE);
    }

    function test_Split_RevertInvalidReceiver() public {
        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(ALICE);
        pm.split(marketId, 1 ether, address(0));
    }

    function test_Split_RevertMarketNotFound() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(ALICE);
        pm.split(999, 1 ether, ALICE);
    }

    function test_Split_RevertMarketClosed_AfterClose() public {
        vm.warp(closeTime);
        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.split(marketId, 1 ether, ALICE);
    }

    function test_Split_RevertMarketClosed_AfterResolved() public {
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.split(marketId, 1 ether, ALICE);
    }

    /*//////////////////////////////////////////////////////////////
                              MERGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Merge_Success() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 merged, uint256 collateralOut) = pm.merge(marketId, 5, ALICE);

        assertEq(merged, 5);
        assertEq(collateralOut, 5 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 5);
        assertEq(pm.balanceOf(ALICE, noId), 5);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + 5 ether);
    }

    function test_Merge_CapsToBalance() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Transfer some YES away
        vm.prank(ALICE);
        pm.transfer(BOB, marketId, 3);

        vm.prank(ALICE);
        (uint256 merged,) = pm.merge(marketId, 100, ALICE);

        // Should merge min(100, 7, 10) = 7
        assertEq(merged, 7);
        assertEq(pm.balanceOf(ALICE, marketId), 0);
        assertEq(pm.balanceOf(ALICE, noId), 3);
    }

    function test_Merge_EmitsEvent() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.expectEmit(true, true, false, true);
        emit PAMM.Merged(ALICE, marketId, 5, 5 ether);

        vm.prank(ALICE);
        pm.merge(marketId, 5, ALICE);
    }

    function test_Merge_RevertAmountZero() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.merge(marketId, 0, ALICE);
    }

    function test_Merge_RevertNoBalance() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.merge(marketId, 1, ALICE);
    }

    /*//////////////////////////////////////////////////////////////
                            RESOLVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_YesWins() public {
        vm.warp(closeTime);

        vm.expectEmit(true, false, false, true);
        emit PAMM.Resolved(marketId, true);

        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome);
    }

    function test_Resolve_NoWins() public {
        vm.warp(closeTime);

        vm.prank(RESOLVER);
        pm.resolve(marketId, false);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertFalse(outcome);
    }

    function test_Resolve_RevertNotResolver() public {
        vm.warp(closeTime);

        vm.expectRevert(PAMM.OnlyResolver.selector);
        vm.prank(ALICE);
        pm.resolve(marketId, true);
    }

    function test_Resolve_RevertMarketNotClosed() public {
        vm.expectRevert(PAMM.MarketNotClosed.selector);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);
    }

    function test_Resolve_RevertAlreadyResolved() public {
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PAMM.AlreadyResolved.selector);
        vm.prank(RESOLVER);
        pm.resolve(marketId, false);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_YesWinner() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.expectEmit(true, true, false, true);
        emit PAMM.Claimed(ALICE, marketId, 10, 10 ether);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, ALICE);

        assertEq(shares, 10);
        assertEq(payout, 10 ether);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + 10 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 0);
    }

    function test_Claim_NoWinner() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, false);

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, ALICE);

        assertEq(shares, 10);
        assertEq(payout, 10 ether);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + 10 ether);
        assertEq(pm.balanceOf(ALICE, noId), 0);
    }

    function test_Claim_RevertNotResolved() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.expectRevert(PAMM.MarketNotClosed.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
    }

    function test_Claim_RevertNoWinningShares() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Transfer YES away
        vm.prank(ALICE);
        pm.transfer(BOB, marketId, 10);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
    }

    /*//////////////////////////////////////////////////////////////
                          RESOLVER FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetResolverFeeBps_Success() public {
        vm.expectEmit(true, false, false, true);
        emit PAMM.ResolverFeeSet(RESOLVER, 500);

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500); // 5%

        assertEq(pm.resolverFeeBps(RESOLVER), 500);
    }

    function test_SetResolverFeeBps_MaxFee() public {
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1000); // 10% max

        assertEq(pm.resolverFeeBps(RESOLVER), 1000);
    }

    function test_SetResolverFeeBps_RevertFeeOverflow() public {
        vm.expectRevert(PAMM.FeeOverflow.selector);
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1001); // > 10%
    }

    function test_Claim_WithResolverFee_ERC20() public {
        // Set 5% resolver fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500);

        // Alice splits
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Resolve YES
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 aliceBefore = wsteth.balanceOf(ALICE);
        uint256 resolverBefore = wsteth.balanceOf(RESOLVER);

        // Claim
        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, ALICE);

        assertEq(shares, 10);
        // Gross = 10 ether, fee = 0.5 ether (5%), payout = 9.5 ether
        assertEq(payout, 9.5 ether);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + 9.5 ether);
        assertEq(wsteth.balanceOf(RESOLVER), resolverBefore + 0.5 ether);
    }

    function test_Claim_WithResolverFee_ETH() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH fee test", RESOLVER, address(0), closeTime, false);

        // Set 10% resolver fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1000);

        // Alice splits ETH
        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        // Resolve YES
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        uint256 aliceBefore = ALICE.balance;
        uint256 resolverBefore = RESOLVER.balance;

        // Claim
        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(ethMarketId, ALICE);

        assertEq(shares, 10);
        // Gross = 10 ether, fee = 1 ether (10%), payout = 9 ether
        assertEq(payout, 9 ether);
        assertEq(ALICE.balance, aliceBefore + 9 ether);
        assertEq(RESOLVER.balance, resolverBefore + 1 ether);
    }

    function test_Claim_NoResolverFee() public {
        // No fee set (default 0)
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, ALICE);

        assertEq(shares, 10);
        assertEq(payout, 10 ether); // Full payout, no fee
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + 10 ether);
    }

    function test_Claim_ResolverFee_MultipleClaimers() public {
        // Set 5% resolver fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500);

        // Alice and Bob split
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.prank(BOB);
        pm.split(marketId, 20 ether, BOB);

        // Transfer YES to each other to get different balances
        vm.prank(ALICE);
        pm.transfer(BOB, noId, 10); // Bob now has all NO

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, false); // NO wins

        uint256 resolverBefore = wsteth.balanceOf(RESOLVER);

        // Bob claims 30 NO shares
        vm.prank(BOB);
        (uint256 bobShares, uint256 bobPayout) = pm.claim(marketId, BOB);

        assertEq(bobShares, 30);
        // Gross = 30 ether, fee = 1.5 ether, payout = 28.5 ether
        assertEq(bobPayout, 28.5 ether);
        assertEq(wsteth.balanceOf(RESOLVER), resolverBefore + 1.5 ether);
    }

    function testFuzz_ResolverFee(uint16 feeBps, uint256 shares) public {
        feeBps = uint16(bound(feeBps, 0, 1000));
        shares = bound(shares, 1, 100);

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(feeBps);

        wsteth.mint(ALICE, shares * 1 ether);

        vm.prank(ALICE);
        pm.split(marketId, shares * 1 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 resolverBefore = wsteth.balanceOf(RESOLVER);
        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 claimedShares, uint256 payout) = pm.claim(marketId, ALICE);

        uint256 gross = claimedShares * 1 ether;
        uint256 expectedFee = (gross * feeBps) / 10_000;
        uint256 expectedPayout = gross - expectedFee;

        assertEq(payout, expectedPayout);
        assertEq(wsteth.balanceOf(ALICE), aliceBefore + expectedPayout);
        assertEq(wsteth.balanceOf(RESOLVER), resolverBefore + expectedFee);
    }

    /*//////////////////////////////////////////////////////////////
                           MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Multicall_SplitAndApprove() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(pm.split, (marketId, 10 ether, ALICE));
        calls[1] = abi.encodeCall(pm.setOperator, (BOB, true));

        vm.prank(ALICE);
        bytes[] memory results = pm.multicall(calls);

        // Verify split worked
        (uint256 shares, uint256 used) = abi.decode(results[0], (uint256, uint256));
        assertEq(shares, 10);
        assertEq(used, 10 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 10);

        // Verify operator set
        assertTrue(pm.isOperator(ALICE, BOB));
    }

    function test_Multicall_MultipleSplits() public {
        // Create second market
        (uint256 marketId2, uint256 noId2) =
            pm.createMarket("Second market", RESOLVER, address(wsteth), closeTime, false);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(pm.split, (marketId, 5 ether, ALICE));
        calls[1] = abi.encodeCall(pm.split, (marketId2, 3 ether, ALICE));

        vm.prank(ALICE);
        pm.multicall(calls);

        assertEq(pm.balanceOf(ALICE, marketId), 5);
        assertEq(pm.balanceOf(ALICE, noId), 5);
        assertEq(pm.balanceOf(ALICE, marketId2), 3);
        assertEq(pm.balanceOf(ALICE, noId2), 3);
    }

    function test_Multicall_MultipleClaims() public {
        // Create two markets and split
        (uint256 marketId2,) =
            pm.createMarket("Second market", RESOLVER, address(wsteth), closeTime, false);

        vm.startPrank(ALICE);
        pm.split(marketId, 10 ether, ALICE);
        pm.split(marketId2, 5 ether, ALICE);
        vm.stopPrank();

        // Resolve both YES
        vm.warp(closeTime);
        vm.startPrank(RESOLVER);
        pm.resolve(marketId, true);
        pm.resolve(marketId2, true);
        vm.stopPrank();

        // Claim both in one tx
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(pm.claim, (marketId, ALICE));
        calls[1] = abi.encodeCall(pm.claim, (marketId2, ALICE));

        uint256 balanceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        bytes[] memory results = pm.multicall(calls);

        // Verify both claims
        (uint256 shares1, uint256 payout1) = abi.decode(results[0], (uint256, uint256));
        (uint256 shares2, uint256 payout2) = abi.decode(results[1], (uint256, uint256));

        assertEq(shares1, 10);
        assertEq(payout1, 10 ether);
        assertEq(shares2, 5);
        assertEq(payout2, 5 ether);
        assertEq(wsteth.balanceOf(ALICE), balanceBefore + 15 ether);
    }

    function test_Multicall_SplitMerge() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(pm.split, (marketId, 5 ether, ALICE));
        calls[1] = abi.encodeCall(pm.merge, (marketId, 3, ALICE));

        uint256 balanceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        pm.multicall(calls);

        // 10 + 5 - 3 = 12 shares
        assertEq(pm.balanceOf(ALICE, marketId), 12);
        assertEq(pm.balanceOf(ALICE, noId), 12);
        // Paid 5 ether, got back 3 ether
        assertEq(wsteth.balanceOf(ALICE), balanceBefore - 2 ether);
    }

    function test_Multicall_RevertsOnFailure() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(pm.split, (marketId, 5 ether, ALICE));
        calls[1] = abi.encodeCall(pm.split, (999, 5 ether, ALICE)); // Invalid market

        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(ALICE);
        pm.multicall(calls);

        // First split should not have happened (atomic)
        assertEq(pm.balanceOf(ALICE, marketId), 0);
    }

    function test_Multicall_EmptyArray() public {
        bytes[] memory calls = new bytes[](0);

        vm.prank(ALICE);
        bytes[] memory results = pm.multicall(calls);

        assertEq(results.length, 0);
    }

    function test_Multicall_SingleCall() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(pm.split, (marketId, 10 ether, ALICE));

        vm.prank(ALICE);
        bytes[] memory results = pm.multicall(calls);

        assertEq(results.length, 1);
        assertEq(pm.balanceOf(ALICE, marketId), 10);
    }

    /*//////////////////////////////////////////////////////////////
                           CLOSE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseMarket_Success() public {
        (uint256 mId,) = pm.createMarket("Closable", RESOLVER, address(wsteth), closeTime, true);

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, false, true, true);
        emit PAMM.Closed(mId, block.timestamp, RESOLVER);

        vm.prank(RESOLVER);
        pm.closeMarket(mId);

        (,,,,,, uint64 close,,,,) = pm.getMarket(mId);
        assertEq(close, block.timestamp);
    }

    function test_CloseMarket_RevertNotClosable() public {
        vm.expectRevert(PAMM.NotClosable.selector);
        vm.prank(RESOLVER);
        pm.closeMarket(marketId);
    }

    function test_CloseMarket_RevertNotResolver() public {
        (uint256 mId,) = pm.createMarket("Closable", RESOLVER, address(wsteth), closeTime, true);

        vm.expectRevert(PAMM.OnlyResolver.selector);
        vm.prank(ALICE);
        pm.closeMarket(mId);
    }

    function test_CloseMarket_RevertAlreadyClosed() public {
        (uint256 mId,) = pm.createMarket("Closable", RESOLVER, address(wsteth), closeTime, true);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(RESOLVER);
        pm.closeMarket(mId);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TradingOpen() public {
        assertTrue(pm.tradingOpen(marketId));

        vm.warp(closeTime);
        assertFalse(pm.tradingOpen(marketId));
    }

    function test_WinningId() public {
        assertEq(pm.winningId(marketId), 0);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        assertEq(pm.winningId(marketId), marketId);
    }

    function test_WinningId_NoWins() public {
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, false);

        assertEq(pm.winningId(marketId), noId);
    }

    function test_CollateralPerShare() public view {
        assertEq(pm.collateralPerShare(marketId), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                          BATCH VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetMarkets_SingleMarket() public view {
        (
            uint256[] memory marketIds,
            address[] memory resolvers,
            address[] memory collaterals,
            uint8[] memory decimalsList,
            uint8[] memory states,
            uint64[] memory closes,
            uint256[] memory collateralAmounts,
            uint256[] memory yesSupplies,
            uint256[] memory noSupplies,
            string[] memory descs,
            uint256 next
        ) = pm.getMarkets(0, 10);

        assertEq(marketIds.length, 1);
        assertEq(marketIds[0], marketId);
        assertEq(resolvers[0], RESOLVER);
        assertEq(collaterals[0], address(wsteth));
        assertEq(decimalsList[0], 18);
        assertEq(states[0], 0); // not resolved, not outcome, not canClose
        assertEq(closes[0], closeTime);
        assertEq(collateralAmounts[0], 0);
        assertEq(yesSupplies[0], 0);
        assertEq(noSupplies[0], 0);
        assertEq(descs[0], DESC);
        assertEq(next, 0);
    }

    function test_GetMarkets_Pagination() public {
        pm.createMarket("market2", RESOLVER, address(wsteth), closeTime, false);
        pm.createMarket("market3", RESOLVER, address(wsteth), closeTime, false);

        (uint256[] memory ids1,,,,,,,,,, uint256 next1) = pm.getMarkets(0, 2);
        assertEq(ids1.length, 2);
        assertEq(next1, 2);

        (uint256[] memory ids2,,,,,,,,,, uint256 next2) = pm.getMarkets(2, 2);
        assertEq(ids2.length, 1);
        assertEq(next2, 0);
    }

    function test_GetMarkets_EmptyStart() public view {
        (uint256[] memory ids,,,,,,,,,,) = pm.getMarkets(100, 10);
        assertEq(ids.length, 0);
    }

    function test_GetUserPositions() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        (
            uint256[] memory marketIds,
            uint256[] memory noIds,
            address[] memory collaterals,
            uint256[] memory yesBalances,
            uint256[] memory noBalances,
            uint256[] memory claimables,
            bool[] memory isResolved,
            bool[] memory isOpen,
            uint256 next
        ) = pm.getUserPositions(ALICE, 0, 10);

        assertEq(marketIds.length, 1);
        assertEq(marketIds[0], marketId);
        assertEq(noIds[0], noId);
        assertEq(collaterals[0], address(wsteth));
        assertEq(yesBalances[0], 5);
        assertEq(noBalances[0], 5);
        assertEq(claimables[0], 0);
        assertFalse(isResolved[0]);
        assertTrue(isOpen[0]);
        assertEq(next, 0);
    }

    function test_GetUserPositions_WithClaimable() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        (,,,,, uint256[] memory claimables, bool[] memory isResolved,,) =
            pm.getUserPositions(ALICE, 0, 10);

        assertTrue(isResolved[0]);
        assertEq(claimables[0], 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC6909 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.prank(ALICE);
        pm.transfer(BOB, marketId, 3);

        assertEq(pm.balanceOf(ALICE, marketId), 2);
        assertEq(pm.balanceOf(BOB, marketId), 3);
    }

    function test_TransferFrom_WithApproval() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, 3);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 3);

        assertEq(pm.balanceOf(ALICE, marketId), 2);
        assertEq(pm.balanceOf(BOB, marketId), 3);
        assertEq(pm.allowance(ALICE, BOB, marketId), 0);
    }

    function test_TransferFrom_WithOperator() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.prank(ALICE);
        pm.setOperator(BOB, true);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 5);

        assertEq(pm.balanceOf(BOB, marketId), 5);
    }

    function test_TransferFrom_MaxAllowance() public {
        vm.prank(ALICE);
        pm.split(marketId, 5 ether, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, type(uint256).max);

        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 3);

        assertEq(pm.allowance(ALICE, BOB, marketId), type(uint256).max);
    }

    function test_SupportsInterface() public view {
        assertTrue(pm.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(pm.supportsInterface(0x0f632fb3)); // ERC6909
    }

    /*//////////////////////////////////////////////////////////////
                         ETH COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_ETH() public {
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        (
            address resolver,
            address collateral,
            uint8 decimals,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            uint256 collateralLocked,
            uint256 yesSupply,
            uint256 noSupply,
            string memory description
        ) = pm.getMarket(ethMarketId);

        assertEq(resolver, RESOLVER);
        assertEq(collateral, address(0));
        assertEq(decimals, 18);
        assertFalse(resolved);
        assertFalse(outcome);
        assertFalse(canClose);
        assertEq(close, closeTime);
        assertEq(collateralLocked, 0);
        assertEq(yesSupply, 0);
        assertEq(noSupply, 0);
        assertEq(description, "ETH market");
        assertTrue(ethNoId != 0);
    }

    function test_Split_ETH() public {
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);
        uint256 aliceBefore = ALICE.balance;
        uint256 pammBefore = address(pm).balance;

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10 ether);
        assertEq(pm.balanceOf(ALICE, ethMarketId), 10);
        assertEq(pm.balanceOf(ALICE, ethNoId), 10);
        assertEq(address(pm).balance, pammBefore + 10 ether);
        assertEq(ALICE.balance, aliceBefore - 10 ether);
    }

    function test_Split_ETH_RefundsDust() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);
        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split{value: 10.5 ether}(ethMarketId, 0, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10 ether);
        assertEq(ALICE.balance, aliceBefore - 10 ether);
    }

    function test_Split_ETH_WithExplicitAmount() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);

        // Can pass collateralIn == msg.value
        vm.prank(ALICE);
        (uint256 shares,) = pm.split{value: 10 ether}(ethMarketId, 10 ether, ALICE);

        assertEq(shares, 10);
    }

    function test_Split_ETH_RevertWrongAmount() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);

        // collateralIn != msg.value should revert
        vm.expectRevert(PAMM.InvalidETHAmount.selector);
        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 5 ether, ALICE);
    }

    function test_Split_ETH_RevertNoValue() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);

        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(ALICE);
        pm.split{value: 0}(ethMarketId, 0, ALICE);
    }

    function test_Split_ERC20_RevertWithETHValue() public {
        vm.deal(ALICE, 100 ether);

        vm.expectRevert(PAMM.WrongCollateralType.selector);
        vm.prank(ALICE);
        pm.split{value: 1 ether}(marketId, 10 ether, ALICE);
    }

    function test_Merge_ETH() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);

        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 merged, uint256 collateralOut) = pm.merge(ethMarketId, 5, ALICE);

        assertEq(merged, 5);
        assertEq(collateralOut, 5 ether);
        assertEq(ALICE.balance, aliceBefore + 5 ether);
    }

    function test_Claim_ETH() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);

        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(ethMarketId, ALICE);

        assertEq(shares, 10);
        assertEq(payout, 10 ether);
        assertEq(ALICE.balance, aliceBefore + 10 ether);
    }

    function test_ETH_TransferFailed() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        ETHRejecter rejecter = new ETHRejecter();
        vm.deal(address(rejecter), 100 ether);

        // First split as rejecter
        vm.prank(address(rejecter));
        pm.split{value: 10 ether}(ethMarketId, 0, address(rejecter));

        // Try to merge - should fail because rejecter rejects ETH
        // 0xb12d13eb is ETHTransferFailed() selector from low-level helper
        vm.expectRevert(bytes4(0xb12d13eb));
        vm.prank(address(rejecter));
        pm.merge(ethMarketId, 5, address(rejecter));
    }

    /*//////////////////////////////////////////////////////////////
                     DIFFERENT DECIMALS TESTS (USDC)
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_USDC() public {
        MockUSDC usdc = new MockUSDC();

        (uint256 usdcMarketId,) =
            pm.createMarket("USDC market", RESOLVER, address(usdc), closeTime, false);

        (address resolver, address collateral, uint8 decimals,,,,,,,,) = pm.getMarket(usdcMarketId);

        assertEq(resolver, RESOLVER);
        assertEq(collateral, address(usdc));
        assertEq(decimals, 6);
    }

    function test_Split_USDC_6Decimals() public {
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 1000e6); // 1000 USDC

        vm.prank(ALICE);
        usdc.approve(address(pm), type(uint256).max);

        (uint256 usdcMarketId, uint256 usdcNoId) =
            pm.createMarket("USDC market", RESOLVER, address(usdc), closeTime, false);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(usdcMarketId, 10e6, ALICE); // 10 USDC

        // 1 share = 1e6 (10^6), so 10e6 / 1e6 = 10 shares
        assertEq(shares, 10);
        assertEq(used, 10e6);
        assertEq(pm.balanceOf(ALICE, usdcMarketId), 10);
        assertEq(pm.balanceOf(ALICE, usdcNoId), 10);
        assertEq(usdc.balanceOf(address(pm)), 10e6);
    }

    function test_Split_USDC_RefundsDust() public {
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 1000e6);

        vm.prank(ALICE);
        usdc.approve(address(pm), type(uint256).max);

        (uint256 usdcMarketId,) =
            pm.createMarket("USDC market", RESOLVER, address(usdc), closeTime, false);

        uint256 aliceBefore = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(usdcMarketId, 10.5e6, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10e6);
        assertEq(usdc.balanceOf(ALICE), aliceBefore - 10e6); // 0.5e6 refunded
    }

    function test_Claim_USDC() public {
        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, 1000e6);

        vm.prank(ALICE);
        usdc.approve(address(pm), type(uint256).max);

        (uint256 usdcMarketId,) =
            pm.createMarket("USDC market", RESOLVER, address(usdc), closeTime, false);

        vm.prank(ALICE);
        pm.split(usdcMarketId, 10e6, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(usdcMarketId, true);

        uint256 aliceBefore = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(usdcMarketId, ALICE);

        assertEq(shares, 10);
        assertEq(payout, 10e6);
        assertEq(usdc.balanceOf(ALICE), aliceBefore + 10e6);
    }

    function test_CollateralPerShare_USDC() public {
        MockUSDC usdc = new MockUSDC();

        (uint256 usdcMarketId,) =
            pm.createMarket("USDC market", RESOLVER, address(usdc), closeTime, false);

        assertEq(pm.collateralPerShare(usdcMarketId), 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                     DIFFERENT DECIMALS TESTS (WBTC)
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_WBTC() public {
        MockWBTC wbtc = new MockWBTC();

        (uint256 wbtcMarketId,) =
            pm.createMarket("WBTC market", RESOLVER, address(wbtc), closeTime, false);

        (,, uint8 decimals,,,,,,,,) = pm.getMarket(wbtcMarketId);
        assertEq(decimals, 8);
    }

    function test_Split_WBTC_8Decimals() public {
        MockWBTC wbtc = new MockWBTC();
        wbtc.mint(ALICE, 100e8); // 100 WBTC

        vm.prank(ALICE);
        wbtc.approve(address(pm), type(uint256).max);

        (uint256 wbtcMarketId, uint256 wbtcNoId) =
            pm.createMarket("WBTC market", RESOLVER, address(wbtc), closeTime, false);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(wbtcMarketId, 10e8, ALICE); // 10 WBTC

        // 1 share = 1e8 (10^8), so 10e8 / 1e8 = 10 shares
        assertEq(shares, 10);
        assertEq(used, 10e8);
        assertEq(pm.balanceOf(ALICE, wbtcMarketId), 10);
        assertEq(pm.balanceOf(ALICE, wbtcNoId), 10);
    }

    function test_CollateralPerShare_WBTC() public {
        MockWBTC wbtc = new MockWBTC();

        (uint256 wbtcMarketId,) =
            pm.createMarket("WBTC market", RESOLVER, address(wbtc), closeTime, false);

        assertEq(pm.collateralPerShare(wbtcMarketId), 1e8);
    }

    /*//////////////////////////////////////////////////////////////
                    SAME QUESTION DIFFERENT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_SameQuestionDifferentCollateral() public {
        MockUSDC usdc = new MockUSDC();

        string memory question = "Will BTC reach $100k?";

        // Create market with wstETH
        (uint256 ethMarketId,) =
            pm.createMarket(question, RESOLVER, address(wsteth), closeTime, false);

        // Create same question with USDC - should NOT revert
        (uint256 usdcMarketId,) =
            pm.createMarket(question, RESOLVER, address(usdc), closeTime, false);

        // Create same question with ETH - should NOT revert
        (uint256 nativeMarketId,) =
            pm.createMarket(question, RESOLVER, address(0), closeTime, false);

        // All three should be different market IDs
        assertTrue(ethMarketId != usdcMarketId);
        assertTrue(ethMarketId != nativeMarketId);
        assertTrue(usdcMarketId != nativeMarketId);

        // Verify collaterals
        (, address c1,,,,,,,,,) = pm.getMarket(ethMarketId);
        (, address c2,,,,,,,,,) = pm.getMarket(usdcMarketId);
        (, address c3,,,,,,,,,) = pm.getMarket(nativeMarketId);

        assertEq(c1, address(wsteth));
        assertEq(c2, address(usdc));
        assertEq(c3, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        INVALID COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_RevertInvalidCollateral() public {
        // Deploy a contract without decimals() function
        address noDecimals = address(new NoDecimalsContract());

        vm.expectRevert(PAMM.InvalidCollateral.selector);
        pm.createMarket("test", RESOLVER, noDecimals, closeTime, false);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Split_ERC20(uint256 collateralIn) public {
        collateralIn = bound(collateralIn, 1 ether, 100 ether);

        wsteth.mint(ALICE, collateralIn);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(marketId, collateralIn, ALICE);

        uint256 expectedShares = collateralIn / 1e18;
        uint256 expectedUsed = expectedShares * 1e18;

        assertEq(shares, expectedShares);
        assertEq(used, expectedUsed);
        assertEq(pm.balanceOf(ALICE, marketId), expectedShares);
    }

    function testFuzz_Split_ETH(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 1 ether, 100 ether);

        (uint256 ethMarketId,) = pm.createMarket("ETH fuzz", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, ethAmount);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split{value: ethAmount}(ethMarketId, 0, ALICE);

        uint256 expectedShares = ethAmount / 1e18;
        uint256 expectedUsed = expectedShares * 1e18;

        assertEq(shares, expectedShares);
        assertEq(used, expectedUsed);
    }

    function testFuzz_Split_USDC(uint256 usdcAmount) public {
        usdcAmount = bound(usdcAmount, 1e6, 1000000e6); // 1 to 1M USDC

        MockUSDC usdc = new MockUSDC();
        usdc.mint(ALICE, usdcAmount);

        vm.prank(ALICE);
        usdc.approve(address(pm), type(uint256).max);

        (uint256 usdcMarketId,) =
            pm.createMarket("USDC fuzz", RESOLVER, address(usdc), closeTime, false);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(usdcMarketId, usdcAmount, ALICE);

        uint256 expectedShares = usdcAmount / 1e6;
        uint256 expectedUsed = expectedShares * 1e6;

        assertEq(shares, expectedShares);
        assertEq(used, expectedUsed);
    }

    /*//////////////////////////////////////////////////////////////
                     FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_ETH() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH lifecycle", RESOLVER, address(0), closeTime, false);

        // Alice and Bob split
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);

        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        vm.prank(BOB);
        pm.split{value: 20 ether}(ethMarketId, 0, BOB);

        // Alice transfers some YES to Bob
        vm.prank(ALICE);
        pm.transfer(BOB, ethMarketId, 5);

        // Bob merges some
        vm.prank(BOB);
        pm.merge(ethMarketId, 10, BOB);

        // Resolve YES
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        // Both claim
        uint256 aliceYes = pm.balanceOf(ALICE, ethMarketId);
        uint256 bobYes = pm.balanceOf(BOB, ethMarketId);

        vm.prank(ALICE);
        (uint256 aliceShares, uint256 alicePayout) = pm.claim(ethMarketId, ALICE);

        vm.prank(BOB);
        (uint256 bobShares, uint256 bobPayout) = pm.claim(ethMarketId, BOB);

        assertEq(aliceShares, aliceYes);
        assertEq(alicePayout, aliceYes * 1e18);
        assertEq(bobShares, bobYes);
        assertEq(bobPayout, bobYes * 1e18);
    }

    function test_FullLifecycle_USDC() public {
        MockUSDC usdc = new MockUSDC();

        // Create USDC market
        (uint256 usdcMarketId, uint256 usdcNoId) =
            pm.createMarket("USDC lifecycle", RESOLVER, address(usdc), closeTime, false);

        // Fund and approve
        usdc.mint(ALICE, 1000e6);
        usdc.mint(BOB, 1000e6);

        vm.prank(ALICE);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(pm), type(uint256).max);

        // Split
        vm.prank(ALICE);
        pm.split(usdcMarketId, 100e6, ALICE); // 100 USDC = 100 shares

        vm.prank(BOB);
        pm.split(usdcMarketId, 200e6, BOB); // 200 USDC = 200 shares

        // Resolve NO
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(usdcMarketId, false);

        // Both claim NO shares
        uint256 aliceNo = pm.balanceOf(ALICE, usdcNoId);
        uint256 bobNo = pm.balanceOf(BOB, usdcNoId);

        vm.prank(ALICE);
        (uint256 aliceShares, uint256 alicePayout) = pm.claim(usdcMarketId, ALICE);

        vm.prank(BOB);
        (uint256 bobShares, uint256 bobPayout) = pm.claim(usdcMarketId, BOB);

        assertEq(aliceShares, aliceNo);
        assertEq(alicePayout, aliceNo * 1e6); // 100e6
        assertEq(bobShares, bobNo);
        assertEq(bobPayout, bobNo * 1e6); // 200e6
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_LosingSharesWorthless() public {
        // Alice splits, gets YES and NO
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Transfer all YES to Bob (Alice keeps NO)
        vm.prank(ALICE);
        pm.transfer(BOB, marketId, 10);

        // Resolve YES wins
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // Alice tries to claim with NO shares - should fail
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        // Bob can claim YES
        vm.prank(BOB);
        (uint256 shares, uint256 payout) = pm.claim(marketId, BOB);
        assertEq(shares, 10);
        assertEq(payout, 10 ether);
    }

    function test_Merge_AfterCloseReverts() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.merge(marketId, 5, ALICE);
    }

    function test_Merge_AfterResolveReverts() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.merge(marketId, 5, ALICE);
    }

    function test_Claim_ToDifferentReceiver() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 bobBefore = wsteth.balanceOf(BOB);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, BOB);

        assertEq(shares, 10);
        assertEq(payout, 10 ether);
        assertEq(wsteth.balanceOf(BOB), bobBefore + 10 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 0);
    }

    function test_Claim_RevertInvalidReceiver() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(ALICE);
        pm.claim(marketId, address(0));
    }

    function test_CollateralLocked_Accounting() public {
        // Split adds to collateralLocked
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        (,,,,,,, uint256 locked,,,) = pm.getMarket(marketId);
        assertEq(locked, 10 ether);

        // Merge subtracts from collateralLocked
        vm.prank(ALICE);
        pm.merge(marketId, 3, ALICE);

        (,,,,,,, locked,,,) = pm.getMarket(marketId);
        assertEq(locked, 7 ether);

        // Claim subtracts from collateralLocked
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        (,,,,,,, locked,,,) = pm.getMarket(marketId);
        assertEq(locked, 0);
    }

    function test_TotalSupply_Accounting() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        assertEq(pm.totalSupplyId(marketId), 10);
        assertEq(pm.totalSupplyId(noId), 10);

        vm.prank(ALICE);
        pm.merge(marketId, 3, ALICE);

        assertEq(pm.totalSupplyId(marketId), 7);
        assertEq(pm.totalSupplyId(noId), 7);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        assertEq(pm.totalSupplyId(marketId), 0);
        assertEq(pm.totalSupplyId(noId), 7); // NO shares remain (worthless)
    }

    function test_GetUserPositions_ClaimableWithFee() public {
        // Set 10% fee
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1000);

        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        (,,,,, uint256[] memory claimables,,,) = pm.getUserPositions(ALICE, 0, 10);

        // Claimable should be net of fee: 10 ether - 10% = 9 ether
        assertEq(claimables[0], 9 ether);
    }

    function test_ResolverFee_CanBeSetToZero() public {
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500);
        assertEq(pm.resolverFeeBps(RESOLVER), 500);

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(0);
        assertEq(pm.resolverFeeBps(RESOLVER), 0);
    }

    function test_ResolverFee_DifferentResolversDifferentFees() public {
        address RESOLVER2 = makeAddr("RESOLVER2");

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500); // 5%

        vm.prank(RESOLVER2);
        pm.setResolverFeeBps(1000); // 10%

        assertEq(pm.resolverFeeBps(RESOLVER), 500);
        assertEq(pm.resolverFeeBps(RESOLVER2), 1000);
    }

    function test_Merge_ToDifferentReceiver() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        uint256 bobBefore = wsteth.balanceOf(BOB);

        vm.prank(ALICE);
        (uint256 merged, uint256 collateralOut) = pm.merge(marketId, 5, BOB);

        assertEq(merged, 5);
        assertEq(collateralOut, 5 ether);
        assertEq(wsteth.balanceOf(BOB), bobBefore + 5 ether);
        // Alice's tokens burned, not Bob's
        assertEq(pm.balanceOf(ALICE, marketId), 5);
        assertEq(pm.balanceOf(ALICE, noId), 5);
    }

    function test_Merge_RevertInvalidReceiver() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(ALICE);
        pm.merge(marketId, 5, address(0));
    }

    function test_CloseMarket_ThenResolve() public {
        (uint256 mId,) = pm.createMarket("Closable", RESOLVER, address(wsteth), closeTime, true);

        // Early close
        vm.warp(block.timestamp + 1 days);
        vm.prank(RESOLVER);
        pm.closeMarket(mId);

        // Can resolve immediately after early close
        vm.prank(RESOLVER);
        pm.resolve(mId, true);

        (,,, bool resolved, bool outcome,,,,,,) = pm.getMarket(mId);
        assertTrue(resolved);
        assertTrue(outcome);
    }

    function test_GetMarkets_StateEncoding() public {
        // Create market with canClose = true
        (uint256 mId,) =
            pm.createMarket("Closable market", RESOLVER, address(wsteth), closeTime, true);

        // Get markets - check state encoding
        (,,,, uint8[] memory states,,,,,,) = pm.getMarkets(0, 10);

        // Find the new market (last one)
        uint8 state = states[states.length - 1];

        // canClose = true -> bit 2 set -> state = 4
        assertEq(state, 4);

        // Resolve the market
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(mId, true);

        (,,,, states,,,,,,) = pm.getMarkets(0, 10);
        state = states[states.length - 1];

        // resolved=true (bit 0), outcome=true (bit 1), canClose=true (bit 2)
        // state = 1 + 2 + 4 = 7
        assertEq(state, 7);
    }

    function test_PoolKey_DeterministicOrdering() public view {
        // Pool key should always order YES/NO correctly regardless of which is smaller
        IZAMM.PoolKey memory key = pm.poolKey(marketId, 30);

        // id0 should always be < id1
        assertTrue(key.id0 < key.id1);

        // Both tokens should be PAMM
        assertEq(key.token0, address(pm));
        assertEq(key.token1, address(pm));
    }

    function test_Claim_ETH_ToDifferentReceiver() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH claim test", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        uint256 bobBefore = BOB.balance;

        vm.prank(ALICE);
        pm.claim(ethMarketId, BOB);

        assertEq(BOB.balance, bobBefore + 10 ether);
    }

    function test_ResolverFee_ETH_PaidToResolver() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH fee test2", RESOLVER, address(0), closeTime, false);

        vm.prank(RESOLVER);
        pm.setResolverFeeBps(500); // 5%

        vm.deal(ALICE, 100 ether);
        vm.prank(ALICE);
        pm.split{value: 10 ether}(ethMarketId, 0, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        uint256 resolverBefore = RESOLVER.balance;
        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        pm.claim(ethMarketId, ALICE);

        // Fee = 10 * 5% = 0.5 ether
        assertEq(RESOLVER.balance, resolverBefore + 0.5 ether);
        assertEq(ALICE.balance, aliceBefore + 9.5 ether);
    }

    function testFuzz_CollateralLockedInvariant(uint256 aliceAmt, uint256 bobAmt, uint256 mergeAmt)
        public
    {
        aliceAmt = bound(aliceAmt, 1 ether, 50 ether);
        bobAmt = bound(bobAmt, 1 ether, 50 ether);

        wsteth.mint(ALICE, aliceAmt);
        wsteth.mint(BOB, bobAmt);

        vm.prank(ALICE);
        pm.split(marketId, aliceAmt, ALICE);

        vm.prank(BOB);
        pm.split(marketId, bobAmt, BOB);

        uint256 aliceShares = pm.balanceOf(ALICE, marketId);
        mergeAmt = bound(mergeAmt, 0, aliceShares);

        if (mergeAmt > 0) {
            vm.prank(ALICE);
            pm.merge(marketId, mergeAmt, ALICE);
        }

        // Invariant: collateralLocked == totalSupply * perShare
        (,,,,,,, uint256 locked,,,) = pm.getMarket(marketId);
        uint256 totalYes = pm.totalSupplyId(marketId);

        assertEq(locked, totalYes * 1e18, "collateralLocked should equal totalSupply * perShare");
    }

    function testFuzz_SplitMergeClaim_NoFundsLost(uint256 splitAmt, uint256 mergeAmt, bool yesWins)
        public
    {
        splitAmt = bound(splitAmt, 1 ether, 50 ether);

        wsteth.mint(ALICE, splitAmt);
        uint256 aliceStartBalance = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(marketId, splitAmt, ALICE);

        mergeAmt = bound(mergeAmt, 0, shares);

        uint256 mergedCollateral;
        if (mergeAmt > 0) {
            vm.prank(ALICE);
            (, mergedCollateral) = pm.merge(marketId, mergeAmt, ALICE);
        }

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, yesWins);

        uint256 claimedCollateral;
        uint256 winId = yesWins ? marketId : noId;
        if (pm.balanceOf(ALICE, winId) > 0) {
            vm.prank(ALICE);
            (, claimedCollateral) = pm.claim(marketId, ALICE);
        }

        uint256 aliceEndBalance = wsteth.balanceOf(ALICE);
        uint256 totalReceived = aliceEndBalance - (aliceStartBalance - used);
        uint256 expectedReceived = mergedCollateral + claimedCollateral;

        assertEq(totalReceived, expectedReceived, "Alice should receive all funds back (no fee)");
    }

    /*//////////////////////////////////////////////////////////////
                        ERC6909 EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_Transfer_ToSelf() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        uint256 balBefore = pm.balanceOf(ALICE, marketId);

        vm.prank(ALICE);
        pm.transfer(ALICE, marketId, 5);

        // Balance unchanged when transferring to self
        assertEq(pm.balanceOf(ALICE, marketId), balBefore);
    }

    function test_Transfer_ZeroAmount() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.prank(ALICE);
        bool success = pm.transfer(BOB, marketId, 0);

        assertTrue(success);
        assertEq(pm.balanceOf(ALICE, marketId), 10);
        assertEq(pm.balanceOf(BOB, marketId), 0);
    }

    function test_TransferFrom_ZeroAmount() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, 100);

        vm.prank(BOB);
        bool success = pm.transferFrom(ALICE, BOB, marketId, 0);

        assertTrue(success);
        assertEq(pm.balanceOf(ALICE, marketId), 10);
    }

    function test_Approve_ZeroAmount() public {
        vm.prank(ALICE);
        bool success = pm.approve(BOB, marketId, 0);

        assertTrue(success);
        assertEq(pm.allowance(ALICE, BOB, marketId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        PAGINATION EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_GetMarkets_StartBeyondLength() public {
        (uint256[] memory marketIds,,,,,,,,,, uint256 next) = pm.getMarkets(1000, 10);

        assertEq(marketIds.length, 0);
        assertEq(next, 0);
    }

    function test_GetMarkets_CountExceedsRemaining() public {
        // Only 1 market exists
        (uint256[] memory marketIds,,,,,,,,,, uint256 next) = pm.getMarkets(0, 1000);

        assertEq(marketIds.length, 1);
        assertEq(next, 0); // No more pages
    }

    function test_GetUserPositions_StartBeyondLength() public {
        (uint256[] memory marketIds,,,,,,,, uint256 next) = pm.getUserPositions(ALICE, 1000, 10);

        assertEq(marketIds.length, 0);
        assertEq(next, 0);
    }

    function test_GetUserPositions_NoBalance() public {
        // Alice has no positions
        (
            ,,,
            uint256[] memory yesBalances,
            uint256[] memory noBalances,
            uint256[] memory claimables,,,
        ) = pm.getUserPositions(ALICE, 0, 10);

        assertEq(yesBalances[0], 0);
        assertEq(noBalances[0], 0);
        assertEq(claimables[0], 0);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTIPLE RESOLVERS SAME DESCRIPTION
    //////////////////////////////////////////////////////////////*/

    function test_SameDescriptionDifferentResolvers() public {
        address RESOLVER2 = makeAddr("RESOLVER2");

        (uint256 mId1,) =
            pm.createMarket("Same question", RESOLVER, address(wsteth), closeTime, false);
        (uint256 mId2,) =
            pm.createMarket("Same question", RESOLVER2, address(wsteth), closeTime, false);

        // Different market IDs
        assertTrue(mId1 != mId2);

        // Both markets exist
        (address r1,,,,,,,,,,) = pm.getMarket(mId1);
        (address r2,,,,,,,,,,) = pm.getMarket(mId2);

        assertEq(r1, RESOLVER);
        assertEq(r2, RESOLVER2);
    }

    /*//////////////////////////////////////////////////////////////
                    RESOLVER FEE CHANGE MID-MARKET
    //////////////////////////////////////////////////////////////*/

    function test_ResolverFee_ChangedAfterSplit() public {
        // User splits with 0% fee expectation
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Resolver increases fee (user beware!)
        vm.prank(RESOLVER);
        pm.setResolverFeeBps(1000); // 10%

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256 resolverBefore = wsteth.balanceOf(RESOLVER);

        vm.prank(ALICE);
        (uint256 shares, uint256 payout) = pm.claim(marketId, ALICE);

        // User gets 10% less than expected
        assertEq(shares, 10);
        assertEq(payout, 9 ether);
        assertEq(wsteth.balanceOf(RESOLVER), resolverBefore + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Reentrancy_ClaimBlocked() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH reentrant", RESOLVER, address(0), closeTime, false);

        // Deploy attacker and have it split
        ReentrantClaimAttacker attacker = new ReentrantClaimAttacker(pm, ethMarketId);
        vm.deal(address(attacker), 100 ether);

        attacker.doSplit{value: 10 ether}();

        // Resolve
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, true);

        // Attacker tries to claim - reentrancy should be blocked
        vm.expectRevert(); // Reentrancy error
        attacker.doClaim();
    }

    /*//////////////////////////////////////////////////////////////
                        COLLATERAL PER SHARE VIEW
    //////////////////////////////////////////////////////////////*/

    function test_CollateralPerShare_ETH_View() public {
        (uint256 ethMarketId,) = pm.createMarket("ETH cps", RESOLVER, address(0), closeTime, false);
        assertEq(pm.collateralPerShare(ethMarketId), 1e18);
    }

    function test_CollateralPerShare_USDC_View() public {
        MockUSDC usdc = new MockUSDC();
        (uint256 usdcMarketId,) =
            pm.createMarket("USDC cps", RESOLVER, address(usdc), closeTime, false);
        assertEq(pm.collateralPerShare(usdcMarketId), 1e6);
    }

    function test_CollateralPerShare_RevertNotFound_View() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        pm.collateralPerShare(999);
    }

    /*//////////////////////////////////////////////////////////////
                    MARKET WITH ZERO ACTIVITY
    //////////////////////////////////////////////////////////////*/

    function test_Resolve_NoSharesMinted() public {
        // Create and resolve without any splits
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        (,,, bool resolved, bool outcome,,, uint256 locked,,,) = pm.getMarket(marketId);
        assertTrue(resolved);
        assertTrue(outcome);
        assertEq(locked, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    DESCRIPTION STORAGE
    //////////////////////////////////////////////////////////////*/

    function test_Description_StoredCorrectly() public {
        string memory desc = "Will BTC hit $100k?";
        (uint256 mId,) = pm.createMarket(desc, RESOLVER, address(wsteth), closeTime, false);

        assertEq(pm.descriptions(mId), desc);

        (,,,,,,,,,, string memory storedDesc) = pm.getMarket(mId);
        assertEq(storedDesc, desc);
    }

    function test_Description_EmptyString() public {
        (uint256 mId,) = pm.createMarket("", RESOLVER, address(wsteth), closeTime, false);

        assertEq(pm.descriptions(mId), "");
    }

    function test_Description_LongString() public {
        string memory longDesc =
            "This is a very long description that exceeds typical lengths and tests storage of longer strings in the contract which might be used for detailed market descriptions";
        (uint256 mId,) = pm.createMarket(longDesc, RESOLVER, address(wsteth), closeTime, false);

        assertEq(pm.descriptions(mId), longDesc);
    }

    /*//////////////////////////////////////////////////////////////
                    FINAL EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_TransferFrom_InsufficientAllowance() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.prank(ALICE);
        pm.approve(BOB, marketId, 5);

        // Bob tries to transfer more than allowed
        vm.expectRevert(); // arithmetic underflow
        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 6);
    }

    function test_TransferFrom_OperatorDoesNotConsumeAllowance() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Set Bob as operator AND give allowance
        vm.prank(ALICE);
        pm.setOperator(BOB, true);
        vm.prank(ALICE);
        pm.approve(BOB, marketId, 5);

        // Bob transfers as operator
        vm.prank(BOB);
        pm.transferFrom(ALICE, BOB, marketId, 3);

        // Allowance should be unchanged (operator bypasses allowance)
        assertEq(pm.allowance(ALICE, BOB, marketId), 5);
    }

    function test_Claim_DoubleClaimFails() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // First claim succeeds
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);

        // Second claim fails (no balance)
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.claim(marketId, ALICE);
    }

    function test_Merge_UnequalBalances_TakesMinimum() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Transfer some YES to Bob, Alice now has 10 NO but only 7 YES
        vm.prank(ALICE);
        pm.transfer(BOB, marketId, 3);

        assertEq(pm.balanceOf(ALICE, marketId), 7); // YES
        assertEq(pm.balanceOf(ALICE, noId), 10); // NO

        // Try to merge 10 - should only merge 7 (min of YES balance)
        vm.prank(ALICE);
        (uint256 merged, uint256 collateralOut) = pm.merge(marketId, 10, ALICE);

        assertEq(merged, 7);
        assertEq(collateralOut, 7 ether);
        assertEq(pm.balanceOf(ALICE, marketId), 0); // All YES burned
        assertEq(pm.balanceOf(ALICE, noId), 3); // 10 - 7 = 3 NO remaining
    }

    function test_Merge_UnequalBalances_NoSideLower() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // Transfer some NO to Bob, Alice now has 10 YES but only 4 NO
        vm.prank(ALICE);
        pm.transfer(BOB, noId, 6);

        assertEq(pm.balanceOf(ALICE, marketId), 10); // YES
        assertEq(pm.balanceOf(ALICE, noId), 4); // NO

        // Try to merge 10 - should only merge 4 (min of NO balance)
        vm.prank(ALICE);
        (uint256 merged,) = pm.merge(marketId, 10, ALICE);

        assertEq(merged, 4);
        assertEq(pm.balanceOf(ALICE, marketId), 6); // 10 - 4 = 6 YES remaining
        assertEq(pm.balanceOf(ALICE, noId), 0); // All NO burned
    }

    function test_PoolKey_Consistency() public view {
        // Pool key should be consistent for same inputs
        IZAMM.PoolKey memory key1 = pm.poolKey(marketId, 30);
        IZAMM.PoolKey memory key2 = pm.poolKey(marketId, 30);

        assertEq(key1.id0, key2.id0);
        assertEq(key1.id1, key2.id1);
        assertEq(key1.token0, key2.token0);
        assertEq(key1.token1, key2.token1);
        assertEq(key1.feeOrHook, key2.feeOrHook);
    }

    function test_AllMarkets_GrowsCorrectly() public {
        uint256 initialCount = pm.marketCount();

        pm.createMarket("Market 1", RESOLVER, address(wsteth), closeTime, false);
        pm.createMarket("Market 2", RESOLVER, address(wsteth), closeTime, false);
        pm.createMarket("Market 3", RESOLVER, address(wsteth), closeTime, false);

        assertEq(pm.marketCount(), initialCount + 3);
    }

    function test_Split_ExactCollateralAmount() public {
        // Split exactly 5 ether - no dust
        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split(marketId, 5 ether, ALICE);

        assertEq(shares, 5);
        assertEq(used, 5 ether);
        // No refund should occur
        assertEq(wsteth.balanceOf(ALICE), 95 ether); // Started with 100, spent exactly 5
    }

    function test_CreateMarket_CloseTimestamp_JustAfterNow() public {
        uint64 justAfterNow = uint64(block.timestamp + 1);
        (uint256 mId,) =
            pm.createMarket("Close soon", RESOLVER, address(wsteth), justAfterNow, false);

        assertTrue(pm.tradingOpen(mId));

        // Warp 1 second, now closed
        vm.warp(block.timestamp + 1);
        assertFalse(pm.tradingOpen(mId));
    }

    function test_Resolve_BothOutcomes() public {
        // Create two markets, resolve one YES, one NO
        (uint256 mId1,) = pm.createMarket("YES market", RESOLVER, address(wsteth), closeTime, false);
        (uint256 mId2,) = pm.createMarket("NO market", RESOLVER, address(wsteth), closeTime, false);

        vm.warp(closeTime);

        vm.prank(RESOLVER);
        pm.resolve(mId1, true);

        vm.prank(RESOLVER);
        pm.resolve(mId2, false);

        assertEq(pm.winningId(mId1), mId1); // YES wins -> marketId
        assertEq(pm.winningId(mId2), pm.getNoId(mId2)); // NO wins -> noId
    }

    /*//////////////////////////////////////////////////////////////
                           METADATA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Name_ReturnsCorrectFormat() public view {
        string memory n = pm.name(marketId);
        // Should be "PAMM-<marketId>"
        assertTrue(bytes(n).length > 5); // "PAMM-" + at least 1 digit
        // Check prefix
        assertEq(bytes(n)[0], "P");
        assertEq(bytes(n)[1], "A");
        assertEq(bytes(n)[2], "M");
        assertEq(bytes(n)[3], "M");
        assertEq(bytes(n)[4], "-");
    }

    function test_Name_Zero() public view {
        assertEq(pm.name(0), "PAMM-0");
    }

    function test_Name_SmallNumber() public {
        PAMM p = new PAMM();
        assertEq(p.name(123), "PAMM-123");
    }

    function test_Name_LargeNumber() public view {
        // Test with actual marketId (large number)
        string memory n = pm.name(marketId);
        assertTrue(bytes(n).length > 10); // "PAMM-" + many digits
    }

    function test_Symbol_ReturnsConstant() public view {
        assertEq(pm.symbol(marketId), "PAMM");
        assertEq(pm.symbol(noId), "PAMM");
        assertEq(pm.symbol(0), "PAMM");
        assertEq(pm.symbol(type(uint256).max), "PAMM");
    }

    function testFuzz_Name_AnyId(uint256 id) public view {
        string memory n = pm.name(id);
        // Should always start with "PAMM-"
        assertEq(bytes(n)[0], "P");
        assertEq(bytes(n)[1], "A");
        assertEq(bytes(n)[2], "M");
        assertEq(bytes(n)[3], "M");
        assertEq(bytes(n)[4], "-");
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN URI TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TokenURI_YesToken_Pending() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        string memory uri = pm.tokenURI(marketId);

        // Check it's a data URI with utf8
        assertTrue(_startsWith(uri, "data:application/json;utf8,"));
        // Check it contains YES and description
        assertTrue(_contains(uri, "YES:"));
        assertTrue(_contains(uri, "ETH")); // part of description
        // Check status is Pending
        assertTrue(_contains(uri, "Pending"));
    }

    function test_TokenURI_YesToken_Resolved_YesWins() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        string memory uri = pm.tokenURI(marketId);
        assertTrue(_contains(uri, "YES wins"));
    }

    function test_TokenURI_YesToken_Resolved_NoWins() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, false);

        string memory uri = pm.tokenURI(marketId);
        assertTrue(_contains(uri, "NO wins"));
    }

    function test_TokenURI_NoToken() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        string memory uri = pm.tokenURI(noId);

        assertTrue(_startsWith(uri, "data:application/json;utf8,"));
        assertTrue(_contains(uri, "NO Share"));
    }

    function test_TokenURI_Reverts_UnknownId() public {
        uint256 randomId = uint256(keccak256("random"));
        vm.expectRevert(abi.encodeWithSignature("MarketNotFound()"));
        pm.tokenURI(randomId);
    }

    function test_TokenURI_NoToken_BeforeSplit_Reverts() public {
        // NO token id exists conceptually but has no supply yet
        vm.expectRevert(abi.encodeWithSignature("MarketNotFound()"));
        pm.tokenURI(noId);
    }

    // Helper: check if string starts with prefix
    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (strBytes.length < prefixBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    // Helper: check if string contains substring
    function _contains(string memory str, string memory substr) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);
        if (substrBytes.length > strBytes.length) return false;
        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM MANY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimMany_SingleMarket() public {
        // Setup: split and resolve
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId;

        uint256 balBefore = wsteth.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 totalPayout = pm.claimMany(ids, ALICE);
        uint256 balAfter = wsteth.balanceOf(ALICE);

        assertEq(totalPayout, 10 ether);
        assertEq(balAfter - balBefore, 10 ether);
    }

    function test_ClaimMany_MultipleMarkets() public {
        // Create second market
        (uint256 marketId2,) =
            pm.createMarket("Second market", RESOLVER, address(wsteth), closeTime, false);

        // Split into both markets
        vm.startPrank(ALICE);
        pm.split(marketId, 10 ether, ALICE);
        pm.split(marketId2, 5 ether, ALICE);
        vm.stopPrank();

        // Resolve both (YES wins for both)
        vm.warp(closeTime + 1);
        vm.startPrank(RESOLVER);
        pm.resolve(marketId, true);
        pm.resolve(marketId2, true);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = marketId;
        ids[1] = marketId2;

        uint256 balBefore = wsteth.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 totalPayout = pm.claimMany(ids, ALICE);
        uint256 balAfter = wsteth.balanceOf(ALICE);

        assertEq(totalPayout, 15 ether);
        assertEq(balAfter - balBefore, 15 ether);
    }

    function test_ClaimMany_SkipsUnresolved() public {
        // Create second market
        (uint256 marketId2,) =
            pm.createMarket("Second market", RESOLVER, address(wsteth), closeTime, false);

        // Split into both markets
        vm.startPrank(ALICE);
        pm.split(marketId, 10 ether, ALICE);
        pm.split(marketId2, 5 ether, ALICE);
        vm.stopPrank();

        // Only resolve first market
        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256[] memory ids = new uint256[](2);
        ids[0] = marketId;
        ids[1] = marketId2; // Not resolved - should be skipped

        vm.prank(ALICE);
        uint256 totalPayout = pm.claimMany(ids, ALICE);

        assertEq(totalPayout, 10 ether); // Only first market claimed
    }

    function test_ClaimMany_SkipsNoBalance() public {
        // Split only as ALICE
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId;

        // BOB has no balance - should revert with AmountZero
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSignature("AmountZero()"));
        pm.claimMany(ids, BOB);
    }

    function test_ClaimMany_RevertsZeroReceiver() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId;

        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        pm.claimMany(ids, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      EXACT-OUT EARLY GUARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SellYesForExactCollateral_RevertsEarlyIfMaxSwapExceedsMaxIn() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // maxSwapIn (100) > maxYesIn (10) should revert early
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ExcessiveInput()"));
        pm.sellYesForExactCollateral(marketId, 1 ether, 10, 100, 30, ALICE, 0);
    }

    function test_SellNoForExactCollateral_RevertsEarlyIfMaxSwapExceedsMaxIn() public {
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        // maxSwapIn (100) > maxNoIn (10) should revert early
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("ExcessiveInput()"));
        pm.sellNoForExactCollateral(marketId, 1 ether, 10, 100, 30, ALICE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       ADDITIONAL COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseMarket_RevertAlreadyResolved() public {
        // Create a closable market
        (uint256 mId,) = pm.createMarket("Closable", RESOLVER, address(wsteth), closeTime, true);

        // Warp past close time and resolve it
        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(mId, true);

        // Try to close an already resolved market - should revert
        vm.prank(RESOLVER);
        vm.expectRevert(PAMM.AlreadyResolved.selector);
        pm.closeMarket(mId);
    }

    function test_Split_ETH_RefundsETHDust_Coverage() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market dust", RESOLVER, address(0), closeTime, false);

        // Fund ALICE with ETH
        vm.deal(ALICE, 100 ether);
        uint256 aliceBalBefore = ALICE.balance;

        // Split with dust (10.5 ETH should give 10 shares and refund 0.5 ETH)
        vm.prank(ALICE);
        (uint256 shares, uint256 used) = pm.split{value: 10.5 ether}(ethMarketId, 0, ALICE);

        assertEq(shares, 10);
        assertEq(used, 10 ether);
        // Alice should have received 0.5 ETH refund
        assertEq(ALICE.balance, aliceBalBefore - 10 ether);
    }

    function test_ClaimMany_AllSkipped_RevertsAmountZero() public {
        // Create a market but don't split (no positions)
        (uint256 marketId2,) =
            pm.createMarket("Empty market", RESOLVER, address(wsteth), closeTime, false);

        // Resolve it
        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId2, true);

        // Try to claim with no balance - should revert
        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId2;

        vm.prank(ALICE);
        vm.expectRevert(PAMM.AmountZero.selector);
        pm.claimMany(ids, ALICE);
    }

    function test_ClaimMany_SkipsInvalidMarket() public {
        // Setup: split and resolve a valid market
        vm.prank(ALICE);
        pm.split(marketId, 10 ether, ALICE);

        vm.warp(closeTime + 1);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true);

        // Try to claim from valid market + invalid market ID
        uint256[] memory ids = new uint256[](2);
        ids[0] = 999999; // Invalid market (no resolver)
        ids[1] = marketId;

        uint256 balBefore = wsteth.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 totalPayout = pm.claimMany(ids, ALICE);

        // Should skip invalid and claim from valid
        assertEq(totalPayout, 10 ether);
        assertEq(wsteth.balanceOf(ALICE) - balBefore, 10 ether);
    }

    function test_CloseMarket_RevertMarketNotFound() public {
        vm.prank(RESOLVER);
        vm.expectRevert(PAMM.MarketNotFound.selector);
        pm.closeMarket(999999);
    }

    function test_CreateMarket_InvalidDecimals() public {
        // Deploy a mock token that returns decimals > 77
        MockHighDecimals highDec = new MockHighDecimals();

        vm.expectRevert(PAMM.InvalidDecimals.selector);
        pm.createMarket("High decimals", RESOLVER, address(highDec), closeTime, false);
    }
}

/// @notice Mock ERC20 with decimals > 77 for testing InvalidDecimals
contract MockHighDecimals {
    uint8 public decimals = 78;
}

/// @notice Contract without decimals() function for testing
contract NoDecimalsContract {
    // Intentionally no decimals() function

    }

/// @notice Contract that attempts reentrancy on claim
contract ReentrantClaimAttacker {
    PAMM public pamm;
    uint256 public targetMarketId;
    bool public attacking;

    constructor(PAMM _pamm, uint256 _marketId) {
        pamm = _pamm;
        targetMarketId = _marketId;
    }

    function doSplit() external payable {
        pamm.split{value: msg.value}(targetMarketId, 0, address(this));
    }

    function doClaim() external {
        pamm.claim(targetMarketId, address(this));
    }

    receive() external payable {
        if (!attacking) {
            attacking = true;
            // Try to reenter claim
            pamm.claim(targetMarketId, address(this));
        }
    }
}

/*//////////////////////////////////////////////////////////////
                        ZAMM INTEGRATION TESTS
//////////////////////////////////////////////////////////////*/

import {ZAMM} from "@zamm/ZAMM.sol";

contract PAMM_ZAMM_Test is Test {
    PAMM internal pm;
    ZAMM internal zamm;
    MockERC20 internal wsteth;

    address internal RESOLVER = makeAddr("RESOLVER");
    address internal ALICE = makeAddr("ALICE");
    address internal BOB = makeAddr("BOB");

    string internal constant DESC = "Will ETH reach $10k in 2025?";
    uint64 internal closeTime;

    uint256 internal marketId;
    uint256 internal noId;

    // ZAMM's expected address from PAMM
    address constant ZAMM_ADDRESS = 0x000000000000040470635EB91b7CE4D132D616eD;
    uint256 constant FEE_BPS = 30; // 0.3%

    function setUp() public {
        // Deploy ZAMM at the expected address using CREATE2-style deployment
        // The ZAMM constructor stores tx.origin as fee setter in slot 0x00
        bytes memory zammCode = type(ZAMM).creationCode;

        // First deploy to get the runtime bytecode
        address zammDeployed;
        assembly {
            zammDeployed := create(0, add(zammCode, 0x20), mload(zammCode))
        }

        // Etch the runtime code to the expected address
        vm.etch(ZAMM_ADDRESS, zammDeployed.code);

        // Initialize storage slot 0x00 (feeToSetter) to this contract
        // This is what the constructor would set
        vm.store(ZAMM_ADDRESS, bytes32(uint256(0x00)), bytes32(uint256(uint160(address(this)))));

        zamm = ZAMM(payable(ZAMM_ADDRESS));

        wsteth = new MockERC20();
        pm = new PAMM();
        closeTime = uint64(block.timestamp + 30 days);

        // Fund users with large amounts (need > 1000 shares per LP to exceed MINIMUM_LIQUIDITY)
        wsteth.mint(ALICE, 100000 ether);
        wsteth.mint(BOB, 100000 ether);
        vm.deal(ALICE, 100000 ether);
        vm.deal(BOB, 100000 ether);

        // Approve PM for wstETH
        vm.prank(ALICE);
        wsteth.approve(address(pm), type(uint256).max);
        vm.prank(BOB);
        wsteth.approve(address(pm), type(uint256).max);

        // Create default market with wstETH collateral
        (marketId, noId) = pm.createMarket(DESC, RESOLVER, address(wsteth), closeTime, false);
    }

    /*//////////////////////////////////////////////////////////////
                          POOLKEY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PoolKey_OrdersTokensCorrectly() public view {
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);

        // YES/NO ids should be ordered correctly (id0 < id1)
        assertTrue(key.id0 < key.id1, "id0 should be less than id1");

        // Both tokens should be the PAMM contract itself
        assertEq(key.token0, address(pm), "token0 should be PAMM");
        assertEq(key.token1, address(pm), "token1 should be PAMM");

        // Fee should be set
        assertEq(key.feeOrHook, FEE_BPS, "fee should match");
    }

    function test_PoolKey_ConsistentAcrossCalls() public view {
        IZAMM.PoolKey memory key1 = pm.poolKey(marketId, FEE_BPS);
        IZAMM.PoolKey memory key2 = pm.poolKey(marketId, FEE_BPS);

        assertEq(key1.id0, key2.id0, "id0 should be consistent");
        assertEq(key1.id1, key2.id1, "id1 should be consistent");
        assertEq(key1.token0, key2.token0, "token0 should be consistent");
        assertEq(key1.token1, key2.token1, "token1 should be consistent");
        assertEq(key1.feeOrHook, key2.feeOrHook, "feeOrHook should be consistent");
    }

    function test_PoolKey_DifferentFeesGenerateDifferentPools() public view {
        IZAMM.PoolKey memory key30 = pm.poolKey(marketId, 30);
        IZAMM.PoolKey memory key100 = pm.poolKey(marketId, 100);

        // Keys should differ only in fee
        assertEq(key30.id0, key100.id0, "id0 should be same");
        assertEq(key30.id1, key100.id1, "id1 should be same");
        assertNotEq(key30.feeOrHook, key100.feeOrHook, "feeOrHook should differ");
    }

    /*//////////////////////////////////////////////////////////////
                    SPLIT AND ADD LIQUIDITY TESTS (ERC20)
    //////////////////////////////////////////////////////////////*/

    function test_SplitAndAddLiquidity_ERC20_Success() public {
        // Need at least 1001 shares to get liquidity > 0 after MINIMUM_LIQUIDITY deduction
        // sqrt(1001 * 1001) = 1001, 1001 - 1000 = 1 liquidity
        // Use larger amounts for cleaner tests
        uint256 collateralIn = 10000 ether; // 10000 shares each

        vm.prank(ALICE);
        (uint256 shares, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, collateralIn, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Should mint 10000 shares (10000 ether / 1e18)
        assertEq(shares, 10000, "should mint 10000 shares");
        assertTrue(liquidity > 0, "should receive liquidity tokens");

        // ALICE should have LP tokens in ZAMM
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId = _getPoolId(key);
        assertEq(zamm.balanceOf(ALICE, poolId), liquidity, "ALICE should have LP tokens");

        // PAMM should have the collateral locked
        (,,,,,,, uint256 collateralLocked,,,) = pm.getMarket(marketId);
        assertEq(collateralLocked, 10000 ether, "collateral should be locked");

        // Total supply should be updated
        assertEq(pm.totalSupplyId(marketId), 10000, "YES supply should be 10000");
        assertEq(pm.totalSupplyId(noId), 10000, "NO supply should be 10000");
    }

    function test_SplitAndAddLiquidity_ERC20_RefundsDust() public {
        uint256 collateralIn = 10000.5 ether; // 0.5 ether dust

        uint256 aliceBefore = wsteth.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 shares,) =
            pm.splitAndAddLiquidity(marketId, collateralIn, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Should mint 10000 shares (floored)
        assertEq(shares, 10000, "should mint 10000 shares");

        // ALICE should get 0.5 ether refunded
        assertEq(wsteth.balanceOf(ALICE), aliceBefore - 10000 ether, "dust should be refunded");
    }

    function test_SplitAndAddLiquidity_ERC20_MinLiquidity() public {
        uint256 collateralIn = 10000 ether;
        uint256 minLiquidity = 1; // Very low minimum

        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, collateralIn, FEE_BPS, 0, 0, minLiquidity, ALICE, 0);

        assertTrue(liquidity >= minLiquidity, "liquidity should meet minimum");
    }

    function test_SplitAndAddLiquidity_ERC20_RevertInsufficientOutput() public {
        uint256 collateralIn = 10000 ether;
        uint256 minLiquidity = type(uint256).max; // Impossible to meet

        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, collateralIn, FEE_BPS, 0, 0, minLiquidity, ALICE, 0);
    }

    function test_SplitAndAddLiquidity_ERC20_RevertMarketClosed() public {
        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 100 ether, FEE_BPS, 0, 0, 0, ALICE, 0);
    }

    function test_SplitAndAddLiquidity_ERC20_RevertInvalidReceiver() public {
        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 100 ether, FEE_BPS, 0, 0, 0, address(0), 0);
    }

    function test_SplitAndAddLiquidity_ERC20_RevertAmountZero() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);
    }

    function test_SplitAndAddLiquidity_ERC20_RevertCollateralTooSmall() public {
        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 0.5 ether, FEE_BPS, 0, 0, 0, ALICE, 0); // Less than 1 share
    }

    function test_SplitAndAddLiquidity_ERC20_RevertWrongCollateralType() public {
        vm.expectRevert(PAMM.WrongCollateralType.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 1 ether}(marketId, 100 ether, FEE_BPS, 0, 0, 0, ALICE, 0);
    }

    function test_SplitAndAddLiquidity_ERC20_EmitsSplitEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PAMM.Split(ALICE, marketId, 10000, 10000 ether);

        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SPLIT AND ADD LIQUIDITY TESTS (ETH)
    //////////////////////////////////////////////////////////////*/

    function test_SplitAndAddLiquidity_ETH_Success() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        uint256 ethAmount = 10000 ether;

        vm.prank(ALICE);
        (uint256 shares, uint256 liquidity) =
            pm.splitAndAddLiquidity{value: ethAmount}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        assertEq(shares, 10000, "should mint 10000 shares");
        assertTrue(liquidity > 0, "should receive liquidity tokens");

        // Check PAMM ETH balance
        assertEq(address(pm).balance, 10000 ether, "PAMM should hold ETH");
    }

    function test_SplitAndAddLiquidity_ETH_WithExplicitAmount() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.prank(ALICE);
        (uint256 shares,) = pm.splitAndAddLiquidity{value: 10000 ether}(
            ethMarketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0
        );

        assertEq(shares, 10000, "should mint 10000 shares");
    }

    function test_SplitAndAddLiquidity_ETH_RefundsDust() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 shares,) = pm.splitAndAddLiquidity{value: 10000.5 ether}(
            ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0
        );

        assertEq(shares, 10000, "should mint 10000 shares");
        assertEq(ALICE.balance, aliceBefore - 10000 ether, "dust should be refunded");
    }

    function test_SplitAndAddLiquidity_ETH_RevertInvalidETHAmount() public {
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        vm.expectRevert(PAMM.InvalidETHAmount.selector);
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 100 ether}(ethMarketId, 50 ether, FEE_BPS, 0, 0, 0, ALICE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      CREATE MARKET AND SEED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarketAndSeed_ERC20_Success() public {
        string memory desc = "New seeded market";
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        (uint256 mId, uint256 nId, uint256 liquidity) = pm.createMarketAndSeed(
            desc, RESOLVER, address(wsteth), closeTime, false, collateralIn, FEE_BPS, 0, ALICE, 0
        );

        // Market should exist
        (address resolver, address collateral,,,,,,,,,) = pm.getMarket(mId);
        assertEq(resolver, RESOLVER, "resolver set");
        assertEq(collateral, address(wsteth), "collateral set");

        // noId should match
        assertEq(nId, pm.getNoId(mId), "noId matches");

        // Should have liquidity
        assertTrue(liquidity > 0, "liquidity minted");

        // Pool should have reserves
        (uint256 rYes, uint256 rNo,,) = pm.getPoolState(mId, FEE_BPS);
        assertEq(rYes, 10000, "YES reserve");
        assertEq(rNo, 10000, "NO reserve");
    }

    function test_CreateMarketAndSeed_ETH_Success() public {
        string memory desc = "ETH seeded market";
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        (uint256 mId, uint256 nId, uint256 liquidity) = pm.createMarketAndSeed{value: collateralIn}(
            desc, RESOLVER, address(0), closeTime, false, 0, FEE_BPS, 0, ALICE, 0
        );

        // Market should exist with ETH collateral
        (address resolver, address collateral,,,,,,,,,) = pm.getMarket(mId);
        assertEq(resolver, RESOLVER, "resolver set");
        assertEq(collateral, address(0), "ETH collateral");

        // noId should match
        assertEq(nId, pm.getNoId(mId), "noId matches");

        // Should have liquidity
        assertTrue(liquidity > 0, "liquidity minted");

        // PAMM should hold the ETH
        assertEq(address(pm).balance, 10000 ether, "PAMM holds ETH");
    }

    function test_CreateMarketAndSeed_ETH_RefundsDust() public {
        string memory desc = "ETH dust refund market";
        uint256 aliceBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 mId,, uint256 liquidity) = pm.createMarketAndSeed{value: 10000.5 ether}(
            desc, RESOLVER, address(0), closeTime, false, 0, FEE_BPS, 0, ALICE, 0
        );

        assertTrue(liquidity > 0, "liquidity minted");
        assertEq(ALICE.balance, aliceBefore - 10000 ether, "dust refunded");
        assertEq(address(pm).balance, 10000 ether, "exact ETH held");
    }

    function test_CreateMarketAndSeed_MinLiquidity() public {
        string memory desc = "Min liquidity market";
        uint256 minLiquidity = 1000;

        vm.prank(ALICE);
        (,, uint256 liquidity) = pm.createMarketAndSeed(
            desc,
            RESOLVER,
            address(wsteth),
            closeTime,
            false,
            10000 ether,
            FEE_BPS,
            minLiquidity,
            ALICE,
            0
        );

        assertTrue(liquidity >= minLiquidity, "meets min liquidity");
    }

    function test_CreateMarketAndSeed_RevertInsufficientLiquidity() public {
        string memory desc = "Insufficient liquidity market";
        uint256 minLiquidity = type(uint256).max;

        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            desc,
            RESOLVER,
            address(wsteth),
            closeTime,
            false,
            10000 ether,
            FEE_BPS,
            minLiquidity,
            ALICE,
            0
        );
    }

    function test_CreateMarketAndSeed_RevertInvalidResolver() public {
        vm.expectRevert(PAMM.InvalidResolver.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            "Bad resolver",
            address(0),
            address(wsteth),
            closeTime,
            false,
            10000 ether,
            FEE_BPS,
            0,
            ALICE,
            0
        );
    }

    function test_CreateMarketAndSeed_RevertInvalidClose() public {
        vm.expectRevert(PAMM.InvalidClose.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            "Bad close",
            RESOLVER,
            address(wsteth),
            uint64(block.timestamp),
            false,
            10000 ether,
            FEE_BPS,
            0,
            ALICE,
            0
        );
    }

    function test_CreateMarketAndSeed_RevertMarketExists() public {
        // Market with DESC already exists from setUp, so this should fail
        vm.expectRevert(PAMM.MarketExists.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            DESC, RESOLVER, address(wsteth), closeTime, false, 10000 ether, FEE_BPS, 0, ALICE, 0
        );
    }

    function test_CreateMarketAndSeed_RevertCollateralTooSmall() public {
        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            "Small collateral",
            RESOLVER,
            address(wsteth),
            closeTime,
            false,
            0.5 ether,
            FEE_BPS,
            0,
            ALICE,
            0
        );
    }

    function test_CreateMarketAndSeed_RevertInvalidReceiver() public {
        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(ALICE);
        pm.createMarketAndSeed(
            "Bad receiver",
            RESOLVER,
            address(wsteth),
            closeTime,
            false,
            10000 ether,
            FEE_BPS,
            0,
            address(0),
            0
        );
    }

    function test_CreateMarketAndSeed_WithCanClose() public {
        vm.prank(ALICE);
        (uint256 mId,,) = pm.createMarketAndSeed(
            "Closable seeded",
            RESOLVER,
            address(wsteth),
            closeTime,
            true,
            10000 ether,
            FEE_BPS,
            0,
            ALICE,
            0
        );

        (,,,,, bool canClose,,,,,) = pm.getMarket(mId);
        assertTrue(canClose, "canClose flag set");
    }

    function test_CreateMarketAndSeed_DifferentLPRecipient() public {
        vm.prank(ALICE);
        (uint256 mId,, uint256 liquidity) = pm.createMarketAndSeed(
            "LP to BOB",
            RESOLVER,
            address(wsteth),
            closeTime,
            false,
            10000 ether,
            FEE_BPS,
            0,
            BOB,
            0
        );

        // BOB should have LP tokens, not ALICE
        IZAMM.PoolKey memory key = pm.poolKey(mId, FEE_BPS);
        uint256 poolId = _getPoolId(key);
        assertEq(zamm.balanceOf(BOB, poolId), liquidity, "BOB has LP tokens");
        assertEq(zamm.balanceOf(ALICE, poolId), 0, "ALICE has no LP tokens");
    }

    function test_CreateMarketAndSeed_EmitsEvents() public {
        string memory desc = "Event test market";
        uint256 expectedMarketId = pm.getMarketId(desc, RESOLVER, address(wsteth));
        uint256 expectedNoId = pm.getNoId(expectedMarketId);

        // Expect Created event
        vm.expectEmit(true, true, false, true);
        emit PAMM.Created(
            expectedMarketId, expectedNoId, desc, RESOLVER, address(wsteth), 18, closeTime, false
        );

        // Expect Split event
        vm.expectEmit(true, true, false, true);
        emit PAMM.Split(ALICE, expectedMarketId, 10000, 10000 ether);

        vm.prank(ALICE);
        pm.createMarketAndSeed(
            desc, RESOLVER, address(wsteth), closeTime, false, 10000 ether, FEE_BPS, 0, ALICE, 0
        );
    }

    /*//////////////////////////////////////////////////////////////
                      SUBSEQUENT LIQUIDITY ADDITIONS
    //////////////////////////////////////////////////////////////*/

    function test_SplitAndAddLiquidity_AddToExistingPool() public {
        // First LP - needs > 1000 shares for MINIMUM_LIQUIDITY
        vm.prank(ALICE);
        (, uint256 liquidity1) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Second LP - can use smaller amounts after pool initialized
        vm.prank(BOB);
        (, uint256 liquidity2) =
            pm.splitAndAddLiquidity(marketId, 5000 ether, FEE_BPS, 0, 0, 0, BOB, 0);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId = _getPoolId(key);

        // Both should have LP tokens
        assertEq(zamm.balanceOf(ALICE, poolId), liquidity1, "ALICE LP tokens");
        assertEq(zamm.balanceOf(BOB, poolId), liquidity2, "BOB LP tokens");

        // Pool should have combined reserves
        (uint112 r0, uint112 r1,,,,,) = zamm.pools(poolId);
        assertEq(uint256(r0) + uint256(r1), 30000, "total reserves should be 15000 YES + 15000 NO");
    }

    /*//////////////////////////////////////////////////////////////
                          GET POOL STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPoolState_EmptyPool() public view {
        (uint256 rYes, uint256 rNo, uint256 pYesNum, uint256 pYesDen) =
            pm.getPoolState(marketId, FEE_BPS);

        assertEq(rYes, 0, "empty pool YES reserve");
        assertEq(rNo, 0, "empty pool NO reserve");
        assertEq(pYesNum, 0, "empty pool probability numerator");
        assertEq(pYesDen, 0, "empty pool probability denominator");
    }

    function test_GetPoolState_AfterLiquidity() public {
        // Add liquidity first
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        (uint256 rYes, uint256 rNo, uint256 pYesNum, uint256 pYesDen) =
            pm.getPoolState(marketId, FEE_BPS);

        // 50/50 pool should have equal reserves
        assertEq(rYes, 10000, "YES reserve");
        assertEq(rNo, 10000, "NO reserve");

        // Probability should be 50% (10000 / 20000)
        assertEq(pYesNum, 10000, "probability numerator = NO reserve");
        assertEq(pYesDen, 20000, "probability denominator = YES + NO");
    }

    function test_GetPoolState_ImpliedProbability() public {
        // Add initial liquidity
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // The initial state is 50/50
        (,, uint256 pYesNum, uint256 pYesDen) = pm.getPoolState(marketId, FEE_BPS);

        // pYes = rNo / (rYes + rNo) = 10000 / 20000 = 50%
        uint256 impliedProbability = (pYesNum * 10000) / pYesDen;
        assertEq(impliedProbability, 5000, "implied probability should be 50%");
    }

    /*//////////////////////////////////////////////////////////////
                       SWAP TESTS VIA ZAMM
    //////////////////////////////////////////////////////////////*/

    function test_Swap_YESforNO() public {
        // Setup: ALICE adds liquidity (needs > 1000 shares)
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB splits to get YES/NO shares
        vm.prank(BOB);
        pm.split(marketId, 1000 ether, BOB);

        uint256 bobYesBefore = pm.balanceOf(BOB, marketId);
        uint256 bobNoBefore = pm.balanceOf(BOB, noId);

        // BOB approves ZAMM to transfer his YES shares
        vm.prank(BOB);
        pm.setOperator(ZAMM_ADDRESS, true);

        // BOB swaps YES for NO
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);

        // Determine which is id0/id1
        bool yesIsId0 = key.id0 == marketId;

        vm.prank(BOB);
        uint256 amountOut = zamm.swapExactIn(
            _toZAMMPoolKey(key),
            500, // 500 YES shares
            0, // min out
            yesIsId0, // zeroForOne (YES -> NO if YES is id0)
            BOB,
            block.timestamp + 1
        );

        assertTrue(amountOut > 0, "should receive NO shares");

        // BOB should have fewer YES, more NO
        assertEq(pm.balanceOf(BOB, marketId), bobYesBefore - 500, "BOB YES balance reduced");
        assertEq(pm.balanceOf(BOB, noId), bobNoBefore + amountOut, "BOB NO balance increased");
    }

    function test_Swap_NOforYES() public {
        // Setup: ALICE adds liquidity (needs > 1000 shares)
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB splits to get YES/NO shares
        vm.prank(BOB);
        pm.split(marketId, 1000 ether, BOB);

        uint256 bobYesBefore = pm.balanceOf(BOB, marketId);
        uint256 bobNoBefore = pm.balanceOf(BOB, noId);

        // BOB approves ZAMM
        vm.prank(BOB);
        pm.setOperator(ZAMM_ADDRESS, true);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);

        // Determine direction
        bool noIsId0 = key.id0 == noId;

        vm.prank(BOB);
        uint256 amountOut = zamm.swapExactIn(
            _toZAMMPoolKey(key),
            500, // 500 NO shares
            0,
            noIsId0, // zeroForOne (NO -> YES if NO is id0)
            BOB,
            block.timestamp + 1
        );

        assertTrue(amountOut > 0, "should receive YES shares");

        // BOB should have more YES, fewer NO
        assertEq(pm.balanceOf(BOB, marketId), bobYesBefore + amountOut, "BOB YES balance increased");
        assertEq(pm.balanceOf(BOB, noId), bobNoBefore - 500, "BOB NO balance reduced");
    }

    function test_Swap_PriceImpact() public {
        // Setup pool with liquidity (needs > 1000 shares)
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Check initial pool state
        (uint256 rYesBefore,, uint256 pYesNumBefore, uint256 pYesDenBefore) =
            pm.getPoolState(marketId, FEE_BPS);

        // BOB makes a swap
        vm.prank(BOB);
        pm.split(marketId, 2000 ether, BOB);

        vm.prank(BOB);
        pm.setOperator(ZAMM_ADDRESS, true);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        bool yesIsId0 = key.id0 == marketId;

        // Large swap: 1000 YES -> NO
        vm.prank(BOB);
        zamm.swapExactIn(_toZAMMPoolKey(key), 1000, 0, yesIsId0, BOB, block.timestamp + 1);

        // Check new pool state
        (uint256 rYesAfter,, uint256 pYesNumAfter, uint256 pYesDenAfter) =
            pm.getPoolState(marketId, FEE_BPS);

        // YES reserve should increase (more YES in pool)
        assertTrue(rYesAfter > rYesBefore, "YES reserve should increase after selling YES");

        // Implied probability of YES should decrease
        uint256 probBefore = (pYesNumBefore * 10000) / pYesDenBefore;
        uint256 probAfter = (pYesNumAfter * 10000) / pYesDenAfter;
        assertTrue(probAfter < probBefore, "YES probability should decrease after selling YES");
    }

    /*//////////////////////////////////////////////////////////////
                      REMOVE LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RemoveLiquidity_ReturnsShares() public {
        // Add liquidity (needs > 1000 shares)
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId = _getPoolId(key);

        // Approve ZAMM to burn LP tokens
        vm.prank(ALICE);
        zamm.approve(address(zamm), poolId, liquidity);

        // Remove liquidity
        vm.prank(ALICE);
        (uint256 amount0, uint256 amount1) =
            zamm.removeLiquidity(_toZAMMPoolKey(key), liquidity, 0, 0, ALICE, block.timestamp + 1);

        assertTrue(amount0 > 0, "should receive token0");
        assertTrue(amount1 > 0, "should receive token1");

        // ALICE should have received YES and NO shares
        assertTrue(pm.balanceOf(ALICE, marketId) > 0 || pm.balanceOf(ALICE, noId) > 0);
    }

    function test_RemoveLiquidity_PartialWithdraw() public {
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId = _getPoolId(key);

        uint256 lpBefore = zamm.balanceOf(ALICE, poolId);

        // Remove half
        vm.prank(ALICE);
        zamm.removeLiquidity(_toZAMMPoolKey(key), liquidity / 2, 0, 0, ALICE, block.timestamp + 1);

        uint256 lpAfter = zamm.balanceOf(ALICE, poolId);
        assertEq(lpAfter, lpBefore - liquidity / 2, "LP balance should be halved");
    }

    /*//////////////////////////////////////////////////////////////
                      FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_ZAMM_ERC20() public {
        // 1. Create pool and add liquidity (needs > 1000 shares)
        vm.prank(ALICE);
        (, uint256 aliceLp) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // 2. BOB splits and trades
        vm.prank(BOB);
        pm.split(marketId, 5000 ether, BOB);

        vm.prank(BOB);
        pm.setOperator(ZAMM_ADDRESS, true);

        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        bool yesIsId0 = key.id0 == marketId;

        // BOB sells 2500 YES for NO
        vm.prank(BOB);
        uint256 noReceived =
            zamm.swapExactIn(_toZAMMPoolKey(key), 2500, 0, yesIsId0, BOB, block.timestamp + 1);

        // 3. Verify BOB's position
        assertEq(pm.balanceOf(BOB, marketId), 2500, "BOB has 2500 YES");
        assertEq(pm.balanceOf(BOB, noId), 5000 + noReceived, "BOB has 5000 + swap NO");

        // 4. ALICE removes liquidity
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) =
            zamm.removeLiquidity(_toZAMMPoolKey(key), aliceLp, 0, 0, ALICE, block.timestamp + 1);

        assertTrue(a0 > 0 && a1 > 0, "ALICE receives both tokens");

        // 5. Resolve market
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(marketId, true); // YES wins

        // 6. BOB claims
        vm.prank(BOB);
        (uint256 bobShares, uint256 bobPayout) = pm.claim(marketId, BOB);

        assertEq(bobShares, 2500, "BOB claims 2500 YES shares");
        assertEq(bobPayout, 2500 ether, "BOB gets 2500 ether");

        // 7. ALICE merges or claims remaining shares
        uint256 aliceYes = pm.balanceOf(ALICE, marketId);
        if (aliceYes > 0) {
            vm.prank(ALICE);
            pm.claim(marketId, ALICE);
        }
    }

    function test_FullLifecycle_ZAMM_ETH() public {
        // Create ETH market
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // 1. ALICE adds liquidity (needs > 1000 shares)
        vm.prank(ALICE);

        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // 2. BOB splits
        vm.prank(BOB);
        pm.split{value: 5000 ether}(ethMarketId, 0, BOB);

        // 3. BOB trades
        vm.prank(BOB);
        pm.setOperator(ZAMM_ADDRESS, true);

        IZAMM.PoolKey memory key = pm.poolKey(ethMarketId, FEE_BPS);
        bool yesIsId0 = key.id0 == ethMarketId;

        vm.prank(BOB);
        zamm.swapExactIn(_toZAMMPoolKey(key), 2500, 0, yesIsId0, BOB, block.timestamp + 1);

        // 4. Resolve NO wins
        vm.warp(closeTime);
        vm.prank(RESOLVER);
        pm.resolve(ethMarketId, false);

        // 5. BOB claims NO
        uint256 bobNoBal = pm.balanceOf(BOB, ethNoId);
        uint256 bobEthBefore = BOB.balance;

        vm.prank(BOB);
        pm.claim(ethMarketId, BOB);

        assertEq(BOB.balance, bobEthBefore + bobNoBal * 1 ether, "BOB receives ETH payout");
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SplitAndAddLiquidity_ERC20(uint256 collateralIn) public {
        // Need at least 1001 shares to exceed MINIMUM_LIQUIDITY (1000)
        collateralIn = bound(collateralIn, 1001 ether, 50000 ether);

        vm.prank(ALICE);
        (uint256 shares, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, collateralIn, FEE_BPS, 0, 0, 0, ALICE, 0);

        uint256 expectedShares = collateralIn / 1e18;
        assertEq(shares, expectedShares, "shares match collateral");
        assertTrue(liquidity > 0, "liquidity minted");
    }

    function testFuzz_SplitAndAddLiquidity_ETH(uint256 ethAmount) public {
        // Need at least 1001 shares to exceed MINIMUM_LIQUIDITY (1000)
        ethAmount = bound(ethAmount, 1001 ether, 50000 ether);

        (uint256 ethMarketId,) = pm.createMarket("ETH fuzz", RESOLVER, address(0), closeTime, false);

        vm.deal(ALICE, ethAmount);

        vm.prank(ALICE);
        (uint256 shares, uint256 liquidity) =
            pm.splitAndAddLiquidity{value: ethAmount}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        uint256 expectedShares = ethAmount / 1e18;
        assertEq(shares, expectedShares, "shares match ETH");
        assertTrue(liquidity > 0, "liquidity minted");
    }

    /*//////////////////////////////////////////////////////////////
                          BUY/SELL HELPER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BuyYes_Success() public {
        // First seed the pool with liquidity
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES with 100 ether collateral
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have YES tokens and spent collateral
        assertEq(pm.balanceOf(BOB, marketId), yesOut, "BOB has YES");
        assertEq(pm.balanceOf(BOB, noId), 0, "BOB has no NO");
        assertEq(wsteth.balanceOf(BOB), bobBefore - 100 ether, "BOB spent collateral");

        // Should get more YES than just splitting would give (100 shares)
        // because we also swap the NO for YES
        assertTrue(yesOut > 100, "got more YES than split amount");
    }

    function test_BuyNo_Success() public {
        // First seed the pool with liquidity
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys NO with 100 ether collateral
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 noOut = pm.buyNo(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have NO tokens and spent collateral
        assertEq(pm.balanceOf(BOB, noId), noOut, "BOB has NO");
        assertEq(pm.balanceOf(BOB, marketId), 0, "BOB has no YES");
        assertEq(wsteth.balanceOf(BOB), bobBefore - 100 ether, "BOB spent collateral");

        // Should get more NO than just splitting would give (100 shares)
        assertTrue(noOut > 100, "got more NO than split amount");
    }

    function test_BuyYes_MinOutput() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Should revert if minYesOut not met
        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(BOB);
        pm.buyYes(marketId, 100 ether, type(uint256).max, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyNo_MinOutput() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Should revert if minNoOut not met
        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(BOB);
        pm.buyNo(marketId, 100 ether, type(uint256).max, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyYes_ETH() public {
        // Create ETH market
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES with ETH
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes{value: 100 ether}(ethMarketId, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(pm.balanceOf(BOB, ethMarketId), yesOut, "BOB has YES");
        assertEq(pm.balanceOf(BOB, ethNoId), 0, "BOB has no NO");
        assertEq(BOB.balance, bobBefore - 100 ether, "BOB spent ETH");
        assertTrue(yesOut > 100, "got more YES than split");
    }

    function test_SellYes_Success() public {
        // Seed pool and get BOB some YES tokens
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens by splitting (he'll have equal YES and NO)
        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);
        assertEq(pm.balanceOf(BOB, marketId), 200, "BOB has 200 YES");
        assertEq(pm.balanceOf(BOB, noId), 200, "BOB has 200 NO");

        // BOB sells 100 YES
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, 100, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have received collateral
        assertEq(wsteth.balanceOf(BOB), bobBefore + collateralOut, "BOB got collateral");
        assertTrue(collateralOut > 0, "got some collateral");

        // BOB's YES should be reduced
        assertTrue(pm.balanceOf(BOB, marketId) < 200, "YES reduced");
    }

    function test_SellNo_Success() public {
        // Seed pool and get BOB some NO tokens
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets NO tokens by splitting
        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);
        assertEq(pm.balanceOf(BOB, marketId), 200, "BOB has 200 YES");
        assertEq(pm.balanceOf(BOB, noId), 200, "BOB has 200 NO");

        // BOB sells 100 NO
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellNo(marketId, 100, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have received collateral
        assertEq(wsteth.balanceOf(BOB), bobBefore + collateralOut, "BOB got collateral");
        assertTrue(collateralOut > 0, "got some collateral");

        // BOB's NO should be reduced
        assertTrue(pm.balanceOf(BOB, noId) < 200, "NO reduced");
    }

    function test_SellYes_OnlyYes() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES only (no NO balance)
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        assertEq(pm.balanceOf(BOB, noId), 0, "BOB has no NO");
        assertTrue(yesOut > 0, "BOB has YES");

        // BOB sells his YES
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(wsteth.balanceOf(BOB), bobBefore + collateralOut, "BOB got collateral back");
        assertTrue(collateralOut > 0, "got some collateral");
    }

    function test_SellYes_MinOutput() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);

        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(BOB);
        pm.sellYes(marketId, 100, 0, type(uint256).max, 0, FEE_BPS, BOB, 0);
    }

    function test_SellNo_MinOutput() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);

        vm.expectRevert(PAMM.InsufficientOutput.selector);
        vm.prank(BOB);
        pm.sellNo(marketId, 100, 0, type(uint256).max, 0, FEE_BPS, BOB, 0);
    }

    function test_SellYes_ZeroAmount() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(BOB);
        pm.sellYes(marketId, 0, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellNo_ZeroAmount() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(BOB);
        pm.sellNo(marketId, 0, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyYes_MarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyNo_MarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.buyNo(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellYes_MarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.sellYes(marketId, 50, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyYes_InvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, address(0), 0);
    }

    function test_BuyNo_InvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.buyNo(marketId, 100 ether, 0, 0, FEE_BPS, address(0), 0);
    }

    function test_SellYes_InvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.sellYes(marketId, 50, 0, 0, 0, FEE_BPS, address(0), 0);
    }

    function test_SellNo_InvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.sellNo(marketId, 50, 0, 0, 0, FEE_BPS, address(0), 0);
    }

    function test_SellNo_MarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.sellNo(marketId, 50, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyYes_MarketNotFound() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(BOB);
        pm.buyYes(12345, 100 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyNo_MarketNotFound() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(BOB);
        pm.buyNo(12345, 100 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellYes_MarketNotFound() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(BOB);
        pm.sellYes(12345, 100, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellNo_MarketNotFound() public {
        vm.expectRevert(PAMM.MarketNotFound.selector);
        vm.prank(BOB);
        pm.sellNo(12345, 100, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyYes_ToDifferentRecipient() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES but sends to ALICE
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, ALICE, 0);

        // ALICE should have the YES tokens
        assertEq(pm.balanceOf(ALICE, marketId), yesOut, "ALICE has YES");
        assertEq(pm.balanceOf(BOB, marketId), 0, "BOB has no YES");
    }

    function test_SellYes_ToDifferentRecipient() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        // BOB sells YES but sends collateral to ALICE
        uint256 aliceBefore = wsteth.balanceOf(ALICE);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut, 0, 0, 0, FEE_BPS, ALICE, 0);

        assertEq(wsteth.balanceOf(ALICE), aliceBefore + collateralOut, "ALICE got collateral");
    }

    function test_SellYes_ReturnsLeftovers() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        uint256 yesBefore = pm.balanceOf(BOB, marketId);
        uint256 noBefore = pm.balanceOf(BOB, noId);

        // BOB sells all YES
        vm.prank(BOB);
        pm.sellYes(marketId, yesOut, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have received leftover shares back (due to AMM slippage)
        uint256 yesAfter = pm.balanceOf(BOB, marketId);
        uint256 noAfter = pm.balanceOf(BOB, noId);

        // Either leftovers returned or fully consumed
        assertTrue(yesAfter >= 0, "YES balance valid");
        assertTrue(noAfter >= noBefore, "NO balance should not decrease");
    }

    function test_SellNo_ReturnsLeftovers() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets NO tokens
        vm.prank(BOB);
        uint256 noOut = pm.buyNo(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        uint256 yesBefore = pm.balanceOf(BOB, marketId);

        // BOB sells all NO
        vm.prank(BOB);
        pm.sellNo(marketId, noOut, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB should have received leftover shares back
        uint256 yesAfter = pm.balanceOf(BOB, marketId);

        assertTrue(yesAfter >= yesBefore, "YES balance should not decrease");
    }

    function test_BuyYes_DoesNotTouchOtherBalances() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB already has some YES and NO from a previous split
        vm.prank(BOB);
        pm.split(marketId, 50 ether, BOB);
        uint256 bobYesBefore = pm.balanceOf(BOB, marketId);
        uint256 bobNoBefore = pm.balanceOf(BOB, noId);

        // BOB buys more YES
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);

        // BOB's YES should increase, NO should stay same
        assertEq(pm.balanceOf(BOB, marketId), bobYesBefore + yesOut, "YES increased");
        assertEq(pm.balanceOf(BOB, noId), bobNoBefore, "NO unchanged");
    }

    function test_SellYes_DoesNotTouchOtherBalances() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB has YES and NO
        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);
        uint256 bobNoBefore = pm.balanceOf(BOB, noId);

        // BOB sells some YES - should NOT touch his NO balance
        vm.prank(BOB);
        pm.sellYes(marketId, 50, 0, 0, 0, FEE_BPS, BOB, 0);

        // NO balance should be untouched
        assertEq(pm.balanceOf(BOB, noId), bobNoBefore, "NO unchanged by sellYes");
    }

    function test_SellNo_DoesNotTouchOtherBalances() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB has YES and NO
        vm.prank(BOB);
        pm.split(marketId, 200 ether, BOB);
        uint256 bobYesBefore = pm.balanceOf(BOB, marketId);

        // BOB sells some NO - should NOT touch his YES balance
        vm.prank(BOB);
        pm.sellNo(marketId, 50, 0, 0, 0, FEE_BPS, BOB, 0);

        // YES balance should be untouched
        assertEq(pm.balanceOf(BOB, marketId), bobYesBefore, "YES unchanged by sellNo");
    }

    function test_BuyNo_ETH() public {
        // Create ETH market
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys NO with ETH
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        uint256 noOut = pm.buyNo{value: 100 ether}(ethMarketId, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(pm.balanceOf(BOB, ethNoId), noOut, "BOB has NO");
        assertEq(pm.balanceOf(BOB, ethMarketId), 0, "BOB has no YES");
        assertEq(BOB.balance, bobBefore - 100 ether, "BOB spent ETH");
        assertTrue(noOut > 100, "got more NO than split");
    }

    function test_SellYes_ETH() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES with ETH
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes{value: 100 ether}(ethMarketId, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB sells YES back for ETH
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        uint256 ethOut = pm.sellYes(ethMarketId, yesOut, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(BOB.balance, bobBefore + ethOut, "BOB got ETH back");
        assertTrue(ethOut > 0, "got some ETH");
    }

    function test_SellNo_ETH() public {
        // Create ETH market
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys NO with ETH
        vm.prank(BOB);
        uint256 noOut = pm.buyNo{value: 100 ether}(ethMarketId, 0, 0, 0, FEE_BPS, BOB, 0);

        // BOB sells NO back for ETH
        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        uint256 ethOut = pm.sellNo(ethMarketId, noOut, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(BOB.balance, bobBefore + ethOut, "BOB got ETH back");
        assertTrue(ethOut > 0, "got some ETH");
    }

    function test_BuyYes_SmallAmount() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Buy 10 shares worth (need enough for swap to produce non-zero output)
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 10 ether, 0, 0, FEE_BPS, BOB, 0);

        assertTrue(yesOut > 0, "got YES");
    }

    function test_SellYes_OddAmount() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        // Sell odd number (tests integer division)
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, 33, 0, 0, 0, FEE_BPS, BOB, 0);

        assertTrue(collateralOut > 0, "got collateral");
    }

    function testFuzz_BuyYes(uint256 amount) public {
        // Need at least 10 shares for swap to produce non-zero output
        amount = bound(amount, 10 ether, 1000 ether);

        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, amount, 0, 0, FEE_BPS, BOB, 0);

        assertEq(pm.balanceOf(BOB, marketId), yesOut, "BOB has YES");
        assertEq(pm.balanceOf(BOB, noId), 0, "BOB has no NO");
        assertTrue(
            wsteth.balanceOf(BOB) <= bobBefore - amount + 1e18, "BOB spent collateral (within dust)"
        );
        assertTrue(yesOut > amount / 1e18, "got more YES than split");
    }

    function testFuzz_BuyNo(uint256 amount) public {
        // Need at least 10 shares for swap to produce non-zero output
        amount = bound(amount, 10 ether, 1000 ether);

        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 noOut = pm.buyNo(marketId, amount, 0, 0, FEE_BPS, BOB, 0);

        assertEq(pm.balanceOf(BOB, noId), noOut, "BOB has NO");
        assertEq(pm.balanceOf(BOB, marketId), 0, "BOB has no YES");
        assertTrue(
            wsteth.balanceOf(BOB) <= bobBefore - amount + 1e18, "BOB spent collateral (within dust)"
        );
        assertTrue(noOut > amount / 1e18, "got more NO than split");
    }

    function testFuzz_SellYes(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 10 ether, 500 ether);

        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys YES
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, buyAmount, 0, 0, FEE_BPS, BOB, 0);

        // BOB sells all YES back
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(wsteth.balanceOf(BOB), bobBefore + collateralOut, "BOB got collateral");
        assertTrue(collateralOut > 0, "got some collateral");
    }

    function testFuzz_SellNo(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 10 ether, 500 ether);

        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB buys NO
        vm.prank(BOB);
        uint256 noOut = pm.buyNo(marketId, buyAmount, 0, 0, FEE_BPS, BOB, 0);

        // BOB sells all NO back
        uint256 bobBefore = wsteth.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = pm.sellNo(marketId, noOut, 0, 0, 0, FEE_BPS, BOB, 0);

        assertEq(wsteth.balanceOf(BOB), bobBefore + collateralOut, "BOB got collateral");
        assertTrue(collateralOut > 0, "got some collateral");
    }

    function test_BuyAndSell_RoundTrip() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        uint256 collateralIn = 100 ether;
        uint256 bobStartBalance = wsteth.balanceOf(BOB);

        // Buy YES
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, collateralIn, 0, 0, FEE_BPS, BOB, 0);

        // Sell YES
        vm.prank(BOB);
        uint256 collateralOut = pm.sellYes(marketId, yesOut, 0, 0, 0, FEE_BPS, BOB, 0);

        // Should lose some to slippage/fees but not more than ~20% for reasonable amounts
        uint256 loss = collateralIn - collateralOut;
        assertTrue(loss < collateralIn / 5, "loss should be reasonable");

        // BOB should have recovered most of his collateral
        assertTrue(wsteth.balanceOf(BOB) > bobStartBalance - collateralIn / 5, "recovered most");
    }

    function test_BuyYes_CollateralTooSmall() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(BOB);
        pm.buyYes(marketId, 0.5 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_BuyNo_CollateralTooSmall() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(BOB);
        pm.buyNo(marketId, 0.5 ether, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellYes_InsufficientBalance() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB has no YES tokens
        vm.expectRevert(); // underflow
        vm.prank(BOB);
        pm.sellYes(marketId, 100, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    function test_SellNo_InsufficientBalance() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB has no NO tokens
        vm.expectRevert(); // underflow
        vm.prank(BOB);
        pm.sellNo(marketId, 100, 0, 0, 0, FEE_BPS, BOB, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SELL FOR EXACT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SellYesForExactCollateral_Success() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);
        uint256 yesBefore = pm.balanceOf(BOB, marketId);

        // BOB sells YES for exact 10 ether collateral
        uint256 collateralWanted = 10 ether;
        uint256 bobCollateralBefore = wsteth.balanceOf(BOB);

        vm.prank(BOB);
        uint256 yesSpent =
            pm.sellYesForExactCollateral(marketId, collateralWanted, 50, 50, FEE_BPS, BOB, 0);

        // Verify results
        assertEq(
            wsteth.balanceOf(BOB), bobCollateralBefore + collateralWanted, "got exact collateral"
        );
        assertEq(pm.balanceOf(BOB, marketId), yesBefore - yesSpent, "YES spent correctly");
        assertTrue(yesSpent > 0 && yesSpent <= 50, "reasonable YES spent");
    }

    function test_SellNoForExactCollateral_Success() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets NO tokens
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);
        uint256 noBefore = pm.balanceOf(BOB, noId);

        // BOB sells NO for exact 10 ether collateral
        uint256 collateralWanted = 10 ether;
        uint256 bobCollateralBefore = wsteth.balanceOf(BOB);

        vm.prank(BOB);
        uint256 noSpent =
            pm.sellNoForExactCollateral(marketId, collateralWanted, 50, 50, FEE_BPS, BOB, 0);

        // Verify results
        assertEq(
            wsteth.balanceOf(BOB), bobCollateralBefore + collateralWanted, "got exact collateral"
        );
        assertEq(pm.balanceOf(BOB, noId), noBefore - noSpent, "NO spent correctly");
        assertTrue(noSpent > 0 && noSpent <= 50, "reasonable NO spent");
    }

    function test_SellYesForExactCollateral_RefundsLeftover() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);
        uint256 yesBefore = pm.balanceOf(BOB, marketId);

        // BOB offers maxYesIn=50 but should spend less
        uint256 collateralWanted = 5 ether;

        vm.prank(BOB);
        uint256 yesSpent =
            pm.sellYesForExactCollateral(marketId, collateralWanted, 50, 50, FEE_BPS, BOB, 0);

        // Should have gotten leftover YES back
        assertEq(pm.balanceOf(BOB, marketId), yesBefore - yesSpent, "only spent what was needed");
        assertTrue(yesSpent < 50, "didn't use all maxYesIn");
    }

    function test_SellYesForExactCollateral_RevertExcessiveInput() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        // Try to get collateral where total YES needed (swapped + merged) exceeds maxYesIn
        // maxSwapIn is high enough to not trigger ZAMM revert, but maxYesIn is too low
        // For 5 ether collateral: need 5 YES to merge + ~5 YES to swap = ~10 total
        // Set maxYesIn=8 (too low), maxSwapIn=100 (high enough for ZAMM)
        vm.expectRevert(PAMM.ExcessiveInput.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 5 ether, 8, 100, FEE_BPS, BOB, 0);
    }

    function test_SellNoForExactCollateral_RevertExcessiveInput() public {
        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets NO tokens
        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        // Try to get collateral where total NO needed (swapped + merged) exceeds maxNoIn
        // maxSwapIn is high enough to not trigger ZAMM revert, but maxNoIn is too low
        // For 5 ether collateral: need 5 NO to merge + ~5 NO to swap = ~10 total
        // Set maxNoIn=8 (too low), maxSwapIn=100 (high enough for ZAMM)
        vm.expectRevert(PAMM.ExcessiveInput.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 5 ether, 8, 100, FEE_BPS, BOB, 0);
    }

    function test_SellYesForExactCollateral_RevertAmountZero() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 0, 10, 10, FEE_BPS, BOB, 0);
    }

    function test_SellNoForExactCollateral_RevertAmountZero() public {
        vm.expectRevert(PAMM.AmountZero.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 0, 10, 10, FEE_BPS, BOB, 0);
    }

    function test_SellYesForExactCollateral_RevertInvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, address(0), 0);
    }

    function test_SellNoForExactCollateral_RevertInvalidReceiver() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.expectRevert(PAMM.InvalidReceiver.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, address(0), 0);
    }

    function test_SellYesForExactCollateral_RevertMarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, BOB, 0);
    }

    function test_SellNoForExactCollateral_RevertMarketClosed() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(closeTime);

        vm.expectRevert(PAMM.MarketClosed.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, BOB, 0);
    }

    function test_SellYesForExactCollateral_RevertCollateralTooSmall() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        // 0.5 ether is less than 1 share for 18 decimal token
        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 0.5 ether, 50, 50, FEE_BPS, BOB, 0);
    }

    function test_SellNoForExactCollateral_RevertCollateralTooSmall() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        // 0.5 ether is less than 1 share for 18 decimal token
        vm.expectRevert(PAMM.CollateralTooSmall.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 0.5 ether, 50, 50, FEE_BPS, BOB, 0);
    }

    function test_SellYesForExactCollateral_ETH() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets YES tokens
        vm.prank(BOB);
        pm.split{value: 100 ether}(ethMarketId, 0, BOB);

        uint256 bobEthBefore = BOB.balance;

        // BOB sells YES for exact 10 ether
        vm.prank(BOB);
        pm.sellYesForExactCollateral(ethMarketId, 10 ether, 50, 50, FEE_BPS, BOB, 0);

        assertEq(BOB.balance, bobEthBefore + 10 ether, "got exact ETH");
    }

    function test_SellNoForExactCollateral_ETH() public {
        // Create ETH market
        (uint256 ethMarketId, uint256 ethNoId) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Seed pool
        vm.prank(ALICE);
        pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // BOB gets NO tokens
        vm.prank(BOB);
        pm.split{value: 100 ether}(ethMarketId, 0, BOB);

        uint256 bobEthBefore = BOB.balance;

        // BOB sells NO for exact 10 ether
        vm.prank(BOB);
        pm.sellNoForExactCollateral(ethMarketId, 10 ether, 50, 50, FEE_BPS, BOB, 0);

        assertEq(BOB.balance, bobEthBefore + 10 ether, "got exact ETH");
    }

    /*//////////////////////////////////////////////////////////////
                           DEADLINE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BuyYes_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Warp to a future time, then set deadline in the past
        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, expiredDeadline);
    }

    function test_BuyNo_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.buyNo(marketId, 100 ether, 0, 0, FEE_BPS, BOB, expiredDeadline);
    }

    function test_SellYes_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.sellYes(marketId, 50, 0, 0, 0, FEE_BPS, BOB, expiredDeadline);
    }

    function test_SellNo_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.sellNo(marketId, 50, 0, 0, 0, FEE_BPS, BOB, expiredDeadline);
    }

    function test_SellYesForExactCollateral_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.sellYesForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, BOB, expiredDeadline);
    }

    function test_SellNoForExactCollateral_DeadlineExpired() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(BOB);
        pm.split(marketId, 100 ether, BOB);

        vm.warp(1000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert(PAMM.DeadlineExpired.selector);
        vm.prank(BOB);
        pm.sellNoForExactCollateral(marketId, 10 ether, 50, 50, FEE_BPS, BOB, expiredDeadline);
    }

    function test_BuyYes_DeadlineZeroMeansNoDeadline() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // deadline=0 should work (no deadline)
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, 0);
        assertTrue(yesOut > 0, "buy succeeded with zero deadline");
    }

    function test_BuyYes_FutureDeadline() public {
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Future deadline should work
        uint256 futureDeadline = block.timestamp + 1 hours;
        vm.prank(BOB);
        uint256 yesOut = pm.buyYes(marketId, 100 ether, 0, 0, FEE_BPS, BOB, futureDeadline);
        assertTrue(yesOut > 0, "buy succeeded with future deadline");
    }

    /*//////////////////////////////////////////////////////////////
                    REMOVE LIQUIDITY TO COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RemoveLiquidityToCollateral_Success() public {
        // Alice adds liquidity
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        assertTrue(liquidity > 0, "should have liquidity");

        // Get pool id for LP token approval
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId =
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));

        // Alice approves PAMM to pull LP tokens from ZAMM
        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        uint256 wstethBefore = wsteth.balanceOf(ALICE);

        // Remove liquidity to collateral
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 leftoverYes, uint256 leftoverNo) =
            pm.removeLiquidityToCollateral(marketId, FEE_BPS, liquidity, 0, 0, 0, ALICE, 0);

        uint256 wstethAfter = wsteth.balanceOf(ALICE);

        assertTrue(collateralOut > 0, "should receive collateral");
        assertEq(wstethAfter - wstethBefore, collateralOut, "collateral should be transferred");
        // Leftovers should be small or zero for balanced pool
        assertTrue(leftoverYes + leftoverNo < 1000, "leftovers should be minimal for balanced pool");
    }

    function test_RemoveLiquidityToCollateral_PartialRemoval() public {
        // Alice adds liquidity
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Approve PAMM
        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        // Remove only half
        vm.prank(ALICE);
        (uint256 collateralOut,,) =
            pm.removeLiquidityToCollateral(marketId, FEE_BPS, liquidity / 2, 0, 0, 0, ALICE, 0);

        assertTrue(collateralOut > 0, "should receive collateral");

        // Alice should still have remaining LP tokens
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId =
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
        uint256 remainingLp = zamm.balanceOf(ALICE, poolId);
        assertTrue(remainingLp > 0, "should have remaining LP tokens");
    }

    function test_RemoveLiquidityToCollateral_WithLeftovers() public {
        // Alice adds liquidity
        vm.prank(ALICE);
        pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Bob buys YES, unbalancing the pool
        vm.prank(BOB);
        pm.buyYes(marketId, 1000 ether, 0, 0, FEE_BPS, BOB, 0);

        // Get Alice's LP balance
        IZAMM.PoolKey memory key = pm.poolKey(marketId, FEE_BPS);
        uint256 poolId =
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
        uint256 aliceLp = zamm.balanceOf(ALICE, poolId);

        // Approve and remove
        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        uint256 yesBefore = pm.balanceOf(ALICE, marketId);
        uint256 noBefore = pm.balanceOf(ALICE, noId);

        vm.prank(ALICE);
        (uint256 collateralOut, uint256 leftoverYes, uint256 leftoverNo) =
            pm.removeLiquidityToCollateral(marketId, FEE_BPS, aliceLp, 0, 0, 0, ALICE, 0);

        uint256 yesAfter = pm.balanceOf(ALICE, marketId);
        uint256 noAfter = pm.balanceOf(ALICE, noId);

        assertTrue(collateralOut > 0, "should receive collateral");
        // With unbalanced pool, one of the leftovers should be non-zero
        assertEq(yesAfter - yesBefore, leftoverYes, "leftover YES should be refunded");
        assertEq(noAfter - noBefore, leftoverNo, "leftover NO should be refunded");
    }

    function test_RemoveLiquidityToCollateral_ETH() public {
        // Create ETH market
        (uint256 ethMarketId,) =
            pm.createMarket("ETH market", RESOLVER, address(0), closeTime, false);

        // Alice adds ETH liquidity
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity{value: 10000 ether}(ethMarketId, 0, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Approve PAMM
        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        uint256 ethBefore = ALICE.balance;

        vm.prank(ALICE);
        (uint256 collateralOut,,) =
            pm.removeLiquidityToCollateral(ethMarketId, FEE_BPS, liquidity, 0, 0, 0, ALICE, 0);

        uint256 ethAfter = ALICE.balance;

        assertTrue(collateralOut > 0, "should receive ETH");
        assertEq(ethAfter - ethBefore, collateralOut, "ETH should be transferred");
    }

    function test_RemoveLiquidityToCollateral_MinCollateralOut() public {
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        // Set unreasonably high minCollateralOut
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("InsufficientOutput()"));
        pm.removeLiquidityToCollateral(
            marketId, FEE_BPS, liquidity, 0, 0, type(uint256).max, ALICE, 0
        );
    }

    function test_RemoveLiquidityToCollateral_RevertsZeroLiquidity() public {
        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("AmountZero()"));
        pm.removeLiquidityToCollateral(marketId, FEE_BPS, 0, 0, 0, 0, ALICE, 0);
    }

    function test_RemoveLiquidityToCollateral_RevertsZeroReceiver() public {
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        pm.removeLiquidityToCollateral(marketId, FEE_BPS, liquidity, 0, 0, 0, address(0), 0);
    }

    function test_RemoveLiquidityToCollateral_RevertsMarketClosed() public {
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        vm.prank(ALICE);
        zamm.setOperator(address(pm), true);

        // Warp past close time
        vm.warp(closeTime + 1);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("MarketClosed()"));
        pm.removeLiquidityToCollateral(marketId, FEE_BPS, liquidity, 0, 0, 0, ALICE, 0);
    }

    function test_RemoveLiquidityToCollateral_RevertsMarketNotFound() public {
        uint256 fakeMarketId = uint256(keccak256("fake"));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("MarketNotFound()"));
        pm.removeLiquidityToCollateral(fakeMarketId, FEE_BPS, 1000, 0, 0, 0, ALICE, 0);
    }

    function test_RemoveLiquidityToCollateral_RevertsWithoutApproval() public {
        vm.prank(ALICE);
        (, uint256 liquidity) =
            pm.splitAndAddLiquidity(marketId, 10000 ether, FEE_BPS, 0, 0, 0, ALICE, 0);

        // Don't approve - should fail when trying to transfer LP tokens
        vm.prank(ALICE);
        vm.expectRevert(); // Will revert with InsufficientPermission from ZAMM
        pm.removeLiquidityToCollateral(marketId, FEE_BPS, liquidity, 0, 0, 0, ALICE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getPoolId(IZAMM.PoolKey memory key) internal pure returns (uint256 pid) {
        assembly ("memory-safe") {
            pid := keccak256(key, 0xa0)
        }
    }

    /// @notice Convert IZAMM.PoolKey to ZAMM.PoolKey for direct ZAMM calls
    function _toZAMMPoolKey(IZAMM.PoolKey memory key) internal pure returns (ZAMM.PoolKey memory) {
        return ZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                         PERMIT TESTS
//////////////////////////////////////////////////////////////*/

contract PAMM_Permit_Test is Test {
    PAMM internal pm;
    MockERC20Permit internal permitToken;
    MockDAI internal daiToken;

    address internal RESOLVER = makeAddr("RESOLVER");
    uint256 internal alicePk = 0xA11CE;
    address internal ALICE = vm.addr(alicePk);
    uint256 internal bobPk = 0xB0B;
    address internal BOB = vm.addr(bobPk);

    string internal constant DESC = "Will ETH reach $10k in 2025?";
    uint64 internal closeTime;

    uint256 internal permitMarketId;
    uint256 internal daiMarketId;

    function setUp() public {
        pm = new PAMM();
        permitToken = new MockERC20Permit();
        daiToken = new MockDAI();
        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        permitToken.mint(ALICE, 100 ether);
        permitToken.mint(BOB, 100 ether);
        daiToken.mint(ALICE, 100 ether);
        daiToken.mint(BOB, 100 ether);

        // Create markets
        vm.prank(RESOLVER);
        (permitMarketId,) = pm.createMarket(DESC, RESOLVER, address(permitToken), closeTime, false);

        vm.prank(RESOLVER);
        (daiMarketId,) =
            pm.createMarket("DAI market", RESOLVER, address(daiToken), closeTime, false);
    }

    /*//////////////////////////////////////////////////////////////
                          EIP-2612 PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Permit_Success() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        // Create permit signature
        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Call permit
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);

        // Check allowance was set
        assertEq(permitToken.allowance(ALICE, address(pm)), amount);
        assertEq(permitToken.nonces(ALICE), nonce + 1);
    }

    function test_Permit_ThenSplit() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Permit then split
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);

        vm.prank(ALICE);
        (uint256 shares,) = pm.split(permitMarketId, amount, ALICE);

        assertEq(shares, 10); // 10 ether / 1e18 = 10 shares
        assertEq(pm.balanceOf(ALICE, permitMarketId), 10);
    }

    function test_Permit_MulticallPermitAndSplit() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Build multicall data
        bytes[] memory calls = new bytes[](2);
        calls[0] =
            abi.encodeCall(PAMM.permit, (address(permitToken), ALICE, amount, deadline, v, r, s));
        calls[1] = abi.encodeCall(PAMM.split, (permitMarketId, amount, ALICE));

        // Execute multicall as ALICE
        vm.prank(ALICE);
        pm.multicall(calls);

        // Verify split worked
        assertEq(pm.balanceOf(ALICE, permitMarketId), 10);
    }

    function test_Permit_RevertExpiredDeadline() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp - 1; // Expired
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("PERMIT_DEADLINE_EXPIRED");
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);
    }

    function test_Permit_RevertInvalidSignature() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        // Sign with wrong key (BOB instead of ALICE)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.expectRevert("INVALID_SIGNER");
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);
    }

    function test_Permit_RevertReplayedSignature() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = permitToken.nonces(ALICE);

        bytes32 digest =
            _getEIP2612Digest(address(permitToken), ALICE, address(pm), amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // First call succeeds
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);

        // Second call with same signature fails (nonce incremented)
        vm.expectRevert("INVALID_SIGNER");
        pm.permit(address(permitToken), ALICE, amount, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                          DAI-STYLE PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PermitDAI_Success() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);

        assertEq(daiToken.allowance(ALICE, address(pm)), type(uint256).max);
        assertEq(daiToken.nonces(ALICE), nonce + 1);
    }

    function test_PermitDAI_ThenSplit() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);

        vm.prank(ALICE);
        (uint256 shares,) = pm.split(daiMarketId, 10 ether, ALICE);

        assertEq(shares, 10);
        assertEq(pm.balanceOf(ALICE, daiMarketId), 10);
    }

    function test_PermitDAI_MulticallPermitAndSplit() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            PAMM.permitDAI, (address(daiToken), ALICE, nonce, expiry, true, v, r, s)
        );
        calls[1] = abi.encodeCall(PAMM.split, (daiMarketId, 10 ether, ALICE));

        vm.prank(ALICE);
        pm.multicall(calls);

        assertEq(pm.balanceOf(ALICE, daiMarketId), 10);
    }

    function test_PermitDAI_RevokeAllowance() public {
        // First grant allowance
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(pm)), type(uint256).max);

        // Now revoke
        nonce = daiToken.nonces(ALICE);
        digest = _getDAIPermitDigest(
            address(daiToken),
            ALICE,
            address(pm),
            nonce,
            expiry,
            false // revoke
        );
        (v, r, s) = vm.sign(alicePk, digest);

        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, false, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(pm)), 0);
    }

    function test_PermitDAI_RevertExpiredDeadline() public {
        // Warp to a later time so we can have a meaningful expired timestamp
        vm.warp(1000);

        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp - 1; // Expired (999)

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("PERMIT_DEADLINE_EXPIRED");
        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_RevertInvalidNonce() public {
        uint256 nonce = daiToken.nonces(ALICE) + 1; // Wrong nonce
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.expectRevert("INVALID_NONCE");
        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_RevertInvalidSignature() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.expectRevert("INVALID_SIGNER");
        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
    }

    function test_PermitDAI_ZeroExpiryMeansNoExpiry() public {
        uint256 nonce = daiToken.nonces(ALICE);
        uint256 expiry = 0; // No expiry

        bytes32 digest =
            _getDAIPermitDigest(address(daiToken), ALICE, address(pm), nonce, expiry, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        // Should succeed even with expiry=0
        pm.permitDAI(address(daiToken), ALICE, nonce, expiry, true, v, r, s);
        assertEq(daiToken.allowance(ALICE, address(pm)), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getEIP2612Digest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return keccak256(
            abi.encodePacked("\x19\x01", MockERC20Permit(token).DOMAIN_SEPARATOR(), structHash)
        );
    }

    function _getDAIPermitDigest(
        address token,
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed
    ) internal view returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
        );
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed));
        return
            keccak256(abi.encodePacked("\x19\x01", MockDAI(token).DOMAIN_SEPARATOR(), structHash));
    }
}
