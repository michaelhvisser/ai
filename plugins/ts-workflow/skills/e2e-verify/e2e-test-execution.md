# Step 5: E2E Test Execution via Chrome DevTools MCP

This step performs browser-based E2E testing of web-facing changes. For
UI-visible diffs it is **mandatory and blocking** — failures stop the workflow
before any label, ship, or `VERIFIED` signal. It skips cleanly only when the
project has no web UI or the diff contains no UI-visible files.

**CRITICAL PRINCIPLE: Screenshots must be READ, not just captured.** A screenshot you don't look at is worthless. After every `take_screenshot`, you MUST read the image with your vision capabilities, describe what you see, and compare it against the spec/issue requirements. DOM-only checks (console errors, network requests) supplement visual verification — they do NOT substitute for it.

## 5a. Skip vs. Fail Decision

Skipping is allowed only when there is genuinely nothing to verify. If there
**is** something to verify but the tooling can't, that is a `fail`, not a
`skip`.

**Skip** (set `E2E_RESULT="skipped"` and continue to Step 6) when:

- The project has NO web components (none of the indicators below are present), AND
- No web-facing files were changed in the diff (both `WEB_CHANGES` and `HANDLER_CHANGES` empty), AND
- The issue/PR body contains no layout-sensitive keywords (see §5a.1).

**Fail** (set `E2E_RESULT="missing-browser-tooling"` and stop E2E) when the diff
IS UI-visible (see §5a.1) and:

- Chrome DevTools MCP tools are NOT available
  (neither `mcp__chrome-devtools__navigate_page` nor
  `mcp__chrome-devtools-mcp__navigate_page` is in the available tools list).

In every fail case, still proceed to Step 6 to post the failure comment so the
gate in `SKILL.md` Step 7 can stop the workflow.

**Web component indicators** (at least one must be true):
- A UI framework is declared in `package.json` dependencies (`next`, `astro`,
  `react`, `vue`, `svelte`, `@remix-run/*`, `nuxt`, `solid-js`)
- `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.astro`, or `*.html` files exist in
  the project
- Changed server files contain HTTP route patterns: an App Router
  `route.ts`/`route.js`, a `pages/api/` handler, `express()`/`app.get(`,
  `Hono`, `fastify`, or a Convex `httpAction`

**Web-facing change detection:**

```bash
if [ -z "$CHANGED_FILES" ]; then
  CHANGED_FILES=$(git -C "$WORKTREE_PATH" diff --name-only "${BASE_REMOTE}/${BASE_BRANCH}...HEAD")
fi
WEB_CHANGES=$(echo "$CHANGED_FILES" | grep -E '\.(tsx|jsx|vue|svelte|astro|html|mdx|css|scss)$' || true)
HANDLER_CHANGES=$(echo "$CHANGED_FILES" | grep -E '\.(ts|js|mts|cts|mjs|cjs)$' | while IFS= read -r f; do
  case "$f" in
    */route.ts|*/route.js|route.ts|route.js|*/pages/api/*|pages/api/*) echo "$f"; continue ;;
  esac
  grep -l -E 'export (async )?function (GET|POST|PUT|PATCH|DELETE)|NextResponse|NextRequest|express\(\)|app\.(get|post|put|patch|delete)\(|new Hono\(|fastify\(|httpAction|httpRouter' "$WORKTREE_PATH/$f" 2>/dev/null
done || true)
```

If both `WEB_CHANGES` and `HANDLER_CHANGES` are empty AND no layout-sensitive
keywords appear in the issue/PR body → skip E2E testing per the rule above.

## 5a.1 UI-visible diff detection

Both this step and `SKILL.md` §7 use the same definition. The diff is
**UI-visible** if ANY of these hold:

- `WEB_CHANGES` is non-empty.
- `HANDLER_CHANGES` is non-empty.
- The issue/PR body mentions any of these layout-sensitive keywords:
  `layout`, `responsive`, `label`, `QR`, `card`, `print`, `grid`,
  `typography`, `media placement`, `mobile`, `desktop`, `breakpoint`.

