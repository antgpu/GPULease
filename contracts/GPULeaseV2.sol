// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./GPULeaseWalletV2.sol";

interface IGPULeaseReferralV2 {
    function referrerOf(bytes32 accountId) external view returns (bytes32);
    function referralShareBps() external view returns (uint256);
}

contract GPULeaseV2 is Ownable {
    uint256 public constant SETTLEMENT_INTERVAL = 1 days;
    uint256 public constant MAX_SETTLEMENT_BATCH_SIZE = 50;

    struct Lease {
        bytes32 userId;
        bytes32 providerId;
        uint256 startTime;
        uint256 duration;
        uint256 storagePricePerSecond;
        uint256 computePricePerSecond;
        uint256 leaseFeePercentage;
        bool active;
        bool completed;
        bool paused;
        uint256 pausedAt;
        uint256 pausedDuration;
    }

    struct FrozenFundsInfo {
        uint256 leaseId;
        uint256 amount;
    }

    struct LeaseReferralInfo {
        bytes32 referrerId;
        uint256 referralShareBps;
    }

    struct LeaseSettlement {
        uint256 providerPaid;
        uint256 feePaid;
        uint256 referralPaid;
        uint256 lastSettledAt;
    }

    struct LeaseRequest {
        uint256 startTimestamp;
        uint256 duration;
        uint256 storagePricePerSecond;
        uint256 computePricePerSecond;
        bytes32 providerId;
        bytes32 userId;
    }

    GPULeaseWalletV2 public immutable wallet;
    IGPULeaseReferralV2 public referralManager;
    bytes32 public treasuryId;
    address public settlementOperator;

    mapping(bytes32 => uint256[]) public userActiveLeases;
    mapping(bytes32 => uint256) public userFeePercentage;
    mapping(bytes32 => bool) public hasCustomUserFee;
    mapping(uint256 => uint256) public frozenFunds;
    mapping(uint256 => uint256) public frozenCashFunds;
    mapping(uint256 => uint256) public frozenBonusFunds;
    mapping(uint256 => Lease) public leases;
    mapping(uint256 => LeaseReferralInfo) public leaseReferralInfo;
    mapping(uint256 => LeaseSettlement) public leaseSettlements;
    mapping(uint256 => uint256) public leaseActivationTime;

    uint256 public leaseCount;
    uint256 public platformFeePercentage = 10;

    event PlatformFeeUpdated(uint256 previousFeePercentage, uint256 newFeePercentage);
    event UserFeeUpdated(bytes32 indexed accountId, uint256 feePercentage);
    event UserFeeCleared(bytes32 indexed accountId);
    event ReferralManagerUpdated(address indexed previousManager, address indexed newManager);
    event TreasuryUpdated(bytes32 indexed previousTreasuryId, bytes32 indexed newTreasuryId);
    event SettlementOperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event LeaseStarted(
        uint256 indexed leaseId,
        bytes32 indexed userId,
        bytes32 indexed providerId,
        uint256 startTimestamp,
        uint256 activationTimestamp,
        uint256 duration,
        uint256 amount
    );
    event LeaseCompleted(uint256 indexed leaseId);
    event LeasePaused(uint256 indexed leaseId);
    event LeaseResumed(uint256 indexed leaseId);
    event LeaseSettled(
        uint256 indexed leaseId,
        uint256 providerAmount,
        uint256 platformFee,
        uint256 referralAmount,
        uint256 settledAt
    );

    modifier onlySettlementOperator() {
        require(
            msg.sender == owner() || msg.sender == settlementOperator,
            "not settlement operator"
        );
        _;
    }

    constructor(address wallet_, bytes32 treasuryId_) Ownable(msg.sender) {
        require(wallet_ != address(0), "zero wallet");
        require(treasuryId_ != bytes32(0), "zero treasury");
        wallet = GPULeaseWalletV2(wallet_);
        treasuryId = treasuryId_;
        settlementOperator = msg.sender;
    }

    function setPlatformFee(uint256 feePercentage) external onlyOwner {
        require(feePercentage <= 100, "fee too high");
        emit PlatformFeeUpdated(platformFeePercentage, feePercentage);
        platformFeePercentage = feePercentage;
    }

    function setUserFee(bytes32 accountId, uint256 feePercentage) external onlyOwner {
        _requireAccount(accountId);
        require(feePercentage <= 100, "fee too high");
        userFeePercentage[accountId] = feePercentage;
        hasCustomUserFee[accountId] = true;
        emit UserFeeUpdated(accountId, feePercentage);
    }

    function clearUserFee(bytes32 accountId) external onlyOwner {
        _requireAccount(accountId);
        delete userFeePercentage[accountId];
        delete hasCustomUserFee[accountId];
        emit UserFeeCleared(accountId);
    }

    function setReferralManager(address newReferralManager) external onlyOwner {
        emit ReferralManagerUpdated(address(referralManager), newReferralManager);
        referralManager = IGPULeaseReferralV2(newReferralManager);
    }

    function setTreasuryId(bytes32 newTreasuryId) external onlyOwner {
        _requireAccount(newTreasuryId);
        bytes32 previousTreasuryId = treasuryId;
        require(newTreasuryId != previousTreasuryId, "same treasury");
        wallet.moveBalance(previousTreasuryId, newTreasuryId);
        treasuryId = newTreasuryId;
        emit TreasuryUpdated(previousTreasuryId, newTreasuryId);
    }

    function setSettlementOperator(address newSettlementOperator) external onlyOwner {
        require(newSettlementOperator != address(0), "zero settlement operator");
        emit SettlementOperatorUpdated(settlementOperator, newSettlementOperator);
        settlementOperator = newSettlementOperator;
    }

    function feePercentageForUser(bytes32 accountId) public view returns (uint256) {
        return hasCustomUserFee[accountId]
            ? userFeePercentage[accountId]
            : platformFeePercentage;
    }

    function startLease(
        uint256 startTimestamp,
        uint256 duration,
        uint256 storagePricePerSecond,
        uint256 computePricePerSecond,
        bytes32 providerId,
        bytes32 userId
    ) external onlyOwner returns (uint256 leaseId) {
        return _startLease(LeaseRequest({
            startTimestamp: startTimestamp,
            duration: duration,
            storagePricePerSecond: storagePricePerSecond,
            computePricePerSecond: computePricePerSecond,
            providerId: providerId,
            userId: userId
        }));
    }

    function _startLease(LeaseRequest memory request) internal returns (uint256 leaseId) {
        require(request.startTimestamp > 0, "invalid start timestamp");
        require(request.startTimestamp <= block.timestamp, "start in future");
        require(request.duration > 0, "zero duration");
        require(
            request.storagePricePerSecond > 0 || request.computePricePerSecond > 0,
            "zero price"
        );
        _requireAccount(request.userId);
        _requireAccount(request.providerId);

        uint256 leaseFeePercentage = feePercentageForUser(request.userId);
        uint256 baseAmount = request.duration * (
            request.storagePricePerSecond + request.computePricePerSecond
        );
        uint256 totalAmount = baseAmount + ((baseAmount * leaseFeePercentage) / 100);
        (bytes32 referrerId, uint256 referralShareBps) =
            _referralInfoForLease(request.userId);
        (uint256 cashUsed, uint256 bonusUsed) =
            wallet.debitForLease(request.userId, totalAmount);

        leaseId = leaseCount++;
        frozenFunds[leaseId] = totalAmount;
        frozenCashFunds[leaseId] = cashUsed;
        frozenBonusFunds[leaseId] = bonusUsed;
        leases[leaseId] = Lease({
            userId: request.userId,
            providerId: request.providerId,
            startTime: request.startTimestamp,
            duration: request.duration,
            storagePricePerSecond: request.storagePricePerSecond,
            computePricePerSecond: request.computePricePerSecond,
            leaseFeePercentage: leaseFeePercentage,
            active: true,
            completed: false,
            paused: false,
            pausedAt: 0,
            pausedDuration: 0
        });
        leaseReferralInfo[leaseId] = LeaseReferralInfo(referrerId, referralShareBps);
        leaseActivationTime[leaseId] = block.timestamp;
        leaseSettlements[leaseId].lastSettledAt = block.timestamp;
        userActiveLeases[request.userId].push(leaseId);

        emit LeaseStarted(
            leaseId,
            request.userId,
            request.providerId,
            request.startTimestamp,
            block.timestamp,
            request.duration,
            totalAmount
        );
    }

    function pauseLease(uint256 leaseId) external onlyOwner {
        Lease storage lease = leases[leaseId];
        require(lease.active && !lease.completed, "lease not active");
        require(!lease.paused, "already paused");
        lease.paused = true;
        lease.pausedAt = block.timestamp;
        emit LeasePaused(leaseId);
    }

    function resumeLease(uint256 leaseId) external onlyOwner {
        Lease storage lease = leases[leaseId];
        require(lease.active && !lease.completed, "lease not active");
        require(lease.paused, "not paused");
        uint256 leaseEnd = lease.startTime + lease.duration;
        uint256 pauseEnd = block.timestamp < leaseEnd ? block.timestamp : leaseEnd;
        if (pauseEnd > lease.pausedAt) {
            lease.pausedDuration += pauseEnd - lease.pausedAt;
        }
        lease.paused = false;
        lease.pausedAt = 0;
        emit LeaseResumed(leaseId);
    }

    function completeLease(uint256 leaseId) external onlyOwner {
        Lease storage lease = leases[leaseId];
        require(lease.active && !lease.completed, "lease not active");
        _settleLease(leaseId);
        wallet.refundLeaseBalance(
            lease.userId,
            frozenCashFunds[leaseId],
            frozenBonusFunds[leaseId]
        );
        delete frozenFunds[leaseId];
        delete frozenCashFunds[leaseId];
        delete frozenBonusFunds[leaseId];
        lease.completed = true;
        lease.active = false;
        _removeActiveLease(lease.userId, leaseId);
        emit LeaseCompleted(leaseId);
    }

    function settleLease(uint256 leaseId) external onlySettlementOperator {
        require(isSettlementDue(leaseId), "settlement not due");
        _settleLease(leaseId);
    }

    function settleLeases(uint256[] calldata leaseIds) external onlySettlementOperator {
        require(leaseIds.length > 0, "empty batch");
        require(leaseIds.length <= MAX_SETTLEMENT_BATCH_SIZE, "batch too large");
        for (uint256 i; i < leaseIds.length; ++i) {
            require(isSettlementDue(leaseIds[i]), "settlement not due");
            _settleLease(leaseIds[i]);
        }
    }

    function isSettlementDue(uint256 leaseId) public view returns (bool) {
        Lease storage lease = leases[leaseId];
        if (!lease.active || lease.completed) return false;
        LeaseSettlement storage settlement = leaseSettlements[leaseId];
        bool intervalPassed = block.timestamp >= settlement.lastSettledAt + SETTLEMENT_INTERVAL;
        bool leaseEnded = block.timestamp >= lease.startTime + lease.duration;
        if (!intervalPassed && !leaseEnded) return false;
        (uint256 providerEarned, uint256 feeEarned, ) = settlementEntitlement(leaseId);
        return providerEarned > settlement.providerPaid || feeEarned > settlement.feePaid;
    }

    function settlementEntitlement(uint256 leaseId)
        public
        view
        returns (uint256 providerEarned, uint256 feeEarned, uint256 referralEarned)
    {
        Lease storage lease = leases[leaseId];
        require(lease.startTime > 0, "lease not started");
        (uint256 storageCost, uint256 computeCost) = calculateActualCost(leaseId);
        uint256 actualTotalCost = storageCost + computeCost;
        feeEarned = (actualTotalCost * lease.leaseFeePercentage) / 100;
        providerEarned = actualTotalCost - feeEarned;
        LeaseReferralInfo storage referralInfo = leaseReferralInfo[leaseId];
        if (referralInfo.referrerId != bytes32(0) && referralInfo.referralShareBps > 0) {
            referralEarned = (feeEarned * referralInfo.referralShareBps) / 10_000;
        }
    }

    function calculateActualCost(uint256 leaseId)
        public
        view
        returns (uint256 actualStorageCost, uint256 actualComputeCost)
    {
        Lease storage lease = leases[leaseId];
        require(lease.startTime > 0, "lease not started");
        uint256 leaseEnd = lease.startTime + lease.duration;
        uint256 calculationTime = block.timestamp < leaseEnd ? block.timestamp : leaseEnd;
        uint256 storageDuration = calculationTime - lease.startTime;
        uint256 activationTime = leaseActivationTime[leaseId];
        uint256 computeDuration = calculationTime > activationTime
            ? calculationTime - activationTime
            : 0;
        uint256 totalPaused = lease.pausedDuration;
        if (lease.paused && calculationTime > lease.pausedAt) {
            totalPaused += calculationTime - lease.pausedAt;
        }
        if (totalPaused > computeDuration) totalPaused = computeDuration;
        actualStorageCost = storageDuration * lease.storagePricePerSecond;
        actualComputeCost = (computeDuration - totalPaused) * lease.computePricePerSecond;
    }

    function getUserFrozenFunds(bytes32 accountId)
        external
        view
        returns (FrozenFundsInfo[] memory result)
    {
        uint256[] storage leaseIds = userActiveLeases[accountId];
        result = new FrozenFundsInfo[](leaseIds.length);
        for (uint256 i; i < leaseIds.length; ++i) {
            result[i] = FrozenFundsInfo(leaseIds[i], frozenFunds[leaseIds[i]]);
        }
    }

    function _settleLease(uint256 leaseId) internal {
        Lease storage lease = leases[leaseId];
        require(lease.active && !lease.completed, "lease not active");
        LeaseSettlement storage settlement = leaseSettlements[leaseId];
        (uint256 providerEarned, uint256 feeEarned, uint256 referralEarned) =
            settlementEntitlement(leaseId);
        uint256 providerAmount = providerEarned - settlement.providerPaid;
        uint256 platformFee = feeEarned - settlement.feePaid;
        uint256 referralAmount = referralEarned - settlement.referralPaid;
        uint256 totalAmount = providerAmount + platformFee;
        settlement.providerPaid = providerEarned;
        settlement.feePaid = feeEarned;
        settlement.referralPaid = referralEarned;
        settlement.lastSettledAt = block.timestamp;
        if (totalAmount == 0) return;
        _consumeFrozenFunds(leaseId, totalAmount);
        LeaseReferralInfo storage referralInfo = leaseReferralInfo[leaseId];
        if (referralAmount > 0) wallet.creditBalance(referralInfo.referrerId, referralAmount);
        if (platformFee > referralAmount) wallet.creditBalance(treasuryId, platformFee - referralAmount);
        if (providerAmount > 0) wallet.creditBalance(lease.providerId, providerAmount);
        emit LeaseSettled(leaseId, providerAmount, platformFee, referralAmount, block.timestamp);
    }

    function _consumeFrozenFunds(uint256 leaseId, uint256 amount) internal {
        uint256 bonusAmount = amount < frozenBonusFunds[leaseId]
            ? amount
            : frozenBonusFunds[leaseId];
        uint256 cashAmount = amount - bonusAmount;
        frozenBonusFunds[leaseId] -= bonusAmount;
        frozenCashFunds[leaseId] -= cashAmount;
        frozenFunds[leaseId] -= amount;
    }

    function _referralInfoForLease(bytes32 accountId)
        internal
        view
        returns (bytes32 referrerId, uint256 shareBps)
    {
        if (address(referralManager) == address(0)) return (bytes32(0), 0);
        referrerId = referralManager.referrerOf(accountId);
        if (referrerId == bytes32(0)) return (bytes32(0), 0);
        shareBps = referralManager.referralShareBps();
        require(shareBps <= 10_000, "referral share too high");
    }

    function _removeActiveLease(bytes32 accountId, uint256 leaseId) internal {
        uint256[] storage leaseIds = userActiveLeases[accountId];
        for (uint256 i; i < leaseIds.length; ++i) {
            if (leaseIds[i] == leaseId) {
                leaseIds[i] = leaseIds[leaseIds.length - 1];
                leaseIds.pop();
                return;
            }
        }
    }

    function _requireAccount(bytes32 accountId) internal pure {
        require(accountId != bytes32(0), "zero account");
    }
}
