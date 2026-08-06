# michaelhvisser/ai

AI coding assistant plugins for TypeScript/JavaScript builders — by [Michael Visser](https://michaelhvisser.com).

This is a [Claude Code](https://claude.ai/code) plugin marketplace: a curated collection of the workflows and skills I use daily to ship Next.js, Astro, and Convex projects, packaged so any TS/JS builder can use them.

## Installation

Add the marketplace in Claude Code:

```
/plugin marketplace add michaelhvisser/ai
```

Then install a plugin:

```
/plugin install ts-workflow@michaelhvisser-ai
```

## Plugins

### ts-workflow

Issue-to-PR workflow automation with git worktree management for TypeScript/JavaScript projects.

- **`/ts-workflow:start-issue`** — pick up a GitHub issue: worktree, plan, orchestrated multi-agent TDD implementation (explore → implement → spec review → quality review)
- **`/ts-workflow:complete-issue`** — end-to-end loop from issue to merged PR
- **`/ts-workflow:ship`** — verify locally, push, open PR, watch CI and review bots, merge
- **`/ts-workflow:review-deep`** — deep review of a PR or branch with issue context; fixes and commits actionable findings
- **`/ts-workflow:address-review`** — fetch human/bot review feedback and resolve it in a fix loop
- **`/ts-workflow:codex-ship`** — triage-gated Codex↔fix loop: judge every Codex connector finding (real vs. slop) with a second-opinion cross-check, fix only the confirmed-real set, and loop until Codex runs out of genuine value
- **`/ts-workflow:antagonist-review`** — cross-model adversarial review: a strong finder model and the local Codex CLI fight over every finding, a third model breaks ties, and a human settles only what the models can't
- **`/ts-workflow:e2e-verify`** — browser-based end-to-end verification of a PR against the dev stack
- **`/ts-workflow:commit`**, **`/ts-workflow:create-pr`**, **`/ts-workflow:worktree`**, **`/ts-workflow:tmux-start`** — the supporting cast

Works with any Node repo. Detects your package manager (pnpm / npm / yarn / bun), monorepo tooling (Turborepo / Nx / workspaces), and test runner (vitest / jest / Playwright), with framework-aware guidance for Next.js (App Router, React 19), Astro, and Convex.

## Credits

`ts-workflow` is forked from [go-workflow](https://github.com/gopherguides/gopher-ai) by Gopher Guides (MIT) and adapted for the TypeScript/JavaScript ecosystem. If you write Go, go use the original — it's excellent.

## License

[MIT](./LICENSE)
