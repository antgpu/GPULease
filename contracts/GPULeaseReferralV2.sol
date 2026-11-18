// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/access/Ownable.sol";

contract GPULeaseReferralV2 is Ownable {
    uint256 private constant BPS = 10_000;

    mapping(bytes32 => bytes32) public referrerOf;
    uint256 public referralShareBps = 5_000;

    event ReferrerUpdated(bytes32 indexed accountId, bytes32 indexed referrerId);
    event ReferrerCleared(bytes32 indexed accountId, bytes32 indexed previousReferrerId);
    event ReferralShareUpdated(uint256 previousShareBps, uint256 newShareBps);

    constructor() Ownable(msg.sender) {}

    function setReferrer(bytes32 accountId, bytes32 referrerId) external onlyOwner {
        require(accountId != bytes32(0), "zero account");
        require(referrerId != bytes32(0), "zero referrer");
        require(accountId != referrerId, "self referral");
        referrerOf[accountId] = referrerId;
        emit ReferrerUpdated(accountId, referrerId);
    }

    function clearReferrer(bytes32 accountId) external onlyOwner {
        require(accountId != bytes32(0), "zero account");
        bytes32 previousReferrerId = referrerOf[accountId];
        delete referrerOf[accountId];
        emit ReferrerCleared(accountId, previousReferrerId);
    }

    function setReferralShareBps(uint256 newShareBps) external onlyOwner {
        require(newShareBps <= BPS, "share too high");
        emit ReferralShareUpdated(referralShareBps, newShareBps);
        referralShareBps = newShareBps;
    }
}
