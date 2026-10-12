# Adopt the shared work method

Install `workflow@michaelhvisser-ai` alongside the repository's language tools.
The three common skills are available as `$workflow:plan-work`,
`$workflow:safety-proof`, and `$workflow:verify-feature` in Codex, or the same
qualified names with a leading slash in Claude Code. Refresh the plugin and
start a new session after the release; existing sessions retain their original
versioned skill paths.

Adding a plugin does not rewrite a repository's explicit skill calls. A Go
repository can retain go-workflow review and ship while adding these hooks to
its WORKFLOW.md:

- In plan-only dispatch, run plan-work with the admitted issue context and
  return its handoff in the coordinator's plan format. Do not implement,
  publish, or change state from this planning skill.
- In implementation, carry the plan's applicable work method into the existing
  implementation/fixer brief. Require executed bug reproduction and relevant
  safety checks; run safety-proof for consequential assumptions that still lack
  evidence. Resolve test commands and wrappers from repository instructions.
- In verification, use verify-feature when an affected runtime path needs a
  maintained recipe. Reuse existing browser/test tools and evidence manifests.
  Do not replace ordinary regression tests or mandatory screenshot attachment.
- Before delivery, resolve effective repository and host policy. Local-only
  worker validation replaces CI polling; required change-specific checks and
  human approval remain mandatory.

Keep the canonical workpad and coordinator readiness fields. Add criterion,
method, exact head, command/artifact, observed result, and pass/fail/blocked/gap
outcomes there. Keep selected/rejected design rationale and unresolved
assumptions in that record instead of adding another status system.

The shared references live in workflow/lib and are copied into the TypeScript
plugin at release packaging. A dispatched Go fixer receives relevant text in
its prompt. Other plugins cannot resolve another plugin's versioned cache path.
Installing this release does not patch Gopher AI's independent ship/E2E skills;
the repository's policy must explicitly govern their CI and delivery behavior.

This method grants no new external-action, delegation, merge, or release
authority and makes no model/effort override. Fix contradictory isolation or
test-organization instructions in the repository that owns them.