A UI-visible diff requires `E2E_RESULT=pass` to pass the Step 7 gate. A
non-UI-visible diff is allowed to set `E2E_RESULT=skipped`.

## 5a.2 MCP connection and callability

The official Chrome DevTools Claude plugin exposes
`mcp__chrome-devtools__*`; existing user configurations may expose
`mcp__chrome-devtools-mcp__*`. Resolve the available namespace once and use it
consistently. The examples below show the latter namespace.

Tool discovery is not proof that the browser is usable. The server connects
successfully but the first browser tool call fails, or a later call may fail
after some routes were inspected. In either case, set
`E2E_RESULT='missing-browser-tooling'`, preserve the actual `PAGES_TESTED`
count, stop the E2E run, and proceed only to Step 6 so the failure is posted.
Do not report `partial` or `skipped`, and do not continue after an MCP
reconnection because the selected page and browser state are no longer proven.

## 5b. Load the Spec (REQUIRED — do this BEFORE any browser testing)

Before touching the browser, understand what you're verifying against. Read the PR description and linked issue to build a mental model of expected visual state:

```bash
PR_JSON=$(cd "$WORKTREE_PATH" && github_pr "$PR_NUM") || { echo "Error: Could not read PR #$PR_NUM"; exit 1; }
jq -r '"\(.title)\n\n\(.body // \"\")"' <<< "$PR_JSON"
```

If the PR links to an issue, read those too. Use the GitHub API's structured closing references first (most reliable), then fall back to text parsing:

The `closingIssuesReferences` lookup below is the sole GraphQL-only exception
in this workflow because REST does not expose the PR's structured closing
references. All fallback content comes from the REST PR metadata already read.

```bash
ISSUE_NUMS=$(gh pr view "$PR_NUM" --repo "$REPO_SLUG" --json closingIssuesReferences --jq '.closingIssuesReferences[].number' 2>/dev/null)

if [ -z "$ISSUE_NUMS" ]; then
  ISSUE_NUMS=$(jq -r '.body // ""' <<< "$PR_JSON" | rg -io '(closes|fixes|resolves|close|fix|resolve)\s+([a-z0-9/_-]+)?#[0-9]+' | rg -o '[0-9]+$' || true)
fi

for ISSUE_NUM in $ISSUE_NUMS; do
  ISSUE_JSON=$(gh api "repos/$REPO_SLUG/issues/$ISSUE_NUM" 2>/dev/null) || continue
  jq -r '"\(.title)\n\n\(.body // \"\")"' <<< "$ISSUE_JSON"
done
```

**Build a checklist** of what the spec says should be visible:
- What pages/routes were added or changed?
- What should they look like? (layout, components, text, styling)
- What user flows were added? (forms, buttons, navigation)
- What acceptance criteria are listed?
- Are there mockups, wireframes, or design descriptions?

This checklist is what you verify screenshots against. If you can't articulate what you expect to see, you can't verify it.

## 5c. Detect Dev Server

Detect the command beneath `$WORKTREE_PATH` and store the raw executable
command in `DEV_SERVER_CMD`. Use the `$PM` resolved in `rebase-and-build.md`
§2a (re-run that detection block if `$PM` is unset):

1. Check `package.json` scripts for `dev` → command: `$PM run dev`
2. Check `package.json` scripts for `start`/`serve` → command: `$PM run start`
3. In a monorepo, prefer the root `dev` script so the task runner starts every
   workspace (web + backend); only target a single workspace
   (`pnpm --filter <pkg> dev`, `npm run dev -w <pkg>`) when the root script does
   not exist
4. Fallback for a framework with no script: `$PMX next dev`, `$PMX astro dev`,
   or `$PMX vite`

Detect the server port:
- Check the `dev`/`start` script for an explicit `-p`/`--port` flag
- Check for `PORT` env var patterns in code
- Check `.env`, `.env.local`, or `.envrc` for `PORT`
- Default by framework: `3000` for Next.js/Remix/Express, `4321` for Astro,
  `5173` for Vite, `8788` for Wrangler

