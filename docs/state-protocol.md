# State File Protocol

Authoritative reference for the JSON file that `extension.mjs` writes and `pet.swift` polls. This file,
`extension.mjs`'s `MOODS` manifest, and the Swift `Mood` enum must stay in sync.

## `state.json` schema

```json
{ "mood": "working", "message": "editing code", "seq": 42, "ts": 1699999999999, "heartbeat": 1699999999999 }
```

| Field | Type | Meaning | Units |
| --- | --- | --- | --- |
| `mood` | string | Current display mood or control signal. Unknown display values fall back to `idle` in Swift. | — |
| `message` | string | Optional speech-bubble text, truncated by the controller before writing. | — |
| `seq` | number | Monotonic counter; a changed value means “new mood/message to react to.” | count |
| `ts` | number | Last state write timestamp, mostly useful for debugging. | ms since Unix epoch |
| `heartbeat` | number | Controller liveness timestamp. The Swift pet terminates when it goes stale, driving the ~12s watchdog. | ms since Unix epoch |

## Mood vocabulary

Display moods are visual states. These are the only values accepted by the `pet_control` tool's `mood`
parameter and are mirrored by `pet.swift`'s `Mood` enum.

| Mood | Represents |
| --- | --- |
| `greet` | The pet has just appeared or restarted. |
| `thinking` | Copilot is considering a prompt or speaking on command. |
| `working` | Copilot is using a tool; `message` may describe the tool activity. |
| `happy` | The turn finished after real work — a brief "done!" celebration. |
| `worried` | A tool failed or an extension error occurred. |
| `idle` | The turn is finished and the pet is relaxed. |
| `sleeping` | The pet has been idle long enough to sleep. |

Control signals are protocol commands, not display moods:

| Signal | Effect |
| --- | --- |
| `hidden` | Swift orders the pet window out before mood mapping. |
| `quit` | Swift terminates the pet process before mood mapping. |

## Write mechanics

`extension.mjs` writes state atomically: it serializes the payload to `state.json.tmp`, then renames that
file over `state.json`. This keeps the Swift poller from seeing partial JSON.

Every mood change increments `seq` before writing. Heartbeat refreshes rewrite the file with the same `seq`,
so the pet knows the controller is alive without treating the refresh as a new mood. The controller refreshes
`heartbeat` every 5s; if the Swift side observes it stale for roughly 12s, the pet exits.

## Keeping the seam aligned

When adding, removing, or renaming a mood, update all three authoritative mirrors together:

1. `extension.mjs` `MOODS`
2. `pet.swift` `Mood`
3. this document
