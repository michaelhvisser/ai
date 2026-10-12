import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  acquireUpdateLock,
  assertNoUpdateOwner,
  cli,
  inventory,
  main,
  restoreDisabled,
  schedulePlist,
  updatePlugins as runUpdatePlugins,
} from "../update-plugins.ts";

const plugin = (name, marketplace, enabled = true, sourceType = "git") => ({
  pluginId: `${name}@${marketplace}`,
  marketplaceName: marketplace,
  enabled,
  version: "1.0.0",
  marketplaceSource: { sourceType },
});
const temporary = () => mkdtempSync(join(tmpdir(), "plugin-update-test-"));

// Mocked inventories must never consult the operator's pending recovery state.
function updatePlugins(options) {
  const home = options.codexHome || temporary();
  try {
    return runUpdatePlugins({ ...options, codexHome: home });
  } finally {
    if (!options.codexHome) rmSync(home, { recursive: true, force: true });
  }
}

test("refuses overlapping updaters and schedule changes while an owner is alive", () => {
  const home = temporary();
  const release = acquireUpdateLock(home);
  try {
    assert.throws(() => acquireUpdateLock(home), /Another updater is running/);
    assert.throws(
      () => assertNoUpdateOwner(home),
      /Another updater is running/,
    );
    assert.equal(readdirSync(join(home, ".plugin-update-lock")).length, 1);
    release();
    assertNoUpdateOwner(home);
    const releaseNext = acquireUpdateLock(home);
    releaseNext();
  } finally {
    release();
    rmSync(home, { recursive: true, force: true });
  }
});

