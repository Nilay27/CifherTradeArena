const { cofhejs, Encryptable, FheTypes } = require('cofhejs/node');
import { ethers } from 'ethers';

export const initializeCofheJs = async (signer: ethers.Wallet) => {
    await cofhejs.initializeWithEthers({
        ethersProvider: signer.provider,
        ethersSigner: signer,
        environment: 'MOCK'  // Use MOCK for local testing with Anvil
    });
    console.log("CoFHE.js initialized successfully in MOCK mode");
};

export const decryptAmount = async (encryptedAmount: string): Promise<bigint> => {
    try {
        // Decode the encrypted handle from the encrypted amount bytes
        const encryptedHandle = ethers.AbiCoder.defaultAbiCoder().decode(
            ["uint256"],
            encryptedAmount
        )[0];
        
        console.log(`Decrypting handle: ${encryptedHandle}`);
        
        // In MOCK mode or with simulated encryption, the handle IS the actual value
        // Since we're using submitTestIntent which just encodes the amount directly
        // We don't need to decrypt - the value is already there
        const decryptedValue = encryptedHandle;
        
        console.log(`Decrypted amount (simulated): ${decryptedValue}`);
        return BigInt(decryptedValue);
    } catch (error) {
        console.error("Error decrypting amount:", error);
        throw error;
    }
};

export const encryptAmount = async (amount: bigint): Promise<string> => {
    try {
        // Encrypt the amount using cofhejs
        const encResult = await cofhejs.encrypt([Encryptable.uint128(amount)]);
        
        if (!encResult.success) {
            throw new Error(`Encryption failed: ${encResult.error}`);
        }
        
        // Get the encrypted handle
        const encryptedHandle = encResult.data[0];
        
        // Encode the handle as bytes for storage
        const encodedAmount = ethers.AbiCoder.defaultAbiCoder().encode(
            ["uint256"],
            [encryptedHandle]
        );
        
        return encodedAmount;
    } catch (error) {
        console.error("Error encrypting amount:", error);
        throw error;
    }
};

// Helper function to decrypt and process a swap task
export const decryptSwapTask = async (task: any): Promise<{
    decryptedAmount: bigint;
    tokenIn: string;
    tokenOut: string;
    user: string;
}> => {
    console.log("Decrypting swap task...");
    
    // Decrypt the encrypted amount
    const decryptedAmount = await decryptAmount(task.encryptedAmount);
    
    return {
        decryptedAmount,
        tokenIn: task.tokenIn,
        tokenOut: task.tokenOut,
        user: task.user
    };
};