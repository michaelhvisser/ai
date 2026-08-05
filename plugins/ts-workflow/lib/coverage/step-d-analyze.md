# Step D — Analyze Changed-File Coverage

Loaded by `coverage-verification.md` Step D. Owns the statement-weighted
`coverage-summary.json` parser, the `ALL_ENTRYPOINT` flag logic, and the
per-language JSON parsing notes.

## Node/TypeScript: statement-weighted parser

Compute **statement-weighted** coverage (not the average of per-file
percentages) from the istanbul-shaped summary Step C produced. Each entry
carries `statements: { total, covered, pct }`; the aggregate is
`sum(covered) / sum(total)` over gated files.

Uncovered function *names* come from `coverage-final.json`: `fnMap[i].name`
where the hit count `f[i]` is `0`. Anonymous entries (`(anonymous_3)`) are
dropped — they name nothing a test author can target.

The loop runs twice: first over `CHANGED_SRC_GATED` (counted toward the
aggregate), then over `CHANGED_SRC_INFO` (entrypoint/wiring files — displayed
but excluded from totals). Per-file row generation, uncovered-function
extraction, and the `N/A (no statements)` short-circuit are identical in both
passes; only the totals accumulation differs. The `Notes` column distinguishes
the two: blank for gated rows, `excluded from gate (entrypoint/wiring)` for
info rows.

```bash
# Prints "<statements.total> <statements.covered> <uncovered fn names, comma-separated>"
# for one repo-relative path. Summary keys are usually ABSOLUTE paths, so match
# by path suffix. Prints "-1 0" when the file has no entry at all.
file_cov() {
  node -e '
const fs = require("fs");
const [summaryPath, finalPath, rel] = process.argv.slice(1);
const load = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { return {}; } };
const norm = (s) => s.replace(/\\/g, "/");
const find = (obj) => Object.keys(obj).find((k) => k !== "total" && (norm(k) === rel || norm(k).endsWith("/" + rel)));
const summary = load(summaryPath);
const sk = find(summary);
if (!sk) { process.stdout.write("-1 0"); process.exit(0); }
const st = summary[sk].statements || summary[sk].lines || { total: 0, covered: 0 };
const final = load(finalPath);
const fk = find(final);
let names = [];
if (fk && final[fk] && final[fk].fnMap) {
  const hits = final[fk].f || {};
  names = [...new Set(Object.keys(final[fk].fnMap)
    .filter((i) => hits[i] === 0)
    .map((i) => final[fk].fnMap[i].name)
    .filter((n) => n && !/^\(anonymous/.test(n)))];
}
process.stdout.write(st.total + " " + st.covered + " " + names.join(", "));
' "$COVERAGE_JSON" "$COVERAGE_FINAL" "$1" 2>/dev/null || printf -- "-1 0"
}

# Executable-line proxy used to weight a file that never made it into the report.
src_line_count() {
  n=$(grep -cvE '^[[:space:]]*(//|/\*|\*|$)' "$WORKTREE_PATH/$1" 2>/dev/null || true)
  echo "${n:-0}"
}

AGGREGATE_COVERAGE=""
FILE_REPORT=""
UNCOVERED_FUNCS=""
TOTAL_STMTS=0
TOTAL_COVERED=0
INFO_COUNT=0

# Pass 1: gated files — count toward TOTAL_STMTS / TOTAL_COVERED.
for f in $CHANGED_SRC_GATED; do
  FIELDS=$(file_cov "$f")
  FILE_TOTAL=$(echo "$FIELDS" | awk '{print $1}')
  FILE_COVERED=$(echo "$FIELDS" | awk '{print $2}')
  UNCOV=$(echo "$FIELDS" | cut -s -d' ' -f3-)

  # Missing entry: no test imported this file. Count it as fully uncovered,
  # weighted by its executable-line count, so an untested changed file drags the
  # aggregate down instead of silently vanishing from the gate.
  if [ "$FILE_TOTAL" = "-1" ]; then
    FILE_TOTAL=$(src_line_count "$f")
    if [ "$FILE_TOTAL" -eq 0 ] 2>/dev/null; then
      FILE_REPORT="${FILE_REPORT}\n| ${f} | N/A (no statements) | — |  |"
      continue
    fi
    TOTAL_STMTS=$((TOTAL_STMTS + FILE_TOTAL))
    FILE_REPORT="${FILE_REPORT}\n| ${f} | 0.0% | not in coverage report |  |"
    UNCOVERED_FUNCS="${UNCOVERED_FUNCS}\n${f}:<whole file — no test loads it>"
    continue
  fi

  if [ "$FILE_TOTAL" -eq 0 ] 2>/dev/null; then
    FILE_REPORT="${FILE_REPORT}\n| ${f} | N/A (no statements) | — |  |"
    continue
  fi

  FILE_COV=$(awk "BEGIN {printf \"%.1f\", ($FILE_COVERED/$FILE_TOTAL)*100}")
  TOTAL_STMTS=$((TOTAL_STMTS + FILE_TOTAL))
  TOTAL_COVERED=$((TOTAL_COVERED + FILE_COVERED))

  UNCOV_DISPLAY="${UNCOV:-—}"
  FILE_REPORT="${FILE_REPORT}\n| ${f} | ${FILE_COV}% | ${UNCOV_DISPLAY} |  |"

  if [ -n "$UNCOV" ]; then
    UNCOVERED_FUNCS="${UNCOVERED_FUNCS}\n${f}:${UNCOV}"
  fi
done

# Pass 2: info files (entrypoint/wiring) — display only, do NOT touch totals.
for f in $CHANGED_SRC_INFO; do
  INFO_COUNT=$((INFO_COUNT + 1))
  FIELDS=$(file_cov "$f")
  FILE_TOTAL=$(echo "$FIELDS" | awk '{print $1}')
  FILE_COVERED=$(echo "$FIELDS" | awk '{print $2}')
  UNCOV=$(echo "$FIELDS" | cut -s -d' ' -f3-)

  NOTE="excluded from gate (entrypoint/wiring)"

  if [ "$FILE_TOTAL" = "-1" ]; then
    FILE_REPORT="${FILE_REPORT}\n| ${f} | 0.0% | not in coverage report | ${NOTE} |"
    continue
  fi

  if [ "$FILE_TOTAL" -eq 0 ] 2>/dev/null; then
    FILE_REPORT="${FILE_REPORT}\n| ${f} | N/A (no statements) | — | ${NOTE} |"
    continue
  fi

  FILE_COV=$(awk "BEGIN {printf \"%.1f\", ($FILE_COVERED/$FILE_TOTAL)*100}")
  UNCOV_DISPLAY="${UNCOV:-—}"
  FILE_REPORT="${FILE_REPORT}\n| ${f} | ${FILE_COV}% | ${UNCOV_DISPLAY} | ${NOTE} |"
done

# Aggregate is computed from gated files only. ALL_ENTRYPOINT signals "every
# changed file was an entrypoint/wiring module" — Step E.2 emits a warning
# instead of running the gate.
ALL_ENTRYPOINT=false
if [ "$TOTAL_STMTS" -gt 0 ]; then
  AGGREGATE_COVERAGE=$(awk "BEGIN {printf \"%.1f\", ($TOTAL_COVERED/$TOTAL_STMTS)*100}")
elif [ -z "$CHANGED_SRC_GATED" ] && [ -n "$CHANGED_SRC_INFO" ]; then
  AGGREGATE_COVERAGE="N/A"
  ALL_ENTRYPOINT=true
else
  AGGREGATE_COVERAGE="0.0"
fi
```

