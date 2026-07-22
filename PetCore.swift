// PetCore — pure model for the Copilot pet. No AppKit, no top-level code.
// Compiled into the app (with pet.swift) and exercised directly by
// Tests/PetCoreTests.swift. Mirrors the MOODS manifest in extension.mjs and
// docs/state-protocol.md.

import Foundation
import CoreGraphics

// MARK: - Mood (typed vocabulary)
// Control signals "hidden" / "quit" travel over the same wire but are handled
// in loadState() before mapping to a Mood, so they never become render state.

enum Mood: String {
    case greet, thinking, working, happy, worried, idle, sleeping
    // `celebrate` and `nudge` are wellness signals the controller raises (see
    // extension.mjs): `celebrate` marks a milestone (tests pass, a PR is
    // opened/merged) with a bigger party than the routine "done!" `happy`, and
    // `nudge` is a gentle "time for a break?" after a long continuous work run.
    // Both travel the wire and are in the `MOODS` manifest; both are opt-in via
    // config and auto-return to idle so they never linger.
    case celebrate, nudge
    // `loved` is a *local* interaction mood: it is triggered only by clicking
    // (petting) the dog, never travels the wire, and is absent from the
    // `MOODS` manifest in extension.mjs. It plays a brief reaction, then
    // auto-returns to idle and re-syncs to whatever the live session is doing.
    case loved

    /// Automatic transition after a mood has been shown for `after` seconds.
    var autoNext: (after: TimeInterval, to: Mood)? {
        switch self {
        case .greet:     return (1.6, .idle)
        case .happy:     return (1.5, .idle)    // "done!" celebration, then relax
        case .celebrate: return (2.0, .idle)    // milestone party — lingers a touch longer
        case .nudge:     return (2.6, .idle)    // gentle break reminder, then relax
        case .loved:     return (1.5, .idle)    // petting reaction, then relax
        case .worried:   return (2.4, .idle)
        case .idle:      return (18,  .sleeping)
        default:         return nil             // thinking / working persist until the next event
        }
    }
}

// MARK: - Animation cadence policy (testable, no AppKit)

/// How often the view should tick/redraw. Kept separate from AppKit (pure
/// function of mood + the OS Reduce Motion setting) so it's unit-testable
/// without a running app. The renderer additionally drops to `hiddenFPS`
/// whenever the window itself isn't visible — that case lives here too so
/// all cadence numbers are defined in one place.
enum Cadence {
    /// Ticks/frames per second while the window is on-screen.
    static func fps(reduceMotion: Bool, calm: Bool) -> Double {
        switch (reduceMotion, calm) {
        case (false, false): return 30   // actively animating (greet/thinking/working/happy/worried)
        case (false, true):  return 5    // idle/sleeping — nothing urgent to show
        case (true, false):  return 10   // Reduce Motion, but still reacting to something
        case (true, true):   return 2    // Reduce Motion + calm — bare minimum to notice a change
        }
    }

    /// Tick interval in seconds for `fps(reduceMotion:calm:)`.
    static func interval(reduceMotion: Bool, calm: Bool) -> TimeInterval {
        1.0 / fps(reduceMotion: reduceMotion, calm: calm)
    }

    /// FPS used purely to keep polling state/heartbeat while the window is
    /// hidden or occluded: no animation, no redraw, just enough to notice a
    /// mood change or a stale heartbeat.
    static let hiddenFPS: Double = 5
    static let hiddenInterval: TimeInterval = 1.0 / hiddenFPS

    /// Moods with nothing time-sensitive to communicate — safe to throttle.
    static func isCalm(_ mood: Mood) -> Bool {
        mood == .idle || mood == .sleeping
    }
}

// MARK: - Coat palettes (personalization)
//
// Pure colour data (no AppKit) so palette selection stays unit-testable;
// pet.swift maps each RGBA to an NSColor at draw time. Adding a new breed colour
// is just one more entry in `Palette.all`.

/// Straight RGBA components in 0…1 — an AppKit-free stand-in for a colour.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// A dachshund coat colour scheme. Only the coat and its markings are
/// parameterized; facial accents (nose, eye, tongue, blush) stay constant since
/// they read cleanly on every coat.
struct Palette: Equatable {
    let name: String
    let outline, body, bodyHi, shade, dark, tan, tanShade, saddle: RGBA

    /// Every selectable palette. `chestnut` is first and is the default.
    static let all: [Palette] = [chestnut, blackAndTan, red, cream]

