# Architecture & Design Decisions

How `copilot-pet` is built and why. Two processes, one state file.

## Overview

```
  GitHub Copilot app (one per session)
        │  forks
        ▼
  extension.mjs  ──writes──►  $TMPDIR/copilot-pet/sessions/<id>.json  ◄──polls all──  .bin/pet (Swift/AppKit)
   (Node, JSON-RPC child)          { id, mood, message, seq,                          transparent overlay window
   hooks + events → mood           ts, activity, heartbeat }                         arbitrates → renders one pet
```

- **`extension.mjs`** (Node) is the *controller*. There is one per session. It joins the session, listens to
  Copilot activity, compiles + spawns the pet, and translates activity into moods by writing its **own**
  per-session JSON state file.
- **`pet.swift`** → **`.bin/pet`** (native) is the single *renderer*. A small, always-on-top, draggable
  `NSWindow` that polls **every** session file, runs the pure arbiter, and animates a pixel-art dachshund for
  the winning session's mood. A `Mood` decodes to a `Pose` (motion + expression), which the view renders.

## One pet across many sessions

Every local session runs its own controller, but only one dog is ever on screen (enforced by `pet.lock`). To
keep concurrent sessions from stomping each other, **each controller writes its own file** under `sessions/`
and the pet arbitrates. The decision logic lives in the pure, unit-tested `Arbitration` enum in
`PetCore.swift`:

- **Most-recent-activity wins** — the session that changed mood last drives the pet.
- **Control signals are global** — a `hidden` / `quit` from the winning session acts on the one shared pet.
- **Greet de-dup** — a greet only plays on the 0→N live-session transition, so opening N sessions no longer
  triggers N "hi!"s (the original cause of the greet spam).
- **Liveness** — a session is ignored once its heartbeat is >12s stale, and its file is pruned after 60s.

See [`state-protocol.md`](state-protocol.md) for the wire format and exact rules.

## Why native Swift (not Electron)

- The build machine had **`swiftc` (Swift 6.3) available** and **no Electron installed**.
- Electron would add a **~200 MB** dependency for what is a tiny always-on-top overlay.
- AppKit gives a first-class transparent, draggable, all-Spaces overlay with no deps.

Trade-off: Swift ties this to macOS. A cross-platform port would use Electron or Tauri.

## Why a polled state file for IPC (not stdin / socket)

The obvious channel — write JSON to the child's **stdin** — breaks across **`/clear` reloads**:

- On reload the app **SIGTERMs the old `extension.mjs`**, but the pet was spawned **detached +
  `unref()`**, so it survives.
- A brand-new `extension.mjs` starts and **cannot write to the old pet's stdin** (it never owned that
  pipe).

A **state file** sidesteps this entirely: any controller instance writes to its file, and the pet reads
them all. Benefits:

