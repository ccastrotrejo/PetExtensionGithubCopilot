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

    static func make(for mood: Mood, phase: Double, message: String) -> Pose {
        var p = Pose()
        switch mood {
        case .idle:
            // Calm breathing; the tail sways and the ear ticks (handled in draw).
            p.scaleY = 1 + sin(phase * 2.2) * 0.02
            p.feat = DogFeatures(eyes: .open, mouth: .smile, wag: 2)
        case .sleeping:
            // Slow deep breaths; the head rises and falls with each breath.
            p.scaleY = 1 + sin(phase * 1.8) * 0.035
            p.headBob = sin(phase * 1.8) * 0.4
            p.feat = DogFeatures(eyes: .closed, mouth: .neutral, wag: 0)
            p.accessory = .sleep
        case .greet:
            // Eager little hops with a fast wagging tail.
            p.bob = abs(sin(phase * 7)) * 8
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 12)
            p.accessory = .wave; p.bubble = "hi!"
        case .thinking:
            // Curious head tilt side to side — the body stays put.
            p.headTilt = sin(phase * 1.5) * 0.22
            p.feat = DogFeatures(eyes: .open, mouth: .neutral, wag: 1)
            p.accessory = .think; p.bubble = message.isEmpty ? "thinking…" : message
        case .working:
            // Nose-down sniffing/digging while it works; panting tongue.
            p.headBob = -abs(sin(phase * 5)) * 1.4
            p.feat = DogFeatures(eyes: .open, mouth: .pant, wag: 5)
            p.accessory = .gear; p.bubble = message.isEmpty ? "working…" : message
        case .happy:
            // Springy bounce with a squash-and-stretch on the landing.
            let hop = abs(sin(phase * 6))
            p.bob = hop * 16
            p.scaleY = 1 + (1 - hop) * 0.06 - hop * 0.03
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 13)
            p.accessory = .sparkle; p.bubble = message.isEmpty ? "done!" : message
        case .worried:
            // Cowering: head lowered and trembling, tail tucked.
            p.headBob = -0.7
            p.tremble = 0.5
            p.feat = DogFeatures(eyes: .worried, mouth: .open, wag: 0, tailDown: true)
            p.accessory = .sweat; p.bubble = message.isEmpty ? "uh oh" : message
        }
        return p
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
