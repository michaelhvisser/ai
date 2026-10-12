---
name: verify-feature
description: "Create, maintain, or run repository-local feature-verification recipes that drive the real UI, CLI, or service and preserve evidence. Use when repeatable runtime verification is missing or has drifted. SKIP ordinary unit-test runs and PR shipping; use the repository's test or ship workflow."
argument-hint: "[feature] [create|maintain|run]"
---

# Verify a feature

Resolve <PLUGIN_ROOT> from this file's directory by ascending two levels on
Codex; use the injected per-plugin root on Claude Code. Read
<PLUGIN_ROOT>/lib/driver-interaction.md and
<PLUGIN_ROOT>/lib/decision-gates.md. Resolve the requested mode from the user
request; creating or maintaining a recipe does not authorize product fixes,
deployment, publication, or sending messages.

Read <PLUGIN_ROOT>/lib/validation-policy.md and the verification-record
section of <PLUGIN_ROOT>/lib/work-method.md. Bind the target repository's
actual runtime and interaction tools. UI, CLI, and service verification share
the evidence contract; their launch and drive commands differ.

## Locate or build the recipe

Reuse the repository's existing verification skill, feature index, or test
harness. If none exists and creation is requested, put a small recipe next to
its maintained verification guidance. Record:

- feature and supported entry points, from actual source;
- code head, safe fixture or known test organization, and prerequisites;
- launch/readiness and interaction commands or selectors;
- action, observable result, and expected persisted or external side effect;
- evidence location and cleanup for only the run's own resources.

Use real commands and stable handles found in the repository. A script written
down but never run is a draft recipe. Keep ordinary regression tests; do not
build a second harness merely to duplicate them.

## Execute and maintain

Drive the actual user path with authorized test data. Capture the action and
result, and check the relevant side effect. A convenient internal setter or
test-only endpoint does not establish the user path. For visible UI, read the
captured images with vision and follow the repository's attachment rules.
Backend or CLI work uses output and behavior evidence rather than invented
screenshots.

In create mode, execute the new recipe end to end for the named feature before
delivery. In maintain mode, compare affected source entry points with the
feature index, update only recipe-owned files, and run every affected recipe.
A wider maintenance sweep runs every feature it claims to cover. An unavailable
path remains blocked or gap; it cannot silently disappear from the index.
In run mode, use the recipe without changing it unless maintenance was also
authorized.

Clean up after successful and failed attempts, retaining the evidence. Record
criterion, method, exact head, command/artifact, actual result, and verdict in
the caller's existing manifest or workpad. Distinguish recipe drift, interaction
tool gaps, product defects, and missing prerequisites. Report product defects
without fixing them unless the request also authorizes fixes.

Completion names what ran, what it proved, coverage gaps, recipe changes,
evidence, and cleanup. A create or maintain result is complete only when its
claimed recipes have executed successfully; otherwise deliver an explicit
incomplete draft. A run is verified only for the criteria with pass evidence.
