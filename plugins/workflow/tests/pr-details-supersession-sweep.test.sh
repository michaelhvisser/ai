#!/bin/bash
# Executes pr-details' ACTUAL §1e supersession-sweep blocks — extracted from
# facts.md, so the doc is the code under test — against scripted git repos and
# a REST fixture, with the whole test running in a +10:00 timezone because the
# block's one load-bearing subtlety is UTC-normalizing every timestamp (a
# local-offset SINCE or mergedAt lexically mis-compares against GitHub's Zulu
# timestamps). The shipped half is local git (pr_facts_shipped_local), so the
# window is the merge-base..tip range itself and order is merge order — the
# creation-order cap that michaelhvisser/ai#17 describes cannot recur.
#   V1 hostile TZ       → squash commits at known UTC instants; the one after the
#                         merge-base is kept (Zulu mergedAt, issues + files
#                         extracted), the one before it never enters the range,
#                         and SINCE itself is Zulu-form
#   V2 cap hit          → 3 in-range commits, cap 2 → 2 rows, SHIPPED_TRUNCATED=true
#   V3 cap covered      → same repo, cap 3 → 3 rows, false; a direct push with no
#                         PR number survives with number:null
#   V4 closed issues    → REST fixture: closed_at window applied, PR rows dropped
#   V5 merge order      → the oldest PR number merged last is row 0 (#17's case)
set -euo pipefail
PLUGIN_DIR=$(cd "$(dirname "$0")/.." && pwd)
FACTS="$PLUGIN_DIR/skills/pr-details/facts.md"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TZ=Australia/Brisbane   # UTC+10, no DST — the hostile zone for every scenario

# --- extract the two §1e blocks by content marker ---
awk -v out="$SANDBOX/block" '
  /^```bash$/ {inb=1; n++; f=out "." n ".sh"; next}
  /^```/      {inb=0; next}
  inb         {print > f}
' "$FACTS"
SHIPPED_BLOCK=$(grep -l 'pr_facts_shipped_local' "$SANDBOX"/block.*.sh | head -1)
CLOSED_BLOCK=$(grep -l 'pr_facts_closed_issues' "$SANDBOX"/block.*.sh | head -1)
[ -n "$SHIPPED_BLOCK" ] || { echo "FAIL: shipped-sweep block extraction came up empty"; exit 1; }
[ -n "$CLOSED_BLOCK" ] || { echo "FAIL: closed-issue block extraction came up empty"; exit 1; }
grep -q 'format-local' "$SHIPPED_BLOCK" || { echo "FAIL: shipped block lost its UTC SINCE (format-local)"; exit 1; }
bash -n "$SHIPPED_BLOCK"
bash -n "$CLOSED_BLOCK"

# The blocks call lib functions; load the real lib, not a stub.
# shellcheck source=/dev/null
. "$PLUGIN_DIR/lib/github-rest.sh"
# shellcheck source=/dev/null
. "$PLUGIN_DIR/lib/pr-facts.sh"

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

stamp_commit() {  # $1 = UTC instant, $2 = subject, $3 = body, $4... = files to touch
  local when="$1" subject="$2" body="$3"; shift 3
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$when $subject" >> "$f"; git add "$f"; done
  GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" \
    git commit -q --allow-empty -m "$subject" -m "$body"
}

run_shipped() {  # $1 = repo, $2 = merge-base sha, $3 = cap; runs the doc's block
  (
    cd "$1"
    RUN_DIR="$1"; MERGE_BASE="$2"; BASE_TIP=$(git rev-parse HEAD); SHIPPED_CAP="$3"
    . "$SHIPPED_BLOCK"
    printf '%s\n' "$SINCE" > "$RUN_DIR/since.out"
    printf '%s\n' "$SHIPPED_TRUNCATED" > "$RUN_DIR/truncated.out"
  )
}

# ---------- V1: hostile TZ, range window, field extraction ----------
REPO1="$SANDBOX/r1"; mkdir -p "$REPO1"; cd "$REPO1"; git init -q -b main
stamp_commit "2025-12-31T20:00:00Z" "fix: pre-window (#3)" "Fixes #99" convex/http.ts
stamp_commit "2026-01-01T00:00:00Z" "base" ""
MERGE_BASE=$(git rev-parse HEAD)
stamp_commit "2026-01-01T05:00:00Z" "feat: in-window (#5)" "Some prose.

Fixes #144
closes #144
Resolved #145 by the same change." convex/http.ts app/x/page.tsx
run_shipped "$REPO1" "$MERGE_BASE" 200
[ "$(cat "$REPO1/since.out")" = "2026-01-01T00:00:00Z" ] \
  || fail V1 "SINCE not Zulu-form UTC: $(cat "$REPO1/since.out")"
[ "$(jq length "$REPO1/shipped.json")" = 1 ] \
  || fail V1 "expected 1 in-range PR, got $(jq -c . "$REPO1/shipped.json")"
