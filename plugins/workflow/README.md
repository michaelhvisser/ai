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
| `/workflow:pr-details [PR]` | Read-only situation report for one PR: CI against the base branch's real required checks, reviews, threads, mergeability, board state, whether the linked issue's problem still exists (checked against recently shipped and backlog work, so a superseded PR is named for closing), whether its plan is right, which review skill is still needed at this head — and the ordered execution plan to merge-readiness, approvable at the closing prompt for local execution or a Detent handoff, with a by-hand recipe per step and preview-deploy screenshots for UI changes |
| `/workflow:issue-details <n> [...] \| --since <n>d` | Read-only triage evaluation for one or more issues: class (bug / goal / idea / question / noise), an advisory duplicate verdict from a closed vocabulary (open issues, open PRs, PRs merged into the base branch since filing — at most one canonical, no invented numbers), goal alignment via `goal:*` labels and epic references, proposed board Priority and Detent effort tier (never `max`), the author-decides social rule — then one marker-backed comment per issue, edited in place on re-run, posted only past the closing approval |
| `/workflow:antagonist-review [PR]` | Cross-model adversarial review with quorum tie-breaks: a strong finder model finds defects, the local Codex CLI attacks every one, a third model breaks ties, and a human settles only what the models genuinely cannot — then Codex fixes the confirmed set and the loop re-reviews until clean |
| `/workflow:codex-ship [PR]` | Triage-gated Codex↔fix loop: judge every Codex connector finding (real vs. slop), corroborate with a local Codex CLI second opinion, fix only the confirmed-real set, and loop until Codex runs out of genuine value |
| `/workflow:resolve-conflicts` | Resolve an in-progress merge/rebase conflict hunk by hunk on intent, verify with the repo's own checks, and prove no reviewed change was silently dropped |
| `/workflow:commit` | Create a git commit with an auto-generated conventional message from staged changes |
| `/workflow:create-pr` | Open a pull request using the repo's PR template |
| `/workflow:create-worktree <number>` | Create (or reuse) a git worktree for a GitHub issue or PR |
| `/workflow:remove-worktree` | Interactively select and remove a git worktree |
| `/workflow:prune-worktree` | Batch cleanup of all completed issue and PR-review worktrees |

`commit`, `create-pr`, `worktree`, `pr-details`, `issue-details`, and
`resolve-conflicts` are also reachable in Codex as `$workflow:commit`,
`$workflow:create-pr`, `$workflow:worktree <action>`, `$workflow:pr-details`,
`$workflow:issue-details`, and `$workflow:resolve-conflicts`. Codex requires the qualified plugin name; bare
skill names are not resolver aliases.

## The Flow

The main loop for driving one PR to merge: run `pr-details`, run the one skill
it names, run `pr-details` again — until the answer is a terminal or
human-owned step. You never have to decide which review skill to spend tokens
on; the decision table decides, keyed on what already ran at the current head
SHA and how big the diff is.

You rarely need the table below by hand: `pr-details` closes with an approval
prompt offering to execute the whole plan locally (this session drives every
agent-executable step, re-checking between each — the same process the Detent
lane would run), hand the issue to Detent's board lane, run just the first
step, or stop at the report. The table is the same mapping, for when you drive
the loop yourself or from `--json`.

| `next_step.id` from `pr-details` | What to run |
|---|---|
| `rebase` | Rebase onto the base branch; if it stops on conflicts → `/workflow:resolve-conflicts` |
| `codex-ship` | `/workflow:codex-ship` |
| `antagonist-review` | `/workflow:antagonist-review` |
| `address-review` | Your language plugin's `address-review` (e.g. `/ts-workflow:address-review`) |
| `ui-review` | Your language plugin's browser/E2E verification (e.g. `/ts-workflow:e2e-verify`) |
| `fix-plan` | Apply the plan-check's proposed issue edits — a human action, on the issue |
| `complete-gate` | Complete the specific contract conjunct the report's `why:` line names — the local gate run, a deep review at the head SHA, a refreshed issue workpad — then re-run `pr-details`. The gate command alone clears it only when the gate was the missing conjunct |
| `wait-ci` | Nothing — CI is running |
| `hand-to-detent` / `human-approval` / `move-to-human-review` | Board or human owns the next move |
| `merged` / `closed` | Done |

Everything else in the vocabulary (`blocked`, `no-active-issue`,
`close-superseded`, `close-duplicate`, `board-terminal`, `facts-incomplete`,
`finish-draft`, `needs-human`) names a situation, not a skill — the report's
`why` line says what a human needs to settle.

**On-ramps** into the loop: `issue-details` to settle what an issue is, whether
it already exists or shipped, and how it ranks before anyone plans it;
`create-worktree` to pick up an issue or PR in an isolated worktree; then `commit`
and `create-pr` to get a PR into existence.

## Before the PR exists: `issue-details`

`issue-details` is the issue-side twin of `pr-details`, first cut — the
"first deliverable" of the issue-intake design. It reads one issue (or every
open issue filed in the last `n` days) and settles five things before anyone
spends tokens planning it: the **class** (`bug` only when the expected
behaviour is already defined somewhere citable; `noise` only on a mechanical
signal such as a `detent-intake` fingerprint or a build-output path), an
advisory **dedupe verdict** from a closed vocabulary (`needed`,
`likely-duplicate-of #N`, `already-fixed-by #N`, `unclear` — a number may only
be named if it appeared in a search result), the **goal** it serves (its own
`goal:*` label, else an epic it references that carries one — proposed, never
applied), and a proposed board **Priority** and Detent **effort** tier from the
repo's own rubric, never `max`. An existing `detent-agent` block is reported
beside the proposal, never overwritten. When the issue's author is not you, the
comment never proposes close or park, and a priority disagreement is a note to
them.

