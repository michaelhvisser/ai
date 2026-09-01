#!/bin/bash
# Executes pr-details' ACTUAL §1e supersession-sweep blocks — extracted from
# facts.md, so the doc is the code under test — against a scripted repo and
# fixtures, with the whole test running in a +10:00 timezone because the block's
# one load-bearing subtlety is UTC-normalizing the window boundary (a
# local-offset SINCE lexically mis-compares against GitHub's Zulu timestamps).
#   V1 hostile TZ       → merge-base at a known UTC instant; a PR merged 5h
#                         after the boundary is kept, one 4h before is dropped,
#                         and SINCE itself is Zulu-form
#   V2 cap hit, all in  → 30/30 rows inside the window → SHIPPED_TRUNCATED=true
#   V3 cap hit, covered → 30 rows, oldest predates SINCE → false
#   V4 closed issues    → the same window applied to closedAt
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
SHIPPED_BLOCK=$(grep -l 'format-local' "$SANDBOX"/block.*.sh | head -1)
CLOSED_BLOCK=$(grep -l 'issue list -R' "$SANDBOX"/block.*.sh | head -1)
[ -n "$SHIPPED_BLOCK" ] || { echo "FAIL: shipped-sweep block extraction came up empty"; exit 1; }
[ -n "$CLOSED_BLOCK" ] || { echo "FAIL: closed-issue block extraction came up empty"; exit 1; }
bash -n "$SHIPPED_BLOCK"
bash -n "$CLOSED_BLOCK"

FAILS=0
fail() { echo "FAIL [$1]: $2"; FAILS=$((FAILS+1)); }
pass() { echo "  ok [$1] $2"; }

# one scripted repo: a single commit stamped at a known UTC instant
REPO="$SANDBOX/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main
GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" \
  git commit -q --allow-empty -m base
MERGE_BASE=$(git rev-parse HEAD)

run_shipped() {  # $1 = fixture path; runs the doc's block with pr_facts_gh stubbed
  FIXTURE="$1"
  (
    pr_facts_gh() { cat "$FIXTURE"; }
    RUN_DIR="$REPO"; SLUG="o/r"; BASE="main"
    . "$SHIPPED_BLOCK"
    printf '%s\n' "$SINCE" > "$RUN_DIR/since.out"
    printf '%s\n' "$SHIPPED_TRUNCATED" > "$RUN_DIR/truncated.out"
  )
}

# ---------- V1: hostile TZ, window filter, field extraction ----------
jq -n '[
  {number: 5, title: "in-window",  mergedAt: "2026-01-01T05:00:00Z",
   files: [{path: "convex/http.ts"}, {path: "app/x/page.tsx"}],
   closingIssuesReferences: [{number: 144}]},
  {number: 3, title: "pre-window", mergedAt: "2025-12-31T20:00:00Z",
   files: [{path: "convex/http.ts"}], closingIssuesReferences: []}
]' > "$SANDBOX/v1.json"
run_shipped "$SANDBOX/v1.json"
[ "$(cat "$REPO/since.out")" = "2026-01-01T00:00:00Z" ] \
  || fail V1 "SINCE not Zulu-form UTC: $(cat "$REPO/since.out")"
[ "$(jq length "$REPO/shipped.json")" = 1 ] \
  || fail V1 "expected 1 in-window PR, got $(jq -c . "$REPO/shipped.json")"
[ "$(jq -r '.[0].number' "$REPO/shipped.json")" = 5 ] || fail V1 "wrong PR survived"
[ "$(jq -c '.[0].issues' "$REPO/shipped.json")" = "[144]" ] || fail V1 "closed issues not extracted"
[ "$(jq '.[0].files | length' "$REPO/shipped.json")" = 2 ] || fail V1 "file list not extracted"
[ "$(cat "$REPO/truncated.out")" = false ] || fail V1 "truncated should be false under the cap"
[ "$FAILS" = 0 ] && pass V1 "hostile TZ: Zulu SINCE, window filter, issues+files extracted"

# ---------- V2: cap hit with every row inside the window → truncated ----------
jq -n '[range(30) | {number: ., title: "t", mergedAt: "2026-01-02T00:00:00Z",
                     files: [{path: "a.ts"}], closingIssuesReferences: []}]' > "$SANDBOX/v2.json"
run_shipped "$SANDBOX/v2.json"
[ "$(cat "$REPO/truncated.out")" = true ] || fail V2 "30/30 in-window must set SHIPPED_TRUNCATED"
[ "$(jq length "$REPO/shipped.json")" = 30 ] || fail V2 "all 30 rows should survive the filter"
[ "$FAILS" = 0 ] && pass V2 "cap hit, all in window: SHIPPED_TRUNCATED=true"

# ---------- V3: cap hit but the oldest row predates the window → covered ----------
jq -n '[range(30) | {number: ., title: "t",
                     mergedAt: (if . == 29 then "2025-12-01T00:00:00Z" else "2026-01-02T00:00:00Z" end),
                     files: [], closingIssuesReferences: []}]' > "$SANDBOX/v3.json"
run_shipped "$SANDBOX/v3.json"
[ "$(cat "$REPO/truncated.out")" = false ] || fail V3 "window fully covered — must not report truncation"
[ "$(jq length "$REPO/shipped.json")" = 29 ] || fail V3 "pre-window row should be filtered"
[ "$FAILS" = 0 ] && pass V3 "cap hit, window covered: SHIPPED_TRUNCATED=false"

# ---------- V4: closed-issue window uses the same boundary ----------
jq -n '[
  {number: 9, title: "in",  closedAt: "2026-01-02T00:00:00Z", labels: []},
  {number: 8, title: "out", closedAt: "2025-12-30T00:00:00Z", labels: []}
]' > "$SANDBOX/v4.json"
CLOSED_OUT=$(
  FIXTURE="$SANDBOX/v4.json"
  pr_facts_gh() { cat "$FIXTURE"; }
  SLUG="o/r"; SINCE="2026-01-01T00:00:00Z"
  . "$CLOSED_BLOCK"
)
[ "$(jq length <<<"$CLOSED_OUT")" = 1 ] || fail V4 "expected 1 in-window issue: $CLOSED_OUT"
[ "$(jq -r '.[0].number' <<<"$CLOSED_OUT")" = 9 ] || fail V4 "wrong issue survived"
[ "$FAILS" = 0 ] && pass V4 "closed-issue window filter on closedAt"

if [ "$FAILS" -gt 0 ]; then echo "pr-details-supersession-sweep: $FAILS failure(s)"; exit 1; fi
echo "pr-details-supersession-sweep: OK"
