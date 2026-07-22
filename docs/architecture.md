# Architecture & Design Decisions

How `copilot-pet` is built and why. Two processes, one state file.

## Overview

```
  GitHub Copilot app
        │  forks
        ▼
  extension.mjs  ──writes──►  $TMPDIR/copilot-pet/state.json  ◄──polls──  .bin/pet (Swift/AppKit)
   (Node, JSON-RPC child)          { mood, message, seq,                   transparent overlay window
   hooks + events → mood            ts, heartbeat }                        renders the animated pet
```

- **`extension.mjs`** (Node) is the *controller*. It joins the session, listens to Copilot activity,
  compiles + spawns the pet, and translates activity into moods by writing a small JSON state file.
- **`pet.swift`** → **`.bin/pet`** (native) is the *renderer*. A small, always-on-top, draggable
  `NSWindow` that polls the state file and animates a pixel-art dachshund accordingly. A `Mood`
  decodes to a `Pose` (motion + expression), which the view renders.

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

A **state file** sidesteps this entirely: any controller instance writes to the same path, and the pet
reads whoever wrote last. Benefits:

- **Reload-proof** — new controller reconnects instantly to the surviving pet.
- **Single-instance** — a `pet.pid` file + liveness check prevents duplicate pets.
- **Trivial** — no socket/port lifecycle, no protocol framing.

State lives under `os.tmpdir()/copilot-pet/` (on macOS that's `/var/folders/.../T/copilot-pet/`, not
`/tmp`).

### `state.json` schema

```json
{ "mood": "working", "message": "editing code", "seq": 42, "ts": 1699999999999, "heartbeat": 1699999999999 }
```

| Field | Meaning |
| --- | --- |
| `mood` | one of: `greet`, `thinking`, `working`, `happy`, `worried`, `idle`, `sleeping`, `hidden`, `quit` |
| `message` | speech-bubble text (≤48 chars) |
| `seq` | monotonic counter; the pet treats a **changed `seq`** as "new mood → wake + react" |
| `ts` | last write time (debug) |
| `heartbeat` | controller liveness timestamp (ms); refreshed every 5s |

Writes are **atomic**: write `state.json.tmp`, then `rename()` over `state.json`.

### Files in the state dir

| File | Purpose |
| --- | --- |
| `state.json` | current mood + heartbeat (the IPC channel) |
| `pet.pid` | PID of the running pet, for single-instance reuse |
| `pet.log` | pet stdout/stderr |

## Single instance & reload survival

`ensureRunning()`:
1. Read `pet.pid`; if that PID is alive (`process.kill(pid, 0)`), **reuse it** — do nothing.
2. Otherwise spawn `.bin/pet` **detached** with `stdio` → `pet.log`, `child.unref()`, and write the new
   PID to `pet.pid`.

`seq` is initialized from the **existing** `state.json` (not 0), so a reused pet — whose `lastSeq` may
already be high — still sees subsequent writes as changes.

## Heartbeat watchdog (auto-cleanup)

Problem: a detached pet would otherwise **outlive the app forever** with no controller to dismiss it.

Solution:
- Controller refreshes `heartbeat = Date.now()` **every 5s** (and on every mood change).
- Pet checks each frame: if `now - heartbeat > 12s`, it calls `NSApp.terminate`.

Result: close the app/session → `extension.mjs` dies → heartbeat freezes → **pet vanishes within ~12s**.
Reopen → extension reloads → pet respawns and greets. The `/clear` gap (<1s) is well under 12s, so the
pet survives reloads.

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
- `idle` → `sleeping` after 18s of no new `seq`
- any new `seq` → wake + adopt the new mood
- `mood: "quit"` → `NSApp.terminate`; `mood: "hidden"` → `orderOut`

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
origin is persisted to `pet.pos` (next to `state.json`) and restored on launch.

A `Timer` at ~30 fps drives `PetView.tick()`, which polls the state file (~5×/s), runs the mood machine,
and redraws. The pet is a pixel-art dachshund drawn with Core Graphics as grid-aligned blocks (limited
palette), plus a pixel-art status icon (gear, sparkle, thought cloud, sweat, Zzz, waving paw), a rounded
speech bubble with a tail, and a soft ground shadow.

## Known limitations

- **macOS only** (AppKit).
- Uses **`NSScreen.main`** only — no multi-monitor spanning.
- Pixel-art sprite is code-drawn (no image assets); tuning the art means editing cell coordinates.
- Requires `swiftc` for the one-time compile.
