import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  Contract,
  Interface,
  JsonRpcProvider,
  formatUnits,
  getAddress,
  isAddress,
  keccak256,
  toUtf8Bytes,
} from "ethers";

const RPC_URL =
  process.env.SNAPSHOT_RPC_URL ??
  "https://base-mainnet.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161";
const WALLET_ADDRESS =
  process.env.OLD_GPULEASE_WALLET_ADDRESS ??
  "0xf6d56d64938b65c6Ad58cFD447Cd1d74b39eEeF2";
const LEASE_ADDRESS =
  process.env.OLD_GPULEASE_ADDRESS ??
  "0x1350d6D31dc4c8B1314aF51d99e61cF0E3da938f";
const REFERRAL_ADDRESS =
  process.env.OLD_GPULEASE_REFERRAL_ADDRESS ??
  "0x2695d98bF8b233539f5a1Fb823298AA055f2a143";
const VERIFIER_ADDRESS =
  process.env.OLD_VERIFIER_ADDRESS ??
  "0xcacA2090Ae57d990A1A5CbDC43d8128864380511";
const CAMPAIGN_FACTORY_ADDRESS =
  process.env.OLD_CAMPAIGN_FACTORY_ADDRESS ??
  "0x40C99f349A8cB30d452c9cdc7808221D57427851";
const USDC_ADDRESS =
  process.env.USDC_ADDRESS ?? "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
const WALLET_START_BLOCK = Number(process.env.OLD_WALLET_START_BLOCK ?? 49_919_840);
const VERIFIER_START_BLOCK = Number(process.env.OLD_VERIFIER_START_BLOCK ?? 45_000_000);
const LOG_BLOCK_SPAN = Number(process.env.SNAPSHOT_LOG_BLOCK_SPAN ?? 10_000);
const OUTPUT_DIR = resolve(process.env.SNAPSHOT_OUTPUT_DIR ?? "migration");
const PROGRESS_FILE = resolve(OUTPUT_DIR, "snapshot-v1-progress.json");
const OUTPUT_FILE = resolve(OUTPUT_DIR, "snapshot-v1.json");

const provider = new JsonRpcProvider(RPC_URL, 8453, { staticNetwork: true });

const walletInterface = new Interface([
  "event Deposit(address indexed user,uint256 amount)",
  "event Withdraw(address indexed user,uint256 amount)",
  "event BonusGranted(address indexed user,uint256 amount)",
  "event BonusRevoked(address indexed user,uint256 amount)",
  "event LeaseBalanceDebited(address indexed user,uint256 cashAmount,uint256 bonusAmount)",
  "event LeaseBalanceRefunded(address indexed user,uint256 cashAmount,uint256 bonusAmount)",
]);
const verifierInterface = new Interface([
  "event WalletVerified(address indexed wallet,string userId)",
]);

type StoredLog = {
  address: string;
  blockNumber: number;
  transactionHash: string;
  index: number;
  topics: readonly string[];
  data: string;
};

type ScanProgress = {
  chainId: string;
  snapshotBlock: number;
  walletNextBlock: number;
  verifierNextBlock: number;
  walletLogs: StoredLog[];
  verifierLogs: StoredLog[];
};

function sleep(ms: number) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function serializableLog(log: any): StoredLog {
  return {
    address: log.address,
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    index: log.index,
    topics: log.topics,
    data: log.data,
  };
}

async function getLogsWithRetry(address: string, fromBlock: number, toBlock: number) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await provider.getLogs({ address, fromBlock, toBlock });
    } catch (error) {
      if (attempt >= 20) throw error;
      const delay = Math.min(15_000, 500 * 2 ** Math.min(attempt, 5));
      console.warn(
        `getLogs retry ${attempt + 1}: ${address} ${fromBlock}-${toBlock}; waiting ${delay}ms`,
      );
      await sleep(delay);
    }
  }
}

async function scanLogs(
  progress: ScanProgress,
  kind: "wallet" | "verifier",
  address: string,
) {
  const nextKey = kind === "wallet" ? "walletNextBlock" : "verifierNextBlock";
  const logsKey = kind === "wallet" ? "walletLogs" : "verifierLogs";
  while (progress[nextKey] <= progress.snapshotBlock) {
    const fromBlock = progress[nextKey];
    const toBlock = Math.min(progress.snapshotBlock, fromBlock + LOG_BLOCK_SPAN);
    const logs = await getLogsWithRetry(address, fromBlock, toBlock);
    progress[logsKey].push(...logs.map(serializableLog));
    progress[nextKey] = toBlock + 1;
    writeFileSync(PROGRESS_FILE, JSON.stringify(progress, null, 2) + "\n");
    console.log(`${kind}: ${fromBlock}-${toBlock}, total logs ${progress[logsKey].length}`);
    await sleep(150);
  }
}

