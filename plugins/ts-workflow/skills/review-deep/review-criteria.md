# Review Criteria: Consolidated TypeScript/JavaScript-Specific + General Analysis

This document defines the complete review criteria applied during deep review. Criteria are adapted from the gopher-ai review system (MIT) and consolidated here for single-pass application.

## Review Focus Areas

### 1. Correctness (Priority 0-1)

- **Floating promises**: Every promise-returning call must be `await`ed, returned, or explicitly handled (`.catch(...)`, `void` with a comment). An unawaited async call in a request handler, effect, or test is a P0 — the work escapes the caller's error boundary and lifetime.
- **Missing `await`**: `if (asyncFn())` is always truthy; `try/catch` around a non-awaited call never catches. Check every `try`/`if`/`return` whose operand is async.
- **Null/undefined access**: Property access on values that can be `undefined` — array `.find()`/`.at()` results, `Map.get`, optional fields, JSON parses, `process.env.X`. Verify a guard or `?.` exists before use, and that `??`/`||` defaults are correct (`||` swallows `0`/`""`/`false`).
- **Async race conditions**: Concurrent writes to shared module-level or request-scoped state; `Promise.all` over mutations that assume ordering; stale-closure reads in async callbacks; effects that set state after unmount without a cancellation flag or `AbortController`.
- **Error handling**: Errors caught must be inspected, not swallowed (`catch {}`). Rethrow with cause (`new Error("...", { cause: err })`) instead of discarding the original. `catch (e)` is `unknown` — narrow before use.
- **Resource cleanup**: Every `addEventListener`, `setInterval`, subscription, stream, or `AbortController` created in an effect or handler has a matching teardown on the return path and on the error path.
- **Logic errors**: Off-by-one, wrong comparison operator, inverted conditions, missing `break` in `switch`, `==` where `===` is meant.

### 2. Security (Priority 0-1)

- **Server-side authorization**: Every mutation, route handler, server action, and API endpoint authenticates and authorizes on the server. Client-side gating (hidden buttons, conditional rendering) is not authorization. Verify the user owns or may access the specific record, not merely that a user is signed in.
- **XSS**: `dangerouslySetInnerHTML`, `innerHTML`, `document.write`, `eval`, and `new Function` on any value that can originate from user input or an external API. Require sanitization (e.g. DOMPurify) or removal.
- **Injection**: Parameterized queries, never template-literal SQL. No user input interpolated into shell commands (`child_process.exec`) — use `execFile` with an argument array.
- **Secret leakage**: No API keys, tokens, or connection strings in source. No secret read into a `NEXT_PUBLIC_*`/`VITE_*`/`PUBLIC_*` variable or otherwise referenced from a client component or bundle.
- **Data exposure**: Server responses must not return whole records containing PII, password hashes, or internal fields. Sensitive values must not reach logs or error messages returned to clients.
- **Unvalidated input**: Request bodies, query params, and webhook payloads validated with a schema (zod/valibot/Convex validators) before use. Webhooks verify their signature.
- **Path/URL traversal**: User-controlled path segments normalized and bounded before filesystem access; open-redirect checks on user-supplied redirect targets.

### 3. Performance (Priority 1-2)

- **O(n^2) loops**: Nested iterations over large collections — especially `.find()`/`.includes()` inside a loop where a `Map`/`Set` lookup belongs.
- **Sequential awaits**: `await` inside a loop over independent work; use `Promise.all`/`Promise.allSettled`. Conversely, flag unbounded `Promise.all` over a large collection with no concurrency limit.
- **Database**: N+1 query patterns (a query per item in a loop). Full-table scans where an index exists. Queries missing pagination or a result limit.
- **Unnecessary re-renders**: Object/array/function literals passed as props on every render; missing `useMemo`/`useCallback` where a memoized child depends on them; state placed too high in the tree; context values recreated each render.
- **Bundle weight**: Heavy dependencies pulled into a client component; namespace imports (`import * as X`) that defeat tree-shaking; a large library imported for one helper; a `"use client"` boundary that drags a subtree onto the client unnecessarily.
- **Unbounded growth**: Caches, maps, or arrays that accumulate without eviction; listeners registered per render.

### 4. Maintainability (Priority 2-3)

