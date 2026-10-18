/**
 * @file index.ts
 * @notice QMOOSA Governance Protocol — Specification, Mathematical Models, and Invariant Verification
 */

export enum ProposalState {
  Pending = 0,
  Active = 1,
  Canceled = 2,
  Defeated = 3,
  Succeeded = 4,
  Queued = 5,
  Expired = 6,
  Executed = 7,
  Vetoed = 8
}

export enum VoteType {
  Against = 0,
  For = 1,
  Abstain = 2
}

export interface Checkpoint {
  readonly fromBlock: number;
  readonly votes: bigint;
}

export interface GovernanceConfig {
  readonly votingDelay: number; // in blocks (e.g. 1)
  readonly votingPeriod: number; // in blocks (e.g. 50400)
  readonly proposalThreshold: bigint; // e.g. 100,000 * 10^18
  readonly quorumNumerator: bigint; // e.g. 4 for 4%
  readonly quorumDenominator: bigint; // e.g. 100
  readonly timelockDelay: number; // in seconds (e.g. 86400)
  readonly gracePeriod: number; // in seconds (e.g. 14 days = 1209600)
}

export const DEFAULT_GOVERNANCE_CONFIG: Readonly<GovernanceConfig> = Object.freeze({
  votingDelay: 1,
  votingPeriod: 50400,
  proposalThreshold: 100_000n * 10n ** 18n,
  quorumNumerator: 4n,
  quorumDenominator: 100n,
  timelockDelay: 86400,
  gracePeriod: 14 * 86400
});

/**
 * Calculates historical checkpoint voting weight using binary search over past checkpoints.
 * Replicates EVM binary search checkpoint lookup strictly.
 */
export function getPastVotes(
  checkpoints: readonly Checkpoint[],
  blockNumber: number,
  currentBlock: number
): bigint {
  if (blockNumber >= currentBlock) {
    throw new Error("CANNOT_QUERY_CURRENT_OR_FUTURE_BLOCK");
  }

  const n = checkpoints.length;
  if (n === 0) {
    return 0n;
  }

  // If oldest checkpoint is newer than target block, 0 votes
  if (checkpoints[0].fromBlock > blockNumber) {
    return 0n;
  }

  // Binary search for most recent checkpoint on or before blockNumber
  let lower = 0;
  let upper = n - 1;

  while (upper > lower) {
    const center = Math.ceil((upper + lower) / 2);
    const cp = checkpoints[center];
    if (cp.fromBlock === blockNumber) {
      return cp.votes;
    } else if (cp.fromBlock < blockNumber) {
      lower = center;
    } else {
      upper = center - 1;
    }
  }

  return checkpoints[lower].votes;
}

/**
 * Calculates required quorum weight at a snapshot block
 */
export function calculateQuorum(
  totalSupply: bigint,
  quorumNumerator: bigint = DEFAULT_GOVERNANCE_CONFIG.quorumNumerator,
  quorumDenominator: bigint = DEFAULT_GOVERNANCE_CONFIG.quorumDenominator
): bigint {
  if (quorumDenominator === 0n) throw new Error("DIVISION_BY_ZERO");
  return (totalSupply * quorumNumerator) / quorumDenominator;
}

/**
 * Evaluates whether a queued transaction is within its legal execution window.
 */
export function isTimelockExecutable(
  eta: number,
  currentTime: number,
  gracePeriod: number = DEFAULT_GOVERNANCE_CONFIG.gracePeriod
): { executable: boolean; reason?: string } {
  if (eta === 0) {
    return { executable: false, reason: "NOT_QUEUED" };
  }
  if (currentTime < eta) {
    return { executable: false, reason: "TIMELOCK_NOT_MET" };
  }
  if (currentTime > eta + gracePeriod) {
    return { executable: false, reason: "TRANSACTION_EXPIRED" };
  }
  return { executable: true };
}

/**
 * Resolves proposal state given current block, timestamp, and vote tallies.
 */
export function resolveProposalState(params: {
  currentBlock: number;
  currentTime: number;
  startBlock: number;
  endBlock: number;
  forVotes: bigint;
  againstVotes: bigint;
  abstainVotes: bigint;
  quorum: bigint;
  eta: number;
  canceled: boolean;
  executed: boolean;
  vetoed: boolean;
  gracePeriod?: number;
}): ProposalState {
  if (params.vetoed) return ProposalState.Vetoed;
  if (params.canceled) return ProposalState.Canceled;
  if (params.executed) return ProposalState.Executed;

  if (params.currentBlock <= params.startBlock) {
    return ProposalState.Pending;
  }
  if (params.currentBlock <= params.endBlock) {
    return ProposalState.Active;
  }

  const quorumReached = params.forVotes + params.abstainVotes >= params.quorum;
  const voteSucceeded = params.forVotes > params.againstVotes;

  if (!quorumReached || !voteSucceeded) {
    return ProposalState.Defeated;
  }

  if (params.eta === 0) {
    return ProposalState.Succeeded;
  }

  const grace = params.gracePeriod ?? DEFAULT_GOVERNANCE_CONFIG.gracePeriod;
  if (params.currentTime > params.eta + grace) {
    return ProposalState.Expired;
  }

  return ProposalState.Queued;
}
