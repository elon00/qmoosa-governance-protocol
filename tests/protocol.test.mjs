import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ProposalState,
  VoteType,
  DEFAULT_GOVERNANCE_CONFIG,
  getPastVotes,
  calculateQuorum,
  isTimelockExecutable,
  resolveProposalState
} from '../dist/index.js';

test('Protocol Invariant: Checkpoint Binary Search Lookup', () => {
  const checkpoints = [
    { fromBlock: 10, votes: 100n },
    { fromBlock: 20, votes: 250n },
    { fromBlock: 30, votes: 500n },
    { fromBlock: 50, votes: 1000n }
  ];

  // Block prior to first checkpoint
  assert.equal(getPastVotes(checkpoints, 5, 100), 0n);

  // Exact checkpoint blocks
  assert.equal(getPastVotes(checkpoints, 10, 100), 100n);
  assert.equal(getPastVotes(checkpoints, 20, 100), 250n);
  assert.equal(getPastVotes(checkpoints, 30, 100), 500n);
  assert.equal(getPastVotes(checkpoints, 50, 100), 1000n);

  // In-between blocks
  assert.equal(getPastVotes(checkpoints, 15, 100), 100n);
  assert.equal(getPastVotes(checkpoints, 25, 100), 250n);
  assert.equal(getPastVotes(checkpoints, 49, 100), 500n);
  assert.equal(getPastVotes(checkpoints, 75, 100), 1000n);

  // Empty checkpoints
  assert.equal(getPastVotes([], 50, 100), 0n);

  // Rejects future or current block
  assert.throws(
    () => getPastVotes(checkpoints, 100, 100),
    /CANNOT_QUERY_CURRENT_OR_FUTURE_BLOCK/
  );
  assert.throws(
    () => getPastVotes(checkpoints, 105, 100),
    /CANNOT_QUERY_CURRENT_OR_FUTURE_BLOCK/
  );
});

test('Protocol Invariant: Quorum Calculation with BigInt', () => {
  const totalSupply = 10_000_000n * 10n ** 18n; // 10M tokens
  const quorum = calculateQuorum(totalSupply, 4n, 100n);
  assert.equal(quorum, 400_000n * 10n ** 18n); // 400k tokens (4%)

  assert.throws(() => calculateQuorum(totalSupply, 4n, 0n), /DIVISION_BY_ZERO/);
});

test('Protocol Invariant: Timelock Execution Window', () => {
  const now = 1_000_000;
  const eta = now + 86400; // 1 day in future
  const grace = 14 * 86400;

  // Not queued
  assert.deepEqual(isTimelockExecutable(0, now), {
    executable: false,
    reason: 'NOT_QUEUED'
  });

  // Timelock not met
  assert.deepEqual(isTimelockExecutable(eta, now), {
    executable: false,
    reason: 'TIMELOCK_NOT_MET'
  });

  // Executable at ETA
  assert.deepEqual(isTimelockExecutable(eta, eta), {
    executable: true
  });

  // Executable within grace period
  assert.deepEqual(isTimelockExecutable(eta, eta + grace - 1), {
    executable: true
  });

  // Expired past grace period
  assert.deepEqual(isTimelockExecutable(eta, eta + grace + 1), {
    executable: false,
    reason: 'TRANSACTION_EXPIRED'
  });
});

test('Protocol Invariant: Proposal State Machine Resolution', () => {
  const quorum = 400_000n * 10n ** 18n;
  const base = {
    currentBlock: 10,
    currentTime: 1000,
    startBlock: 20,
    endBlock: 50,
    forVotes: 500_000n * 10n ** 18n,
    againstVotes: 100_000n * 10n ** 18n,
    abstainVotes: 0n,
    quorum,
    eta: 0,
    canceled: false,
    executed: false,
    vetoed: false
  };

  // Pending
  assert.equal(resolveProposalState({ ...base, currentBlock: 15 }), ProposalState.Pending);

  // Active
  assert.equal(resolveProposalState({ ...base, currentBlock: 30 }), ProposalState.Active);

  // Vetoed
  assert.equal(resolveProposalState({ ...base, vetoed: true }), ProposalState.Vetoed);

  // Canceled
  assert.equal(resolveProposalState({ ...base, canceled: true }), ProposalState.Canceled);

  // Executed
  assert.equal(resolveProposalState({ ...base, executed: true }), ProposalState.Executed);

  // Defeated: voting ended, quorum not reached
  assert.equal(
    resolveProposalState({
      ...base,
      currentBlock: 55,
      forVotes: 100_000n * 10n ** 18n // < 400k
    }),
    ProposalState.Defeated
  );

  // Defeated: voting ended, against >= for
  assert.equal(
    resolveProposalState({
      ...base,
      currentBlock: 55,
      forVotes: 500_000n * 10n ** 18n,
      againstVotes: 600_000n * 10n ** 18n
    }),
    ProposalState.Defeated
  );

  // Succeeded: voting ended, quorum reached, for > against, not yet queued
  assert.equal(
    resolveProposalState({
      ...base,
      currentBlock: 55
    }),
    ProposalState.Succeeded
  );

  // Queued: eta set
  assert.equal(
    resolveProposalState({
      ...base,
      currentBlock: 55,
      eta: 2000,
      currentTime: 1500
    }),
    ProposalState.Queued
  );

  // Expired: eta past grace period
  assert.equal(
    resolveProposalState({
      ...base,
      currentBlock: 55,
      eta: 2000,
      currentTime: 2000 + 14 * 86400 + 10
    }),
    ProposalState.Expired
  );
});