- **Dead code**: Unused functions, variables, imports, exports, or types introduced in this diff.
- **Function length**: Functions or components exceeding ~50 lines should be flagged for review.
- **Cognitive complexity**: Deeply nested conditionals (>3 levels). Complex boolean expressions. Deeply nested ternaries in JSX.
- **Naming**: `camelCase` values, `PascalCase` types and components, `SCREAMING_SNAKE_CASE` module constants. Names describe intent, not type. Booleans read as predicates (`isLoading`, `hasAccess`).
- **Single responsibility**: Each function does one thing; each module has a clear purpose. Data fetching, transformation, and presentation are separable.
- **Duplication**: Repeated types or literals that should be a shared type, constant, or util — check whether the repo already exports one before adding another.
- **Missing cleanup in tests**: `afterEach`/`vi.restoreAllMocks()`/`cleanup()` so state and mocks do not leak between cases.

### 5. Developer Experience (Priority 2-3)

- **Error context**: Thrown errors should identify the operation and the offending value, and preserve the original via `{ cause }`. A bare `throw new Error("failed")` is not diagnosable.
- **API clarity**: Exported functions should be self-documenting. Prefer a named options object over three positional booleans. Parameter names convey purpose.
- **Poor defaults**: Functions that require callers to remember non-obvious setup or call ordering.
- **Confusing control flow**: Non-obvious state machines, effects that trigger effects, or implicit coupling between hooks.

---

## TypeScript/JavaScript Idiom Checks

These are TS/JS patterns that distinguish idiomatic code:

- **No unnecessary `any`**: `any` disables checking silently. Prefer `unknown` plus narrowing, a generic, or the real type. Flag every `any` introduced by this diff that a concrete type could replace.
- **No unsafe casts**: `as SomeType` on a value the compiler cannot verify, `as unknown as T`, and non-null assertions (`!`) hide exactly the bugs this review looks for. Require a runtime guard or schema parse instead.
- **Narrow, don't assert**: Type predicates (`x is T`), `in`/`typeof`/`instanceof` checks, and discriminated unions over casts. Exhaustive `switch` with a `never` default.
- **`readonly` and immutability**: Do not mutate function parameters, props, or state objects in place. Prefer `const` and non-mutating array methods where the intent is a new value.
- **Explicit module boundaries**: Exported functions have explicit return types; internal inference is fine. No re-exporting a barrel that creates an import cycle.
- **Errors over sentinel values**: Throw or return a discriminated result; do not signal failure with `null`, `-1`, or `""` where a caller can miss it.
- **`import type`** for type-only imports so they are erased at build time.
- **Test conventions**: colocated `*.test.ts`/`*.spec.ts` (or a `__tests__/` sibling, matching the repo). Use `it.each`/`test.each` case tables instead of copy-pasted cases. Async assertions are awaited (`await expect(p).rejects.toThrow()`). Mocks restored in `afterEach`.

## Framework Checks (apply only to the frameworks detected in context gathering)

### React / Next.js

- **Rules of hooks**: Hooks called unconditionally at the top level — never inside conditionals, loops, or after an early return.
- **Dependency arrays**: `useEffect`/`useMemo`/`useCallback` deps complete and honest. Flag missing deps that cause stale closures, and flag deps suppressed with an eslint-disable that has no explanation.
- **Effects used for derivation**: State synced from props inside an effect that should just be computed during render.
- **Server/client boundary**: `"use client"` present wherever hooks, browser APIs, or event handlers are used. Server-only modules (DB clients, secrets, `fs`) never imported into a client component. Server components not passing non-serializable values (functions, class instances) as props to client components.
- **Server actions**: A `"use server"` function is a public endpoint — it must authenticate, authorize, and validate its arguments independently of the calling UI.
- **Caching and revalidation**: `fetch` cache semantics, `revalidatePath`/`revalidateTag` after a mutation, and `dynamic`/`revalidate` route settings match the data's freshness needs.
- **Keys and lists**: Stable `key` props — not array indices for reorderable lists.
- **Accessibility**: Interactive elements are real buttons/links, labeled inputs, and no click handlers on non-interactive nodes without keyboard support.

### Convex

