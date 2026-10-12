#!/usr/bin/env node
// Publish language-neutral workflow references into each plugin's own cache root.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const check = process.argv.includes("--check");
let drift = 0;
for (const name of ["work-method.md", "validation-policy.md"]) {
  const source = readFileSync(join(root, "plugins/workflow/lib", name), "utf8");
  const target = join(root, "plugins/ts-workflow/lib", name);
  if (existsSync(target) && readFileSync(target, "utf8") === source) continue;
  drift++;
  if (check) console.error(`ts-workflow/lib/${name}: differs from workflow source`);
  else writeFileSync(target, source);
}
if (check && drift) process.exit(1);
console.log(check ? "shared workflow references in sync" : `synced ${drift} workflow reference(s)`);
