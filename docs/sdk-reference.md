# `@github/copilot-sdk` Reference (extension author's view)

> The API surface actually used/observed while building `copilot-pet`. Verified against the app's
> `.d.ts` files and `docs/agent-author.md`. Import from `@github/copilot-sdk/extension`.

## `joinSession(config?)`

```js
import { joinSession } from "@github/copilot-sdk/extension";
const session = await joinSession({ tools, hooks, onPermissionRequest });
```

Joins the current foreground session and returns a `CopilotSession`. Config is a
`JoinSessionConfig` (a `ResumeSessionConfig` variant). The fields that matter for most extensions:

| Field | Type | Notes |
| --- | --- | --- |
| `tools` | `Tool[]` | Custom tools the agent can call. |
| `hooks` | `SessionHooks` | Lifecycle callbacks (see below). |
| `onPermissionRequest` | `PermissionHandler` | Optional custom permission prompting. |

## Tools

```js
{
  name: "tool_name",             // REQUIRED. Globally unique across ALL loaded extensions.
  description: "What it does",    // REQUIRED. Shown to the model.
  parameters: {                   // Optional JSON Schema for args.
    type: "object",
    properties: { arg1: { type: "string", description: "..." } },
    required: ["arg1"],
  },
  skipPermission: true,           // Optional. If true, the user is NOT prompted before running.
  handler: async (args, invocation) => {
    // invocation: { sessionId, toolCallId, toolName }
    return "a string";            // success
    // or: { textResultForLlm: string, resultType?: "success"|"failure"|"rejected"|"denied" }
  },
}
```

Constraints & behavior:
- **Tool name collisions are fatal** — if two extensions register the same name, the second fails to load.
- Handler return value **is** the tool result. Returning `undefined` → empty success. **Throwing** → a
  failure result with the error message.
- **`stdout` is reserved for JSON-RPC.** Never `console.log()` — it corrupts the protocol. Use
  `session.log()` to surface messages to the user.

## Hooks (`SessionHooks`)

All hook inputs include `timestamp: Date` and `workingDirectory: string`. All handlers receive
`invocation: { sessionId }` as the second arg. Any handler may return `void`/`undefined` (no-op) or an
output object.

| Hook | Input (besides timestamp/workingDirectory) | Notable outputs |
| --- | --- | --- |
| `onSessionStart` | `{ source: "startup"\|"resume"\|"new", initialPrompt? }` | `additionalContext` |
| `onUserPromptSubmitted` | `{ prompt }` | `modifiedPrompt`, `additionalContext` |
| `onPreToolUse` | `{ toolName, toolArgs }` | `permissionDecision: "allow"\|"deny"\|"ask"`, `permissionDecisionReason`, `modifiedArgs`, `additionalContext` |
| `onPostToolUse` | `{ toolName, toolArgs, toolResult }` — **success only** | `modifiedResult`, `additionalContext` |
| `onPostToolUseFailure` | `{ toolName, toolArgs, error }` — only `"failure"` results | `additionalContext` |
| `onSessionEnd` | `{ reason, finalMessage?, error? }` | `sessionSummary`, `cleanupActions` |
| `onErrorOccurred` | `{ error, errorContext, recoverable }` | `errorHandling: "retry"\|"skip"\|"abort"`, `retryCount`, `userNotification` |

Notes:
- `onPostToolUse` fires **only** for successful tool results. To observe failures, also register
  `onPostToolUseFailure`. (Only `"failure"` triggers it — not `"rejected"`/`"denied"`/`"timeout"`.)
- Don't call `session.send()` synchronously from `onUserPromptSubmitted` — defer with
  `setTimeout(() => session.send(...), 0)` to avoid infinite loops.

## The `session` object (`CopilotSession`)

| Member | Signature | Purpose |
| --- | --- | --- |
| `session.send` | `(prompt \| MessageOptions) => Promise<string>` | Send a message programmatically; returns messageId. Supports `attachments: [{ type: "file", path }]`. |
| `session.sendAndWait` | `(opts, timeout?) => Promise<AssistantMessageEvent \| undefined>` | Send and block until the session goes idle. Reply in `response?.data.content`. |
| `session.log` | `(message, { level?, ephemeral? }) => Promise<void>` | Log to the timeline. `level`: default/`warning`/`error`. `ephemeral: true` = transient, not persisted. |
| `session.on` | `(eventType, handler) => () => void` | Subscribe to events; returns an unsubscribe fn. Also `on(handler)` for all events. |
| `session.workspacePath` | `string \| undefined` | Session workspace dir (checkpoints, plan.md, files/). |
| `session.rpc` | — | Low-level typed RPC to all session APIs (model, mode, plan, workspace, …). |

### Key event types (`session.on("<type>", cb)`)

| Event | Key `event.data` fields |
| --- | --- |
| `assistant.message` | `content`, `messageId` |
| `user.message` | `content`, `attachments`, `source` |
| `tool.execution_start` | `toolCallId`, `toolName`, `arguments` |
| `tool.execution_complete` | `toolCallId`, `toolName`, `success`, `result`, `error` |
| `session.idle` | `backgroundTasks` — fires when no work/background tasks are in flight |
| `session.error` | `errorType`, `message`, `stack` |
| `session.start` / `session.resume` | session metadata |
| `permission.requested` | `requestId`, `permissionRequest.kind` |
| `session.shutdown` | `shutdownType`, `totalPremiumRequests` |

> Full event schema: `copilot-sdk/generated/session-events.d.ts`.

## Hooks vs events — which to use

- **Hooks** are synchronous interception points in the agent loop; they can *modify* behavior (change a
  prompt, deny a tool, rewrite a result). Reliable for "a tool is about to run / just ran".
- **Events** (`session.on`) are fire-and-forget observations. `session.idle` is the clean signal for
  "the turn finished". `copilot-pet` uses hooks for prompt/tool signals and the `session.idle` event for
  the idle/sleep transition.
