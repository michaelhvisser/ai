# Bot logins — author classification

Maps a GitHub login to an author class for read-only reporting. This is the
**classification** half of ts-workflow's `address-review/bot-registry.md` only;
re-review triggers and approval signals stay there. Keep the two login lists in
sync when a new review bot shows up.

| Login (match rule) | Class |
|---|---|
| `chatgpt-codex-connector*` (`startswith`) | `codex-bot` |
| `coderabbitai[bot]` | `review-bot` |
| `greptileai` | `review-bot` |
| `copilot-pull-request-review[bot]` | `review-bot` |
| `claude[bot]` | `review-bot` |
| `github-actions[bot]`, `dependabot[bot]`, `renovate[bot]`, `netlify[bot]`, `vercel[bot]` | `ci-bot` (ignore for review state) |
| any other `__typename: Bot` | `other-bot` |
| `__typename: User` | `human` (then subdivide by body markers — see `pr-details/facts.md`) |
| `null` author (deleted account) | `human/unknown` |

Note the REST/GraphQL difference: REST logins carry the `[bot]` suffix; GraphQL
`login` on a `Bot` node does **not** — match on the bare name and on `__typename`.
