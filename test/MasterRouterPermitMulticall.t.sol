// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouter.sol";

interface IPAMMExtended is IPAMM {
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev Mock ERC20 with EIP-2612 permit support
contract MockERC20WithPermit {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

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
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
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
        require(deadline >= block.timestamp, "EXPIRED");

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
        require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNATURE");

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}

/// @dev Mock ERC20 with DAI-style permit
contract MockDAI {
    string public name = "Mock DAI";
    string public symbol = "DAI";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
    );

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

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
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
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
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed))
            )
        );

        require(holder == ecrecover(digest, v, r, s), "INVALID_SIGNATURE");
        require(expiry == 0 || block.timestamp <= expiry, "EXPIRED");
        require(nonce == nonces[holder]++, "INVALID_NONCE");

        allowance[holder][spender] = allowed ? type(uint256).max : 0;
        emit Approval(holder, spender, allowed ? type(uint256).max : 0);
    }
}

/// @notice Comprehensive tests for permit + multicall + router actions
contract MasterRouterPermitMulticallTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    MockERC20WithPermit public token;
    MockDAI public dai;

    uint256 public aliceKey = 0xA11CE;
    uint256 public bobKey = 0xB0B;
    address public alice;
    address public bob;
    address public taker = address(0x999);

    uint256 public tokenMarketId;
    uint256 public tokenNoId;
    uint256 public daiMarketId;
    uint256 public daiNoId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = new MasterRouter();
        token = new MockERC20WithPermit();
        dai = new MockDAI();

        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);

        // Mint tokens to users
        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
        dai.mint(alice, 1000 ether);
        dai.mint(bob, 1000 ether);

        vm.deal(taker, 100 ether);

        // Create markets with different collaterals
        (tokenMarketId, tokenNoId) = pamm.createMarket(
            "Token Market", address(this), address(token), uint64(block.timestamp + 30 days), false
        );

        (daiMarketId, daiNoId) = pamm.createMarket(
            "DAI Market", address(this), address(dai), uint64(block.timestamp + 30 days), false
        );
    }

    /*//////////////////////////////////////////////////////////////
                      ERC-2612 PERMIT + MULTICALL
    //////////////////////////////////////////////////////////////*/

    function test_erc2612Permit_mintAndPool() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Create permit signature
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(aliceKey, address(token), alice, address(router), amount, deadline);

        // Encode multicall: permit + mintAndPool
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.mintAndPool.selector, tokenMarketId, amount, true, 5000, alice
        );

        // Execute multicall as alice
        vm.prank(alice);
        router.multicall(calls);

        // Verify alice got YES shares
        assertEq(pamm.balanceOf(alice, tokenMarketId), amount, "Alice should have YES shares");

        // Verify pool was created
        bytes32 poolId = router.getPoolId(tokenMarketId, false, 5000);
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, amount, "Pool should have shares");
    }

    function test_erc2612Permit_fillFromPool() public {
        // Setup: Alice creates pool
        vm.startPrank(alice);
        token.approve(address(router), 10 ether);
        bytes32 poolId = router.mintAndPool(tokenMarketId, 10 ether, true, 5000, alice);
        vm.stopPrank();

        // Bob uses permit + multicall to fill from pool
        uint256 amount = 5 ether;
        uint256 collateralNeeded = (amount * 5000) / 10000; // 2.5 ether at 50% price
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(bobKey, address(token), bob, address(router), collateralNeeded, deadline);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), bob, collateralNeeded, deadline, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.fillFromPool.selector, tokenMarketId, false, 5000, amount, bob
        );

        vm.prank(bob);
        router.multicall(calls);

        // Verify bob got NO shares
        assertEq(pamm.balanceOf(bob, tokenNoId), amount, "Bob should have NO shares");

        // Verify pool was filled (totalShares shows remaining, not filled)
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, 5 ether, "Pool should have 5 shares remaining");
    }

    function test_erc2612Permit_multipleActions() public {
        uint256 amount = 20 ether;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(aliceKey, address(token), alice, address(router), amount, deadline);

        // Multicall: permit + mintAndPool twice (different prices)
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.mintAndPool.selector, tokenMarketId, 10 ether, true, 4000, alice
        );
        calls[2] = abi.encodeWithSelector(
            router.mintAndPool.selector, tokenMarketId, 10 ether, true, 6000, alice
        );

        vm.prank(alice);
        router.multicall(calls);

        // Verify both pools created
        bytes32 poolId1 = router.getPoolId(tokenMarketId, false, 4000);
        bytes32 poolId2 = router.getPoolId(tokenMarketId, false, 6000);

        (uint256 shares1,,,) = router.pools(poolId1);
        (uint256 shares2,,,) = router.pools(poolId2);

        assertEq(shares1, 10 ether, "Pool 1 should have shares");
        assertEq(shares2, 10 ether, "Pool 2 should have shares");
        assertEq(pamm.balanceOf(alice, tokenMarketId), 20 ether, "Alice should have 20 YES");
    }

    /*//////////////////////////////////////////////////////////////
                      DAI-STYLE PERMIT + MULTICALL
    //////////////////////////////////////////////////////////////*/

    function test_daiPermit_mintAndPool() public {
        uint256 amount = 10 ether;
        uint256 nonce = dai.nonces(alice);
        uint256 expiry = block.timestamp + 1 hours;

        // Create DAI-style permit signature
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermitDAI(aliceKey, address(dai), alice, address(router), nonce, expiry, true);

        // Encode multicall: permitDAI + mintAndPool
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.permitDAI.selector, address(dai), alice, nonce, expiry, true, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.mintAndPool.selector, daiMarketId, amount, true, 5000, alice
        );

        vm.prank(alice);
        router.multicall(calls);

        // Verify
        assertEq(pamm.balanceOf(alice, daiMarketId), amount, "Alice should have YES shares");
        assertEq(
            dai.allowance(alice, address(router)), type(uint256).max, "Should have max allowance"
        );
    }

    function test_daiPermit_fillFromPool() public {
        // Setup: Alice creates pool with DAI
        vm.startPrank(alice);
        dai.approve(address(router), 10 ether);
        router.mintAndPool(daiMarketId, 10 ether, true, 5000, alice);
        vm.stopPrank();

        // Bob uses DAI permit + multicall
        uint256 amount = 5 ether;
        uint256 collateralNeeded = (amount * 5000) / 10000;
        uint256 nonce = dai.nonces(bob);
        uint256 expiry = 0; // No expiry

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermitDAI(bobKey, address(dai), bob, address(router), nonce, expiry, true);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.permitDAI.selector, address(dai), bob, nonce, expiry, true, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.fillFromPool.selector, daiMarketId, false, 5000, amount, bob
        );

        vm.prank(bob);
        router.multicall(calls);

        assertEq(pamm.balanceOf(bob, daiNoId), amount, "Bob should have NO shares");
    }

    /*//////////////////////////////////////////////////////////////
                      COMPLEX WORKFLOWS
    //////////////////////////////////////////////////////////////*/

    function test_fullWorkflow_permitPoolFillClaim() public {
        // Step 1: Alice permits and pools
        uint256 aliceAmount = 10 ether;
        uint256 deadline1 = block.timestamp + 1 hours;

        (uint8 v1, bytes32 r1, bytes32 s1) =
            _signPermit(aliceKey, address(token), alice, address(router), aliceAmount, deadline1);

        bytes[] memory calls1 = new bytes[](2);
        calls1[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, aliceAmount, deadline1, v1, r1, s1
        );
        calls1[1] = abi.encodeWithSelector(
            router.mintAndPool.selector, tokenMarketId, aliceAmount, true, 5000, alice
        );

        vm.prank(alice);
        router.multicall(calls1);

        // Step 2: Bob permits and fills
        uint256 bobAmount = 5 ether;
        uint256 bobCollateral = (bobAmount * 5000) / 10000;
        uint256 deadline2 = block.timestamp + 1 hours;

        (uint8 v2, bytes32 r2, bytes32 s2) =
            _signPermit(bobKey, address(token), bob, address(router), bobCollateral, deadline2);

        bytes[] memory calls2 = new bytes[](2);
        calls2[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), bob, bobCollateral, deadline2, v2, r2, s2
        );
        calls2[1] = abi.encodeWithSelector(
            router.fillFromPool.selector, tokenMarketId, false, 5000, bobAmount, bob
        );

        vm.prank(bob);
        router.multicall(calls2);

        // Step 3: Alice claims (no permit needed)
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(tokenMarketId, false, 5000, alice);

        assertEq(claimed, bobCollateral, "Alice should receive Bob's collateral");
        assertEq(token.balanceOf(alice), 990 ether + bobCollateral, "Alice balance updated");
    }

    function test_withdraw_afterPermitAndPool() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(aliceKey, address(token), alice, address(router), amount, deadline);

        // Permit + pool + withdraw in one multicall
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.mintAndPool.selector, tokenMarketId, amount, true, 5000, alice
        );
        calls[2] = abi.encodeWithSelector(
            router.withdrawFromPool.selector,
            tokenMarketId,
            false,
            5000,
            0,
            alice // 0 = withdraw all
        );

        vm.prank(alice);
        router.multicall(calls);

        // Verify: Alice should have YES from pool, and NO from withdrawal
        assertEq(pamm.balanceOf(alice, tokenMarketId), amount, "Alice has YES");
        assertEq(pamm.balanceOf(alice, tokenNoId), amount, "Alice has NO (withdrew all)");
    }

    /*//////////////////////////////////////////////////////////////
                          ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_expiredPermit() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp - 1; // Expired

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(aliceKey, address(token), alice, address(router), amount, deadline);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );

        vm.prank(alice);
        vm.expectRevert("EXPIRED");
        router.multicall(calls);
    }

    function test_revert_invalidSignature() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(bobKey, address(token), alice, address(router), amount, deadline);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );

        vm.prank(alice);
        vm.expectRevert("INVALID_SIGNATURE");
        router.multicall(calls);
    }

    function test_revert_multicallFailsOnSecondCall() public {
        uint256 amount = 10 ether;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(aliceKey, address(token), alice, address(router), amount, deadline);

        // Second call will fail (invalid price)
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            router.permit.selector, address(token), alice, amount, deadline, v, r, s
        );
        calls[1] = abi.encodeWithSelector(
            router.mintAndPool.selector,
            tokenMarketId,
            amount,
            true,
            10000,
            alice // Invalid price
        );

        vm.prank(alice);
        vm.expectRevert(); // Should revert with ERR_VALIDATION
        router.multicall(calls);

        // Verify permit was not applied (reverted)
        assertEq(token.allowance(alice, address(router)), 0, "Allowance should be 0 after revert");
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _signPermit(
        uint256 privateKey,
        address tokenAddress,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        MockERC20WithPermit permitToken = MockERC20WithPermit(tokenAddress);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permitToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        permitToken.PERMIT_TYPEHASH(),
                        owner,
                        spender,
                        value,
                        permitToken.nonces(owner),
                        deadline
                    )
                )
            )
        );

        (v, r, s) = vm.sign(privateKey, digest);
    }

    function _signPermitDAI(
        uint256 privateKey,
        address tokenAddress,
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        MockDAI daiToken = MockDAI(tokenAddress);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                daiToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(daiToken.PERMIT_TYPEHASH(), holder, spender, nonce, expiry, allowed)
                )
            )
        );

        (v, r, s) = vm.sign(privateKey, digest);
    }
}