## 5d. Run Database Migrations (if applicable)

**Run migrations BEFORE starting the dev server.** Many apps require up-to-date schema to boot successfully.

```bash
MIGRATE_SCRIPT=$(jq -r '.scripts // {} | keys[]' "$WORKTREE_PATH/package.json" 2>/dev/null \
  | grep -E '^(migrate|db:migrate|db:push|migrate:up)$' | head -1 || true)
if [ -n "$MIGRATE_SCRIPT" ]; then
  (cd "$WORKTREE_PATH" && $PM run "$MIGRATE_SCRIPT")
elif [ -d "$WORKTREE_PATH/prisma" ]; then
  (cd "$WORKTREE_PATH" && $PMX prisma migrate deploy)
elif ls "$WORKTREE_PATH"/drizzle.config.* >/dev/null 2>&1; then
  (cd "$WORKTREE_PATH" && $PMX drizzle-kit migrate)
else
  echo "No migration tool detected — skipping migrations"
fi
```

Convex projects need no separate migration step: `convex dev` pushes the schema
in `convex/schema.ts` as part of starting the backend.

## 5e. Start Dev Server (if not already running)

Check if the port is already in use before starting:

```bash
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" 2>/dev/null | grep -qE '^[1234]'; then
  echo "Server already running on port $PORT — reusing"
  SERVER_ALREADY_RUNNING=true
else
  (cd "$WORKTREE_PATH" && $DEV_SERVER_CMD) &
  SERVER_PID=$!
  SERVER_ALREADY_RUNNING=false
fi
```

Wait for server readiness (poll up to 30 seconds):

```bash
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" 2>/dev/null | grep -qE '^[1234]' && break
  sleep 1
done
```

If the server fails to start within 30 seconds:

- **UI-visible diff** (per §5a.1) → set `E2E_RESULT="fail"` with reason
  `skipped-server-failed` (the reason string is preserved for state-file
  compatibility, but the result IS a fail). Stop E2E and proceed to Step 6 to
  post the failure comment. The Step 7 gate in `SKILL.md` will block shipping.
- **Non-UI diff** → set `E2E_RESULT="skipped"` with reason
  `skipped-server-failed` and continue to Step 6. There was nothing visual to
  verify anyway.

## 5e.1 Existing Playwright Suite (if configured)

If the repo configures Playwright (`playwright.config.ts`/`.js` present, or
`@playwright/test` in `devDependencies`), run the existing suite against the
running dev server before the manual route walk:

```bash
if ls "$WORKTREE_PATH"/playwright.config.* >/dev/null 2>&1; then
  (cd "$WORKTREE_PATH" && $PMX playwright test --reporter=list) || PLAYWRIGHT_RESULT=fail
fi
```

A Playwright failure on a UI-visible diff sets `E2E_RESULT='fail'`; record the
failing spec names in the findings. Install prompts (`playwright install`) are
never auto-accepted — if browsers are missing, record the suite as not run and
continue with the MCP walk below.

**A green Playwright suite does NOT satisfy this step.** Playwright asserts what
the DOM contains; it cannot tell you the page looks right. The
navigate → stabilize → screenshot → READ sequence in §5h remains mandatory.

## 5f. Login Flow (if applicable)

Detect if the app requires authentication:

1. Use `mcp__chrome-devtools-mcp__new_page` to open a browser tab
2. Use `mcp__chrome-devtools-mcp__navigate_page` to `http://localhost:$PORT/`
3. Check if the page redirected to a login/auth page (URL contains `/login`, `/sign-in`, `/auth`)

**If login is required:**

1. Look for test credentials in environment files:
   ```bash
   for envfile in .envrc .env .env.local .env.test; do
     if [ -f "$WORKTREE_PATH/$envfile" ]; then
       grep -iE '(TEST_USER|TEST_EMAIL|ADMIN_EMAIL|TEST_PASSWORD|ADMIN_PASSWORD)' "$WORKTREE_PATH/$envfile" 2>/dev/null || true
     fi
   done
   ```
