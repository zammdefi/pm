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

/// @title Mock PMHookRouter for testing MasterRouter integration
/// @notice Simulates PMHookRouter's vault and trading functionality
contract MockPMHookRouter {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    // Track vault deposits per market/side
    mapping(uint256 => mapping(bool => uint256)) public vaultBalances;
    mapping(uint256 => mapping(bool => mapping(address => uint256))) public userVaultShares;

    receive() external payable {}

    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 /*deadline*/
    )
        external
        returns (uint256 vaultShares)
    {
        // Transfer shares from caller to this contract
        uint256 tokenId = isYes ? marketId : _getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), tokenId, shares);

        // Mint 1:1 vault shares
        vaultShares = shares;
        vaultBalances[marketId][isYes] += shares;
        userVaultShares[marketId][isYes][receiver] += vaultShares;

        return vaultShares;
    }

    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256,
        /*minSharesOut*/
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) {
        // Check if we have vault liquidity on the opposite side
        bool sellSide = !buyYes;
        uint256 available = vaultBalances[marketId][sellSide];

        if (available > 0) {
            // OTC from vault - simplified: 1:1 exchange
            sharesOut = collateralIn > available ? available : collateralIn;
            vaultBalances[marketId][sellSide] -= sharesOut;

            // Transfer shares to buyer
            uint256 tokenId = buyYes ? marketId : _getNoId(marketId);

            // Mint new shares for the buyer (simplified - in reality would use vault shares)
            PAMM.split{value: sharesOut}(marketId, sharesOut, address(this));
            PAMM.transfer(to, tokenId, sharesOut);

            source = bytes4(0x6f746300); // "otc\0"

            // Refund excess
            if (msg.value > sharesOut) {
                payable(msg.sender).transfer(msg.value - sharesOut);
            }
        } else {
            // No vault liquidity - mint new shares
            PAMM.split{value: collateralIn}(marketId, collateralIn, address(this));

            uint256 tokenId = buyYes ? marketId : _getNoId(marketId);
            PAMM.transfer(to, tokenId, collateralIn);

            // Deposit opposite side to vault
            uint256 oppositeId = buyYes ? _getNoId(marketId) : marketId;
            vaultBalances[marketId][!buyYes] += collateralIn;
            vaultSharesMinted = collateralIn;

            sharesOut = collateralIn;
            source = bytes4(0x6d696e74); // "mint"
        }
    }

    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256,
        /*minCollateralOut*/
        address to,
        uint256 /*deadline*/
    ) external returns (uint256 collateralOut, bytes4 source) {
        // Transfer shares from seller
        uint256 tokenId = sellYes ? marketId : _getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        // Check if we have vault liquidity on opposite side to merge
        bool buySide = !sellYes;
        uint256 available = vaultBalances[marketId][buySide];

        if (available >= sharesIn) {
            // Can merge with vault shares
            vaultBalances[marketId][buySide] -= sharesIn;
            collateralOut = sharesIn; // Simplified 1:1

            // Send collateral to seller
            payable(to).transfer(collateralOut);
            source = bytes4(0x6f746300); // "otc\0"
        } else {
            // Deposit to vault instead
            vaultBalances[marketId][sellYes] += sharesIn;
            collateralOut = 0;
            source = bytes4(0x7661756c); // "vaul"
        }
    }

    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }
}

