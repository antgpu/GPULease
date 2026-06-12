// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IGPULease {
    function deposit(uint256 amount) external;
}

interface ICampaignParticipantRegistry {
    function registerParticipant(address participant) external;
}

contract LLMFundraising is Ownable, ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // Backer tiers are calculated in basis points (bps) of the campaign target.
    // BPS is 100%, so 100 bps = 1%, 500 bps = 5%, and 1,500 bps = 15%.
    // A donor's total donations are divided by targetAmount to find their donated
    // percentage, then compared with these minimum thresholds to assign a grade.
    uint256 private constant BPS = 10_000;
    uint256 private constant CONTRIBUTOR_MIN_BPS = 100;
    uint256 private constant FOUNDING_BACKER_MIN_BPS = 500;
    uint256 private constant LEAD_BACKER_MIN_BPS = 1_500;
    bytes1 private constant JSON_QUOTE = 0x22;
    bytes1 private constant JSON_BACKSLASH = 0x5c;
    bytes1 private constant ASCII_0 = 0x30;
    bytes1 private constant ASCII_B = 0x62;
    bytes1 private constant ASCII_F = 0x66;
    bytes1 private constant ASCII_N = 0x6e;
    bytes1 private constant ASCII_R = 0x72;
    bytes1 private constant ASCII_T = 0x74;
    bytes1 private constant ASCII_U = 0x75;

    enum CampaignState {
        ACTIVE,
        SUCCESS,
        FAILED
    }

    enum BackerGrade {
        NONE,
        SUPPORTER,
        CONTRIBUTOR,
        FOUNDING_BACKER,
        LEAD_BACKER
    }

    uint256 public immutable campaignId;
    uint256 public immutable targetAmount;
    uint256 public immutable startTimestamp;
    uint256 public immutable duration;
    uint256 public immutable templateId;
    string public campaignName;

    IERC20 public immutable usdc;
    IGPULease public immutable gpuLease;
    ICampaignParticipantRegistry public immutable participantRegistry;

    CampaignState public state;
    uint256 public totalRaised;
    uint256 public nextRewardTokenId = 1;

    address[] private _donors;
    mapping(address => uint256) public donations;
    mapping(address => bool) public refunded;
    mapping(address => BackerGrade) public backerGrades;
    mapping(address => bool) public hasDonated;
    mapping(address => uint256) public rewardTokenByDonor;
    mapping(uint256 => BackerGrade) public rewardTokenGrades;

    event Donated(
        address indexed donor,
        uint256 amount,
        uint256 totalDonated,
        BackerGrade grade
    );
    event BackerGradeUpdated(
        address indexed donor,
        BackerGrade previousGrade,
        BackerGrade newGrade,
        uint256 totalDonated,
        uint256 targetShareBps
    );
    event CampaignSucceeded(uint256 totalRaised);
    event CampaignFailed(uint256 totalRaised);
    event Refunded(address indexed donor, uint256 amount);
    event FundsTransferred(address indexed gpuLease, uint256 amount);
    event BackerRewardMinted(
        address indexed donor,
        uint256 indexed tokenId,
        string campaignName,
        BackerGrade grade
    );

    constructor(
        uint256 _campaignId,
        uint256 _targetAmount,
        uint256 _duration,
        uint256 _startTimestamp,
        uint256 _templateId,
        string memory _campaignName,
        address _usdc,
        address _gpuLease,
        address _participantRegistry,
        address _campaignOwner
    ) Ownable(_campaignOwner) ERC721("LLM Fundraising Backer", "LLMBACKER") {
        require(_usdc != address(0), "zero usdc");
        require(_gpuLease != address(0), "zero gpuLease");
        require(_participantRegistry != address(0), "zero registry");
        require(_targetAmount > 0, "zero target");
        require(_duration > 0, "zero duration");
        require(bytes(_campaignName).length > 0, "empty name");

        campaignId = _campaignId;
        targetAmount = _targetAmount;
        duration = _duration;
        startTimestamp = _startTimestamp;
        templateId = _templateId;
        campaignName = _campaignName;

        usdc = IERC20(_usdc);
        gpuLease = IGPULease(_gpuLease);
        participantRegistry = ICampaignParticipantRegistry(
            _participantRegistry
        );

        state = CampaignState.ACTIVE;
    }

    function deadline() public view returns (uint256) {
        return startTimestamp + duration;
    }

    function isExpired() public view returns (bool) {
        return block.timestamp >= deadline();
    }

    function isTargetReached() public view returns (bool) {
        return totalRaised >= targetAmount;
    }

    function checkConditions()
        public
        view
        returns (bool expired, bool reached)
    {
        expired = isExpired();
        reached = isTargetReached();
    }

    function donorShareBps(address donor) public view returns (uint256) {
        return (donations[donor] * BPS) / targetAmount;
    }

    function gradeForDonation(
        address donor
    ) external view returns (BackerGrade) {
        return _bestAvailableGrade(donations[donor]);
    }

    function donorsCount() external view returns (uint256) {
        return _donors.length;
    }

    function donorAt(uint256 index) external view returns (address) {
        return _donors[index];
    }

    function donors() external view returns (address[] memory) {
        return _donors;
    }

    function donorsSlice(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory donors_) {
        uint256 donorCount = _donors.length;
        if (offset >= donorCount) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > donorCount) {
            end = donorCount;
        }

        donors_ = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            donors_[i - offset] = _donors[i];
        }
    }

    function donorInfo(
        address donor
    )
        external
        view
        returns (
            bool participated,
            uint256 donatedAmount,
            uint256 targetShareBps,
            BackerGrade grade,
            bool wasRefunded,
            uint256 rewardTokenId
        )
    {
        participated = hasDonated[donor];
        donatedAmount = donations[donor];
        targetShareBps = donorShareBps(donor);
        grade = backerGrades[donor];
        wasRefunded = refunded[donor];
        rewardTokenId = rewardTokenByDonor[donor];
    }

    function claimBackerReward() external nonReentrant returns (uint256 tokenId) {
        return _mintBackerReward(msg.sender);
    }

    function mintBackerRewards(
        uint256 offset,
        uint256 limit
    ) external nonReentrant returns (uint256 minted) {
        require(limit > 0, "zero limit");
        uint256 donorCount = _donors.length;
        require(offset < donorCount, "offset out of range");

        uint256 end = offset + limit;
        if (end > donorCount) {
            end = donorCount;
        }

        for (uint256 i = offset; i < end; i++) {
            address donor = _donors[i];
            if (rewardTokenByDonor[donor] == 0 && donations[donor] > 0) {
                _mintBackerReward(donor);
                minted += 1;
            }
        }
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);

        string memory gradeName = _backerGradeName(rewardTokenGrades[tokenId]);
        string memory escapedCampaignName = _escapeJson(campaignName);
        string memory escapedGradeName = _escapeJson(gradeName);

        bytes memory metadata = abi.encodePacked(
            '{"name":"',
            escapedCampaignName,
            " - ",
            escapedGradeName,
            '","description":"Backer reward NFT for a successful LLM fundraising campaign.",',
            '"attributes":[{"trait_type":"Campaign","value":"',
            escapedCampaignName,
            '"},{"trait_type":"Backer Level","value":"',
            escapedGradeName,
            '"},{"trait_type":"Campaign ID","value":"',
            campaignId.toString(),
            '"}]}'
        );

        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(metadata)
            );
    }

    function donate(uint256 amount) external nonReentrant {
        require(state == CampaignState.ACTIVE, "not active");
        require(block.timestamp >= startTimestamp, "not started");
        require(!isExpired(), "expired");
        require(amount > 0, "zero amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (!hasDonated[msg.sender]) {
            hasDonated[msg.sender] = true;
            _donors.push(msg.sender);
            participantRegistry.registerParticipant(msg.sender);
        }

        donations[msg.sender] += amount;
        totalRaised += amount;

        BackerGrade grade = _updateBackerGrade(msg.sender);

        emit Donated(msg.sender, amount, donations[msg.sender], grade);

        _evaluateState();
    }

    function checkState() external {
        require(state == CampaignState.ACTIVE, "already closed");
        _evaluateState();
    }

    function refund() external nonReentrant {
        require(state == CampaignState.FAILED, "not failed");

        uint256 amount = donations[msg.sender];
        require(amount > 0, "nothing to refund");
        require(!refunded[msg.sender], "already refunded");

        refunded[msg.sender] = true;
        donations[msg.sender] = 0;
        _setBackerGrade(msg.sender, BackerGrade.NONE);

        usdc.safeTransfer(msg.sender, amount);

        emit Refunded(msg.sender, amount);
    }

    function _evaluateState() internal {
        if (isTargetReached()) {
            _markSuccess();
        } else if (isExpired()) {
            _markFailed();
        }
    }

    function _markSuccess() internal {
        require(state == CampaignState.ACTIVE, "not active");

        uint256 balance = usdc.balanceOf(address(this));
        require(balance >= targetAmount, "insufficient funds");

        state = CampaignState.SUCCESS;

        _transferToGPULease(balance);

        emit CampaignSucceeded(balance);
    }

    function _markFailed() internal {
        require(state == CampaignState.ACTIVE, "not active");

        state = CampaignState.FAILED;

        emit CampaignFailed(totalRaised);
    }

    function _transferToGPULease(uint256 amount) internal {
        require(amount > 0, "no funds");

        usdc.forceApprove(address(gpuLease), amount);

        gpuLease.deposit(amount);

        emit FundsTransferred(address(gpuLease), amount);
    }

    function _mintBackerReward(
        address donor
    ) internal returns (uint256 tokenId) {
        require(state == CampaignState.SUCCESS, "not successful");
        require(donations[donor] > 0, "not donor");
        require(rewardTokenByDonor[donor] == 0, "already minted");

        BackerGrade grade = backerGrades[donor];
        require(grade != BackerGrade.NONE, "no grade");

        tokenId = nextRewardTokenId;
        nextRewardTokenId += 1;

        rewardTokenByDonor[donor] = tokenId;
        rewardTokenGrades[tokenId] = grade;

        _safeMint(donor, tokenId);

        emit BackerRewardMinted(donor, tokenId, campaignName, grade);
    }

    function _targetShareBps(uint256 amount) internal view returns (uint256) {
        return (amount * BPS) / targetAmount;
    }

    function _bestAvailableGrade(
        uint256 amount
    ) internal view returns (BackerGrade) {
        if (amount == 0) {
            return BackerGrade.NONE;
        }

        uint256 shareBps = _targetShareBps(amount);

        if (shareBps >= LEAD_BACKER_MIN_BPS) {
            return BackerGrade.LEAD_BACKER;
        }

        if (shareBps >= FOUNDING_BACKER_MIN_BPS) {
            return BackerGrade.FOUNDING_BACKER;
        }

        if (shareBps >= CONTRIBUTOR_MIN_BPS) {
            return BackerGrade.CONTRIBUTOR;
        }

        return BackerGrade.SUPPORTER;
    }

    function _updateBackerGrade(
        address donor
    ) internal returns (BackerGrade) {
        BackerGrade nextGrade = _bestAvailableGrade(donations[donor]);
        _setBackerGrade(donor, nextGrade);
        return nextGrade;
    }

    function _setBackerGrade(address donor, BackerGrade nextGrade) internal {
        BackerGrade previousGrade = backerGrades[donor];
        if (previousGrade == nextGrade) {
            return;
        }

        backerGrades[donor] = nextGrade;

        emit BackerGradeUpdated(
            donor,
            previousGrade,
            nextGrade,
            donations[donor],
            donorShareBps(donor)
        );
    }

    function _backerGradeName(
        BackerGrade grade
    ) internal pure returns (string memory) {
        if (grade == BackerGrade.LEAD_BACKER) {
            return "Lead Backer";
        }

        if (grade == BackerGrade.FOUNDING_BACKER) {
            return "Founding Backer";
        }

        if (grade == BackerGrade.CONTRIBUTOR) {
            return "Contributor";
        }

        if (grade == BackerGrade.SUPPORTER) {
            return "Supporter";
        }

        return "None";
    }

    function _escapeJson(
        string memory value
    ) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        bytes memory output = new bytes(input.length * 6);
        uint256 outputLength;

        for (uint256 i = 0; i < input.length; i++) {
            bytes1 char = input[i];

            if (char == JSON_QUOTE) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = JSON_QUOTE;
            } else if (char == JSON_BACKSLASH) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = JSON_BACKSLASH;
            } else if (char == 0x08) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_B;
            } else if (char == 0x09) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_T;
            } else if (char == 0x0a) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_N;
            } else if (char == 0x0c) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_F;
            } else if (char == 0x0d) {
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_R;
            } else if (uint8(char) < 0x20) {
                bytes16 hexSymbols = "0123456789abcdef";
                output[outputLength++] = JSON_BACKSLASH;
                output[outputLength++] = ASCII_U;
                output[outputLength++] = ASCII_0;
                output[outputLength++] = ASCII_0;
                output[outputLength++] = hexSymbols[uint8(char) >> 4];
                output[outputLength++] = hexSymbols[uint8(char) & 0x0f];
            } else {
                output[outputLength++] = char;
            }
        }

        assembly ("memory-safe") {
            mstore(output, outputLength)
        }

        return string(output);
    }
}
