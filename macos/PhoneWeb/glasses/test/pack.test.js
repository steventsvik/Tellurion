import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { resolveOrigin } from "../link.js";

const script = join(dirname(fileURLToPath(import.meta.url)), "..", "pack", "pack.sh");

function files(origin, version = "1.0.0") {
  const folder = mkdtempSync(join(tmpdir(), "glasses-pack-"));
  execFileSync("sh", [script, "--files", folder, origin, version]);
  return folder;
}

test("the package is made for one Mac's address and nothing else", () => {
  const folder = files("https://my-mac.example.ts.net:8443/", "1.2.3");
  try {
    const manifest = JSON.parse(readFileSync(join(folder, "app.json"), "utf8"));
    assert.match(manifest.package_id, /^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$/);
    assert.ok(manifest.name.length <= 20);
    assert.equal(manifest.version, "1.2.3");
    assert.equal(manifest.edition, "202601");
    assert.equal(manifest.min_sdk_version, "0.0.16");
    assert.ok(existsSync(join(folder, "app", manifest.entrypoint)));
    assert.deepEqual(manifest.permissions.map((p) => p.name), ["network", "g2-microphone"]);
    assert.deepEqual(manifest.permissions[0].whitelist, ["https://my-mac.example.ts.net:8443"]);
    for (const permission of manifest.permissions) assert.ok(permission.desc.length >= 1 && permission.desc.length <= 300);
    assert.deepEqual(manifest.supported_languages, ["en"]);

    const config = readFileSync(join(folder, "app", "config.js"), "utf8");
    const origin = /TELLURION_ORIGIN = "([^"]*)"/.exec(config)[1];
    assert.deepEqual(resolveOrigin(origin, { protocol: "file:", host: "" }), { origin: "https://my-mac.example.ts.net:8443", packaged: true });

    const packed = readdirSync(join(folder, "app")).sort();
    assert.ok(packed.includes("app.js") && packed.includes("vendor"));
    assert.ok(!packed.includes("test") && !packed.includes("pack") && !packed.includes("package.json"));
    // Nothing but the address is written in: no token, no code.
    assert.doesNotMatch(config, /token|pair/i);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("anything but an https address is turned away", () => {
  for (const bad of ["", "http://my-mac.example", "https://my-mac.example/path", "https://Mac.Example", "https://x.example\"; rm", "mac.example"]) {
    assert.equal(spawnSync("sh", [script, "--files", join(tmpdir(), "glasses-pack-refused"), bad]).status, 1, bad);
  }
  assert.equal(spawnSync("sh", [script, "--files", join(tmpdir(), "glasses-pack-refused"), "https://mac.example", "one"]).status, 1);
  assert.equal(existsSync(join(tmpdir(), "glasses-pack-refused", "app.json")), false);
});