    /// Look up a palette by (case-insensitive) name, falling back to the default
    /// `chestnut` for an unknown or empty name so a typo never breaks rendering.
    static func named(_ n: String) -> Palette {
        let key = n.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name == key } ?? chestnut
    }

    // Classic red-and-tan — the original hand-tuned coat.
    static let chestnut = Palette(
        name: "chestnut",
        outline:  RGBA(0.17, 0.10, 0.07),
        body:     RGBA(0.64, 0.37, 0.18),
        bodyHi:   RGBA(0.77, 0.51, 0.28),
        shade:    RGBA(0.44, 0.24, 0.19),
        dark:     RGBA(0.38, 0.21, 0.11),
        tan:      RGBA(0.91, 0.73, 0.50),
        tanShade: RGBA(0.78, 0.58, 0.38),
        saddle:   RGBA(0.33, 0.17, 0.09))

    // Black-and-tan — charcoal coat (not pure black, so shading still reads)
    // with rich tan points on the belly, muzzle and paws.
    static let blackAndTan = Palette(
        name: "black-and-tan",
        outline:  RGBA(0.06, 0.05, 0.05),
        body:     RGBA(0.20, 0.18, 0.17),
        bodyHi:   RGBA(0.33, 0.30, 0.28),
        shade:    RGBA(0.13, 0.12, 0.11),
        dark:     RGBA(0.10, 0.09, 0.09),
        tan:      RGBA(0.80, 0.55, 0.28),
        tanShade: RGBA(0.64, 0.42, 0.20),
        saddle:   RGBA(0.08, 0.07, 0.07))

    // Solid red/ginger — warm all over with a low-contrast, same-hue saddle.
    static let red = Palette(
        name: "red",
        outline:  RGBA(0.34, 0.15, 0.07),
        body:     RGBA(0.74, 0.37, 0.15),
        bodyHi:   RGBA(0.87, 0.52, 0.23),
        shade:    RGBA(0.55, 0.26, 0.12),
        dark:     RGBA(0.60, 0.28, 0.11),
        tan:      RGBA(0.93, 0.69, 0.41),
        tanShade: RGBA(0.81, 0.55, 0.31),
        saddle:   RGBA(0.58, 0.26, 0.10))

    // Cream/blond — a pale coat; the outline warms to soft brown so it doesn't
    // read as harsh black against the light body.
    static let cream = Palette(
        name: "cream",
        outline:  RGBA(0.46, 0.35, 0.23),
        body:     RGBA(0.87, 0.75, 0.55),
        bodyHi:   RGBA(0.94, 0.85, 0.66),
        shade:    RGBA(0.73, 0.60, 0.42),
        dark:     RGBA(0.68, 0.55, 0.37),
        tan:      RGBA(0.95, 0.88, 0.72),
        tanShade: RGBA(0.85, 0.74, 0.56),
        saddle:   RGBA(0.72, 0.58, 0.40))
}

// MARK: - Sprite geometry

enum Sprite {
    /// Side length (points) of one pixel-art cell for a pet of `size` points.
    /// Rounded to a whole number so every cell lands on integer point
    /// boundaries — the sprite scales crisply (no half-pixel cells) at any
    /// configured size. Shared by the renderer's body/head/shadow passes.
    static func cell(forSize s: CGFloat) -> CGFloat { max(2, (s / 26).rounded()) }
}

// MARK: - Expression model

enum EyeState { case open, closed, happy, worried }
enum MouthState { case neutral, smile, pant, open, yawn }
enum Accessory { case wave, think, gear, sparkle, sweat, sleep }

/// Which way the dog is looking. The pet turns at random intervals so it feels
/// alive — mostly side-on, occasionally facing you.
enum Facing {
    case right, left, front

    /// Pick a facing to turn to, different from `current`, given a uniform
    /// random value in [0, 1). Sides are weighted heavier than front.
    static func turn(from current: Facing, random r: Double) -> Facing {
        var opts: [(Facing, Double)] = []
        if current != .right { opts.append((.right, 0.4)) }
        if current != .left  { opts.append((.left,  0.4)) }
        if current != .front { opts.append((.front, 0.3)) }
        let total = opts.reduce(0) { $0 + $1.1 }
        let pick = r * total
        var acc = 0.0
        for (f, w) in opts { acc += w; if pick < acc { return f } }
        return opts.last!.0
    }
}