- **Reload-proof** — new controller reconnects instantly to the surviving pet.
- **Single-instance** — a `pet.pid` file + a `pet.lock` flock prevent duplicate pets.
- **Multi-session-safe** — each session writes its own file, so controllers never overwrite each other; the
  pet arbitrates (see [One pet across many sessions](#one-pet-across-many-sessions)).
- **Trivial** — no socket/port lifecycle, no protocol framing.

State lives under `os.tmpdir()/copilot-pet/` (on macOS that's `/var/folders/.../T/copilot-pet/`, not
`/tmp`), with per-session files in the `sessions/` subdirectory.

### `sessions/<id>.json` schema

```json
{ "id": "b1f2…", "mood": "working", "message": "editing code", "seq": 42,
  "ts": 1699999999999, "activity": 1699999999900, "heartbeat": 1699999999999 }
```

| Field | Meaning |
| --- | --- |
| `id` | stable id of the writing controller (one per session process) |
| `mood` | one of: `greet`, `thinking`, `working`, `happy`, `worried`, `idle`, `sleeping`, `hidden`, `quit` |
| `message` | speech-bubble text (≤48 chars) |
| `seq` | monotonic counter, per controller (debug) |
| `ts` | last write time, any write incl. heartbeat (debug) |
| `activity` | time of last **mood change**; drives most-recent-activity arbitration |
| `heartbeat` | controller liveness timestamp (ms); refreshed every 5s |

Writes are **atomic**: write `sessions/<id>.json.tmp`, then `rename()` over `sessions/<id>.json`.

### Files in the state dir

| File | Purpose |
| --- | --- |
| `sessions/<id>.json` | one per session controller — the IPC channel the pet arbitrates over |
| `pet.pid` | PID of the running pet, for single-instance reuse |
| `pet.lock` | flock held by the live pet, backing single-instance |
| `pet.pos` | persisted window position |
| `pet.log` | pet stdout/stderr |

## Single instance & reload survival

`ensureRunning()`:
1. Read `pet.pid`; if that PID is alive (`process.kill(pid, 0)`), **reuse it** — do nothing.
2. Otherwise spawn `.bin/pet` **detached** with `stdio` → `pet.log`, `child.unref()`, and write the new
   PID to `pet.pid`.

On boot a controller writes its session file **before** spawning the pet, so the pet finds it on the first
poll. Each controller uses a fresh `id`, so a reused pet simply sees a new session file appear and — because
greet de-dup keys on the *0→N live-session transition*, not per process — a reload during the sub-second
`/clear` gap does not re-greet.

## Heartbeat watchdog (auto-cleanup)

Problem: a detached pet would otherwise **outlive the app forever** with no controller to dismiss it.

Solution:
- Each controller refreshes its `heartbeat = Date.now()` **every 5s** (and on every mood change).
- The pet tracks the **freshest** heartbeat across all session files; if that is >12s stale (i.e. *every*
  session is gone), it calls `NSApp.terminate`. Controllers also delete their own file on graceful exit, and
  the pet prunes files whose controller has been gone for 60s.

Result: close the last app/session → its heartbeat freezes → **pet vanishes within ~12s**. Reopen →
extension reloads → pet respawns. The `/clear` gap (<1s) is well under 12s, so the pet survives reloads. With
several sessions open, closing one just drops it from arbitration; the pet stays for the rest.

## Compilation strategy

`ensureCompiled()` rebuilds only when `pet.swift` or `PetCore.swift` is newer than `.bin/pet` (or the binary is missing).
The extension compiles **without `-O`** (a few seconds) since runtime cost is negligible for a small
overlay. (`-O` builds took ~44s in testing — too slow for a load-time step.)

## Event → mood mapping

| Copilot signal | Handler | Mood |
| --- | --- | --- |
| session starts | `onSessionStart` | `greet` |
| prompt submitted | `onUserPromptSubmitted` | `thinking` |
| tool about to run | `onPreToolUse` | `working` (+ friendly tool label) |
| tool failed | `onPostToolUseFailure` | `worried` |
| error occurred | `onErrorOccurred` | `worried` |
| turn finished | `session.on("session.idle")` | `happy` ("done!") if it was mid-task, else `idle` |

The pet stays `working` across a whole run of tools (only the label changes) — there is **no** per-tool
success reaction, so it no longer flashes "done!" between every call. `pet_control` is filtered out of
`onPreToolUse` so the pet doesn't react to its own control calls.

## Local (Swift-side) mood state machine

The renderer owns transient/auto transitions so the controller only sends discrete events:

- `greet` → `idle` after 1.6s
- `happy` → `idle` after 1.5s
- `worried` → `idle` after 2.4s
- `thinking` / `working` → persist until the next event (no auto transition)
- `idle` → `sleeping` after 18s with no new winning event
- a new winning `(id, activity)` → wake + adopt that session's mood
- winner `mood: "quit"` → `NSApp.terminate`; winner `mood: "hidden"` → `orderOut`

## The overlay window

```swift
window.styleMask = .borderless
window.isOpaque = false
window.backgroundColor = .clear
window.level = .floating                  // above normal windows
window.ignoresMouseEvents = false         // catch drags…
window.isMovableByWindowBackground = true // …to move the pet
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
app.setActivationPolicy(.accessory)       // no Dock icon, never steals focus
```

The window is small (sized to the pet, not full-screen). `PetView.hitTest` returns the view only over
the pet's body, so everywhere else stays click-through; dragging the body moves the window and the new
origin is persisted to `pet.pos` (in the state dir) and restored on launch.

A `Timer` at ~30 fps drives `PetView.tick()`, which polls the state file (~5×/s), runs the mood machine,
and redraws. The pet is a pixel-art dachshund drawn with Core Graphics as grid-aligned blocks (limited
palette), plus a pixel-art status icon (gear, sparkle, thought cloud, sweat, Zzz, waving paw), a rounded
speech bubble with a tail, and a soft ground shadow.

## Known limitations

- **macOS only** (AppKit).
- Uses **`NSScreen.main`** only — no multi-monitor spanning.
- Pixel-art sprite is code-drawn (no image assets); tuning the art means editing cell coordinates.
- Requires `swiftc` for the one-time compile.
