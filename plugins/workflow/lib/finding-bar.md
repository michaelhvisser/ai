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

## The target repo's declared context bounds the bar

When the repository under review declares a supported operating context (a "Supported
context" section in AGENTS.md/CLAUDE.md, or wherever its reviewer guidance lives), a
finding about behavior outside that context is dismissed with reason `out-of-context` and
a pointer — the same mechanism as a "Not a finding" entry. Two exceptions keep this
honest: a finding that shows a boundary **guard failing to refuse** is in scope (the
refusal is the supported behavior), and a diff that **moves the boundary** re-opens
whatever it moved. Absent any declaration, this section changes nothing.

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

## Known non-findings persist — but almost none qualify

Durable dismissals live wherever the repo keeps its reviewer guidance: a **"Not a finding"**
section in AGENTS.md/CLAUDE.md, or a review-scoped file those point at. Prior review ledgers
count too, as do the dismissal rows of an earlier review comment on the same PR. A new finding
matching one auto-dismisses with a pointer — unless the diff changed the facts the note rests
on. The same ghost must never cost the human twice, in either skill.

**Most dismissals are not eligible for persistence.** A dismissal qualifies only when all three
hold:

1. **Class-level, not line-level.** It states a standing by-design behavior ("we intentionally
   X"), not a verdict about specific lines in one diff. A line-scoped dismissal can only recur
   if a later PR touches those lines — and then the diff *is* the changed fact, so the note is
   suspended for re-verification anyway. It buys nothing.
2. **Premise-stable.** Its premise cannot be quietly falsified from elsewhere in the repo. A
   premise that is a *global* property ("no code path does X") fails this test: it can go false
   without anyone touching the noted lines, and the note would keep auto-dismissing a defect
   that has since become real. Record the premise and the date in the note itself, so the
   "facts changed" check has something concrete to check.
3. **Not conceded or withdrawn.** A finding whose own sponsor withdrew it — or that was
   dismissed as pre-existing or out-of-scope — is a resolved argument, not a recurring ghost.

Persisting an ineligible dismissal is a defect in the review, not diligence. Instruction files
load into every unrelated session, so each note is a standing attention cost; and a note whose
premise has gone stale is an instruction to ignore a real bug.

## Out-of-scope observations die quietly

Never propose filing an issue, opening a follow-up, or "deferring" an out-of-scope or
pre-existing observation — deferred work is backlog. Dismiss it with its reason on the
record; deferral exists only if the human proposes it themselves, unprompted.
