import { readFileSync } from "node:fs";
import { network } from "hardhat";

const { ethers } = await network.connect();

async function main() {
  const deployment = JSON.parse(
    readFileSync("deployments/base-v2.json", "utf8"),
  );
  const networkInfo = await ethers.provider.getNetwork();
  if (networkInfo.chainId !== 8453n || deployment.chainId !== "8453") {
    throw new Error("not a Base mainnet deployment");
  }

  const wallet = await ethers.getContractAt(
    "GPULeaseWalletV2",
    deployment.wallet,
  );
  const lease = await ethers.getContractAt("GPULeaseV2", deployment.lease);
  const referral = await ethers.getContractAt(
    "GPULeaseReferralV2",
    deployment.referral,
  );
  const factory = await ethers.getContractAt(
    "LLMFundraisingFactoryV2",
    deployment.campaignFactoryV2,
  );
  const token = new ethers.Contract(
    deployment.usdc,
    ["function balanceOf(address account) view returns (uint256)"],
    ethers.provider,
  );

  const values = await Promise.all([
    wallet.owner(),
    wallet.registrar(),
    wallet.leaseManager(),
    wallet.accountedBalance(),
    token.balanceOf(deployment.wallet),
    lease.owner(),
    lease.wallet(),
    lease.referralManager(),
    lease.treasuryId(),
    lease.settlementOperator(),
    referral.owner(),
    factory.owner(),
    factory.gpuLeaseWallet(),
    factory.usdc(),
    factory.metadataRenderer(),
    factory.feeRecipient(),
    factory.campaignImplementation(),
  ]);
  const [
    walletOwner,
    registrar,
    leaseManager,
    accounted,
    tokenBalance,
    leaseOwner,
    leaseWallet,
    referralManager,
    treasuryId,
    settlementOperator,
    referralOwner,
    factoryOwner,
    factoryWallet,
    factoryUsdc,
    renderer,
    feeRecipient,
    implementation,
  ] = values;

  const addressChecks = [
    ["wallet owner", walletOwner, deployment.deployer],
    ["registrar", registrar, deployment.registrar],
    ["wallet lease manager", leaseManager, deployment.lease],
    ["lease owner", leaseOwner, deployment.deployer],
    ["lease wallet", leaseWallet, deployment.wallet],
    ["lease referral", referralManager, deployment.referral],
    ["settlement operator", settlementOperator, deployment.settlementOperator],
    ["referral owner", referralOwner, deployment.deployer],
    ["factory owner", factoryOwner, deployment.deployer],
    ["factory wallet", factoryWallet, deployment.wallet],
    ["factory USDC", factoryUsdc, deployment.usdc],
    ["factory renderer", renderer, deployment.campaignMetadataRenderer],
    ["factory fee recipient", feeRecipient, deployment.campaignFeeRecipient],
    ["campaign implementation", implementation, deployment.campaignImplementationV2],
  ];
  for (const [label, actual, expected] of addressChecks) {
    if (actual.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`${label} mismatch: ${actual} != ${expected}`);
    }
  }
  if (treasuryId !== deployment.treasuryAccountId) {
    throw new Error(`treasury ID mismatch: ${treasuryId}`);
  }
  if (accounted !== tokenBalance) {
    throw new Error(`wallet insolvent: accounted=${accounted} token=${tokenBalance}`);
  }

  for (const [label, address] of [
    ["wallet", deployment.wallet],
    ["lease", deployment.lease],
    ["referral", deployment.referral],
    ["campaign factory", deployment.campaignFactoryV2],
    ["campaign implementation", deployment.campaignImplementationV2],
  ]) {
    if ((await ethers.provider.getCode(address)) === "0x") {
      throw new Error(`${label} has no code at ${address}`);
    }
  }

  console.log(JSON.stringify({
    chainId: networkInfo.chainId.toString(),
    block: await ethers.provider.getBlockNumber(),
    wallet: deployment.wallet,
    lease: deployment.lease,
    referral: deployment.referral,
    campaignFactory: deployment.campaignFactoryV2,
    campaignImplementation: deployment.campaignImplementationV2,
    tokenBalance: tokenBalance.toString(),
    accountedBalance: accounted.toString(),
    status: "ok",
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
