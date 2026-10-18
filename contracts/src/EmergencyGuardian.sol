// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title EmergencyGuardian
 * @notice Multi-signature emergency guardian with configurable threshold (M-of-N).
 *         Can pause governance or veto compromised proposals within bounded duration.
 *         Requires threshold of approved signers for pause, unpause, and veto actions.
 */
contract EmergencyGuardian {
    address public immutable governor;
    uint256 public immutable threshold;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    address[] public signers;
    mapping(address => bool) public isSigner;

    bool public paused;
    uint256 public pausedAt;

    uint256 public pauseNonce;
    mapping(uint256 => mapping(address => bool)) public pauseVotes;
    mapping(uint256 => uint256) public pauseVoteCount;

    uint256 public unpauseNonce;
    mapping(uint256 => mapping(address => bool)) public unpauseVotes;
    mapping(uint256 => uint256) public unpauseVoteCount;

    mapping(uint256 => mapping(address => bool)) public vetoVotes;
    mapping(uint256 => uint256) public vetoVoteCount;
    mapping(uint256 => bool) public vetoedProposals;

    event GovernancePaused(address indexed by, uint256 timestamp);
    event GovernanceUnpaused(address indexed by, uint256 timestamp);
    event ProposalVetoed(uint256 indexed proposalId, address indexed by, string reason);
    event PauseVoteCast(uint256 indexed nonce, address indexed signer, uint256 currentVotes);
    event VetoVoteCast(uint256 indexed proposalId, address indexed signer, uint256 currentVotes);

    error Unauthorized();
    error ZeroAddress();
    error InvalidThreshold();
    error DuplicateSigner();
    error AlreadyVoted();
    error AlreadyPaused();
    error NotPaused();
    error AlreadyVetoed();

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address _governor, address[] memory _signers, uint256 _threshold) {
        if (_governor == address(0)) revert ZeroAddress();
        if (_threshold == 0 || _threshold > _signers.length) revert InvalidThreshold();

        governor = _governor;
        threshold = _threshold;

        for (uint256 i = 0; i < _signers.length; i++) {
            address s = _signers[i];
            if (s == address(0)) revert ZeroAddress();
            if (isSigner[s]) revert DuplicateSigner();
            isSigner[s] = true;
            signers.push(s);
        }
    }

    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    function signerCount() external view returns (uint256) {
        return signers.length;
    }

    function pause() external onlySigner {
        if (isPaused()) revert AlreadyPaused();
        if (pauseVotes[pauseNonce][msg.sender]) revert AlreadyVoted();

        pauseVotes[pauseNonce][msg.sender] = true;
        pauseVoteCount[pauseNonce]++;

        emit PauseVoteCast(pauseNonce, msg.sender, pauseVoteCount[pauseNonce]);

        if (pauseVoteCount[pauseNonce] >= threshold) {
            paused = true;
            pausedAt = block.timestamp;
            pauseNonce++;
            emit GovernancePaused(msg.sender, block.timestamp);
        }
    }

    function unpause() external onlySigner {
        if (!isPaused()) revert NotPaused();
        if (unpauseVotes[unpauseNonce][msg.sender]) revert AlreadyVoted();

        unpauseVotes[unpauseNonce][msg.sender] = true;
        unpauseVoteCount[unpauseNonce]++;

        if (unpauseVoteCount[unpauseNonce] >= threshold) {
            paused = false;
            pausedAt = 0;
            unpauseNonce++;
            emit GovernanceUnpaused(msg.sender, block.timestamp);
        }
    }

    function isPaused() public view returns (bool) {
        if (!paused) return false;
        if (block.timestamp > pausedAt + MAX_PAUSE_DURATION) {
            return false;
        }
        return true;
    }

    function vetoProposal(uint256 proposalId, string calldata reason) external onlySigner {
        if (vetoedProposals[proposalId]) revert AlreadyVetoed();
        if (vetoVotes[proposalId][msg.sender]) revert AlreadyVoted();

        vetoVotes[proposalId][msg.sender] = true;
        vetoVoteCount[proposalId]++;

        emit VetoVoteCast(proposalId, msg.sender, vetoVoteCount[proposalId]);

        if (vetoVoteCount[proposalId] >= threshold) {
            vetoedProposals[proposalId] = true;
            emit ProposalVetoed(proposalId, msg.sender, reason);
        }
    }

    function isVetoed(uint256 proposalId) external view returns (bool) {
        return vetoedProposals[proposalId];
    }
}
