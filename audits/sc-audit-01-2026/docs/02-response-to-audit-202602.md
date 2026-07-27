---
layout: default
title: Response to Audit 202602
---

## Introduction

We would like to thank Gnosis Ltd and Côme du Crest for conducting the HOPR v4 Update Audit and for the thorough review of the scoped smart contracts.
We appreciate the clarity of the findings and the constructive recommendations provided throughout the report.

In the following sections, we address each finding in detail.

### 1. [Info] Memory safety of HoprNodeStakeFactory is frail

**Status:** <span style="background-color:#1a73e8; color:#ffffff; padding:2px 8px; border-radius:12px; font-size:0.85em;">Acknowledged</span>

#### Assessment

We agree with the finding.
The current implementation resizes the admins memory array using inline assembly, which relies on implicit assumptions about Solidity’s memory layout and compiler behavior.

This approach is inherently fragile and may break under different compiler versions, optimization settings, or future refactors.

#### Design rationale

We evaluated the recommendation to require the factory address to be appended by the caller, as well as alternative implementations that avoid in-place memory mutation.

However, we decided not to adopt these approaches for the following reasons:

- Developer experience: The admins array is expected to represent Safe owners.
  Requiring callers to include the factory address introduces a non-obvious requirement and leaks internal implementation details into the external interface.
- Gas efficiency: Constructing a new memory array to safely append the factory address would introduce additional memory allocation and copying costs in a frequently executed path.

Given the nature of this function, we prioritize a clean interface and gas efficiency.

#### Risk acceptance and mitigations

We acknowledge that this implementation depends on current compiler behavior and is not forward-proof.

To manage this risk:

- The contract is compiled and deployed with a fixed, pinned Solidity compiler version and configuration
- Any future compiler upgrade or refactor affecting this code path will require explicit re-evaluation of this pattern
- The logic is isolated and well understood, minimizing the likelihood of unintended memory interactions

Importantly, the identified issue does not introduce a direct security vulnerability (e.g., fund loss or privilege escalation), but rather a potential for functional breakage under changing conditions.

### 2. HoprLedger does not use `EfficientHashLib`

**Status:** <span style="background-color:#1a73e8; color:#ffffff; padding:2px 8px; border-radius:12px; font-size:0.85em;">Acknowledged</span>

#### Assessment

We reviewed this observation and determined that the current implementation in `HoprLedger.indexEvent()` is appropriate and does not require modification

#### Design rationale

Solady’s `EfficientHashLib` is generally advantageous in scenarios where hashing is performed over data encoded using `abi.encode`, as it can reduce memory overhead and improve gas efficiency in those cases.

However, the hashing logic in `HoprLedger.indexEvent()` relies on `abi.encodePacked`. For this encoding pattern, `EfficientHashLib` does not provide the same benefits and is not expected to yield measurable gas improvements.
As such, its omission from this function is intentional.

#### Risk acceptance and mitigations

There is no security or functional risk associated with the current implementation.
The consideration here is purely one of gas optimization.

We periodically review gas-sensitive code paths and will revisit this decision if:

- the hashing pattern changes, or
- new benchmarks demonstrate a clear advantage of alternative approaches in this context

### 3. HoprChannels version is still 2.0.0

**Status:** <span style="background-color:#188038; color:#ffffff; padding:2px 8px; border-radius:12px; font-size:0.85em;">Fixed</span> in commit `271bb6628ccf357d171785a4def539e357fa2844`

#### Assessment

We agree with the finding. The `VERSION` constant in `HoprChannels` was not updated to reflect the changes introduced in this iteration of the contract.

#### Design rationale

Version identifiers are intended to provide clarity to integrators, tooling, and downstream consumers regarding contract evolution.
Keeping these values in sync with contract updates is important to avoid confusion and ensure accurate version tracking.

#### Resolution

We have updated the `VERSION` constant in `HoprChannels` to reflect the current contract version.

In addition, we identified a similar inconsistency in `NodeSafeRegistry` contract and have updated its version identifier accordingly to maintain consistency across the codebase.

### 4. HoprAnnouncements does not use storage gaps

**Status:** <span style="background-color:#188038; color:#ffffff; padding:2px 8px; border-radius:12px; font-size:0.85em;">Fixed</span> in commit `faf84b28209e3ba9b3b1e19c9ed94220157e547a`.

#### Assessment

We agree with the observation.
As noted in the audit report, `HoprAnnouncements` is an upgradeable contract and inherits from contracts that use storage but do not reserve storage gaps, which may limit flexibility for future upgrades.

#### Design rationale

Although this does not introduce an immediate security issue in the current version, storage gaps are a well-established best practice for upgradeable contracts.
Reserving storage slots helps preserve upgrade flexibility and reduces the risk of storage layout incompatibilities when extending inherited contracts in future iterations.

#### Resolution

We have introduced storage gaps in the relevant contracts to reserve storage space for potential future state variables.

This change improves upgrade safety and aligns the inheritance chain more closely with established patterns for upgradeable contract design.
