# workflow

Language-agnostic PR and review workflow skills: adversarial cross-model review,
Codex-driven ship loops, commits, PRs, and git worktree management.

Nothing here assumes a toolchain. The skills resolve the repo's lint / typecheck
/ test / build commands at runtime from whatever the project actually uses —
`package.json`, `go.mod`, `Cargo.toml`, or a `Makefile` — so the same review loop
runs on a Next.js app, a Go service, or a Rust crate.

## Installation

Add the marketplace, then install the plugin:

```bash
/plugin marketplace add michaelhvisser/ai
/plugin install workflow@michaelhvisser-ai
```

## Skills and Commands

| Claude Code invocation | Description |
|------------------------|-------------|
| `/workflow:pr-details [PR]` | Read-only situation report for one PR: CI against the base branch's real required checks, reviews, threads, mergeability, board state, whether the linked issue's problem still exists, whether its plan is right, and the single next step to take |
| `/workflow:antagonist-review [PR]` | Cross-model adversarial review with quorum tie-breaks: a strong finder model finds defects, the local Codex CLI attacks every one, a third model breaks ties, and a human settles only what the models genuinely cannot — then Codex fixes the confirmed set and the loop re-reviews until clean |
| `/workflow:codex-ship [PR]` | Triage-gated Codex↔fix loop: judge every Codex connector finding (real vs. slop), corroborate with a local Codex CLI second opinion, fix only the confirmed-real set, and loop until Codex runs out of genuine value |
| `/workflow:commit` | Create a git commit with an auto-generated conventional message from staged changes |
| `/workflow:create-pr` | Open a pull request using the repo's PR template |
| `/workflow:create-worktree <number>` | Create (or reuse) a git worktree for a GitHub issue or PR |
| `/workflow:remove-worktree` | Interactively select and remove a git worktree |
| `/workflow:prune-worktree` | Batch cleanup of all completed issue and PR-review worktrees |

`commit`, `create-pr`, `worktree`, and `pr-details` are also reachable in Codex
as `$workflow:commit`, `$workflow:create-pr`, `$workflow:worktree <action>`, and
`$workflow:pr-details`. Codex requires the qualified plugin name; bare skill
names are not resolver aliases.

## Where to Start: `pr-details`

`pr-details` is the front door of the review family. Every other review skill
here either mutates the PR (`address-review`, `codex-ship`) or spends a lot of
tokens (`antagonist-review`). `pr-details` does neither — it issues `gh` read
verbs only, never pushes, comments, resolves, or moves a board item, and its
product is a decision about which expensive skill to reach for.

It reports:

- **Status** — CI evaluated against the base branch's *actual* required checks
  (from the branch ruleset, matched on `(context, integration_id)`, so a
  required check that never reported reads `pending`, not green), review
  decision and approval sufficiency, unresolved threads split by author class,
  mergeability and behind-count, and the linked **issue's** board state (never
  the PR's own stray board row).
- **Purpose** — whether the linked issue's problem still exists on the base
  branch, traced through pinned `git show`/`git grep` reads at the base and head
  SHAs, plus duplicate issues and PRs.
- **Plan** — a strong model audits whether the issue's plan is the right plan
  for its problem, and proposes issue-body edits as text. `--plan-model both`
  runs a two-family quorum; a split verdict is itself a signal.
- **UI** — whether the diff warrants visual review, and which routes to look at.
- **Next step** — exactly one, from a thirty-row table evaluated top to bottom.

The next-step vocabulary is closed, so callers can branch on it:
`merged`, `closed`, `facts-incomplete`, `board-terminal`, `blocked`,
`no-active-issue`, `close-superseded`, `close-duplicate`, `rebase`,
`address-review`, `codex-ship`, `fix-plan`, `antagonist-review`, `wait-ci`,
`ui-review`, `finish-draft`, `complete-gate`, `human-approval`,
`move-to-human-review`, `hand-to-detent`, `needs-human`. There is no "optional"
outcome — a weaker secondary suggestion goes in `then[]` or `notes[]`.

