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
