// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import "./Campaign.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGPULeaseWalletV2Campaign {
    function depositFor(bytes32 accountId, uint256 amount) external;
    function accountOfWallet(address wallet) external view returns (bytes32);
}

/// @notice Fundraising campaign whose proceeds belong to an application account
/// and therefore do not require the creator to have a wallet at creation time.
contract LLMFundraisingV2 is LLMFundraising {
    using SafeERC20 for IERC20;

    bytes32 public creatorAccountId;

    /// @dev Called by the factory immediately after cloning and before the
    /// inherited initializer. Splitting this out avoids an unsafe oversized
    /// initializer stack while keeping clone creation atomic.
    function initializeCreatorAccount(bytes32 creatorAccountId_) external {
        require(!initialized, "already initialized");
        require(creatorAccountId_ != bytes32(0), "zero creator account");
        require(creatorAccountId == bytes32(0), "creator already initialized");
        creatorAccountId = creatorAccountId_;
    }

    function _transferToWallet(uint256 amount) internal override {
        require(amount > 0, "no funds");
        usdc.forceApprove(address(gpuLeaseWallet), amount);
        IGPULeaseWalletV2Campaign(address(gpuLeaseWallet)).depositFor(
            creatorAccountId,
            amount
        );
        emit FundsTransferred(address(gpuLeaseWallet), amount);
    }
}
