# Development & Debugging Guide

## Layout

```
copilot-pet/
├── extension.mjs        # controller (Node)
├── pet.swift            # renderer (Swift/AppKit)
├── .bin/pet             # compiled binary (git-ignored)
├── README.md
└── docs/
    ├── copilot-extensions.md
    ├── sdk-reference.md
    ├── architecture.md
    └── development.md    # this file
```

State dir at runtime: `"$TMPDIR/copilot-pet/"` → `sessions/<id>.json` (one per session), `pet.pid`,
`pet.lock`, `pet.pos`, `pet.log`.

## Edit → reload loop

1. Edit `extension.mjs` and/or `pet.swift`.
2. Reload: ask the agent to run `extensions_reload` (or `/clear`, or restart the app).
   - If `pet.swift` changed, the extension auto-recompiles (binary older than source).
3. Verify: `extensions_manage({ operation: "inspect", name: "copilot-pet" })` → status should be
   `running`, and the log tail should be clean.

> `console.log()` is forbidden inside `extension.mjs` (stdout = JSON-RPC). Use `session.log(msg)` or
> write to a file for debugging.

## Compile the pet manually

```bash
cd ~/.copilot/extensions/copilot-pet
swiftc pet.swift PetCore.swift -o .bin/pet          # fast, unoptimized (what the extension uses)
# swiftc -O pet.swift PetCore.swift -o .bin/pet     # optimized (~44s; unnecessary here)

# run the model unit tests
swiftc PetCore.swift Tests/PetCoreTests.swift -o /tmp/pettests && /tmp/pettests
```

## Run the pet standalone (no Copilot)

```bash
SD="$TMPDIR/copilot-pet"; mkdir -p "$SD/sessions"
NOW=$(node -e 'process.stdout.write(String(Date.now()))')
# The pet reads every file in sessions/ and arbitrates. One session file is enough to drive it.
printf '{"id":"demo","mood":"working","message":"hello","seq":1,"activity":%s,"heartbeat":%s}' "$NOW" "$NOW" > "$SD/sessions/demo.json"
~/.copilot/extensions/copilot-pet/.bin/pet "$SD/state.json" &   # arg only anchors the state dir; the pet scans sessions/
# change mood live (bump activity so it wins / counts as a new event):
NOW=$(node -e 'process.stdout.write(String(Date.now()))')
printf '{"id":"demo","mood":"happy","message":"yay","seq":2,"activity":%s,"heartbeat":%s}' "$NOW" "$NOW" > "$SD/sessions/demo.json"
# dismiss it:
NOW=$(node -e 'process.stdout.write(String(Date.now()))')
printf '{"id":"demo","mood":"quit","message":"","seq":3,"activity":%s,"heartbeat":%s}' "$NOW" "$NOW" > "$SD/sessions/demo.json"
```

Two ways to stop a standalone pet:
- Send `mood: "quit"` with a newer `activity`.
- Stop refreshing `heartbeat` — the watchdog terminates it within ~12s once every session is stale.

> This environment blocks `kill <pid>` with a variable PID. Prefer `mood: "quit"` or the heartbeat
> watchdog over `kill`. Use `ps -p <pid>` to check liveness.

## Inspect runtime state

```bash
SD="$TMPDIR/copilot-pet"
cat "$SD"/sessions/*.json                         # each session's current mood + heartbeat
ps -p "$(cat "$SD/pet.pid")" -o pid=,stat=,command=   # is the pet alive?
cat "$SD/pet.log"                                 # pet output/errors
```

Extension logs (controller side):
```
~/.copilot/logs/extensions/user-copilot-pet-<ts>-<pid>.log
```

## Manual control via the agent tool

`pet_control` (registered by the extension, `skipPermission: true`):

| action | effect |
| --- | --- |
| `mood` | set a mood (`greet`/`thinking`/`working`/`happy`/`worried`/`idle`/`sleeping`) + optional `message` |
| `say` | show a speech bubble (`thinking` face) with `message` |
| `show` | make the pet visible (`idle`) |
| `hide` | hide the window |
| `quit` | dismiss the pet and remove the pidfile |
| `restart` | quit, recompile if needed, respawn, greet |

## Common tweaks

| Want to… | Where |
| --- | --- |
| Change moods/animation/expressions | `pet.swift` → `Pose.make(for:)` |
| Change idle→sleep delay | `pet.swift` → `Mood.autoNext` (`idle` case) |
| Change heartbeat/watchdog timing | 5s: `extension.mjs` `setInterval`; 12s: `pet.swift` `hbAgeMs > 12_000` |
| Friendlier tool labels | `extension.mjs` → `TOOL_LABELS` |
| Map different events to moods | `extension.mjs` → `hooks` / `session.on(...)` |
| Pet size / ground position | `pet.swift` → `petSize`, `groundY` |
| Pixel-art shape / colours | `pet.swift` → `drawDachshundPixel` + palette constants |
| Reposition the pet | drag its body; position persists in `pet.pos` in the state dir |

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| Extension `failed` in `inspect` | Check the log tail. Usually a syntax error — run `node --check extension.mjs`. |
| No pet on screen | `swiftc` missing or compile failed → see `pet.log` / recompile manually. |
| Pet won't change mood | `seq` not increasing (a reused pet ignores equal/old `seq`). |
| Two pets | Stale `pet.pid` + a still-running orphan → `pet_control` `quit`, then reload. |
| Pet lingers after closing app | Expected up to ~12s (heartbeat watchdog), then it exits. |
