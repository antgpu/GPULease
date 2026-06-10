// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IGPULease {
    function deposit(uint256 amount) external;
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        (bool success, bytes memory returndata) = address(token).call(data);
        require(success, "erc20 call failed");

        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "erc20 operation failed");
        }
    }
}

contract Ownable {
    address public owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor(address initialOwner) {
        require(initialOwner != address(0), "zero owner");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract LLMFundraising is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant CONTRIBUTOR_MIN_BPS = 100;
    uint256 private constant FOUNDING_BACKER_MIN_BPS = 500;
    uint256 private constant LEAD_BACKER_MIN_BPS = 1_500;

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
    string public campaignURI;

    IERC20 public immutable usdc;
    IGPULease public immutable gpuLease;

    CampaignState public state;
    uint256 public totalRaised;

    mapping(address => uint256) public donations;
    mapping(address => bool) public refunded;
    mapping(address => BackerGrade) public backerGrades;

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

    constructor(
        uint256 _campaignId,
        uint256 _targetAmount,
        uint256 _duration,
        uint256 _startTimestamp,
        uint256 _templateId,
        string memory _campaignURI,
        address _usdc,
        address _gpuLease,
        address _campaignOwner
    ) Ownable(_campaignOwner) {
        require(_usdc != address(0), "zero usdc");
        require(_gpuLease != address(0), "zero gpuLease");
        require(_targetAmount > 0, "zero target");
        require(_duration > 0, "zero duration");

        campaignId = _campaignId;
        targetAmount = _targetAmount;
        duration = _duration;
        startTimestamp = _startTimestamp;
        templateId = _templateId;
        campaignURI = _campaignURI;

        usdc = IERC20(_usdc);
        gpuLease = IGPULease(_gpuLease);

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

    function donate(uint256 amount) external nonReentrant {
        require(state == CampaignState.ACTIVE, "not active");
        require(block.timestamp >= startTimestamp, "not started");
        require(!isExpired(), "expired");
        require(amount > 0, "zero amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

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

        usdc.safeApprove(address(gpuLease), 0);
        usdc.safeApprove(address(gpuLease), amount);

        gpuLease.deposit(amount);

        emit FundsTransferred(address(gpuLease), amount);
    }

    function _targetShareBps(uint256 amount) internal view returns (uint256) {
        return (amount * BPS) / targetAmount;
    }

    function _bestAvailableGrade(uint256 amount) internal view returns (BackerGrade) {
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
}