/// @title MasterRouter PMHookRouter Integration Tests
/// @notice Tests MasterRouter integration with PMHookRouter (mocked)
contract MasterRouterPMHookIntegrationTest is Test {
    MasterRouter public router;
    MockPMHookRouter public mockPMHookRouter;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0xa11ce);
    address public bob = address(0xb0b);
    address public carol = address(0xca201);
    address public dave = address(0xda4e);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        // Fork mainnet where PAMM is deployed
        vm.createSelectFork(vm.rpcUrl("main"));

        // Deploy mock PMHookRouter
        mockPMHookRouter = new MockPMHookRouter();

        // Deploy the mock at the expected address using vm.etch
        address expectedAddr = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
        vm.etch(expectedAddr, address(mockPMHookRouter).code);

        // Also need to copy storage - give the mock some ETH
        vm.deal(expectedAddr, 1000 ether);

        // Set PAMM operator approval for the mock
        vm.prank(expectedAddr);
        pamm.setOperator(expectedAddr, true);

        // Deploy MasterRouter (will use the mock at expectedAddr)
        router = new MasterRouter();

        // Create market directly via PAMM
        (marketId, noId) = pamm.createMarket(
            "Test Market - MasterRouter Integration",
            address(this),
            address(0), // ETH
            uint64(block.timestamp + 30 days),
            false
        );

        // Fund test accounts
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
    }

    function _getNoId(uint256 _marketId) internal pure returns (uint256 _noId) {
        assembly {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, _marketId)
            _noId := keccak256(0x00, 0x2a)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    POOLED ORDERBOOK TESTS (no PMHookRouter needed)
    //////////////////////////////////////////////////////////////*/

    function test_mintAndPool_basic() public {
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 4000, alice);

        // Alice should have YES tokens
        assertEq(pamm.balanceOf(alice, marketId), 10 ether, "Alice should have YES");

        // Pool should have NO tokens
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, 10 ether, "Pool should have 10 NO shares");
    }

    function test_fillFromPool_basic() public {
        // Alice pools NO at 40%
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 4000, alice);

        // Bob fills from pool
        vm.prank(bob);
        (uint256 bought, uint256 paid) =
            router.fillFromPool{value: 4 ether}(marketId, false, 4000, 10 ether, bob);

        assertEq(bought, 10 ether, "Should buy 10 NO shares");
        assertEq(paid, 4 ether, "Should pay 4 ETH (10 * 0.40)");
        assertEq(pamm.balanceOf(bob, noId), 10 ether, "Bob should have NO tokens");
    }

    function test_claimProceeds_basic() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob fills
        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, bob);

        // Alice claims
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 5000, alice);

        assertEq(claimed, 5 ether, "Alice should claim 5 ETH");
        assertEq(alice.balance - aliceBalBefore, 5 ether, "Alice balance should increase");
    }

    function test_withdrawFromPool_basic() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob fills half
        vm.prank(bob);
        router.fillFromPool{value: 2.5 ether}(marketId, false, 5000, 5 ether, bob);

        // Alice claims first (required before withdraw)
        vm.prank(alice);
        router.claimProceeds(marketId, false, 5000, alice);

        // Alice withdraws remaining
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromPool(marketId, false, 5000, 0, alice);

        assertEq(withdrawn, 5 ether, "Alice should withdraw 5 NO shares");
        assertEq(pamm.balanceOf(alice, noId), 5 ether, "Alice should have NO tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-USER POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multiUser_poolAndFill() public {
        // Alice and Bob both pool at same price
        vm.prank(alice);
        router.mintAndPool{value: 6 ether}(marketId, 6 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 4 ether}(marketId, 4 ether, true, 5000, bob);

        // Carol fills everything
        vm.prank(carol);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, carol);

        // Both should be able to claim proportionally
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);

        // Alice had 60%, Bob had 40%
        assertEq(aliceClaimed, 3 ether, "Alice should get 60% = 3 ETH");
        assertEq(bobClaimed, 2 ether, "Bob should get 40% = 2 ETH");
    }

    function test_multiUser_partialFillAndWithdraw() public {
        // Alice pools
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        // Bob pools
        vm.prank(bob);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, bob);

        // Carol fills 10 (half the pool)
        vm.prank(carol);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, carol);

        // Alice claims her share (2.5 ETH = 50% of 5 ETH)
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(aliceClaimed, 2.5 ether, "Alice claims 2.5 ETH");

        // Alice withdraws remaining shares
        vm.prank(alice);
        uint256 aliceWithdrawn = router.withdrawFromPool(marketId, false, 5000, 0, alice);
        assertEq(aliceWithdrawn, 5 ether, "Alice withdraws 5 NO shares");

        // Bob can still claim his share
        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);
        assertEq(bobClaimed, 2.5 ether, "Bob claims 2.5 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE TIER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_multiplePriceTiers() public {
        // Alice pools at 40%
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 4000, alice);

        // Bob pools at 60%
        vm.prank(bob);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 6000, bob);

        // Carol buys from cheaper tier first
        vm.prank(carol);
        (uint256 bought1,) =
            router.fillFromPool{value: 2 ether}(marketId, false, 4000, 5 ether, carol);
        assertEq(bought1, 5 ether, "Should buy all 5 shares at 40%");

        // Carol buys from more expensive tier
        vm.prank(carol);
        (uint256 bought2,) =
            router.fillFromPool{value: 3 ether}(marketId, false, 6000, 5 ether, carol);
        assertEq(bought2, 5 ether, "Should buy all 5 shares at 60%");

        // Verify claims
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 4000, alice);
        assertEq(aliceClaimed, 2 ether, "Alice gets 2 ETH from 40% tier");

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 6000, bob);
        assertEq(bobClaimed, 3 ether, "Bob gets 3 ETH from 60% tier");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_fillMoreThanAvailable() public {
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, alice);

        vm.prank(bob);
        vm.expectRevert();
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, bob);
    }

    function test_revert_withdrawMoreThanOwned() public {
        vm.prank(alice);
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 5000, alice);

        vm.prank(bob);
        vm.expectRevert();
        router.withdrawFromPool(marketId, false, 5000, 1 ether, bob);
    }

    function test_revert_invalidPrice() public {
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 0, alice);

        vm.prank(alice);
        vm.expectRevert();
        router.mintAndPool{value: 5 ether}(marketId, 5 ether, true, 10000, alice);
    }

    /*//////////////////////////////////////////////////////////////
                    GAS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function testGas_mintAndPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 1 ether}(marketId, 1 ether, true, 5000, alice);
    }

    function testGas_fillFromPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, bob);
    }

    function testGas_claimProceeds() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(bob);
        router.fillFromPool{value: 5 ether}(marketId, false, 5000, 10 ether, bob);

        vm.prank(alice);
        router.claimProceeds(marketId, false, 5000, alice);
    }

    function testGas_withdrawFromPool() public {
        vm.prank(alice);
        router.mintAndPool{value: 10 ether}(marketId, 10 ether, true, 5000, alice);

        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 5 ether, alice);
    }
}