- **Validators**: Every `query`/`mutation`/`action` declares `args` validators (and a `returns` validator where the codebase does). Unvalidated args are a P0 on public functions.
- **Auth**: Every public function calls the repo's auth helper (`ctx.auth.getUserIdentity()` or the project wrapper) and checks record ownership before reading or writing. `internal*` functions are not reachable from clients, but confirm the caller enforced auth.
- **Indexes**: Queries use `withIndex` against an index declared in `schema.ts`, not `filter` over a full table scan. The index field order matches the query's equality-then-range order.
- **Query vs action**: No side effects or `fetch` in a `query`; actions do not access `ctx.db` directly (use `ctx.runQuery`/`ctx.runMutation`).
- **Pagination**: Unbounded `.collect()` on a growing table should be `.paginate()` or `.take(n)`.
- **Schema migrations**: New required fields on existing tables need a backfill or an optional type; otherwise existing documents fail validation.

---

## Spec Compliance Criteria (when issue/PR context available)

When PR or issue context is available, also verify:

1. **Requirement coverage**: Does every acceptance criterion from the issue have a corresponding implementation in the diff?
2. **Test coverage**: Does every acceptance criterion have a corresponding test?
3. **Missing requirements**: Are there requirements mentioned in the issue body or comments that are NOT addressed?
4. **Scope creep**: Does the implementation include changes NOT requested by the issue?
5. **Bug fix root cause** (bug fixes only): Does the fix address the actual root cause, not just the symptom?
6. **Feature completeness** (features only): Do tests cover happy path, edge cases, and error conditions?

**CRITICAL: Do NOT trust the implementer's claims. Independently verify by reading the actual code line-by-line against the requirements.**

---

## Breaking Change Detection

Check for API-breaking changes in exported symbols:

```bash
git diff "${BASE_BRANCH}...HEAD" \
  -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs' \
  | grep -E "^-[[:space:]]*export[[:space:]]+(default|const|let|var|async[[:space:]]+function|function|class|abstract[[:space:]]+class|interface|type|enum|\{|\*)"

# Package entry points and public surface
git diff "${BASE_BRANCH}...HEAD" -- '*package.json' \
  | grep -E "^[-+][[:space:]]*\"(name|main|module|types|exports|bin|peerDependencies)\""
```

Breaking changes include:
- Removed or renamed exported functions, classes, types, interfaces, enums, or constants
- Changed function signatures (added required parameters, narrowed accepted types, widened return types)
- Required fields added to an exported interface/type, or fields removed from one
- A changed default export, or a removed re-export from a barrel/index file
- Changed `exports`/`main`/`types` entry points, or a moved public module path
- A dependency demoted to `peerDependencies`, or a major bump in one
- API route path, method, or response-shape changes; changed Convex function names or arg shapes (clients call them by path)

---

## Quality Score Rubric

Score the changes on a 100-point scale:

| Criteria | Points | Description |
|----------|--------|-------------|
| Error Handling | 20 | Promises awaited or handled, errors inspected and rethrown with cause, no silent `catch {}` |
| Test Coverage | 20 | New code has tests, edge cases covered, `it.each` case tables, async assertions awaited |
| Naming/Style | 15 | Idiomatic TS/JS conventions, clear naming, consistent formatting |
| Documentation | 15 | Exported symbols documented, complex logic commented |
| Complexity | 15 | Functions focused (<50 lines), low nesting, single responsibility |
| Type Safety | 15 | No unnecessary `any`, no unsafe casts or `!`, null/undefined guarded, inputs validated |

**Scoring guide:**
- 90-100: Excellent -- ready to merge
- 75-89: Good -- minor issues only
- 60-74: Needs work -- several findings to address
- Below 60: Significant issues -- major rework needed

---

## Confidence Scoring

For each finding, assign a confidence score (0.0 to 1.0):

- **0.9-1.0**: Certain -- clear bug, provable issue, obvious violation
- **0.7-0.8**: High confidence -- very likely an issue, but context might justify it
- **0.5-0.6**: Medium confidence -- possible issue, needs evaluation
- **0.3-0.4**: Low confidence -- might be intentional, worth flagging
- **Below 0.3**: Filtered out -- too uncertain to be actionable

Findings with confidence < 0.3 are automatically discarded. Findings with priority 3 AND confidence < 0.5 are auto-skipped during the fix phase.

---

## Rules

1. Only flag issues INTRODUCED by this diff. Do not flag pre-existing code unless it interacts with new code to create a bug.
2. Every finding MUST cite the exact file path and line range from the diff.
3. Verify line numbers against the diff -- accuracy is critical.
4. Do NOT stop after finding a few issues -- continue reviewing the entire diff until every qualifying finding is listed.
5. If the diff is clean and has no issues, report zero findings with a "patch is correct" verdict and the quality score.
