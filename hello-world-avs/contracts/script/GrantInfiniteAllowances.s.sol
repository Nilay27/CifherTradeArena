// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console2.sol";
import {IERC20} from "@oz-v5/contracts/token/ERC20/IERC20.sol";
import {SimpleBoringVault} from "../src/SimpleBoringVault.sol";

/**
 * @title GrantInfiniteAllowances
 * @notice Utility script that signs transactions as the TradeManager to grant unlimited allowances
 *         from the SimpleBoringVault to the supported protocol adapters (Aave, Morpho, Pendle).
 *
 * Usage:
 *  forge script contracts/script/GrantInfiniteAllowances.s.sol:GrantInfiniteAllowances \
 *      --broadcast --rpc-url <RPC_URL> --chain <CHAIN_ID>
 *
 * Required env variables:
 *  TRADE_MANAGER_PRIVATE_KEY - Private key for the TradeManager (hex string, 0x-prefixed)
 */
contract GrantInfiniteAllowances is Script {
    using stdJson for string;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        string memory chainIdStr = vm.toString(block.chainid);
        string memory root = vm.projectRoot();

        // Load deployment artifacts
        string memory tradeManagerPath = string.concat(
            root,
            "/deployments/trade-manager/",
            chainIdStr,
            ".json"
        );
        string memory tradeManagerJson = vm.readFile(tradeManagerPath);

        address tradeManager = tradeManagerJson.readAddress(".addresses.TradeManager");

        string memory boringVaultPath = string.concat(
            root,
            "/deployments/boring-vault/",
            chainIdStr,
            ".json"
        );
        string memory boringVaultJson = vm.readFile(boringVaultPath);
        address boringVault = boringVaultJson.readAddress(".addresses.SimpleBoringVault");
        string memory mocksPath = string.concat(
            root,
            "/deployments/mocks/",
            chainIdStr,
            ".json"
        );
        string memory mocksJson = vm.readFile(mocksPath);

        address[5] memory tokens = [
            mocksJson.readAddress(".tokens.USDC"),
            mocksJson.readAddress(".tokens.USDT"),
            mocksJson.readAddress(".tokens.PT_eUSDE"),
            mocksJson.readAddress(".tokens.PT_sUSDE"),
            mocksJson.readAddress(".tokens.PT_USR")
        ];

        address[3] memory protocols = [
            mocksJson.readAddress(".protocols.aave"),
            mocksJson.readAddress(".protocols.morpho"),
            mocksJson.readAddress(".protocols.pendle")
        ];

        SimpleBoringVault vault = SimpleBoringVault(payable(boringVault));

        vm.startBroadcast(privateKey);

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;

            for (uint256 j = 0; j < protocols.length; j++) {
                address spender = protocols[j];
                if (spender == address(0)) continue;

                bytes memory callData = abi.encodeWithSelector(
                    IERC20.approve.selector,
                    spender,
                    type(uint256).max
                );

                vault.execute(token, callData, 0);

                console2.log("Approved token", token);
                console2.log("for spender", spender);
                console2.log("on chain", block.chainid);
            }
        }

        vm.stopBroadcast();

        console2.log("Infinite allowances granted by TradeManager at", tradeManager);
    }
}
