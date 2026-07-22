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

    /// Automatic transition after a mood has been shown for `after` seconds.
    var autoNext: (after: TimeInterval, to: Mood)? {
        switch self {
        case .greet:   return (1.6, .idle)
        case .happy:   return (1.5, .idle)      // "done!" celebration, then relax
        case .worried: return (2.4, .idle)
        case .idle:    return (18,  .sleeping)
        default:       return nil               // thinking / working persist until the next event
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

// MARK: - Expression model

enum EyeState { case open, closed, happy, worried }
enum MouthState { case neutral, smile, pant, open }
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

    static func make(for mood: Mood, phase: Double, message: String, reduceMotion: Bool = false) -> Pose {
        var p = Pose()
        let scale: CGFloat = reduceMotion ? reducedMotionScale : 1
        p.motionScale = scale
        switch mood {
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
        case .worried:
            // Cowering: head lowered and trembling, tail tucked.
            p.headBob = -0.7 * scale
            p.tremble = 0.5 * scale
            p.feat = DogFeatures(eyes: .worried, mouth: .open, wag: 0, tailDown: true)
            p.accessory = .sweat; p.bubble = message.isEmpty ? "uh oh" : message
        }
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
    var breed: String = "dachshund"      // reserved for the personalization issue
    var palette: String = "chestnut"     // reserved for the personalization issue

    /// Behaviors the pet understands today. Unknown entries in the file are ignored.
    static let knownBehaviors: Set<String> = ["lookAround", "bubbles"]

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
        return c
    }
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