function addAddress(addresses: Set<string>, value: string) {
  if (isAddress(value)) addresses.add(getAddress(value));
}

async function main() {
  mkdirSync(OUTPUT_DIR, { recursive: true });
  const network = await provider.getNetwork();
  if (network.chainId !== 8453n) throw new Error(`unexpected chain ${network.chainId}`);

  let progress: ScanProgress;
  if (existsSync(PROGRESS_FILE)) {
    progress = JSON.parse(readFileSync(PROGRESS_FILE, "utf8"));
    console.log(`resuming snapshot at block ${progress.snapshotBlock}`);
  } else {
    progress = {
      chainId: network.chainId.toString(),
      snapshotBlock: await provider.getBlockNumber(),
      walletNextBlock: WALLET_START_BLOCK,
      verifierNextBlock: VERIFIER_START_BLOCK,
      walletLogs: [],
      verifierLogs: [],
    };
    writeFileSync(PROGRESS_FILE, JSON.stringify(progress, null, 2) + "\n");
  }

  await scanLogs(progress, "wallet", WALLET_ADDRESS);
  await scanLogs(progress, "verifier", VERIFIER_ADDRESS);

  const wallet = new Contract(
    WALLET_ADDRESS,
    [
      "function balances(address) view returns(uint256)",
      "function bonusBalances(address) view returns(uint256)",
      "function bonusReserve() view returns(uint256)",
      "function owner() view returns(address)",
      "function leaseManager() view returns(address)",
    ],
    provider,
  );
  const lease = new Contract(
    LEASE_ADDRESS,
    [
      "function owner() view returns(address)",
      "function treasury() view returns(address)",
      "function leaseCount() view returns(uint256)",
      "function leases(uint256) view returns(address user,address provider,uint256 startTime,uint256 duration,uint256 storagePricePerSecond,uint256 computePricePerSecond,uint256 leaseFeePercentage,bool active,bool completed,bool paused,uint256 pausedAt,uint256 pausedDuration)",
      "function frozenFunds(uint256) view returns(uint256)",
    ],
    provider,
  );
  const referral = new Contract(
    REFERRAL_ADDRESS,
    ["function referrerOf(address) view returns(address)"],
    provider,
  );
  const usdc = new Contract(
    USDC_ADDRESS,
    ["function balanceOf(address) view returns(uint256)"],
    provider,
  );

  const candidates = new Set<string>();
  for (const log of progress.walletLogs) {
    try {
      const parsed = walletInterface.parseLog(log);
      if (parsed?.args.user) addAddress(candidates, parsed.args.user);
    } catch {}
  }

  const leaseCount = BigInt(await lease.leaseCount({ blockTag: progress.snapshotBlock }));
  let frozenTotal = 0n;
  const activeLeaseIds: string[] = [];
  for (let leaseId = 0n; leaseId < leaseCount; leaseId += 1n) {
    const item = await lease.leases(leaseId, { blockTag: progress.snapshotBlock });
    addAddress(candidates, item.user);
    addAddress(candidates, item.provider);
    const referrer = await referral.referrerOf(item.user, {
      blockTag: progress.snapshotBlock,
    });
    addAddress(candidates, referrer);
    if (item.active && !item.completed) {
      activeLeaseIds.push(leaseId.toString());
      frozenTotal += BigInt(
        await lease.frozenFunds(leaseId, { blockTag: progress.snapshotBlock }),
      );
    }
  }
  addAddress(candidates, await lease.owner({ blockTag: progress.snapshotBlock }));
  addAddress(candidates, await lease.treasury({ blockTag: progress.snapshotBlock }));
  addAddress(candidates, await wallet.owner({ blockTag: progress.snapshotBlock }));

  try {
    const factory = new Contract(
      CAMPAIGN_FACTORY_ADDRESS,
      [
        "function campaignsCount() view returns(uint256)",
        "function campaigns(uint256) view returns(address)",
      ],
      provider,
    );
    const campaignCount = BigInt(
      await factory.campaignsCount({ blockTag: progress.snapshotBlock }),
    );
    for (let i = 0n; i < campaignCount; i += 1n) {
      const campaignAddress = await factory.campaigns(i, {
        blockTag: progress.snapshotBlock,
      });
      const campaign = new Contract(
        campaignAddress,
        ["function owner() view returns(address)"],
        provider,
      );
      addAddress(candidates, await campaign.owner({ blockTag: progress.snapshotBlock }));
    }
  } catch (error) {
    console.warn(`campaign enumeration skipped: ${String(error)}`);
  }

  const verifierClaims = new Map<string, { userId: string; blockNumber: number }>();
  for (const log of progress.verifierLogs) {
    try {
      const parsed = verifierInterface.parseLog(log);
      if (!parsed) continue;
      const address = getAddress(parsed.args.wallet);
      const existing = verifierClaims.get(address.toLowerCase());
      if (!existing || log.blockNumber >= existing.blockNumber) {
        verifierClaims.set(address.toLowerCase(), {
          userId: parsed.args.userId,
          blockNumber: log.blockNumber,
        });
      }
    } catch {}
  }

  const accounts = [];
  let cashTotal = 0n;
  let bonusTotal = 0n;
  for (const address of [...candidates].sort()) {
    const [cash, bonus] = await Promise.all([
      wallet.balances(address, { blockTag: progress.snapshotBlock }),
      wallet.bonusBalances(address, { blockTag: progress.snapshotBlock }),
    ]);
    const cashAmount = BigInt(cash);
    const bonusAmount = BigInt(bonus);
    if (cashAmount === 0n && bonusAmount === 0n) continue;
    cashTotal += cashAmount;
    bonusTotal += bonusAmount;
    const claim = verifierClaims.get(address.toLowerCase());
    accounts.push({
      address,
      cash: cashAmount.toString(),
      bonus: bonusAmount.toString(),
      cashUsdc: formatUnits(cashAmount, 6),
      bonusUsdc: formatUnits(bonusAmount, 6),
      verifierUserIdClaim: claim?.userId ?? null,
      claimedAccountId: claim ? keccak256(toUtf8Bytes(claim.userId)) : null,
      verifierClaimBlock: claim?.blockNumber ?? null,
      databaseVerified: false,
    });
  }

  const [reserveRaw, tokenBalanceRaw, walletOwner, leaseManager] = await Promise.all([
    wallet.bonusReserve({ blockTag: progress.snapshotBlock }),
    usdc.balanceOf(WALLET_ADDRESS, { blockTag: progress.snapshotBlock }),
    wallet.owner({ blockTag: progress.snapshotBlock }),
    wallet.leaseManager({ blockTag: progress.snapshotBlock }),
  ]);
  const reserve = BigInt(reserveRaw);
  const tokenBalance = BigInt(tokenBalanceRaw);
  const accounted = cashTotal + bonusTotal + reserve + frozenTotal;
  const complete = accounted === tokenBalance;

  const output = {
    generatedAt: new Date().toISOString(),
    chainId: progress.chainId,
    snapshotBlock: progress.snapshotBlock,
    contracts: {
      wallet: WALLET_ADDRESS,
      lease: LEASE_ADDRESS,
      referral: REFERRAL_ADDRESS,
      verifier: VERIFIER_ADDRESS,
      campaignFactory: CAMPAIGN_FACTORY_ADDRESS,
      usdc: USDC_ADDRESS,
    },
    walletOwner,
    leaseManager,
    leaseCount: leaseCount.toString(),
    activeLeaseIds,
    totals: {
      cash: cashTotal.toString(),
      bonus: bonusTotal.toString(),
      bonusReserve: reserve.toString(),
      frozen: frozenTotal.toString(),
      accounted: accounted.toString(),
      tokenBalance: tokenBalance.toString(),
      accountedUsdc: formatUnits(accounted, 6),
      tokenBalanceUsdc: formatUnits(tokenBalance, 6),
    },
    completenessCheckPassed: complete,
    warning:
      "Verifier events are untrusted user claims. Set databaseVerified=true only after joining against launchpad.verified_wallets.",
    accounts,
  };
  writeFileSync(OUTPUT_FILE, JSON.stringify(output, null, 2) + "\n");
  console.log(`wrote ${OUTPUT_FILE}`);
  console.log(
    `accounts=${accounts.length} accounted=${formatUnits(accounted, 6)} USDC token=${formatUnits(tokenBalance, 6)} USDC complete=${complete}`,
  );
  if (!complete) process.exitCode = 2;
  if (activeLeaseIds.length > 0) process.exitCode = 3;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