// MARK: - Cursor gaze (look-at pointer)
//
// When the pointer comes near, the pet watches it: its eyes shift toward the
// cursor and its head turns via the three existing facings, instead of glancing
// around on its own. Pure geometry so it's unit-tested without AppKit — the view
// feeds in the vector from the pet's head to the cursor (screen points) and the
// pet size, and `Gaze` decides whether the pointer is "near", which way to face,
// and how far to nudge the pupils. It carries no motion of its own, so the
// renderer suppresses it under Reduce Motion just like the autonomous glancing.
struct Gaze {
    var active: Bool = false   // pointer is near enough to track
    var facing: Facing = .front
    var pupil: CGVector = .zero // eye offset in *cells*, each component in [-1, 1]

    /// Not watching anything — eyes centered, facing left to the caller.
    static let none = Gaze()

    /// - Parameters:
    ///   - dx: horizontal offset from the pet's head to the cursor, in points (+ = cursor to the right).
    ///   - dy: vertical offset, in points (+ = cursor above the head; AppKit y grows upward).
    ///   - size: the pet's rendered size (`config.size`), used to scale the "near" range.
    static func toward(dx: CGFloat, dy: CGFloat, size: CGFloat) -> Gaze {
        let radius = size * 4                       // "near" range — generous, so it feels attentive
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 0.001, dist <= radius else { return .none }
        // Head faces the side the cursor is clearly on; a ±size horizontal
        // dead-zone keeps it front-on (looking at you) when the cursor is above
        // or near the center, and prevents rapid left/right flip-flopping.
        let facing: Facing = dx < -size ? .left : (dx > size ? .right : .front)
        let nx = max(-1, min(1, dx / (size * 0.9)))
        let ny = max(-1, min(1, dy / (size * 0.9)))
        return Gaze(active: true, facing: facing, pupil: CGVector(dx: nx, dy: ny))
    }
}

// MARK: - Click vs. drag (pet the dog without repositioning it)
//
// The pet body is both a drag handle (move it around the desktop) and a pet
// target (a plain click triggers the `loved` reaction). A press is a *click*
// only while the pointer stays within `dragThreshold` points of where it went
// down; the moment it travels further it's a drag and no petting happens, so
// repositioning never accidentally pets. Pure + testable; the view supplies the
// measured travel.
enum Interaction {
    /// Pointer travel (points) below which a press is treated as a click.
    static let dragThreshold: CGFloat = 4

    /// Whether a press whose greatest travel was `maxDisplacement` points is a click.
    static func isClick(maxDisplacement: CGFloat) -> Bool {
        maxDisplacement <= dragThreshold
    }
}

struct DogFeatures {
    var eyes: EyeState = .open
    var mouth: MouthState = .smile
    var wag: Double = 2          // tail-wag speed (0 = still)
    var tailDown: Bool = false   // tuck the tail (worried)
}

// MARK: - Pose (deep module: a mood decodes to everything needed to render)

struct Pose {
    var bob: CGFloat = 0        // whole-body hop (a genuine jump leaves the ground)
    var scaleY: CGFloat = 1     // whole-body breathing / landing squash
    var scaleX: CGFloat = 1     // whole-body horizontal stretch (the long-dog stretch antic)
    var headTilt: CGFloat = 0   // radians — tilt just the head (curious)
    var headBob: CGFloat = 0    // head vertical offset in cells (+ up / − nose-down sniff)
    var tremble: CGFloat = 0    // head jitter amplitude in cells (fear)
    var accessory: Accessory? = nil
    var bubble: String? = nil
    var feat = DogFeatures()

    /// How much of the model's "raw" motion survives once Reduce Motion is
    /// respected: `1` normally, damped to `reducedMotionScale` (~15%) when the
    /// OS setting is on. Non-essential bobbing/tilting/trembling below is
    /// scaled by it directly; the renderer applies the same value to its own
    /// tail/ear/accessory/pant amplitudes (see pet.swift). Expressions — eyes,
    /// mouth, accessory kind, bubble text — are never touched by this: only
    /// the wobble is damped, not what the pet is communicating.
    var motionScale: CGFloat = 1
    static let reducedMotionScale: CGFloat = 0.15

