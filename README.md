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

For Codex, run these commands in a separate terminal, then start a new session
to load the refreshed plugin versions:

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

### Update all installed Codex plugins automatically

Requires Node 22.18+ and a Codex CLI with `codex plugin` support. The updater
discovers installed plugins with `codex plugin list --json`, refreshes their Git
marketplaces once each, and loops over every installed plugin. There are no
hardcoded marketplace or plugin names. Disabled local plugins stay disabled.
Disabled account-managed plugins are reported and skipped because the CLI's
install operation enables them on the server and offers no disable command.
Plugins you have not installed are left alone, and missing release versions
are treated as unknown rather than blocking the update batch.

From this checkout:

```bash
node scripts/update-plugins.ts --dry-run
node scripts/update-plugins.ts
```

Individual failures do not prevent other plugins from updating. Failures produce
a nonzero exit status. If the CLI warns that remote inventory is incomplete,
the entire batch stops before any updates; fix authentication or retry when the
catalog is available. Local marketplaces use their current files; the updater
does not pull or switch branches in development checkouts. Remote plugins are
refreshed through the same CLI and may fail if account access or authentication
is required. New sessions load the updated versions. The native CLI can remove
old cache versions; an active session still using those files may need a restart.
After interruption, the updater restores a saved disabled preference directly
in the configuration before loading inventory. A missing or unrecognized config
stops the batch and retains the recovery record for repair.
Profiles with cached account-managed installations require ChatGPT authentication
for a complete inventory; signed-out or API-key authentication stops the batch.
Local-only profiles continue to work without ChatGPT authentication.
Unset `CODEX_API_KEY` and `OPENAI_API_KEY` for profiles with cached account-managed
plugins: plugin commands give those variables precedence over stored ChatGPT auth.

On macOS, install a daily LaunchAgent:

```bash
node scripts/update-plugins.ts --install-schedule
```

It runs immediately and every 24 hours while logged in. Keep this checkout and
the Node installation at their current paths. The job captures your current
`PATH` and `CODEX_HOME`; reinstall it if those change. Output and errors go to
`~/Library/Logs/michaelhvisser-ai/update-plugins.log`. On Linux, schedule the
ordinary updater command with your scheduler and set its `PATH` and `CODEX_HOME`.

To remove the macOS job:

```bash
node scripts/update-plugins.ts --remove-schedule
```

Overlapping updater runs are refused. Claims under
`$CODEX_HOME/.plugin-update-lock/` (default home `~/.codex`) identify each run
by PID and process start time. Interrupted runs leave claims that are removed
once their owner stops, including after reboot or PID reuse. A pending disabled
setting is saved before installation and recovered on the next run if restoration
was interrupted. Recovery failures stop the batch and remain in the log.
The updater's tests use a disposable `CODEX_HOME` and never change your plugins.

Claude Code has its own automatic updates: `/plugin` → Marketplaces → select a
marketplace → Enable auto-update.

## Plugins

### workflow

Language-agnostic PR and review workflow skills. No toolchain assumptions — it resolves the repo's lint / typecheck / test / build commands at runtime from `package.json`, `go.mod`, `Cargo.toml`, or a `Makefile`.

- **`/workflow:pr-details`** — read-only situation report for one PR with an approvable execution plan to merge-readiness
- **`/workflow:issue-details`** — read-only triage evaluation for issues: class, advisory duplicate verdict, goal alignment, proposed priority and effort, one marker comment per issue edited in place — posted only past the closing approval
- **`/workflow:split-issue`** — break a large Detent issue into independently reviewable children and wire their dependencies through the Detent MCP; `--plan-only` previews the split
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
