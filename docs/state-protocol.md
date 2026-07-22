# State File Protocol

Authoritative reference for the JSON files that `extension.mjs` writes and `pet.swift` polls. These files,
`extension.mjs`'s `MOODS` manifest, and the Swift `Mood` enum must stay in sync.

## One pet, many sessions

Every local Copilot session runs its own `extension.mjs` (a *controller*), but there is only **one** desktop
pet. To stop concurrent sessions from stomping a single shared file, **each controller writes its own state
file** under `sessions/`:

```
$TMPDIR/copilot-pet/
  sessions/
    <sessionId>.json   ← one per controller process (uuid)
  pet.pid  pet.lock  pet.pos  pet.log
```

The pet reads **all** files in `sessions/`, ignores any whose controller has stopped heart-beating, and runs
the pure arbiter in `PetCore.swift` (`Arbitration.resolve`) to decide what the single pet should do. See
[Arbitration](#arbitration).

## Per-session file schema

```json
{ "id": "b1f2…", "mood": "working", "message": "editing code", "seq": 42,
  "ts": 1699999999999, "activity": 1699999999900, "heartbeat": 1699999999999 }
```

| Field | Type | Meaning | Units |
| --- | --- | --- | --- |
| `id` | string | Stable id of the writing controller (one per process). | — |
| `mood` | string | Current display mood or control signal. Unknown display values fall back to `idle` in Swift. | — |
| `message` | string | Optional speech-bubble text, truncated by the controller before writing. | — |
| `seq` | number | Monotonic counter, per controller; retained for debugging. | count |
| `ts` | number | Last state write timestamp (any write, incl. heartbeat). | ms since Unix epoch |
| `activity` | number | Timestamp of the last **mood change** (not heartbeat refresh). Drives most-recent-activity arbitration. | ms since Unix epoch |
| `heartbeat` | number | Controller liveness timestamp. A session goes stale after ~12s; the pet exits once **all** sessions are stale. | ms since Unix epoch |

## Arbitration

`Arbitration.resolve(sessions, now, hadLiveSessions)` in `PetCore.swift` is pure and unit-tested. Given every
session snapshot it decides the shared pet's command:

1. **Liveness** — a session is *live* only while `now - heartbeat ≤ 12s`. Stale sessions are ignored (and
   pruned from disk after 60s).
2. **Most-recent-activity wins** — among live sessions, the one with the greatest `activity` drives the pet
   (ties broken deterministically by `id`).
3. **Control signals are global** — if the winner's `mood` is `quit` the pet terminates; if `hidden` the pet's
   window is ordered out. They act on the one shared pet, i.e. respected globally.
4. **Greet de-dup** — a `greet` is only honored on the transition from *no* live sessions to some. A session
   that boots while others are already live shows `idle` instead of a redundant second "hi!".

The pet reacts to a change only when the winning `(id, activity)` pair changes, so a session repeatedly writing
the same mood never resets local animation timers.

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

Each controller writes its own file atomically: it serializes the payload to `sessions/<id>.json.tmp`, then
renames that over `sessions/<id>.json`. This keeps the Swift poller from seeing partial JSON.

Every mood change increments `seq` and updates `activity` before writing. Heartbeat refreshes rewrite the file
with the same `seq`/`activity`, so a session stays *live* without winning arbitration over a more recently
active one. The controller refreshes `heartbeat` every 5s; the pet exits once **every** session's heartbeat is
stale for roughly 12s. Controllers also delete their own file on graceful exit; the pet prunes files whose
controller has been gone for 60s.

## Keeping the seam aligned

When adding, removing, or renaming a mood, update all three authoritative mirrors together:

1. `extension.mjs` `MOODS`
2. `pet.swift` `Mood`
3. this document
