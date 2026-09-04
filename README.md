# michaelhvisser/ai

AI coding assistant plugins for shipping software — by [Michael Visser](https://michaelhvisser.com).

This is a [Claude Code](https://claude.ai/code) and Codex plugin marketplace: a curated collection of the workflows and skills I use daily, packaged so anyone can use them. The review, PR, and worktree machinery is language-agnostic; the issue-to-PR pipeline on top of it is per-ecosystem.

## Installation

Requires Git, `jq`, `curl`, and the Claude Code CLI, Codex CLI, or both. Codex must
support `codex plugin add` (verified with 0.153.3). These commands install plugins;
they do not install or sign in to the assistant applications.

### One script for Claude Code and Codex

```bash
git clone https://github.com/michaelhvisser/ai.git
cd ai
bash scripts/install-all.sh --with-gopher-ai
```

The installer detects installed CLIs and installs every supported plugin from
this repository and [Gopher AI](https://github.com/gopherguides/gopher-ai).
Omit `--with-gopher-ai` to install only this repository. Preview with `--dry-run`,
or select `--platform claude`, `--platform codex`, or `--platform both`.

| Source | Claude Code | Codex |
|--------|-------------|-------|
| michaelhvisser/ai | workflow, ts-workflow, slack-triage | workflow, ts-workflow |
| gopherguides/gopher-ai | go-workflow, go-dev, productivity, gopher-guides, llm-tools, go-web, tailwind | All listed except productivity |

`slack-triage` and Gopher AI's `productivity` currently have only Claude packaging.
The installer reads each platform's catalog, so it does not copy unsupported
commands into Codex's skills directory. Plugin-specific credentials and optional
tools still need their own setup; see each plugin's README.

New `michaelhvisser-ai` marketplace registrations use this checkout's absolute
path: keep the checkout. Existing registrations and installed plugins (including
disabled ones) are preserved. Gopher AI is registered from GitHub. Installations
are personal: Claude uses user scope, and Codex uses the active `CODEX_HOME`.
Rerunning installs missing plugins; it does **not** update existing plugins or
prune caches. A failed command stops the script with an error; completed installs
remain in place and can be skipped on the next run.

Start a new Codex session and run `/reload-plugins` in Claude Code after installing.
Verify from a terminal:

```bash
codex plugin list
claude plugin list
```

### Codex only (manual)

From this checkout:

```bash
codex plugin marketplace add "$PWD"
codex plugin add workflow@michaelhvisser-ai
codex plugin add ts-workflow@michaelhvisser-ai
```

In Codex, invoke skills with qualified names such as `$workflow:pr-details` and
`$ts-workflow:start-issue 42`. The catalog at `.agents/plugins/marketplace.json`
makes the plugins discoverable; the `plugin add` commands enable them. See the
[official plugin documentation](https://developers.openai.com/codex/plugins).

### Claude Code only (manual)

Run inside Claude Code:

```text
/plugin marketplace add michaelhvisser/ai
/plugin install workflow@michaelhvisser-ai
/plugin install ts-workflow@michaelhvisser-ai
/plugin install slack-triage@michaelhvisser-ai
```

### Updates

For a marketplace registered from a local checkout, first run `git pull --ff-only`
in that checkout. In Claude Code, update the marketplace, then each installed
plugin you want to update, and reload:

```text
/plugin marketplace update michaelhvisser-ai
/plugin update workflow@michaelhvisser-ai
/plugin update ts-workflow@michaelhvisser-ai
/plugin update slack-triage@michaelhvisser-ai
/reload-plugins
```

For Codex, close running Codex sessions before refreshing plugins, then run these
commands in a separate terminal and start a new session:

```bash
codex plugin add workflow@michaelhvisser-ai
codex plugin add ts-workflow@michaelhvisser-ai
```

If the marketplace was registered from GitHub instead of a local checkout, run
`codex plugin marketplace upgrade michaelhvisser-ai` before the `plugin add`
commands above. Local registrations read directly from the checkout.

For Gopher AI updates and migration from older flat-skill installations, use
[Cory's maintained installer](https://github.com/gopherguides/gopher-ai/blob/main/scripts/install-codex.sh)
(`bash scripts/install-codex.sh --user` from a Gopher AI checkout, with Codex
sessions closed). His [universal installer](https://github.com/gopherguides/gopher-ai/blob/main/scripts/install-all.sh)
also handles Gemini. Our installer targets Claude Code and Codex and handles
first-time marketplace registration as well as missing plugins.

## Plugins

### workflow

Language-agnostic PR and review workflow skills. No toolchain assumptions — it resolves the repo's lint / typecheck / test / build commands at runtime from `package.json`, `go.mod`, `Cargo.toml`, or a `Makefile`.

- **`/workflow:pr-details`** — read-only situation report for one PR with an approvable execution plan to merge-readiness
- **`/workflow:issue-details`** — read-only triage evaluation for issues: class, advisory duplicate verdict, goal alignment, proposed priority and effort, one marker comment per issue edited in place — posted only past the closing approval
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
