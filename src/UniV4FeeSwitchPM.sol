// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

address constant UNIV4 = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant PAMM = 0x000000000071176401AdA1f2CD7748e28E173FCa;

interface IPAMM {
    function createMarket(
        string calldata description,
        address resolver,
        uint72 close,
        bool canClose,
        uint256 seedYes,
        uint256 seedNo
    ) external returns (uint256 marketId, uint256 noId);

    function closeMarket(uint256 marketId) external;
    function resolve(uint256 marketId, bool outcome) external;
}

/// @notice Bet on UNIV4 fee switch. Forever on Ethereum.
/// @dev Markets resolve early if threshold is met. Nice.
contract UniV4FeeSwitchPM {
    error Unknown();
    error Pending();

    mapping(uint256 marketId => uint256) public deadline;
    
    function protocolFeeController() public view returns (address) {
        return UniV4FeeSwitchPM(UNIV4).protocolFeeController();
    }

    function makeBet(uint256 _deadline, uint256 seedYes, uint256 seedNo) public returns (uint256 marketId, uint256 noId) {
        string memory description = string(
            abi.encodePacked(
                "Uniswap V4 protocolFeeController() != address(0) by ",
                _toString(_deadline),
                " Unix epoch time. ",
                "Note: market may close early once threshold is reached."
            )
        );
        (marketId, noId) = IPAMM(PAMM).createMarket(description, address(this), uint72(_deadline), true, seedYes, seedNo);
        deadline[marketId] = _deadline;
    }

    function resolveBet(uint256 marketId) public {
        uint256 _deadline = deadline[marketId];
        if (_deadline == 0) revert Unknown();

        if (protocolFeeController() != address(0)) {
            if (block.timestamp < _deadline) IPAMM(PAMM).closeMarket(marketId);
            IPAMM(PAMM).resolve(marketId, true);
            delete deadline[marketId];
            return;
        }

        if (block.timestamp < _deadline) revert Pending();
        IPAMM(PAMM).resolve(marketId, false);
        delete deadline[marketId];
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
}