// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {QmoosaToken} from "../src/QmoosaToken.sol";
import {QmoosaTimelock} from "../src/QmoosaTimelock.sol";
import {QmoosaGovernor} from "../src/QmoosaGovernor.sol";
import {EmergencyGuardian} from "../src/EmergencyGuardian.sol";

contract TargetContract {
    uint256 public value;

    function setValue(uint256 _value) external payable {
        value = _value;
    }
}

contract QmoosaGovernorTest is Test {
    QmoosaToken public token;
    QmoosaTimelock public timelock;
    QmoosaGovernor public governor;
    EmergencyGuardian public guardian;
    TargetContract public target;

    address public admin = address(0x10);
    address public proposer = address(0x20);
    address public voter1 = address(0x30);
    address public voter2 = address(0x40);
    address public attacker = address(0x99);
    address public guardianAddress = address(0x88);

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18; // 10M tokens
    uint256 public constant TIMELOCK_DELAY = 1 days;
    uint256 public constant VOTING_DELAY = 1; // 1 block
    uint256 public constant VOTING_PERIOD = 5; // 5 blocks
    uint256 public constant PROPOSAL_THRESHOLD = 100_000 * 1e18; // 100k tokens
    uint256 public constant QUORUM_PERCENT = 4; // 4%

    function setUp() public {
        vm.startPrank(admin);
        token = new QmoosaToken(INITIAL_SUPPLY, admin);
        timelock = new QmoosaTimelock(admin, TIMELOCK_DELAY);

        governor = new QmoosaGovernor(
            address(token),
            payable(address(timelock)),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENT
        );

        guardian = new EmergencyGuardian(address(governor), guardianAddress);
        governor.setGuardian(address(guardian));

        // Transfer timelock admin to governor
        timelock.setAdmin(address(governor));

        target = new TargetContract();

        // Distribute tokens
        token.transfer(proposer, 500_000 * 1e18); // 500k tokens (> 100k threshold)
        token.transfer(voter1, 1_000_000 * 1e18);  // 1M tokens (10% > 4% quorum)
        token.transfer(voter2, 200_000 * 1e18);    // 200k tokens
        vm.stopPrank();

        // Delegate voting power (users must delegate to themselves or others)
        vm.prank(proposer);
        token.delegate(proposer);

        vm.prank(voter1);
        token.delegate(voter1);

        vm.prank(voter2);
        token.delegate(voter2);

        // Mine a block so delegations are checkpointed
        vm.roll(block.number + 1);
    }

    function test_InitialState() public view {
        assertEq(token.balanceOf(proposer), 500_000 * 1e18);
        assertEq(token.getCurrentVotes(proposer), 500_000 * 1e18);
        assertEq(governor.proposalCount(), 0);
        assertEq(timelock.delay(), TIMELOCK_DELAY);
    }

    function test_FullProposalLifecycle() public {
        // Step 1: Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(target);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(42);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(
            targets,
            values,
            signatures,
            calldatas,
            "Proposal #1: Set Target Value to 42"
        );

        assertEq(proposalId, 1);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Pending));

        // Step 2: Roll past voting delay (1 block)
        vm.roll(block.number + 2);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Active));

        // Step 3: Cast Votes
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // 1 = For

        vm.prank(voter2);
        governor.castVote(proposalId, 0); // 0 = Against

        // Step 4: Roll past voting period (5 blocks)
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Succeeded));

        // Step 5: Queue proposal in Timelock
        governor.queue(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Queued));

        // Step 6: Attempt premature execution (must fail)
        vm.expectRevert();
        governor.execute(proposalId);

        // Step 7: Advance time past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Step 8: Execute proposal
        governor.execute(proposalId);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Executed));
        assertEq(target.value(), 42);
    }

    function test_FlashLoanVoteBorrowingFails() public {
        // Attacker starts with 0 tokens and 0 votes
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.getCurrentVotes(attacker), 0);

        // Step 1: Create proposal
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(999);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(
            targets,
            values,
            signatures,
            calldatas,
            "Proposal #2: Normal proposal"
        );

        // Roll into active voting block
        vm.roll(block.number + 2);
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Active));

        // Step 2: Simulating Flash-Loan in the active voting block
        // Attacker borrows 5,000,000 tokens during this active block
        vm.prank(admin);
        token.transfer(attacker, 5_000_000 * 1e18);

        vm.prank(attacker);
        token.delegate(attacker);

        // Attacker has current votes right now
        assertEq(token.getCurrentVotes(attacker), 5_000_000 * 1e18);

        // Step 3: Attacker attempts to cast vote on the active proposal
        // MUST REVERT because at proposal.startBlock (the historical checkpoint snapshot), attacker had 0 votes!
        vm.prank(attacker);
        vm.expectRevert(QmoosaGovernor.ZeroVotingPower.selector);
        governor.castVote(proposalId, 1);
    }

    function test_DoubleVotingReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");

        vm.roll(block.number + 2);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // Second vote must revert
        vm.prank(voter1);
        vm.expectRevert(QmoosaGovernor.AlreadyVoted.selector);
        governor.castVote(proposalId, 1);
    }

    function test_QuorumFailureDefeatsProposal() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");

        vm.roll(block.number + 2);

        // voter2 has 200k tokens (2%), quorum is 4% (400k tokens)
        vm.prank(voter2);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + VOTING_PERIOD + 1);

        // Quorum not met -> Defeated
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Defeated));
    }

    function test_EmergencyGuardianVeto() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Compromised Prop");

        vm.roll(block.number + 2);
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // Emergency Guardian detects exploit and vetoes proposal
        vm.prank(guardianAddress);
        guardian.vetoProposal(proposalId, "Exploit payload detected");

        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Vetoed));
    }

    function test_EmergencyGuardianPauseAndUnpause() public {
        vm.prank(guardianAddress);
        guardian.pause();
        assertTrue(guardian.isPaused());

        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        // Cannot propose while paused
        vm.prank(proposer);
        vm.expectRevert(QmoosaGovernor.GovernancePaused.selector);
        governor.propose(targets, values, signatures, calldatas, "Prop");

        // Unpause
        vm.prank(guardianAddress);
        guardian.unpause();
        assertFalse(guardian.isPaused());

        // Propose succeeds after unpause
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");
        assertEq(proposalId, 1);
    }

    function test_ProposerThresholdEnforcement() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        // voter2 only has 200k, let's test an address with < 100k
        address lowBalance = address(0x777);
        vm.prank(admin);
        token.transfer(lowBalance, 50_000 * 1e18); // 50k < 100k threshold
        vm.prank(lowBalance);
        token.delegate(lowBalance);
        vm.roll(block.number + 1);

        vm.prank(lowBalance);
        vm.expectRevert(QmoosaGovernor.ProposalThresholdNotMet.selector);
        governor.propose(targets, values, signatures, calldatas, "Prop Under Threshold");
    }

    function test_VotingBeforeStartBlockFails() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");

        // Immediately try to vote while state is Pending
        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Pending));
        vm.prank(voter1);
        vm.expectRevert(QmoosaGovernor.ProposalNotActive.selector);
        governor.castVote(proposalId, 1);
    }

    function test_InvalidVoteTypeReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");
        vm.roll(block.number + 2);

        vm.prank(voter1);
        vm.expectRevert(QmoosaGovernor.InvalidVoteType.selector);
        governor.castVote(proposalId, 3); // 3 is invalid (only 0, 1, 2)
    }

    function test_ExpiredProposalCannotExecute() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop");

        vm.roll(block.number + 2);
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + VOTING_PERIOD + 1);
        governor.queue(proposalId);

        // Fast forward past timelock delay AND past grace period (14 days)
        vm.warp(block.timestamp + TIMELOCK_DELAY + 15 days);

        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Expired));
        vm.expectRevert();
        governor.execute(proposalId);
    }

    function test_ProposalCancellationByGuardian() public {
        address[] memory targets = new address[](1);
        targets[0] = address(target);
        uint256[] memory values = new uint256[](1);
        string[] memory signatures = new string[](1);
        signatures[0] = "setValue(uint256)";
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encode(123);

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, signatures, calldatas, "Prop To Cancel");

        vm.roll(block.number + 2);

        vm.prank(guardianAddress);
        governor.cancel(proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(QmoosaGovernor.ProposalState.Canceled));
    }
}
