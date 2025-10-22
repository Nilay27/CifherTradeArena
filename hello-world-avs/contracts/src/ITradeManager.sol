// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {InEaddress, InEuint32, InEuint64, InEuint16} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @notice Dynamic encrypted input - supports any FHE type based on utype
 * @dev Allows flexible argument encoding where args can be addresses, uint128, etc.
 */
struct DynamicInE {
    uint256 ctHash;
    uint8 securityZone;
    uint8 utype;
    bytes signature;
}

interface ITradeManager {
    // ============ OPERATOR MANAGEMENT ============

    function getOperatorCount() external view returns (uint256);
    function isOperatorRegistered(address operator) external view returns (bool);
    function registerOperator() external;

    // ============ EPOCH MANAGEMENT ============

    function startEpoch(
        InEuint64 calldata encSimStartTime,
        InEuint64 calldata encSimEndTime,
        uint64 epochDuration,
        uint8[] calldata weights,
        uint256 notionalPerTrader,
        uint256 allocatedCapital
    ) external;

    function submitEncryptedStrategy(
        InEaddress[] calldata encoders,
        InEaddress[] calldata targets,
        InEuint32[] calldata selectors,
        DynamicInE[][] calldata nodeArgs
    ) external;

    function reportEncryptedAPY(
        uint256 epochNumber,
        address trader,
        InEuint16 calldata encryptedAPY
    ) external;

    // ============ EVENTS ============

    event BoringVaultSet(address indexed vault);
    // ============ ADMIN FUNCTIONS ============

    function setBoringVault(address payable _vault) external;
}
