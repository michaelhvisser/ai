# Resolve validation and delivery policy

Read after identifying the target repository and before CI triggers, polling,
readiness labels, or merge actions. Resolve policy again on resume.

## Effective policy

Read repository agent instructions, WORKFLOW.md, any applicable local workflow,
and coordinator configuration. Respect their stated precedence and the user's
existing authorization. Record the effective local gate, required change-specific
checks, CI mode, human-approval boundary, isolation prerequisites, and policy
sources in the existing workpad. Do not expose credentials.

Bind VALIDATION_MODE to local when repository policy explicitly makes local
validation authoritative or prohibits worker CI polling. Bind it to pr-ci when
policy requires current-head PR checks. Bind it to auto with no explicit
policy and retain the calling skill's CI applicability checks. An explicit
pr-ci policy may require external checks without GitHub Actions files; missing
workflow files cannot override it. Contradictory requirements that the declared precedence
cannot resolve are a concrete policy gap, not permission to guess.

This binding is derived from policy, not a user-set environment override or
an invented bypass flag. Missing remote checks cannot select local mode.
Local mode never changes repository rulesets or substitutes for an actual
server-required check.

Resolve this policy before the caller's resume phase routing, using its
persisted target repository. Record the resolved validation mode and policy
sources in its existing state. A saved `has_ci=false` is evidence of a prior
decision, not current authority. If a resumed ship now requires PR CI after
local mode, clear the saved CI skip and route through exact-head CI before bot
review or merging. If a new local gate, required check, head, or isolation
prerequisite makes inherited evidence stale, return to verification first.
Recheck current human approval independently; a policy change cannot grant it.

## Local validation path

When VALIDATION_MODE is local, skip the caller's CI registration waits, watchers,
and automatic trigger-label steps. Use this procedure in their place:

1. Finish all edits, synchronization, generation, and migration renumbering.
2. Run the repository's local gate and all required change-specific checks,
   including tests its fast gate skips. Record commands, results, and the exact
   tested head or dirty-diff identity. Failed, blocked, or missing required
   evidence prevents readiness.
3. After a commit, rerun any checks repository policy requires on the final head.
   After publishing, read the PR head once and compare it with the tested local
   SHA. A different head needs reconciliation and fresh evidence. Do not poll
   commit statuses to manufacture a local-mode requirement.
4. Preserve the existing structured readiness metadata and proof artifacts.
   Record CI as not applicable under the cited policy, never as passed.
5. Continue only to the caller's authorized next phase. Human Review and merge
   approval remain independent of passing validation.

A later edit, rebase, or remote head shift follows the repository's evidence
invalidation rules. A required local check cannot be waived by choosing another
mode. Read-only reports may report missing evidence, but do not run mutating
checks or claim a gate passed.

## CI and labels

In pr-ci mode, use the caller's bounded exact-head check monitor and handle
unavailable, failed, or changed-head results explicitly.

Before applying a CI-trigger or readiness label, verify that current repository
policy and configuration name it and that the requested action is authorized.
A conventional name such as run-full-ci does not establish that a label starts
a workflow. Local-mode operator-requested jobs use the repository's documented
trigger helper and remain supplemental unless policy states otherwise.

Verification recipes use an explicitly known test tenant or fixture. A login
picker's first visible organization is not proof that it is suitable for
capturing or posting evidence. Report the missing safe fixture when none is
available. Own the processes, ports, data, browser profile, and worker queues
used by a run, and clean up only resources that run created.