`COVERAGE_JSON` and `COVERAGE_FINAL` are set by Step C. On a monorepo where each
package writes its own `coverage/` directory, run the two passes once per
summary file and sum the results — `file_cov` returns `-1` for any path a given
summary does not contain, so a file is only ever scored by the summary that
actually owns it.

## Per-language parsing (fallbacks)

For **Rust**, parse the JSON output from llvm-cov or tarpaulin — extract
per-file line coverage.

For **Python**, parse `coverage.json` — extract
`files.<path>.summary.percent_covered` for each changed file.

For **Go** (secondary fallback), read per-file percentages from
`go -C "$WORKTREE_PATH" tool cover -func=.local/state/coverage.out`: each line
is `file:line: functionName  coverage%`. Group the lines by file, average them
per file, and take functions ending in `0.0%` as `UNCOVERED_FUNCS`. Feed the
same `FILE_REPORT` / `AGGREGATE_COVERAGE` variables; `ALL_ENTRYPOINT` is always
`false` on this path.

## Outputs (consumed by Steps E and F)

| Variable | Type | Notes |
|----------|------|-------|
| `AGGREGATE_COVERAGE` | string | `"82.4"`, `"0.0"`, or `"N/A"` |
| `ALL_ENTRYPOINT` | `true`/`false` | True only when every changed file is an entrypoint/wiring module |
| `FILE_REPORT` | string | Pre-rendered table rows (gated first, then info) |
| `UNCOVERED_FUNCS` | newline-separated | `file:func1, func2` entries (gated files only) |
| `INFO_COUNT` | int | Number of entrypoint/wiring files in the report |
| `TOTAL_STMTS`, `TOTAL_COVERED` | int | Raw statement counts from gated pass |
