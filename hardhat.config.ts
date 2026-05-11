import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";
import path from "path";

dotenv.config({ path: path.resolve(__dirname, ".env") });

const PRIVATE_KEY   = process.env.DEPLOYER_PRIVATE_KEY ?? "0x" + "0".repeat(64);
const SEPOLIA_URL   = process.env.ALCHEMY_SEPOLIA_URL  ?? "";
const ETHERSCAN_KEY = process.env.ETHERSCAN_API_KEY    ?? "";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          evmVersion: "cancun",
        },
      },
    ],
  },
  networks: {
    sepolia: {
      url: SEPOLIA_URL,
      accounts: [PRIVATE_KEY],
      chainId: 11155111,
    },
  },
  etherscan: {
    apiKey: ETHERSCAN_KEY,
  },
  paths: {
    sources:   "./src",
    tests:     "./test",
    cache:     "./cache_hardhat",
    artifacts: "./artifacts",
  },
};

export default config;
