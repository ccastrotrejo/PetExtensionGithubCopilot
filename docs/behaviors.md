# Behavior composition

The pet's on-screen frame is built by **composing small behaviors** instead of
one growing switch. Each frame, an ordered pipeline of `Behavior`s each
contributes to a single mutable `Pose`, and the renderer (`draw()` in
`pet.swift`) only ever consumes that final `Pose`. Adding a new behavior means
slotting it into the pipeline — the renderer never changes.

This is the pet's lightweight take on Pets Therapy's "YAGE" composition engine,
kept over the existing pure/testable `Pose`/`Mood` core (see issue #6).

## The pieces (all in `PetCore.swift`)

| Type | Role |
| --- | --- |
| `BehaviorContext` | Immutable per-frame inputs: `mood`, `phase`, `message`, `reduceMotion`, `motionScale`, `antic`, `anticPhase`. |
| `Behavior` | Protocol: `apply(to pose: inout Pose, _ ctx: BehaviorContext)`. Side-effect-light — mutates the pose, reads only the context. No IO, no globals. |
| `MoodExpression` | The deep module: a mood decodes to breathing, hops, head motion, eyes/mouth/tail, accessory, and bubble. |
| `IdleAnticLayer` | Overlays the current idle antic (stretch, yawn, sniff…) onto the calm idle pose. Only in `idle`, never under Reduce Motion. |
| `PetBehaviors` | The pipeline (`[MoodExpression(), IdleAnticLayer()]`) and `render(_:through:)`, the composition entry point. |

`Pose.make(...)` is a thin, stable adapter: it packages its arguments into a
`BehaviorContext` and calls `PetBehaviors.render`. Keeping its signature means
every existing call site — the renderer and all unit tests — is unchanged, which
is why the refactor carries **no visual regression**.

## How a frame is composed

```swift
let ctx = BehaviorContext(mood: mood, phase: phase, message: message,
                          reduceMotion: reduceMotion,
                          motionScale: reduceMotion ? Pose.reducedMotionScale : 1,
                          antic: antic, anticPhase: anticPhase)
let pose = PetBehaviors.render(ctx)   // == [MoodExpression(), IdleAnticLayer()]
```

`render` seeds a fresh `Pose` with `motionScale` (so every behavior sees the same
Reduce-Motion damping), then applies each behavior in order. It is pure: the same
context always yields the same `Pose`.

## Adding a behavior

1. Conform a type to `Behavior` and contribute to the pose:

   ```swift
   struct Blink: Behavior {
       func apply(to p: inout Pose, _ ctx: BehaviorContext) {
           guard !ctx.reduceMotion else { return }
           if sin(ctx.phase * 0.4) > 0.98 { p.feat.eyes = .closed }
       }
   }
   ```

2. Add it to `PetBehaviors.pipeline`. Order matters — later behaviors layer on
   top of earlier ones (that's why `IdleAnticLayer` runs after `MoodExpression`).

3. Add a unit test in `Tests/PetCoreTests.swift`. The renderer needs no changes.

Behaviors that need inputs beyond today's context (e.g. cursor position for a
cursor-chase, or window/ground geometry for gravity/perch) should extend
`BehaviorContext` with those fields and have `pet.swift` populate them — still
without touching `draw()`'s pixel code.