    /// Build the render frame for `mood`. Thin adapter over the behavior
    /// pipeline (`PetBehaviors`): it packages the inputs into a `BehaviorContext`
    /// and composes the ordered behaviors into a single `Pose`. The mood's
    /// expression and the idle-antic overlay are themselves behaviors, so a new
    /// behavior (cursor-chase, gravity, perch…) slots into the pipeline without
    /// touching this signature or the renderer's `draw()`. Kept as the stable
    /// entry point so every existing call site (and unit test) is unchanged.
    static func make(for mood: Mood, phase: Double, message: String, reduceMotion: Bool = false,
                     antic: Antic? = nil, anticPhase: Double = 0) -> Pose {
        let ctx = BehaviorContext(mood: mood, phase: phase, message: message,
                                  reduceMotion: reduceMotion,
                                  motionScale: reduceMotion ? reducedMotionScale : 1,
                                  antic: antic, anticPhase: anticPhase)
        return PetBehaviors.render(ctx)
    }
}

// MARK: - Idle antics (autonomous idle variety)
//
// Plain idle is calm breathing. To keep the pet from feeling too predictable,
// it occasionally performs a short antic — a stretch, a yawn, an ear scratch —
// at relaxed intervals. Antics are purely *local* liveliness: they are not on
// the wire, an agent cannot request them, and they play only while the mood is
// `idle` (any real mood cancels them, and Reduce Motion suppresses them). The
// selection + scheduling is pure and unit-tested here; the renderer only drives
// the clock and draws the resulting Pose.

/// One idle flourish. Each reuses the existing head/body split in `Pose` rather
/// than moving the whole sprite, so it stays crisp and genuine.
enum Antic: String, CaseIterable {
    case stretch, yawn, scratch, sniff, dig, chaseTail, sit

    /// Seconds the antic plays before the pet settles back to plain idle.
    var duration: Double {
        switch self {
        case .stretch:   return 1.9
        case .yawn:      return 1.5
        case .scratch:   return 1.7
        case .sniff:     return 2.2
        case .dig:       return 1.7
        case .chaseTail: return 1.7
        case .sit:       return 2.4
        }
    }

    /// Relative likelihood in the weighted pick — calm antics are commoner and
    /// energetic ones rarer, so idle stays mostly serene.
    var weight: Double {
        switch self {
        case .stretch:   return 1.4
        case .yawn:      return 1.3
        case .sniff:     return 1.2
        case .sit:       return 1.1
        case .scratch:   return 1.0
        case .dig:       return 0.7
        case .chaseTail: return 0.6
        }
    }

    /// Overlay this antic's part-based motion onto an idle `Pose`. `anticPhase`
    /// is seconds since the antic began (0…`duration`). A `sin(πu)` envelope
    /// ramps every antic up from — and back down to — the resting idle pose, so
    /// it blends in and out without a jump. Discrete expression changes (closed
    /// eyes, open mouth, …) are gated behind the envelope for the same reason:
    /// at `anticPhase == 0` an antic is a no-op, identical to plain idle.
    func apply(_ p: inout Pose, anticPhase: Double) {
        let u = max(0, min(1, anticPhase / duration))
        let env = sin(.pi * u)              // 0 → 1 → 0
        let e = CGFloat(env)
        let t = anticPhase
        switch self {
        case .stretch:
            // A long dachshund stretch: the body extends and the front bows down.
            p.scaleX = 1 + 0.18 * e
            p.scaleY -= 0.05 * e
            p.headBob = -1.3 * e
        case .yawn:
            // Head lifts, eyes scrunch shut and the mouth gapes at the peak.
            p.headBob = 0.5 * e
            if env > 0.5 { p.feat.eyes = .closed; p.feat.mouth = .yawn }
        case .scratch:
            // Head cocks to one side and buzzes as a hind leg thumps the ear.
            p.headTilt = 0.16 * e
            p.tremble = 0.5 * e
            if env > 0.25 { p.feat.eyes = .happy }
        case .sniff:
            // Nose to the ground, sweeping slowly side to side.
            p.headBob = -1.6 * e
            p.headTilt = CGFloat(sin(t * 3.2) * 0.09) * e
        case .dig:
            // Quick, eager digging — the nose jabs down as the body bobs.
            let fast = abs(sin(t * 12))
            p.headBob = CGFloat(-0.7 - fast * 0.8) * e
            p.bob = CGFloat(fast * 3) * e
            if env > 0.25 { p.feat.mouth = .pant }
        case .chaseTail:
            // Spins after its own tail: head cranes back, little hops, fast wag.
            p.headTilt = 0.30 * e
            p.bob = CGFloat(abs(sin(t * 7)) * 6) * e
            if env > 0.25 { p.feat.wag = 12 }
        case .sit:
            // Settles onto its haunches, head held high and calm.
            p.scaleY -= 0.09 * e
            p.headBob = 0.35 * e
            if env > 0.25 { p.feat.wag = 1 }
        }
    }
}

