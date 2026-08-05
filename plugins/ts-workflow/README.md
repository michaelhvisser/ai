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
| `/ts-workflow:commit` | Create a git commit with auto-generated message |
| `/ts-workflow:create-pr` | Create a PR following the repo template |
| `/ts-workflow:e2e-verify [PR]` | Run browser E2E verification on a PR |
| `/ts-workflow:ship` | Verify, push, watch CI/reviews, and merge |
| `/ts-workflow:create-worktree <number>` | Create a new git worktree for isolated issue work |
| `/ts-workflow:remove-worktree` | Interactively select and remove a git worktree |
| `/ts-workflow:prune-worktree` | Batch cleanup of all completed issue worktrees |

## Skill Invocation Modes

| Mode | Skills |
|------|--------|
| Slash-only | `start-issue`, `address-review`, `worktree` (`/create-worktree`, `/remove-worktree`, `/prune-worktree`), `e2e-verify`, `ship`, `complete-issue`, `tmux-start` |
| Auto-triggerable | `commit`, `create-pr`, `review-deep` |

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

#### Subagent Model Tiering

The default orchestrated flow routes read-heavy and review subagents through
rolling model aliases in agent prompt frontmatter:

| Agent | Model policy |
|-------|--------------|
| Explore | Haiku |
| Implementer | Inherits the parent session model |
| Spec Review | Sonnet |
| Quality Review | Sonnet |

Set `CLAUDE_CODE_SUBAGENT_MODEL=<model>` before running
`$ts-workflow:start-issue` or `$ts-workflow:complete-issue` to override all
subagent models for that run. Use
`--no-agents` to switch to the single-session workflow.

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

When bot reviewers (Codex, CodeRabbit, Greptile, etc.) leave feedback, the skill automatically requests re-review by posting `@bot review` comments.

**Supported bots:**
- `codex` → `@codex review`
- `coderabbitai` → `@coderabbitai review`
- `greptileai` → `@greptileai review`
- `copilot` → Added via GitHub Reviewers

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

## Requirements

- Node.js 20+ and one of pnpm / npm / yarn / bun
- GitHub CLI (`gh`) - authenticated
- Git with worktree support
- Chrome DevTools MCP (for `e2e-verify` browser testing)

## Credits

Forked from go-workflow in gopherguides/gopher-ai (MIT).

## License

MIT - see [LICENSE](../../LICENSE)
