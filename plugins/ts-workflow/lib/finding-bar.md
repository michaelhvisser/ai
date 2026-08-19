# The finding bar — shared triage criteria for review findings

Read this before finding, judging, attacking, or filtering any review finding, in any skill.
It is the single source of truth for what counts as a finding; `antagonist-review` (finder,
attacker, juror roles) and `codex-ship` (judge, second-opinion roles) all hold every finding
to this bar, so a defect class dismissed at one gate cannot re-enter through the next.

The review's product is a **shippable PR, not new work items**. The costliest outputs are not
missed defects — they are plausible-but-wrong findings that survive to the human, and
out-of-scope observations that turn into backlog.

## Bar for entry — a finding must clear ALL four

1. **Introduced here.** The defect is created or materially worsened by this diff. A defect
   that already exists on the base branch is not a finding, no matter how real — dismiss on
   sight, reason `pre-existing`, no debate.
2. **Fixable here.** The minimal correct fix lands inside this PR's blast radius. If fixing
   it means changing a shared component other surfaces depend on, migrating persisted data,
   or redesigning something the PR merely touches, it is repo-level work, not a finding.
3. **Self-refuted first.** Before asserting the finding, try to kill it: read the implicated
   code as it actually exists (not just the hunk) — upstream guards, validators, sanitizers,
   callers, tests. If the claim is cheaply checkable (a normalizer, a regex, a validator,
   state that may already be live), **check it** rather than speculate; and a claim that
   something is *missing* requires verifying present state, not pattern-matching its absence
   from the hunk.
4. **Traced.** A concrete failure scenario: specific input or state → specific wrong outcome,
   at file:line. "Could be a problem if…" without the trace is not a finding.

## Never-findings — excluded by name, regardless of any confidence score

- DoS, resource exhaustion, or missing rate limiting
- Missing input validation on non-security-critical fields without a demonstrated consequence
- Theoretical attacks with no traced reachable path
- Pedantic style/naming/structure nits; general quality opinions the repo's guidelines
  don't demand
- Code under an explicit lint-ignore/suppression comment
- Anything the repo's own gate (linter, compiler, tests) will catch on its own

## Mechanically-checkable claims defer to the tools

A finding in a class the toolchain decides (type errors, unused symbols, null flow, lint
rules) must be corroborated by actually running the relevant tool on the changed files. The
tool's verdict outranks model reasoning in **both** directions: uncorroborated, the finding
is dropped; corroborated, it needs no debate. Where a deterministic checker exists for a
claim class (e.g. semgrep for injection patterns), prefer running it over arguing.

## Burden of proof

The finding's sponsor carries it, always. A refutation grounded in read code beats a
confidence number. A `security`/`data-loss` **label** never elevates a finding by itself — a
traced failure path does, and an **executable repro** (a failing test, a script, a run
against real code) settles what debate cannot: a feasible repro that fails is strong evidence
for dismissal; one that succeeds usually ends the argument in confirmation.

## Known non-findings persist

The canonical home for durable dismissals is a **"Not a finding"** section in the repo's
AGENTS.md/CLAUDE.md; prior review ledgers count too. A new finding matching one auto-dismisses
with a pointer — unless the diff changed the facts the note rests on. The same ghost must
never cost the human twice, in either skill.

## Out-of-scope observations die quietly

Never propose filing an issue, opening a follow-up, or "deferring" an out-of-scope or
pre-existing observation — deferred work is backlog. Dismiss it with its reason on the
record; deferral exists only if the human proposes it themselves, unprompted.