/// Pure scheduling + weighted selection for idle antics. No time source or RNG
/// of its own — the caller supplies the clock and uniform random values — so it
/// is fully deterministic under test.
enum IdleAntics {
    /// Relaxed gap between antics, in seconds. Idle should feel calm, not busy.
    static let minGap: Double = 6
    static let maxGap: Double = 15

    /// Seconds until the next antic, from a uniform random value in [0, 1).
    static func nextGap(random r: Double) -> Double {
        minGap + max(0, min(1, r)) * (maxGap - minGap)
    }

    /// Weighted-random antic for `random` in [0, 1), never repeating `avoiding`
    /// so the pet doesn't perform the same trick twice in a row.
    static func pick(random r: Double, avoiding: Antic? = nil) -> Antic {
        let opts = Antic.allCases.filter { $0 != avoiding }
        let total = opts.reduce(0) { $0 + $1.weight }
        let pick = max(0, min(1, r)) * total
        var acc = 0.0
        for a in opts { acc += a.weight; if pick < acc { return a } }
        return opts.last!
    }
}

// MARK: - Behavior composition (pluggable frame contributors)
//
// A pet's on-screen frame is built by *composing* small behaviors rather than
// growing one switch. Each `Behavior` reads the immutable per-frame inputs
// (`BehaviorContext`) and contributes to a shared, mutable `Pose`. The renderer
// only ever consumes the final `Pose`, so a new behavior (cursor-chase,
// gravity, perch, extra flourishes…) is added by slotting it into
// `PetBehaviors.pipeline` — never by editing `draw()`.
//
// Today the pipeline is two behaviors: `MoodExpression` (the deep module that
// decodes a mood into features + motion) and `IdleAnticLayer` (the autonomous
// idle flourishes). Both are pure and unit-tested; adding a third leaves them
// untouched. This is the pet's "YAGE-style" composition core.

/// Immutable inputs a behavior may read while contributing to a frame.
struct BehaviorContext {
    let mood: Mood
    let phase: Double          // animation clock, in seconds
    let message: String        // agent-supplied bubble text (may be empty)
    let reduceMotion: Bool     // OS or config Reduce Motion in effect
    let motionScale: CGFloat   // 1 normally, damped to ~15% under Reduce Motion
    let antic: Antic?          // idle flourish currently playing, if any
    let anticPhase: Double     // seconds since that antic began
}

/// One frame contributor. Behaviors are side-effect-light: they mutate the
/// passed-in `Pose` and read only the context — no IO, no global state — so the
/// whole pipeline stays deterministic and testable without a running app.
protocol Behavior {
    func apply(to pose: inout Pose, _ ctx: BehaviorContext)
}