2. If credentials found:
   - Use `mcp__chrome-devtools-mcp__fill_form` with the discovered credentials
   - Use `mcp__chrome-devtools-mcp__click` on the submit/login button
   - Use `mcp__chrome-devtools-mcp__wait_for` to confirm navigation after login
   - Use `mcp__chrome-devtools-mcp__take_screenshot` to capture post-login state
   - **READ the screenshot** — verify you're logged in and see the expected post-login page
3. If no credentials found: skip login, test only public routes

## 5g. Visual Stabilization Protocol

**Before every screenshot**, use
`mcp__chrome-devtools-mcp__evaluate_script` once with the self-contained
function below. One call avoids relying on JavaScript state created by earlier
tool calls. If `evaluate_script` is unavailable, use `wait_for` with a
reasonable timeout before capturing.

After `new_page`, `navigate_page`, or `resize_page`, compare the returned
`url` with the route being tested. Allow an expected canonical or authentication redirect when the application behavior or login flow explains it, and continue
against the redirected route. For an unexpected URL after a successful tool
call, navigate to the intended route once more. If the tool still succeeds but
returns an unexpected URL, record a route failure with `E2E_RESULT='fail'`;
that is application behavior, not missing tooling.

If a page-scoped tool schema exposes an explicit page identifier, pass the
same identifier to every page-scoped call. Otherwise, the current server's
selected page is connection state: never assume it survives a tool error or
MCP reconnect. A tool error or a lost selected-page target uses the
`missing-browser-tooling` failure path in §5a.2.

Remove the `document.activeElement?.blur()` statement when testing a
focus-dependent state such as validation, keyboard navigation, or an active
input.

```javascript
async () => {
  await new Promise(resolve => {
    let lastCount = performance.getEntriesByType('resource').length;
    let stableChecks = 0;
    const finish = () => {
      clearInterval(interval);
      clearTimeout(deadline);
      resolve();
    };
    const interval = setInterval(() => {
      const currentCount = performance.getEntriesByType('resource').length;
      if (currentCount === lastCount) {
        stableChecks++;
        if (stableChecks >= 5) {
          finish();
        }
      } else {
        lastCount = currentCount;
        stableChecks = 0;
      }
    }, 100);
    const deadline = setTimeout(finish, 5000);
  });

  if (document.fonts?.ready) {
    await Promise.race([
      document.fonts.ready,
      new Promise(resolve => setTimeout(resolve, 5000))
    ]);
  }

  await Promise.race([
    Promise.all(
      Array.from(document.images)
        .filter(image => !image.complete)
        .map(image => new Promise(resolve => {
          image.addEventListener('load', resolve, { once: true });
          image.addEventListener('error', resolve, { once: true });
        }))
    ),
    new Promise(resolve => setTimeout(resolve, 5000))
  ]);

  let style = document.getElementById('ts-workflow-e2e-stabilization');
  if (!style) {
    style = document.createElement('style');
    style.id = 'ts-workflow-e2e-stabilization';
    style.textContent = '*, *::before, *::after { animation-duration: 0s !important; transition-duration: 0s !important; scroll-behavior: auto !important; }';
    document.head.appendChild(style);
  }

  document.activeElement?.blur();
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));

  return {
    url: location.href,
    readyState: document.readyState
  };
}
```

## 5h. Route Testing (the core of E2E)

Identify routes from changed files using the framework's file conventions:

1. **Next.js App Router:** `app/**/page.tsx` → the directory path is the route
   (`app/(marketing)/pricing/page.tsx` → `/pricing`; route groups in
   parentheses do not appear in the URL, `[param]` segments need a real value)
2. **Next.js Pages Router:** `pages/**/*.tsx` → file path minus `pages/` and the
   extension (`pages/index.tsx` → `/`)
3. **Astro:** `src/pages/**/*.astro` → same file-path mapping
4. **Remix / React Router:** `app/routes/*.tsx` → dots become slashes
5. **Express/Hono/Fastify:** parse the registration call for the URL pattern
   (e.g. `app.get("/api/users", ...)`)
