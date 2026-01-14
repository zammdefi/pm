// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";

/// @title PMHookRouterSelectors
/// @notice Verify all function and error selectors used in PMHookRouter assembly
contract PMHookRouterSelectorsTest is Test {
    // ============ Error Selector Verification ============

    error ValidationError(uint8 code);
    error TimingError(uint8 code);
    error StateError(uint8 code);
    error TransferError(uint8 code);
    error ComputationError(uint8 code);
    error SharesError(uint8 code);
    error Reentrancy();
    error ApproveFailed();
    error WithdrawalTooSoon(uint256 remainingSeconds);

    // Expected selectors from PMHookRouter.sol
    bytes4 constant ERR_SHARES = 0x9325dafd;
    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_COMPUTATION = 0x05832717;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_TRANSFER = 0x2929f974;

    function test_ErrorSelector_ValidationError() public pure {
        assertEq(ValidationError.selector, ERR_VALIDATION, "ValidationError selector mismatch");
        assertEq(ValidationError.selector, bytes4(keccak256("ValidationError(uint8)")));
    }

    function test_ErrorSelector_TimingError() public pure {
        assertEq(TimingError.selector, ERR_TIMING, "TimingError selector mismatch");
        assertEq(TimingError.selector, bytes4(keccak256("TimingError(uint8)")));
    }

    function test_ErrorSelector_StateError() public pure {
        assertEq(StateError.selector, ERR_STATE, "StateError selector mismatch");
        assertEq(StateError.selector, bytes4(keccak256("StateError(uint8)")));
    }

    function test_ErrorSelector_TransferError() public pure {
        assertEq(TransferError.selector, ERR_TRANSFER, "TransferError selector mismatch");
        assertEq(TransferError.selector, bytes4(keccak256("TransferError(uint8)")));
    }

    function test_ErrorSelector_ComputationError() public pure {
        assertEq(ComputationError.selector, ERR_COMPUTATION, "ComputationError selector mismatch");
        assertEq(ComputationError.selector, bytes4(keccak256("ComputationError(uint8)")));
    }

    function test_ErrorSelector_SharesError() public pure {
        assertEq(SharesError.selector, ERR_SHARES, "SharesError selector mismatch");
        assertEq(SharesError.selector, bytes4(keccak256("SharesError(uint8)")));
    }

    function test_ErrorSelector_Reentrancy() public pure {
        assertEq(Reentrancy.selector, bytes4(0xab143c06), "Reentrancy selector mismatch");
        assertEq(Reentrancy.selector, bytes4(keccak256("Reentrancy()")));
    }

    function test_ErrorSelector_ApproveFailed() public pure {
        assertEq(ApproveFailed.selector, bytes4(0x3e3f8f73), "ApproveFailed selector mismatch");
        assertEq(ApproveFailed.selector, bytes4(keccak256("ApproveFailed()")));
    }

    function test_ErrorSelector_WithdrawalTooSoon() public pure {
        assertEq(
            WithdrawalTooSoon.selector, bytes4(0xff56d9bd), "WithdrawalTooSoon selector mismatch"
        );
        assertEq(WithdrawalTooSoon.selector, bytes4(keccak256("WithdrawalTooSoon(uint256)")));
    }

    // ============ Function Selector Verification ============

    // External call selectors used in assembly staticcalls
    uint256 constant SELECTOR_POOLS_SHIFTED = 0xac4afa38 << 224;
    uint256 constant SELECTOR_MARKETS_SHIFTED = 0xb1283e77 << 224;

    function test_FunctionSelector_pools() public pure {
        bytes4 expected = bytes4(keccak256("pools(uint256)"));
        assertEq(expected, bytes4(0xac4afa38), "pools selector mismatch");
        assertEq(uint256(uint32(expected)) << 224, SELECTOR_POOLS_SHIFTED);
    }

    function test_FunctionSelector_markets() public pure {
        bytes4 expected = bytes4(keccak256("markets(uint256)"));
        assertEq(expected, bytes4(0xb1283e77), "markets selector mismatch");
        assertEq(uint256(uint32(expected)) << 224, SELECTOR_MARKETS_SHIFTED);
    }

    function test_FunctionSelector_getCurrentFeeBps() public pure {
        // Used in _getPoolFeeBps at line 1968
        bytes4 expected = bytes4(keccak256("getCurrentFeeBps(uint256)"));
        assertEq(expected, bytes4(0xb9056dbd), "getCurrentFeeBps selector mismatch");
    }

    function test_FunctionSelector_getCloseWindow() public pure {
        // Used in _isInCloseWindow at line 815
        bytes4 expected = bytes4(keccak256("getCloseWindow(uint256)"));
        assertEq(expected, bytes4(0x5f598ac3), "getCloseWindow selector mismatch");
    }

    function test_FunctionSelector_getMaxPriceImpactBps() public pure {
        // Used in _getMaxPriceImpactBps at line 1740
        bytes4 expected = bytes4(keccak256("getMaxPriceImpactBps(uint256)"));
        assertEq(expected, bytes4(0x9e9feaae), "getMaxPriceImpactBps selector mismatch");
    }

    function test_FunctionSelector_permit() public pure {
        // EIP-2612 permit
        bytes4 expected =
            bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertEq(expected, bytes4(0xd505accf), "permit selector mismatch");
    }

    function test_FunctionSelector_permitDAI() public pure {
        // DAI-style permit
        bytes4 expected =
            bytes4(keccak256("permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)"));
        assertEq(expected, bytes4(0x8fcbaf0c), "DAI permit selector mismatch");
    }

    function test_FunctionSelector_allowance() public pure {
        // Used in ensureApproval
        bytes4 expected = bytes4(keccak256("allowance(address,address)"));
        assertEq(expected, bytes4(0xdd62ed3e), "allowance selector mismatch");
    }

    function test_FunctionSelector_approve() public pure {
        // Used in ensureApproval
        bytes4 expected = bytes4(keccak256("approve(address,uint256)"));
        assertEq(expected, bytes4(0x095ea7b3), "approve selector mismatch");
    }

    function test_FunctionSelector_transfer() public pure {
        // Used in safeTransfer
        bytes4 expected = bytes4(keccak256("transfer(address,uint256)"));
        assertEq(expected, bytes4(0xa9059cbb), "transfer selector mismatch");
    }

    function test_FunctionSelector_transferFrom() public pure {
        // Used in safeTransferFrom
        bytes4 expected = bytes4(keccak256("transferFrom(address,address,uint256)"));
        assertEq(expected, bytes4(0x23b872dd), "transferFrom selector mismatch");
    }

    // ============ Error Code Constants ============
    // Validate error code constants match documented enums
    // These define what each error code means (reference documentation)

    // ValidationError: 0=Overflow, 1=AmountZero, 2=Slippage, 3=InsufficientOutput,
    //                  4=InsufficientShares, 5=InsufficientVaultShares, 6=InvalidETHAmount, 7=InvalidCloseTime
    uint8 constant VALIDATION_OVERFLOW = 0;
    uint8 constant VALIDATION_AMOUNT_ZERO = 1;
    uint8 constant VALIDATION_SLIPPAGE = 2;
    uint8 constant VALIDATION_INSUFFICIENT_OUTPUT = 3;
    uint8 constant VALIDATION_INSUFFICIENT_SHARES = 4;
    uint8 constant VALIDATION_INSUFFICIENT_VAULT_SHARES = 5;
    uint8 constant VALIDATION_INVALID_ETH_AMOUNT = 6;
    uint8 constant VALIDATION_INVALID_CLOSE_TIME = 7;

    // TimingError: 0=Expired, 1=TooSoon, 2=MarketClosed, 3=MarketNotClosed, 4=PoolNotReady
    uint8 constant TIMING_EXPIRED = 0;
    uint8 constant TIMING_TOO_SOON = 1;
    uint8 constant TIMING_MARKET_CLOSED = 2;
    uint8 constant TIMING_MARKET_NOT_CLOSED = 3;
    uint8 constant TIMING_POOL_NOT_READY = 4;

    // StateError: 0=MarketResolved, 1=MarketNotResolved, 2=MarketNotRegistered,
    //             3=MarketAlreadyRegistered, 4=VaultDepleted, 5=OrphanedAssets, 6=CirculatingLPsExist
    uint8 constant STATE_MARKET_RESOLVED = 0;
    uint8 constant STATE_MARKET_NOT_RESOLVED = 1;
    uint8 constant STATE_MARKET_NOT_REGISTERED = 2;
    uint8 constant STATE_MARKET_ALREADY_REGISTERED = 3;
    uint8 constant STATE_VAULT_DEPLETED = 4;
    uint8 constant STATE_ORPHANED_ASSETS = 5;
    uint8 constant STATE_CIRCULATING_LPS_EXIST = 6;

    // TransferError: 0=TransferFailed, 1=TransferFromFailed, 2=ETHTransferFailed
    uint8 constant TRANSFER_FAILED = 0;
    uint8 constant TRANSFER_FROM_FAILED = 1;
    uint8 constant ETH_TRANSFER_FAILED = 2;

    // ComputationError: 0=MulDivFailed, 1=FullMulDivFailed, 2=TWAPCorrupt, 3=TWAPRequired,
    //                   4=TWAPInitFailed, 5=SpotDeviantFromTWAP, 6=HookInvalidPoolId, 7=NonCanonicalPool
    uint8 constant COMPUTATION_MUL_DIV_FAILED = 0;
    uint8 constant COMPUTATION_FULL_MUL_DIV_FAILED = 1;
    uint8 constant COMPUTATION_TWAP_CORRUPT = 2;
    uint8 constant COMPUTATION_TWAP_REQUIRED = 3;
    uint8 constant COMPUTATION_TWAP_INIT_FAILED = 4;
    uint8 constant COMPUTATION_SPOT_DEVIANT = 5;
    uint8 constant COMPUTATION_HOOK_INVALID_POOL_ID = 6;
    uint8 constant COMPUTATION_NON_CANONICAL_POOL = 7;

    // SharesError: 0=ZeroShares, 1=ZeroVaultShares, 2=NoVaultShares, 3=SharesOverflow,
    //              4=VaultSharesOverflow, 5=SharesReturnedOverflow
    uint8 constant SHARES_ZERO = 0;
    uint8 constant SHARES_ZERO_VAULT = 1;
    uint8 constant SHARES_NO_VAULT = 2;
    uint8 constant SHARES_OVERFLOW = 3;
    uint8 constant SHARES_VAULT_OVERFLOW = 4;
    uint8 constant SHARES_RETURNED_OVERFLOW = 5;

    /// @notice Verify error codes are within valid range
    function test_ErrorCodes_ValidRange() public pure {
        // ValidationError max code is 7
        assertTrue(VALIDATION_INVALID_CLOSE_TIME == 7);
        // TimingError max code is 4
        assertTrue(TIMING_POOL_NOT_READY == 4);
        // StateError max code is 6
        assertTrue(STATE_CIRCULATING_LPS_EXIST == 6);
        // TransferError max code is 2
        assertTrue(ETH_TRANSFER_FAILED == 2);
        // ComputationError max code is 7
        assertTrue(COMPUTATION_NON_CANONICAL_POOL == 7);
        // SharesError max code is 5
        assertTrue(SHARES_RETURNED_OVERFLOW == 5);
    }
}
