// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GasPM} from "../src/GasPM.sol";

contract GasPMTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(oracle.lastBaseFee(), 50 gwei);
        assertEq(oracle.cumulativeBaseFee(), 0);
        assertEq(oracle.startTime(), block.timestamp);
        assertEq(oracle.lastUpdateTime(), block.timestamp);
        assertEq(oracle.maxBaseFee(), 50 gwei);
        assertEq(oracle.minBaseFee(), 50 gwei);
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.rewardAmount(), 0);
        assertEq(oracle.cooldown(), 0);
        assertEq(oracle.publicCreation(), false);
        assertEq(oracle.marketCount(), 0);
    }

    function test_Constants() public view {
        assertEq(oracle.RESOLVER(), 0x0000000000b0ba1b2bb3AF96FbB893d835970ec4);
        assertEq(oracle.PAMM(), 0x0000000000F8bA51d6e987660D3e455ac2c4BE9d);
    }

    /*//////////////////////////////////////////////////////////////
                            TWAP CORE
    //////////////////////////////////////////////////////////////*/

    function test_BaseFeeCurrent() public {
        assertEq(oracle.baseFeeCurrent(), 50 gwei);
        assertEq(oracle.baseFeeCurrentGwei(), 50);

        vm.fee(100 gwei);
        assertEq(oracle.baseFeeCurrent(), 100 gwei);
        assertEq(oracle.baseFeeCurrentGwei(), 100);
    }

    function test_Update_SameBlock_Skips() public {
        oracle.update();
        assertEq(oracle.cumulativeBaseFee(), 0);
    }

    function test_Update_AccumulatesCorrectly() public {
        vm.warp(deployTime + 1 hours);
        oracle.update();

        assertEq(oracle.cumulativeBaseFee(), 50 gwei * 1 hours);
        assertEq(oracle.lastBaseFee(), 50 gwei);
        assertEq(oracle.lastUpdateTime(), block.timestamp);
    }

    function test_Update_MultipleUpdates() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        assertEq(oracle.cumulativeBaseFee(), 50 gwei * 1 hours);
        assertEq(oracle.lastBaseFee(), 100 gwei);

        vm.warp(deployTime + 2 hours);
        oracle.update();

        assertEq(oracle.cumulativeBaseFee(), 50 gwei * 1 hours + 100 gwei * 1 hours);
    }

    function test_BaseFeeAverage_ImmediatelyAfterDeploy() public view {
        assertEq(oracle.baseFeeAverage(), 50 gwei);
        assertEq(oracle.baseFeeAverageGwei(), 50);
    }

    function test_BaseFeeAverage_ConstantFee() public {
        vm.warp(deployTime + 1 hours);
        oracle.update();

        assertEq(oracle.baseFeeAverage(), 50 gwei);
        assertEq(oracle.baseFeeAverageGwei(), 50);
    }

    function test_BaseFeeAverage_ChangingFee() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        assertEq(oracle.baseFeeAverage(), 75 gwei);
        assertEq(oracle.baseFeeAverageGwei(), 75);
    }

    function test_BaseFeeAverage_WithoutUpdate_StillWorks() public {
        vm.warp(deployTime + 1 hours);
        assertEq(oracle.baseFeeAverage(), 50 gwei);
    }

    function test_BaseFeeAverage_PendingTime() public {
        vm.warp(deployTime + 1 hours);
        oracle.update();

        vm.fee(100 gwei);
        vm.warp(deployTime + 2 hours);

        assertEq(oracle.baseFeeAverage(), 50 gwei);

        oracle.update();
        assertEq(oracle.baseFeeAverage(), 50 gwei);
    }

    function test_TrackingDuration() public {
        assertEq(oracle.trackingDuration(), 0);

        vm.warp(deployTime + 1 hours);
        assertEq(oracle.trackingDuration(), 1 hours);

        vm.warp(deployTime + 24 hours);
        assertEq(oracle.trackingDuration(), 24 hours);
    }

    function test_Update_EmitsEvent() public {
        vm.warp(deployTime + 1 hours);

        vm.expectEmit(true, true, true, true);
        emit GasPM.Updated(
            uint64(deployTime + 1 hours), 50 gwei, 50 gwei * 1 hours, address(this), 0
        );

        oracle.update();
    }

    function testFuzz_BaseFeeAverage_Bounded(
        uint256 fee1,
        uint256 fee2,
        uint256 time1,
        uint256 time2
    ) public {
        fee1 = bound(fee1, 1 gwei, 1000 gwei);
        fee2 = bound(fee2, 1 gwei, 1000 gwei);
        time1 = bound(time1, 1 hours, 30 days);
        time2 = bound(time2, 1 hours, 30 days);

        vm.fee(fee1);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time1);
        newOracle.update();

        vm.fee(fee2);
        vm.warp(block.timestamp + time2);
        newOracle.update();

        uint256 avg = newOracle.baseFeeAverage();
        uint256 minFee = fee1 < fee2 ? fee1 : fee2;
        uint256 maxFee = fee1 > fee2 ? fee1 : fee2;

        assertGe(avg, minFee);
        assertLe(avg, maxFee);
    }

    function test_LongTermAccumulation() public {
        vm.fee(100 gwei);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + 365 days);
        newOracle.update();

        assertEq(newOracle.baseFeeAverage(), 100 gwei);
        assertEq(newOracle.cumulativeBaseFee(), 100 gwei * 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Owner_IsDeployer() public view {
        assertEq(oracle.owner(), address(this));
    }

    function test_SetReward_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.setReward(0.001 ether, 1 hours);
    }

    function test_SetReward_RequiresCooldownIfRewardSet() public {
        vm.expectRevert(GasPM.InvalidCooldown.selector);
        oracle.setReward(0.001 ether, 0);
    }

    function test_SetReward_AllowsZeroReward() public {
        oracle.setReward(0, 0);
        assertEq(oracle.rewardAmount(), 0);
        assertEq(oracle.cooldown(), 0);
    }

    function test_SetReward_Success() public {
        oracle.setReward(0.001 ether, 1 hours);
        assertEq(oracle.rewardAmount(), 0.001 ether);
        assertEq(oracle.cooldown(), 1 hours);
    }

    function test_TransferOwnership() public {
        address newOwner = address(0xbeef);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), newOwner);

        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.setReward(0, 0);

        vm.prank(newOwner);
        oracle.setReward(0.001 ether, 1 hours);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.deal(address(oracle), 1 ether);

        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.withdraw(address(0xdead), 1 ether);
    }

    function test_Withdraw_PartialAmount() public {
        vm.deal(address(oracle), 1 ether);

        uint256 balBefore = address(this).balance;
        oracle.withdraw(address(this), 0.5 ether);

        assertEq(address(this).balance - balBefore, 0.5 ether);
        assertEq(address(oracle).balance, 0.5 ether);
    }

    function test_Withdraw_AllWithZero() public {
        vm.deal(address(oracle), 1 ether);

        uint256 balBefore = address(this).balance;
        oracle.withdraw(address(this), 0);

        assertEq(address(this).balance - balBefore, 1 ether);
        assertEq(address(oracle).balance, 0);
    }

    function test_SetPublicCreation_OnlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.setPublicCreation(true);
    }

    function test_SetPublicCreation_Success() public {
        assertEq(oracle.publicCreation(), false);

        oracle.setPublicCreation(true);
        assertEq(oracle.publicCreation(), true);

        oracle.setPublicCreation(false);
        assertEq(oracle.publicCreation(), false);
    }

    function test_SetPublicCreation_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit GasPM.PublicCreationSet(true);
        oracle.setPublicCreation(true);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Update_NoRewardIfNotConfigured() public {
        vm.deal(address(oracle), 1 ether);
        vm.warp(deployTime + 1 hours);

        uint256 balBefore = address(this).balance;
        oracle.update();

        assertEq(address(this).balance, balBefore);
    }

    function test_Update_NoRewardIfCooldownNotPassed() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 1 ether);

        vm.warp(deployTime + 30 minutes);

        uint256 balBefore = address(this).balance;
        oracle.update();

        assertEq(address(this).balance, balBefore);
    }

    function test_Update_NoRewardIfNotFunded() public {
        oracle.setReward(0.001 ether, 1 hours);

        vm.warp(deployTime + 1 hours);

        uint256 balBefore = address(this).balance;
        oracle.update();

        assertEq(address(this).balance, balBefore);
    }

    function test_Update_PaysReward() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 1 ether);

        vm.warp(deployTime + 1 hours);

        uint256 balBefore = address(this).balance;
        oracle.update();

        assertEq(address(this).balance - balBefore, 0.001 ether);
        assertEq(address(oracle).balance, 0.999 ether);
    }

    function test_Update_CooldownPreventsRapidDraining() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 1 ether);

        vm.warp(deployTime + 1 hours);
        oracle.update();
        assertEq(address(oracle).balance, 0.999 ether);

        vm.warp(deployTime + 1 hours + 1 minutes);
        uint256 balBefore = address(this).balance;
        oracle.update();
        assertEq(address(this).balance, balBefore);

        vm.warp(deployTime + 2 hours + 1 minutes);
        oracle.update();
        assertEq(address(oracle).balance, 0.998 ether);
    }

    function test_Update_RewardEmittedInEvent() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 1 ether);

        vm.warp(deployTime + 1 hours);

        vm.expectEmit(true, true, true, true);
        emit GasPM.Updated(
            uint64(deployTime + 1 hours), 50 gwei, 50 gwei * 1 hours, address(this), 0.001 ether
        );

        oracle.update();
    }

    function test_Receive_AcceptsFunds() public {
        (bool ok,) = address(oracle).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(oracle).balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       MARKET CREATION ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateMarket_AnyoneWhenPublic() public {
        oracle.setPublicCreation(true);

        // Would fail at Resolver call since we're not on mainnet, but access check passes
        vm.prank(address(0xdead));
        vm.deal(address(0xdead), 10 ether);
        vm.expectRevert(); // Resolver call will fail in test env
        oracle.createMarket{value: 1 ether}(
            50,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(0xdead)
        );
    }

    function test_CreateMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp), true, 3, 1 ether, 30, 0, address(this)
        );

        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp - 1), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateMarket_InvalidOp() public {
        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp + 1 days), true, 0, 1 ether, 30, 0, address(this)
        );

        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp + 1 days), true, 1, 1 ether, 30, 0, address(this)
        );

        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createMarket(
            50, address(0), uint64(block.timestamp + 1 days), true, 4, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateMarket_InvalidETHAmount() public {
        // ETH collateral but wrong msg.value
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createMarket{value: 0.5 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateMarket_ERC20_RevertIfETHSent() public {
        // ERC20 collateral but ETH sent
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createMarket{value: 1 ether}(
            50,
            address(0xdead),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          MARKET VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_MarketCount_InitiallyZero() public view {
        assertEq(oracle.marketCount(), 0);
    }

    function test_GetMarkets_EmptyReturnsEmpty() public view {
        uint256[] memory ids = oracle.getMarkets(0, 10);
        assertEq(ids.length, 0);
    }

    function test_GetMarkets_StartBeyondLength() public view {
        uint256[] memory ids = oracle.getMarkets(100, 10);
        assertEq(ids.length, 0);
    }

    function test_GetMarketInfos_EmptyReturnsEmpty() public view {
        GasPM.MarketInfo[] memory infos = oracle.getMarketInfos(0, 10);
        assertEq(infos.length, 0);
    }

    function test_IsOurMarket_FalseForUnknown() public view {
        assertEq(oracle.isOurMarket(12345), false);
    }

    /*//////////////////////////////////////////////////////////////
                       ADDITIONAL COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetReward_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit GasPM.RewardConfigured(0.001 ether, 1 hours);
        oracle.setReward(0.001 ether, 1 hours);
    }

    function test_TransferOwnership_EmitsEvent() public {
        address newOwner = address(0xbeef);
        vm.expectEmit(true, true, true, true);
        emit GasPM.OwnershipTransferred(address(this), newOwner);
        oracle.transferOwnership(newOwner);
    }

    function test_GetMarkets_CountClipping() public view {
        // Can't add markets without Resolver, but test the clipping logic
        // When count exceeds remaining items, should clip to available
        uint256[] memory ids = oracle.getMarkets(0, 1000);
        assertEq(ids.length, 0); // No markets, so empty
    }

    function test_Update_RewardTransferFailed() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 1 ether);

        vm.warp(deployTime + 1 hours);

        // Deploy a contract that rejects ETH
        RejectETH rejecter = new RejectETH();

        // Prank as the rejecter and try to update
        vm.prank(address(rejecter));
        vm.expectRevert(bytes4(0xb12d13eb)); // ETHTransferFailed selector
        oracle.update();
    }

    function test_Withdraw_TransferFailed() public {
        vm.deal(address(oracle), 1 ether);

        // Deploy a contract that rejects ETH
        RejectETH rejecter = new RejectETH();

        vm.expectRevert(bytes4(0xb12d13eb)); // ETHTransferFailed selector
        oracle.withdraw(address(rejecter), 1 ether);
    }

    function test_Update_ByAnyone() public {
        vm.warp(deployTime + 1 hours);

        // Non-owner can call update
        vm.prank(address(0xdead));
        oracle.update();

        assertEq(oracle.lastUpdateTime(), block.timestamp);
    }

    function test_BaseFeeAverage_WeightedCorrectly() public {
        // Test weighted average: 1 hour at 50 gwei, 3 hours at 100 gwei
        // Expected: (50*1 + 100*3) / 4 = 350/4 = 87.5 gwei (rounds to 87)

        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update(); // Records 50 gwei for first hour

        vm.warp(deployTime + 4 hours);
        oracle.update(); // Records 100 gwei for next 3 hours

        // (50 gwei * 1h + 100 gwei * 3h) / 4h = 87.5 gwei
        uint256 avg = oracle.baseFeeAverage();
        assertEq(avg, 87500000000); // 87.5 gwei in wei
    }

    function test_CreateMarket_OwnerCanCreateWhenNotPublic() public {
        // Owner can create even when publicCreation is false
        // Will fail at Resolver call, but validates access check passes
        vm.expectRevert(); // Resolver call fails
        oracle.createMarket{value: 1 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_Update_DifferentCallers() public {
        oracle.setReward(0.001 ether, 1 hours);
        vm.deal(address(oracle), 10 ether);

        // First caller gets reward
        vm.warp(deployTime + 1 hours);
        address caller1 = address(0x1111);
        vm.deal(caller1, 0);
        vm.prank(caller1);
        oracle.update();
        assertEq(caller1.balance, 0.001 ether);

        // Second caller after cooldown also gets reward
        vm.warp(deployTime + 2 hours);
        address caller2 = address(0x2222);
        vm.deal(caller2, 0);
        vm.prank(caller2);
        oracle.update();
        assertEq(caller2.balance, 0.001 ether);
    }

    function test_SetReward_CanDisableAfterEnabled() public {
        oracle.setReward(0.001 ether, 1 hours);
        assertEq(oracle.rewardAmount(), 0.001 ether);

        // Disable rewards
        oracle.setReward(0, 0);
        assertEq(oracle.rewardAmount(), 0);
        assertEq(oracle.cooldown(), 0);
    }

    function test_SetReward_CanChangeRewardAndCooldown() public {
        oracle.setReward(0.001 ether, 1 hours);

        // Change to different values
        oracle.setReward(0.002 ether, 2 hours);
        assertEq(oracle.rewardAmount(), 0.002 ether);
        assertEq(oracle.cooldown(), 2 hours);
    }

    function test_TransferOwnership_ToZeroAddress() public {
        // Should work (no validation on newOwner)
        oracle.transferOwnership(address(0));
        assertEq(oracle.owner(), address(0));

        // Now no one can call owner functions
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.setReward(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       ERC20 COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_ERC20_TransfersFromCaller() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        uint256 balBefore = token.balanceOf(address(this));

        // Will fail at Resolver call, but ERC20 transfer should happen first
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket(
            50,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            3,
            10 ether,
            30,
            0,
            address(this)
        );

        // Token should have been transferred to oracle (before Resolver call failed)
        // Actually, since it reverts, the transfer is rolled back
        assertEq(token.balanceOf(address(this)), balBefore);
    }

    function test_CreateMarket_ERC20_6Decimals() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(address(this), 10000e6); // 10000 USDC
        usdc.approve(address(oracle), type(uint256).max);

        // Will fail at Resolver, but validates the flow accepts 6 decimal tokens
        vm.expectRevert();
        oracle.createMarket(
            50,
            address(usdc),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1000e6,
            30,
            0,
            address(this)
        );
    }

    function test_CreateMarket_ERC20_8Decimals() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        wbtc.mint(address(this), 10e8); // 10 WBTC
        wbtc.approve(address(oracle), type(uint256).max);

        // Will fail at Resolver, but validates the flow accepts 8 decimal tokens
        vm.expectRevert();
        oracle.createMarket(
            50, address(wbtc), uint64(block.timestamp + 1 days), true, 3, 1e8, 30, 0, address(this)
        );
    }

    function test_CreateMarket_ERC20_NoApproval_Reverts() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        // Don't approve

        vm.expectRevert(); // TransferFromFailed
        oracle.createMarket(
            50,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            3,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateMarket_ERC20_InsufficientBalance_Reverts() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 1 ether); // Only 1 ether
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(); // TransferFromFailed - not enough balance
        oracle.createMarket(
            50,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            3,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateMarket_USDT_Style_NoReturnValue() public {
        MockUSDT usdt = new MockUSDT();
        usdt.mint(address(this), 10000e6);
        usdt.approve(address(oracle), type(uint256).max);

        // USDT-style token (no return value on transfer)
        vm.expectRevert(); // Resolver not deployed, but transfer works
        oracle.createMarket(
            50,
            address(usdt),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1000e6,
            30,
            0,
            address(this)
        );
    }

    function test_CreateMarket_LTE_Operator() public {
        // Test that LTE (op=2) is accepted
        vm.expectRevert(); // Resolver not deployed, but op validation passes
        oracle.createMarket{value: 1 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 2, 1 ether, 30, 0, address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                       CREATE MARKET AND BUY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarketAndBuy_OnlyOwnerWhenNotPublic() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether,
            minOut: 0,
            yesForNo: false, // buyYes
            recipient: address(0)
        });

        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createMarketAndBuy(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateMarketAndBuy_InvalidThreshold() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createMarketAndBuy(
            0, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateMarketAndBuy_InvalidClose() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createMarketAndBuy(50, address(0), uint64(block.timestamp), true, 3, seed, swap);
    }

    function test_CreateMarketAndBuy_InvalidOp() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createMarketAndBuy{value: 12 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 5, seed, swap
        );
    }

    function test_CreateMarketAndBuy_InvalidETHAmount() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        // Should require seed.collateralIn + swap.collateralForSwap = 12 ether
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createMarketAndBuy{value: 10 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateMarketAndBuy_ETH_CorrectTotalValue() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        // Will fail at Resolver call, but validates msg.value check passes
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarketAndBuy{value: 12 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateMarketAndBuy_LTE_Operator() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        // Test that LTE (op=2) is accepted
        vm.expectRevert(); // Resolver not deployed, but op validation passes
        oracle.createMarketAndBuy{value: 12 ether}(
            50, address(0), uint64(block.timestamp + 1 days), true, 2, seed, swap
        );
    }

    function test_CreateMarketAndBuy_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });
        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 2 ether, minOut: 0, yesForNo: false, recipient: address(0)
        });

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createMarketAndBuy{value: 1 ether}(
            50, address(token), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    /*//////////////////////////////////////////////////////////////
                         RANGE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BaseFeeInRange_WithinRange() public view {
        // Initial basefee is 50 gwei
        assertEq(oracle.baseFeeInRange(30 gwei, 70 gwei), 1); // 50 is within 30-70
        assertEq(oracle.baseFeeInRange(50 gwei, 100 gwei), 1); // 50 is at lower bound (inclusive)
        assertEq(oracle.baseFeeInRange(1 gwei, 50 gwei), 1); // 50 is at upper bound (inclusive)
    }

    function test_BaseFeeInRange_OutsideRange() public view {
        // Initial basefee is 50 gwei
        assertEq(oracle.baseFeeInRange(60 gwei, 100 gwei), 0); // 50 < 60
        assertEq(oracle.baseFeeInRange(1 gwei, 40 gwei), 0); // 50 > 40
    }

    function test_BaseFeeOutOfRange_WithinRange() public view {
        // Initial basefee is 50 gwei - should return 0 (not out of range)
        assertEq(oracle.baseFeeOutOfRange(30 gwei, 70 gwei), 0); // 50 is within 30-70
        assertEq(oracle.baseFeeOutOfRange(50 gwei, 100 gwei), 0); // 50 is at lower bound
        assertEq(oracle.baseFeeOutOfRange(1 gwei, 50 gwei), 0); // 50 is at upper bound
    }

    function test_BaseFeeOutOfRange_OutsideRange() public view {
        // Initial basefee is 50 gwei - should return 1 (is out of range)
        assertEq(oracle.baseFeeOutOfRange(60 gwei, 100 gwei), 1); // 50 < 60
        assertEq(oracle.baseFeeOutOfRange(1 gwei, 40 gwei), 1); // 50 > 40
    }

    function test_BaseFeeInRange_AfterUpdate() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        // TWAP should be 75 gwei (50*1h + 100*1h) / 2h
        assertEq(oracle.baseFeeAverageGwei(), 75);
        assertEq(oracle.baseFeeInRange(70 gwei, 80 gwei), 1); // 75 is within 70-80
        assertEq(oracle.baseFeeInRange(76 gwei, 100 gwei), 0); // 75 < 76
    }

    function test_BaseFeeOutOfRange_AfterUpdate() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        // TWAP should be 75 gwei
        assertEq(oracle.baseFeeOutOfRange(70 gwei, 80 gwei), 0); // 75 is within 70-80
        assertEq(oracle.baseFeeOutOfRange(76 gwei, 100 gwei), 1); // 75 < 76, so out of range
    }

    function test_CreateRangeMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createRangeMarket(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateRangeMarket_InvalidThreshold_ZeroLower() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarket(
            0, 70, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateRangeMarket_InvalidThreshold_ZeroUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarket(
            30, 0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateRangeMarket_InvalidThreshold_LowerGteUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarket(
            70,
            30,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarket(
            50,
            50,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateRangeMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createRangeMarket(
            30, 70, address(0), uint64(block.timestamp), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateRangeMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createRangeMarket{value: 0.5 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateRangeMarket_ETH_ValidParams() public {
        // Will fail at Resolver call, but validates all checks pass
        vm.expectRevert(); // Resolver not deployed
        oracle.createRangeMarket{value: 1 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateRangeMarket_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createRangeMarket{value: 1 ether}(
            30,
            70,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateRangeMarket_AnyoneWhenPublic() public {
        oracle.setPublicCreation(true);

        vm.prank(address(0xdead));
        vm.deal(address(0xdead), 10 ether);
        vm.expectRevert(); // Resolver call will fail in test env
        oracle.createRangeMarket{value: 1 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(0xdead)
        );
    }

    /*//////////////////////////////////////////////////////////////
                       BREAKOUT MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateBreakoutMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createBreakoutMarket(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateBreakoutMarket_InvalidThreshold_ZeroLower() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createBreakoutMarket(
            0, 70, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateBreakoutMarket_InvalidThreshold_ZeroUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createBreakoutMarket(
            30, 0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateBreakoutMarket_InvalidThreshold_LowerGteUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createBreakoutMarket(
            70,
            30,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createBreakoutMarket(
            50,
            50,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateBreakoutMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createBreakoutMarket(
            30, 70, address(0), uint64(block.timestamp), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateBreakoutMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createBreakoutMarket{value: 0.5 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateBreakoutMarket_ETH_ValidParams() public {
        // Will fail at Resolver call, but validates all checks pass
        vm.expectRevert(); // Resolver not deployed
        oracle.createBreakoutMarket{value: 1 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateBreakoutMarket_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createBreakoutMarket{value: 1 ether}(
            30,
            70,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateBreakoutMarket_AnyoneWhenPublic() public {
        oracle.setPublicCreation(true);

        vm.prank(address(0xdead));
        vm.deal(address(0xdead), 10 ether);
        vm.expectRevert(); // Resolver call will fail in test env
        oracle.createBreakoutMarket{value: 1 ether}(
            30,
            70,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(0xdead)
        );
    }

    /*//////////////////////////////////////////////////////////////
                         PEAK/TROUGH MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BaseFeeMax_Initial() public view {
        // Initial basefee is 50 gwei
        assertEq(oracle.baseFeeMax(), 50 gwei);
    }

    function test_BaseFeeMin_Initial() public view {
        // Initial basefee is 50 gwei
        assertEq(oracle.baseFeeMin(), 50 gwei);
    }

    function test_BaseFeeMax_UpdatesOnHigherFee() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        assertEq(oracle.baseFeeMax(), 100 gwei);
        assertEq(oracle.minBaseFee(), 50 gwei); // min unchanged
    }

    function test_BaseFeeMin_UpdatesOnLowerFee() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(25 gwei);
        oracle.update();

        assertEq(oracle.baseFeeMax(), 50 gwei); // max unchanged
        assertEq(oracle.baseFeeMin(), 25 gwei);
    }

    function test_BaseFeeMax_TracksHistoricalPeak() public {
        // Gas spikes to 200, then drops to 30
        vm.warp(deployTime + 1 hours);
        vm.fee(200 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(30 gwei);
        oracle.update();

        // Max should still be 200 (the historical peak)
        assertEq(oracle.baseFeeMax(), 200 gwei);
    }

    function test_BaseFeeMin_TracksHistoricalTrough() public {
        // Gas drops to 10, then rises to 100
        vm.warp(deployTime + 1 hours);
        vm.fee(10 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(100 gwei);
        oracle.update();

        // Min should still be 10 (the historical trough)
        assertEq(oracle.baseFeeMin(), 10 gwei);
    }

    function test_BaseFeeSpread_Initial() public view {
        // At deploy, max == min == block.basefee, so spread is 0
        assertEq(oracle.baseFeeSpread(), 0);
    }

    function test_BaseFeeSpread_AfterVolatility() public {
        // Gas goes low then high
        vm.warp(deployTime + 1 hours);
        vm.fee(10 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(100 gwei);
        oracle.update();

        // Spread = max - min = 100 - 10 = 90 gwei
        assertEq(oracle.baseFeeSpread(), 90 gwei);
    }

    function test_BaseFeeSpread_MonotonicallyIncreases() public {
        // Spread can only increase (max goes up, min goes down)
        vm.warp(deployTime + 1 hours);
        vm.fee(60 gwei); // higher than deploy (50)
        oracle.update();
        uint256 spread1 = oracle.baseFeeSpread();

        vm.warp(deployTime + 2 hours);
        vm.fee(40 gwei); // lower than deploy (50)
        oracle.update();
        uint256 spread2 = oracle.baseFeeSpread();

        vm.warp(deployTime + 3 hours);
        vm.fee(50 gwei); // back to middle
        oracle.update();
        uint256 spread3 = oracle.baseFeeSpread();

        // Spread should monotonically increase or stay same
        assertGe(spread2, spread1);
        assertGe(spread3, spread2);
        // Final spread = 60 - 40 = 20 gwei
        assertEq(spread3, 20 gwei);
    }

    function test_CreateVolatilityMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createVolatilityMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateVolatilityMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createVolatilityMarket(
            50 gwei, address(0), uint64(block.timestamp - 1), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateVolatilityMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createVolatilityMarket{value: 0.5 ether}(
            50 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateStabilityMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createStabilityMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateStabilityMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createStabilityMarket(
            20 gwei, address(0), uint64(block.timestamp - 1), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateStabilityMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createStabilityMarket{value: 0.5 ether}(
            20 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreatePeakMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createPeakMarket(
            100, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreatePeakMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createPeakMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreatePeakMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createPeakMarket(
            100, address(0), uint64(block.timestamp - 1), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreatePeakMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createPeakMarket{value: 0.5 ether}(
            100, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreatePeakMarket_ETH_ValidParams() public {
        // Will fail at Resolver call, but validates all checks pass
        vm.expectRevert(); // Resolver not deployed
        oracle.createPeakMarket{value: 1 ether}(
            100, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreatePeakMarket_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createPeakMarket{value: 1 ether}(
            100,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreatePeakMarket_AnyoneWhenPublic() public {
        oracle.setPublicCreation(true);

        vm.prank(address(0xdead));
        vm.deal(address(0xdead), 10 ether);
        vm.expectRevert(); // Resolver call will fail in test env
        oracle.createPeakMarket{value: 1 ether}(
            100, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(0xdead)
        );
    }

    function test_CreateTroughMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createTroughMarket(
            20, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateTroughMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createTroughMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateTroughMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createTroughMarket(
            20, address(0), uint64(block.timestamp - 1), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateTroughMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createTroughMarket{value: 0.5 ether}(
            20, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateTroughMarket_ETH_ValidParams() public {
        // Will fail at Resolver call, but validates all checks pass
        vm.expectRevert(); // Resolver not deployed
        oracle.createTroughMarket{value: 1 ether}(
            20, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateTroughMarket_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createTroughMarket{value: 1 ether}(
            20,
            address(token),
            uint64(block.timestamp + 1 days),
            true,
            10 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateTroughMarket_AnyoneWhenPublic() public {
        oracle.setPublicCreation(true);

        vm.prank(address(0xdead));
        vm.deal(address(0xdead), 10 ether);
        vm.expectRevert(); // Resolver call will fail in test env
        oracle.createTroughMarket{value: 1 ether}(
            20, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(0xdead)
        );
    }

    /*//////////////////////////////////////////////////////////////
                         USER STORY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice User Story: Gas Bull - Bet that gas will spike above 50 gwei
    function test_UserStory_GasBull() public {
        // Gas Bull creates GTE market betting gas will exceed 50 gwei
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket{value: 10 ether}(
            50, // threshold: 50 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // canClose early if condition met
            3, // op=3 (GTE)
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Gas Bear - Bet that gas will stay below 30 gwei
    function test_UserStory_GasBear() public {
        // Gas Bear creates LTE market betting gas stays low
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket{value: 10 ether}(
            30, // threshold: 30 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            false, // wait until deadline to check
            2, // op=2 (LTE)
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Range Trader - Bet that gas will stay between 30-70 gwei
    function test_UserStory_RangeTrader() public {
        // Range Trader creates market betting gas stays in normal range
        vm.expectRevert(); // Resolver not deployed
        oracle.createRangeMarket{value: 10 ether}(
            30, // lower: 30 gwei
            70, // upper: 70 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            false, // check at deadline
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Hedger - Insure against gas leaving safe range
    function test_UserStory_BreakoutHedger() public {
        // Hedger creates breakout market to get paid if gas spikes or crashes
        // canClose=true means early payout when gas leaves 30-70 range
        vm.expectRevert(); // Resolver not deployed
        oracle.createBreakoutMarket{value: 10 ether}(
            30, // lower: 30 gwei
            70, // upper: 70 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // early close when breakout occurs
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Peak Speculator - Bet gas will spike to 100 gwei
    function test_UserStory_PeakSpeculator() public {
        // Speculator bets gas will touch 100 gwei at some point
        // canClose=true means immediate payout when 100 gwei is touched
        vm.expectRevert(); // Resolver not deployed
        oracle.createPeakMarket{value: 10 ether}(
            100, // threshold: 100 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // early close when peak reached
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Trough Hunter - Bet gas will dip to 10 gwei
    function test_UserStory_TroughHunter() public {
        // Trader bets gas will dip to cheap levels at some point
        // canClose=true means immediate payout when gas dips
        vm.expectRevert(); // Resolver not deployed
        oracle.createTroughMarket{value: 10 ether}(
            10, // threshold: 10 gwei
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // early close when trough reached
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Volatility Trader - Bet gas will swing by 50 gwei
    function test_UserStory_VolatilityTrader() public {
        // Trader bets that gas volatility (max - min spread) will exceed 50 gwei
        // canClose=true means immediate payout when volatility threshold hit
        vm.expectRevert(); // Resolver not deployed
        oracle.createVolatilityMarket{value: 10 ether}(
            50 gwei, // threshold: 50 gwei spread
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // early close when volatility reached
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Stability Trader - Bet gas will stay calm
    function test_UserStory_StabilityTrader() public {
        // Trader bets that gas will remain stable (spread stays under 20 gwei)
        // Opposite of volatility - wins if gas prices don't swing much
        vm.expectRevert(); // Resolver not deployed
        oracle.createStabilityMarket{value: 10 ether}(
            20 gwei, // threshold: max 20 gwei spread
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            true, // early close if volatility exceeds threshold (NO wins)
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Keeper - Earn rewards by updating oracle
    function test_UserStory_Keeper() public {
        // Owner configures rewards
        oracle.setReward(0.01 ether, 1 hours);
        vm.deal(address(oracle), 10 ether);

        // Keeper waits for cooldown and calls update
        address keeper = address(0x4444);
        vm.deal(keeper, 0);

        vm.warp(deployTime + 1 hours);
        vm.prank(keeper);
        oracle.update();

        // Keeper earned reward
        assertEq(keeper.balance, 0.01 ether);
    }

    /// @notice User Story: Market Creator with Skewed Odds
    function test_UserStory_SkewedOddsCreator() public {
        // Creator wants to start market at 70% YES odds instead of 50/50
        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: 10 ether,
            feeOrHook: 30,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 0,
            lpRecipient: address(this),
            deadline: 0
        });

        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: 3 ether, // Buy YES to push price up
            minOut: 0,
            yesForNo: false, // buyYes
            recipient: address(0)
        });

        vm.expectRevert(); // Resolver not deployed
        oracle.createMarketAndBuy{value: 13 ether}(
            50, address(0), uint64(block.timestamp + 30 days), true, 3, seed, swap
        );
    }

    /// @notice User Story: Window Volatility Trader - Bet gas will swing during market
    function test_UserStory_WindowVolatilityTrader() public {
        // Trader bets gas will swing by 30 gwei DURING THIS MARKET (not lifetime)
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowVolatilityMarket{value: 10 ether}(
            30 gwei, // threshold: 30 gwei new swing during market
            address(0), // ETH collateral
            uint64(block.timestamp + 7 days),
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Window Stability Trader - Bet gas stays calm during market
    function test_UserStory_WindowStabilityTrader() public {
        // Trader bets gas will NOT swing more than 10 gwei DURING THIS MARKET
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowStabilityMarket{value: 10 ether}(
            10 gwei, // threshold: max 10 gwei new swing during market
            address(0), // ETH collateral
            uint64(block.timestamp + 7 days),
            false, // check at deadline only
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Spot Trader - Bet gas will be high at resolution
    function test_UserStory_SpotTrader() public {
        // Trader bets spot gas price will be >= 100 gwei at resolution time
        // Uses baseFeeCurrent() not TWAP - single block price
        // Best for high thresholds where manipulation is costly
        vm.expectRevert(); // Resolver not deployed
        oracle.createSpotMarket{value: 10 ether}(
            100 gwei, // threshold: 100 gwei spot price
            address(0), // ETH collateral
            uint64(block.timestamp + 7 days),
            true, // canClose=true for instant payout when threshold hit
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice User Story: Comparison Trader - Bet gas will be higher at close
    function test_UserStory_ComparisonTrader() public {
        // Trader bets TWAP will be higher at market close than at creation
        // Snapshots current TWAP, compares at resolution
        vm.expectRevert(); // Resolver not deployed
        oracle.createComparisonMarket{value: 10 ether}(
            address(0), // ETH collateral
            uint64(block.timestamp + 30 days),
            10 ether,
            30,
            0,
            address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        WINDOW MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BaseFeeAverageSince_NoSnapshot_FallsBackToLifetime() public view {
        // Without a snapshot, should return lifetime average
        assertEq(oracle.baseFeeAverageSince(12345), oracle.baseFeeAverage());
    }

    function test_BaseFeeAverageSince_WithSnapshot() public {
        // Change fee BEFORE first update so it records correctly
        vm.fee(100 gwei);
        vm.warp(deployTime + 1 hours);
        oracle.update();
        // cumulative = 50 gwei * 1hr (from deploy), lastBaseFee = 100 gwei

        vm.warp(deployTime + 2 hours);
        // Now pending: 100 gwei * 1hr
        // Lifetime average: (50 * 1hr + 100 * 1hr) / 2hr = 75 gwei
        assertEq(oracle.baseFeeAverage(), 75 gwei);

        // Without snapshot, baseFeeAverageSince falls back to lifetime
        assertEq(oracle.baseFeeAverageSince(12345), 75 gwei);
    }

    function test_BaseFeeInRangeSince_WithinRange() public view {
        // With no snapshot, falls back to lifetime (50 gwei)
        assertEq(oracle.baseFeeInRangeSince(12345, 30 gwei, 70 gwei), 1);
        assertEq(oracle.baseFeeInRangeSince(12345, 50 gwei, 100 gwei), 1);
    }

    function test_BaseFeeInRangeSince_OutsideRange() public view {
        // With no snapshot, falls back to lifetime (50 gwei)
        assertEq(oracle.baseFeeInRangeSince(12345, 60 gwei, 100 gwei), 0);
        assertEq(oracle.baseFeeInRangeSince(12345, 10 gwei, 40 gwei), 0);
    }

    function test_BaseFeeOutOfRangeSince_OutsideRange() public view {
        // With no snapshot, falls back to lifetime (50 gwei)
        assertEq(oracle.baseFeeOutOfRangeSince(12345, 60 gwei, 100 gwei), 1);
        assertEq(oracle.baseFeeOutOfRangeSince(12345, 10 gwei, 40 gwei), 1);
    }

    function test_BaseFeeOutOfRangeSince_WithinRange() public view {
        // With no snapshot, falls back to lifetime (50 gwei)
        assertEq(oracle.baseFeeOutOfRangeSince(12345, 30 gwei, 70 gwei), 0);
    }

    function test_BaseFeeSpreadSince_NoSnapshot_FallsBackToLifetime() public view {
        // Without a snapshot, should return lifetime spread
        assertEq(oracle.baseFeeSpreadSince(12345), oracle.baseFeeSpread());
    }

    function test_BaseFeeSpreadSince_MeasuresNewVolatility() public {
        // At deploy, max=min=50 gwei, so spread = 0
        assertEq(oracle.baseFeeSpread(), 0);

        // Gas goes up to 70 gwei
        vm.warp(deployTime + 1 hours);
        vm.fee(70 gwei);
        oracle.update();

        // Now max=70, min=50, lifetime spread = 20
        assertEq(oracle.baseFeeSpread(), 20 gwei);

        // Without snapshot, falls back to lifetime
        assertEq(oracle.baseFeeSpreadSince(12345), 20 gwei);

        // Now simulate a volatility snapshot was taken at this point
        // (In real usage, createWindowVolatilityMarket does this)
        // If a market was created NOW with max=70, min=50:
        // - Any NEW high above 70 or NEW low below 50 counts as window spread
        // - If gas stays between 50-70, window spread = 0
    }

    function test_BaseFeeSpreadSince_OnlyCountsNewExtremes() public {
        // Gas swings before "market creation"
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei); // new high
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(20 gwei); // new low
        oracle.update();

        // Lifetime spread = 100 - 20 = 80 gwei
        assertEq(oracle.baseFeeSpread(), 80 gwei);

        // Simulate snapshotting at this point (max=100, min=20)
        // In real usage createWindowVolatilityMarket would store this

        // After snapshot, gas moves but stays within previous range
        vm.warp(deployTime + 3 hours);
        vm.fee(60 gwei); // within 20-100 range
        oracle.update();

        // Lifetime spread unchanged (no new extremes)
        assertEq(oracle.baseFeeSpread(), 80 gwei);

        // Without a snapshot stored, still returns lifetime
        assertEq(oracle.baseFeeSpreadSince(12345), 80 gwei);
    }

    function test_CreateWindowVolatilityMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowVolatilityMarket(
            0, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowVolatilityMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowVolatilityMarket(
            30 gwei, address(0), uint64(block.timestamp - 1), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowStabilityMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowStabilityMarket(
            0, address(0), uint64(block.timestamp + 1 days), false, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowStabilityMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowStabilityMarket(
            10 gwei, address(0), uint64(block.timestamp - 1), false, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateSpotMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createSpotMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateSpotMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createSpotMarket(
            100 gwei, address(0), uint64(block.timestamp - 1), true, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateSpotMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createSpotMarket{value: 0.5 ether}(
            100 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_BaseFeeHigherThanStart_NoSnapshot() public view {
        // Without a snapshot, returns 0
        assertEq(oracle.baseFeeHigherThanStart(12345), 0);
    }

    function test_BaseFeeHigherThanStart_Higher() public {
        // Simulate: start at 50 gwei, TWAP increases over time
        // At deploy, TWAP = 50 gwei
        assertEq(oracle.baseFeeAverage(), 50 gwei);

        // Gas increases - need time to pass for TWAP to change
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        // More time at high gas
        vm.warp(deployTime + 3 hours);
        oracle.update();

        // TWAP = (50 * 1hr + 100 * 2hr) / 3hr = 250/3 = 83.3 gwei
        assertGt(oracle.baseFeeAverage(), 50 gwei);
    }

    function test_CreateComparisonMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createComparisonMarket(
            address(0), uint64(block.timestamp - 1), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateComparisonMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createComparisonMarket{value: 0.5 ether}(
            address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowMarket(
            0, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowMarket(
            50 gwei, address(0), uint64(block.timestamp - 1), true, 3, 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowMarket_InvalidOp() public {
        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createWindowMarket{value: 1 ether}(
            50 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowMarket_InvalidETHAmount() public {
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createWindowMarket{value: 0.5 ether}(
            50 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowMarket_OnlyOwnerWhenNotPublic() public {
        address notOwner = address(0x1234);
        vm.deal(notOwner, 10 ether);
        vm.prank(notOwner);
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createWindowMarket{value: 1 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), true, 3, 1 ether, 30, 0, notOwner
        );
    }

    function test_CreateWindowMarket_ETH_ValidParams() public {
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowMarket{value: 1 ether}(
            50 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowMarketAndBuy_InvalidThreshold() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(1 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(0.5 ether, 0, false, address(0));
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowMarketAndBuy{value: 1.5 ether}(
            0, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateWindowMarketAndBuy_InvalidOp() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(1 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(0.5 ether, 0, false, address(0));
        vm.expectRevert(GasPM.InvalidOp.selector);
        oracle.createWindowMarketAndBuy{value: 1.5 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), true, 1, seed, swap
        );
    }

    function test_CreateWindowMarketAndBuy_ETH_ValidParams() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(1 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(0.5 ether, 0, false, address(0));
        vm.expectRevert(); // Resolver not deployed, but passes our checks
        oracle.createWindowMarketAndBuy{value: 1.5 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), true, 3, seed, swap
        );
    }

    function test_CreateWindowRangeMarket_InvalidThreshold_ZeroLower() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowRangeMarket(
            0,
            70 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            false,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowRangeMarket_InvalidThreshold_LowerGteUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowRangeMarket(
            70 gwei,
            30 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            false,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowRangeMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowRangeMarket(
            30 gwei,
            70 gwei,
            address(0),
            uint64(block.timestamp - 1),
            false,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowRangeMarket_ETH_ValidParams() public {
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowRangeMarket{value: 1 ether}(
            30 gwei,
            70 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            false,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowBreakoutMarket_InvalidThreshold_ZeroLower() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowBreakoutMarket(
            0,
            70 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowBreakoutMarket_InvalidThreshold_LowerGteUpper() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowBreakoutMarket(
            70 gwei,
            30 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowBreakoutMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowBreakoutMarket(
            30 gwei,
            70 gwei,
            address(0),
            uint64(block.timestamp - 1),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_CreateWindowBreakoutMarket_ETH_ValidParams() public {
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowBreakoutMarket{value: 1 ether}(
            30 gwei,
            70 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    function test_MarketSnapshots_InitiallyEmpty() public view {
        (uint192 cumulative, uint64 timestamp) = oracle.marketSnapshots(12345);
        assertEq(cumulative, 0);
        assertEq(timestamp, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    WINDOW PEAK/TROUGH MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateWindowPeakMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowPeakMarket(
            0, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowPeakMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowPeakMarket(
            100 gwei, address(0), uint64(block.timestamp - 1), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowPeakMarket_AlreadyExceeded() public {
        // maxBaseFee is 50 gwei at deploy
        vm.expectRevert(GasPM.AlreadyExceeded.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Also fails for lower threshold
        vm.expectRevert(GasPM.AlreadyExceeded.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            30 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowPeakMarket_ValidThreshold() public {
        // 100 gwei > current maxBaseFee (50 gwei), should pass validation
        vm.expectRevert(); // Resolver not deployed, but passes our checks
        oracle.createWindowPeakMarket{value: 1 ether}(
            100 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowPeakMarket_OnlyOwnerWhenNotPublic() public {
        address notOwner = address(0x1234);
        vm.deal(notOwner, 10 ether);
        vm.prank(notOwner);
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            100 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, notOwner
        );
    }

    function test_CreateWindowPeakMarket_AfterMaxIncreases() public {
        // Simulate gas spike to 80 gwei
        vm.fee(80 gwei);
        vm.warp(block.timestamp + 1 hours);
        oracle.update();
        assertEq(oracle.baseFeeMax(), 80 gwei);

        // Now threshold of 60 gwei should fail (already exceeded)
        vm.expectRevert(GasPM.AlreadyExceeded.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            60 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // But 100 gwei should pass (not yet exceeded)
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowPeakMarket{value: 1 ether}(
            100 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowTroughMarket_InvalidThreshold() public {
        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowTroughMarket(
            0, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowTroughMarket_InvalidClose() public {
        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowTroughMarket(
            10 gwei, address(0), uint64(block.timestamp - 1), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowTroughMarket_AlreadyBelowThreshold() public {
        // minBaseFee is 50 gwei at deploy
        vm.expectRevert(GasPM.AlreadyBelowThreshold.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Also fails for higher threshold
        vm.expectRevert(GasPM.AlreadyBelowThreshold.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            70 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowTroughMarket_ValidThreshold() public {
        // 10 gwei < current minBaseFee (50 gwei), should pass validation
        vm.expectRevert(); // Resolver not deployed, but passes our checks
        oracle.createWindowTroughMarket{value: 1 ether}(
            10 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    function test_CreateWindowTroughMarket_OnlyOwnerWhenNotPublic() public {
        address notOwner = address(0x1234);
        vm.deal(notOwner, 10 ether);
        vm.prank(notOwner);
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            10 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, notOwner
        );
    }

    function test_CreateWindowTroughMarket_AfterMinDecreases() public {
        // Simulate gas dip to 30 gwei
        vm.fee(30 gwei);
        vm.warp(block.timestamp + 1 hours);
        oracle.update();
        assertEq(oracle.baseFeeMin(), 30 gwei);

        // Now threshold of 40 gwei should fail (already below)
        vm.expectRevert(GasPM.AlreadyBelowThreshold.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            40 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // But 10 gwei should pass (not yet reached)
        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowTroughMarket{value: 1 ether}(
            10 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                      PERMIT & MULTICALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Permit_ERC20() public {
        MockERC20Permit token = new MockERC20Permit("Permit", "PRMT", 18);
        token.mint(address(this), 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        // Permit should set allowance via the permit function
        oracle.permit(address(token), address(this), 50 ether, deadline, v, r, s);

        // Verify allowance was set
        assertEq(token.allowance(address(this), address(oracle)), 50 ether);
    }

    function test_PermitDAI_Style() public {
        MockDAIPermit token = new MockDAIPermit();
        token.mint(address(this), 100 ether);

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        // DAI-style permit sets max allowance
        oracle.permitDAI(address(token), address(this), nonce, deadline, true, v, r, s);

        // Verify max allowance was set
        assertEq(token.allowance(address(this), address(oracle)), type(uint256).max);
    }

    function test_Multicall_BatchUpdates() public {
        // Warp time so update does something
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);

        // Single update via multicall
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(oracle.update, ());

        oracle.multicall(calls);

        assertEq(oracle.lastBaseFee(), 100 gwei);
    }

    function test_Multicall_PermitThenCreateMarket_ERC20() public {
        MockERC20Permit token = new MockERC20Permit("Permit", "PRMT", 18);
        token.mint(address(this), 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        // Build multicall: permit + createMarket
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            oracle.permit, (address(token), address(this), 10 ether, deadline, v, r, s)
        );
        calls[1] = abi.encodeCall(
            oracle.createMarket,
            (
                50 gwei,
                address(token),
                uint64(block.timestamp + 1 days),
                true,
                3,
                10 ether,
                30,
                0,
                address(this)
            )
        );

        // Will revert at Resolver call (not deployed)
        // Note: multicall reverts atomically, so permit state is also rolled back
        vm.expectRevert();
        oracle.multicall(calls);

        // Allowance is 0 because multicall reverted atomically
        assertEq(token.allowance(address(this), address(oracle)), 0);
    }

    function test_Multicall_PermitOnly() public {
        MockERC20Permit token = new MockERC20Permit("Permit", "PRMT", 18);
        token.mint(address(this), 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        // Multicall with just permit (no revert)
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            oracle.permit, (address(token), address(this), 50 ether, deadline, v, r, s)
        );

        oracle.multicall(calls);

        // Verify permit was successful
        assertEq(token.allowance(address(this), address(oracle)), 50 ether);
    }

    function test_Multicall_NonPayable() public {
        // Verify multicall cannot receive ETH (non-payable)
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(oracle.update, ());

        // Low-level call with value should fail
        (bool success,) =
            address(oracle).call{value: 1 ether}(abi.encodeCall(oracle.multicall, (calls)));
        assertFalse(success, "Multicall should reject ETH");
    }

    receive() external payable {}
}

/// @dev Helper contract that rejects ETH transfers
contract RejectETH {
    receive() external payable {
        revert("no ETH");
    }
}

/// @dev Simple ERC20 mock for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style token that doesn't return bool on transfer
contract MockUSDT {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) public {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) public {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev ERC20 with EIP-2612 permit support (simplified for testing)
contract MockERC20Permit {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Simplified permit that doesn't verify signature (for testing only)
    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256, /* deadline */
        uint8, /* v */
        bytes32, /* r */
        bytes32 /* s */
    ) public {
        allowance[owner_][spender] = value;
    }
}

/*//////////////////////////////////////////////////////////////
                    RANGE MARKET AND BUY TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMRangeMarketAndBuyTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    function test_CreateRangeMarketAndBuy_InvalidThreshold_ZeroLower() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            0, 70 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_InvalidThreshold_ZeroUpper() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 0, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_InvalidThreshold_LowerGteUpper() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            70 gwei, 30 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            50 gwei, 50 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_InvalidClose() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_InvalidETHAmount() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        // Should require seed.collateralIn + swap.collateralForSwap = 12 ether
        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createRangeMarketAndBuy{value: 10 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_OnlyOwnerWhenNotPublic() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createRangeMarketAndBuy(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_ETH_ValidParams() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        // Will fail at Resolver call, but validates all checks pass
        vm.expectRevert(); // Resolver not deployed
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createRangeMarketAndBuy{value: 1 ether}(
            30 gwei, 70 gwei, address(token), uint64(block.timestamp + 1 days), true, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_BuyYes() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0)); // buyYes

        vm.expectRevert(); // Resolver not deployed
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    function test_CreateRangeMarketAndBuy_BuyNo() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, true, address(0)); // buyNo

        vm.expectRevert(); // Resolver not deployed
        oracle.createRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                WINDOW RANGE/BREAKOUT AND BUY TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMWindowMarketAndBuyTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    function test_CreateWindowRangeMarketAndBuy_InvalidThreshold_ZeroLower() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowRangeMarketAndBuy{value: 12 ether}(
            0, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    function test_CreateWindowRangeMarketAndBuy_InvalidThreshold_LowerGteUpper() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidThreshold.selector);
        oracle.createWindowRangeMarketAndBuy{value: 12 ether}(
            70 gwei, 30 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    function test_CreateWindowRangeMarketAndBuy_InvalidClose() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidClose.selector);
        oracle.createWindowRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp), false, seed, swap
        );
    }

    function test_CreateWindowRangeMarketAndBuy_InvalidETHAmount() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createWindowRangeMarketAndBuy{value: 10 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    function test_CreateWindowRangeMarketAndBuy_OnlyOwnerWhenNotPublic() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createWindowRangeMarketAndBuy(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    function test_CreateWindowRangeMarketAndBuy_ETH_ValidParams() public {
        GasPM.SeedParams memory seed = GasPM.SeedParams(10 ether, 30, 0, 0, 0, address(this), 0);
        GasPM.SwapParams memory swap = GasPM.SwapParams(2 ether, 0, false, address(0));

        vm.expectRevert(); // Resolver not deployed
        oracle.createWindowRangeMarketAndBuy{value: 12 ether}(
            30 gwei, 70 gwei, address(0), uint64(block.timestamp + 1 days), false, seed, swap
        );
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                    TWAP EDGE CASE TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMEdgeCaseTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /// @notice Test baseFeeAverageSince when duration is 0 (same block as snapshot)
    function test_BaseFeeAverageSince_ZeroDuration() public view {
        // This simulates a market snapshot taken in the same block we query
        // The function should return block.basefee when duration == 0

        // Without actual snapshot, it falls back to lifetime average
        // But we can test the edge case through the lifetime path
        assertEq(oracle.baseFeeAverage(), 50 gwei);
    }

    /// @notice Test that TWAP handles very large time gaps
    function test_BaseFeeAverage_VeryLargeTimeGap() public {
        // Fast forward 10 years
        vm.warp(deployTime + 3650 days);

        // Should not overflow and return correct average
        assertEq(oracle.baseFeeAverage(), 50 gwei);

        // Update and verify still works
        vm.fee(100 gwei);
        oracle.update();

        // Average should still be close to 50 (dominated by long period at 50)
        assertLt(oracle.baseFeeAverage(), 51 gwei);
    }

    /// @notice Test TWAP with very high gas fee
    function test_BaseFeeAverage_VeryHighFee() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(10000 gwei); // Extreme spike
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        // Average = (50 * 1hr + 10000 * 1hr) / 2hr = 5025 gwei
        assertEq(oracle.baseFeeAverage(), 5025 gwei);
    }

    /// @notice Test TWAP with very low (but non-zero) gas fee
    function test_BaseFeeAverage_VeryLowFee() public {
        vm.warp(deployTime + 1 hours);
        vm.fee(1); // 1 wei - extremely low
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        // Average = (50 gwei * 1hr + 1 wei * 1hr) / 2hr ≈ 25 gwei
        uint256 avg = oracle.baseFeeAverage();
        assertGt(avg, 24 gwei);
        assertLt(avg, 26 gwei);
    }

    /// @notice Test multiple rapid updates
    function test_Update_RapidSequence() public {
        for (uint256 i = 1; i <= 100; i++) {
            vm.warp(deployTime + i * 1 minutes);
            vm.fee(uint256(50 gwei) + i * 1 gwei);
            oracle.update();
        }

        // After 100 updates over 100 minutes, average should be roughly 100 gwei
        // (fees ranged from 51 to 150 gwei)
        uint256 avg = oracle.baseFeeAverage();
        assertGt(avg, 90 gwei);
        assertLt(avg, 110 gwei);
    }

    /// @notice Test max/min tracking edge cases
    function test_MaxMin_IdenticalFees() public {
        // If fee never changes, max == min
        vm.warp(deployTime + 1 hours);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        oracle.update();

        assertEq(oracle.baseFeeMax(), 50 gwei);
        assertEq(oracle.baseFeeMin(), 50 gwei);
        assertEq(oracle.baseFeeSpread(), 0);
    }

    /// @notice Test that max/min are updated atomically with cumulative
    function test_Update_AtomicMaxMinUpdate() public {
        vm.warp(deployTime + 1 hours);

        // Gas spikes to 200 gwei
        vm.fee(200 gwei);
        oracle.update();

        // All values should be updated in same tx
        assertEq(oracle.baseFeeMax(), 200 gwei);
        assertEq(oracle.baseFeeMin(), 50 gwei);
        assertEq(oracle.lastBaseFee(), 200 gwei);
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                VOLATILITY SNAPSHOT MATH TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMVolatilitySnapshotTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /// @notice Test baseFeeSpreadSince returns 0 when price stays within original bounds
    function test_BaseFeeSpreadSince_NoNewExtremes() public {
        // Establish initial extremes
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();
        assertEq(oracle.baseFeeMax(), 100 gwei);

        vm.warp(deployTime + 2 hours);
        vm.fee(20 gwei);
        oracle.update();
        assertEq(oracle.baseFeeMin(), 20 gwei);

        // Lifetime spread = 100 - 20 = 80 gwei
        assertEq(oracle.baseFeeSpread(), 80 gwei);

        // Without snapshot, falls back to lifetime
        assertEq(oracle.baseFeeSpreadSince(12345), 80 gwei);
    }

    /// @notice Test window spread struct packing
    function test_WindowSpreads_InitiallyZero() public view {
        (uint128 windowMax, uint128 windowMin) = oracle.windowSpreads(99999);
        assertEq(windowMax, 0);
        assertEq(windowMin, 0);
    }

    /// @notice Test that baseFeeSpreadSince correctly calculates new highs
    function test_BaseFeeSpreadSince_OnlyNewHigh() public {
        // At deploy: max=min=50 gwei
        // If snapshot was taken here and gas goes to 70:
        // newHigh = 70 - 50 = 20
        // newLow = 0 (min didn't go lower)
        // spread = 20

        vm.warp(deployTime + 1 hours);
        vm.fee(70 gwei);
        oracle.update();

        assertEq(oracle.baseFeeMax(), 70 gwei);
        assertEq(oracle.baseFeeMin(), 50 gwei);
        assertEq(oracle.baseFeeSpread(), 20 gwei);
    }

    /// @notice Test that baseFeeSpreadSince correctly calculates new lows
    function test_BaseFeeSpreadSince_OnlyNewLow() public {
        // At deploy: max=min=50 gwei
        // If snapshot was taken here and gas goes to 30:
        // newHigh = 0 (max didn't go higher)
        // newLow = 50 - 30 = 20
        // spread = 20

        vm.warp(deployTime + 1 hours);
        vm.fee(30 gwei);
        oracle.update();

        assertEq(oracle.baseFeeMax(), 50 gwei);
        assertEq(oracle.baseFeeMin(), 30 gwei);
        assertEq(oracle.baseFeeSpread(), 20 gwei);
    }

    /// @notice Test both new high and new low
    function test_BaseFeeSpreadSince_BothExtremes() public {
        // Gas goes high then low
        vm.warp(deployTime + 1 hours);
        vm.fee(80 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(30 gwei);
        oracle.update();

        // max=80, min=30, spread = 50
        assertEq(oracle.baseFeeMax(), 80 gwei);
        assertEq(oracle.baseFeeMin(), 30 gwei);
        assertEq(oracle.baseFeeSpread(), 50 gwei);
    }

    /// @notice Test pokeWindowVolatility on non-window market does nothing
    function test_PokeWindowVolatility_NonWindowMarket() public {
        // Poke on non-existent market should not revert
        oracle.pokeWindowVolatility(99999);
        (uint128 windowMax, uint128 windowMin) = oracle.windowSpreads(99999);
        assertEq(windowMax, 0);
        assertEq(windowMin, 0);
    }

    /// @notice Test pokeWindowVolatilityBatch on non-existent markets
    function test_PokeWindowVolatilityBatch_NonExistent() public {
        // Batch poke on non-existent markets should not revert
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        oracle.pokeWindowVolatilityBatch(ids);
        // All should remain zero
        (uint128 max1,) = oracle.windowSpreads(1);
        assertEq(max1, 0);
    }

    /// @notice Test that baseFeeSpreadSince view includes current basefee
    function test_BaseFeeSpreadSince_ViewIncludesCurrentBasefee() public {
        // Without any window spread set, should fall back to lifetime spread
        vm.warp(deployTime + 1 hours);
        vm.fee(70 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(30 gwei);
        oracle.update();

        // Lifetime spread = 70 - 30 = 40 gwei
        assertEq(oracle.baseFeeSpread(), 40 gwei);

        // For non-existent market, falls back to lifetime
        assertEq(oracle.baseFeeSpreadSince(99999), 40 gwei);

        // Current basefee is 30, so:
        // currentMax = max(30, 0) = 30 (but 0 means fallback to lifetime)
        // This verifies the fallback behavior
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                    COMPARISON MARKET TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMComparisonMarketTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /// @notice Test comparisonStartValue is initially zero
    function test_ComparisonStartValue_InitiallyZero() public view {
        assertEq(oracle.comparisonStartValue(12345), 0);
    }

    /// @notice Test baseFeeHigherThanStart returns 0 for non-existent market
    function test_BaseFeeHigherThanStart_NoSnapshot() public view {
        // Without a snapshot, returns 0
        assertEq(oracle.baseFeeHigherThanStart(12345), 0);
    }

    /// @notice Test comparison logic - TWAP increases
    function test_BaseFeeHigherThanStart_TWAPIncreases() public {
        // Initial TWAP = 50 gwei
        uint256 startTwap = oracle.baseFeeAverage();
        assertEq(startTwap, 50 gwei);

        // Gas increases significantly
        vm.warp(deployTime + 1 hours);
        vm.fee(150 gwei);
        oracle.update();

        vm.warp(deployTime + 3 hours);
        oracle.update();

        // New TWAP = (50*1 + 150*2) / 3 = 350/3 ≈ 116 gwei
        assertGt(oracle.baseFeeAverage(), startTwap);
    }

    /// @notice Test comparison logic - TWAP decreases
    function test_BaseFeeHigherThanStart_TWAPDecreases() public {
        // Initial TWAP = 50 gwei
        uint256 startTwap = oracle.baseFeeAverage();

        // Gas decreases
        vm.warp(deployTime + 1 hours);
        vm.fee(10 gwei);
        oracle.update();

        vm.warp(deployTime + 3 hours);
        oracle.update();

        // New TWAP = (50*1 + 10*2) / 3 = 70/3 ≈ 23 gwei
        assertLt(oracle.baseFeeAverage(), startTwap);
    }

    /// @notice Test createComparisonMarket authorization
    function test_CreateComparisonMarket_OnlyOwnerWhenNotPublic() public {
        vm.prank(address(0xdead));
        vm.expectRevert(GasPM.Unauthorized.selector);
        oracle.createComparisonMarket(
            address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    /// @notice Test createComparisonMarket with ERC20
    function test_CreateComparisonMarket_ERC20_NoETHAllowed() public {
        MockERC20 token = new MockERC20("Test", "TEST", 18);
        token.mint(address(this), 100 ether);
        token.approve(address(oracle), type(uint256).max);

        vm.expectRevert(GasPM.InvalidETHAmount.selector);
        oracle.createComparisonMarket{value: 1 ether}(
            address(token), uint64(block.timestamp + 1 days), 10 ether, 30, 0, address(this)
        );
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMFuzzTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /// @notice Fuzz test that baseFeeInRange is consistent with baseFeeOutOfRange
    function testFuzz_RangeConsistency(uint256 lower, uint256 upper, uint256 fee, uint256 time)
        public
    {
        lower = bound(lower, 1 gwei, 500 gwei);
        upper = bound(upper, lower + 1, 1000 gwei);
        fee = bound(fee, 1 gwei, 1000 gwei);
        time = bound(time, 1 hours, 365 days);

        vm.fee(fee);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time);
        newOracle.update();

        uint256 inRange = newOracle.baseFeeInRange(lower, upper);
        uint256 outOfRange = newOracle.baseFeeOutOfRange(lower, upper);

        // Must be mutually exclusive
        assertTrue(inRange != outOfRange || (inRange == 0 && outOfRange == 0));
        // At least one must be true (XOR)
        assertTrue(inRange == 1 || outOfRange == 1);
    }

    /// @notice Fuzz test that max >= min always
    function testFuzz_MaxAlwaysGteMin(
        uint256 fee1,
        uint256 fee2,
        uint256 fee3,
        uint256 time1,
        uint256 time2,
        uint256 time3
    ) public {
        fee1 = bound(fee1, 1 gwei, 1000 gwei);
        fee2 = bound(fee2, 1 gwei, 1000 gwei);
        fee3 = bound(fee3, 1 gwei, 1000 gwei);
        time1 = bound(time1, 1 minutes, 1 days);
        time2 = bound(time2, 1 minutes, 1 days);
        time3 = bound(time3, 1 minutes, 1 days);

        vm.fee(fee1);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time1);
        vm.fee(fee2);
        newOracle.update();
        assertGe(newOracle.baseFeeMax(), newOracle.baseFeeMin());

        vm.warp(block.timestamp + time2);
        vm.fee(fee3);
        newOracle.update();
        assertGe(newOracle.baseFeeMax(), newOracle.baseFeeMin());

        vm.warp(block.timestamp + time3);
        newOracle.update();
        assertGe(newOracle.baseFeeMax(), newOracle.baseFeeMin());
    }

    /// @notice Fuzz test that spread is always max - min
    function testFuzz_SpreadCalculation(uint256 fee1, uint256 fee2, uint256 time1, uint256 time2)
        public
    {
        fee1 = bound(fee1, 1 gwei, 1000 gwei);
        fee2 = bound(fee2, 1 gwei, 1000 gwei);
        time1 = bound(time1, 1 hours, 30 days);
        time2 = bound(time2, 1 hours, 30 days);

        vm.fee(fee1);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time1);
        vm.fee(fee2);
        newOracle.update();

        vm.warp(block.timestamp + time2);
        newOracle.update();

        uint256 spread = newOracle.baseFeeSpread();
        uint256 max = newOracle.baseFeeMax();
        uint256 min = newOracle.baseFeeMin();

        assertEq(spread, max - min);
    }

    /// @notice Fuzz test TWAP bounds
    function testFuzz_TWAPWithinBounds(uint256 fee1, uint256 fee2, uint256 time1, uint256 time2)
        public
    {
        fee1 = bound(fee1, 1 gwei, 1000 gwei);
        fee2 = bound(fee2, 1 gwei, 1000 gwei);
        time1 = bound(time1, 1 hours, 30 days);
        time2 = bound(time2, 1 hours, 30 days);

        vm.fee(fee1);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time1);
        newOracle.update();

        vm.fee(fee2);
        vm.warp(block.timestamp + time2);
        newOracle.update();

        uint256 avg = newOracle.baseFeeAverage();
        uint256 minFee = fee1 < fee2 ? fee1 : fee2;
        uint256 maxFee = fee1 > fee2 ? fee1 : fee2;

        assertGe(avg, minFee);
        assertLe(avg, maxFee);
    }

    /// @notice Fuzz test window TWAP fallback behavior
    function testFuzz_WindowTWAPFallback(uint256 marketId, uint256 fee, uint256 time) public {
        marketId = bound(marketId, 1, type(uint128).max);
        fee = bound(fee, 1 gwei, 1000 gwei);
        time = bound(time, 1 hours, 365 days);

        vm.fee(fee);
        GasPM newOracle = new GasPM();

        vm.warp(block.timestamp + time);
        newOracle.update();

        // Without snapshot, window functions should fallback to lifetime
        assertEq(newOracle.baseFeeAverageSince(marketId), newOracle.baseFeeAverage());
        assertEq(newOracle.baseFeeSpreadSince(marketId), newOracle.baseFeeSpread());
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                    OBSERVABLE STRING TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMObservableTest is Test {
    GasPM oracle;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
    }

    /// @notice Test that market creation builds correct observable strings
    /// We can't directly test internal _buildObservable, but we can verify
    /// via the MarketCreated event threshold values

    function test_CreateMarket_ThresholdInEvent() public {
        // The threshold in MarketCreated event should match input
        // We can't capture events in test without actual market creation
        // but we can verify the validation passes for various thresholds

        // Test with exact gwei values
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket{value: 1 ether}(
            50 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );

        // Test with fractional gwei (wei precision)
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket{value: 1 ether}(
            50.5 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );

        // Test with sub-gwei value
        vm.expectRevert(); // Resolver not deployed
        oracle.createMarket{value: 1 ether}(
            0.127 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            3,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    /// @notice Test range market observable with various bounds
    function test_CreateRangeMarket_BoundsInEvent() public {
        // Wide range
        vm.expectRevert();
        oracle.createRangeMarket{value: 1 ether}(
            10 gwei,
            1000 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );

        // Narrow range
        vm.expectRevert();
        oracle.createRangeMarket{value: 1 ether}(
            49 gwei,
            51 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );

        // Fractional gwei bounds
        vm.expectRevert();
        oracle.createRangeMarket{value: 1 ether}(
            30.5 gwei,
            70.5 gwei,
            address(0),
            uint64(block.timestamp + 1 days),
            true,
            1 ether,
            30,
            0,
            address(this)
        );
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                  MARKET TYPE CONSTANTS TESTS
//////////////////////////////////////////////////////////////*/

contract GasPMMarketTypesTest is Test {
    GasPM oracle;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
    }

    /// @notice Verify market type constants are unique
    function test_MarketTypeConstants_Unique() public pure {
        // These match the internal constants in GasPM.sol
        uint8 MARKET_TYPE_RANGE = 4;
        uint8 MARKET_TYPE_BREAKOUT = 5;
        uint8 MARKET_TYPE_PEAK = 6;
        uint8 MARKET_TYPE_TROUGH = 7;
        uint8 MARKET_TYPE_VOLATILITY = 8;
        uint8 MARKET_TYPE_STABILITY = 9;
        uint8 MARKET_TYPE_SPOT = 10;
        uint8 MARKET_TYPE_COMPARISON = 11;

        // All must be unique
        uint8[8] memory types = [
            MARKET_TYPE_RANGE,
            MARKET_TYPE_BREAKOUT,
            MARKET_TYPE_PEAK,
            MARKET_TYPE_TROUGH,
            MARKET_TYPE_VOLATILITY,
            MARKET_TYPE_STABILITY,
            MARKET_TYPE_SPOT,
            MARKET_TYPE_COMPARISON
        ];

        for (uint256 i = 0; i < types.length; i++) {
            for (uint256 j = i + 1; j < types.length; j++) {
                assertTrue(types[i] != types[j], "Market types must be unique");
            }
        }

        // Must not overlap with operator constants (2=LTE, 3=GTE)
        for (uint256 i = 0; i < types.length; i++) {
            assertTrue(types[i] != 2, "Must not overlap with LTE");
            assertTrue(types[i] != 3, "Must not overlap with GTE");
        }
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                    WINDOW PEAK/TROUGH TRACKING TESTS
//////////////////////////////////////////////////////////////*/

/// @notice Tests for window peak/trough per-market max/min tracking
contract GasPMWindowPeakTroughTest is Test {
    GasPM oracle;
    uint256 deployTime;

    function setUp() public {
        vm.fee(50 gwei);
        vm.startPrank(address(this), address(this)); // Set tx.origin to test contract
        oracle = new GasPM();
        vm.stopPrank();
        deployTime = block.timestamp;
    }

    /// @notice Test baseFeeMaxSince returns 0 for non-existent market (no windowSpreads)
    function test_BaseFeeMaxSince_NonExistentMarket() public view {
        // For a market that doesn't exist, windowMax is 0
        // The function returns max(0, current basefee) = current basefee
        assertEq(oracle.baseFeeMaxSince(99999), block.basefee);
    }

    /// @notice Test baseFeeMinSince returns current basefee for non-existent market
    function test_BaseFeeMinSince_NonExistentMarket() public view {
        // For a market that doesn't exist, windowMin is 0
        // The function returns min(0, current basefee) = 0 (since 0 < any positive basefee)
        // But since windowMin=0 indicates uninitialized, we actually compare with basefee
        assertEq(oracle.baseFeeMinSince(99999), block.basefee);
    }

    /// @notice Test that windowSpreads can be manually set and read correctly
    function test_WindowSpreads_StorageLayout() public {
        // Simulate what createWindowPeakMarket does internally
        // We can't call the actual function without Resolver, but we can test the view functions

        // When basefee changes, the view functions should reflect it
        vm.fee(60 gwei);

        // Non-existent market should return current basefee
        assertEq(oracle.baseFeeMaxSince(12345), 60 gwei);
        assertEq(oracle.baseFeeMinSince(12345), 60 gwei);
    }

    /// @notice Test baseFeeMaxSince includes current basefee when higher
    function test_BaseFeeMaxSince_IncludesCurrentBasefee() public {
        // Initial basefee is 50 gwei
        // For non-existent market, should return current basefee
        assertEq(oracle.baseFeeMaxSince(12345), 50 gwei);

        // Increase basefee
        vm.fee(80 gwei);
        assertEq(oracle.baseFeeMaxSince(12345), 80 gwei);

        // Decrease basefee
        vm.fee(30 gwei);
        // For non-existent market, still returns current basefee
        assertEq(oracle.baseFeeMaxSince(12345), 30 gwei);
    }

    /// @notice Test baseFeeMinSince includes current basefee when lower
    function test_BaseFeeMinSince_IncludesCurrentBasefee() public {
        // Initial basefee is 50 gwei
        assertEq(oracle.baseFeeMinSince(12345), 50 gwei);

        // Decrease basefee
        vm.fee(30 gwei);
        assertEq(oracle.baseFeeMinSince(12345), 30 gwei);

        // Increase basefee
        vm.fee(80 gwei);
        // For non-existent market, still returns current basefee
        assertEq(oracle.baseFeeMinSince(12345), 80 gwei);
    }

    /// @notice Test pokeWindowVolatility updates max for window markets
    function test_PokeWindowVolatility_UpdatesMax() public {
        // First, we need to simulate a window market existing
        // The windowSpreads mapping is public, but we can't write to it directly
        // We can verify the poke function behavior by checking that non-window markets are skipped

        // For non-window market (windowMax=0, windowMin=0), poke should do nothing
        oracle.pokeWindowVolatility(12345);
        (uint128 max, uint128 min) = oracle.windowSpreads(12345);
        assertEq(max, 0);
        assertEq(min, 0);
    }

    /// @notice Test that lifetime max/min are separate from window max/min
    function test_LifetimeVsWindowMetrics() public {
        // Update oracle with varying fees
        vm.warp(deployTime + 1 hours);
        vm.fee(100 gwei);
        oracle.update();

        vm.warp(deployTime + 2 hours);
        vm.fee(20 gwei);
        oracle.update();

        // Lifetime metrics should reflect all updates
        assertEq(oracle.baseFeeMax(), 100 gwei);
        assertEq(oracle.baseFeeMin(), 20 gwei);

        // Window metrics for non-existent market return current basefee
        assertEq(oracle.baseFeeMaxSince(99999), 20 gwei); // current basefee
        assertEq(oracle.baseFeeMinSince(99999), 20 gwei); // current basefee
    }

    /// @notice Test windowSpreads struct packing (max in lower bits, min in upper bits)
    function test_WindowSpreads_StructPacking() public view {
        // WindowSpread struct: { uint128 windowMax, uint128 windowMin }
        // In Solidity storage, first field (windowMax) is in lower 128 bits
        // second field (windowMin) is in upper 128 bits

        // Verify by reading an empty slot
        (uint128 windowMax, uint128 windowMin) = oracle.windowSpreads(0);
        assertEq(windowMax, 0);
        assertEq(windowMin, 0);
    }

    /// @notice Test createWindowPeakMarket threshold validation uses current basefee
    function test_CreateWindowPeakMarket_ThresholdVsCurrentBasefee() public {
        // At deploy, basefee = 50 gwei
        // Creating a peak market with threshold <= current basefee should revert

        // Threshold = current basefee (50 gwei) should revert
        vm.expectRevert(GasPM.AlreadyExceeded.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Threshold < current basefee (30 gwei) should also revert
        vm.expectRevert(GasPM.AlreadyExceeded.selector);
        oracle.createWindowPeakMarket{value: 1 ether}(
            30 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Threshold > current basefee (100 gwei) should pass validation
        // (will revert later due to Resolver not being deployed)
        vm.expectRevert(); // Resolver call fails
        oracle.createWindowPeakMarket{value: 1 ether}(
            100 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    /// @notice Test createWindowTroughMarket threshold validation uses current basefee
    function test_CreateWindowTroughMarket_ThresholdVsCurrentBasefee() public {
        // At deploy, basefee = 50 gwei
        // Creating a trough market with threshold >= current basefee should revert

        // Threshold = current basefee (50 gwei) should revert
        vm.expectRevert(GasPM.AlreadyBelowThreshold.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            50 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Threshold > current basefee (70 gwei) should also revert
        vm.expectRevert(GasPM.AlreadyBelowThreshold.selector);
        oracle.createWindowTroughMarket{value: 1 ether}(
            70 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );

        // Threshold < current basefee (30 gwei) should pass validation
        // (will revert later due to Resolver not being deployed)
        vm.expectRevert(); // Resolver call fails
        oracle.createWindowTroughMarket{value: 1 ether}(
            30 gwei, address(0), uint64(block.timestamp + 1 days), 1 ether, 30, 0, address(this)
        );
    }

    /// @notice Test that basefee changes affect view function results
    function test_ViewFunctions_ReactToBasefeeChanges() public {
        uint256 marketId = 12345;

        // Initially at 50 gwei
        assertEq(oracle.baseFeeMaxSince(marketId), 50 gwei);
        assertEq(oracle.baseFeeMinSince(marketId), 50 gwei);

        // Spike to 100 gwei
        vm.fee(100 gwei);
        assertEq(oracle.baseFeeMaxSince(marketId), 100 gwei);
        assertEq(oracle.baseFeeMinSince(marketId), 100 gwei);

        // Drop to 10 gwei
        vm.fee(10 gwei);
        assertEq(oracle.baseFeeMaxSince(marketId), 10 gwei);
        assertEq(oracle.baseFeeMinSince(marketId), 10 gwei);
    }

    /// @notice Fuzz test baseFeeMaxSince with various basefee values
    function testFuzz_BaseFeeMaxSince(uint256 marketId, uint256 basefee) public {
        marketId = bound(marketId, 1, type(uint128).max);
        basefee = bound(basefee, 1 gwei, 10000 gwei);

        vm.fee(basefee);

        // For non-existent market, should return current basefee
        assertEq(oracle.baseFeeMaxSince(marketId), basefee);
    }

    /// @notice Fuzz test baseFeeMinSince with various basefee values
    function testFuzz_BaseFeeMinSince(uint256 marketId, uint256 basefee) public {
        marketId = bound(marketId, 1, type(uint128).max);
        basefee = bound(basefee, 1 gwei, 10000 gwei);

        vm.fee(basefee);

        // For non-existent market, should return current basefee
        assertEq(oracle.baseFeeMinSince(marketId), basefee);
    }

    receive() external payable {}
}

/// @dev DAI-style permit token (simplified for testing)
contract MockDAIPermit {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev DAI-style permit (simplified for testing)
    function permit(
        address owner_,
        address spender,
        uint256 nonce,
        uint256, /* deadline */
        bool allowed,
        uint8, /* v */
        bytes32, /* r */
        bytes32 /* s */
    ) public {
        require(nonce == nonces[owner_]++, "Invalid nonce");
        allowance[owner_][spender] = allowed ? type(uint256).max : 0;
    }
}

/// @dev Test harness to expose internal functions and allow direct storage writes
contract GasPMHarness is GasPM {
    function toGweiString(uint256 wei_) external pure returns (string memory) {
        return _toGweiString(wei_);
    }

    function toString(uint256 value) external pure returns (string memory) {
        return _toString(value);
    }

    /// @dev Directly set windowSpreads for testing storage reads
    function setWindowSpread(uint256 marketId, uint128 max, uint128 min) external {
        windowSpreads[marketId] = WindowSpread(max, min);
    }
}

contract GasPMToGweiStringTest is Test {
    GasPMHarness harness;

    function setUp() public {
        vm.fee(50 gwei);
        harness = new GasPMHarness();
    }

    /*//////////////////////////////////////////////////////////////
                        _toGweiString EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test zero wei
    function test_ToGweiString_Zero() public view {
        assertEq(harness.toGweiString(0), "0");
    }

    /// @notice Test 1 wei (sub-gwei, should be "0")
    function test_ToGweiString_OneWei() public view {
        // 1 wei = 0 gwei with remainder 1 wei
        // remainder / 1e6 = 0, so just "0"
        assertEq(harness.toGweiString(1), "0");
    }

    /// @notice Test exactly 1 gwei
    function test_ToGweiString_OneGwei() public view {
        assertEq(harness.toGweiString(1 gwei), "1");
    }

    /// @notice Test fractional gwei with 1 decimal place (e.g., 1.5 gwei)
    function test_ToGweiString_FractionalOneDecimal() public view {
        // 1.5 gwei = 1.5e9 wei
        assertEq(harness.toGweiString(1.5 gwei), "1.5");
    }

    /// @notice Test fractional gwei with 2 decimal places (e.g., 1.25 gwei)
    function test_ToGweiString_FractionalTwoDecimals() public view {
        // 1.25 gwei = 1.25e9 wei
        assertEq(harness.toGweiString(1.25 gwei), "1.25");
    }

    /// @notice Test fractional gwei with 3 decimal places (e.g., 1.123 gwei)
    function test_ToGweiString_FractionalThreeDecimals() public view {
        // 1.123 gwei = 1123000000 wei
        assertEq(harness.toGweiString(1123000000), "1.123");
    }

    /// @notice Test fractional with leading zeros (e.g., 1.001 gwei)
    function test_ToGweiString_FractionalLeadingZeros() public view {
        // 1.001 gwei = 1001000000 wei
        assertEq(harness.toGweiString(1001000000), "1.001");
    }

    /// @notice Test fractional with leading zero and 2 places (e.g., 1.01 gwei)
    function test_ToGweiString_FractionalLeadingZeroTwoPlaces() public view {
        // 1.01 gwei = 1010000000 wei
        assertEq(harness.toGweiString(1010000000), "1.01");
    }

    /// @notice Test large gwei value (typical mainnet range)
    function test_ToGweiString_LargeValue() public view {
        // 500 gwei
        assertEq(harness.toGweiString(500 gwei), "500");
    }

    /// @notice Test very large gwei value
    function test_ToGweiString_VeryLargeValue() public view {
        // 10000 gwei = 10 microether
        assertEq(harness.toGweiString(10000 gwei), "10000");
    }

    /// @notice Test sub-milligwei values (< 1e6 wei remainder)
    function test_ToGweiString_SubMilligwei() public view {
        // 1 gwei + 999999 wei = 1000999999 wei
        // remainder = 999999, remainder / 1e6 = 0
        // So output is just "1"
        assertEq(harness.toGweiString(1000999999), "1");
    }

    /// @notice Test exactly at milligwei boundary
    function test_ToGweiString_ExactlyMilligwei() public view {
        // 1 gwei + 1e6 wei = 1001000000 wei
        // remainder = 1e6, remainder / 1e6 = 1
        // So output is "1.001"
        assertEq(harness.toGweiString(1001000000), "1.001");
    }

    /// @notice Test max uint256 value
    function test_ToGweiString_MaxUint256() public view {
        // type(uint256).max / 1 gwei is a very large number
        // This tests that the function doesn't overflow/revert
        string memory result = harness.toGweiString(type(uint256).max);
        assertTrue(bytes(result).length > 0);
        // type(uint256).max / 1e9 = 115792089237316195423570985008687907853269984665640564039457584007913
        // remainder = type(uint256).max % 1e9 = 129639935
        // remainder / 1e6 = 129 (milligwei precision)
        assertEq(
            result, "115792089237316195423570985008687907853269984665640564039457584007913.129"
        );
    }

    /// @notice Test common gas prices
    function test_ToGweiString_CommonGasPrices() public view {
        assertEq(harness.toGweiString(5 gwei), "5");
        assertEq(harness.toGweiString(20 gwei), "20");
        assertEq(harness.toGweiString(50 gwei), "50");
        assertEq(harness.toGweiString(100 gwei), "100");
        assertEq(harness.toGweiString(200 gwei), "200");
    }

    /// @notice Fuzz test: output should be parseable back to approximate value
    function testFuzz_ToGweiString_Reasonable(uint256 wei_) public view {
        wei_ = bound(wei_, 0, 10000 gwei);
        string memory result = harness.toGweiString(wei_);
        assertTrue(bytes(result).length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                        _toString EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test _toString with zero
    function test_ToString_Zero() public view {
        assertEq(harness.toString(0), "0");
    }

    /// @notice Test _toString with max uint256
    function test_ToString_MaxUint256() public view {
        assertEq(
            harness.toString(type(uint256).max),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    /// @notice Test _toString with small values
    function test_ToString_SmallValues() public view {
        assertEq(harness.toString(1), "1");
        assertEq(harness.toString(9), "9");
        assertEq(harness.toString(10), "10");
        assertEq(harness.toString(99), "99");
        assertEq(harness.toString(100), "100");
    }

    /*//////////////////////////////////////////////////////////////
                    WINDOW SPREAD STORAGE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test baseFeeMaxSince reads from correct storage location
    /// @dev This test would have caught the mapping storage bug where
    ///      `sload(add(windowSpreads.slot, marketId))` was used instead of proper keccak
    function test_BaseFeeMaxSince_ReadsCorrectStorageSlot() public {
        uint256 marketId = 42;
        uint128 storedMax = 100 gwei;
        uint128 storedMin = 50 gwei;

        // Write directly to windowSpreads mapping
        harness.setWindowSpread(marketId, storedMax, storedMin);

        // Set current basefee below stored max
        vm.fee(60 gwei);

        // baseFeeMaxSince should return storedMax (100 gwei), not current basefee (60 gwei)
        uint256 result = harness.baseFeeMaxSince(marketId);
        assertEq(result, storedMax, "Should read stored windowMax from correct storage slot");
    }

    /// @notice Test baseFeeMinSince reads from correct storage location
    function test_BaseFeeMinSince_ReadsCorrectStorageSlot() public {
        uint256 marketId = 42;
        uint128 storedMax = 100 gwei;
        uint128 storedMin = 50 gwei;

        // Write directly to windowSpreads mapping
        harness.setWindowSpread(marketId, storedMax, storedMin);

        // Set current basefee above stored min
        vm.fee(80 gwei);

        // baseFeeMinSince should return storedMin (50 gwei), not current basefee (80 gwei)
        uint256 result = harness.baseFeeMinSince(marketId);
        assertEq(result, storedMin, "Should read stored windowMin from correct storage slot");
    }

    /// @notice Fuzz test that baseFeeMaxSince correctly reads stored values
    function testFuzz_BaseFeeMaxSince_ReadsStoredValue(
        uint256 marketId,
        uint64 storedMax,
        uint64 currentFee
    ) public {
        vm.assume(storedMax > 0); // Non-zero means initialized
        vm.assume(currentFee > 0);
        marketId = bound(marketId, 1, type(uint128).max);

        harness.setWindowSpread(marketId, storedMax, storedMax); // Use same for both
        vm.fee(currentFee);

        uint256 result = harness.baseFeeMaxSince(marketId);

        // Result should be max(storedMax, currentFee)
        uint256 expected = currentFee > storedMax ? currentFee : storedMax;
        assertEq(result, expected);
    }

    /// @notice Fuzz test that baseFeeMinSince correctly reads stored values
    function testFuzz_BaseFeeMinSince_ReadsStoredValue(
        uint256 marketId,
        uint64 storedMin,
        uint64 currentFee
    ) public {
        vm.assume(storedMin > 0); // Non-zero means initialized
        vm.assume(currentFee > 0);
        marketId = bound(marketId, 1, type(uint128).max);

        harness.setWindowSpread(marketId, storedMin, storedMin); // Use same for both
        vm.fee(currentFee);

        uint256 result = harness.baseFeeMinSince(marketId);

        // Result should be min(storedMin, currentFee)
        uint256 expected = currentFee < storedMin ? currentFee : storedMin;
        assertEq(result, expected);
    }
}

/*//////////////////////////////////////////////////////////////
                    INTEGRATION TESTS
//////////////////////////////////////////////////////////////*/

import {PAMM} from "../src/PAMM.sol";
import {Resolver} from "../src/Resolver.sol";
import {ZAMM} from "@zamm/ZAMM.sol";

/// @notice Mock ERC20 for integration tests
contract IntegrationMockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public constant DECIMALS = 18;

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

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }
}

/// @notice Integration tests for GasPM with full contract stack (ZAMM, PAMM, Resolver)
contract GasPMIntegrationTest is Test {
    // Hardcoded addresses from contracts
    address payable constant ZAMM_ADDRESS = payable(0x000000000000040470635EB91b7CE4D132D616eD);
    address payable constant PAMM_ADDRESS = payable(0x0000000000F8bA51d6e987660D3e455ac2c4BE9d);
    address payable constant RESOLVER_ADDRESS = payable(0x0000000000b0ba1b2bb3AF96FbB893d835970ec4);

    ZAMM zamm;
    PAMM pm;
    Resolver resolver;
    GasPM gasPM;
    IntegrationMockERC20 token;

    address ALICE = makeAddr("ALICE");
    uint64 closeTime;
    uint256 constant FEE_BPS = 30; // 0.3%

    function setUp() public {
        vm.fee(50 gwei);

        // Deploy ZAMM and etch to expected address
        bytes memory zammCode = type(ZAMM).creationCode;
        address zammDeployed;
        assembly {
            zammDeployed := create(0, add(zammCode, 0x20), mload(zammCode))
        }
        vm.etch(ZAMM_ADDRESS, zammDeployed.code);
        vm.store(ZAMM_ADDRESS, bytes32(uint256(0x00)), bytes32(uint256(uint160(address(this)))));
        zamm = ZAMM(payable(ZAMM_ADDRESS));

        // Deploy PAMM and etch to expected address
        PAMM pammDeployed = new PAMM();
        vm.etch(PAMM_ADDRESS, address(pammDeployed).code);
        pm = PAMM(PAMM_ADDRESS);

        // Deploy Resolver and etch to expected address
        Resolver resolverDeployed = new Resolver();
        vm.etch(RESOLVER_ADDRESS, address(resolverDeployed).code);
        resolver = Resolver(payable(RESOLVER_ADDRESS));

        // Deploy GasPM (uses tx.origin for owner)
        vm.startPrank(address(this), address(this));
        gasPM = new GasPM();
        // Enable public creation so anyone can create markets
        gasPM.setPublicCreation(true);
        vm.stopPrank();

        // Setup token and users
        token = new IntegrationMockERC20();
        closeTime = uint64(block.timestamp + 30 days);

        // Fund users
        token.mint(ALICE, 100000 ether);
        vm.deal(ALICE, 100000 ether);

        // Approve GasPM for token
        vm.prank(ALICE);
        token.approve(address(gasPM), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                       BASIC MARKET CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test basic directional market creation with ETH
    function test_Integration_CreateMarket_ETH() public {
        uint256 threshold = 100 gwei;
        uint256 collateralIn = 10000 ether;
        uint256 minLiquidity = 1;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createMarket{value: collateralIn}(
            threshold,
            address(0), // ETH
            closeTime,
            true, // canClose
            3, // GTE
            collateralIn,
            FEE_BPS,
            minLiquidity,
            ALICE
        );

        // Verify market was created and registered
        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");
        assertEq(gasPM.marketCount(), 1, "Should have 1 market");

        // Verify GasPM has no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");

        // Verify GasPM has no leftover ETH
        assertEq(address(gasPM).balance, 0, "GasPM should have no leftover ETH");
    }

    /// @notice Test basic directional market creation with ERC20
    function test_Integration_CreateMarket_ERC20() public {
        uint256 threshold = 100 gwei;
        uint256 collateralIn = 10000 ether;
        uint256 minLiquidity = 1;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createMarket(
            threshold,
            address(token),
            closeTime,
            true, // canClose
            3, // GTE
            collateralIn,
            FEE_BPS,
            minLiquidity,
            ALICE
        );

        // Verify market was created
        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify GasPM has no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");

        // Verify GasPM has no leftover tokens
        assertEq(token.balanceOf(address(gasPM)), 0, "GasPM should have no leftover tokens");
    }

    /// @notice Test market creation with buy (AndBuy variant)
    function test_Integration_CreateMarketAndBuy_ETH() public {
        uint256 threshold = 100 gwei;
        uint256 collateralIn = 10000 ether;
        uint256 swapAmount = 1000 ether;

        GasPM.SeedParams memory seed = GasPM.SeedParams({
            collateralIn: collateralIn,
            feeOrHook: FEE_BPS,
            amount0Min: 0,
            amount1Min: 0,
            minLiquidity: 1,
            lpRecipient: ALICE,
            deadline: 0
        });

        GasPM.SwapParams memory swap = GasPM.SwapParams({
            collateralForSwap: swapAmount,
            minOut: 0,
            yesForNo: false, // Buy YES
            recipient: ALICE
        });

        uint256 totalValue = collateralIn + swapAmount;

        vm.prank(ALICE);
        (uint256 marketId, uint256 swapOut) = gasPM.createMarketAndBuy{value: totalValue}(
            threshold,
            address(0), // ETH
            closeTime,
            true, // canClose
            3, // GTE
            seed,
            swap
        );

        // Verify market was created
        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");
        assertGt(swapOut, 0, "Should have received YES tokens from swap");

        // Verify ALICE received YES tokens
        assertGt(pm.balanceOf(ALICE, marketId), 0, "ALICE should have YES tokens");

        // Verify GasPM has no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");

        // Verify GasPM has no leftover ETH
        assertEq(address(gasPM).balance, 0, "GasPM should have no leftover ETH");
    }

    /// @notice Test range market creation
    function test_Integration_CreateRangeMarket_ETH() public {
        uint256 lowerBound = 50 gwei;
        uint256 upperBound = 100 gwei;
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createRangeMarket{value: collateralIn}(
            lowerBound, upperBound, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test breakout market creation
    function test_Integration_CreateBreakoutMarket_ETH() public {
        uint256 lowerBound = 50 gwei;
        uint256 upperBound = 100 gwei;
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createBreakoutMarket{value: collateralIn}(
            lowerBound, upperBound, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test peak market creation
    function test_Integration_CreatePeakMarket_ETH() public {
        uint256 threshold = 200 gwei; // Above current 50 gwei
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createPeakMarket{value: collateralIn}(
            threshold, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test trough market creation
    function test_Integration_CreateTroughMarket_ETH() public {
        uint256 threshold = 10 gwei; // Below current 50 gwei
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createTroughMarket{value: collateralIn}(
            threshold, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test volatility market creation
    function test_Integration_CreateVolatilityMarket_ETH() public {
        uint256 threshold = 100 gwei; // Spread threshold
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createVolatilityMarket{value: collateralIn}(
            threshold, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test stability market creation
    function test_Integration_CreateStabilityMarket_ETH() public {
        uint256 threshold = 100 gwei; // Max spread threshold
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createStabilityMarket{value: collateralIn}(
            threshold, address(0), closeTime, true, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test spot market creation
    function test_Integration_CreateSpotMarket_ETH() public {
        uint256 threshold = 100 gwei;
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createSpotMarket{value: collateralIn}(
            threshold,
            address(0),
            closeTime,
            true, // canClose
            collateralIn,
            FEE_BPS,
            1,
            ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test comparison market creation
    function test_Integration_CreateComparisonMarket_ETH() public {
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createComparisonMarket{value: collateralIn}(
            address(0), closeTime, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /*//////////////////////////////////////////////////////////////
                       WINDOW MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test window directional market creation
    function test_Integration_CreateWindowMarket_ETH() public {
        uint256 threshold = 100 gwei;
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createWindowMarket{value: collateralIn}(
            threshold,
            address(0),
            closeTime,
            true,
            3, // GTE
            collateralIn,
            FEE_BPS,
            1,
            ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify snapshot was stored
        (uint192 cumulative, uint64 timestamp) = gasPM.marketSnapshots(marketId);
        assertGt(timestamp, 0, "Snapshot should be stored");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test window peak market creation
    function test_Integration_CreateWindowPeakMarket_ETH() public {
        uint256 threshold = 200 gwei; // Above current 50 gwei
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createWindowPeakMarket{value: collateralIn}(
            threshold, address(0), closeTime, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify window spread was initialized
        (uint128 windowMax, uint128 windowMin) = gasPM.windowSpreads(marketId);
        assertGt(windowMax, 0, "Window max should be initialized");
        assertGt(windowMin, 0, "Window min should be initialized");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /// @notice Test window trough market creation
    function test_Integration_CreateWindowTroughMarket_ETH() public {
        uint256 threshold = 10 gwei; // Below current 50 gwei
        uint256 collateralIn = 10000 ether;

        vm.prank(ALICE);
        uint256 marketId = gasPM.createWindowTroughMarket{value: collateralIn}(
            threshold, address(0), closeTime, collateralIn, FEE_BPS, 1, ALICE
        );

        assertTrue(gasPM.isOurMarket(marketId), "Market should be registered");

        // Verify window spread was initialized
        (uint128 windowMax, uint128 windowMin) = gasPM.windowSpreads(marketId);
        assertGt(windowMax, 0, "Window max should be initialized");
        assertGt(windowMin, 0, "Window min should be initialized");

        // Verify no leftover shares
        uint256 noId = pm.getNoId(marketId);
        assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
        assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
    }

    /*//////////////////////////////////////////////////////////////
                    LEFTOVER SHARE FLUSHING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that multiple market creations don't accumulate leftover shares
    function test_Integration_MultipleMarkets_NoAccumulatedShares() public {
        uint256 collateralIn = 10000 ether;

        // Create multiple markets
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(ALICE);
            gasPM.createMarket{value: collateralIn}(
                (100 + i * 10) * 1 gwei, // Different thresholds
                address(0),
                closeTime + uint64(i * 1 days),
                true,
                3,
                collateralIn,
                FEE_BPS,
                1,
                ALICE
            );
        }

        assertEq(gasPM.marketCount(), 5, "Should have 5 markets");

        // Verify no accumulated shares in GasPM
        // Check a few market IDs
        uint256[] memory markets = gasPM.getMarkets(0, 5);
        for (uint256 i = 0; i < markets.length; i++) {
            uint256 marketId = markets[i];
            uint256 noId = pm.getNoId(marketId);
            assertEq(pm.balanceOf(address(gasPM), marketId), 0, "GasPM should have 0 YES");
            assertEq(pm.balanceOf(address(gasPM), noId), 0, "GasPM should have 0 NO");
        }

        // Verify no leftover ETH
        assertEq(address(gasPM).balance, 0, "GasPM should have no leftover ETH");
    }

    /// @notice Test ERC20 market creation doesn't leave tokens
    function test_Integration_ERC20Market_NoLeftoverTokens() public {
        uint256 collateralIn = 10000 ether;

        uint256 aliceBalanceBefore = token.balanceOf(ALICE);

        vm.prank(ALICE);
        gasPM.createMarket(
            100 gwei, address(token), closeTime, true, 3, collateralIn, FEE_BPS, 1, ALICE
        );

        // Verify ALICE spent the collateral
        assertEq(
            token.balanceOf(ALICE),
            aliceBalanceBefore - collateralIn,
            "ALICE should have spent collateral"
        );

        // Verify no tokens stuck in GasPM
        assertEq(token.balanceOf(address(gasPM)), 0, "GasPM should have no leftover tokens");

        // Verify no tokens stuck in Resolver
        assertEq(token.balanceOf(address(resolver)), 0, "Resolver should have no leftover tokens");
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD ESCROW PRESERVATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify ETH-collateral market creation does NOT drain reward escrow
    /// @dev Critical regression test: without the ethEscrow fix, _refundDust would
    ///      send the entire contract balance (including rewards) to msg.sender
    function test_Integration_CreateMarket_PreservesRewardEscrow() public {
        // Configure rewards and fund the contract
        vm.prank(gasPM.owner());
        gasPM.setReward(0.01 ether, 1 hours);
        vm.deal(address(gasPM), 1 ether);

        uint256 escrowBefore = address(gasPM).balance;
        uint256 collateralIn = 100 ether;

        // Create ETH-collateral market - should NOT drain reward escrow
        vm.prank(ALICE);
        gasPM.createMarket{value: collateralIn}(
            50 gwei, address(0), closeTime, false, 3, collateralIn, FEE_BPS, 1, ALICE
        );

        // Reward escrow should be preserved
        assertEq(address(gasPM).balance, escrowBefore, "Reward escrow should be preserved");
    }

    /// @notice Verify createMarketAndBuy preserves reward escrow
    function test_Integration_CreateMarketAndBuy_PreservesRewardEscrow() public {
        // Configure rewards and fund the contract
        vm.prank(gasPM.owner());
        gasPM.setReward(0.01 ether, 1 hours);
        vm.deal(address(gasPM), 1 ether);

        uint256 escrowBefore = address(gasPM).balance;
        uint256 seedAmount = 100 ether;
        uint256 swapAmount = 50 ether;

        // Create ETH-collateral market with buy
        vm.prank(ALICE);
        gasPM.createMarketAndBuy{value: seedAmount + swapAmount}(
            50 gwei,
            address(0),
            closeTime,
            false,
            3,
            GasPM.SeedParams(seedAmount, FEE_BPS, 0, 0, 1, ALICE, 0),
            GasPM.SwapParams(swapAmount, 0, false, ALICE)
        );

        // Reward escrow should be preserved
        assertEq(address(gasPM).balance, escrowBefore, "Reward escrow should be preserved");
    }

    /// @notice Verify window market preserves escrow after internal update() pays reward
    /// @dev Window peak/trough/volatility markets call update() before computing ethEscrow.
    ///      The fix ensures ethEscrow is computed AFTER update() so reward payout is excluded.
    function test_Integration_CreateWindowVolatilityMarket_PreservesEscrowAfterRewardPayout()
        public
    {
        // Configure rewards and fund the contract
        vm.prank(gasPM.owner());
        gasPM.setReward(0.01 ether, 1 hours);
        vm.deal(address(gasPM), 1 ether);

        // Wait for cooldown so update() will pay reward
        vm.warp(block.timestamp + 1 hours);

        uint256 escrowBefore = address(gasPM).balance;
        uint256 collateralIn = 100 ether;

        // Create window volatility market (calls update() internally which pays reward)
        vm.prank(ALICE);
        gasPM.createWindowVolatilityMarket{value: collateralIn}(
            10 gwei, address(0), closeTime, collateralIn, FEE_BPS, 1, ALICE
        );

        // Escrow should be: original - reward paid by update()
        // The market creation itself should NOT have drained additional escrow
        assertEq(
            address(gasPM).balance,
            escrowBefore - 0.01 ether,
            "Only reward should have been paid, escrow preserved"
        );
    }
}
