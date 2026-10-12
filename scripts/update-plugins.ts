#!/usr/bin/env node
// Refresh every installed Codex plugin through its CLI, preserving disabled state.
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Plugin = {
  pluginId: string;
  marketplaceName: string;
  enabled: boolean;
  version: string | null;
  source?: { source?: string };
  marketplaceSource?: { sourceType?: string };
};
type Run = (args: string[]) => unknown;

export function cli(args: string[]): unknown {
  const result = spawnSync("codex", args, {
    encoding: "utf8",
    cwd: homedir(),
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || `codex exited ${result.status}`);
  }
  return JSON.parse(result.stdout);
}

export function inventory(value: unknown): Plugin[] {
  if (!value || !Array.isArray((value as { installed?: unknown }).installed)) {
    throw new Error(
      "Invalid codex plugin list response: expected installed array",
    );
  }
  const plugins = (value as { installed: Plugin[] }).installed;
  const ids = new Set<string>();
  for (const plugin of plugins) {
    if (
      !plugin ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$/.test(
        plugin.pluginId,
      ) ||
      !plugin.pluginId.endsWith(`@${plugin.marketplaceName}`) ||
      typeof plugin.enabled !== "boolean" ||
      (plugin.version !== null && typeof plugin.version !== "string") ||
      ids.has(plugin.pluginId)
    ) {
      throw new Error("Invalid or duplicate installed plugin entry");
    }
    ids.add(plugin.pluginId);
  }
  return plugins;
}

// Locate structural lines without interpreting text in TOML strings or arrays
// as configuration. We only edit the table/boolean written by Codex's editor.
function structuralLines(lines: string[]): boolean[] {
  let quote = "";
  let depth = 0;
  return lines.map((line) => {
    const structural = !quote && depth === 0;
    for (let i = 0; i < line.length; i++) {
      const character = line[i];
      if (!quote) {
        if (character === "#") break;
        if (character === '"' || character === "'") {
          quote = line.startsWith(character.repeat(3), i)
            ? character.repeat(3)
            : character;
          i += quote.length - 1;
        } else if (character === "[" || character === "{") depth++;
        else if (character === "]" || character === "}") depth--;
      } else if (quote[0] === '"' && character === "\\") i++;
      else if (line.startsWith(quote, i)) {
        i += quote.length - 1;
        // A multiline closing delimiter may include one or two literal quotes.
        if (quote.length === 3) while (line[i + 1] === quote[0]) i++;
        quote = "";
      }
    }
    return structural;
  });
}

