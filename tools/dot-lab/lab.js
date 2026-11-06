// Dot Lab UI — scaffolding only; nothing in the pet imports this.
import { KNOBS, MODES, STATES, STATE_LABELS, DEFAULTS, FRAME_W, FRAME_H, normalize, reroll, renderFrame, renderSheet } from "./dot.js";

const $ = (s) => document.querySelector(s);
const LOCAL_KEY = "dot-lab.saved";
let config = normalize(JSON.parse(localStorage.getItem("dot-lab.current") || "null") || DEFAULTS);
let locked = new Set(JSON.parse(localStorage.getItem("dot-lab.locked") || "[]"));
let previewState = "idle";
let frame = 0;
let lastExport = null;
const hasServer = location.protocol.startsWith("http");

// --- Panel ---------------------------------------------------------------
const tabs = $("#tabs");
for (const m of MODES) {
  const b = Object.assign(document.createElement("button"), { textContent: m });
  b.onclick = () => set({ mode: m });
  b.dataset.mode = m;
  tabs.append(b);
}

const rows = new Map();
const groups = {};
for (const k of KNOBS) {
  if (!groups[k.group]) {
    const fs = document.createElement("fieldset");
    fs.innerHTML = `<legend>${k.group}</legend>`;
    $("#knobs").append(fs);
    groups[k.group] = fs;
  }
  const row = document.createElement("div");
  row.className = "row";
  const lock = Object.assign(document.createElement("button"), { className: "lock", textContent: "🔒" });
  lock.dataset.key = k.key;
  lock.setAttribute("aria-label", `Lock ${k.label}`);
  const label = Object.assign(document.createElement("label"), { textContent: k.label, htmlFor: `k-${k.key}` });
  row.append(lock, label);
  if (k.type === "select") {
    const sel = document.createElement("select");
    sel.id = `k-${k.key}`;
    for (const o of k.options) sel.append(new Option(o, o));
    sel.onchange = () => set({ [k.key]: sel.value });
    row.append(sel);
    rows.set(k.key, { row, input: sel });
  } else {
    const input = Object.assign(document.createElement("input"), { type: "range", id: `k-${k.key}`, min: k.min, max: k.max, step: k.step });
    const out = document.createElement("output");
    input.oninput = () => set({ [k.key]: Number(input.value) });
    row.append(input, out);
    rows.set(k.key, { row, input, out });
  }
  groups[k.group].append(row);
}

document.querySelectorAll(".lock").forEach((b) => {
  b.onclick = () => {
    const key = b.dataset.key;
    locked.has(key) ? locked.delete(key) : locked.add(key);
    localStorage.setItem("dot-lab.locked", JSON.stringify([...locked]));
    syncPanel();
  };
});

function syncPanel() {
  for (const b of tabs.children) b.setAttribute("aria-pressed", String(b.dataset.mode === config.mode));
  for (const k of KNOBS) {
    const { row, input, out } = rows.get(k.key);
    input.value = config[k.key];
    if (out) out.textContent = Number(config[k.key]).toFixed(k.step < 1 ? (k.step < 0.05 ? 3 : 2) : 0);
    row.classList.toggle("off", !!k.modes && !k.modes.includes(config.mode));
  }
  document.querySelectorAll(".lock").forEach((b) => b.setAttribute("aria-pressed", String(locked.has(b.dataset.key))));
  $("#seed").value = config.seed;
  if (!$("#name").dataset.touched) $("#name").value = `${config.mode}-${config.seed}`;
}

let pending = false;
function set(patch) {
  config = normalize({ ...config, ...patch });
  localStorage.setItem("dot-lab.current", JSON.stringify(config));
  syncPanel();
  if (!pending) { pending = true; requestAnimationFrame(() => { pending = false; draw(); }); }
}

// --- Canvases ------------------------------------------------------------
const stage = $("#stage");
const sctx = stage.getContext("2d");
const stripCanvases = STATES.map((st) => {
  const b = document.createElement("button");
  const cv = Object.assign(document.createElement("canvas"), { width: FRAME_W, height: FRAME_H });
  b.append(cv, STATE_LABELS[st]);
  b.onclick = () => { previewState = st; syncStrip(); draw(); };
  b.dataset.state = st;
  $("#strip").append(b);
  return [st, cv.getContext("2d")];
});
function syncStrip() {
  for (const b of $("#strip").children) b.setAttribute("aria-pressed", String(b.dataset.state === previewState));
}

