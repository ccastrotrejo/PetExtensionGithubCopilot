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
- while `idle`, the pet occasionally performs a short **antic** (stretch, yawn, scratch, sniff, dig,
  chase-tail, sit) at relaxed 6–15s intervals — autonomous local variety, not a wire mood. Any real mood
  cancels it and Reduce Motion suppresses it, so an antic never fights an expression. The weighted
  selection + scheduling is the pure, unit-tested `Antic` / `IdleAntics` in `PetCore.swift`.
- a new winning `(id, activity)` → wake + adopt that session's mood
- winner `mood: "quit"` → `NSApp.terminate`; winner `mood: "hidden"` → `orderOut`

## Petdex packs (spritesheet pets)

The flagship dachshund is code-drawn, but the pet can also render **installed
[Petdex](https://petdex.dev) packs** — community pets in a portable
`pet.json` + spritesheet format (see [`petdex.md`](petdex.md) for the full story).
This is the ecosystem work from issues #9/#10.

- **Format & mapping are pure.** `SpriteSheet` (grid geometry + `frameIndex` /
  `frameRect`), `PetdexState` + `Mood.petdexState` (our moods → the sheet's
  animation rows), and `PetPackInfo` (`pet.json` parsing) all live in
  `PetCore.swift` and are unit-tested — no image decode needed. The invariant is
  the **192×208 frame size**, so sheets with different row counts (8×9, 8×11, …)
  all slice correctly.
- **`config.activePet`** selects the pet: `"dachshund"` (default flagship) or an
  installed slug loaded from `~/.copilot-pet/pets/<slug>/`. `loadConfig` reloads
  the pack only when the slug changes (`syncActivePack`); a failed load falls
  back to the dog. The window resizes to the pack's frame aspect
  (`PetMetrics.windowSize`).
- **Rendering** (`PetView.drawSpritePack`): the mood picks the sheet **row**
  (state), the animation clock picks the **column** (frame, 6 fps); Reduce Motion
  freezes on the first frame. Spritesheets decode via ImageIO (`CGImageSource` —
  native WebP/PNG on macOS 11+); frames are cropped on demand. The dog-only
  touches (three facings, cursor gaze, idle antics) are skipped for packs.
- **Consume** flow lives in the controller: `extension.mjs` adds a `pet_gallery`
  tool (browse the cached public manifest, install a pack into the pets dir,
  `use`/`remove` via a merge-write of `config.json`).
- **Contribute:** `pet --export <dir>` renders the dachshund headlessly into a
  1536×1872 Petdex spritesheet + `pet.json` (`PetExport`), driven by
  `tools/export-dachshund.sh`; the committed result is
  `assets/petdex/copilot-dachshund/`.

## The overlay window

```swift
window.styleMask = .borderless
window.isOpaque = false
window.backgroundColor = .clear
window.level = .floating                  // above normal windows
window.ignoresMouseEvents = false         // catch presses on the pet…
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
app.setActivationPolicy(.accessory)       // no Dock icon, never steals focus
```

The window is small (sized to the pet, not full-screen). `PetView.hitTest` returns the view only over
the pet's body, so everywhere else stays click-through.

## Interacting with the pet — drag, click, and gaze

The pet body is both a drag handle and a pet target, so `PetView` handles the press itself rather than
relying on `isMovableByWindowBackground` (which would swallow the click/drag distinction):

- **Click to pet** — a press that never travels past `Interaction.dragThreshold` (4 pt) is a *click*: it
  plays the local `loved` reaction (a blushing wriggle with a ♥). `Interaction` is pure/testable, so the
  click-vs-drag rule is exercised without a running app.
- **Drag to move** — once the pointer travels past the threshold the press becomes a window drag; the new
  origin is persisted to `pet.pos` (in the state dir) and restored on launch. So repositioning the pet
  never accidentally pets it (issue acceptance criterion).
- **Look at the cursor** — while the pointer is *near* (polled via `NSEvent.mouseLocation` each idle tick),
  the pet watches it: the pure `Gaze.toward(dx:dy:size:)` model decides whether the cursor is near, which
  of the three facings to turn to, and a pupil offset the renderer applies to the eyes (`eyeLook`, mirrored
  for the left-facing sprite). Autonomous glancing is suspended while watching. Like the automatic
  look-around, gaze is non-essential motion, so it's gated behind the `lookAround` behavior and suppressed
  under (effective) Reduce Motion.

`loved` is a *local-only* mood (never on the wire — see [`state-protocol.md`](state-protocol.md)); when it
ends, `advanceMood` clears `lastKey` so the pet re-syncs to whatever the live session is doing.

`PetView.tick()` polls the state file (~5×/s), runs the mood machine, and redraws — but it isn't driven
by a fixed-rate `Timer` any more. Instead, `main()` schedules a one-shot `Timer` after every tick, using
`PetView.nextTickInterval` for the delay, so cadence adapts on the fly:

- **`Cadence`** (in `PetCore.swift`, pure/testable) maps `(reduceMotion, calm)` to an FPS: 30 fps while
  actively animating, 5 fps once the mood is calm (idle/sleeping), 10 fps / 2 fps for the same two cases
  when Reduce Motion is in effect. Effective Reduce Motion is the OR of the live OS accessibility setting
  (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`) and the user's `config.json` override
  (`reduceMotion`, see [`docs/config.md`](config.md)) — either one asks for stillness and the pet holds still.
- Whenever the window is hidden (`hidden` mood → `orderOut`) or occluded (`window.occlusionState` doesn't
  contain `.visible` — covered by another window, or on another Space), `tick()` still polls state and the
  heartbeat at `Cadence.hiddenFPS` (5 fps), but skips advancing `state.phase` and never sets `needsDisplay`
  — nothing is animated or redrawn while nobody can see it. `tick()` checks visibility only *after*
  `loadState()` runs (which may itself show/hide the window), so a window hidden or shown this tick is
  never animated/redrawn against stale, pre-load visibility; `nextTickInterval` is likewise read only after
  `tick()` returns, so the next scheduled tick reflects that same fresh state.
- Reduce Motion also damps the pet's own motion via `Pose.motionScale` (`~15%` of normal, `Pose.reducedMotionScale`):
  whole-body bob, breathing scale, head tilt/bob, and trembling are scaled down in `Pose.make`, and the
  renderer scales its own tail wag / ear flap / accessory bob amplitudes by the same factor. The gear's
  spinning teeth, the sparkle's pulsing size, and the panting tongue's drop are binary/discrete rather than
  continuous, so they're frozen on one frame instead of just scaled down. Expressions — which
  eyes/mouth/accessory/bubble are shown — are never touched, so the pet still reads clearly; only the
  ambient wobble is dampened. The automatic look-around (turning to face you) and cursor-watching (gaze)
  are skipped entirely under (effective) Reduce Motion or when the `lookAround` behavior is disabled in
  `config.json`, as they're the most conspicuous non-essential motion.

The pet is a pixel-art dachshund drawn with Core Graphics as grid-aligned blocks (limited palette), plus
a pixel-art status icon (gear, sparkle, thought cloud, sweat, Zzz, waving paw), a rounded speech bubble
with a tail, and a soft ground shadow.

## Known limitations

- **macOS only** (AppKit).
- Uses **`NSScreen.main`** only — no multi-monitor spanning.
- The flagship dachshund is code-drawn (no image assets); tuning its art means editing cell coordinates. Installed [Petdex packs](petdex.md), by contrast, are image spritesheets.
- Requires `swiftc` for the one-time compile.
- Submitting our exported pet to the Petdex gallery is an interactive step (`npx petdex submit`, OAuth login) — the export is automated, the submission is not.
