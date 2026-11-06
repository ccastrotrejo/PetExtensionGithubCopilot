// Run: node --test tools/dot-lab/dot-lab.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DEFAULTS, KNOBS, MODES, normalize, reroll, mulberry32 } from "./schema.js";

test("mulberry32 is deterministic per seed", () => {
  const a = mulberry32(42), b = mulberry32(42), c = mulberry32(43);
  const seqA = [a(), a(), a()];
  assert.deepEqual(seqA, [b(), b(), b()]);
  assert.notDeepEqual(seqA, [c(), c(), c()]);
  for (const v of seqA) assert.ok(v >= 0 && v < 1);
});

test("normalize fills defaults and clamps into knob bounds", () => {
  const c = normalize({ width: 9999, hue: -5, furLength: "nope", mode: "blob", prop: "hat", seed: -1 });
  const knob = (key) => KNOBS.find((k) => k.key === key);
  assert.equal(c.width, knob("width").max);
  assert.equal(c.hue, knob("hue").min);
  assert.equal(c.furLength, DEFAULTS.furLength);
  assert.equal(c.mode, DEFAULTS.mode);
  assert.equal(c.prop, DEFAULTS.prop);
  assert.equal(c.seed, 4294967295);
  assert.equal(c.eyeSize, DEFAULTS.eyeSize);
});

test("reroll is deterministic, stays in bounds, and honors locks", () => {
  const a = reroll(DEFAULTS, 1234), b = reroll(DEFAULTS, 1234);
  assert.deepEqual(a, b);
  assert.equal(a.seed, 1234);
  assert.ok(MODES.includes(a.mode));
  for (const k of KNOBS) if (k.type !== "select") assert.ok(a[k.key] >= k.min && a[k.key] <= k.max, k.key);

  const base = { ...DEFAULTS, hue: 7, mode: "star" };
  const locked = reroll(base, 99, new Set(["hue", "mode"]));
  assert.equal(locked.hue, 7);
  assert.equal(locked.mode, "star");
  // Locking one knob must not shift the rolls of the others.
  const free = reroll(base, 99);
  assert.equal(locked.width, free.width);
});

test("serve.mjs only accepts same-origin JSON writes from localhost", async (t) => {
  const server = spawn(process.execPath, [fileURLToPath(new URL("./serve.mjs", import.meta.url)), "0"]);
  t.after(() => server.kill());
  const base = await new Promise((resolve, reject) => {
    server.stdout.on("data", (d) => { const m = /http:\/\/127\.0\.0\.1:\d+/.exec(String(d)); if (m) resolve(m[0]); });
    server.on("exit", (code) => reject(new Error(`server exited ${code}`)));
  });
  const post = (headers, body = { name: "bad name!", config: {} }) =>
    fetch(`${base}/api/save`, { method: "POST", headers, body: JSON.stringify(body) });

  assert.equal((await fetch(`${base}/`)).status, 200);
  assert.equal((await fetch(`${base}/..%2f..%2fREADME.md`)).status, 404);
  assert.equal((await post({ "content-type": "text/plain" })).status, 403);
  assert.equal((await post({ "content-type": "application/json", origin: "https://evil.example" })).status, 403);
  // fetch() drops custom Host headers, so simulate DNS rebinding with http.request.
  const rebound = await new Promise((resolve, reject) => {
    const { hostname, port } = new URL(base);
    http.request({ hostname, port, path: "/", headers: { host: "evil.example" } }, (res) => { res.resume(); resolve(res.statusCode); })
      .on("error", reject).end();
  });
  assert.equal(rebound, 403);
  // Trusted request reaches validation (bad slug → 400, nothing written).
  assert.equal((await post({ "content-type": "application/json", origin: base })).status, 400);
  assert.equal((await fetch(`${base}/api/configs`)).status, 200);
});