// Codex's TOML editor expands inline plugin tables and may retain literal quotes.
// Change only the enabled line it writes, leaving other user settings intact.
export function restoreDisabled(configPath: string, id: string): void {
  if (!existsSync(configPath))
    throw new Error(`Missing config while preserving ${id}`);
  const path = realpathSync(configPath);
  const text = readFileSync(path, "utf8");
  const escapedId = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const header = new RegExp(
    `^\\s*\\[\\s*(?:plugins|"plugins"|'plugins')\\s*\\.\\s*(?:"${escapedId}"|'${escapedId}')\\s*\\]\\s*(?:#.*)?$`,
  );
  const lines = text.split("\n");
  const structural = structuralLines(lines);
  const start = lines.findIndex(
    (line, i) => structural[i] && header.test(line),
  );
  if (start < 0)
    throw new Error(`Cannot find Codex's generated table for ${id}`);
  let enabled = -1;
  for (let i = start + 1; i < lines.length; i++) {
    if (!structural[i]) continue;
    if (/^\s*\[/.test(lines[i])) break;
    if (
      /^\s*(?:enabled|"enabled"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?$/.test(
        lines[i],
      )
    ) {
      if (enabled >= 0) throw new Error(`Duplicate enabled field for ${id}`);
      enabled = i;
    }
  }
  if (enabled < 0) throw new Error(`Cannot find enabled field for ${id}`);
  if (/=\s*false\b/.test(lines[enabled])) return;
  lines[enabled] = lines[enabled].replace(/(=\s*)true\b/, "$1false");
  const temporary = `${path}.plugin-update-${process.pid}`;
  try {
    writeFileSync(temporary, lines.join("\n"), {
      mode: statSync(path).mode & 0o777,
      flag: "wx",
    });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
}

export function updatePlugins({
  run = cli,
  dryRun = false,
  codexHome = process.env.CODEX_HOME || join(homedir(), ".codex"),
  log = console.log,
}: {
  run?: Run;
  dryRun?: boolean;
  codexHome?: string;
  log?: (message: string) => void;
} = {}): number {
  const plugins = inventory(run(["plugin", "list", "--json"]));
  const failures: string[] = [];
  const failedMarketplaces = new Set<string>();
  const gitMarketplaces = new Set(
    plugins
      .filter((p) => p.marketplaceSource?.sourceType === "git")
      .map((p) => p.marketplaceName),
  );
  for (const name of gitMarketplaces) {
    log(`Refresh marketplace: ${name}`);
    if (dryRun) continue;
    try {
      const result = run([
        "plugin",
        "marketplace",
        "upgrade",
        name,
        "--json",
      ]) as { errors?: unknown[] };
      if (!result || !Array.isArray(result.errors) || result.errors.length) {
        throw new Error(
          `Marketplace refresh failed: ${JSON.stringify(result?.errors)}`,
        );
      }
    } catch (error) {
      failures.push(`${name}: ${String(error)}`);
      failedMarketplaces.add(name);
    }
  }
  let refreshed = 0;
  let skipped = 0;
  for (const plugin of plugins) {
    const id = plugin.pluginId;
    if (
      !plugin.enabled &&
      (plugin.source?.source === "remote" ||
        plugin.marketplaceSource?.sourceType === "remote")
    ) {
      log(
        `SKIPPED: ${id}: the CLI install would enable this account-managed plugin; leave it disabled.`,
      );
      skipped++;
      continue;
    }
    log(
      `${dryRun ? "Would update" : "Update"}: ${id}${plugin.enabled ? "" : " (keep disabled)"}`,
    );
    if (dryRun) continue;
    if (failedMarketplaces.has(plugin.marketplaceName)) {
      failures.push(`${id}: skipped because marketplace refresh failed`);
      continue;
    }
    try {
      // Restore even when the CLI fails after partially changing configuration.
      try {
        const result = run(["plugin", "add", id, "--json"]) as {
          pluginId?: string;
          version?: string;
        };
        if (result?.pluginId !== id || typeof result.version !== "string") {
          throw new Error("Invalid plugin install response");
        }
        log(`  ${plugin.version ?? "unknown"} -> ${result.version}`);
      } finally {
        if (!plugin.enabled)
          restoreDisabled(join(codexHome, "config.toml"), id);
      }
      refreshed++;
    } catch (error) {
      failures.push(`${id}: ${String(error)}`);
      log(`  FAILED: ${String(error)}`);
    }
  }
  if (!dryRun && plugins.length) {
    try {
      const after = new Map(
        inventory(run(["plugin", "list", "--json"])).map((p) => [
          p.pluginId,
          p,
        ]),
      );
      for (const before of plugins) {
        if (after.get(before.pluginId)?.enabled !== before.enabled) {
          failures.push(
            `${before.pluginId}: enabled state changed or plugin disappeared`,
          );
        }
      }
    } catch (error) {
      failures.push(
        `Could not verify installed plugin states: ${String(error)}`,
      );
    }
  }
  for (const failure of failures) log(`FAILED: ${failure}`);
  log(
    dryRun
      ? `Dry run: ${plugins.length} installed plugins; ${skipped} skipped; no changes made.`
      : `${refreshed}/${plugins.length} plugins refreshed; ${skipped} skipped; ${failures.length} failures. New sessions load updates.`,
  );
  return failures.length ? 1 : 0;
}

const label = "com.michaelhvisser.ai.update-plugins";
function xml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

export function schedulePlist(
  script: string,
  node: string,
  path: string,
  codexHome: string,
  log: string,
): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(node)}</string><string>${xml(script)}</string></array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(path)}</string><key>CODEX_HOME</key><string>${xml(codexHome)}</string></dict>
<key>StartInterval</key><integer>86400</integer>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>${xml(log)}</string>
<key>StandardErrorPath</key><string>${xml(log)}</string>
</dict></plist>
`;
}

function launchctl(args: string[], tolerateMissing = false): void {
  const result = spawnSync("launchctl", args, { encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status && !tolerateMissing) throw new Error(result.stderr.trim());
}

function schedule(remove: boolean): void {
  if (process.platform !== "darwin")
    throw new Error(
      "Scheduling requires macOS; run the updater with your scheduler on Linux.",
    );
  const agent = join(homedir(), "Library", "LaunchAgents", `${label}.plist`);
  const codexHome = resolve(
    process.env.CODEX_HOME || join(homedir(), ".codex"),
  );
  if (existsSync(join(codexHome, ".plugin-update-lock"))) {
    throw new Error(
      "An updater holds the lock; let it finish before changing the schedule.",
    );
  }
  if (!remove) inventory(cli(["plugin", "list", "--json"]));
  const domain = `gui/${process.getuid!()}`;
  launchctl(["bootout", `${domain}/${label}`], true);
  if (remove) {
    rmSync(agent, { force: true });
    console.log("Removed daily plugin updater.");
    return;
  }
  const log = join(
    homedir(),
    "Library",
    "Logs",
    "michaelhvisser-ai",
    "update-plugins.log",
  );
  mkdirSync(dirname(agent), { recursive: true });
  mkdirSync(dirname(log), { recursive: true });
  writeFileSync(
    agent,
    schedulePlist(
      realpathSync(fileURLToPath(import.meta.url)),
      process.execPath,
      process.env.PATH || "",
      codexHome,
      log,
    ),
  );
  launchctl(["bootstrap", domain, agent]);
  console.log(
    `Installed updater: runs now and daily. Keep this checkout and Node installation. Log: ${log}`,
  );
}

export function main(args: string[]): number {
  if (
    args.length > 1 ||
    (args.length &&
      ![
        "--help",
        "--dry-run",
        "--install-schedule",
        "--remove-schedule",
      ].includes(args[0]))
  ) {
    throw new Error(
      "Usage: node scripts/update-plugins.ts [--dry-run|--install-schedule|--remove-schedule|--help]",
    );
  }
  if (args[0] === "--help") {
    console.log(
      "Usage: node scripts/update-plugins.ts [--dry-run|--install-schedule|--remove-schedule]\nRequires Node 22.18+ and codex plugin commands. Updates installed Codex plugins; disabled account-managed plugins are reported and skipped to preserve their state.\n--install-schedule runs now and daily via macOS launchd; --remove-schedule removes that job.",
    );
    return 0;
  }
  if (args[0] === "--install-schedule" || args[0] === "--remove-schedule") {
    schedule(args[0] === "--remove-schedule");
    return 0;
  }
  const dryRun = args[0] === "--dry-run";
  const codexHome = resolve(
    process.env.CODEX_HOME || join(homedir(), ".codex"),
  );
  const lock = join(codexHome, ".plugin-update-lock");
  if (!dryRun) {
    mkdirSync(codexHome, { recursive: true });
    try {
      mkdirSync(lock);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") {
        throw new Error(
          `Another update owns ${lock}. If its process stopped, remove this directory before retrying.`,
        );
      }
      throw error;
    }
  }
  try {
    if (!dryRun) writeFileSync(join(lock, "pid"), String(process.pid));
    console.log(`[${new Date().toISOString()}] Updating Codex plugins`);
    return updatePlugins({ dryRun, codexHome });
  } finally {
    if (!dryRun) rmSync(lock, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  existsSync(process.argv[1]) &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(`Plugin update failed: ${String(error)}`);
    process.exitCode = 1;
  }
}
