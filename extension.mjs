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
const statePath = path.join(stateDir, "state.json");
const pidPath = path.join(stateDir, "pet.pid");
const logPath = path.join(stateDir, "pet.log");

fs.mkdirSync(stateDir, { recursive: true });
fs.mkdirSync(binDir, { recursive: true });

// Keep seq monotonically increasing across reloads so a reused pet picks up changes.
let seq = readExistingSeq();
let current = { mood: MOOD.greet, message: "" };

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
// The pet greets ("hi!") only once per process. onSessionStart fires again on
// every resume, so without this guard the pet would say "hi" constantly.
let hasGreeted = false;
let bootError = null;
const build = ensureCompiled();
if (!build.ok) {
  bootError = build.error;
} else {
  try {
    ensureRunning();
    setMood(MOOD.greet);
    hasGreeted = true;
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
      // Stay "working" across a whole run of tools; only the label changes.
      if (input?.toolName === "pet_control") return;
      setMood(MOOD.working, prettyTool(input?.toolName));
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
}