6. If route detection fails, test the root path (`/`) as a baseline

**For each route, execute the FULL test sequence:**

### 1. Navigate
`mcp__chrome-devtools-mcp__navigate_page` to `http://localhost:$PORT<route>`

### 2. Stabilize
Run the Visual Stabilization Protocol (section 5g) to ensure the page is fully rendered.

### 3. Viewport Coverage (layout-sensitive diffs)

If the diff is layout-sensitive (per §5a.1 — keywords like layout, responsive,
label, QR, card, print, grid, typography, media placement, mobile, desktop,
breakpoint), capture multiple viewports per route, not just one:

- If the spec names a viewport, test that one.
- Otherwise capture **desktop 1280×720** and **narrow mobile 375×667** at minimum.
- For print/label/QR work, navigate to and screenshot the **print/label
  surface itself** (e.g. the actual printable page, the QR-rendering
  component), not just the surrounding admin page.

Use `mcp__chrome-devtools-mcp__resize_page` between captures, then re-run the
Visual Stabilization Protocol (§5g) before each new screenshot.

### 4. Screenshot
`mcp__chrome-devtools-mcp__take_screenshot` to capture the rendered page (per
viewport, if step 3 added more than one).

### 5. READ THE SCREENSHOT (MANDATORY)

**This is the most important step.** Use your multimodal vision to read the screenshot image and verify:

- **Layout correctness:** Are elements positioned correctly? Is spacing reasonable? Are there overlapping elements or broken layouts?
- **Content presence:** Is the expected text, data, and imagery visible? Are headings, labels, and body text present and readable?
- **Styling:** Are colors, fonts, and visual hierarchy consistent? Does it look like a finished page or a broken one?
- **Component rendering:** Are UI components (buttons, forms, tables, cards, navigation) rendered properly? No missing borders, broken icons, or placeholder text?
- **Image/asset loading:** Are images displayed (not broken image icons)? Are SVGs and icons rendering?
- **Responsive behavior:** Does the layout make sense at the current viewport width? Is anything overflowing or clipped?

**Visual defects that mean Verdict=FAIL (verification stops, do not ship):**
overlapping elements, QR codes over text, images covering labels, clipped
text, hidden buttons, overflowing content, unreadable wrapping, broken
print/label layouts, mobile or desktop breakpoint breakage. Any of these on a
tested route sets `E2E_RESULT='fail'` — record Expected/Observed/Verdict in
the findings and stop. Do NOT continue to Step 7's finish actions; the gate in
`SKILL.md` will block shipping.

**Compare against the spec:** Check each item on the checklist you built in step 5b. If the spec says "add a user table with name and email columns" — verify you see a table with those columns. If the spec says "add a login form" — verify the form fields are visible and labeled correctly.

**Document what you see in detail.** Not just "looks good" — describe the actual visual state:
- "The dashboard shows a navigation sidebar on the left, main content area with a table of 3 users showing name and email columns, header with the app logo"
- "The login form has email and password fields, a 'Sign In' button, and a 'Forgot Password' link below"

**Flag any discrepancies** between what you see and what the spec requires. This is the output that matters.

**Uninspected screenshots are a fail.** If you call `take_screenshot` but skip
the read+compare+document step, mark that route as
`uninspected-screenshots`. When the run completes, if any route is in this
state, set `E2E_RESULT='uninspected-screenshots'` — Step 7's gate treats this
the same as `fail`.

### 6. Console Check
`mcp__chrome-devtools-mcp__list_console_messages` — check for JavaScript errors. Console errors supplement visual verification; they do not replace it. A page can have a clean console and still look broken.

### 7. Network Check
`mcp__chrome-devtools-mcp__list_network_requests` — verify no failed requests (5xx responses). Supplementary, like the console check. A 5xx on a UI-visible diff is a `fail` per §5j.

### 8. Form Interaction (if the page contains forms related to changed code)
- Use `mcp__chrome-devtools-mcp__fill` to populate form fields with test data
- Use `mcp__chrome-devtools-mcp__click` to submit
- **Take another screenshot AFTER submission**
- **READ that screenshot** — verify the success/error state matches expectations
- Check console/network for errors