/// The deep expression module: a mood decodes to everything needed to render
/// (breathing, hops, head motion, eyes/mouth/tail, accessory, bubble). Ambient
/// wobble is damped by `ctx.motionScale`; discrete expression is not.
struct MoodExpression: Behavior {
    func apply(to p: inout Pose, _ ctx: BehaviorContext) {
        let scale = ctx.motionScale
        let phase = ctx.phase
        let message = ctx.message
        switch ctx.mood {
        case .idle:
            // Calm breathing; the tail sways and the ear ticks (handled in draw).
            p.scaleY = 1 + sin(phase * 2.2) * 0.02 * scale
            p.feat = DogFeatures(eyes: .open, mouth: .smile, wag: 2)
        case .sleeping:
            // Slow deep breaths; the head rises and falls with each breath.
            p.scaleY = 1 + sin(phase * 1.8) * 0.035 * scale
            p.headBob = sin(phase * 1.8) * 0.4 * scale
            p.feat = DogFeatures(eyes: .closed, mouth: .neutral, wag: 0)
            p.accessory = .sleep
        case .greet:
            // Eager little hops with a fast wagging tail.
            p.bob = abs(sin(phase * 7)) * 8 * scale
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 12)
            p.accessory = .wave; p.bubble = "hi!"
        case .thinking:
            // Curious head tilt side to side — the body stays put.
            p.headTilt = sin(phase * 1.5) * 0.22 * scale
            p.feat = DogFeatures(eyes: .open, mouth: .neutral, wag: 1)
            p.accessory = .think; p.bubble = message.isEmpty ? "thinking…" : message
        case .working:
            // Nose-down sniffing/digging while it works; panting tongue.
            p.headBob = -abs(sin(phase * 5)) * 1.4 * scale
            p.feat = DogFeatures(eyes: .open, mouth: .pant, wag: 5)
            p.accessory = .gear; p.bubble = message.isEmpty ? "working…" : message
        case .happy:
            // Springy bounce with a squash-and-stretch on the landing.
            let hop = abs(sin(phase * 6))
            p.bob = hop * 16 * scale
            p.scaleY = 1 + ((1 - hop) * 0.06 - hop * 0.03) * scale
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 13)
            p.accessory = .sparkle; p.bubble = message.isEmpty ? "done!" : message
        case .celebrate:
            // A milestone party — bigger, bouncier hops than the routine "done!"
            // plus a little side-to-side wiggle, so it reads as a distinct,
            // special celebration (tests pass, a PR opened/merged).
            let hop = abs(sin(phase * 6.5))
            p.bob = hop * 22 * scale                          // higher than happy's 16
            p.scaleY = 1 + ((1 - hop) * 0.08 - hop * 0.04) * scale
            p.headTilt = sin(phase * 9) * 0.14 * scale        // giddy wiggle
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 16)
            p.accessory = .sparkle; p.bubble = message.isEmpty ? "🎉" : message
        case .nudge:
            // A gentle break reminder: a slow yawn and a sleepy head-tilt with a
            // zzz. Deliberately low-energy so it invites rest without stealing
            // attention; it still faces you (open eyes) rather than dozing off.
            p.scaleY = 1 + sin(phase * 1.8) * 0.03 * scale
            p.headBob = 0.4 * scale
            p.headTilt = sin(phase * 1.2) * 0.10 * scale
            p.feat = DogFeatures(eyes: .open, mouth: .yawn, wag: 1)
            p.accessory = .sleep; p.bubble = message.isEmpty ? "take a break?" : message
        case .loved:
            // Petting reaction: a delighted wriggle — quick little hops, a fast
            // wagging tail and blushing (happy eyes) with a ♥. Deliberately has
            // no accessory so it never reads as the "done!" sparkle.
            let hop = abs(sin(phase * 7))
            p.bob = hop * 12 * scale
            p.scaleY = 1 + ((1 - hop) * 0.05 - hop * 0.03) * scale
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 14)
            p.bubble = "♥"
        case .worried:
            // Cowering: head lowered and trembling, tail tucked.
            p.headBob = -0.7 * scale
            p.tremble = 0.5 * scale
            p.feat = DogFeatures(eyes: .worried, mouth: .open, wag: 0, tailDown: true)
            p.accessory = .sweat; p.bubble = message.isEmpty ? "uh oh" : message
        }
    }
}

/// Overlays the idle antic (stretch, yawn, sniff…) onto the calm idle pose.
/// Only in `idle`, and never under Reduce Motion, so a real mood's expression
/// always takes precedence — an antic never fights a mood, and eases in from
/// rest. This runs after `MoodExpression`, layering on top of its pose.
struct IdleAnticLayer: Behavior {
    func apply(to p: inout Pose, _ ctx: BehaviorContext) {
        guard ctx.mood == .idle, let antic = ctx.antic, !ctx.reduceMotion else { return }
        antic.apply(&p, anticPhase: ctx.anticPhase)
    }
}

/// The active behavior pipeline and the composition entry point. New behaviors
/// are added to `pipeline` — the renderer never changes.
enum PetBehaviors {
    /// Ordered composition run every frame: expression first, then overlays.
    static let pipeline: [Behavior] = [MoodExpression(), IdleAnticLayer()]

    /// Compose `behaviors` (defaulting to `pipeline`) into a single frame.
    /// `motionScale` is seeded on the fresh `Pose` so every behavior sees the
    /// same Reduce-Motion damping factor, then each behavior contributes in
    /// order. Pure: given the same context it always returns the same `Pose`.
    static func render(_ ctx: BehaviorContext, through behaviors: [Behavior] = pipeline) -> Pose {
        var p = Pose()
        p.motionScale = ctx.motionScale
        for b in behaviors { b.apply(to: &p, ctx) }
        return p
    }
}

// MARK: - Config (user settings; hot-reloaded from config.json)

