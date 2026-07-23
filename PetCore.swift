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

// MARK: - Petdex interop (pet-pack format + spritesheet mapping)
//
// A "pet pack" is a Petdex-compatible pet: a `pet.json` plus a spritesheet laid
// out as an 8×9 grid of 192×208 frames (see docs/petdex.md and
// https://github.com/crafter-station/petdex). The rows are animation *states*;
// the columns are the frames of that state's loop. This enum, the Mood→state
// mapping, and the frame math are all pure so they're exercised directly by
// PetCoreTests without decoding an image or running the app.

/// The eight animation rows of a Petdex spritesheet, top to bottom. The raw
/// value is only for debugging; `row` is the authoritative sheet index. A ninth
/// grid row exists in the format but is a spare we never sample.
enum PetdexState: String, CaseIterable {
    case idle, wave, run, failed, review, jump, extra1, extra2

    /// 0-based row index into the spritesheet grid.
    var row: Int {
        switch self {
        case .idle:   return 0
        case .wave:   return 1
        case .run:    return 2
        case .failed: return 3
        case .review: return 4
        case .jump:   return 5
        case .extra1: return 6
        case .extra2: return 7
        }
    }
}

extension Mood {
    /// Map our mood vocabulary onto Petdex animation states so an installed
    /// spritesheet pet reacts to the same Copilot signals as the bespoke dog.
    /// Chosen so the pet reads correctly even though Petdex sheets are a fixed,
    /// forward-facing set: greeting waves, work runs, failures play `failed`,
    /// thinking uses the calmer `review`, and celebrations jump.
    var petdexState: PetdexState {
        switch self {
        case .greet:     return .wave
        case .thinking:  return .review
        case .working:   return .run
        case .happy:     return .jump
        case .celebrate: return .jump
        case .nudge:     return .wave
        case .loved:     return .wave
        case .worried:   return .failed
        case .idle:      return .idle
        case .sleeping:  return .idle
        }
    }
}

/// Geometry + timing of a Petdex spritesheet, resolved from a decoded image's
/// pixel dimensions. Kept pure (no CoreGraphics image type) so frame math is
/// unit-tested against plain integers. The invariant across Petdex sheets is the
/// **192×208 frame size**, not a fixed row count — curated sheets vary (e.g. 8×9
/// vs 8×11) — so we derive cols/rows by dividing the image by the frame size.
struct SpriteSheet: Equatable {
    let cols: Int          // frames per state (Petdex: 8)
    let rows: Int          // animation-state rows in the grid (≥8; varies by sheet)
    let frameW: Int        // px width of one frame
    let frameH: Int        // px height of one frame
    let fps: Double        // playback frames per second (Petdex default: 6)

    /// The canonical Petdex frame + grid.
    static let standardFrameW = 192
    static let standardFrameH = 208
    static let defaultCols = 8
    static let defaultRows = 9
    static let defaultFPS: Double = 6

    /// Derive the grid from an image's pixel size, assuming Petdex's fixed
    /// 192×208 frames. Returns nil unless the image divides cleanly into whole
    /// frames of that size (a sheet we can't trust to slice). Both homelander
    /// (8×9) and boba (8×11) satisfy this — only the row count differs.
    static func from(imageWidth w: Int, imageHeight h: Int,
                     frameW: Int = standardFrameW, frameH: Int = standardFrameH,
                     fps: Double = defaultFPS) -> SpriteSheet? {
        guard frameW > 0, frameH > 0, w >= frameW, h >= frameH,
              w % frameW == 0, h % frameH == 0 else { return nil }
        return SpriteSheet(cols: w / frameW, rows: h / frameH, frameW: frameW, frameH: frameH, fps: fps)
    }

    /// Which column (0-based) a state's loop is on at animation-clock `phase`
    /// (seconds). Static (fps 0 or Reduce Motion) freezes on the first frame.
    func frameIndex(phase: Double, frozen: Bool = false) -> Int {
        guard cols > 0 else { return 0 }
        if frozen || fps <= 0 { return 0 }
        let n = Int((phase * fps).rounded(.down))
        return ((n % cols) + cols) % cols
    }

