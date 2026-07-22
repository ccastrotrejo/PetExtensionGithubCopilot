// Extension: copilot-pet
// A native macOS desktop companion that reacts to GitHub Copilot activity.
// Spawns pet.swift (compiled on first load) and drives its mood via a polled state file.

import { joinSession } from "@github/copilot-sdk/extension";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const extDir = path.dirname(fileURLToPath(import.meta.url));
const petSrc = path.join(extDir, "pet.swift");
const petCoreSrc = path.join(extDir, "PetCore.swift");
const binDir = path.join(extDir, ".bin");
const petBin = path.join(binDir, "pet");

// Single source of truth for the mood protocol across the state-file seam.
// Mirrored by the `Mood` enum in PetCore.swift and documented in docs/state-protocol.md.
const MOOD = {
  greet: "greet", thinking: "thinking", working: "working", happy: "happy",
  worried: "worried", idle: "idle", sleeping: "sleeping",
  hidden: "hidden", quit: "quit",
};
const MOODS = {
  display: [MOOD.greet, MOOD.thinking, MOOD.working, MOOD.happy, MOOD.worried, MOOD.idle, MOOD.sleeping],
  control: [MOOD.hidden, MOOD.quit],
};

const stateDir = path.join(os.tmpdir(), "copilot-pet");
// One shared pet, but each session owns its own state file. The Swift pet reads
// every file in sessionsDir and arbitrates (see docs/state-protocol.md), so
// concurrent sessions no longer stomp one global file.
const sessionsDir = path.join(stateDir, "sessions");
const statePath = path.join(stateDir, "state.json"); // legacy path kept only to anchor pet's dir layout
const pidPath = path.join(stateDir, "pet.pid");
const logPath = path.join(stateDir, "pet.log");
// Optional user settings, read by both this extension and the pet. See docs/config.md.
const configPath = path.join(extDir, "config.json");

// A stable id for this controller process. One extension.mjs == one session.
const sessionId = randomUUID();
const sessionPath = path.join(sessionsDir, `${sessionId}.json`);

fs.mkdirSync(stateDir, { recursive: true });
fs.mkdirSync(sessionsDir, { recursive: true });
fs.mkdirSync(binDir, { recursive: true });

// Sweep session files whose controllers are long gone, so the dir stays small.
function pruneStaleSessions() {
  let names = [];
  try { names = fs.readdirSync(sessionsDir); } catch { return; }
  const now = Date.now();
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const full = path.join(sessionsDir, name);
    try {
      const s = JSON.parse(fs.readFileSync(full, "utf8"));
      if (now - (s.heartbeat || 0) > 60_000) fs.rmSync(full, { force: true });
    } catch {
      fs.rmSync(full, { force: true });
    }
  }
}
pruneStaleSessions();

let seq = 0;
let current = { mood: MOOD.greet, message: "", tool: "" };
let lastActivity = Date.now(); // timestamp of the last mood change (drives arbitration)

// Returns a warning string if config.json exists but isn't valid JSON, else null.
// The pet reads the file itself; this only surfaces obvious mistakes to the user.
function configWarning() {
  if (!fs.existsSync(configPath)) return null;
  try {
    JSON.parse(fs.readFileSync(configPath, "utf8"));
    return null;
  } catch (e) {
    return `config.json is not valid JSON (${e.message}); the pet is using defaults.`;
  }
}

function writeState() {
  const payload = JSON.stringify({
    id: sessionId,
    mood: current.mood,
    message: current.message,
    tool: current.tool,
    seq,
    ts: Date.now(),
    activity: lastActivity,
    heartbeat: Date.now(),
  });
  const tmp = `${sessionPath}.tmp`;
  fs.writeFileSync(tmp, payload);
  fs.renameSync(tmp, sessionPath); // atomic
}

function setMood(mood, message = "", tool = "") {
  // `tool` is the raw agent tool name; the pet categorises it (WorkActivity) to
  // pick a working-mood micro-animation. Non-working moods pass "" to clear it.
  current = { mood, message: String(message).slice(0, 48), tool: String(tool).slice(0, 40) };
  seq += 1;
  lastActivity = Date.now(); // a mood change is "activity"; heartbeats are not
  writeState();
}

function touchHeartbeat() {
  // Refresh heartbeat without changing mood or activity, so this session stays
  // "live" for the watchdog but doesn't win arbitration over a more recent one.
  writeState();
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
}

function readPid() {
  try {
    return parseInt(fs.readFileSync(pidPath, "utf8").trim(), 10);
  } catch {
    return 0;
  }
}

// Wait (up to timeoutMs) for a pid to exit — used on restart so we never spawn
// a second pet before the previous one has released its single-instance lock.
async function waitForExit(pid, timeoutMs) {
  if (!pid) return;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline && pidAlive(pid)) {
    await new Promise((r) => setTimeout(r, 50));
  }
}

function ensureCompiled() {
  const newestSrc = Math.max(
    fs.statSync(petSrc).mtimeMs,
    fs.statSync(petCoreSrc).mtimeMs,
  );
  const needsBuild = !fs.existsSync(petBin) || newestSrc > fs.statSync(petBin).mtimeMs;
  if (!needsBuild) return { ok: true };
  const res = spawnSync("swiftc", ["pet.swift", "PetCore.swift", "-o", ".bin/pet"], {
    cwd: extDir,
    encoding: "utf8",
    timeout: 120000,
  });
  if (res.status !== 0) {
    return { ok: false, error: (res.stderr || res.stdout || "swiftc failed").trim() };
  }
  return { ok: true };
}

