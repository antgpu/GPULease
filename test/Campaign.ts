import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("LLMFundraising campaigns", function () {
  let owner: any;
  let donor: any;
  let secondDonor: any;
  let treasury: any;

  let token: any;
  let gpuLease: any;
  let factory: any;

  const campaignName = "Open LLM GPU Fund";
  const campaignURI = "ipfs://campaign";
  const targetAmount = ethers.parseEther("1000");

  async function deployCampaign() {
    const block = await ethers.provider.getBlock("latest");
    if (!block) throw new Error("Cannot fetch latest block");

    await factory.createCampaign(
      targetAmount,
      7 * 24 * 60 * 60,
      block.timestamp,
      1,
      campaignName,
      campaignURI
    );

    const campaignAddress = await factory.campaignById(1);
    return ethers.getContractAt("LLMFundraising", campaignAddress);
  }

  beforeEach(async () => {
    [owner, donor, secondDonor, treasury] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Mock USDC", "USDC");

    await token.mint(donor.address, ethers.parseEther("2000"));
    await token.mint(secondDonor.address, ethers.parseEther("2000"));

    const GPULease = await ethers.getContractFactory("GPULease");
    gpuLease = await GPULease.deploy(token.target, treasury.address);

    const Factory = await ethers.getContractFactory("LLMFundraisingFactory");
    factory = await Factory.deploy(token.target, gpuLease.target);
  });

  it("stores campaign name and indexes participants inside the campaign", async () => {
    const campaign = await deployCampaign();
    const campaignAddress = await campaign.getAddress();

    await token
      .connect(donor)
      .approve(campaignAddress, ethers.parseEther("200"));
    await token
      .connect(secondDonor)
      .approve(campaignAddress, ethers.parseEther("50"));

    await campaign.connect(donor).donate(ethers.parseEther("100"));
    await campaign.connect(secondDonor).donate(ethers.parseEther("50"));
    await campaign.connect(donor).donate(ethers.parseEther("25"));

    expect(await campaign.campaignName()).to.equal(campaignName);
    expect(await campaign.donorsCount()).to.equal(2);
    expect(await campaign.donorAt(0)).to.equal(donor.address);
    expect(await campaign.donorAt(1)).to.equal(secondDonor.address);
    expect(await campaign.donors()).to.deep.equal([
      donor.address,
      secondDonor.address,
    ]);
    expect(await campaign.donorsSlice(1, 10)).to.deep.equal([
      secondDonor.address,
    ]);
    expect(await campaign.donorsSlice(10, 10)).to.deep.equal([]);

    const info = await campaign.donorInfo(donor.address);
    expect(info.participated).to.equal(true);
    expect(info.donatedAmount).to.equal(ethers.parseEther("125"));
    expect(info.targetShareBps).to.equal(1250);
    expect(info.grade).to.equal(3);
    expect(info.wasRefunded).to.equal(false);
    expect(info.rewardTokenId).to.equal(0);
  });

  it("indexes campaigns by participant in the factory", async () => {
    const campaign = await deployCampaign();
    const campaignAddress = await campaign.getAddress();

    await token
      .connect(donor)
      .approve(campaignAddress, ethers.parseEther("200"));

    await campaign.connect(donor).donate(ethers.parseEther("100"));
    await campaign.connect(donor).donate(ethers.parseEther("50"));

    expect(await factory.campaignsByParticipant(donor.address)).to.deep.equal([
      campaignAddress,
    ]);
    expect(await factory.participantCampaignsCount(donor.address)).to.equal(1);
    expect(await factory.participantCampaignAt(donor.address, 0)).to.equal(
      campaignAddress
    );
    expect(
      await factory.hasParticipatedInCampaign(donor.address, campaignAddress)
    ).to.equal(true);
    expect(
      await factory.hasParticipatedInCampaign(
        secondDonor.address,
        campaignAddress
      )
    ).to.equal(false);
  });

  it("mints one reward NFT per donor after campaign success", async () => {
    const campaign = await deployCampaign();
    const campaignAddress = await campaign.getAddress();

    await token
      .connect(donor)
      .approve(campaignAddress, ethers.parseEther("100"));
    await token
      .connect(secondDonor)
      .approve(campaignAddress, ethers.parseEther("900"));

    await campaign.connect(donor).donate(ethers.parseEther("100"));
    await campaign.connect(secondDonor).donate(ethers.parseEther("900"));

    expect(await campaign.state()).to.equal(1);

    await expect(campaign.connect(donor).claimBackerReward())
      .to.emit(campaign, "BackerRewardMinted")
      .withArgs(donor.address, 1, campaignName, 3);

    await expect(campaign.connect(secondDonor).claimBackerReward())
      .to.emit(campaign, "BackerRewardMinted")
      .withArgs(secondDonor.address, 2, campaignName, 4);

    expect(await campaign.ownerOf(1)).to.equal(donor.address);
    expect(await campaign.ownerOf(2)).to.equal(secondDonor.address);
    expect(await campaign.rewardTokenByDonor(donor.address)).to.equal(1);
    expect(await campaign.rewardTokenGrades(1)).to.equal(3);
    expect(await campaign.rewardTokenGrades(2)).to.equal(4);

    const tokenURI = await campaign.tokenURI(2);
    const encodedJson = tokenURI.replace("data:application/json;base64,", "");
    const metadata = JSON.parse(Buffer.from(encodedJson, "base64").toString());

    expect(metadata.name).to.equal(`${campaignName} - Lead Backer`);
    expect(metadata.attributes).to.deep.include({
      trait_type: "Campaign",
      value: campaignName,
    });
    expect(metadata.attributes).to.deep.include({
      trait_type: "Backer Level",
      value: "Lead Backer",
    });
  });

  it("does not allow reward minting before success or double minting", async () => {
    const campaign = await deployCampaign();
    const campaignAddress = await campaign.getAddress();

    await token
      .connect(donor)
      .approve(campaignAddress, ethers.parseEther("1000"));

    await campaign.connect(donor).donate(ethers.parseEther("100"));

    await expect(
      campaign.connect(donor).claimBackerReward()
    ).to.be.revertedWith("not successful");

    await campaign.connect(donor).donate(ethers.parseEther("900"));
    await campaign.connect(donor).claimBackerReward();

    await expect(
      campaign.connect(donor).claimBackerReward()
    ).to.be.revertedWith("already minted");
  });
});
