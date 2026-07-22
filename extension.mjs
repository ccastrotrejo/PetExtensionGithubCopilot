// Extension: copilot-pet
// A native macOS desktop companion that reacts to GitHub Copilot activity.
// Spawns pet.swift (compiled on first load) and drives its mood via a polled state file.

import { joinSession } from "@github/copilot-sdk/extension";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const extDir = path.dirname(fileURLToPath(import.meta.url));
const petSrc = path.join(extDir, "pet.swift");
const binDir = path.join(extDir, ".bin");
const petBin = path.join(binDir, "pet");

// Single source of truth for the mood protocol across the state-file seam.
// Mirrored by the `Mood` enum in pet.swift and documented in docs/state-protocol.md.
const MOODS = {
  display: ["greet", "thinking", "working", "happy", "worried", "idle", "sleeping"],
  control: ["hidden", "quit"],
};

const stateDir = path.join(os.tmpdir(), "copilot-pet");
const statePath = path.join(stateDir, "state.json");
const pidPath = path.join(stateDir, "pet.pid");
const logPath = path.join(stateDir, "pet.log");

fs.mkdirSync(stateDir, { recursive: true });
fs.mkdirSync(binDir, { recursive: true });

// Keep seq monotonically increasing across reloads so a reused pet picks up changes.
let seq = readExistingSeq();
let current = { mood: "greet", message: "" };

function readExistingSeq() {
  try {
    const s = JSON.parse(fs.readFileSync(statePath, "utf8"));
    return typeof s.seq === "number" ? s.seq : 0;
  } catch {
    return 0;
  }
}

function writeState() {
  const payload = JSON.stringify({
    mood: current.mood,
    message: current.message,
    seq,
    ts: Date.now(),
    heartbeat: Date.now(),
  });
  const tmp = `${statePath}.tmp`;
  fs.writeFileSync(tmp, payload);
  fs.renameSync(tmp, statePath); // atomic
}

function setMood(mood, message = "") {
  current = { mood, message: String(message).slice(0, 48) };
  seq += 1;
  writeState();
}

function touchHeartbeat() {
  // Refresh heartbeat without changing mood (same seq -> pet keeps current mood).
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

function ensureCompiled() {
  const needsBuild =
    !fs.existsSync(petBin) ||
    fs.statSync(petSrc).mtimeMs > fs.statSync(petBin).mtimeMs;
  if (!needsBuild) return { ok: true };
  const res = spawnSync("swiftc", ["pet.swift", "-o", ".bin/pet"], {
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
  const child = spawn(petBin, [statePath], {
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
let bootError = null;
const build = ensureCompiled();
if (!build.ok) {
  bootError = build.error;
} else {
  try {
    ensureRunning();
    setMood("greet");
  } catch (e) {
    bootError = e.message;
  }
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
        setMood(mood || "idle", message || "");
        return `Pet mood set to "${mood || "idle"}".`;
      case "say":
        setMood("thinking", message || "");
        return `Pet says: ${message || ""}`;
      case "show":
        setMood("idle");
        return "Pet is visible.";
      case "hide":
        setMood("hidden");
        return "Pet hidden.";
      case "quit":
        setMood("quit");
        try { fs.rmSync(pidPath, { force: true }); } catch {}
        return "Pet dismissed.";
      case "restart": {
        setMood("quit");
        try { fs.rmSync(pidPath, { force: true }); } catch {}
        await new Promise((r) => setTimeout(r, 400));
        const b = ensureCompiled();
        if (!b.ok) return `Failed to recompile pet: ${b.error}`;
        ensureRunning();
        setMood("greet");
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
    onSessionStart: async () => { setMood("greet"); },
    onUserPromptSubmitted: async () => { setMood("thinking"); },
    onPreToolUse: async (input) => {
      // Don't let the pet react to its own control tool.
      if (input?.toolName === "pet_control") return;
      setMood("working", prettyTool(input?.toolName));
    },
    onPostToolUse: async (input) => {
      if (input?.toolName === "pet_control") return;
      setMood("happy");
    },
    onPostToolUseFailure: async () => { setMood("worried"); },
    onErrorOccurred: async () => { setMood("worried"); },
  },
});

// Idle event -> pet relaxes (and drifts to sleep after a while).
session.on("session.idle", () => { setMood("idle"); });

if (bootError) {
  await session.log(`🐾 Copilot pet couldn't start: ${bootError}`, { level: "warning" });
} else {
  await session.log("🐾 Copilot pet is here — it reacts to what I'm doing.", { ephemeral: true });
}
