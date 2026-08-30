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
