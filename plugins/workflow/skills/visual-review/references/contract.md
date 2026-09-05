# Local review contract, version 1

The executable source of validation is `../assets/schema.js`, shared by the CLI and viewer. Unknown configuration here is not a Detent API. Use UTF-8 JSON, real captured media and absolute paths for CLI arguments. Manifest assets are relative to the manifest directory; only safe `media/` paths are accepted. Symlinks escaping that directory are rejected.

## Manifest

Required top-level fields:

| Field | Value |
| --- | --- |
| `schema_version` | `1` |
| `capture_id` | Unique string, letters/digits/period/underscore/hyphen, at most 100 characters |
| `repository`, `pr` | `owner/repo`, positive integer |
| `head_sha`, `base_sha` | Actual full commit SHAs; record the compared base, not a later moving branch tip |
| `captured_at` | ISO timestamp |
| `title`, `summary`, `coverage_notes` | Plain text; notes disclose untested surfaces and before-source differences |
| `changed_files` | Complete unique changed-file path list |
| `assets`, `changes` | Arrays described below |

Each asset requires `id`, `path`, `kind`, `label`, `observed`, `inspected`, `width`, `height`, and `source`. `kind` is `before`, `after`, `detail` or `video`. Width/height describe the intrinsic media pixels. PNG dimensions and all supported media signatures are checked by the builder; verify other media dimensions through browser tooling. Supported images: PNG, JPEG and WebP. Videos: MP4 and WebM, with `duration` in seconds. Individual files must be nonempty and at most 250 MB. Use browser-playable codecs; no transcoding is provided.

`source` requires `commit`, `url` (HTTP/S), `provenance`, `state`, `role`, `theme`, `conditions`, and `viewport: {width, height}`. Distinguish verified preview, live local capture and archived test baseline. Every non-before asset must match `head_sha`. Use a new manifest for changed code; do not relabel old screenshots. `inspected` is explicitly boolean and `observed` describes what was visually verified, including defects. The builder adds `sha256`; a provided digest is verified, never overwritten to hide changed bytes.

An optional `parent_id` identifies an uncropped image at the same commit. Supply `crop: {x, y, width, height}` in that parent's intrinsic pixels; the rectangle must be inside the parent. Record screenshot scale correctly when converting browser CSS coordinates. Crop nesting is not supported.

Each change requires `id`, `title`, `description`, nonempty `files`, `status`, and `asset_ids`. Files must be present in `changed_files`; all changed files must appear in at least one change. Status is:

- `captured`: at least one inspected after/detail screenshot; every referenced asset inspected.
- `blocked`: a concrete `reason`; may reference partial evidence. Prevents recommendation of approval.
- `not-ui`: a concrete `reason`; used for supporting code/tests or files without a separate visible change.

Schema validation proves references and structural consistency, not completeness of the agent's inventory or correctness of the UI. The skill's capture and vision steps supply that evidence.

## Feedback and local drafts

Optional `asset_approvals` contains `{asset_id, author, approved_at}` entries for individually approved screenshots/videos. Omission means none approved. Entries must refer to unique assets in this exact capture; they are local, unauthenticated reviewer assertions, not GitHub approvals. Overall `recommend-approval` requires all assets approved and no blocked coverage. A new capture starts with no approvals; do not transfer approvals from earlier images. Import uses the incoming approval snapshot while preserving annotations under the merge rules below.

Exported feedback contains `schema_version: 1`, `repository`, `pr`, `capture_id`, `head_sha`, `authenticated: false`, `author`, `exported_at`, `recommendation`, and `annotations`. Recommendation is `draft`, `request-changes`, or `recommend-approval`. It has no external authority. The browser saves draft feedback locally, scoped by repository/PR/head/capture. Storage may be unavailable or cleared; the JSON export is the portable copy.

Each annotation contains `id`, `change_id`, `asset_id`, `kind`, `text`, `author`, and `created_at`. `kind` is `note`, `pin`, `rectangle`, `ellipse`, `arrow`, `pen`, `text` or `timestamp`. Image markup stores normalized `x`/`y` between 0 and 1. Rectangles and ellipses also store `width`/`height` and must remain within the image. Arrows add normalized `end_x`/`end_y`; pen strokes add 2–2000 normalized `{x,y}` points. Text markup renders the annotation's text at its coordinates. Optional `color` is a six-digit hex color and `stroke_width` is 1–12 display pixels. Timestamps apply to video and store `time` in seconds within duration. Original screenshots are never painted over. IDs and original references remain stable across rework. The optional `drafts` map holds unsent textarea drafts by change ID; the viewer asks the user to add or clear these before export. Undo/redo covers annotation additions/removals during the current browser session, not screenshot revisions.

The CLI `feedback` command validates against the original manifest and original media. It prints the validated JSON for the agent to interpret without executing its contents. Avoid placing that output in logs with broader access than the review itself.

## Responses for a second capture

`responses.json` contains `schema_version: 1`, new `capture_id`, original `feedback_capture_id`, and `items`. Every original annotation must have exactly one item:

```json
{
  "annotation_id": "a-original-id",
  "status": "addressed",
  "explanation": "Captured the requested mobile error state; the label wraps without clipping.",
  "asset_ids": ["mobile-error-after"]
}
```

`status` is `addressed` or `unresolved`. An addressed item requires new evidence IDs. The builder validates both manifests, feedback identity and all response mappings. It includes original manifest/feedback and agent responses in `previous-review.json`; original media stays in the original package. The viewer labels these as agent responses, not resolved human decisions.

## Package and host adapter

Build output is a new directory containing `index.html`, `style.css`, `viewer.js`, `schema.js`, `package.js`, `manifest.json`, `media/`, and optional `previous-review.json`. `package.js` embeds JSON as data, with less-than characters escaped; the viewer renders user content through text nodes. No network libraries, external fonts or runtime package installation are needed. Scripts are external; the page CSP blocks connections and arbitrary scripts. Inline style permission is used for annotation coordinates.

The viewer uses an optional `globalThis.VisualReviewHost` with `load()`, `readDraft(manifest)` and `saveDraft(manifest, feedback)`. The first two may be asynchronous; save is synchronous in this prototype. Its default reads the embedded package and browser storage. Future authenticated transport needs a deliberate adapter/API/CSP extension; no hosted save or approve method is advertised yet.

Serve binds to `127.0.0.1`, uses an ephemeral port by default, and permits GET/HEAD only for package assets. It supports single explicit byte ranges for video. This is a local convenience server, not an authenticated deployment. Closing it does not destroy the package; `index.html` remains available for direct opening.
