#!/usr/bin/env node
// Dot Lab dev server (localhost only). Serves the lab and persists decisions:
//   POST /api/save     → tools/dot-lab/configs/<name>.json
//   POST /api/export   → assets/petdex/copilot-dot-<name>/{spritesheet.png,pet.json,dot-config.json}
//   POST /api/install  → copies a pack to ~/.copilot-pet/pets/<slug>/ (+ activePet if the
//                        installed extension's config dir exists)
// Usage: node tools/dot-lab/serve.mjs [port]
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const labDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.resolve(labDir, "../..");
const configsDir = path.join(labDir, "configs");
const packsDir = path.join(repoDir, "assets", "petdex");
const petsDir = path.join(os.homedir(), ".copilot-pet", "pets");
const extConfig = path.join(os.homedir(), ".copilot", "extensions", "copilot-pet", "config.json");
const port = Number(process.argv[2] || process.env.PORT || 5178);
const SLUG_RE = /^[a-z0-9_-]{1,64}$/;
const SHEET = { w: 1536, h: 1872 };
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".png": "image/png" };

const rel = (p) => path.relative(repoDir, p);
const titleCase = (s) => s.replace(/[-_]+/g, " ").replace(/\b\w/g, (m) => m.toUpperCase());

function readBody(req, limit = 25 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(new Error("body too large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); } catch { reject(new Error("invalid JSON")); }
    });
    req.on("error", reject);
  });
}

function pngSize(buf) {
  const sig = "89504e470d0a1a0a";
  if (buf.length < 24 || buf.subarray(0, 8).toString("hex") !== sig) throw new Error("not a PNG");
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n");
  fs.renameSync(tmp, file);
}

function checkSlug(s) {
  if (typeof s !== "string" || !SLUG_RE.test(s)) throw new Error("name must match [a-z0-9_-]");
  return s;
}

// Writes must come from the lab itself. Cross-site pages can't send application/json
// without a CORS preflight (never answered here), and the Host check blocks DNS rebinding.
function isTrusted(req) {
  const host = req.headers.host || "";
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(host)) return false;
  if (req.method !== "POST") return true;
  const origin = req.headers.origin;
  if (origin && origin !== `http://${host}`) return false;
  return (req.headers["content-type"] || "").startsWith("application/json");
}

function readSavedConfig(file) {
  try { return JSON.parse(fs.readFileSync(path.join(configsDir, file), "utf8")); } catch { return null; }
}

const routes = {
  "GET /api/configs": () => {
    let files = [];
    try { files = fs.readdirSync(configsDir).filter((f) => f.endsWith(".json")); } catch {}
    const configs = files
      .map((f) => ({ f, t: fs.statSync(path.join(configsDir, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t)
      .map(({ f }) => ({ name: f.slice(0, -5), config: readSavedConfig(f) }))
      .filter((s) => s.config && typeof s.config === "object");
    return { configs };
  },
  "POST /api/save": ({ name, config }) => {
    const file = path.join(configsDir, `${checkSlug(name)}.json`);
    if (!config || typeof config !== "object") throw new Error("missing config");
    writeJson(file, config);
    return { path: rel(file) };
  },
  "POST /api/export": ({ name, config, png }) => {
    const slug = `copilot-dot-${checkSlug(name)}`;
    const buf = Buffer.from(String(png || "").replace(/^data:image\/png;base64,/, ""), "base64");
    const { w, h } = pngSize(buf);
    if (w !== SHEET.w || h !== SHEET.h) throw new Error(`spritesheet is ${w}x${h}, want ${SHEET.w}x${SHEET.h}`);
    const dir = path.join(packsDir, slug);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "spritesheet.png"), buf);
    writeJson(path.join(dir, "pet.json"), {
      id: slug,
      displayName: `Copilot Dot · ${titleCase(name)}`,
      description: "A plush, Dot-style Copilot companion generated with Dot Lab.",
      spritesheetPath: "spritesheet.png",
    });
    writeJson(path.join(dir, "dot-config.json"), config);
    return { slug, path: rel(dir), dims: `${w}x${h}` };
  },
  "POST /api/install": ({ slug }) => {
    checkSlug(slug);
    const src = path.join(packsDir, slug);
    if (!fs.existsSync(path.join(src, "pet.json"))) throw new Error(`no exported pack at ${rel(src)}`);
    const dest = path.join(petsDir, slug);
    const staging = `${dest}.tmp-${process.pid}`;
    fs.rmSync(staging, { recursive: true, force: true });
    fs.mkdirSync(staging, { recursive: true });
    for (const f of ["pet.json", "spritesheet.png"]) fs.copyFileSync(path.join(src, f), path.join(staging, f));
    fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(staging, dest);
    if (fs.existsSync(path.dirname(extConfig))) {
      let cfg = {};
      if (fs.existsSync(extConfig)) cfg = JSON.parse(fs.readFileSync(extConfig, "utf8")) || {};
      cfg.activePet = slug;
      writeJson(extConfig, cfg);
      return { message: `Installed to ~/.copilot-pet/pets/${slug} and set activePet — the pet hot-reloads.` };
    }
    return { message: `Installed to ~/.copilot-pet/pets/${slug}. Switch with: pet_gallery use ${slug}` };
  },
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const send = (code, body, type = "application/json") => {
    res.writeHead(code, { "content-type": type, "cache-control": "no-store" });
    res.end(type === "application/json" ? JSON.stringify(body) : body);
  };
  const route = routes[`${req.method} ${url.pathname}`];
  if (!isTrusted(req)) return send(403, { error: "forbidden" });
  if (route) {
    try { send(200, route(req.method === "POST" ? await readBody(req) : {})); }
    catch (e) { send(400, { error: e.message }); }
    return;
  }
  if (req.method !== "GET") return send(405, { error: "method not allowed" });
  const file = path.join(labDir, path.normalize(url.pathname === "/" ? "/index.html" : url.pathname));
  if (!file.startsWith(labDir + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return send(404, { error: "not found" });
  send(200, fs.readFileSync(file), TYPES[path.extname(file)] || "application/octet-stream");
});

server.listen(port, "127.0.0.1", () => console.log(`Dot Lab → http://127.0.0.1:${server.address().port}/`));