/// User-adjustable settings, parsed from `config.json` next to the extension.
/// Every field is optional in the file; missing or malformed keys keep the
/// defaults here, so an absent or partial config is always valid. Pure and
/// testable — no file IO lives in this type (see `docs/config.md`).
struct PetConfig: Equatable {
    var size: CGFloat = 62
    var lookAroundMin: Double = 4
    var lookAroundMax: Double = 9
    var behaviors: Set<String> = ["lookAround", "bubbles"]
    var muted: Bool = false
    var reduceMotion: Bool = false
    var breed: String = "dachshund"      // reserved: only the dachshund is drawn today
    var palette: String = "chestnut"     // coat colour scheme (see Palette.named)
    var name: String = ""                // optional pet name, surfaced subtly (tooltip + greet)
    var speed: Double = 1                // animation speed multiplier (0.5…2.0)
    // Wellness nudges (issue #8). These are consumed by the *controller*
    // (extension.mjs), which detects milestones and long work runs — the
    // renderer never reads them. Parsed and clamped here so the config schema
    // stays one documented, unit-tested model (like `breed`).
    var celebrateMilestones: Bool = false // party animation when tests pass / a PR opens/merges
    var breakReminderMinutes: Double = 0  // 0 = off; nudge after this many minutes of continuous work
    /// What a double-click on the pet opens. Empty = the default host app
    /// (the GitHub Copilot app that spawned the pet); a bundle id, an app
    /// name/path, or "none"/"off" to disable. See `doubleClickAction`.
    var openOnDoubleClick: String = ""

    /// Behaviors the pet understands today. Unknown entries in the file are ignored.
    static let knownBehaviors: Set<String> = ["lookAround", "bubbles"]

    /// The coat colour scheme to render, resolved from `palette` (falls back to
    /// the default coat for an unknown name).
    var resolvedPalette: Palette { Palette.named(palette) }

    /// Resolved meaning of `openOnDoubleClick`, kept pure (no AppKit) so it can
    /// be unit-tested; the view just switches on it to drive `NSWorkspace`.
    var doubleClickAction: DoubleClickAction {
        let raw = openOnDoubleClick.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .openDefaultHost }
        if ["none", "off", "disabled", "false"].contains(raw.lowercased()) { return .disabled }
        // A path or an app bundle: open by file URL.
        if raw.hasSuffix(".app") || raw.contains("/") { return .openApp(raw) }
        // Reverse-DNS with no spaces looks like a bundle identifier.
        if raw.contains(".") && !raw.contains(" ") { return .openBundleId(raw) }
        // Otherwise treat it as an application name, e.g. "Copilot".
        return .openApp(raw)
    }

    /// Seconds between autonomous glances (left / right / at-you).
    var lookAroundInterval: ClosedRange<Double> { lookAroundMin...lookAroundMax }
    /// Glancing around is on unless the user turns it off.
    var lookAround: Bool { behaviors.contains("lookAround") }
    /// Speech bubbles show only when enabled *and* not muted.
    var bubblesEnabled: Bool { !muted && behaviors.contains("bubbles") }

    /// Merge a decoded JSON object over the defaults. Wrong types are ignored so
    /// a malformed value never crashes the pet — it falls back to the default.
    static func parse(_ obj: [String: Any]?) -> PetConfig {
        var c = PetConfig()
        guard let obj = obj else { return c }

        if let n = obj["size"] as? Double { c.size = CGFloat(min(160, max(32, n))) }

        // lookAroundInterval: a single number (fixed) or a [min, max] pair, seconds.
        switch obj["lookAroundInterval"] {
        case let n as Double:
            let v = max(1, n); c.lookAroundMin = v; c.lookAroundMax = v
        case let arr as [Any]:
            let nums = arr.compactMap { $0 as? Double }
            if nums.count >= 2 {
                c.lookAroundMin = max(1, min(nums[0], nums[1]))
                c.lookAroundMax = max(c.lookAroundMin, max(nums[0], nums[1]))
            }
        default: break
        }

        if let arr = obj["enabledBehaviors"] as? [Any] {
            c.behaviors = Set(arr.compactMap { $0 as? String }).intersection(knownBehaviors)
        }
        if let b = obj["muted"] as? Bool { c.muted = b }
        if let b = obj["reduceMotion"] as? Bool { c.reduceMotion = b }
        if let s = obj["breed"] as? String, !s.isEmpty { c.breed = s }
        if let s = obj["palette"] as? String, !s.isEmpty { c.palette = s }
        if let s = obj["name"] as? String { c.name = String(s.prefix(24)) }
        if let n = obj["speed"] as? Double { c.speed = min(2, max(0.5, n)) }
        if let b = obj["celebrateMilestones"] as? Bool { c.celebrateMilestones = b }
        // 0 (or any non-positive value) means "off"; a positive value is clamped
        // to a sane 1…600-minute window.
        if let n = obj["breakReminderMinutes"] as? Double {
            c.breakReminderMinutes = n <= 0 ? 0 : min(600, max(1, n))
        }
        if let s = obj["openOnDoubleClick"] as? String { c.openOnDoubleClick = s }
        return c
    }
}