Its product is one marker-backed comment per issue — a fenced YAML block plus
cited prose — that a re-run finds by marker and edits in place. Nothing is
written before the closing approval, which asks once per run: post the
comments (plus `triage:needs-decision` where a decision is required), print
them, or stop. `--json` and non-interactive sessions mean print only. It
never changes board Status or Priority, never closes, never edits a body.

The mechanics are one script, `scripts/issue-details.sh` (`collect` →
judgement → `finalize` → `print` / `post`): every GitHub read, every per-issue
fact (held in `state-<n>.json`, never in shell variables between steps), the
guards, the comment render, the fail-closed pre-write refresh, and the
three-command write set. The orchestrator's only job between `collect` and
`finalize` is the judgement — class, verdict, priority, proposed effort —
written to `judgement-<n>.json`. `tests/issue-details-triage.test.sh` drives
the script end to end against a stubbed `gh`.

Deliberately out of scope in this version: planning, the pinned-read
still-needed check (a marked hook only), the antagonist review, and any sweep
or close logic.

## Where to Start: `pr-details`

`pr-details` is the front door of the review family. Every other review skill
here either mutates the PR (`address-review`, `codex-ship`) or spends a lot of
tokens (`antagonist-review`). `pr-details` does neither while it reports — `gh`
read verbs only; no push, comment, resolve, or board move — and its product is
an execution plan plus a decision about which expensive skill to reach for.
Mutation exists only past the closing approval, in the mode you pick there.

It reports:

- **Status** — CI evaluated against the base branch's *actual* required checks
  (from the branch ruleset, matched on `(context, integration_id)`, so a
  required check that never reported reads `pending`, not green), review
  decision and approval sufficiency, unresolved threads split by author class,
  mergeability and behind-count, and the linked **issue's** board state (never
  the PR's own stray board row).
- **Purpose** — whether the linked issue's problem still exists on the base
  branch, traced through pinned `git show`/`git grep` reads at the base and head
  SHAs, plus duplicate issues and PRs — and whether the fix is still the plan of
  record, judged against PRs merged since the merge-base (and the issues they
  closed) and backlog issues planning a rework of the same area, so a
  superseded or no-longer-needed PR is named for closing instead of polishing.
- **Plan** — a strong model audits whether the issue's plan is the right plan
  for its problem, and proposes issue-body edits as text. `--plan-model both`
  runs a two-family quorum; a split verdict is itself a signal.
- **UI** — whether the diff warrants visual review, which routes to look at,
  and — when a preview deployment exists — a screenshot glance of those routes
  with a short visual summary, so a simple UI change never forces you to launch
  the app.
- **Quality** — which of codex-ship, antagonist-review, deep review, and E2E
  already ran at this head SHA, and which the table still requires before merge.
- **Execution plan** — exactly one actual step from a thirty-row table
  evaluated top to bottom, then the projected path behind it (cap 5), each
  entry carrying the skill command and a by-hand `local:` recipe. The closing
  prompt can set the whole plan in motion — locally or via Detent.

The next-step vocabulary is closed, so callers can branch on it:
`merged`, `closed`, `facts-incomplete`, `board-terminal`, `blocked`,
`no-active-issue`, `close-superseded`, `close-duplicate`, `rebase`,
`address-review`, `codex-ship`, `fix-plan`, `antagonist-review`, `wait-ci`,
`ui-review`, `finish-draft`, `complete-gate`, `human-approval`,
`move-to-human-review`, `hand-to-detent`, `needs-human`. There is no "optional"
outcome — a weaker secondary suggestion goes in `then[]` or `notes[]`.

`--json` puts the whole fact set on stdout (schema 4 — adds `pr.transport`,
`status.threads.resolution_known`, `issues[].board.source` and `snapshot_age_s`;
every schema-3 field is unchanged) with every diagnostic on stderr; the same object is written to the
run directory as `facts.json` on every run. Nothing consumes it yet — siblings may later, to share one `HEAD_SHA` pin
across a session instead of each re-deriving the PR number, base, linked issue,
bot logins, and thread state.

Exit codes are `0` for any report produced (**including a `blocked` verdict**),
`2` usage, `3` auth or rate-limit refusal, `4` PR not found.

`lib/pr-facts.sh` carries the read-only fact recipes it uses — a retry wrapper,
the three-bucket rate gate, repo identity from the git remote, the PR / files /
diff / issue records on REST in the `gh --json` shapes, issue-timeline links, the
derived review decision, ruleset aggregation, the check matrix that preserves
`app_id`, the CI-state materializer, REST review threads, the board row from
Detent's local snapshot, the shipped sweep from local git, closed issues, compare,
and shared-file duplicate detection. Exactly two functions speak GraphQL —
paginated review threads (for resolution state) and Projects v2 lookups — and
both are fallbacks the skill reaches only when REST or the snapshot cannot
answer, because GraphQL's secondary limit is invisible to `rate_limit` and shared
with the Detent fleet. Source it alongside `lib/github-rest.sh`.

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
