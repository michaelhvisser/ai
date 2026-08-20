# michaelhvisser/ai

AI coding assistant plugins for shipping software — by [Michael Visser](https://michaelhvisser.com).

This is a [Claude Code](https://claude.ai/code) plugin marketplace: a curated collection of the workflows and skills I use daily, packaged so anyone can use them. The review, PR, and worktree machinery is language-agnostic; the issue-to-PR pipeline on top of it is per-ecosystem.

## Installation

Add the marketplace in Claude Code:

```
/plugin marketplace add michaelhvisser/ai
```

Then install a plugin:

```
/plugin install workflow@michaelhvisser-ai
```

Most people want `workflow` plus the language plugin for their stack — for Node/TS repos that is `ts-workflow`.

## Plugins

### workflow

Language-agnostic PR and review workflow skills. No toolchain assumptions — it resolves the repo's lint / typecheck / test / build commands at runtime from `package.json`, `go.mod`, `Cargo.toml`, or a `Makefile`.

- **`/workflow:antagonist-review`** — cross-model adversarial review: a strong finder model and the local Codex CLI fight over every finding, a third model breaks ties, and a human settles only what the models can't
- **`/workflow:codex-ship`** — triage-gated Codex↔fix loop: judge every Codex connector finding (real vs. slop) with a second-opinion cross-check, fix only the confirmed-real set, and loop until Codex runs out of genuine value
- **`/workflow:commit`**, **`/workflow:create-pr`** — conventional commits and template-driven PRs
- **`/workflow:create-worktree`**, **`/workflow:remove-worktree`**, **`/workflow:prune-worktree`** — git worktree lifecycle for isolated issue work

`codex-ship` hands the fix pass and the merge to whichever language plugin matches the repo (`ts-workflow` for Node, `go-workflow` for Go), and falls back to an inline fix + plain push when none is installed.

### ts-workflow

Issue-to-PR workflow automation for TypeScript/JavaScript projects. Pairs with `workflow`, which supplies its commit, PR, worktree, and review skills.

- **`/ts-workflow:start-issue`** — pick up a GitHub issue: worktree, plan, orchestrated multi-agent TDD implementation (explore → implement → spec review → quality review)
- **`/ts-workflow:complete-issue`** — end-to-end loop from issue to merged PR
- **`/ts-workflow:ship`** — verify locally, push, open PR, watch CI and review bots, merge
- **`/ts-workflow:review-deep`** — deep review of a PR or branch with issue context; fixes and commits actionable findings
- **`/ts-workflow:address-review`** — fetch human/bot review feedback and resolve it in a fix loop
- **`/ts-workflow:e2e-verify`** — browser-based end-to-end verification of a PR against the dev stack
- **`/ts-workflow:tmux-start`** — the supporting cast

Works with any Node repo. Detects your package manager (pnpm / npm / yarn / bun), monorepo tooling (Turborepo / Nx / workspaces), and test runner (vitest / jest / Playwright), with framework-aware guidance for Next.js (App Router, React 19), Astro, and Convex.

### slack-triage

Turn reaction-flagged Slack feedback into researched GitHub issues on a Projects v2 board.

- **`/slack-triage:triage-slack`** — read the messages your team flagged with an emoji, research each one against the codebase, and file the ones that survive as properly-evidenced issues with board status and priority set

React with `:ticket:` and the message becomes a candidate; the tool adds a done reaction and replies in-thread with the issue link, so Slack itself records what has been processed and re-running is always safe. Because that reaction is a deliberate human decision, filing straight into an active board state is safe for workflows that would otherwise require manual triage — and a report the research pass can't substantiate is filed as `Blocked` with the missing context instead of being handed to an agent as a spec.

One Slack app and one bot token serve every repo; onboarding another is a `slack-triage.json`. Issue creation goes over REST and board writes honour a configurable GraphQL reserve, because that quota is per-user and shared across every repo on the account.

## Credits

`ts-workflow` — and the `workflow` skills factored out of it — began as a fork of [go-workflow](https://github.com/gopherguides/gopher-ai) by Gopher Guides (MIT), adapted for the TypeScript/JavaScript ecosystem. If you write Go, the original is excellent and pairs with `workflow` the same way.

## License

[MIT](./LICENSE)
