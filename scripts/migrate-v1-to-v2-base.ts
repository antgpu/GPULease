import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { network } from "hardhat";

const { ethers } = await network.connect();

type SnapshotAccount = {
  address: string;
  cash: string;
  bonus: string;
};

type Snapshot = {
  chainId: string;
  snapshotBlock: number;
  completenessCheckPassed: boolean;
  activeLeaseIds: string[];
  contracts: { wallet: string; lease: string; usdc: string };
  totals: {
    cash: string;
    bonus: string;
    bonusReserve: string;
    tokenBalance: string;
  };
  accounts: SnapshotAccount[];
};

type VerifiedWallet = {
  user_id?: number;
  wallet_verifier_id: string;
  address: string;
  linked_at?: string;
};

const SNAPSHOT_FILE = process.env.MIGRATION_SNAPSHOT_FILE ?? "migration/snapshot-v1.json";
const DEPLOYMENT_FILE = process.env.V2_DEPLOYMENT_FILE ?? "deployments/base-v2.json";
const VERIFIED_WALLETS_FILE =
  process.env.VERIFIED_WALLETS_FILE ?? "migration/verified-wallets.json";
const EXECUTE = process.env.EXECUTE_MIGRATION === "YES";
const ALLOW_TEMPORARY_LEGACY_IDS =
  process.env.ALLOW_TEMPORARY_LEGACY_IDS === "YES";
const TREASURY_ADDRESS = (
  process.env.TREASURY_ADDRESS ?? "0x80CFfF5C710E3e21050AaB272201B574a53A66B3"
).toLowerCase();
const TREASURY_ID =
  process.env.TREASURY_ACCOUNT_ID ??
  ethers.keccak256(ethers.toUtf8Bytes("antgpu:treasury"));

function accountIdForVerifierId(verifierId: string) {
  return ethers.keccak256(ethers.toUtf8Bytes(verifierId.trim().toLowerCase()));
}

function legacyAccountId(address: string) {
  return ethers.keccak256(
    ethers.toUtf8Bytes(`antgpu:legacy-wallet:${address.toLowerCase()}`),
  );
}

