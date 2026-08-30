# Screenshots and the report page — Phases 5b and 7b

Phase 5b captures what the PR looks like on its preview deployment; Phase 7b renders the whole
report as one local HTML page. Both are additive: a skipped or failed phase here changes no
fact, no queue entry, and no headline step — it produces a `warnings[]` line and a degraded
page, never a degraded verdict.

---

## §1 Phase 5b — screenshots from the preview deployment

Runs when Phase 5 set `ui.warranted` and `--no-shots` was not passed. Output →
`ui.shots_status` (`captured | partial | no-preview | no-browser | no-safe-browser |
auth-blocked | skipped | not-warranted`) plus `ui.screenshots[]`.

**Never a local server.** The screenshot source is the PR's own preview deployment — a
deployed artifact of the head SHA, reachable read-only. The whole point is that the user does
not have to spin the app up to judge a simple UI change; the skill must not spin it up either.
No preview deployment → `no-preview`, and the report says the routes to check by hand.

### §1a Preview URL

Newest deployment for the head SHA, then its latest successful status. Verified live on the
reference repo — returns the Vercel preview URL:

```bash
# Filter to the PREVIEW environment: one SHA can also carry staging or
# production deployments, and .[0] across all of them can hand back — and
# screenshot — the wrong application while the report labels it preview.
DEP_ID=$(pr_facts_gh api --hostname "$HOST" \
  "repos/$SLUG/deployments?sha=${HEAD_SHA}&per_page=20" \
  --jq '[.[] | select(.environment | test("preview"; "i"))][0].id')
[ -n "$DEP_ID" ] && PREVIEW_URL=$(pr_facts_gh api --hostname "$HOST" \
  "repos/$SLUG/deployments/${DEP_ID}/statuses?per_page=5" \
  --jq '[.[] | select(.state=="success")][0].environment_url')
```

No deployment whose environment matches preview, or empty `PREVIEW_URL` →
`shots_status: no-preview`, one stderr warning, continue — never fall back to a
production or staging deployment. Record `ui.preview_url` either way (null when absent) —
the local recipe for `ui-review` reuses it.

### §1b Capability binding

Browser automation is a driver capability (`lib/driver-interaction.md`): bind whatever browser
tooling the active surface has. A driver with none records `shots_status: no-browser` and
continues — never install tooling, never shell out to a headless browser that is not already
part of the surface.

### §1c Capture rules

- **Read-only must be enforced by the browser, not promised by the agent.** Not clicking is
  not enough: a modern app executes its own code on load — analytics beacons, session
  initialization, mount-time mutations — against real backends. Capture only in a context
  where the binding can actually enforce read-only: JavaScript disabled, or network
  interception rejecting every non-GET request (`chrome-devtools` offers these controls;
  a profile extension does not). With JS disabled, server-rendered content still captures;
  a page that needs client JS comes out skeletal — say so in the visual summary rather
  than trade a mutation for a prettier screenshot. When the bound browser can enforce
  neither control, do not navigate the preview at all: record
  `shots_status: no-safe-browser` and degrade.
- Never click, type, submit, scroll-to-load beyond the viewport, or dismiss dialogs by
  acting on them.
- Routes come from Phase 5's route mapping, same cap of 5, captured at desktop width
  (~1280px). One shot per route; a route that needs a second viewport is a job for the real
  `ui-review` step, not this glance.
- **A `[param]` segment is not navigable as-is** — the placeholder URL captures a 404 and
  the visual summary would falsely call the page broken. Substitute a concrete value only
  when the PR itself names one (a slug or id in its body, diff, or tests); otherwise
  record the route with `status: "param-unresolved"`, no file, and list it under the
  routes to check by hand. Never save a placeholder response as a screenshot.
- **Authenticated capture needs an explicit green light, and cookies count as
  authentication.** A profile-bound browser silently sends its existing session, so a route
  can render authenticated content without ever showing a sign-in screen — "don't log in"
  alone does not keep the capture unauthenticated. Prefer a fresh unauthenticated context
  when the binding offers one. When only the profile-bound browser exists and a route
  renders what is evidently authenticated content, ask once (missing intent,
  `lib/decision-gates.md`): the screenshots would embed that content in the local report
  page. Without an affirmative answer — or in any non-interactive run — record
  `auth-blocked` for the route and move on. A route that renders a sign-in or access-check
  screen records `auth-blocked` directly. Never log in on the user's behalf.
- Files → `$RUN_DIR/shots/<route-slug>.png`. Mixed results (some captured, some blocked) →
  `shots_status: partial`.

