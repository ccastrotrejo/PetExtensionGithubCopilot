// Unit tests for the pure pet model (PetCore.swift).
// Run:  swiftc PetCore.swift Tests/PetCoreTests.swift -o /tmp/pettests && /tmp/pettests
// No AppKit or running app needed — this is the payoff of extracting Pose/Mood.

import Foundation
import CoreGraphics

@main
enum PetCoreTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ok   \(msg)") } else { print("  FAIL \(msg)"); failures += 1 }
    }

    static func main() {
        // MARK: Mood.autoNext — data-driven transitions
        check(Mood.greet.autoNext?.to == .idle && Mood.greet.autoNext?.after == 1.6, "greet → idle after 1.6s")
        check(Mood.happy.autoNext?.to == .idle && Mood.happy.autoNext?.after == 1.5, "happy → idle after 1.5s")
        check(Mood.worried.autoNext?.to == .idle && Mood.worried.autoNext?.after == 2.4, "worried → idle after 2.4s")
        check(Mood.idle.autoNext?.to == .sleeping && Mood.idle.autoNext?.after == 18, "idle → sleeping after 18s")
        check(Mood.thinking.autoNext == nil, "thinking has no auto transition")
        check(Mood.working.autoNext == nil, "working has no auto transition")
        check(Mood.sleeping.autoNext == nil, "sleeping has no auto transition")

        // MARK: Wire-protocol raw values
        check(Mood(rawValue: "worried") == .worried, "known raw value maps to case")
        check(Mood(rawValue: "bogus") == nil, "unknown raw value is nil (caller falls back to idle)")

        // MARK: Pose.make — per-mood features
        let idle = Pose.make(for: .idle, phase: 0, message: "")
        check(idle.accessory == nil && idle.bubble == nil, "idle: no accessory or bubble")
        check(idle.feat.eyes == .open && idle.feat.wag > 0, "idle: open eyes, tail wagging")

        let sleeping = Pose.make(for: .sleeping, phase: 0, message: "")
        check(sleeping.accessory == .sleep && sleeping.feat.eyes == .closed && sleeping.feat.wag == 0,
              "sleeping: zzz, closed eyes, still tail")

        let greet = Pose.make(for: .greet, phase: 0, message: "")
        check(greet.accessory == .wave && greet.bubble == "hi!" && greet.feat.eyes == .happy,
              "greet: waving paw, hi! bubble, happy eyes")

        let working = Pose.make(for: .working, phase: 0, message: "")
        check(working.accessory == .gear && working.feat.mouth == .pant, "working: gear, panting mouth")

        let happy = Pose.make(for: .happy, phase: 0, message: "")
        check(happy.accessory == .sparkle && happy.feat.eyes == .happy, "happy: sparkle, happy eyes")

        let worried = Pose.make(for: .worried, phase: 0, message: "")
        check(worried.accessory == .sweat && worried.feat.tailDown && worried.feat.wag == 0,
              "worried: sweat, tucked tail, no wag")

        // MARK: Bubble — default vs. message passthrough
        check(Pose.make(for: .thinking, phase: 0, message: "").bubble == "thinking…", "thinking: default bubble")
        check(Pose.make(for: .thinking, phase: 0, message: "reticulating").bubble == "reticulating",
              "thinking: passes message through")
        check(Pose.make(for: .working, phase: 0, message: "npm test").bubble == "npm test",
              "working: passes message through")

        print(failures == 0 ? "\n✓ ALL PASSED" : "\n✗ \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
