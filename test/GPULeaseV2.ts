import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("GPULease V2 account-ID accounting", function () {
  let owner: any;
  let registrar: any;
  let userWallet: any;
  let replacementWallet: any;
  let payer: any;
  let providerWallet: any;
  let relayer: any;
  let token: any;
  let wallet: any;
  let lease: any;
  let referral: any;

  const unit = 1_000_000n;
  const userId = ethers.keccak256(ethers.toUtf8Bytes("user-uuid"));
  const providerId = ethers.keccak256(ethers.toUtf8Bytes("provider-uuid"));
  const treasuryId = ethers.keccak256(ethers.toUtf8Bytes("antgpu:treasury"));

  beforeEach(async () => {
    [owner, registrar, userWallet, replacementWallet, payer, providerWallet, relayer] =
      await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Mock USDC", "USDC");

    const Wallet = await ethers.getContractFactory("GPULeaseWalletV2");
    wallet = await Wallet.deploy(token.target, registrar.address);

    const Referral = await ethers.getContractFactory("GPULeaseReferralV2");
    referral = await Referral.deploy();

    const Lease = await ethers.getContractFactory("GPULeaseV2");
    lease = await Lease.deploy(wallet.target, treasuryId);
    await wallet.setLeaseManager(lease.target);
    await lease.setReferralManager(referral.target);

    await token.mint(payer.address, 10_000n * unit);
    await token.mint(owner.address, 10_000n * unit);
    await token.connect(payer).approve(wallet.target, ethers.MaxUint256);
    await token.approve(wallet.target, ethers.MaxUint256);
  });

  async function eip712Domain() {
    const { chainId } = await ethers.provider.getNetwork();
    return {
      name: "GPULeaseWalletV2",
      version: "1",
      chainId,
      verifyingContract: await wallet.getAddress(),
    };
  }

  it("holds funds by account ID before a wallet exists", async () => {
    await expect(wallet.connect(payer).depositFor(providerId, 125n * unit))
      .to.emit(wallet, "Deposit")
      .withArgs(providerId, payer.address, 125n * unit);

    expect(await wallet.walletOf(providerId)).to.equal(ethers.ZeroAddress);
    expect(await wallet.withdrawableBalance(providerId)).to.equal(125n * unit);
    expect(await wallet.accountedBalance()).to.equal(125n * unit);
    await expect(wallet.connect(providerWallet).withdraw(providerId, unit)).to.be.revertedWith(
      "not linked wallet",
    );
  });

  it("lets the registrar bind and rotate a withdrawal wallet without moving funds", async () => {
    await wallet.connect(payer).depositFor(providerId, 125n * unit);

    await expect(wallet.connect(registrar).bindWallet(providerId, providerWallet.address))
      .to.emit(wallet, "WalletBound")
      .withArgs(providerId, ethers.ZeroAddress, providerWallet.address);

    await wallet.connect(registrar).bindWallet(providerId, replacementWallet.address);
    expect(await wallet.walletOf(providerId)).to.equal(replacementWallet.address);
    expect(await wallet.accountOfWallet(providerWallet.address)).to.equal(ethers.ZeroHash);
    expect(await wallet.withdrawableBalance(providerId)).to.equal(125n * unit);

    await expect(wallet.connect(providerWallet).withdraw(providerId, unit)).to.be.revertedWith(
      "not linked wallet",
    );
    await wallet.connect(replacementWallet).withdraw(providerId, 25n * unit);
    expect(await token.balanceOf(replacementWallet.address)).to.equal(25n * unit);
    expect(await wallet.withdrawableBalance(providerId)).to.equal(100n * unit);
  });

  it("prevents a wallet from being bound to two accounts", async () => {
    await wallet.connect(registrar).bindWallet(userId, userWallet.address);
    await expect(
      wallet.connect(registrar).bindWallet(providerId, userWallet.address),
    ).to.be.revertedWith("wallet already bound");
  });

  it("merges a temporary legacy account into a canonical user ID", async () => {
    const legacyId = ethers.keccak256(
      ethers.toUtf8Bytes(`antgpu:legacy-wallet:${userWallet.address.toLowerCase()}`),
    );
    await wallet.connect(payer).depositFor(legacyId, 50n * unit);
    await wallet.connect(registrar).bindWallet(legacyId, userWallet.address);

    await expect(wallet.connect(registrar).mergeAccount(legacyId, userId))
      .to.emit(wallet, "AccountMerged")
      .withArgs(legacyId, userId, 50n * unit, 0);

    expect(await wallet.withdrawableBalance(legacyId)).to.equal(0);
    expect(await wallet.withdrawableBalance(userId)).to.equal(50n * unit);
    expect(await wallet.walletOf(userId)).to.equal(userWallet.address);
    expect(await wallet.accountOfWallet(userWallet.address)).to.equal(userId);
  });

  it("supports fully gasless wallet binding with registrar and wallet signatures", async () => {
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const value = {
      accountId: userId,
      wallet: userWallet.address,
      nonce: 0n,
      deadline,
    };
    const types = {
      BindWallet: [
        { name: "accountId", type: "bytes32" },
        { name: "wallet", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const domain = await eip712Domain();
    const registrarSignature = await registrar.signTypedData(domain, types, value);
    const walletSignature = await userWallet.signTypedData(domain, types, value);

    await expect(
      wallet
        .connect(relayer)
        .bindWalletWithSignatures(
          userId,
          userWallet.address,
          deadline,
          registrarSignature,
          walletSignature,
        ),
    )
      .to.emit(wallet, "WalletBound")
      .withArgs(userId, ethers.ZeroAddress, userWallet.address);

    expect(await wallet.walletOf(userId)).to.equal(userWallet.address);
    expect(await wallet.bindNonces(userId)).to.equal(1);
    await expect(
      wallet
        .connect(relayer)
        .bindWalletWithSignatures(
          userId,
          userWallet.address,
          deadline,
          registrarSignature,
          walletSignature,
        ),
    ).to.be.revertedWith("invalid registrar signature");
  });

  it("supports a relayed gasless withdrawal and blocks replay", async () => {
    await wallet.connect(payer).depositFor(userId, 100n * unit);
    await wallet.connect(registrar).bindWallet(userId, userWallet.address);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const value = { accountId: userId, amount: 40n * unit, nonce: 0n, deadline };
    const types = {
      Withdraw: [
        { name: "accountId", type: "bytes32" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const signature = await userWallet.signTypedData(
      await eip712Domain(),
      types,
      value,
    );

    await expect(
      wallet
        .connect(relayer)
        .withdrawWithSignature(userId, 40n * unit, deadline, signature),
    )
      .to.emit(wallet, "Withdraw")
      .withArgs(userId, userWallet.address, relayer.address, 40n * unit);

    expect(await token.balanceOf(userWallet.address)).to.equal(40n * unit);
    expect(await wallet.withdrawableBalance(userId)).to.equal(60n * unit);
    expect(await wallet.withdrawNonces(userId)).to.equal(1);
    await expect(
      wallet
        .connect(relayer)
        .withdrawWithSignature(userId, 40n * unit, deadline, signature),
    ).to.be.revertedWith("invalid wallet signature");
  });

  it("imports only fully funded legacy balances and tracks liabilities", async () => {
    await wallet.migrateBalances(
      [userId, providerId],
      [30n * unit, 70n * unit],
      [20n * unit, 0],
    );

    expect(await wallet.withdrawableBalance(userId)).to.equal(30n * unit);
    expect(await wallet.bonusBalance(userId)).to.equal(20n * unit);
    expect(await wallet.withdrawableBalance(providerId)).to.equal(70n * unit);
    expect(await wallet.totalCashLiability()).to.equal(100n * unit);
    expect(await wallet.totalBonusLiability()).to.equal(20n * unit);
    expect(await wallet.accountedBalance()).to.equal(120n * unit);
    expect(await token.balanceOf(wallet.target)).to.equal(120n * unit);
  });

  it("credits a provider ID with no wallet and permits later gasless withdrawal", async () => {
    await lease.setPlatformFee(10);
    await wallet.connect(payer).depositFor(userId, 1_000n * unit);

    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing block");
    const startTimestamp = block.timestamp + 1;
    await ethers.provider.send("evm_setNextBlockTimestamp", [startTimestamp]);
    await lease.startLease(startTimestamp, 100, unit, 0, providerId, userId);
    await ethers.provider.send("evm_increaseTime", [101]);
    await ethers.provider.send("evm_mine", []);
    await lease.completeLease(0);

    const providerBalance = await wallet.withdrawableBalance(providerId);
    expect(providerBalance).to.be.gt(0);
    expect(await wallet.walletOf(providerId)).to.equal(ethers.ZeroAddress);

    await wallet.connect(registrar).bindWallet(providerId, providerWallet.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const value = {
      accountId: providerId,
      amount: providerBalance,
      nonce: 0n,
      deadline,
    };
    const types = {
      Withdraw: [
        { name: "accountId", type: "bytes32" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const signature = await providerWallet.signTypedData(
      await eip712Domain(),
      types,
      value,
    );
    await wallet
      .connect(relayer)
      .withdrawWithSignature(providerId, providerBalance, deadline, signature);
    expect(await token.balanceOf(providerWallet.address)).to.equal(providerBalance);
  });

  it("keeps bonus and cash accounting consistent across lease refunds", async () => {
    await wallet.fundBonusPool(60n * unit);
    await wallet.grantBonus(userId, 60n * unit);
    await wallet.connect(payer).depositFor(userId, 50n * unit);
    await lease.setPlatformFee(0);

    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("missing block");
    const startTimestamp = block.timestamp + 1;
    await ethers.provider.send("evm_setNextBlockTimestamp", [startTimestamp]);
    await lease.startLease(startTimestamp, 100, unit, 0, providerId, userId);

    expect(await lease.frozenBonusFunds(0)).to.equal(60n * unit);
    expect(await lease.frozenCashFunds(0)).to.equal(40n * unit);
    expect(await wallet.withdrawableBalance(userId)).to.equal(10n * unit);
    await ethers.provider.send("evm_increaseTime", [50]);
    await ethers.provider.send("evm_mine", []);
    await lease.completeLease(0);
    expect(await wallet.spendableBalance(userId)).to.be.gt(10n * unit);
    expect(await token.balanceOf(wallet.target)).to.equal(await wallet.accountedBalance());
  });
});
