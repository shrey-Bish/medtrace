// Hardhat configuration for MedTrace.
// Networks:
//   - hardhat / localhost : local development chain (no setup needed)
//   - amoy                : Polygon Amoy testnet (needs .env, see .env.example)
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { AMOY_RPC_URL, PRIVATE_KEY, POLYGONSCAN_API_KEY } = process.env;

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
    },
  },
  networks: {
    localhost: { url: "http://127.0.0.1:8545" },
    amoy: {
      url: AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
      chainId: 80002,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    // Used by `npx hardhat verify` to publish source code on the block explorer.
    apiKey: POLYGONSCAN_API_KEY || "",
  },
  gasReporter: {
    // Run `REPORT_GAS=true npx hardhat test` to print gas cost per function.
    enabled: process.env.REPORT_GAS === "true",
  },
};
