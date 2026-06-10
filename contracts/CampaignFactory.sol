// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IGPULease, LLMFundraising} from "./Campaign.sol";

contract LLMFundraisingFactory is Ownable {
    uint256 public nextCampaignId = 1;

    IERC20 public immutable usdc;
    IGPULease public immutable gpuLease;

    address[] public campaigns;
    mapping(uint256 => address) public campaignById;
    mapping(address => address[]) private _campaignsByCreator;

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed campaign,
        address indexed creator,
        uint256 targetAmount,
        uint256 startTimestamp,
        uint256 duration,
        uint256 templateId,
        string campaignURI
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
                campaignURI,
                address(usdc),
                address(gpuLease),
                msg.sender
            )
        );

        campaigns.push(campaign);
        campaignById[campaignId] = campaign;
        _campaignsByCreator[msg.sender].push(campaign);

        emit CampaignCreated(
            campaignId,
            campaign,
            msg.sender,
            targetAmount,
            startTimestamp,
            duration,
            templateId,
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
}
