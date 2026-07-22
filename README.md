# 🐾 Copilot Pet

A native macOS desktop companion (inspired by [pets-therapy.com](https://pets-therapy.com/)) that
reacts to what GitHub Copilot is doing. It runs as a **user-scoped Copilot extension** and renders a
**pixel-art dachshund** you can **drag anywhere** on your desktop (its position is remembered).

| When Copilot… | The pet… |
| --- | --- |
| Starts a session | 🐶 **greets** you 👋 (happy eyes, tail wagging) |
| Receives a prompt | 🐶 **thinks** 💭 (head tilts) |
| Runs a tool | 🐶 **works** ⚙️ (pants, tongue out; bubble names the tool) |
| Finishes a tool successfully | 🐶 is **happy** ✨ (bounces, tail wags fast) |
| Hits an error / failure | 🐶 gets **worried** 💦 (brow up, tail tucked) |
| Goes idle | 🐶 waits (gentle breathing), then 😴 **sleeps** after ~18s |

## Install / activate

This extension lives in `~/.copilot/extensions/copilot-pet/`. It is discovered automatically by the
GitHub Copilot app / CLI. After any change, reload it:

- From the agent: `extensions_reload`
- Or restart the app, or `/clear` the session.

On first load it compiles `pet.swift` with `swiftc` (a few seconds) into `.bin/pet`, then spawns it.

## Requirements

- macOS (uses AppKit)
- Xcode command-line tools (`swiftc`) — for the one-time compile
- Node.js runtime (provided by the Copilot app)

## Manual control

The extension registers a `pet_control` tool. Ask the agent things like *"hide the pet"*,
*"make the pet sleep"*, *"restart the pet"*. Actions: `mood`, `say`, `show`, `hide`, `quit`, `restart`.

## Files

| File | Purpose |
| --- | --- |
| `extension.mjs` | The Copilot extension. Compiles + spawns the pet, maps Copilot events → moods. |
| `pet.swift` | Native AppKit overlay window + pet rendering/animation. |
| `.bin/pet` | Compiled binary (git-ignored, rebuilt on demand). |
| `docs/` | Full knowledge dump — see below. |

## Documentation

- [`docs/copilot-extensions.md`](docs/copilot-extensions.md) — how Copilot extensions work (architecture, discovery, lifecycle).
- [`docs/sdk-reference.md`](docs/sdk-reference.md) — the `@github/copilot-sdk` API: `joinSession`, hooks, session object, events.
- [`docs/architecture.md`](docs/architecture.md) — this pet's design, IPC protocol, and decisions.
- [`docs/development.md`](docs/development.md) — how to modify, compile, test, and debug.

## Auto-cleanup

The extension writes a `heartbeat` timestamp every 5s. If the app/session closes (extension process
dies), the heartbeat goes stale and the pet **self-terminates within ~12s**. It reappears next time
the extension loads. No orphan processes.