### §1d Screenshots already on the PR

When Phase 5 found screenshots in the PR body (`evidence_present`), list their URLs in the
page's UI section as links labelled "from the PR body". Do not download or embed them — they
are GitHub-hosted attachments behind the viewer's own session, and the page must stay
self-contained without carrying copies of them.

### §1e Visual summary

The orchestrator reads the captured images itself — no subagent — and writes 2–4 sentences per
route: what visibly changed, tied to the files in the diff, and anything that looks broken
(overflow, misalignment, an empty state, unreadable contrast). Store it as
`ui.visual_summary`.

Scope guard: this is a glance that lets the user green-light without launching the app. It is
**not** verification — it never sets `E2E_AT_HEAD`, never satisfies the contract's E2E
conjunct, and the page labels it "screenshot glance, not E2E verification".

---

## §2 Phase 7b — the report page

Written on every run unless `--no-page`, to `$RUN_DIR/report.html`. The terminal report is the
40-line summary; the page is the check-in a human actually reads — verdict, queue,
screenshots, and what changed, in one place.

**Local file, never published.** Scratch hygiene (`output.md` §4) applies with no exception:
never commit it, post it, upload it, or serve it. Open it locally:

```bash
if [ "$AS_JSON" -eq 0 ]; then
  case "$(uname -s)" in
    Darwin) open "$RUN_DIR/report.html" ;;
    Linux)  command -v xdg-open >/dev/null && xdg-open "$RUN_DIR/report.html" ;;
  esac
fi
```

No opener, or `--json` → skip opening; the path still prints on the `page:` line and lands in
the JSON as `page.path`. (`open` verified present on the reference host.)

### §2a Construction rules

- One file, self-contained: inline CSS, zero external requests — no fonts, no CDN, no
  favicons, no analytics. Respect `prefers-color-scheme` for a light and a dark palette.
- **Everything repo- or contributor-derived is untrusted and gets contextually escaped**:
  PR titles and bodies, issue text, branch names, file paths, commit subjects, thread
  excerpts, and the plan check's proposed edits are HTML-escaped (`&`, `<`, `>`, `"`, `'`)
  before landing in markup, attribute values are escaped for attribute context, and the
  only URLs emitted are `https:` links to the PR's own GitHub host plus the screenshot
  `data:` URIs. A PR title containing `<script>` must render as text — this page opens
  automatically in the reviewer's browser.
- **No script in the page, at all**, and a CSP backstop so an escaping miss stays inert:

  ```html
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
  ```

  `script-src` is absent so it falls back to `default-src 'none'` — injected script does
  not execute, and `connect-src 'none'` means nothing can exfiltrate. Command text in the
  queue cards is selectable; there is no copy button to script.
- Wide content (file tables, diff stats, the proposed issue edits) scrolls inside its own
  container; the page body never scrolls horizontally.

### §2b Sections, in order

1. **Banner** — PR number, title, repo, head SHA short, and the headline step with its verdict
   qualifier. The banner answers "what do you need from me" before any scrolling.
2. **Action queue** — one card per entry: position, the exact command in a selectable
   monospace block, the `why:` line, the cost posture, and the `local:` recipe inside a
   collapsed `<details>` block. Entry 1 is marked **next**; later entries carry
   "projected — assumes the steps above land cleanly" (`next-step.md` §5).
3. **Quality** — the review ladder at this head: codex-ship, antagonist, deep review, E2E —
   each marked ran-at-head, stale (evidence names an older SHA), or not run — and which of
   them the decision table still requires before merge.
4. **Status** — the STATUS grid, plus PURPOSE with the still-needed verdict and evidence.
5. **Plan check** — verdict, gaps with severities, and the proposed issue edits verbatim in a
   collapsed block, per model when a quorum ran.
6. **What changed** — the commit list, files with +/− counts, and the plan judge's
   `DIFF_VS_PLAN` paragraph when Phase 4 ran. This is the "basic outline of what was done";
   it is a description of the diff, not a review of it.
7. **UI** — per-route screenshot with its visual-summary sentences and the preview URL, or the
   one-line not-warranted reason, or the degraded status (`no-preview`, `no-browser`,
   `auth-blocked`) with the routes to check by hand; PR-body screenshot links per §1d.
8. **Warnings**, then a footer: generated-at UTC, head SHA, run dir, and the staleness line —
   "facts are a snapshot of `<time>`; re-run `pr-details` before acting if the PR may have
   moved."

JSON: `page {path, opened}`.