**Record results** for each page tested: URL, visual verification findings (what you saw vs. what was expected), console errors (if any), network failures, spec compliance (pass/fail with explanation).

## 5i. Edge Case Testing

After testing the primary routes, look for edge cases related to the changed code:

1. **Old/new code paths:** If the PR adds a migration or schema change, insert test data that exercises both the old format and new format to verify backwards compatibility
2. **Empty states:** Navigate to pages that may render differently with no data (empty lists, first-time user views)
   - **Screenshot and READ** — verify empty state messaging is present and looks correct
3. **Error states:** If the PR changes validation or error handling, submit invalid inputs to verify error messages render correctly
   - **Screenshot and READ** — verify error messages are visible, properly styled, and informative
4. **Boundary values:** If the PR adds pagination, filters, or limits, test with values at the boundary (0 items, 1 item, max items)

For each edge case tested, record: description, expected behavior, **what you actually saw in the screenshot**, pass/fail.

If test data was inserted for edge case testing, clean it up afterwards to avoid polluting the database.

## 5j. Cleanup

Kill the dev server (only if we started it):

```bash
if [ "$SERVER_ALREADY_RUNNING" != "true" ] && [ -n "$SERVER_PID" ]; then
  kill $SERVER_PID 2>/dev/null || true
fi
```

Collect results:
- `E2E_RESULT`: one of `pass`, `fail`, `partial`, `skipped`,
  `skipped-server-failed`, `missing-browser-tooling`, `uninspected-screenshots`.
  For UI-visible diffs, anything other than `pass` is a blocking failure per
  Step 7's gate. `skipped` is reserved for non-UI diffs.
- `PAGES_TESTED`: count of routes tested
- Per-route results for the PR comment including **visual verification findings**

**E2E failure handling on a UI-visible diff** (per §5a.1):
- Visual discrepancy from spec → `E2E_RESULT='fail'`. Document
  Expected/Observed/Verdict in the findings and stop before any label/ship.
- Page returning 5xx (or 4xx for a route the spec says should render) →
  `E2E_RESULT='fail'`.
- Console JavaScript errors → record in findings. Not load-bearing on their
  own, but combined with a visual defect they reinforce the fail.
- `PLAYWRIGHT_RESULT=fail` from §5e.1 → `E2E_RESULT='fail'`. List the failing
  spec names in the findings.
- MCP tool call fails on the first call or mid-test →
  `E2E_RESULT='missing-browser-tooling'`. Preserve `PAGES_TESTED`; the browser
  cannot inspect what it cannot reach.
- Any route where a screenshot was taken but not read → contributes to
  `E2E_RESULT='uninspected-screenshots'` (also a fail).

On a non-UI diff (per §5a.1) the same conditions are still recorded as
findings, but the Step 7 gate evaluates against `skipped` rather than `pass` —
so non-UI diffs proceed even when E2E hit issues, because there was nothing
visual to verify in the first place.

## Visual Verification Checklist (self-check before completing Step 5)

Before marking E2E testing as complete, confirm ALL of these:

- [ ] I read the PR/issue spec BEFORE starting browser tests
- [ ] I built a checklist of expected visual state from the spec
- [ ] For EVERY screenshot I took, I READ the screenshot image (not just captured it)
- [ ] For EVERY screenshot, I described what I saw in concrete terms
- [ ] I compared what I saw against the spec checklist and noted matches/discrepancies
- [ ] My results include visual findings, not just "screenshot captured"
- [ ] If I found visual discrepancies, I documented them with specific details
- [ ] On a layout-sensitive diff (per §5a.1), every tested route was captured at the required viewport(s) — desktop 1280×720 + narrow mobile 375×667 minimum, or the spec-named viewport(s)
- [ ] For print/label/QR work, I screenshotted the print/label surface itself, not just the surrounding admin page

**If you cannot check all of these boxes on a UI-visible diff, set `E2E_RESULT='uninspected-screenshots'` — Step 7 will block shipping.**
