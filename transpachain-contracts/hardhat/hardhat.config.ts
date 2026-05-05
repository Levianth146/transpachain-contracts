import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import * as dotenv from "dotenv";

dotenv.config({ path: "../.env" });

const PRIVATE_KEY = process.env.PRIVATE_KEY ?? "0x" + "0".repeat(64);
const SEPOLIA_RPC  = process.env.SEPOLIA_RPC_URL ?? "";
const ETHERSCAN_KEY = process.env.ETHERSCAN_API_KEY ?? "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    sepolia: {
      url: SEPOLIA_RPC,
      accounts: [PRIVATE_KEY],
      chainId: 11155111,
    },
  },
  etherscan: {
    apiKey: ETHERSCAN_KEY,
  },
  // Point Hardhat at Foundry's src/ so it compiles the same files
  paths: {
    sources: "../src",
    tests: "../test",
    cache: "./cache_hardhat",
    artifacts: "./artifacts",
  },
};

export default config;
