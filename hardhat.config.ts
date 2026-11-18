import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import { configVariable, defineConfig } from "hardhat/config";
import { existsSync } from "node:fs";
import { loadEnvFile } from "node:process";

if (existsSync(".env")) {
  loadEnvFile(".env");
}

export default defineConfig({
  plugins: [hardhatToolboxMochaEthersPlugin],
  solidity: {
    profiles: {
      default: {
        version: "0.8.31",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: "0.8.31",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      // GPULeaseWalletV2/GPULeaseV2/GPULeaseReferralV2 were deployed with
      // this profile before the campaign optimizer was enabled.
      unoptimized: {
        version: "0.8.31",
        settings: {
          optimizer: {
            enabled: false,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    base: {
      type: "http",
      chainType: "op",
      url: process.env.BASE_RPC_URL ?? "https://mainnet.base.org",
      accounts: process.env.BASE_PRIVATE_KEY
        ? [process.env.BASE_PRIVATE_KEY]
        : [configVariable("BASE_PRIVATE_KEY")],
    },
  },
  verify: {
    etherscan: {
      apiKey: configVariable("BASESCAN_API_KEY"),
    },
  },
});
