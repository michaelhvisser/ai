# Work method and evidence

Use the sections that match the requested task. Repository policy and the
admitted plan determine scope, commands, required checks, and delivery authority.
A read-only review evaluates the evidence; it does not acquire permission to
implement a plan or run mutating verification.

## Route before implementation

Record the task class, applicable method, and acceptance checks in the existing
plan or canonical workpad. Mixed tasks may use more than one method.

- Bug: execute the original failure before patching, then repeat it after the fix.
- Feature or refactor: use the repository's established shape. When ownership,
  public interfaces, state representation, or concurrency is uncertain, compare
  two viable designs and write caller usage before choosing types and signatures.
- Performance: establish a correct baseline before changing code. Compare the
  same completed work, inputs, configuration, and environment; repeat measurements
  and identify the limiting resource. An unrelated microbenchmark is not proof
  of a user-visible improvement.
- Investigation: return supported findings and unresolved questions. Implement
  only when the request also authorizes fixes.

Retain an inapplicable method with a concrete reason. A reason explains routing;
it cannot waive a repository gate. Use existing repository skills or harnesses
when available. Language-specific test commands, generators, and checks are
resolved from repository instructions and the actual toolchain, not assumed
from a filename or a marketplace name.

## Reproduce and fix a bug

Before a fix, run a bounded check that reaches the real failure path and asserts
the reported symptom. A test, request, replay, or harness may provide the signal.
Confirm that the failure comes from the defect, rather than missing setup.

For intermittent failures, record the trigger, attempts, failure rate, and seed
or timing conditions. A single passing attempt does not disprove the bug.
Minimize the reproduction, state falsifiable hypotheses, and change one
variable at a time. Reuse an installed diagnosis skill if it covers this method.

Write the regression test at the public interface that reaches the bug. Run it
failing before the fix and passing after it; also rerun the original scenario.
When running old code requires an isolated base worktree, preserve the user's
current work and obey the repository's database and worker-isolation rules.
If access or a usable test interface is missing, record what was tried and the
unproven behavior. Follow repository policy on whether that blocks completion.
Keep required behavior tests even when a temporary reproduction is useful.

## Prove the safety assumption

For changes to shared contracts, stored formats, identity, authorization,
concurrency, or cleanup, name the one or two assumptions the change depends on.
Trace consumers outside the diff, persisted and serialized representations,
teardown/failure paths, and relevant pinned dependency behavior.

For each consequential assumption, run the cheapest check that could reject the
unsafe case. Record the assumption, source location, executed command, expected
outcome, actual result, and remaining uncertainty. Reading callers is useful
context; it does not establish runtime safety. An unproven assumption that the
change relies on remains a gap, subject to the repository's readiness rules.

A review stays within its existing finding bar. Missing historical evidence is
not by itself a code defect; demonstrate the introduced unsafe behavior or name
the concrete validation gap. Keep verified risks separate from checked-and-cleared
risks. Do not expand the diff to address hypothetical consumers.

## Design decisions and concurrency

For consequential design uncertainty, compare whole alternatives rather than
cosmetic variations. Record caller usage, ownership, invalid states, compatibility,
test interface, chosen design, and why the other viable design was rejected.
Use existing domain and architecture records. Do not start competing implementations
or additional model calls merely to satisfy the comparison.

Before authorized parallel work, identify blocking prerequisites, independent
artifacts, exclusive writable paths, and shared mutable resources. Prefer isolated
targets; serialize resources that cannot be safely separated. A single owner is
appropriate for tightly coupled changes. This method does not grant delegation
permission or change the coordinator's dispatch limits.

For a novel repeated task class, verify one complete unit before admitting a
large batch. Correct its brief or verifier based on the result. Existing routine
work does not require a new pilot on every run.

## Verification record

Extend the caller's existing workpad, result object, or evidence manifest. Each
required acceptance criterion records:

- criterion and verification method;
- exact code head, including a dirty-diff identity when work is uncommitted;
- command or artifact, actual result, and any prerequisite;
- verdict: pass, fail, blocked, or gap.

Pass means the check ran on the intended code and environment and established
the expected behavior. Fail means it ran and rejected that behavior. Blocked
means a named prerequisite prevented it. Gap means proof is absent or the
method does not reach the claimed behavior. Only pass satisfies a required
criterion. An applicable skip is not pass; keep its reason and let repository
policy decide whether that criterion is required.

A changed or rebased head invalidates evidence according to repository policy.
Refresh the required checks before readiness. Preserve proof artifacts through
cleanup and obey the caller's attachment requirements. Recipe existence,
receipt existence, and a command written in prose do not prove execution.

## Resume and repeated corrections

On resume, reconcile current branch, head, tracker state, pending feedback, and
evidence with the inherited workpad. Preserve completed work; rerun only checks
made stale by a changed head, environment, or unresolved concern.

Record important choices, rejected alternatives, unproven assumptions, and plan
deviations in the canonical workpad. Keep durable architectural tradeoffs in the
repository's decision records rather than creating another status log.

For a repeated confirmed mistake, first apply the existing in-scope root-fix
policy. When a new type, lint, test, or tooling check is warranted, prove it
rejects the historical failure and accepts the corrected case. Broader process
or skill changes need their own authorized scope; a review finding does not
authorize a repository-wide cleanup.
