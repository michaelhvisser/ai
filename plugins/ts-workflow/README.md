# ts-workflow

Issue-to-PR workflow automation for TypeScript and JavaScript projects, with git
worktree management.

Works with Next.js, Astro, Remix, Convex, Express/Hono APIs, and any other Node
repo — the skills detect the package manager and read `package.json` scripts
rather than assuming a fixed toolchain.

## Installation

Add the marketplace, then install the plugin:

```bash
/plugin marketplace add michaelhvisser/ai
/plugin install ts-workflow@michaelhvisser-ai
```

## Project Detection

Every skill resolves the toolchain before running commands:

| Signal | Result |
|--------|--------|
| `pnpm-lock.yaml` | `pnpm` |
| `yarn.lock` | `yarn` |
| `bun.lock` / `bun.lockb` | `bun` |
| `package-lock.json` or no lockfile | `npm` |
| `turbo.json`, `nx.json`, `pnpm-workspace.yaml` | monorepo — root scripts run from the repo root and fan out to workspaces |

The `scripts` block in `package.json` is the authority for which verification
commands exist: build → `<pm> run build`, type-check → `<pm> run type-check`
(falling back to `npx tsc --noEmit`), tests → `<pm> run test` (falling back to
vitest or jest), lint → `<pm> run lint`, dev server → `<pm> run dev`. Browser
E2E uses Chrome DevTools MCP, plus the repo's Playwright suite when one is
configured.

## Workflow Skills and Commands

| Claude Code invocation | Description |
|------------------------|-------------|
| `/ts-workflow:start-issue <number>` | Start working on a GitHub issue (auto-detects bug vs feature) |
| `/ts-workflow:address-review [PR]` | Address PR review comments, fix, and loop until bots approve |
| `/ts-workflow:review-deep [PR]` | Deep code review with full PR context, then fix findings |
| `/ts-workflow:e2e-verify [PR]` | Run browser E2E verification on a PR |
| `/ts-workflow:ship` | Verify, push, watch CI/reviews, and merge |
| `/ts-workflow:cancel-loop [loop-name]` | Cancel active persistent workflow state |

`commit`, `create-pr`, `antagonist-review`, `codex-ship`, and the worktree commands
(`/create-worktree`, `/remove-worktree`, `/prune-worktree`) moved to the
language-agnostic [`workflow`](../workflow) plugin as of 0.3.0. They are no longer
part of this plugin, so **install `workflow` alongside this one** to keep them:

```bash
/plugin install workflow@michaelhvisser-ai
```

The two are meant to run together: `workflow` owns commits, PRs, worktrees, and
cross-model review for any language; `ts-workflow` owns the Node-specific
`start-issue` → `ship` pipeline. `/workflow:codex-ship` dispatches back into
`ts-workflow` for `address-review` and `ship` when it detects a Node repo.

## Skill Invocation Modes

| Mode | Skills |
|------|--------|
| Slash-only | `start-issue`, `address-review`, `cancel-loop`, `e2e-verify`, `ship`, `complete-issue`, `tmux-start` |
| Auto-triggerable | `review-deep` |

Slash-only skills still run through their slash commands, but their descriptions are omitted from the always-loaded auto-invoked skill list. Use `/ts-workflow:<command>` in Claude Code or `$ts-workflow:<skill>` in Codex. Codex requires the qualified plugin name; bare skill names are not resolver aliases. In Claude Code, type the slash command directly; `$ts-workflow:start-issue` is Codex syntax and causes a blocked Skill-tool invocation. Auto-triggerable skills remain available from natural-language requests such as "commit these changes" or "review my changes".

## Workflows

### Start Issue

The `start-issue` skill provides an intelligent issue-to-PR workflow:

1. **Fetches issue details** including all comments for full context
2. **Offers worktree creation** for isolated work (creates `../repo-issue-123-title/`)
3. **Auto-detects issue type** by analyzing labels, then title/body patterns
4. **Routes to appropriate workflow:**
   - **Bug fix**: Checks duplicates → TDD approach (failing `*.test.ts` first) → `fix/` branch
   - **Feature**: Plans approach → Implementation → Tests → `feat/` branch
