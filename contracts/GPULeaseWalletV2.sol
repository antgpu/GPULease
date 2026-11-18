// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.31;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Custodies ERC20 funds while accounting by an application account ID.
/// A wallet is optional and only grants withdrawal authority for an account.
contract GPULeaseWalletV2 is Ownable, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BATCH_SIZE = 100;
    bytes32 public constant BIND_WALLET_TYPEHASH = keccak256(
        "BindWallet(bytes32 accountId,address wallet,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(bytes32 accountId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    IERC20 public immutable credit;
    address public leaseManager;
    address public registrar;

    mapping(bytes32 => uint256) public balances;
    mapping(bytes32 => uint256) public bonusBalances;
    mapping(bytes32 => address) public walletOf;
    mapping(address => bytes32) public accountOfWallet;
    mapping(bytes32 => uint256) public bindNonces;
    mapping(bytes32 => uint256) public withdrawNonces;

    uint256 public bonusReserve;
    uint256 public totalCashLiability;
    uint256 public totalBonusLiability;

    event Deposit(bytes32 indexed accountId, address indexed payer, uint256 amount);
    event Withdraw(
        bytes32 indexed accountId,
        address indexed wallet,
        address indexed relayer,
        uint256 amount
    );
    event WalletBound(
        bytes32 indexed accountId,
        address indexed previousWallet,
        address indexed newWallet
    );
    event WalletUnbound(bytes32 indexed accountId, address indexed previousWallet);
    event RegistrarUpdated(address indexed previousRegistrar, address indexed newRegistrar);
    event LeaseManagerUpdated(address indexed previousManager, address indexed newManager);
    event BonusPoolFunded(address indexed funder, uint256 amount);
    event BonusGranted(bytes32 indexed accountId, uint256 amount);
    event BonusRevoked(bytes32 indexed accountId, uint256 amount);
    event BonusReserveWithdrawn(address indexed recipient, uint256 amount);
    event LeaseBalanceDebited(
        bytes32 indexed accountId,
        uint256 cashAmount,
        uint256 bonusAmount
    );
    event LeaseBalanceRefunded(
        bytes32 indexed accountId,
        uint256 cashAmount,
        uint256 bonusAmount
    );
    event BalancesMigrated(
        bytes32 indexed accountId,
        uint256 cashAmount,
        uint256 bonusAmount
    );
    event AccountMerged(
        bytes32 indexed fromId,
        bytes32 indexed toId,
        uint256 cashAmount,
        uint256 bonusAmount
    );

    modifier onlyLeaseManager() {
        require(msg.sender == leaseManager, "not lease manager");
        _;
    }

    modifier onlyRegistrar() {
        require(msg.sender == registrar, "not registrar");
        _;
    }

    constructor(address credit_, address registrar_)
        Ownable(msg.sender)
        EIP712("GPULeaseWalletV2", "1")
    {
        require(credit_ != address(0), "zero credit");
        require(registrar_ != address(0), "zero registrar");
        credit = IERC20(credit_);
        registrar = registrar_;
    }

    function setLeaseManager(address newLeaseManager) external onlyOwner {
        require(newLeaseManager != address(0), "zero lease manager");
        emit LeaseManagerUpdated(leaseManager, newLeaseManager);
        leaseManager = newLeaseManager;
    }

    function setRegistrar(address newRegistrar) external onlyOwner {
        require(newRegistrar != address(0), "zero registrar");
        emit RegistrarUpdated(registrar, newRegistrar);
        registrar = newRegistrar;
    }

    /// @notice Gasless-for-user binding after the backend has authenticated the user
    /// and verified control of the target wallet off chain.
    function bindWallet(bytes32 accountId, address wallet) external onlyRegistrar {
        bindNonces[accountId]++;
        _bindWallet(accountId, wallet);
    }

    /// @notice Fully auditable gasless binding. Any relayer may submit matching
    /// EIP-712 signatures from both the registrar and the target wallet.
    function bindWalletWithSignatures(
        bytes32 accountId,
        address wallet,
        uint256 deadline,
        bytes calldata registrarSignature,
        bytes calldata walletSignature
    ) external {
        _requireAccount(accountId);
        require(wallet != address(0), "zero wallet");
        require(block.timestamp <= deadline, "expired");

        uint256 nonce = bindNonces[accountId]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    BIND_WALLET_TYPEHASH,
                    accountId,
                    wallet,
                    nonce,
                    deadline
                )
            )
        );
        require(
            SignatureChecker.isValidSignatureNow(registrar, digest, registrarSignature),
            "invalid registrar signature"
        );
        require(
            SignatureChecker.isValidSignatureNow(wallet, digest, walletSignature),
            "invalid wallet signature"
        );
        _bindWallet(accountId, wallet);
    }

    function unbindWallet(bytes32 accountId) external onlyRegistrar {
        _requireAccount(accountId);
        address previousWallet = walletOf[accountId];
        require(previousWallet != address(0), "wallet not bound");
        delete accountOfWallet[previousWallet];
        delete walletOf[accountId];
        bindNonces[accountId]++;
        emit WalletUnbound(accountId, previousWallet);
    }

    /// @notice Reconciles a temporary legacy-address account with the canonical
    /// application account after backend identity verification.
    function mergeAccount(bytes32 fromId, bytes32 toId) external onlyRegistrar {
        _requireAccount(fromId);
        _requireAccount(toId);
        require(fromId != toId, "same account");

        uint256 cashAmount = balances[fromId];
        uint256 bonusAmount = bonusBalances[fromId];
        balances[toId] += cashAmount;
        bonusBalances[toId] += bonusAmount;
        delete balances[fromId];
        delete bonusBalances[fromId];

        address fromWallet = walletOf[fromId];
        address toWallet = walletOf[toId];
        if (fromWallet != address(0)) {
            delete walletOf[fromId];
            delete accountOfWallet[fromWallet];
            if (toWallet == address(0)) {
                walletOf[toId] = fromWallet;
                accountOfWallet[fromWallet] = toId;
                emit WalletBound(toId, address(0), fromWallet);
            }
        }
        bindNonces[fromId]++;
        withdrawNonces[fromId]++;
        emit AccountMerged(fromId, toId, cashAmount, bonusAmount);
    }

    function depositFor(bytes32 accountId, uint256 amount) external nonReentrant {
        _requireAccount(accountId);
        require(amount > 0, "zero amount");
        credit.safeTransferFrom(msg.sender, address(this), amount);
        balances[accountId] += amount;
        totalCashLiability += amount;
        emit Deposit(accountId, msg.sender, amount);
    }

    function withdraw(bytes32 accountId, uint256 amount) external nonReentrant {
        require(walletOf[accountId] == msg.sender, "not linked wallet");
        _withdraw(accountId, amount, msg.sender);
    }

    /// @notice Gasless withdrawal: the linked wallet signs an EIP-712 intent and
    /// any relayer pays gas. Funds can only go to the currently linked wallet.
    function withdrawWithSignature(
        bytes32 accountId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _requireAccount(accountId);
        require(block.timestamp <= deadline, "expired");
        address wallet = walletOf[accountId];
        require(wallet != address(0), "wallet not bound");

        uint256 nonce = withdrawNonces[accountId]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    WITHDRAW_TYPEHASH,
                    accountId,
                    amount,
                    nonce,
                    deadline
                )
            )
        );
        require(
            SignatureChecker.isValidSignatureNow(wallet, digest, signature),
            "invalid wallet signature"
        );
        _withdraw(accountId, amount, msg.sender);
    }

    function userBalance(bytes32 accountId) external view returns (uint256) {
        return spendableBalance(accountId);
    }

    function withdrawableBalance(bytes32 accountId) external view returns (uint256) {
        return balances[accountId];
    }

    function bonusBalance(bytes32 accountId) external view returns (uint256) {
        return bonusBalances[accountId];
    }

    function spendableBalance(bytes32 accountId) public view returns (uint256) {
        return balances[accountId] + bonusBalances[accountId];
    }

    function accountedBalance() external view returns (uint256) {
        return totalCashLiability + totalBonusLiability + bonusReserve;
    }

    function fundBonusPool(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        credit.safeTransferFrom(msg.sender, address(this), amount);
        bonusReserve += amount;
        emit BonusPoolFunded(msg.sender, amount);
    }

    function grantBonus(bytes32 accountId, uint256 amount) external onlyOwner {
        _grantBonus(accountId, amount);
    }

    function grantBonuses(
        bytes32[] calldata accountIds,
        uint256[] calldata amounts
    ) external onlyOwner {
        require(accountIds.length > 0, "empty batch");
        require(accountIds.length == amounts.length, "length mismatch");
        require(accountIds.length <= MAX_BATCH_SIZE, "batch too large");

        uint256 totalAmount;
        for (uint256 i; i < accountIds.length; ++i) {
            _requireAccount(accountIds[i]);
            require(amounts[i] > 0, "zero amount");
            totalAmount += amounts[i];
        }
        require(bonusReserve >= totalAmount, "insufficient bonus reserve");

        bonusReserve -= totalAmount;
        totalBonusLiability += totalAmount;
        for (uint256 i; i < accountIds.length; ++i) {
            bonusBalances[accountIds[i]] += amounts[i];
            emit BonusGranted(accountIds[i], amounts[i]);
        }
    }

    function revokeBonus(bytes32 accountId, uint256 amount) external onlyOwner {
        _requireAccount(accountId);
        require(amount > 0, "zero amount");
        require(bonusBalances[accountId] >= amount, "insufficient bonus balance");
        bonusBalances[accountId] -= amount;
        totalBonusLiability -= amount;
        bonusReserve += amount;
        emit BonusRevoked(accountId, amount);
    }

    function withdrawBonusReserve(address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(recipient != address(0), "zero recipient");
        require(amount > 0, "zero amount");
        require(bonusReserve >= amount, "insufficient bonus reserve");
        bonusReserve -= amount;
        credit.safeTransfer(recipient, amount);
        emit BonusReserveWithdrawn(recipient, amount);
    }

    /// @notice Atomic, fully funded migration. The caller supplies all imported
    /// funds, so imported liabilities can never create an insolvent wallet.
    function migrateBalances(
        bytes32[] calldata accountIds,
        uint256[] calldata cashAmounts,
        uint256[] calldata bonusAmounts
    ) external onlyOwner nonReentrant {
        uint256 length = accountIds.length;
        require(length > 0, "empty batch");
        require(length == cashAmounts.length && length == bonusAmounts.length, "length mismatch");
        require(length <= MAX_BATCH_SIZE, "batch too large");

        uint256 totalCash;
        uint256 totalBonus;
        for (uint256 i; i < length; ++i) {
            _requireAccount(accountIds[i]);
            require(cashAmounts[i] > 0 || bonusAmounts[i] > 0, "zero balance");
            totalCash += cashAmounts[i];
            totalBonus += bonusAmounts[i];
        }

        credit.safeTransferFrom(msg.sender, address(this), totalCash + totalBonus);
        totalCashLiability += totalCash;
        totalBonusLiability += totalBonus;
        for (uint256 i; i < length; ++i) {
            balances[accountIds[i]] += cashAmounts[i];
            bonusBalances[accountIds[i]] += bonusAmounts[i];
            emit BalancesMigrated(accountIds[i], cashAmounts[i], bonusAmounts[i]);
        }
    }

    function debitForLease(bytes32 accountId, uint256 amount)
        external
        onlyLeaseManager
        returns (uint256 cashUsed, uint256 bonusUsed)
    {
        require(spendableBalance(accountId) >= amount, "insufficient balance");
        bonusUsed = amount < bonusBalances[accountId]
            ? amount
            : bonusBalances[accountId];
        cashUsed = amount - bonusUsed;
        bonusBalances[accountId] -= bonusUsed;
        balances[accountId] -= cashUsed;
        totalBonusLiability -= bonusUsed;
        totalCashLiability -= cashUsed;
        emit LeaseBalanceDebited(accountId, cashUsed, bonusUsed);
    }

    function refundLeaseBalance(
        bytes32 accountId,
        uint256 cashAmount,
        uint256 bonusAmount
    ) external onlyLeaseManager {
        _requireAccount(accountId);
        balances[accountId] += cashAmount;
        bonusBalances[accountId] += bonusAmount;
        totalCashLiability += cashAmount;
        totalBonusLiability += bonusAmount;
        emit LeaseBalanceRefunded(accountId, cashAmount, bonusAmount);
    }

    function debitBalance(bytes32 accountId, uint256 amount) external onlyLeaseManager {
        require(balances[accountId] >= amount, "insufficient balance");
        balances[accountId] -= amount;
        totalCashLiability -= amount;
    }

    function creditBalance(bytes32 accountId, uint256 amount) external onlyLeaseManager {
        _requireAccount(accountId);
        balances[accountId] += amount;
        totalCashLiability += amount;
    }

    function moveBalance(bytes32 fromId, bytes32 toId)
        external
        onlyLeaseManager
        returns (uint256 amount)
    {
        _requireAccount(fromId);
        _requireAccount(toId);
        require(fromId != toId, "same account");
        amount = balances[fromId];
        balances[toId] += amount;
        balances[fromId] = 0;
    }

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _bindWallet(bytes32 accountId, address wallet) internal {
        _requireAccount(accountId);
        require(wallet != address(0), "zero wallet");
        bytes32 existingAccount = accountOfWallet[wallet];
        require(existingAccount == bytes32(0) || existingAccount == accountId, "wallet already bound");

        address previousWallet = walletOf[accountId];
        if (previousWallet != address(0) && previousWallet != wallet) {
            delete accountOfWallet[previousWallet];
        }
        walletOf[accountId] = wallet;
        accountOfWallet[wallet] = accountId;
        emit WalletBound(accountId, previousWallet, wallet);
    }

    function _withdraw(bytes32 accountId, uint256 amount, address relayer) internal {
        require(amount > 0, "zero amount");
        require(balances[accountId] >= amount, "insufficient balance");
        address wallet = walletOf[accountId];
        require(wallet != address(0), "wallet not bound");
        balances[accountId] -= amount;
        totalCashLiability -= amount;
        credit.safeTransfer(wallet, amount);
        emit Withdraw(accountId, wallet, relayer, amount);
    }

    function _grantBonus(bytes32 accountId, uint256 amount) internal {
        _requireAccount(accountId);
        require(amount > 0, "zero amount");
        require(bonusReserve >= amount, "insufficient bonus reserve");
        bonusReserve -= amount;
        bonusBalances[accountId] += amount;
        totalBonusLiability += amount;
        emit BonusGranted(accountId, amount);
    }

    function _requireAccount(bytes32 accountId) internal pure {
        require(accountId != bytes32(0), "zero account");
    }
}
