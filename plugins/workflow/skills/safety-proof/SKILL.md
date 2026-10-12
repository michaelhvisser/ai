---
name: safety-proof
description: "Trace a proposed or implemented change beyond its diff and execute checks for the assumptions that make it safe. Use for blast-radius questions or risky shared-contract, identity, authorization, concurrency, storage-format, or cleanup changes. SKIP general code review; use review-deep or antagonist-review."
argument-hint: "[change or invariant]"
---

# Prove change safety

Resolve <PLUGIN_ROOT> from this file's directory by ascending two levels on
Codex; use the injected per-plugin root on Claude Code. Read
<PLUGIN_ROOT>/lib/driver-interaction.md and
<PLUGIN_ROOT>/lib/decision-gates.md.

Read the repository instructions and the proposed change or current diff.
Read the safety-assumption and verification-record sections of
<PLUGIN_ROOT>/lib/work-method.md. Read
<PLUGIN_ROOT>/lib/validation-policy.md before launching a runtime check.

Name the one or two assumptions on which safety depends. Trace relevant
callers, stored and serialized data, dependency versions, cleanup, and
failure paths. Execute the narrowest authorized checks that could disprove
those assumptions. Respect test fixtures, database wrappers, and worker
isolation required by the target repository.

For a review-only request, keep repository files and external systems unchanged.
Use existing safe checks where possible. When a new harness, fixture, write, or
missing access is necessary, return a gap and the concrete check to run rather
than treating the request as implementation authorization.

Return each assumption with its source location, check, observed result,
verdict, affected consumers, and remaining uncertainty. Separate confirmed
risks from checked-and-cleared risks. An assertion, source reading, or absent
search result does not become executed runtime proof. Keep the calling review's
finding bar and scope; unproven safety is a validation gap until unsafe behavior
is demonstrated.