5. **Asks for clarification** if the type can't be determined automatically

Tests follow the repo's runner and naming (`*.test.ts` / `*.spec.ts`, colocated
or under `__tests__/`), with `it.each`/`test.each` for parameterized cases.

#### Surface-Aware Orchestration

The default start flow uses native delegation when the active surface supports
all required roles. The four prompt Markdown bodies are shared behavioral
templates; each surface supplies its own dispatch metadata.

Claude Code uses the custom agent definitions and their model frontmatter:

| Agent | Model policy |
|-------|--------------|
| Explore | Haiku |
| Implementer | Inherits the parent session model |
| Spec Review | Sonnet |
| Quality Review | Sonnet |

Set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` before a Claude Code
`/ts-workflow:start-issue` or `/ts-workflow:complete-issue` run to override
those agent models.

Codex maps Explore to its `explorer` profile, Implementer to `worker`, and both
review roles to `default`. Delegated agents inherit the active Codex model,
reasoning effort, and configuration. If the required native profiles are not
available, Codex explains the limitation and uses the single-session workflow.
Use `--no-agents` to select the single-session workflow explicitly on either
surface.

#### Codex Model Defaults

The `$ts-workflow:ship` and `$ts-workflow:complete-issue` Codex review stages
omit model flags by default. A `model = "..."` pin in `~/.codex/config.toml`
overrides the provider default for those stages; leaving it unset lets the
Codex CLI use its latest recommended model automatically.

### Address Review

The `$ts-workflow:address-review` skill handles PR review feedback
automatically:

1. **Fetches all feedback** - Review threads (line comments) and pending reviews
2. **Addresses each comment** - Makes code fixes based on feedback
3. **Watches CI** - Ensures all checks pass before continuing
4. **Resolves threads** - Auto-resolves line-specific review threads via GraphQL
5. **Requests re-review** - Automatically triggers re-review from reviewers

#### Auto Bot Re-review

When supported bot reviewers leave feedback, the skill automatically requests
re-review only when discovered among the pull request's actual reviewers.

**Supported bots:**
- `chatgpt-codex-connector[bot]` → `@codex review`
- `coderabbitai[bot]` → `@coderabbitai full review`
- `greptileai` → `@greptileai`
- `copilot-pull-request-review[bot]` → Manual re-request through GitHub Reviewers

**To disable auto bot re-review**, add to your project's CLAUDE.md:
```markdown
## Bot Review Settings
DISABLE_BOT_REREVIEW=true
```

### E2E Verify

`$ts-workflow:e2e-verify` rebases the PR, runs the repo's build/type-check/test/
lint scripts, starts the dev server (`<pm> run dev`), and drives a real browser
through the changed routes via Chrome DevTools MCP — reading every screenshot
and comparing it against the issue spec. Route discovery understands Next.js
App and Pages Router, Astro `src/pages`, Remix `app/routes`, and
Express/Hono/Fastify registrations. A configured Playwright suite runs as a
supplement; it never substitutes for the visual check.
## Local Review Cost and Opt-in

Sub-agent reviews can double the session's token cost by loading another
context, and are disabled by default in ship and review-deep. Ship tries usable
external review CLIs; when none is available, it reports and records a skipped
local review while retaining verification, coverage, E2E, and current-head PR
CI gates. Review-deep addresses findings in the current context, including
large sets of findings across multiple files.

A project that wants a sub-agent review must opt in explicitly, for example by
requesting `$ts-workflow:ship --llm fable` in its workflow instructions.
Review-deep delegation likewise requires an explicit project or user request;
finding count alone never opts in. Explicit backend choices are not silently
replaced.

## Requirements

- Node.js 20+ and one of pnpm / npm / yarn / bun
- GitHub CLI (`gh`) - authenticated
- Git with worktree support
- Chrome DevTools MCP (for `e2e-verify` browser testing)
- The [`workflow`](../workflow) plugin — provides `commit`, `create-pr`, and the
  worktree commands these workflows call

## Credits

Forked from go-workflow in gopherguides/gopher-ai (MIT).

## License

MIT - see [LICENSE](../../LICENSE)
