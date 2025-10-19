// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title AddressConfig
/// @notice Centralized configuration for all testnet addresses
/// @dev Supports Sepolia (11155111), Base Sepolia (84532), and Arbitrum Sepolia (421614)
library AddressConfig {

    /// @notice Network configuration structure
    struct NetworkConfig {
        // Uniswap V4 Core Addresses
        address poolManager;
        address universalRouter;
        address positionManager;
        address stateView;
        address quoter;
        address poolSwapTest;
        address poolModifyLiquidityTest;
        address permit2;

        // Deployed Mock Token Addresses (filled after deployment)
        address mockUSDC;
        address mockUSDT;

        // Encrypted Token Addresses (filled after testDeposit)
        address encryptedUSDC;
        address encryptedUSDT;

        // Hook and Pool Addresses (filled after deployment)
        address universalPrivacyHook;
        bytes32 poolId;
        uint256 batchInterval;
        address swapManager;
    }

    /// @notice Get network configuration by chain ID
    /// @param chainId The chain ID to get config for
    /// @return config Network configuration struct
    function getConfig(uint256 chainId) internal pure returns (NetworkConfig memory config) {
        if (chainId == 11155111) {
            // Sepolia
            return NetworkConfig({
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                universalRouter: 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b,
                positionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                stateView: 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C,
                quoter: 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227,
                poolSwapTest: 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe,
                poolModifyLiquidityTest: 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A,
                permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
                mockUSDC: address(0), // To be filled
                mockUSDT: address(0), // To be filled
                encryptedUSDC: address(0), // To be filled
                encryptedUSDT: address(0), // To be filled
                universalPrivacyHook: address(0), // To be filled
                poolId: bytes32(0), // To be filled
                batchInterval: 30, // To be filled
                swapManager: address(0) // To be filled
            });
        } else if (chainId == 84532) {
            // Base Sepolia
            return NetworkConfig({
                poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                universalRouter: 0x492E6456D9528771018DeB9E87ef7750EF184104,
                positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80,
                stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4,
                quoter: 0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa,
                poolSwapTest: 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9,
                poolModifyLiquidityTest: 0x37429cD17Cb1454C34E7F50b09725202Fd533039,
                permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
                mockUSDC: address(0), // To be filled
                mockUSDT: address(0), // To be filled
                encryptedUSDC: address(0), // To be filled
                encryptedUSDT: address(0), // To be filled
                universalPrivacyHook: address(0), // To be filled
                poolId: bytes32(0), // To be filled
                batchInterval: 10, // To be filled
                swapManager: address(0) // To be filled
            });
        } else if (chainId == 421614) {
            // Arbitrum Sepolia
            return NetworkConfig({
                poolManager: 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317,
                universalRouter: 0xeFd1D4bD4cf1e86Da286BB4CB1B8BcED9C10BA47,
                positionManager: 0xAc631556d3d4019C95769033B5E719dD77124BAc,
                stateView: 0x9D467FA9062b6e9B1a46E26007aD82db116c67cB,
                quoter: 0x7dE51022d70A725b508085468052E25e22b5c4c9,
                poolSwapTest: 0xf3A39C86dbd13C45365E57FB90fe413371F65AF8,
                poolModifyLiquidityTest: 0x9A8ca723F5dcCb7926D00B71deC55c2fEa1F50f7,
                permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
                mockUSDC: address(0), // To be filled
                mockUSDT: address(0), // To be filled
                encryptedUSDC: address(0), // To be filled
                encryptedUSDT: address(0), // To be filled
                universalPrivacyHook: address(0), // To be filled
                poolId: bytes32(0), // To be filled
                batchInterval: 10, // To be filled
                swapManager: address(0) // To be filled
            });
        } else {
            revert("Unsupported chain ID");
        }
    }

    /// @notice Save deployed addresses to environment/config file
    /// @dev This is called after each deployment step to update the config
    /// @param chainId The chain ID
    /// @param key The config key to update
    /// @param value The address value
    function saveAddress(uint256 chainId, string memory key, address value) internal {
        // In Foundry scripts, we'll use vm.writeJson or environment variables
        // This is a placeholder that will be implemented in the scripts
    }

    /// @notice Get network name for logging
    /// @param chainId The chain ID
    /// @return Network name string
    function getNetworkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 11155111) return "Sepolia";
        if (chainId == 84532) return "Base Sepolia";
        if (chainId == 421614) return "Arbitrum Sepolia";
        return "Unknown";
    }
}
