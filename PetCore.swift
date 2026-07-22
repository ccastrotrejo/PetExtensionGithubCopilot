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
