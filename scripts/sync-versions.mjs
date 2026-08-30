#!/usr/bin/env node
// Syncs each plugin's version from .claude-plugin/marketplace.json (the
// canonical source) into plugins/<name>/.claude-plugin/plugin.json and
// plugins/<name>/.codex-plugin/plugin.json (when present).
// With --check it changes nothing and exits 1 if any manifest differs.
//
// Rewrites only the version line via regex so key order, indentation, and
// non-ASCII characters survive (JSON.stringify escapes em-dashes to —).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const check = process.argv.includes("--check");
const marketplace = JSON.parse(
  readFileSync(join(repo, ".claude-plugin", "marketplace.json"), "utf8"),
);

let drift = 0;
for (const { name, version } of marketplace.plugins) {
  for (const manifest of [".claude-plugin", ".codex-plugin"]) {
    const file = join(repo, "plugins", name, manifest, "plugin.json");
    if (!existsSync(file)) continue;
    const source = readFileSync(file, "utf8");
    const current = JSON.parse(source).version;
    if (current === version) continue;
    drift += 1;
    if (check) {
      console.error(`${name}/${manifest}: ${current} != marketplace ${version}`);
      continue;
    }
    const updated = source.replace(/("version"\s*:\s*")[^"]*(")/, `$1${version}$2`);
    if (JSON.parse(updated).version !== version) {
      console.error(`${name}/${manifest}: could not rewrite version field`);
      process.exit(1);
    }
    writeFileSync(file, updated);
    console.log(`${name}/${manifest}: ${current} -> ${version}`);
  }
}

if (check && drift > 0) {
  console.error(`\n${drift} manifest(s) out of sync. Run: node scripts/sync-versions.mjs`);
  process.exit(1);
}
if (drift === 0) console.log("all plugin versions in sync with marketplace.json");