test("a terminated updater leaves a dead claim that the next run removes", () => {
  const home = temporary();
  const moduleUrl = new URL("../update-plugins.ts", import.meta.url).href;
  try {
    assert.throws(
      () =>
        execFileSync(process.execPath, ["--input-type=module", "-"], {
          input: `import {acquireUpdateLock} from ${JSON.stringify(moduleUrl)}; acquireUpdateLock(${JSON.stringify(home)}); process.kill(process.pid, "SIGTERM");`,
          stdio: ["pipe", "ignore", "ignore"],
        }),
      (error) => error.signal === "SIGTERM",
    );
    assert.equal(readdirSync(join(home, ".plugin-update-lock")).length, 1);
    assertNoUpdateOwner(home);
    assert.equal(readdirSync(join(home, ".plugin-update-lock")).length, 0);
    const release = acquireUpdateLock(home);
    release();
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("an incomplete remote inventory warning fails even when Codex exits successfully", () => {
  const root = temporary();
  const savedPath = process.env.PATH;
  try {
    writeFileSync(
      join(root, "codex"),
      `#!${process.execPath}\nconsole.error("Warning: failed to list remote marketplace plugins: authentication unavailable"); console.log('{"installed":[],"available":[]}');`,
      { mode: 0o755 },
    );
    process.env.PATH = `${root}:${savedPath}`;
    assert.throws(
      () => cli(["plugin", "list", "--json"]),
      /Incomplete plugin inventory.*authentication unavailable/,
    );
    writeFileSync(
      join(root, "codex"),
      `#!${process.execPath}\nconsole.error("Warning: unrelated advisory"); console.log('{"installed":[],"available":[]}');`,
    );
    assert.deepEqual(cli(["plugin", "list", "--json"]), {
      installed: [],
      available: [],
    });
  } finally {
    process.env.PATH = savedPath;
    rmSync(root, { recursive: true, force: true });
  }
});

test("recycled PIDs, including a root-owned process, do not keep stale claims alive", () => {
  const home = temporary();
  const root = join(home, ".plugin-update-lock");
  try {
    mkdirSync(root);
    for (const pid of [1, process.pid])
      mkdirSync(
        join(
          root,
          `${pid}-${"0".repeat(64)}-00000000-0000-0000-0000-000000000000`,
        ),
      );
    assertNoUpdateOwner(home);
    assert.deepEqual(readdirSync(root), []);
    const release = acquireUpdateLock(home);
    release();
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("recovers a disabled preference after termination inside plugin install", () => {
  const home = temporary();
  const config = join(home, "config.toml");
  const pending = join(home, ".plugin-update-disabled.json");
  const entry = plugin("off", "fixture", false, "local");
  const moduleUrl = new URL("../update-plugins.ts", import.meta.url).href;
  const logs = [];
  try {
    writeFileSync(config, '[plugins."off@fixture"]\nenabled = false\n');
    assert.throws(
      () =>
        execFileSync(process.execPath, ["--input-type=module", "-"], {
          input: `import {updatePlugins} from ${JSON.stringify(moduleUrl)};
        import {writeFileSync} from 'node:fs';
        updatePlugins({codexHome:${JSON.stringify(home)},log(){},run(args){
          if(args[1]==='list')return {installed:[${JSON.stringify(entry)}]};
          writeFileSync(${JSON.stringify(config)}, '[plugins."off@fixture"]\\nenabled = true\\n');
          process.kill(process.pid,'SIGTERM');
        }});`,
          stdio: ["pipe", "ignore", "ignore"],
        }),
      (error) => error.signal === "SIGTERM",
    );
    assert.match(readFileSync(config, "utf8"), /enabled = true/);
    assert.equal(JSON.parse(readFileSync(pending, "utf8")), entry.pluginId);
    const run = (args) => {
      if (args[1] === "list")
        return {
          installed: [
            {
              ...entry,
              enabled: readFileSync(config, "utf8").includes("enabled = true"),
            },
          ],
        };
      assert.equal(JSON.parse(readFileSync(pending, "utf8")), entry.pluginId);
      writeFileSync(config, '[plugins."off@fixture"]\nenabled = true\n');
      return { pluginId: entry.pluginId, version: "2.0.0" };
    };
    assert.equal(
      updatePlugins({ run, codexHome: home, log: (m) => logs.push(m) }),
      0,
    );
    assert.match(readFileSync(config, "utf8"), /enabled = false/);
    assert.equal(existsSync(pending), false);
    assert.ok(
      logs.some((m) => m.includes("Recovered disabled setting: off@fixture")),
    );
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("pending recovery is untouched by dry-run and fails closed when restoration cannot finish", () => {
  const home = temporary();
  const pending = join(home, ".plugin-update-disabled.json");
  const entry = plugin("off", "fixture", true, "local");
  const calls = [];
  const run = (args) => {
    calls.push(args);
    return { installed: [entry] };
  };
  try {
    writeFileSync(pending, JSON.stringify(entry.pluginId));
    assert.equal(
      updatePlugins({ run, codexHome: home, dryRun: true, log() {} }),
      0,
    );
    assert.equal(existsSync(pending), true);
    assert.throws(
      () => updatePlugins({ run, codexHome: home, log() {} }),
      /Missing config while preserving/,
    );
    assert.equal(existsSync(pending), true);
    assert.ok(calls.every((args) => args[1] === "list"));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("a removed plugin does not block pending recovery or updates of remaining plugins", () => {
  const home = temporary();
  const pending = join(home, ".plugin-update-disabled.json");
  const entry = plugin("on", "fixture", true, "local");
  let installs = 0;
  try {
    writeFileSync(pending, JSON.stringify("removed@fixture"));
    const run = (args) =>
      args[1] === "list"
        ? { installed: [entry] }
        : (installs++, { pluginId: entry.pluginId, version: "2.0.0" });
    assert.equal(updatePlugins({ run, codexHome: home, log() {} }), 0);
    assert.equal(installs, 1);
    assert.equal(existsSync(pending), false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("implicit marketplace plugins delegate to native add without registration metadata", () => {
  const entries = ["local", "git", "git-subdir", "npm"].map((source) => ({
    ...plugin(source, "personal", true, "local"),
    marketplaceSource: undefined,
    source: { source },
  }));
  const installed = [];
  const run = (args) =>
    args[1] === "list"
      ? { installed: entries }
      : (installed.push(args[2]), { pluginId: args[2], version: "2.0.0" });
  assert.equal(updatePlugins({ run, log() {} }), 0);
  assert.deepEqual(
    installed,
    entries.map((entry) => entry.pluginId),
  );
});

test("Codex receives the same absolute home when CODEX_HOME is relative", () => {
  const root = temporary();
  const savedPath = process.env.PATH;
  const savedHome = process.env.CODEX_HOME;
  try {
    writeFileSync(
      join(root, "codex"),
      `#!${process.execPath}\nconsole.log(JSON.stringify({home:process.env.CODEX_HOME}));`,
      { mode: 0o755 },
    );
    process.env.PATH = `${root}:${savedPath}`;
    process.env.CODEX_HOME = "relative-plugin-test-home";
    assert.equal(
      cli(["plugin", "list", "--json"]).home,
      join(process.cwd(), "relative-plugin-test-home"),
    );
  } finally {
    process.env.PATH = savedPath;
    if (savedHome === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = savedHome;
    rmSync(root, { recursive: true, force: true });
  }
});

test("skips disabled account-managed plugins without attempting an install or local config edit", () => {
  const plugins = [
    {
      ...plugin("off", "account", false, "remote"),
      source: { source: "remote", id: "remote-off" },
      marketplaceSource: undefined,
    },
    {
      ...plugin("on", "account", true, "remote"),
      source: { source: "remote", id: "remote-on" },
      marketplaceSource: undefined,
    },
    plugin("local", "workspace", true, "local"),
  ];
  const calls = [],
    output = [];
  assert.equal(
    updatePlugins({
      log: (line) => output.push(line),
      run(args) {
        calls.push(args);
        if (args[1] === "list") return { installed: plugins };
        assert.notEqual(
          args[2],
          "off@account",
          "install would enable this plugin on the server",
        );
        return { pluginId: args[2], version: "2.0.0" };
      },
    }),
    0,
  );
  assert.deepEqual(
    calls.filter((a) => a[1] === "add").map((a) => a[2]),
    ["on@account", "local@workspace"],
  );
  assert.ok(output.some((line) => line.includes("SKIPPED: off@account")));
  assert.ok(output.some((line) => line.includes("1 skipped")));
});

test("a null version remains an unknown version and does not block other installed plugins", () => {
  const plugins = [
    { ...plugin("unknown", "account", true, "remote"), version: null },
    plugin("known", "repo"),
  ];
  const calls = [];
  assert.equal(
    updatePlugins({
      log() {},
      run(args) {
        calls.push(args);
        if (args[1] === "list") return { installed: plugins };
        if (args[1] === "marketplace") return { errors: [] };
        return { pluginId: args[2], version: "2.0.0" };
      },
    }),
    0,
  );
  assert.deepEqual(
    calls.filter((a) => a[1] === "add").map((a) => a[2]),
    plugins.map((p) => p.pluginId),
  );
});

for (const quote of ["'''", '"""']) {
  test(`disabled restoration ignores plugin-looking text inside ${quote} multiline strings`, () => {
    const home = temporary(),
      path = join(home, "config.toml");
    const prompt = `instructions = ${quote}\n[plugins."off@example"]\nenabled = true\n${quote}\n\n`;
    const before = `${prompt}[plugins."off@example"]\nnotes = ${quote}\n[another.fake.table]\nenabled = true\n${quote}\nenabled = true\n`;
    try {
      writeFileSync(path, before);
      restoreDisabled(path, "off@example");
      assert.equal(
        readFileSync(path, "utf8"),
        `${before.slice(0, -"enabled = true\n".length)}enabled = false\n`,
      );
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
}

for (const enabledKey of ["enabled", '"enabled"', "'enabled'"]) {
  test(`restores ${enabledKey} after multiline arrays and comments containing quote delimiters`, () => {
    const root = temporary(),
      path = join(root, "config.toml");
    const before = `# ''' \"\"\" ignored delimiters\n[plugins.'off@example']\nvalues = [\n  [1],\n  [2],\n]\n${enabledKey} = true\n`;
    try {
      writeFileSync(path, before);
      restoreDisabled(path, "off@example");
      assert.equal(
        readFileSync(path, "utf8"),
        before.replace(`${enabledKey} = true`, `${enabledKey} = false`),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test("the CLI executes when invoked through a symlink", () => {
  const root = temporary();
  try {
    const link = join(root, "updater.ts");
    symlinkSync(
      fileURLToPath(new URL("../update-plugins.ts", import.meta.url)),
      link,
    );
    const output = execFileSync(process.execPath, [link, "--help"], {
      encoding: "utf8",
    });
    assert.match(output, /Usage: node scripts\/update-plugins\.ts/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("importing from stdin does not run the CLI or require a real argv path", () => {
  const url = new URL("../update-plugins.ts", import.meta.url).href;
  const output = execFileSync(process.execPath, ["--input-type=module", "-"], {
    input: `await import(${JSON.stringify(url)}); console.log("imported");`,
    encoding: "utf8",
  });
  assert.equal(output.trim(), "imported");
});

test("discovers every installed plugin across Git, local and remote sources, once per Git marketplace", () => {
  const plugins = [
    plugin("one", "arbitrary"),
    plugin("two", "arbitrary"),
    plugin("local", "workspace", true, "local"),
    plugin("remote", "managed", true, "remote"),
  ];
  const calls = [];
  const code = updatePlugins({
    log() {},
    run(args) {
      calls.push(args);
      if (args[1] === "list") return { installed: plugins };
      if (args[1] === "marketplace") return { errors: [] };
      return { pluginId: args[2], version: "2.0.0" };
    },
  });
  assert.equal(code, 0);
  assert.deepEqual(
    calls.filter((a) => a[1] === "marketplace"),
    [["plugin", "marketplace", "upgrade", "arbitrary", "--json"]],
  );
  assert.deepEqual(
    calls.filter((a) => a[1] === "add").map((a) => a[2]),
    plugins.map((p) => p.pluginId),
  );
});

test("dry run reads inventory but never refreshes or installs anything", () => {
  const calls = [];
  assert.equal(
    updatePlugins({
      dryRun: true,
      log() {},
      run(args) {
        calls.push(args);
        return { installed: [plugin("off", "anything", false)] };
      },
    }),
    0,
  );
  assert.deepEqual(calls, [["plugin", "list", "--json"]]);
});

test("continues after an individual failure, reports it and exits nonzero", () => {
  const calls = [];
  const output = [];
  const plugins = [plugin("bad", "example"), plugin("good", "example")];
  assert.equal(
    updatePlugins({
      log: (line) => output.push(line),
      run(args) {
        calls.push(args);
        if (args[1] === "list") return { installed: plugins };
        if (args[1] === "marketplace") return { errors: [] };
        if (args[2] === "bad@example") throw new Error("network unavailable");
        return { pluginId: args[2], version: "2.0.0" };
      },
    }),
    1,
  );
  assert.ok(calls.some((a) => a[2] === "good@example"));
  assert.ok(output.some((line) => line.includes("network unavailable")));
});

test("failed marketplace prevents stale installs there but does not block other marketplaces", () => {
  const calls = [];
  const plugins = [plugin("bad", "broken"), plugin("good", "healthy")];
  assert.equal(
    updatePlugins({
      log() {},
      run(args) {
        calls.push(args);
        if (args[1] === "list") return { installed: plugins };
        if (args[1] === "marketplace")
          return { errors: args[3] === "broken" ? ["offline"] : [] };
        return { pluginId: args[2], version: "2.0.0" };
      },
    }),
    1,
  );
  assert.deepEqual(
    calls.filter((a) => a[1] === "add").map((a) => a[2]),
    ["good@healthy"],
  );
});

test("restores a disabled plugin after a CLI failure that already re-enabled it", () => {
  const home = temporary();
  const path = join(home, "config.toml");
  const before =
    'model = "unchanged"\n\n[plugins."off@example"]\nenabled = false # preference\n\n[plugins."other@example"]\nenabled = true\n';
  const plugins = [plugin("off", "example", false)];
  try {
    writeFileSync(path, before);
    assert.equal(
      updatePlugins({
        codexHome: home,
        log() {},
        run(args) {
          if (args[1] === "list") return { installed: plugins };
          if (args[1] === "marketplace") return { errors: [] };
          writeFileSync(path, before.replace("false", "true"));
          throw new Error("failed after writing config");
        },
      }),
      1,
    );
    assert.equal(readFileSync(path, "utf8"), before);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("restores only the target enabled line and preserves nested plugin settings", () => {
  const home = temporary();
  const path = join(home, "config.toml");
  const before =
    '[plugins."off@example"]\nenabled = true\nother = true\n[plugins."off@example".mcp_servers.docs]\nenabled = true\n';
  try {
    writeFileSync(path, before, { mode: 0o600 });
    restoreDisabled(path, "off@example");
    assert.equal(
      readFileSync(path, "utf8"),
      before.replace("enabled = true", "enabled = false"),
    );
    assert.throws(
      () => restoreDisabled(path, "missing@example"),
      /Cannot find/,
    );
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("invalid inventories and arguments fail before any mutation", () => {
  assert.throws(() => inventory({}), /Invalid/);
  assert.throws(
    () =>
      inventory({ installed: [plugin("one", "two"), plugin("one", "two")] }),
    /duplicate/,
  );
  assert.throws(
    () =>
      inventory({
        installed: [{ ...plugin("one", "two"), pluginId: "--bad" }],
      }),
    /Invalid/,
  );
  assert.throws(() => main(["--unknown"]), /Usage/);
  assert.throws(() => main(["--dry-run", "--install-schedule"]), /Usage/);
});

test("final verification catches a changed enabled setting", () => {
  let lists = 0;
  assert.equal(
    updatePlugins({
      log() {},
      run(args) {
        if (args[1] === "list")
          return {
            installed: [plugin("one", "local", ++lists === 1, "local")],
          };
        return { pluginId: args[2], version: "2.0.0" };
      },
    }),
    1,
  );
});

test("daily LaunchAgent preserves executable paths, PATH and custom CODEX_HOME with XML escaping", () => {
  const plist = schedulePlist(
    "/repo/with & spaces/update.ts",
    "/node path/node",
    "/bin:<&>",
    "/custom/home",
    "/logs/plugin.log",
  );
  assert.match(plist, /<integer>86400<\/integer>/);
  assert.match(plist, /<key>RunAtLoad<\/key><true\/>/);
  assert.match(plist, /with &amp; spaces/);
  assert.match(plist, /<string>\/node path\/node<\/string>/);
  assert.match(plist, /\/bin:&lt;&amp;&gt;/);
  assert.match(plist, /<key>CODEX_HOME<\/key><string>\/custom\/home<\/string>/);
  if (process.platform === "darwin") {
    const root = temporary();
    try {
      const path = join(root, "updater.plist");
      writeFileSync(path, plist);
      execFileSync("plutil", ["-lint", path], { stdio: "ignore" });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
});

test("real Codex refreshes enabled and disabled local plugins using an isolated CODEX_HOME", (t) => {
  try {
    execFileSync("codex", ["plugin", "add", "--help"], { stdio: "ignore" });
  } catch {
    t.skip("codex plugin CLI unavailable");
    return;
  }
  const root = temporary();
  const home = join(root, "home");
  const market = join(root, "market");
  const env = { ...process.env, CODEX_HOME: home };
  const run = (args) =>
    JSON.parse(
      execFileSync("codex", args, { env, encoding: "utf8", timeout: 30_000 }),
    );
  try {
    mkdirSync(home);
    mkdirSync(join(market, ".agents", "plugins"), { recursive: true });
    const plugins = ["on", "off"];
    writeFileSync(
      join(market, ".agents", "plugins", "marketplace.json"),
      JSON.stringify({
        name: "update-fixture",
        plugins: plugins.map((name) => ({
          name,
          source: { source: "local", path: `./plugins/${name}` },
          policy: { installation: "AVAILABLE", authentication: "ON_INSTALL" },
        })),
      }),
    );
    for (const name of plugins) {
      mkdirSync(join(market, "plugins", name, ".codex-plugin"), {
        recursive: true,
      });
      writeFileSync(
        join(market, "plugins", name, ".codex-plugin", "plugin.json"),
        JSON.stringify({
          name,
          version: "1.0.0",
          description: "Temporary update fixture",
        }),
      );
    }
    run(["plugin", "marketplace", "add", market, "--json"]);
    for (const name of plugins)
      run(["plugin", "add", `${name}@update-fixture`, "--json"]);
    restoreDisabled(join(home, "config.toml"), "off@update-fixture");
    const config = join(home, "config.toml");
    writeFileSync(
      config,
      readFileSync(config, "utf8").replace(
        '[plugins."off@update-fixture"]',
        "[plugins.'off@update-fixture'] # retain literal quoting",
      ),
    );
    for (const name of plugins)
      writeFileSync(
        join(market, "plugins", name, ".codex-plugin", "plugin.json"),
        JSON.stringify({
          name,
          version: "2.0.0",
          description: "Temporary update fixture",
        }),
      );
    assert.equal(updatePlugins({ run, codexHome: home, log() {} }), 0);
    const after = inventory(run(["plugin", "list", "--json"]));
    for (const name of plugins) {
      assert.equal(
        after.find((p) => p.pluginId === `${name}@update-fixture`).version,
        "2.0.0",
      );
      assert.ok(
        existsSync(
          join(
            home,
            "plugins",
            "cache",
            "update-fixture",
            name,
            "2.0.0",
            ".codex-plugin",
            "plugin.json",
          ),
        ),
      );
    }
    assert.equal(
      after.find((p) => p.pluginId === "off@update-fixture").enabled,
      false,
    );
    assert.equal(
      after.find((p) => p.pluginId === "on@update-fixture").enabled,
      true,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
