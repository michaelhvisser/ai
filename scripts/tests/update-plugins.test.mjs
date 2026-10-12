import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
  inventory,
  main,
  restoreDisabled,
  schedulePlist,
  updatePlugins,
} from "../update-plugins.ts";

const plugin = (name, marketplace, enabled = true, sourceType = "git") => ({
  pluginId: `${name}@${marketplace}`,
  marketplaceName: marketplace,
  enabled,
  version: "1.0.0",
  marketplaceSource: { sourceType },
});
const temporary = () => mkdtempSync(join(tmpdir(), "plugin-update-test-"));

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
