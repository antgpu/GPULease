import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("LLMFundraising campaigns V2", function () {
  it("credits a successful campaign to the creator ID without a wallet", async () => {
    const [backend, donor, treasury] = await ethers.getSigners();
    const creatorId = ethers.keccak256(
      ethers.toUtf8Bytes("user-without-wallet"),
    );
    const target = ethers.parseEther("1000");
    const fundingTarget = ethers.parseEther("1050");

    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy("Mock USDC", "USDC");
    await token.mint(donor.address, fundingTarget);

    const Wallet = await ethers.getContractFactory("GPULeaseWalletV2");
    const wallet = await Wallet.deploy(token.target, backend.address);

    const MetadataRenderer = await ethers.getContractFactory(
      "CampaignMetadataRenderer",
    );
    const renderer = await MetadataRenderer.deploy();

    const Factory = await ethers.getContractFactory(
      "LLMFundraisingFactoryV2",
    );
    const factory = await Factory.deploy(
      token.target,
      wallet.target,
      renderer.target,
      treasury.address,
    );

    await expect(
      factory.connect(donor).createCampaign(
        creatorId,
        target,
        7 * 24 * 60 * 60,
        1,
        1,
        "Spoofed creator",
      ),
    ).to.be.revertedWith("caller not bound to account");

    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("Cannot fetch latest block");
    await factory.createCampaignFor(
      creatorId,
      backend.address,
      target,
      7 * 24 * 60 * 60,
      block.timestamp,
      1,
      "Creator without wallet",
    );

    const campaignAddress = await factory.campaignById(1);
    const campaign = await ethers.getContractAt(
      "LLMFundraisingV2",
      campaignAddress,
    );
    expect(await campaign.creatorAccountId()).to.equal(creatorId);
    expect(await wallet.walletOf(creatorId)).to.equal(ethers.ZeroAddress);

    await token.connect(donor).approve(campaignAddress, fundingTarget);
    await campaign.connect(donor).donate(fundingTarget);

    expect(await campaign.state()).to.equal(1);
    expect(await wallet.withdrawableBalance(creatorId)).to.equal(target);
    expect(await wallet.totalCashLiability()).to.equal(target);
    expect(await token.balanceOf(wallet.target)).to.equal(target);
    expect(await token.balanceOf(treasury.address)).to.equal(
      ethers.parseEther("50"),
    );
    expect(await factory.campaignsByCreatorId(creatorId)).to.deep.equal([
      campaignAddress,
    ]);
  });
});
