// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title QmoosaTimelock
 * @notice Enforces mandatory minimum delay between proposal passage and execution.
 *         Prevents unexpected privileged actions and provides community veto windows.
 */
contract QmoosaTimelock {
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MINIMUM_DELAY = 1 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    address public admin;
    address public pendingAdmin;
    uint256 public delay;

    mapping(bytes32 => bool) public queuedTransactions;

    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewDelay(uint256 indexed newDelay);
    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta);

    error Unauthorized();
    error InvalidDelay();
    error TransactionNotQueued();
    error TimelockNotMet();
    error TransactionExpired();
    error TransactionExecutionFailed();
    error TransactionAlreadyQueued();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    constructor(address _admin, uint256 _delay) {
        if (_delay < MINIMUM_DELAY || _delay > MAXIMUM_DELAY) revert InvalidDelay();
        admin = _admin;
        delay = _delay;
        emit NewAdmin(_admin);
        emit NewDelay(_delay);
    }

    function setAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) revert Unauthorized();
        admin = _admin;
        emit NewAdmin(_admin);
    }

    function setDelay(uint256 _delay) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (_delay < MINIMUM_DELAY || _delay > MAXIMUM_DELAY) revert InvalidDelay();
        delay = _delay;
        emit NewDelay(_delay);
    }

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyAdmin returns (bytes32) {
        if (eta < block.timestamp + delay) revert TimelockNotMet();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (queuedTransactions[txHash]) revert TransactionAlreadyQueued();

        queuedTransactions[txHash] = true;
        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external onlyAdmin {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (!queuedTransactions[txHash]) revert TransactionNotQueued();

        queuedTransactions[txHash] = false;
        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) external payable onlyAdmin returns (bytes memory) {
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        if (!queuedTransactions[txHash]) revert TransactionNotQueued();
        if (block.timestamp < eta) revert TimelockNotMet();
        if (block.timestamp > eta + GRACE_PERIOD) revert TransactionExpired();

        queuedTransactions[txHash] = false;

        bytes memory callData;
        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        if (!success) revert TransactionExecutionFailed();

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);
        return returnData;
    }

    receive() external payable {}
}
