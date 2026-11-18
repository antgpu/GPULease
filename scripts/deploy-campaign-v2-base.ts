import { readFileSync, writeFileSync } from "node:fs";
import { network } from "hardhat";

const { ethers } = await network.connect();

const DEPLOYMENT_FILE = "deployments/base-v2.json";
const DEFAULT_METADATA_RENDERER =
  "0x48a862d4ca9aE88699251B38097064B8967F405c";
const DEFAULT_FEE_RECIPIENT =
  "0x80CFfF5C710E3e21050AaB272201B574a53A66B3";

async function main() {
  const deployment = JSON.parse(readFileSync(DEPLOYMENT_FILE, "utf8"));
  const [deployer] = await ethers.getSigners();
  const networkInfo = await ethers.provider.getNetwork();
  if (networkInfo.chainId !== 8453n) {
    throw new Error(`refusing to deploy on chain ${networkInfo.chainId}`);
  }
  if (deployment.campaignFactoryV2) {
    throw new Error(
      `campaign V2 factory already recorded: ${deployment.campaignFactoryV2}`,
    );
  }

  const metadataRenderer =
    process.env.CAMPAIGN_METADATA_RENDERER_ADDRESS ?? DEFAULT_METADATA_RENDERER;
  const feeRecipient =
    process.env.TREASURY_ADDRESS ?? DEFAULT_FEE_RECIPIENT;

  console.log("Deploying campaign V2 factory from:", deployer.address);
  console.log("V2 wallet:", deployment.wallet);
  console.log("Metadata renderer:", metadataRenderer);
  console.log("Fee recipient:", feeRecipient);

  const Factory = await ethers.getContractFactory("LLMFundraisingFactoryV2");
  const factory = await Factory.deploy(
    deployment.usdc,
    deployment.wallet,
    metadataRenderer,
    feeRecipient,
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  const implementationAddress = await factory.campaignImplementation();
  const deploymentTx = factory.deploymentTransaction()?.hash;

  const [owner, usdc, wallet, renderer, configuredFeeRecipient] =
    await Promise.all([
      factory.owner(),
      factory.usdc(),
      factory.gpuLeaseWallet(),
      factory.metadataRenderer(),
      factory.feeRecipient(),
    ]);
  const expected = [
    ["owner", owner, deployer.address],
    ["usdc", usdc, deployment.usdc],
    ["wallet", wallet, deployment.wallet],
    ["renderer", renderer, metadataRenderer],
    ["fee recipient", configuredFeeRecipient, feeRecipient],
  ];
  for (const [label, actual, wanted] of expected) {
    if (actual.toLowerCase() !== wanted.toLowerCase()) {
      throw new Error(`${label} mismatch: ${actual} != ${wanted}`);
    }
  }

  deployment.campaignFactoryV2 = factoryAddress;
  deployment.campaignImplementationV2 = implementationAddress;
  deployment.campaignFactoryV2DeploymentTx = deploymentTx;
  deployment.campaignMetadataRenderer = metadataRenderer;
  deployment.campaignFeeRecipient = feeRecipient;
  deployment.campaignDeploymentBlock = await ethers.provider.getBlockNumber();
  writeFileSync(DEPLOYMENT_FILE, JSON.stringify(deployment, null, 2) + "\n");
  console.log(JSON.stringify({
    campaignFactoryV2: factoryAddress,
    campaignImplementationV2: implementationAddress,
    deploymentTx,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