function ensureRunning() {
  let pid = 0;
  try {
    pid = parseInt(fs.readFileSync(pidPath, "utf8").trim(), 10);
  } catch {}
  if (pidAlive(pid)) return { reused: true, pid };

  const out = fs.openSync(logPath, "a");
  const child = spawn(petBin, [statePath, configPath], {
    detached: true,
    stdio: ["ignore", out, out],
  });
  child.unref();
  fs.writeFileSync(pidPath, String(child.pid));
  return { reused: false, pid: child.pid };
}

const TOOL_LABELS = {
  bash: "running a command",
  view: "reading files",
  edit: "editing code",
  create: "writing a file",
  grep: "searching code",
  glob: "finding files",
  sql: "querying data",
  task: "delegating a task",
  web_fetch: "browsing the web",
  web_search: "searching the web",
};

function prettyTool(name = "") {
  const key = String(name).split("-").pop();
  return TOOL_LABELS[name] || TOOL_LABELS[key] || `using ${name}`;
}

// --- Boot the pet ---
// Greet de-dup now lives in the pure arbiter (PetCore.swift): a greet only
// plays on the 0→N live-session transition, so opening many sessions never
// triggers a chorus of "hi!"s. This process still greets on start; the pet
// decides whether to actually show it.
let hasGreeted = false;
let bootError = null;
const build = ensureCompiled();
if (!build.ok) {
  bootError = build.error;
} else {
  try {
    setMood(MOOD.greet); // write our session file *before* spawning the pet
    ensureRunning();
    hasGreeted = true;
  } catch (e) {
    bootError = e.message;
  }
}

// Remove this session's state file when the controller goes away, so it stops
// competing for the pet. Heartbeat staleness is the backstop if we're killed hard.
let cleanedUp = false;
function cleanupSession() {
  if (cleanedUp) return;
  cleanedUp = true;
  try { fs.rmSync(sessionPath, { force: true }); } catch {}
}
process.on("exit", cleanupSession);
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => { cleanupSession(); process.exit(0); });
}

// Refresh heartbeat so the pet knows the app/session is alive.
// When this extension process dies (app/session closed), the heartbeat goes
// stale and the pet self-terminates within ~12s.
const hb = setInterval(touchHeartbeat, 5000);
if (hb.unref) hb.unref();

const petControl = {
  name: "pet_control",
  description:
    "Control the Copilot desktop pet. Actions: mood (set a mood), say (show a message), show, hide, quit, restart.",
  parameters: {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: ["mood", "say", "show", "hide", "quit", "restart"],
        description: "What to do with the pet.",
      },
      mood: {
        type: "string",
        enum: MOODS.display,
        description: "Mood to set when action is 'mood'.",
      },
      message: { type: "string", description: "Speech-bubble text for 'mood' or 'say'." },
    },
    required: ["action"],
  },
  skipPermission: true,
  handler: async (args) => {
    const { action, mood, message } = args || {};
    switch (action) {
      case "mood":
        setMood(mood || MOOD.idle, message || "");
        return `Pet mood set to "${mood || MOOD.idle}".`;
      case "say":
        setMood(MOOD.thinking, message || "");
        return `Pet says: ${message || ""}`;
      case "show":
        setMood(MOOD.idle);
        return "Pet is visible.";
      case "hide":
        setMood(MOOD.hidden);
        return "Pet hidden.";
      case "quit":
        setMood(MOOD.quit);
        try { fs.rmSync(pidPath, { force: true }); } catch {}
        return "Pet dismissed.";
      case "restart": {
        const oldPid = readPid();
        setMood(MOOD.quit);
        await waitForExit(oldPid, 2000);   // let the old pet release its lock
        try { fs.rmSync(pidPath, { force: true }); } catch {}
        const b = ensureCompiled();
        if (!b.ok) return `Failed to recompile pet: ${b.error}`;
        ensureRunning();
        setMood(MOOD.greet);
        return "Pet restarted.";
      }
      default:
        return `Unknown action "${action}".`;
    }
  },
};

const session = await joinSession({
  tools: [petControl],
  hooks: {
    onSessionStart: async (input) => {
      // Greet once per process; never on a resume (which fires repeatedly).
      if (hasGreeted || input?.source === "resume") return;
      hasGreeted = true;
      setMood(MOOD.greet);
    },
    onUserPromptSubmitted: async () => { setMood(MOOD.thinking); },
    onPreToolUse: async (input) => {
      // Stay "working" across a whole run of tools; the label and the
      // tool-specific micro-behavior (see WorkActivity in PetCore.swift) change.
      if (input?.toolName === "pet_control") return;
      setMood(MOOD.working, prettyTool(input?.toolName), input?.toolName);
    },
    // No per-tool reaction on success: the pet keeps "working" until the turn
    // ends, so it doesn't flash "done!" between every tool call.
    onPostToolUseFailure: async () => { setMood(MOOD.worried); },
    onErrorOccurred: async () => { setMood(MOOD.worried); },
  },
});

// Turn finished: celebrate "done!" only if the pet was actually mid-task,
// otherwise just relax. Avoids a spurious "done!" at startup or while idle.
session.on("session.idle", () => {
  const wasBusy = current.mood === MOOD.working || current.mood === MOOD.thinking;
  setMood(wasBusy ? MOOD.happy : MOOD.idle);
});

if (bootError) {
  await session.log(`🐾 Copilot pet couldn't start: ${bootError}`, { level: "warning" });
} else {
  await session.log("🐾 Copilot pet is here — it reacts to what I'm doing.", { ephemeral: true });
  const warn = configWarning();
  if (warn) await session.log(`🐾 ${warn}`, { level: "warning" });
}
