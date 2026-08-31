# Agent guidance — michaelhvisser/ai

This repo is a Claude Code plugin marketplace (`michaelhvisser-ai`): plugins under
`plugins/<name>/`, each with skills in `skills/<skill>/SKILL.md`, shared per-plugin
helpers in `lib/`, and dual manifests (`.claude-plugin/` and `.codex-plugin/`).

**Before creating or editing any SKILL.md, `lib/*.md`, or this file, read
`.agents/writing-for-agents.md`** — the authoring standard. Its "House mechanics" section
carries the frontmatter, zsh-safety, per-plugin-root, and verified-recipe rules that have
each been violated here at least once.

## Verification

The gate is `bash scripts/check.sh`: version sync (`--check`) plus
`claude plugin validate --strict`. Shell-hook tests live per plugin
(`plugins/*/tests/*.test.sh`) and run with plain `bash`.

## Versions

`.claude-plugin/marketplace.json` is the canonical version source. To bump a plugin, edit
its version there and run `node scripts/sync-versions.mjs` — never hand-edit
`plugins/<name>/.claude-plugin/plugin.json` or `.codex-plugin/plugin.json`; the script
rewrites only the version line so formatting and em-dashes survive. Bump the plugin
version in the same PR as the change it ships.

## Release flow

Branch → PR → squash merge to `main`. Consumers then run
`/plugin marketplace update michaelhvisser-ai` and `/reload-plugins`. Never commit to
`main` directly.

## Supported context — the boundary review findings are judged against

These skills are built for one operating context, declared so authors and reviewers judge
findings against it rather than against everything git permits:

- **Same-repository PRs on github.com.** Fork-ambient checkouts, forks as push targets,
  and GitHub Enterprise hosts are handled by loud refusal at the boundary
  (`PUSH_UNRESOLVED`, non-dispatchable gate entries, cross-repo preflight stops) — never
  by feature work.
- **zsh and bash on macOS and Linux.** Every fenced block must run under both; no other
  shell is considered.
- **The workflows this marketplace serves:** single-operator repos with squash-merge
  rulesets, optional CI, and the Detent/Claude/Codex agents as the acting parties.

A review finding about behavior outside this boundary is dismissed with reason
`out-of-context` and a pointer here — unless the diff under review moved the boundary
itself, or the finding shows a boundary **guard failing to refuse**. A guard that refuses
loudly is the supported behavior, not a gap.

## Review-loop economics

Rules for running reviewer loops against PRs here. They exist because a prose skill
wrapping git has an unbounded hypothetical-input space, and the Codex connector rations a
handful of findings per round — a loop whose only exit is "the reviewer found nothing"
does not terminate against that combination.

1. **Front-load the exhaustive pass.** Run the strong local review (antagonist-review's
   finder, or review-deep) and fix its batch **before** the first `@codex review`. The
   connector then spends its rounds on genuine second-family leftovers instead of
   drip-feeding a pool one local pass would have enumerated.
2. **Class-jump rule.** When round N's findings attack the fix round N−1 shipped, stop
   patching that mechanism. Redesign it — preferably by deleting the state or fallback
   under attack — or dismiss the class under the boundary above. The fixes that stick are
   the ones that remove moving parts.
3. **Relevance is a bar, not a counter.** Out-of-context findings and example-text
   consistency nits are *dismissed*, so a round containing only those is a clear round
   under the loop's standard exit — merge. The failure this prevents is confirming
   out-of-context findings as real, which is how loops run to the cap. "Found nothing
   that matters here" is the reachable exit; "found nothing" is not.

## Decision records

Agreed-but-deferred work lives in `.agents/deferred.md` with the trigger that would
revive each item; durable decision history goes in `.agents/adr/`. Out-of-scope findings
go to one of those two files, not into skill prose.
