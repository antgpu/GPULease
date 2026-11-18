// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CampaignV2.sol";

contract LLMFundraisingFactoryV2 is Ownable, ICampaignParticipantRegistry {
    using Clones for address;

    struct CampaignParams {
        bytes32 creatorAccountId;
        address campaignOwner;
        uint256 targetAmount;
        uint256 duration;
        uint256 startTimestamp;
        uint256 templateId;
        string campaignName;
    }

    IERC20 public immutable usdc;
    address public immutable gpuLeaseWallet;
    address public immutable metadataRenderer;
    address public immutable feeRecipient;
    address public immutable campaignImplementation;
    uint256 public nextCampaignId = 1;

    address[] public campaigns;
    mapping(uint256 => address) public campaignById;
    mapping(address => bool) public isCampaign;
    mapping(bytes32 => address[]) private _campaignsByCreatorId;
    mapping(address => address[]) private _campaignsByParticipant;
    mapping(address => mapping(address => bool)) private _participantInCampaign;

    event CampaignCreatedV2(
        uint256 indexed campaignId,
        address indexed campaign,
        bytes32 indexed creatorAccountId,
        address campaignOwner,
        uint256 targetAmount,
        uint256 startTimestamp,
        uint256 duration,
        uint256 templateId,
        string campaignName
    );
    event CampaignParticipantRegistered(
        address indexed participant,
        address indexed campaign
    );

    constructor(
        address usdc_,
        address gpuLeaseWallet_,
        address metadataRenderer_,
        address feeRecipient_
    ) Ownable(msg.sender) {
        require(usdc_ != address(0), "zero usdc");
        require(gpuLeaseWallet_ != address(0), "zero wallet");
        require(metadataRenderer_ != address(0), "zero renderer");
        require(feeRecipient_ != address(0), "zero fee recipient");
        usdc = IERC20(usdc_);
        gpuLeaseWallet = gpuLeaseWallet_;
        metadataRenderer = metadataRenderer_;
        feeRecipient = feeRecipient_;
        campaignImplementation = address(new LLMFundraisingV2());
    }

    /// @notice Backend/relayer path for a creator who has no wallet.
    function createCampaignFor(
        bytes32 creatorAccountId,
        address campaignOwner,
        uint256 targetAmount,
        uint256 duration,
        uint256 startTimestamp,
        uint256 templateId,
        string calldata campaignName
    ) external onlyOwner returns (uint256 campaignId, address campaign) {
        CampaignParams memory params = CampaignParams({
            creatorAccountId: creatorAccountId,
            campaignOwner: campaignOwner,
            targetAmount: targetAmount,
            duration: duration,
            startTimestamp: startTimestamp,
            templateId: templateId,
            campaignName: campaignName
        });
        return _createCampaign(params);
    }

    /// @notice Self-service path. The caller remains campaign admin, while
    /// proceeds are credited to the supplied application account ID.
    function createCampaign(
        bytes32 creatorAccountId,
        uint256 targetAmount,
        uint256 duration,
        uint256 startTimestamp,
        uint256 templateId,
        string calldata campaignName
    ) external returns (uint256 campaignId, address campaign) {
        require(
            IGPULeaseWalletV2Campaign(gpuLeaseWallet).accountOfWallet(
                msg.sender
            ) == creatorAccountId,
            "caller not bound to account"
        );
        CampaignParams memory params = CampaignParams({
            creatorAccountId: creatorAccountId,
            campaignOwner: msg.sender,
            targetAmount: targetAmount,
            duration: duration,
            startTimestamp: startTimestamp,
            templateId: templateId,
            campaignName: campaignName
        });
        return _createCampaign(params);
    }

    function registerParticipant(address participant) external override {
        require(isCampaign[msg.sender], "not campaign");
        if (!_participantInCampaign[participant][msg.sender]) {
            _participantInCampaign[participant][msg.sender] = true;
            _campaignsByParticipant[participant].push(msg.sender);
            emit CampaignParticipantRegistered(participant, msg.sender);
        }
    }

    function campaignsCount() external view returns (uint256) {
        return campaigns.length;
    }

    function campaignsByCreatorId(bytes32 creatorAccountId)
        external
        view
        returns (address[] memory)
    {
        return _campaignsByCreatorId[creatorAccountId];
    }

    function campaignsByParticipant(address participant)
        external
        view
        returns (address[] memory)
    {
        return _campaignsByParticipant[participant];
    }

    function _createCampaign(CampaignParams memory params)
        internal
        returns (uint256 campaignId, address campaign)
    {
        require(params.creatorAccountId != bytes32(0), "zero creator account");
        require(params.campaignOwner != address(0), "zero campaign owner");
        campaignId = nextCampaignId++;
        campaign = campaignImplementation.clone();
        LLMFundraisingV2(campaign).initializeCreatorAccount(
            params.creatorAccountId
        );
        LLMFundraisingV2(campaign).initialize(
            campaignId,
            params.targetAmount,
            params.duration,
            params.startTimestamp,
            params.templateId,
            params.campaignName,
            address(usdc),
            gpuLeaseWallet,
            address(this),
            metadataRenderer,
            params.campaignOwner
        );
        campaigns.push(campaign);
        campaignById[campaignId] = campaign;
        isCampaign[campaign] = true;
        _campaignsByCreatorId[params.creatorAccountId].push(campaign);
        emit CampaignCreatedV2(
            campaignId,
            campaign,
            params.creatorAccountId,
            params.campaignOwner,
            LLMFundraisingV2(campaign).targetAmount(),
            params.startTimestamp,
            params.duration,
            params.templateId,
            params.campaignName
        );
    }
}
