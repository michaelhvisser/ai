# Screenshots — Phase 5b

Phase 5b captures what the PR looks like on its preview deployment, so the user can judge a
simple UI change without launching the app. It is additive: a skipped or failed capture
changes no fact, no queue entry, and no headline step — it produces a `warnings[]` line and a
degraded UI section, never a degraded verdict.

Captures land in `$RUN_DIR/shots/`; the terminal report's `UI REVIEW` section lists each
file path with its visual-summary sentences (§1e). There is no rendered page — the paths and
the summary are the deliverable.

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
  --jq '[.[] | select(.environment | test("preview"; "i"))][0].id // empty')
[ -n "$DEP_ID" ] && PREVIEW_URL=$(pr_facts_gh api --hostname "$HOST" \
  "repos/$SLUG/deployments/${DEP_ID}/statuses?per_page=5" \
  --jq '[.[] | select(.state=="success")][0].environment_url // empty')
# `// empty` on both selectors: a no-match [0] yields the LITERAL "null",
# which passes [ -n ] and turns the next call into deployments/null/statuses.
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
  interception rejecting every non-GET request **and all WebSocket traffic** — the upgrade
  handshake is itself a GET, and the frames behind it carry mutations no method filter
  sees (`chrome-devtools` offers these controls; a profile extension does not). With JS disabled, server-rendered content still captures;
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
  `lib/decision-gates.md`): the screenshots would sit in the run directory as local files.
  Without an affirmative answer — or in any non-interactive run — record
  `auth-blocked` for the route and move on. A route that renders a sign-in or access-check
  screen records `auth-blocked` directly. Never log in on the user's behalf.
- Files → `$RUN_DIR/shots/<route-slug>.png`. Mixed results (some captured, some blocked) →
  `shots_status: partial`.

### §1d Screenshots already on the PR

When Phase 5 found screenshots in the PR body (`evidence_present`), list their URLs in the
terminal report's UI section, labelled "from the PR body". Do not download them — they are
GitHub-hosted attachments behind the viewer's own session; the link is enough.

### §1e Visual summary

The orchestrator reads the captured images itself — no subagent — and writes 2–4 sentences per
route: what visibly changed, tied to the files in the diff, and anything that looks broken
(overflow, misalignment, an empty state, unreadable contrast). Store it as
`ui.visual_summary` and print it under `UI REVIEW`, one indented block per route, after that
route's shot path.

Scope guard: this is a glance that lets the user green-light without launching the app. It is
**not** verification — it never sets `E2E_AT_HEAD`, never satisfies the contract's E2E
conjunct, and the report labels it "screenshot glance, not E2E verification".