    /// The pixel rect of one frame in *top-left origin* image space (the natural
    /// coordinate system of a decoded CGImage), so callers can crop directly.
    func frameRect(state: PetdexState, col: Int) -> CGRect {
        let c = min(max(0, col), cols - 1)
        let r = min(max(0, state.row), rows - 1)
        return CGRect(x: c * frameW, y: r * frameH, width: frameW, height: frameH)
    }
}

/// The metadata half of a pet pack — the parsed `pet.json`. The spritesheet
/// itself is decoded by the renderer; this only carries what the format
/// documents (`id`, `displayName`, `description`, `spritesheetPath`).
struct PetPackInfo: Equatable {
    var id: String
    var displayName: String
    var description: String
    var spritesheetPath: String

    /// Parse a decoded `pet.json`. `slug` seeds sensible fallbacks so a sparse
    /// file (only `spritesheetPath`, say) still yields a usable pack. Returns nil
    /// only when there's no spritesheet path to render at all.
    static func parse(_ obj: [String: Any]?, slug: String) -> PetPackInfo? {
        let obj = obj ?? [:]
        let sheet = (obj["spritesheetPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pack with no declared sheet path falls back to the conventional file
        // name; only reject when we truly have nothing to point at.
        let path = (sheet?.isEmpty == false ? sheet! : "spritesheet.webp")
        let id = (obj["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
        let name = (obj["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
        let desc = (obj["description"] as? String) ?? ""
        return PetPackInfo(id: id, displayName: name, description: desc, spritesheetPath: path)
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
    var walk: Double = 0        // walk-cycle phase (seconds) driving the roam leg gait; 0 = standing still
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
                     antic: Antic? = nil, anticPhase: Double = 0, work: WorkActivity = .general,
                     walking: Bool = false, walkPhase: Double = 0) -> Pose {
        let ctx = BehaviorContext(mood: mood, phase: phase, message: message,
                                  reduceMotion: reduceMotion,
                                  motionScale: reduceMotion ? reducedMotionScale : 1,
                                  antic: antic, anticPhase: anticPhase, work: work,
                                  walking: walking, walkPhase: walkPhase)
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

// MARK: - Work activity (tool-specific micro-behaviors)
//
// While the pet is `working`, its base pose is a nose-down sniff/pant that reads
// the same for every tool. To give signature actions their own bit of life, the
// agent's *tool name* is mapped to a small set of work styles, each overlaying a
// distinct micro-animation onto the working pose (see `WorkActivityLayer`).
// Categorisation is pure + unit-tested and lives only here; the controller
// (`extension.mjs`) just forwards the raw tool name over the wire as `tool`.
//
// Deliberately small and gated: only a few signature tools get a bespoke motion
// and the overlay plays *only* in `working`, so common calls (reading a file,
// querying data) stay on the calm base pose and the pet never feels twitchy.

enum WorkActivity: String, CaseIterable {
    case searching   // grep / glob / search — tracks a scent, nose sweeping
    case editing     // edit / create / write — eager digging
    case running     // bash / shell / run — alert, head high, listening
    case general     // everything else — the plain working pose

    /// Map a raw tool name (possibly namespaced, e.g. "github-mcp-server-search_code")
    /// to a work style. The last `-`-separated segment is matched, mirroring
    /// `extension.mjs`'s `prettyTool`. Unknown tools fall back to `.general`, so
    /// only a curated few signature tools ever animate differently.
    static func from(tool raw: String) -> WorkActivity {
        let name = raw.lowercased()
        let key = name.split(separator: "-").last.map(String.init) ?? name
        if ["grep", "glob"].contains(key) || key.contains("search") { return .searching }
        if ["edit", "create", "write"].contains(key) { return .editing }
        if ["bash", "shell", "terminal", "run"].contains(key) { return .running }
        return .general
    }

    /// Overlay this work style's micro-motion onto an already-built `working`
    /// pose. `phase` is the shared animation clock (seconds); motion is damped by
    /// the pose's `motionScale` so Reduce Motion softens it toward the base pose
    /// just like every other behavior. `.general` is a no-op.
    func apply(_ p: inout Pose, phase: Double) {
        let scale = p.motionScale
        switch self {
        case .general:
            break
        case .searching:
            // Tracking a scent: the nose stays down (base sniff) and the head
            // sweeps slowly side to side, following a trail.
            p.headTilt = sin(phase * 3.0) * 0.13 * scale
            p.feat.wag = 3
        case .editing:
            // Eager digging: quick paw bobs with a jabbing nose.
            let fast = abs(sin(phase * 12))
            p.headBob = (-0.7 - fast * 0.8) * scale
            p.bob = fast * 3 * scale
            p.feat.wag = 6
        case .running:
            // Alert and attentive: head held high, body still, listening for the
            // command's output with a subtle side-cock instead of sniffing.
            p.headBob = 0.5 * scale
            p.bob = 0
            p.headTilt = sin(phase * 2.0) * 0.06 * scale
            p.feat.eyes = .open
            p.feat.mouth = .neutral
            p.feat.wag = 3
        }
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
    let work: WorkActivity     // tool style for the working mood (else .general)
    let walking: Bool          // roam-mode: the pet is walking across the desktop
    let walkPhase: Double      // roam-mode: walk-cycle clock (seconds) driving the gait

    // Explicit init with defaults for the newer fields (`work`, `walking`,
    // `walkPhase`) so every call site (Pose.make, tests) that predates
    // tool-specific micro-behaviors and roam mode keeps compiling unchanged.
    init(mood: Mood, phase: Double, message: String, reduceMotion: Bool,
         motionScale: CGFloat, antic: Antic?, anticPhase: Double,
         work: WorkActivity = .general,
         walking: Bool = false, walkPhase: Double = 0) {
        self.mood = mood
        self.phase = phase
        self.message = message
        self.reduceMotion = reduceMotion
        self.motionScale = motionScale
        self.antic = antic
        self.anticPhase = anticPhase
        self.work = work
        self.walking = walking
        self.walkPhase = walkPhase
    }
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

/// Overlays the tool-specific micro-motion (sniff-track, dig, alert) onto the
/// `working` pose. Only in `working` — any other mood is untouched — so a
/// signature tool enlivens the work pose without ever fighting another mood's
/// expression. Runs after `MoodExpression`, layering on top of its base pose.
struct WorkActivityLayer: Behavior {
    func apply(to p: inout Pose, _ ctx: BehaviorContext) {
        guard ctx.mood == .working else { return }
        ctx.work.apply(&p, phase: ctx.phase)
    }
}

/// Roam-mode locomotion overlay: while the pet is walking across the desktop it
/// gets a gentle trotting bob, a lively tail and a happy panting tongue, and its
/// `walk` phase is published so the renderer can animate the legs (per-leg lift
/// in `draw()`). Runs last so it layers over the calm idle pose it walks out of;
/// a no-op unless `ctx.walking`, so a still pet is byte-for-byte unchanged. The
/// renderer only sets `walking` when roam is enabled and Reduce Motion is off,
/// so this never fights that setting.
struct WalkCycle: Behavior {
    func apply(to p: inout Pose, _ ctx: BehaviorContext) {
        guard ctx.walking else { return }
        p.walk = ctx.walkPhase
        // Trotting bounce — small, integer-friendly, on top of the idle breathing.
        p.bob += CGFloat(abs(sin(ctx.walkPhase * 6))) * 2
        // Happy on-the-move face: perky tail and a panting tongue.
        p.feat.mouth = .pant
        p.feat.wag = max(p.feat.wag, 6)
        p.feat.tailDown = false
    }
}

/// The active behavior pipeline and the composition entry point. New behaviors
/// are added to `pipeline` — the renderer never changes.
enum PetBehaviors {
    /// Ordered composition run every frame: expression first, then overlays.
    static let pipeline: [Behavior] = [MoodExpression(), WorkActivityLayer(), IdleAnticLayer(), WalkCycle()]

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

// MARK: - Roam-mode locomotion (optional; gravity + desktop wander)
//
// When the `roam` behavior is enabled, the pet stops being a static floater and
// instead lives on the desktop floor (the top of the Dock / the screen edge): it
// strolls left and right, obeys gravity so a pet lifted and dropped after a drag
// falls back down and lands, and perches on the floor line. All of that is pure
// physics + a small wander state machine here, kept AppKit-free so it is unit-
// tested without a running app; the renderer (pet.swift) only supplies the frame
// clock and the screen geometry, then applies the resulting window origin.
//
// Coordinates are AppKit screen points (y grows upward). The unit that moves is
// the *window origin*; `floorY` is the origin-y at which the paws rest on the
// floor, and `minX…maxX` is the origin-x travel range that keeps the whole
// window on-screen. Roam is suppressed entirely under Reduce Motion (the
// renderer simply doesn't call `step`), so that setting keeps the pet exactly as
// static + draggable as it is with roam off.
struct Roam {
    // --- tunables (points, seconds) ---
    static let gravity: CGFloat = 2600     // downward acceleration while airborne
    static let maxFall: CGFloat = 2600     // terminal fall speed, so a big drop stays sane
    static let walkSpeed: CGFloat = 42     // ground stroll speed, before the config `speed` multiplier
    static let walkMin = 1.6, walkMax = 4.2   // seconds spent strolling before a pause
    static let pauseMin = 1.4, pauseMax = 4.0 // seconds spent resting before the next stroll
    static let landEps: CGFloat = 0.5      // within this of the floor counts as landed

    enum Gait: Equatable { case walking, pausing }

    var vy: CGFloat = 0        // vertical velocity (+ up); non-zero only while falling
    var gait: Gait = .pausing  // wander phase; starts resting, then picks a direction to stroll
    var dir: CGFloat = 1       // stroll direction: +1 = screen-right, -1 = screen-left
    var timer: Double = 0      // seconds left in the current gait
    var airborne = false       // off the floor last step — so a touchdown fires `landed` exactly once

    /// The next-frame result the renderer applies: the new window origin plus the
    /// flags it needs to pick the pose (walk cycle vs. falling) and a one-shot
    /// `landed` for the landing squash.
    struct Frame: Equatable {
        var x: CGFloat
        var y: CGFloat
        var walking: Bool   // drive the leg walk cycle this frame
        var falling: Bool   // airborne under gravity this frame
        var dir: CGFloat    // facing / travel direction (+1 right, -1 left)
        var landed: Bool    // just touched down this frame (trigger a squash)
    }

    /// Advance the physics one frame.
    /// - Parameters:
    ///   - x, y: the current window origin (may have just been moved by a drag).
    ///   - dt: seconds since the last frame.
    ///   - floorY: origin-y at which the paws rest on the floor.
    ///   - minX, maxX: origin-x travel range keeping the window on-screen.
    ///   - speed: the config animation-speed multiplier (scales the stroll pace).
    ///   - wander: whether the pet may stroll now (idle, no antic/cursor-watch); when
    ///     false it still obeys gravity but just stands once grounded.
    ///   - dragging: the user is holding the pet — physics is frozen until release.
    ///   - random: uniform source in [0, 1) for the wander decisions (injected so this stays testable).
    mutating func step(x: CGFloat, y: CGFloat, dt: Double,
                       floorY: CGFloat, minX: CGFloat, maxX: CGFloat,
                       speed: CGFloat, wander: Bool, dragging: Bool,
                       random: () -> Double) -> Frame {
        let hi = max(minX, maxX)
        func clampX(_ v: CGFloat) -> CGFloat { min(hi, max(minX, v)) }

        // Held by the user: hang where dragged, ready to fall on release. Don't
        // clamp x, so the drag can carry the pet freely; bounds reassert on release.
        if dragging {
            vy = 0; airborne = true; gait = .pausing; timer = 0
            return Frame(x: x, y: y, walking: false, falling: false, dir: dir, landed: false)
        }

        // Airborne: gravity pulls the pet down until the paws reach the floor.
        if y > floorY + Self.landEps {
            vy = max(vy - Self.gravity * CGFloat(dt), -Self.maxFall)
            let ny = y + vy * CGFloat(dt)
            if ny > floorY {
                airborne = true
                return Frame(x: clampX(x), y: ny, walking: false, falling: true, dir: dir, landed: false)
            }
            // Touchdown this frame.
            vy = 0
            let landed = airborne
            airborne = false
            gait = .pausing
            timer = Self.pauseMin + random() * (Self.pauseMax - Self.pauseMin)
            return Frame(x: clampX(x), y: floorY, walking: false, falling: false, dir: dir, landed: landed)
        }

        // Grounded: settle exactly on the floor line.
        vy = 0; airborne = false

        // Not free to wander (a real mood, a playing antic, cursor-watching): just
        // stand on the floor, kept within the horizontal bounds.
        guard wander else {
            gait = .pausing
            return Frame(x: clampX(x), y: floorY, walking: false, falling: false, dir: dir, landed: false)
        }

        // Wander state machine: alternate short strolls and rests; each new stroll
        // picks a fresh direction.
        timer -= dt
        if timer <= 0 {
            if gait == .walking {
                gait = .pausing
                timer = Self.pauseMin + random() * (Self.pauseMax - Self.pauseMin)
            } else {
                gait = .walking
                timer = Self.walkMin + random() * (Self.walkMax - Self.walkMin)
                dir = random() < 0.5 ? -1 : 1
            }
        }

        guard gait == .walking else {
            return Frame(x: clampX(x), y: floorY, walking: false, falling: false, dir: dir, landed: false)
        }

        // Stroll, bouncing off the screen edges (turn around rather than walk off).
        var nx = x + dir * Self.walkSpeed * speed * CGFloat(dt)
        if nx <= minX { nx = minX; dir = 1 }
        if nx >= hi   { nx = hi;   dir = -1 }
        return Frame(x: nx, y: floorY, walking: true, falling: false, dir: dir, landed: false)
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
    /// Which pet the renderer shows. `"dachshund"` (the flagship, code-drawn dog)
    /// is the default; any other value is treated as an installed Petdex pack
    /// slug loaded from `~/.copilot-pet/pets/<slug>/` (see docs/petdex.md). An
    /// unknown/broken slug falls back to the dachshund at render time.
    var activePet: String = "dachshund"

    /// Behaviors the pet understands today. Unknown entries in the file are ignored.
    static let knownBehaviors: Set<String> = ["lookAround", "bubbles", "roam"]

    /// The reserved slug for the built-in, code-drawn flagship dog. Any other
    /// `activePet` value names an installed Petdex pack.
    static let dachshundSlug = "dachshund"

    /// Whether the flagship code-drawn dog is active (vs. an installed Petdex pack).
    var usesDachshund: Bool {
        let s = activePet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty || s == PetConfig.dachshundSlug
    }

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
    /// Roaming (walk around + gravity + perch on the desktop floor). Opt-in: off
    /// unless the user adds `"roam"` to `enabledBehaviors`.
    var roam: Bool { behaviors.contains("roam") }
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
        // Active pet: the flagship dog by default, or an installed Petdex slug.
        // Only a-z0-9/-/_ are accepted so the value is always a safe path segment.
        if let s = obj["activePet"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = !t.isEmpty && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if ok { c.activePet = t }
        }
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
    let tool: String        // raw tool name for the working mood (empty otherwise)

    init(id: String, mood: String, message: String, activity: Double,
         heartbeat: Double, tool: String = "") {
        self.id = id
        self.mood = mood
        self.message = message
        self.activity = activity
        self.heartbeat = heartbeat
        self.tool = tool
    }
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
    let work: WorkActivity  // tool style of the winning working session (else .general)

    init(command: PetCommand, winner: String, activity: Double, work: WorkActivity = .general) {
        self.command = command
        self.winner = winner
        self.activity = activity
        self.work = work
    }
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
        var work: WorkActivity = .general
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
            // Only the working mood carries a tool-specific micro-behavior.
            if mood == .working { work = WorkActivity.from(tool: winner.tool) }
            command = .show(mood, message: winner.message)
        }
        return Resolution(command: command, winner: winner.id, activity: winner.activity, work: work)
    }
}
