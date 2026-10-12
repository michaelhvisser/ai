---
name: plan-work
description: "Plan a feature, bug fix, refactor, performance change, or investigation with task-specific proof and a concrete implementation handoff. Use when planning admitted work or preparing a Detent plan. SKIP PR status reports; use pr-details."
argument-hint: "[issue or task]"
---

# Plan work

Resolve <PLUGIN_ROOT> from this SKILL.md's directory by ascending two levels
on Codex; use the injected per-plugin root on Claude Code. Read
<PLUGIN_ROOT>/lib/driver-interaction.md and
<PLUGIN_ROOT>/lib/decision-gates.md before resolving missing intent.

This is a planning skill. It does not implement, commit, publish, change issue
state, or replace the coordinator. Use the caller's supplied issue context;
fetch missing context only with authorized read access. A Detent plan-only
dispatch remains plan-only.

## Ground the plan

1. Read the admitted task, acceptance criteria, comments, repository instructions,
   existing plan/workpad, and relevant architecture records. Reconcile named
   files and symbols with the current target base. Record drift instead of
   replanning unrelated product scope.
2. Read <PLUGIN_ROOT>/lib/validation-policy.md. Record effective policy and
   the exact commands the implementation must run, including change-specific
   tests outside the normal fast gate.
3. Read <PLUGIN_ROOT>/lib/work-method.md. Select the task method, safety
   assumptions, design comparison, and evidence required by the task. Use
   existing diagnosis/design skills when available; the shared reference is
   sufficient when those skills are absent.
4. For a bug, use available existing reproduction evidence. If the caller
   permits nonmutating checks, run a bounded existing reproduction. If a new
   harness or fixture would require writes forbidden in this planning phase,
   specify it as the first implementation step and mark runtime proof pending.
   Do not imply that an unexecuted reproduction already failed.
5. Write the implementation handoff in build order. Name concrete files,
   functions, contracts, queries, migrations, and tests. Map every criterion
   to its observable outcome and verification method, including excluded
   roles, source instances, and failure paths where relevant. Include the
   setup and isolation prerequisites the next agent cannot infer.

## Completion

Return the plan to the calling workflow for its normal approval/posting flow.
Use its required format. When no format is supplied, include task/method,
effective policy, chosen design and rationale when needed, ordered changes,
criterion-to-check mapping, and unresolved prerequisites. Retain inapplicable
methods with reasons, without waiving repository gates.

A completed plan tells an agent with no prior conversation what to change,
how to prove it, and where to stop. Mark missing runtime proof as pending,
and missing scope or external prerequisites as blocked. Planning does not
establish implementation readiness or authorize merge.
