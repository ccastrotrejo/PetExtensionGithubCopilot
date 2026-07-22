# How GitHub Copilot Extensions Work

> Knowledge captured while building the `copilot-pet` extension. Source of truth: the SDK docs shipped
> inside the app at `/Applications/GitHub Copilot.app/Contents/Resources/copilot-sdk/docs/` and the
> `.d.ts` type definitions alongside them.

## What an extension is

Extensions add **custom tools, hooks, and behaviors** to the Copilot CLI / desktop app. Each extension
runs as its **own Node.js process** that communicates with the app over **JSON-RPC via stdio**.

```
┌─────────────────────┐        JSON-RPC / stdio         ┌──────────────────────┐
│   Copilot CLI/app    │ ◄─────────────────────────────► │  Extension process   │
│   (parent process)   │   tool calls, events, hooks     │  (forked child)      │
│  • Discovers exts    │                                 │  • Registers tools   │
│  • Forks processes   │                                 │  • Registers hooks   │
│  • Routes tool calls │                                 │  • Listens to events │
│  • Manages lifecycle │                                 │  • Uses SDK APIs     │
└─────────────────────┘                                 └──────────────────────┘
```

## Discovery

The app scans for **immediate subdirectories** (not recursive) containing a file named exactly
`extension.mjs`:

| Scope | Location | Availability |
| --- | --- | --- |
| **Project** | `<git-root>/.github/extensions/<name>/extension.mjs` | anyone working in that repo |
| **User** | `~/.copilot/extensions/<name>/extension.mjs` | the user, across all projects |
| **Session** | the current session's state directory | just that session |
| **Plugin** | contributed by an installed & enabled plugin | wherever the plugin applies |

Rules:
- Only `.mjs` (ES modules) is supported. **TypeScript is not.** The file must be named `extension.mjs`.
- Project extensions **shadow** user extensions on name collision.
- The `@github/copilot-sdk` import is **auto-resolved** — you do not install it. A resolver hook injects
  `COPILOT_SDK_PATH` (points at the app's bundled SDK).

## Lifecycle

1. **Discovery** — app scans the extension directories.
2. **Launch** — each extension is forked as a child process (via a bootstrap that wires the SDK resolver).
3. **Connection** — the extension calls `joinSession()`, establishing a JSON-RPC connection over stdio
   and attaching to the user's current foreground session.
4. **Registration** — tools and hooks in the config are registered and become available to the agent.
5. **Reload** — extensions are reloaded on `/clear` (or when the foreground session is replaced), or when
   an agent calls `extensions_reload`. New tools are available immediately, mid-turn.
6. **Shutdown** — stopped on app/CLI exit: `SIGTERM`, then `SIGKILL` after 5s.

> ⚠️ **In-memory state is lost on reload.** If you need state to survive `/clear`, persist it outside the
> process (a file, a socket, etc.). `copilot-pet` persists via a state file + detached child process.

## Minimal extension

```js
import { joinSession } from "@github/copilot-sdk/extension";

const session = await joinSession({
  tools: [],  // optional custom tools
  hooks: {},  // optional lifecycle hooks
});
```

## Managing extensions (agent tools)

The agent has these built-in tools (not part of the SDK — they drive the extension system itself):

- `extensions_manage` — `list`, `inspect` (shows status + a tail of the extension's log — the primary
  way to debug a failed extension), `scaffold` (generate a skeleton; `kind: "canvas"` for a canvas
  extension), `guide` (authoring guide).
- `extensions_reload` — stop all extensions and re-discover/re-launch them.

Logs live at `~/.copilot/logs/extensions/<scope>-<name>-<ts>-<pid>.log`.

## Two kinds of extension

- **Basic** — contributes tools/hooks to the agent (what `copilot-pet` is, plus a spawned GUI).
- **Canvas** — registers a canvas: a UI side-panel the agent can open via `open_canvas`. Scaffold with
  `extensions_manage({ operation: "scaffold", kind: "canvas" })`.

## Further reading (in the app bundle)

- `copilot-sdk/docs/extensions.md` — architecture overview, discovery, lifecycle.
- `copilot-sdk/docs/agent-author.md` — step-by-step authoring, full type signatures, gotchas.
- `copilot-sdk/docs/examples.md` — practical code examples.
- `copilot-sdk/*.d.ts` — authoritative type definitions (`extension.d.ts`, `session.d.ts`,
  `types.d.ts`, `generated/session-events.d.ts`).