[ "$(jq -r '.[0].number' "$REPO1/shipped.json")" = 5 ] || fail V1 "wrong PR survived"
[ "$(jq -r '.[0].mergedAt' "$REPO1/shipped.json")" = "2026-01-01T05:00:00Z" ] \
  || fail V1 "mergedAt not Zulu UTC: $(jq -r '.[0].mergedAt' "$REPO1/shipped.json")"
[ "$(jq -c '.[0].issues' "$REPO1/shipped.json")" = "[144,145]" ] \
  || fail V1 "closed issues not extracted: $(jq -c '.[0].issues' "$REPO1/shipped.json")"
[ "$(jq '.[0].files | length' "$REPO1/shipped.json")" = 2 ] || fail V1 "file list not extracted"
[ "$(cat "$REPO1/truncated.out")" = false ] || fail V1 "truncated should be false under the cap"
[ "$FAILS" = 0 ] && pass V1 "hostile TZ: Zulu SINCE + mergedAt, range window, issues+files extracted"

# ---------- V2/V3/V5: one repo, three in-range commits ----------
REPO2="$SANDBOX/r2"; mkdir -p "$REPO2"; cd "$REPO2"; git init -q -b main
stamp_commit "2026-01-01T00:00:00Z" "base" ""
MERGE_BASE2=$(git rev-parse HEAD)
stamp_commit "2026-01-02T00:00:00Z" "feat: newer PR (#10)" "" a.ts
stamp_commit "2026-01-03T00:00:00Z" "chore: direct push, no PR" "" b.ts
stamp_commit "2026-01-04T00:00:00Z" "fix: old PR merged last (#2)" "Closes #7" c.ts

V2_START=$FAILS
run_shipped "$REPO2" "$MERGE_BASE2" 2
[ "$(cat "$REPO2/truncated.out")" = true ] || fail V2 "3 commits over cap 2 must set SHIPPED_TRUNCATED"
[ "$(jq length "$REPO2/shipped.json")" = 2 ] || fail V2 "cap 2 should keep 2 rows"
[ "$FAILS" = "$V2_START" ] && pass V2 "cap hit: 2 of 3 rows, SHIPPED_TRUNCATED=true"

V3_START=$FAILS
run_shipped "$REPO2" "$MERGE_BASE2" 3
[ "$(cat "$REPO2/truncated.out")" = false ] || fail V3 "range fully covered — must not report truncation"
[ "$(jq length "$REPO2/shipped.json")" = 3 ] || fail V3 "all 3 rows should survive"
[ "$(jq -c 'map(.number)' "$REPO2/shipped.json")" = "[2,null,10]" ] \
  || fail V3 "direct push must survive as number:null, newest first: $(jq -c 'map(.number)' "$REPO2/shipped.json")"
[ "$FAILS" = "$V3_START" ] && pass V3 "cap covered: 3 rows, SHIPPED_TRUNCATED=false, number:null kept"

V5_START=$FAILS
[ "$(jq -r '.[0].number' "$REPO2/shipped.json")" = 2 ] \
  || fail V5 "merge order: the old PR merged last must be row 0"
[ "$(jq -c '.[0].issues' "$REPO2/shipped.json")" = "[7]" ] || fail V5 "issues on the merge-order row"
[ "$FAILS" = "$V5_START" ] && pass V5 "merge order, not creation order (#17)"

# ---------- V4: closed-issue window on REST closed_at, PR rows dropped ----------
jq -n '[[
  {number: 9, title: "in",  closed_at: "2026-01-02T00:00:00Z", labels: [{name: "bug", color: "x"}]},
  {number: 8, title: "out", closed_at: "2025-12-30T00:00:00Z", labels: []},
  {number: 7, title: "a PR, listed as an issue", closed_at: "2026-01-03T00:00:00Z", labels: [],
   pull_request: {url: "https://api.github.com/repos/o/r/pulls/7"}}
]]' > "$SANDBOX/v4.json"
V4_START=$FAILS
CLOSED_OUT=$(
  FIXTURE="$SANDBOX/v4.json"
  pr_facts_gh() { cat "$FIXTURE"; }
  RUN_DIR="$SANDBOX"; HOST="github.com"; SLUG="o/r"; SINCE="2026-01-01T00:00:00Z"
  . "$CLOSED_BLOCK"
  cat "$RUN_DIR/closed-issues.json"
)
[ "$(jq length <<<"$CLOSED_OUT")" = 1 ] || fail V4 "expected 1 in-window issue: $CLOSED_OUT"
[ "$(jq -r '.[0].number' <<<"$CLOSED_OUT")" = 9 ] || fail V4 "wrong issue survived"
[ "$(jq -c '.[0].labels' <<<"$CLOSED_OUT")" = '[{"name":"bug"}]' ] || fail V4 "labels not reduced to {name}"
[ "$FAILS" = "$V4_START" ] && pass V4 "closed-issue window on closed_at; pull_request rows dropped"

if [ "$FAILS" -gt 0 ]; then echo "pr-details-supersession-sweep: $FAILS failure(s)"; exit 1; fi
echo "pr-details-supersession-sweep: OK"