`--json` puts the whole fact set on stdout (schema 1) with every diagnostic on
stderr; the same object is written to the run directory as `facts.json` on every
run. Nothing consumes it yet — siblings may later, to share one `HEAD_SHA` pin
across a session instead of each re-deriving the PR number, base, linked issue,
bot logins, and thread state.

Exit codes are `0` for any report produced (**including a `blocked` verdict**),
`2` usage, `3` auth or rate-limit refusal, `4` PR not found.

`lib/pr-facts.sh` carries the read-only fact recipes it uses — a retry wrapper,
a partial-GraphQL guard, the three-bucket rate gate, ruleset aggregation, the
check matrix that preserves `app_id`, the CI-state materializer, paginated
review threads, Projects v2 lookups, compare, and shared-file duplicate
detection. Source it alongside `lib/github-rest.sh`.

## Project Detection

`lib/detect-checks.sh` resolves the repo's verification commands before any skill
runs one. Source it and call `detect_checks`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/detect-checks.sh"
detect_checks           # or: detect_checks "$WORKTREE_PATH"
```

It sets `PROJECT_KIND` plus four command strings — **an empty string means that
check does not exist for this project**, which is a signal to ask the driver, not
to guess:

| Signal | `PROJECT_KIND` | `CHECK_LINT` | `CHECK_TYPECHECK` | `CHECK_TEST` | `CHECK_BUILD` |
|--------|----------------|--------------|-------------------|--------------|---------------|
| `package.json` | `node` | `<pm> run lint` | `<pm> run typecheck` / `type-check` / `check-types` | `<pm> run test` | `<pm> run build` |
| `go.mod` | `go` | `golangci-lint run` when on `PATH`, else `go vet ./...` | `go build ./...` | `go test ./...` | `go build ./...` |
| `Cargo.toml` | `rust` | `cargo clippy` | `cargo check` | `cargo test` | `cargo build` |
| `Makefile` only | `make` | `make lint` | `make typecheck` | `make test` | `make build` |
| none of the above | `unknown` | — | — | — | — |

Node projects only include a script that `package.json` actually declares, and
the package manager comes from the lockfile (`pnpm-lock.yaml` → `pnpm`,
`yarn.lock` → `yarn`, `bun.lock`/`bun.lockb` → `bun`, otherwise `npm`).
`PM`, `PMX`, and `IS_MONOREPO` are exported alongside for Node repos.

Any check the primary toolchain does not provide is **backfilled from a
same-named `Makefile` target** when one exists — so a Node repo whose `lint` lives
in a Makefile still gets a `CHECK_LINT`.

The helper is sourced into both bash and zsh, so every variable it defines is
uppercase or `DC_`-prefixed: zsh ties several lowercase names (`path`, `cdpath`,
`status`) to special shell state, and clobbering those from a sourced helper
breaks the caller's environment.

## Pairing with a Language Plugin

`codex-ship` dispatches two things this plugin deliberately does not own — the
fix pass (`address-review`) and the merge flow (`ship`) — because both are
language-specific. It resolves a `LANG_PLUGIN` from `PROJECT_KIND`:

| `PROJECT_KIND` | `LANG_PLUGIN` |
|----------------|---------------|
| `node` | [`ts-workflow`](../ts-workflow) |
| `go` | `go-workflow` |
| anything else | asks you which installed plugin provides them |

If no language plugin is installed, `codex-ship` does the fix pass inline with a
plain commit + push and hands the PR back to you instead of merging.

`ts-workflow` also **requires this plugin** alongside it: its `commit`,
`create-pr`, and worktree commands now live here.

## Requirements

- Git with worktree support
- GitHub CLI (`gh`) — authenticated
- `jq`
- Codex CLI (`codex`) — required by `antagonist-review` and `codex-ship`

## License

MIT - see [LICENSE](../../LICENSE)