function draw() {
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  if (stage.width !== 576 * dpr) { stage.width = 576 * dpr; stage.height = 624 * dpr; }
  sctx.clearRect(0, 0, stage.width, stage.height);
  renderFrame(sctx, config, previewState, frame, 3 * dpr, 3);
  for (const [st, g] of stripCanvases) {
    g.clearRect(0, 0, FRAME_W, FRAME_H);
    renderFrame(g, config, st, frame, 1, 3);
  }
}

// Wall-clock 6 fps (the pet's fixed sheet rate): frame index comes from elapsed time,
// so a slow or throttled tick never stretches the loop.
const FPS = 6;
const t0 = performance.now();
(function tick(now) {
  const f = Math.floor(((now - t0) / 1000) * FPS) % 8;
  if (f !== frame) { frame = f; draw(); }
  requestAnimationFrame(tick);
})(t0);

stage.addEventListener("click", (e) => {
  const seed = (Math.random() * 2 ** 32) >>> 0;
  set(e.shiftKey ? { seed } : reroll(config, seed, locked));
});
$("#reroll").onclick = () => set(reroll(config, (Math.random() * 2 ** 32) >>> 0, locked));
$("#seed").onchange = (e) => set({ seed: Number(e.target.value) >>> 0 });
$("#name").oninput = (e) => { e.target.dataset.touched = "1"; };

// --- Save / rail / export ------------------------------------------------
const status = (msg) => { $("#status").textContent = msg; };
const slug = () => ($("#name").value || `${config.mode}-${config.seed}`).toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48) || "dot";

async function api(path, body) {
  const res = await fetch(path, { method: body ? "POST" : "GET", headers: { "content-type": "application/json" }, body: body && JSON.stringify(body) });
  const json = await res.json();
  if (!res.ok) throw new Error(json.error || res.statusText);
  return json;
}

async function loadSaved() {
  if (hasServer) { try { return (await api("/api/configs")).configs; } catch {} }
  return JSON.parse(localStorage.getItem(LOCAL_KEY) || "[]");
}

async function renderRail() {
  const rail = $("#rail");
  rail.replaceChildren();
  for (const { name, config: saved } of await loadSaved()) {
    const b = document.createElement("button");
    const cv = Object.assign(document.createElement("canvas"), { width: 96, height: 104 });
    renderFrame(cv.getContext("2d"), saved, "idle", 0, 0.5, 3);
    b.append(cv, name);
    b.title = `Apply ${name}`;
    b.onclick = () => { $("#name").value = name; $("#name").dataset.touched = "1"; set(saved); status(`Applied ${name}`); };
    rail.append(b);
  }
}

$("#save").onclick = async () => {
  const name = slug();
  const json = JSON.stringify(config, null, 2);
  try { await navigator.clipboard.writeText(json); } catch {}
  try {
    if (!hasServer) throw new Error("no server");
    const { path } = await api("/api/save", { name, config });
    status(`Saved → ${path} (+ clipboard)`);
  } catch {
    const list = (JSON.parse(localStorage.getItem(LOCAL_KEY) || "[]")).filter((s) => s.name !== name);
    localStorage.setItem(LOCAL_KEY, JSON.stringify([{ name, config }, ...list]));
    status(`Saved ${name} to browser storage + clipboard (run serve.mjs to write files)`);
  }
  renderRail();
};

$("#export").onclick = async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true;
  status("Rendering 1536×1872 spritesheet…");
  await new Promise((r) => setTimeout(r, 30));
  try {
    const sheet = renderSheet(config, 2);
    const png = sheet.toDataURL("image/png");
    if (!hasServer) {
      Object.assign(document.createElement("a"), { href: png, download: `copilot-dot-${slug()}.png` }).click();
      status("Downloaded spritesheet (run serve.mjs to write a full pack)");
      return;
    }
    const res = await api("/api/export", { name: slug(), config, png });
    lastExport = res.slug;
    status(`Exported → ${res.path} (${res.dims})`);
  } catch (err) {
    status(`Export failed: ${err.message}`);
  } finally {
    btn.disabled = false;
  }
};

$("#install").onclick = async () => {
  if (!hasServer) return status("Install needs serve.mjs");
  try {
    const res = await api("/api/install", { slug: lastExport || `copilot-dot-${slug()}` });
    status(res.message);
  } catch (err) {
    status(`Install failed: ${err.message} — export first`);
  }
};

syncPanel();
syncStrip();
draw();
renderRail();
