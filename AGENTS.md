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

## Decision records

Agreed-but-deferred work lives in `.agents/deferred.md` with the trigger that would
revive each item; durable decision history goes in `.agents/adr/`. Out-of-scope findings
go to one of those two files, not into skill prose.
