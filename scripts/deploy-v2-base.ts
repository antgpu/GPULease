import { mkdirSync, writeFileSync } from "node:fs";
import { network } from "hardhat";

const { ethers } = await network.connect();

const USDC_ADDRESS =
  process.env.USDC_ADDRESS ?? "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
const TREASURY_ID =
  process.env.TREASURY_ACCOUNT_ID ??
  ethers.keccak256(ethers.toUtf8Bytes("antgpu:treasury"));

async function main() {
  const [deployer] = await ethers.getSigners();
  const registrarAddress = process.env.REGISTRAR_ADDRESS ?? deployer.address;
  const settlementOperatorAddress =
    process.env.SETTLEMENT_OPERATOR_ADDRESS ?? deployer.address;
  const networkInfo = await ethers.provider.getNetwork();
  if (networkInfo.chainId !== 8453n) {
    throw new Error(`refusing to deploy on chain ${networkInfo.chainId}`);
  }

  console.log("Deploying GPULease V2 from:", deployer.address);
  console.log("Registrar:", registrarAddress);
  console.log("Settlement operator:", settlementOperatorAddress);
  console.log("Treasury account ID:", TREASURY_ID);

  const Wallet = await ethers.getContractFactory("GPULeaseWalletV2");
  const wallet = await Wallet.deploy(USDC_ADDRESS, registrarAddress);
  await wallet.waitForDeployment();
  const walletAddress = await wallet.getAddress();
  const walletDeploymentTx = wallet.deploymentTransaction()?.hash;

  const Referral = await ethers.getContractFactory("GPULeaseReferralV2");
  const referral = await Referral.deploy();
  await referral.waitForDeployment();
  const referralAddress = await referral.getAddress();
  const referralDeploymentTx = referral.deploymentTransaction()?.hash;

  const Lease = await ethers.getContractFactory("GPULeaseV2");
  const lease = await Lease.deploy(walletAddress, TREASURY_ID);
  await lease.waitForDeployment();
  const leaseAddress = await lease.getAddress();
  const leaseDeploymentTx = lease.deploymentTransaction()?.hash;

  const setLeaseManagerTx = await wallet.setLeaseManager(leaseAddress);
  await setLeaseManagerTx.wait(1);
  const setReferralManagerTx = await lease.setReferralManager(referralAddress);
  await setReferralManagerTx.wait(1);
  if (settlementOperatorAddress.toLowerCase() !== deployer.address.toLowerCase()) {
    await (await lease.setSettlementOperator(settlementOperatorAddress)).wait(1);
  }

  const [walletOwner, leaseOwner, referralOwner, manager, configuredReferral] =
    await Promise.all([
      wallet.owner(),
      lease.owner(),
      referral.owner(),
      wallet.leaseManager(),
      lease.referralManager(),
    ]);
  for (const [label, actual, expected] of [
    ["wallet owner", walletOwner, deployer.address],
    ["lease owner", leaseOwner, deployer.address],
    ["referral owner", referralOwner, deployer.address],
    ["lease manager", manager, leaseAddress],
    ["referral manager", configuredReferral, referralAddress],
  ]) {
    if (actual.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`${label} mismatch: ${actual} != ${expected}`);
    }
  }

  const deploymentBlock = await ethers.provider.getBlockNumber();
  const result = {
    version: 2,
    deployedAt: new Date().toISOString(),
    chainId: networkInfo.chainId.toString(),
    deploymentBlock,
    deployer: deployer.address,
    usdc: USDC_ADDRESS,
    treasuryAccountId: TREASURY_ID,
    registrar: registrarAddress,
    settlementOperator: settlementOperatorAddress,
    wallet: walletAddress,
    walletDeploymentTx,
    lease: leaseAddress,
    leaseDeploymentTx,
    referral: referralAddress,
    referralDeploymentTx,
    setLeaseManagerTx: setLeaseManagerTx.hash,
    setReferralManagerTx: setReferralManagerTx.hash,
  };
  mkdirSync("deployments", { recursive: true });
  writeFileSync(
    "deployments/base-v2.json",
    JSON.stringify(result, null, 2) + "\n",
  );
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
