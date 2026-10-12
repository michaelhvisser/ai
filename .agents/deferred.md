# Deferred decisions

Agreed-to follow-ups that are deliberately not implemented yet, with the
trigger that would revive each. Distinct from rejected ideas: everything here
is wanted, just not yet load-bearing. (Agreed 2026-08-20 unless noted.)

- **`--facts <path>` handoff from `pr-details` to sibling skills.** pr-details
  already computes the full PR situation; sibling skills re-derive it. Revive
  when a second skill demonstrably re-fetches the same facts in one session.
- **A declared "ready to merge" checklist for non-Detent repos.** The merge
  gate currently encodes Detent's promotion rules. Revive when the first
  non-Detent consumer repo adopts the ship flow.
- **`pr-details` plan-check defaults to `fable`; the Codex leg keeps `gh`
  credentials.** Accepted risk, not an oversight. Revisit if Codex CLI gains
  a credential-scoping mechanism.
- **Zsh state-helper compatibility.** `plugins/ts-workflow/lib/loop-state.sh`
  declares a local `path` in `normalize_workflow_state_path`, which collides
  with Zsh's PATH-tied variable. The normalizer is byte-identical on baseline
  `b5541eb` and the shared-workflow change; `normalize_workflow_state_path '[]'`
  succeeds under Bash and fails under Zsh. Keep this pre-existing issue separate
  from policy wiring. Revive when hardening direct Zsh sourcing of the shared
  state helpers; add real Bash/Zsh state-update scenarios and synchronize helper
  copies. Use Bash when sourcing these helpers until compatibility is addressed. Recorded
  2026-10-12 during independent forward testing.
