# QMOOSA Governance Protocol (`qmoosa-governance-protocol`)

## Overview
Part of the **QMOOSA 1,000 Crypto Projects Mission — Domain 1 (DeFi & Financial Invariants)**.
Repository ID: `046/1000`.

`qmoosa-governance-protocol` specifies the core contracts, types, mathematical models, and invariants for decentralized autonomous governance:
- **`QmoosaToken`**: ERC20 token with checkpointed historical voting power and delegation. Evaluates voting power strictly at historical snapshot blocks, rendering flash-loan voting attacks mathematically impossible.
- **`QmoosaTimelock`**: Enforces minimum delay (1 day to 30 days) and grace period (14 days) before executing passed proposals, guaranteeing community response windows.
- **`QmoosaGovernor`**: Proposal lifecycle state machine (`Pending`, `Active`, `Defeated`, `Succeeded`, `Queued`, `Executed`, `Canceled`, `Vetoed`, `Expired`).
- **`EmergencyGuardian`**: Multi-signature emergency guardian pause and veto authority with bounded duration (maximum 7 days pause).

## Verification
- Unit & Invariant Testing: 12 Foundry tests, 4 Node.js protocol tests.
- Zero-Spend Invariant: $0.00 spent on live networks. Mainnet and public testnets remain strictly locked.
