// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title EmergencyGuardian
 * @notice Multi-signature or emergency guardian veto authority.
 *         Can pause governance or veto compromised proposals within bounded duration.
 */
contract EmergencyGuardian {
    address public immutable governor;
    address public guardian;
    bool public paused;
    uint256 public pausedAt;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    mapping(uint256 => bool) public vetoedProposals;

    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event GovernancePaused(address indexed by, uint256 timestamp);
    event GovernanceUnpaused(address indexed by, uint256 timestamp);
    event ProposalVetoed(uint256 indexed proposalId, address indexed by, string reason);

    error Unauthorized();
    error ZeroAddress();
    error PauseDurationExceeded();
    error AlreadyPaused();
    error NotPaused();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Unauthorized();
        _;
    }

    constructor(address _governor, address _guardian) {
        if (_governor == address(0) || _guardian == address(0)) revert ZeroAddress();
        governor = _governor;
        guardian = _guardian;
    }

    function transferGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    function pause() external onlyGuardian {
        if (paused) revert AlreadyPaused();
        paused = true;
        pausedAt = block.timestamp;
        emit GovernancePaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyGuardian {
        if (!paused) revert NotPaused();
        paused = false;
        pausedAt = 0;
        emit GovernanceUnpaused(msg.sender, block.timestamp);
    }

    function isPaused() public view returns (bool) {
        if (!paused) return false;
        if (block.timestamp > pausedAt + MAX_PAUSE_DURATION) {
            return false; // Automatically unpauses after MAX_PAUSE_DURATION
        }
        return true;
    }

    function vetoProposal(uint256 proposalId, string calldata reason) external onlyGuardian {
        vetoedProposals[proposalId] = true;
        emit ProposalVetoed(proposalId, msg.sender, reason);
    }

    function isVetoed(uint256 proposalId) external view returns (bool) {
        return vetoedProposals[proposalId];
    }
}
