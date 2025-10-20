// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {FHE, InEbool, InEuint8, InEuint16, InEuint32, InEuint64, InEuint128, InEaddress} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ebool, euint8, euint16, euint32, euint64, euint128, eaddress} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {DynamicInE} from "./ITradeManager.sol";

/**
 * @title DynamicFHE
 * @notice Library for loading dynamically-typed encrypted values
 * @dev Converts DynamicInE inputs to internal FHE handles and returns unwrapped uint256
 * @dev Supports all CoFHE types EXCEPT euint256 (deprecated by Fhenix)
 *
 * Supported utypes (from ICofhe.sol):
 * - 0: Bool
 * - 2: Uint8
 * - 3: Uint16
 * - 4: Uint32
 * - 5: Uint64
 * - 6: Uint128
 * - 7: Address (Uint160)
 * - 8: Uint256 (DEPRECATED - explicitly rejected)
 */
library DynamicFHE {
    /**
     * @notice Load a dynamic encrypted input and return the internal handle as uint256
     * @dev All encrypted types are internally represented as uint256, so we unwrap them
     * @param input The dynamic encrypted input with utype specification
     * @return handle The internal FHE handle as uint256 (unwrapped)
     */
    function loadDynamic(DynamicInE calldata input) internal returns (uint256 handle) {
        if (input.utype == 0) {
            // Bool
            ebool h = FHE.asEbool(InEbool({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = ebool.unwrap(h);
        } else if (input.utype == 2) {
            // Uint8
            euint8 h = FHE.asEuint8(InEuint8({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = euint8.unwrap(h);
        } else if (input.utype == 3) {
            // Uint16
            euint16 h = FHE.asEuint16(InEuint16({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = euint16.unwrap(h);
        } else if (input.utype == 4) {
            // Uint32
            euint32 h = FHE.asEuint32(InEuint32({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = euint32.unwrap(h);
        } else if (input.utype == 5) {
            // Uint64
            euint64 h = FHE.asEuint64(InEuint64({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = euint64.unwrap(h);
        } else if (input.utype == 6) {
            // Uint128
            euint128 h = FHE.asEuint128(InEuint128({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = euint128.unwrap(h);
        } else if (input.utype == 7) {
            // Address (Uint160)
            eaddress h = FHE.asEaddress(InEaddress({
                ctHash: input.ctHash,
                securityZone: input.securityZone,
                utype: input.utype,
                signature: input.signature
            }));
            handle = eaddress.unwrap(h);
        } else if (input.utype == 8) {
            // Uint256 - EXPLICITLY REJECTED (deprecated by Fhenix, SDK won't decrypt)
            revert("DynamicFHE: euint256 (utype 8) is deprecated and not supported");
        } else {
            revert("DynamicFHE: Unsupported utype");
        }
    }
}
