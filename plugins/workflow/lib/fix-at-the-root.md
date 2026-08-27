# Fix at the root — class fixes over instance patches

Read this before any fix pass that acts on confirmed-real review findings. Like
`finding-bar.md`, it travels by paste: a dispatched fixer may run in another plugin or a
subagent and cannot resolve this plugin's path, so the dispatching skill must carry this
file's full text in the fixer prompt.

A review finding arrives as an **instance**: a defect at file:line. Most defects are
instances of a **class**: a general property this change violates, which the reported
line merely happens to exhibit. Patching only the reported line is how a fix pass
manufactures its own next round of findings — the sibling instances are still in the
diff, and the next review (bot or human) surfaces them one at a time.

## The ladder — climb as far as scope allows, never further

For each confirmed-real finding, in order:

1. **Fix the instance.** The reported defect at the reported site. The non-negotiable
   floor — rungs 2 and 3 never replace it.
2. **Sweep for siblings.** State the class in one line (the property violated, plus a
   greppable signature), then sweep **this PR's diff** for other sites with the same
   defect. Fix each sibling that is condemned by the same evidence as the original — a
   traced failure at that site, not visual resemblance. A lookalike that is actually
   guarded upstream, or differs in the fact that matters, is not a sibling; leave it.
3. **Fix the origin.** When the instances share a mechanical origin, fix the origin so
   the class cannot recur inside this PR:
   - copy-paste divergence → extract the shared shape; call it from every site
   - the same `switch`/`if`-cascade repeated on the same type → one map or dispatch
     every site shares
   - the same field-bundle passed around and mishandled → one type, constructed once,
     validated where it is built
   - a wrong value flowing to many consumers → fix where it is **produced**, never at
     each consumption site
   - a missing guard repeated at N call sites → guard once, where the data enters

   (Origin patterns adapted from Fowler's code smells, *Refactoring* ch. 3.)

## Scope guardrails — the finding bar still binds every rung

- **Blast radius caps the ladder** (bar rule 2, "fixable here"). The sweep is confined
  to this PR's diff, and an origin fix must land inside this PR's blast radius. If
  fixing the origin means changing a shared component other surfaces depend on,
  migrating data, or a redesign the PR merely touches, stop at rung 2 and record why:
  `root_fix: none (out of blast radius)`.
- **Pre-existing siblings are not findings** (bar rule 1, "introduced here"). A sibling
  already on the base branch is left alone — not fixed, not filed as follow-up, per the
  bar's "out-of-scope observations die quietly". If the *origin* of an introduced
  defect is itself pre-existing (a footgun API this diff merely called), the in-PR fix
  stands and the origin stays.
- **Every sibling fix must be traced** (bar rule 4). "Same shape as the bug" is not
  evidence. A class fix that touches non-defective lookalikes is scope creep wearing a
  root-cause costume — the diff grows only at sites with traced failures, plus the
  minimal shared mechanism of a rung-3 fix.
- **Rung 3 is a judgement call, never mandatory.** Two instances do not automatically
  deserve an abstraction. Extracting one is the same call as Fowler's duplicated-code
  smell: when the shared shape is real, name it and call it from both; when it isn't,
  two plain fixes beat one speculative helper (that's his speculative-generality smell
  pointing the other way).

## Record what the ladder did

For each finding fixed, the fix record (ledger, commit message, or report) carries:

- `class:` the one-line class statement
- `siblings_fixed:` count — 0 is a fine answer; state it, don't omit it
- `root_fix:` what changed at the origin, or `none (<reason>)`

A fixer that cannot state a finding's class has not understood the defect yet — that is
the moment to re-read the code, not to patch the line and move on.
