// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

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

    // ============ EVENTS ============

    event BoringVaultSet(address indexed vault);

    // ============ ADMIN FUNCTIONS ============

    function setBoringVault(address payable _vault) external;
}