/// What a double-click on the pet should do (pure; the AppKit view maps this
/// onto `NSWorkspace`). `.openDefaultHost` targets the GitHub Copilot app that
/// spawned the pet.
enum DoubleClickAction: Equatable {
    case disabled
    case openDefaultHost
    case openBundleId(String)   // e.g. "com.github.githubapp"
    case openApp(String)        // an app name ("Copilot") or a path ("/Applications/Foo.app")
}

// MARK: - Multi-session arbitration
//
// One desktop pet is shared by *every* local Copilot session. Each session's
// controller writes its own state file under `sessions/<id>.json`; the pet reads
// them all and this pure arbiter decides what the single pet should do. Keeping
// the logic here (no AppKit) means it is exercised directly by PetCoreTests.
//
// Rules:
//   • Most-recent-activity wins — the session that changed mood last drives the pet.
//   • Control signals (`hidden` / `quit`) from the winning session act on the one
//     shared pet, i.e. they are respected globally.
//   • Greets are de-duped across processes: a greet only plays on the transition
//     from no live sessions to some, so opening N sessions never means N "hi!"s.
//   • A session whose controller stopped heart-beating is considered dead and is
//     ignored (and eventually pruned).

/// A snapshot of one session's state file, as seen by the pet.
struct SessionSnapshot: Equatable {
    let id: String
    let mood: String        // raw wire value; may be a control signal
    let message: String
    let activity: Double    // ms since epoch — when this session last changed mood
    let heartbeat: Double   // ms since epoch — controller liveness
}

/// What the shared pet should do this tick.
enum PetCommand: Equatable {
    case show(Mood, message: String)
    case hide
    case quit
}

/// The arbiter's verdict. `winner`/`activity` form a change key so the renderer
/// only reacts (resets timers, re-faces) when the driving session actually changes.
struct Resolution: Equatable {
    let command: PetCommand
    let winner: String
    let activity: Double
}

enum Arbitration {
    /// A controller heartbeat older than this (ms) means its session is dead.
    static let staleAfterMs: Double = 12_000

    /// Sessions still considered alive at `now` (ms since epoch).
    static func liveSessions(_ sessions: [SessionSnapshot], now: Double) -> [SessionSnapshot] {
        sessions.filter { now - $0.heartbeat <= staleAfterMs }
    }

    /// Decide what the shared pet should do.
    ///
    /// - Parameters:
    ///   - sessions: every session state file the pet found.
    ///   - now: current time in ms since epoch.
    ///   - hadLiveSessions: whether a live session existed on the previous tick.
    ///     Used to de-dupe greets — a greet is only honored on the 0→N transition.
    /// - Returns: `nil` when no session is live (the caller keeps the current pose;
    ///   the heartbeat watchdog handles termination).
    static func resolve(_ sessions: [SessionSnapshot], now: Double, hadLiveSessions: Bool) -> Resolution? {
        let live = liveSessions(sessions, now: now)
        guard !live.isEmpty else { return nil }

        // Most-recent-activity wins; deterministic id tie-break for stability.
        let winner = live.max { a, b in
            a.activity != b.activity ? a.activity < b.activity : a.id < b.id
        }!

        let command: PetCommand
        switch winner.mood {
        case "quit":
            command = .quit
        case "hidden":
            command = .hide
        default:
            var mood = Mood(rawValue: winner.mood) ?? .idle
            // De-dupe greets across processes: a session that boots while others
            // are already live shows idle instead of a redundant second "hi!".
            if mood == .greet && hadLiveSessions { mood = .idle }
            command = .show(mood, message: winner.message)
        }
        return Resolution(command: command, winner: winner.id, activity: winner.activity)
    }
}
