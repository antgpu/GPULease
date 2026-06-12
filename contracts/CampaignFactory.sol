// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    ICampaignParticipantRegistry,
    IGPULease,
    LLMFundraising
} from "./Campaign.sol";

contract LLMFundraisingFactory is Ownable, ICampaignParticipantRegistry {
    uint256 public nextCampaignId = 1;

    IERC20 public immutable usdc;
    IGPULease public immutable gpuLease;

    address[] public campaigns;
    mapping(uint256 => address) public campaignById;
    mapping(address => bool) public isCampaign;
    mapping(address => address[]) private _campaignsByCreator;
    mapping(address => address[]) private _campaignsByParticipant;
    mapping(address => mapping(address => bool)) private _participantInCampaign;

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed campaign,
        address indexed creator,
        uint256 targetAmount,
        uint256 startTimestamp,
        uint256 duration,
        uint256 templateId,
        string campaignName,
        string campaignURI
    );
    event CampaignParticipantRegistered(
        address indexed participant,
        address indexed campaign
    );

    constructor(address _usdc, address _gpuLease) Ownable(msg.sender) {
        require(_usdc != address(0), "zero usdc");
        require(_gpuLease != address(0), "zero gpuLease");

        usdc = IERC20(_usdc);
        gpuLease = IGPULease(_gpuLease);
    }

    function createCampaign(
        uint256 targetAmount,
        uint256 duration,
        uint256 startTimestamp,
        uint256 templateId,
        string calldata campaignName,
        string calldata campaignURI
    ) external returns (address campaign) {
        uint256 campaignId = nextCampaignId;
        nextCampaignId += 1;

        campaign = address(
            new LLMFundraising(
                campaignId,
                targetAmount,
                duration,
                startTimestamp,
                templateId,
                campaignName,
                campaignURI,
                address(usdc),
                address(gpuLease),
                address(this),
                msg.sender
            )
        );

        campaigns.push(campaign);
        campaignById[campaignId] = campaign;
        isCampaign[campaign] = true;
        _campaignsByCreator[msg.sender].push(campaign);

        emit CampaignCreated(
            campaignId,
            campaign,
            msg.sender,
            targetAmount,
            startTimestamp,
            duration,
            templateId,
            campaignName,
            campaignURI
        );
    }

    function campaignsCount() external view returns (uint256) {
        return campaigns.length;
    }

    function campaignsByCreator(
        address creator
    ) external view returns (address[] memory) {
        return _campaignsByCreator[creator];
    }

    function registerParticipant(address participant) external {
        require(isCampaign[msg.sender], "not campaign");
        require(participant != address(0), "zero participant");

        if (_participantInCampaign[participant][msg.sender]) {
            return;
        }

        _participantInCampaign[participant][msg.sender] = true;
        _campaignsByParticipant[participant].push(msg.sender);

        emit CampaignParticipantRegistered(participant, msg.sender);
    }

    function campaignsByParticipant(
        address participant
    ) external view returns (address[] memory) {
        return _campaignsByParticipant[participant];
    }

    function participantCampaignsCount(
        address participant
    ) external view returns (uint256) {
        return _campaignsByParticipant[participant].length;
    }

    function participantCampaignAt(
        address participant,
        uint256 index
    ) external view returns (address) {
        return _campaignsByParticipant[participant][index];
    }

    function hasParticipatedInCampaign(
        address participant,
        address campaign
    ) external view returns (bool) {
        return _participantInCampaign[participant][campaign];
    }
}
