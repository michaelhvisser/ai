# Writing for agents — the authoring standard for this repo

Read this before creating or editing any document an agent consumes: a SKILL.md, a
`lib/*.md` reference, an `AGENTS.md`. The packaging differs; the writing does not — the
same levers make each one predictable, because the goal is that the agent takes the same
*process* every run, not that it produces the same output.

Adapted from `writing-for-agents` in
[mattpocock/skills](https://github.com/mattpocock/skills) (MIT), with this repo's own
mechanics appended.

## Context pointers

A **context pointer** is a reference held in the agent's context that names out-of-context
material and encodes the condition for reaching it. A skill's `description:` is one; a
line in `AGENTS.md` naming a doc is the same object. The pointer's *wording*, not its
target, decides when the agent reaches the material. A must-have target behind a weakly
worded pointer is a variance bug: sharpen the wording first; inline the material only if
sharpening fails.

A pointer does two jobs: state what the material is, and list the **branches** that
trigger reaching it. Every word of an always-loaded pointer costs on every turn, so:

- **Front-load the trigger words** — the pointer is where they do their work.
- **One trigger per branch.** Synonyms renaming one branch are that branch written twice.
- **Cut identity the body already carries.**

## The two loads

Every document and pointer spends one of two budgets:

- **Context load** — always-loaded material's cost on the agent's window: a description,
  an `AGENTS.md` line, spending tokens whether or not it fires.
- **Cognitive load** — the human's cost: knowing which documents exist and when to reach
  for each. Not a cost to minimise to zero — it is the price of human agency. Spend it
  where human judgement matters; remove it where it does not.

Material behind a pointer escapes context load at the price of the pointer's line;
material with no pointer rides entirely on cognitive load.

## Information hierarchy

Documents are built from **steps** (ordered actions) and **reference** (rules, facts,
definitions consulted on demand). Place each piece on a ladder ranked by how immediately
the agent needs it:

1. **In-file step** — what the agent does, in order. The primary tier.
2. **In-file reference** — consulted on demand. A legitimately flat peer-set (every rule
   of a review on one rung) is a fine arrangement, not a smell.
3. **Disclosed reference** — a separate file behind a context pointer, loaded only when
   the pointer fires. `pr-details`' five sub-files are the house example.

**Progressive disclosure** is the move down the ladder so the top stays legible. The
cleanest test is branching: inline what every branch needs; push behind a pointer what
only some branches reach. When a document has steps, in-file reference that should have
been disclosed buries them — a variance lever, not just a legibility one.

**Co-location** decides what sits *beside* a piece once placed: keep a concept's
definition, rules, and caveats under one heading rather than scattered. The test: the
document should read like documentation written for the agent.

**Sprawl** is the failure mode: a document too long even when every line is live.
Attention thins across the excess. The cure is the ladder, not deletion for its own sake.

## Steps and completion criteria

Every step ends on a **completion criterion** — the condition that tells the agent the
work is done. Two properties make it a lever:

- **Clarity**: can the agent tell done from not-done? A vague bound ("understanding
  reached") invites premature completion, with the visible later steps supplying the pull.
  Sharpen the bound first; only if it is irreducibly fuzzy *and* you observe the rush,
  hide the later steps behind a real context boundary (a subagent dispatch — an inline
  call hides nothing).
- **Demand**: how much the criterion requires. "Every modified file accounted for" forces
  legwork where "produce a change list" does not. Demand is not step-bound: "every rule
  applied" binds a flat reference body just as "every step done" binds a sequence.

The strongest criteria are both checkable and exhaustive. House example:
`resolve-conflicts` completes on "every vanished hunk accounted for", not "the rebase
continued to the end".

## When to split

Splitting one document into two spends one of the two loads, so split only when the cut
earns it: split a run of steps where the later steps tempt the agent to rush the current
one; split reference by branch so each path carries only what it needs. Beware the
reverse merge — it re-exposes each step to what follows it.

## House mechanics

The rules above are general; these are this repo's, and they are load-bearing:

- **Frontmatter**: `name`, `description` (double-quoted), optional `argument-hint`.
  Model-invocable descriptions carry trigger clauses — "Use when …" naming genuinely
  distinct branches, "SKIP when …" naming the adjacent skill to use instead. Skills that
  only a human should start set `disable-model-invocation: true` and strip the trigger
  clauses: a pointer that must never fire should not spend words on firing conditions.
- **`${CLAUDE_PLUGIN_ROOT}` is per-plugin.** Shared libs are copied between plugins,
  never referenced across them — `../other-plugin` resolves into the versioned cache.
  Material a dispatched subagent or another plugin's fixer needs travels by paste: the
  dispatching skill carries the file's full text in the prompt (see `fix-at-the-root.md`).
- **Every embedded shell block must be zsh-safe**: UPPERCASE or prefixed variables (zsh
  ties lowercase `path`, `status`, `cdpath` to shell state), braces around
  colon-adjacent expansions, no bare `=word` tokens.
- **Verify every recipe live before writing it into a SKILL.md.** Run the actual
  commands against a real or scratch repo; two of the first spec's `gh` commands did not
  run. A plausible-looking recipe that fails at runtime is worse than prose, because the
  agent trusts it over its own judgement.
- **And make the verification cumulative.** Every fenced ```bash block is syntax-checked
  under bash AND zsh by `plugins/workflow/tests/skill-blocks-syntax.test.sh` (blocks
  containing `<placeholder>` tokens are skipped — keep placeholders in that angle-bracket
  form). Load-bearing machinery gets scenario tests in `plugins/<p>/tests/*.test.sh` that
  extract and execute the doc's own block against scripted repos — the one-off scratch
  check that proved a recipe becomes a regression test, so a review round never has to
  re-discover it.
- **Decisions route through `lib/decision-gates.md` and `lib/driver-interaction.md`** —
  reference them near the top of any skill that can hit a decision, and classify each
  ask as driver-resolvable, missing-intent, or hard invariant rather than inventing an
  option menu.
