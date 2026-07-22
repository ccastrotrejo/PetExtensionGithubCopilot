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
        case .happy:   return (1.3, .thinking)
        case .worried: return (2.4, .thinking)
        case .idle:    return (18,  .sleeping)
        default:       return nil
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
    var bob: CGFloat = 0
    var rot: CGFloat = 0
    var shakeX: CGFloat = 0
    var scaleY: CGFloat = 1
    var accessory: Accessory? = nil
    var bubble: String? = nil
    var feat = DogFeatures()

    static func make(for mood: Mood, phase: Double, message: String) -> Pose {
        var p = Pose()
        switch mood {
        case .idle:
            p.scaleY = 1 + sin(phase * 2.2) * 0.02          // gentle breathing, in place
            p.feat = DogFeatures(eyes: .open, mouth: .smile, wag: 2)
        case .sleeping:
            p.scaleY = 1 + sin(phase * 2) * 0.03
            p.feat = DogFeatures(eyes: .closed, mouth: .neutral, wag: 0)
            p.accessory = .sleep
        case .greet:
            p.bob = abs(sin(phase * 8)) * 10
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 11)
            p.accessory = .wave; p.bubble = "hi!"
        case .thinking:
            p.rot = sin(phase * 3) * 0.06
            p.feat = DogFeatures(eyes: .open, mouth: .neutral, wag: 1)
            p.accessory = .think; p.bubble = message.isEmpty ? "thinking…" : message
        case .working:
            p.bob = abs(sin(phase * 12)) * 6
            p.feat = DogFeatures(eyes: .open, mouth: .pant, wag: 5)
            p.accessory = .gear; p.bubble = message.isEmpty ? "working…" : message
        case .happy:
            p.bob = abs(sin(phase * 10)) * 16
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 13)
            p.accessory = .sparkle; p.bubble = message.isEmpty ? "done!" : message
        case .worried:
            p.shakeX = sin(phase * 30) * 4
            p.feat = DogFeatures(eyes: .worried, mouth: .open, wag: 0, tailDown: true)
            p.accessory = .sweat; p.bubble = message.isEmpty ? "uh oh" : message
        }
        return p
    }
}