async function main() {
  if (!existsSync(SNAPSHOT_FILE)) throw new Error(`missing ${SNAPSHOT_FILE}`);
  if (!existsSync(DEPLOYMENT_FILE)) throw new Error(`missing ${DEPLOYMENT_FILE}`);

  const snapshot: Snapshot = JSON.parse(readFileSync(SNAPSHOT_FILE, "utf8"));
  const deployment = JSON.parse(readFileSync(DEPLOYMENT_FILE, "utf8"));
  const verifiedWallets: VerifiedWallet[] = existsSync(VERIFIED_WALLETS_FILE)
    ? JSON.parse(readFileSync(VERIFIED_WALLETS_FILE, "utf8"))
    : [];

  if (snapshot.chainId !== "8453" || deployment.chainId !== "8453") {
    throw new Error("migration files are not for Base mainnet");
  }
  if (!snapshot.completenessCheckPassed) throw new Error("snapshot is incomplete");
  if (snapshot.activeLeaseIds.length > 0) throw new Error("snapshot has active leases");

  const [deployer] = await ethers.getSigners();
  const oldWallet = await ethers.getContractAt("GPULeaseWallet", snapshot.contracts.wallet);
  const oldLease = await ethers.getContractAt("GPULease", snapshot.contracts.lease);
  const newWallet = await ethers.getContractAt("GPULeaseWalletV2", deployment.wallet);
  const token = new ethers.Contract(
    snapshot.contracts.usdc,
    [
      "function balanceOf(address account) view returns (uint256)",
      "function approve(address spender, uint256 amount) returns (bool)",
    ],
    deployer,
  );

  const fundedAddresses = new Set(
    snapshot.accounts.map((item) => item.address.toLowerCase()),
  );
  const verifiedByAddress = new Map<string, VerifiedWallet>();
  const verifierIdsByAddress = new Map<string, Set<string>>();
  for (const item of verifiedWallets) {
    if (!ethers.isAddress(item.address)) {
      throw new Error(`invalid verified wallet address: ${item.address}`);
    }
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      item.wallet_verifier_id,
    )) {
      throw new Error(`invalid wallet_verifier_id: ${item.wallet_verifier_id}`);
    }
    const address = item.address.toLowerCase();
    const verifierId = item.wallet_verifier_id.toLowerCase();
    const verifierIds = verifierIdsByAddress.get(address) ?? new Set<string>();
    verifierIds.add(verifierId);
    verifierIdsByAddress.set(address, verifierIds);
    const existing = verifiedByAddress.get(address);
    if (
      !existing ||
      new Date(item.linked_at ?? 0).getTime() >= new Date(existing.linked_at ?? 0).getTime()
    ) {
      verifiedByAddress.set(address, item);
    }
  }
  for (const [address, verifierIds] of verifierIdsByAddress) {
    if (fundedAddresses.has(address) && verifierIds.size > 1) {
      throw new Error(
        `fund ownership is ambiguous: ${address} belongs to multiple user IDs`,
      );
    }
  }

  type Target = {
    accountId: string;
    cash: bigint;
    bonus: bigint;
    sourceAddresses: string[];
    wallet: string;
    canonical: boolean;
  };
  const targets = new Map<string, Target>();
  for (const source of snapshot.accounts) {
    const address = source.address.toLowerCase();
    const verified = verifiedByAddress.get(address);
    const accountId =
      address === TREASURY_ADDRESS
        ? TREASURY_ID
        : verified
          ? accountIdForVerifierId(verified.wallet_verifier_id)
          : legacyAccountId(address);
    const existing = targets.get(accountId);
    const linkedAt = new Date(verified?.linked_at ?? 0).getTime();
    const existingLinkedAt = existing
      ? Math.max(
          ...existing.sourceAddresses.map((candidate) =>
            new Date(verifiedByAddress.get(candidate)?.linked_at ?? 0).getTime(),
          ),
        )
      : -1;
    if (existing) {
      existing.cash += BigInt(source.cash);
      existing.bonus += BigInt(source.bonus);
      existing.sourceAddresses.push(address);
      if (verified && linkedAt >= existingLinkedAt) existing.wallet = address;
    } else {
      targets.set(accountId, {
        accountId,
        cash: BigInt(source.cash),
        bonus: BigInt(source.bonus),
        sourceAddresses: [address],
        wallet: address,
        canonical: address === TREASURY_ADDRESS || Boolean(verified),
      });
    }
  }

  const canonicalCount = [...targets.values()].filter((item) => item.canonical).length;
  const legacyCount = targets.size - canonicalCount;
  const plan = {
    generatedAt: new Date().toISOString(),
    snapshotBlock: snapshot.snapshotBlock,
    deployer: deployer.address,
    oldWallet: snapshot.contracts.wallet,
    newWallet: deployment.wallet,
    sourceAccounts: snapshot.accounts.length,
    targetAccounts: targets.size,
    canonicalAccounts: canonicalCount,
    temporaryLegacyAccounts: legacyCount,
    cash: snapshot.totals.cash,
    bonus: snapshot.totals.bonus,
    bonusReserve: snapshot.totals.bonusReserve,
    execute: EXECUTE,
    allowTemporaryLegacyIds: ALLOW_TEMPORARY_LEGACY_IDS,
    targets: [...targets.values()].map((item) => ({
      ...item,
      cash: item.cash.toString(),
      bonus: item.bonus.toString(),
    })),
  };
  writeFileSync("migration/migration-v2-plan.json", JSON.stringify(plan, null, 2) + "\n");

  const [
    oldOwner,
    oldManager,
    oldTokenBalance,
    oldLeaseCount,
    oldBonusReserve,
    newOwner,
    newRegistrar,
    newManager,
    newTokenBalance,
    newAccountedBalance,
  ] =
    await Promise.all([
      oldWallet.owner(),
      oldWallet.leaseManager(),
      token.balanceOf(snapshot.contracts.wallet),
      oldLease.leaseCount(),
      oldWallet.bonusReserve(),
      newWallet.owner(),
      newWallet.registrar(),
      newWallet.leaseManager(),
      token.balanceOf(deployment.wallet),
      newWallet.accountedBalance(),
    ]);
  if (oldOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(`deployer is not old wallet owner: ${oldOwner}`);
  }
  for (let i = 0n; i < oldLeaseCount; i += 1n) {
    const item = await oldLease.leases(i);
    if (item.active && !item.completed) throw new Error(`active lease ${i}`);
  }
  if (BigInt(oldTokenBalance) !== BigInt(snapshot.totals.tokenBalance)) {
    throw new Error(
      `old wallet changed after snapshot: ${oldTokenBalance} != ${snapshot.totals.tokenBalance}`,
    );
  }
  if (BigInt(oldBonusReserve) !== BigInt(snapshot.totals.bonusReserve)) {
    throw new Error(`old bonus reserve changed: ${oldBonusReserve}`);
  }
  for (const source of snapshot.accounts) {
    const [cash, bonus] = await Promise.all([
      oldWallet.balances(source.address),
      oldWallet.bonusBalances(source.address),
    ]);
    if (BigInt(cash) !== BigInt(source.cash) || BigInt(bonus) !== BigInt(source.bonus)) {
      throw new Error(
        `old account changed: ${source.address} cash=${cash} bonus=${bonus}`,
      );
    }
  }
  for (const [label, actual, expected] of [
    ["new wallet owner", newOwner, deployer.address],
    ["new wallet registrar", newRegistrar, deployer.address],
    ["new wallet lease manager", newManager, deployment.lease],
  ]) {
    if (actual.toLowerCase() !== expected.toLowerCase()) {
      throw new Error(`${label} mismatch: ${actual} != ${expected}`);
    }
  }
  if (BigInt(newTokenBalance) !== 0n || BigInt(newAccountedBalance) !== 0n) {
    throw new Error(
      `new wallet is not empty: token=${newTokenBalance} accounted=${newAccountedBalance}`,
    );
  }

  console.log(JSON.stringify({ ...plan, targets: undefined }, null, 2));
  console.log("Old manager:", oldManager);
  if (!EXECUTE) {
    console.log("Dry run only. Set EXECUTE_MIGRATION=YES after reviewing the plan.");
    return;
  }
  if (!existsSync(VERIFIED_WALLETS_FILE) && !ALLOW_TEMPORARY_LEGACY_IDS) {
    throw new Error(
      `refusing live migration without authoritative ${VERIFIED_WALLETS_FILE}; ` +
        "set ALLOW_TEMPORARY_LEGACY_IDS=YES to preserve unknown balances under deterministic legacy IDs",
    );
  }

  if (oldManager.toLowerCase() !== deployer.address.toLowerCase()) {
    await (await oldWallet.setLeaseManager(deployer.address)).wait(1);
  }

  const deployerLower = deployer.address.toLowerCase();
  for (const source of snapshot.accounts) {
    const oldCash = BigInt(await oldWallet.balances(source.address));
    if (oldCash > 0n && source.address.toLowerCase() !== deployerLower) {
      await (await oldWallet.moveBalance(source.address, deployer.address)).wait(1);
    }
    const oldBonus = BigInt(await oldWallet.bonusBalances(source.address));
    if (oldBonus > 0n) {
      await (await oldWallet.revokeBonus(source.address, oldBonus)).wait(1);
    }
  }

  const aggregatedCash = BigInt(await oldWallet.balances(deployer.address));
  if (aggregatedCash !== BigInt(snapshot.totals.cash)) {
    throw new Error(`aggregated cash mismatch: ${aggregatedCash}`);
  }
  if (aggregatedCash > 0n) {
    await (await oldWallet.withdraw(aggregatedCash)).wait(1);
  }
  const aggregatedReserve = BigInt(await oldWallet.bonusReserve());
  const expectedReserve =
    BigInt(snapshot.totals.bonusReserve) + BigInt(snapshot.totals.bonus);
  if (aggregatedReserve !== expectedReserve) {
    throw new Error(`aggregated bonus reserve mismatch: ${aggregatedReserve}`);
  }
  if (aggregatedReserve > 0n) {
    await (
      await oldWallet.withdrawBonusReserve(deployer.address, aggregatedReserve)
    ).wait(1);
  }

  const migrationTotal =
    BigInt(snapshot.totals.cash) +
    BigInt(snapshot.totals.bonus) +
    BigInt(snapshot.totals.bonusReserve);
  await (await token.approve(deployment.wallet, migrationTotal)).wait(1);

  const targetList = [...targets.values()];
  for (const target of targetList) {
    await (await newWallet.bindWallet(target.accountId, target.wallet)).wait(1);
  }
  for (let offset = 0; offset < targetList.length; offset += 50) {
    const batch = targetList.slice(offset, offset + 50);
    await (
      await newWallet.migrateBalances(
        batch.map((item) => item.accountId),
        batch.map((item) => item.cash),
        batch.map((item) => item.bonus),
      )
    ).wait(1);
  }
  if (BigInt(snapshot.totals.bonusReserve) > 0n) {
    await (await newWallet.fundBonusPool(snapshot.totals.bonusReserve)).wait(1);
  }

  const [oldFinal, newFinal, accounted] = await Promise.all([
    token.balanceOf(snapshot.contracts.wallet),
    token.balanceOf(deployment.wallet),
    newWallet.accountedBalance(),
  ]);
  if (BigInt(oldFinal) !== 0n) throw new Error(`old wallet retains ${oldFinal}`);
  if (BigInt(newFinal) !== migrationTotal || BigInt(accounted) !== migrationTotal) {
    throw new Error(`new wallet reconciliation failed: token=${newFinal}, accounted=${accounted}`);
  }
  const receipt = {
    completedAt: new Date().toISOString(),
    oldWallet: snapshot.contracts.wallet,
    newWallet: deployment.wallet,
    migrated: migrationTotal.toString(),
    oldFinal: oldFinal.toString(),
    newFinal: newFinal.toString(),
    accounted: accounted.toString(),
  };
  writeFileSync(
    "migration/migration-v2-receipt.json",
    JSON.stringify(receipt, null, 2) + "\n",
  );
  console.log(JSON.stringify(receipt, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
