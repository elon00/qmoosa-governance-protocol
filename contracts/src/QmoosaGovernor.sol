// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {QmoosaToken} from "./QmoosaToken.sol";
import {QmoosaTimelock} from "./QmoosaTimelock.sol";
import {EmergencyGuardian} from "./EmergencyGuardian.sol";

/**
 * @title QmoosaGovernor
 * @notice Decentralized governance contract managing proposals, voting, timelock queueing,
 *         and emergency guardian vetoes. Immune to flash-loan vote borrowing by evaluating
 *         voting power strictly at historical snapshot blocks.
 */
contract QmoosaGovernor {
    string public constant name = "QMOOSA Governor";

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed,
        Vetoed
    }

    struct Proposal {
        uint256 id;
        address proposer;
        uint256 eta;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        address[] targets;
        uint256[] values;
        string[] signatures;
        bytes[] calldatas;
    }

    struct Receipt {
        bool hasVoted;
        uint8 support; // 0 = Against, 1 = For, 2 = Abstain
        uint256 votes;
    }

    QmoosaToken public immutable token;
    QmoosaTimelock public immutable timelock;
    EmergencyGuardian public guardian;

    uint256 public votingDelay; // in blocks (e.g. 1)
    uint256 public votingPeriod; // in blocks (e.g. 50400 or test value)
    uint256 public proposalThreshold; // min tokens required to propose
    uint256 public quorumNumerator; // e.g. 4 for 4%
    uint256 public constant QUORUM_DENOMINATOR = 100;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Receipt)) public receipts;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
    event VoteCast(address indexed voter, uint256 indexed proposalId, uint8 support, uint256 weight, string reason);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);

    error Unauthorized();
    error ProposalNotActive();
    error AlreadyVoted();
    error InvalidVoteType();
    error ZeroVotingPower();
    error ProposalThresholdNotMet();
    error InvalidProposalLength();
    error ProposalAlreadyExists();
    error InvalidState(ProposalState expected, ProposalState actual);
    error TimelockNotMet();
    error GovernancePaused();
    error ProposalWasVetoed();

    modifier whenNotPaused() {
        if (address(guardian) != address(0) && guardian.isPaused()) {
            revert GovernancePaused();
        }
        _;
    }

    constructor(
        address _token,
        address payable _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) {
        token = QmoosaToken(_token);
        timelock = QmoosaTimelock(_timelock);
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        proposalThreshold = _proposalThreshold;
        quorumNumerator = _quorumNumerator;
    }

    function setGuardian(address _guardian) external {
        if (address(guardian) != address(0)) {
            if (msg.sender != address(timelock) && msg.sender != guardian.guardian()) revert Unauthorized();
        }
        guardian = EmergencyGuardian(_guardian);
    }

    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) external whenNotPaused returns (uint256) {
        if (token.getPastVotes(msg.sender, block.number - 1) < proposalThreshold) {
            revert ProposalThresholdNotMet();
        }
        if (targets.length == 0 || targets.length != values.length || targets.length != signatures.length || targets.length != calldatas.length) {
            revert InvalidProposalLength();
        }

        proposalCount++;
        uint256 proposalId = proposalCount;

        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.startBlock = block.number + votingDelay;
        p.endBlock = p.startBlock + votingPeriod;
        p.targets = targets;
        p.values = values;
        p.signatures = signatures;
        p.calldatas = calldatas;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            p.startBlock,
            p.endBlock,
            description
        );

        return proposalId;
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "PROPOSAL_DOES_NOT_EXIST");

        if (address(guardian) != address(0) && guardian.isVetoed(proposalId)) {
            return ProposalState.Vetoed;
        }

        if (p.canceled) {
            return ProposalState.Canceled;
        }

        if (p.executed) {
            return ProposalState.Executed;
        }

        if (block.number <= p.startBlock) {
            return ProposalState.Pending;
        }

        if (block.number <= p.endBlock) {
            return ProposalState.Active;
        }

        uint256 q = quorum(p.startBlock);
        bool quorumReached = (p.forVotes + p.abstainVotes) >= q;
        bool voteSucceeded = p.forVotes > p.againstVotes;

        if (!quorumReached || !voteSucceeded) {
            return ProposalState.Defeated;
        }

        if (p.eta == 0) {
            return ProposalState.Succeeded;
        }

        if (block.timestamp > p.eta + timelock.GRACE_PERIOD()) {
            return ProposalState.Expired;
        }

        return ProposalState.Queued;
    }

    function quorum(uint256 blockNumber) public view returns (uint256) {
        return (token.getPastTotalSupply(blockNumber) * quorumNumerator) / QUORUM_DENOMINATOR;
    }

    function castVote(uint256 proposalId, uint8 support) external whenNotPaused returns (uint256) {
        return _castVote(msg.sender, proposalId, support, "");
    }

    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external whenNotPaused returns (uint256) {
        return _castVote(msg.sender, proposalId, support, reason);
    }

    function _castVote(
        address voter,
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) internal returns (uint256) {
        if (state(proposalId) != ProposalState.Active) revert ProposalNotActive();
        if (support > 2) revert InvalidVoteType();

        Receipt storage receipt = receipts[proposalId][voter];
        if (receipt.hasVoted) revert AlreadyVoted();

        Proposal storage p = proposals[proposalId];
        // Strictly historical checkpoint evaluation at snapshotBlock = p.startBlock
        uint256 weight = token.getPastVotes(voter, p.startBlock);
        if (weight == 0) revert ZeroVotingPower();

        if (support == 0) {
            p.againstVotes += weight;
        } else if (support == 1) {
            p.forVotes += weight;
        } else {
            p.abstainVotes += weight;
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = weight;

        emit VoteCast(voter, proposalId, support, weight, reason);
        return weight;
    }

    function queue(uint256 proposalId) external whenNotPaused {
        ProposalState s = state(proposalId);
        if (s != ProposalState.Succeeded) {
            revert InvalidState(ProposalState.Succeeded, s);
        }

        Proposal storage p = proposals[proposalId];
        uint256 eta = block.timestamp + timelock.delay();
        p.eta = eta;

        for (uint256 i = 0; i < p.targets.length; i++) {
            timelock.queueTransaction(
                p.targets[i],
                p.values[i],
                p.signatures[i],
                p.calldatas[i],
                eta
            );
        }

        emit ProposalQueued(proposalId, eta);
    }

    function execute(uint256 proposalId) external payable whenNotPaused {
        ProposalState s = state(proposalId);
        if (s != ProposalState.Queued) {
            revert InvalidState(ProposalState.Queued, s);
        }

        Proposal storage p = proposals[proposalId];
        p.executed = true;

        for (uint256 i = 0; i < p.targets.length; i++) {
            timelock.executeTransaction{value: p.values[i]}(
                p.targets[i],
                p.values[i],
                p.signatures[i],
                p.calldatas[i],
                p.eta
            );
        }

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        ProposalState s = state(proposalId);
        if (s == ProposalState.Executed || s == ProposalState.Canceled || s == ProposalState.Expired) {
            revert InvalidState(ProposalState.Active, s);
        }

        Proposal storage p = proposals[proposalId];
        bool isProposer = (msg.sender == p.proposer);
        bool proposerLostThreshold = (token.getPastVotes(p.proposer, block.number - 1) < proposalThreshold);
        bool isGuardian = (address(guardian) != address(0) && msg.sender == guardian.guardian());

        if (!isGuardian && (!isProposer || !proposerLostThreshold)) {
            // Proposer can cancel if they lost threshold, or guardian can cancel
            if (!isProposer) revert Unauthorized();
        }

        p.canceled = true;
        for (uint256 i = 0; i < p.targets.length; i++) {
            if (p.eta > 0) {
                timelock.cancelTransaction(
                    p.targets[i],
                    p.values[i],
                    p.signatures[i],
                    p.calldatas[i],
                    p.eta
                );
            }
        }

        emit ProposalCanceled(proposalId);
    }

    function getProposal(uint256 proposalId)
        external
        view
        returns (
            address proposer,
            uint256 eta,
            uint256 startBlock,
            uint256 endBlock,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bool canceled,
            bool executed
        )
    {
        Proposal storage p = proposals[proposalId];
        return (
            p.proposer,
            p.eta,
            p.startBlock,
            p.endBlock,
            p.forVotes,
            p.againstVotes,
            p.abstainVotes,
            p.canceled,
            p.executed
        );
    }

    function getActions(uint256 proposalId)
        external
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            string[] memory signatures,
            bytes[] memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }
}
