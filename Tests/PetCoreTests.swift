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

        // MARK: Part-based animation — genuine behaviors, not whole-image motion
        check(Pose.make(for: .thinking, phase: 1.0, message: "").bob == 0, "thinking: no whole-body hop")
        check(abs(Pose.make(for: .thinking, phase: 1.0, message: "").headTilt) > 0.01, "thinking: head tilts")
        check(Pose.make(for: .working, phase: 0.3, message: "").headBob < 0, "working: nose dips to sniff")
        check(Pose.make(for: .worried, phase: 0.2, message: "").tremble > 0, "worried: head trembles")
        check(Pose.make(for: .worried, phase: 0, message: "").headBob < 0, "worried: head lowered (cower)")
        check(Pose.make(for: .happy, phase: 0.25, message: "").bob > 0, "happy: bounces off the ground")

        // MARK: Facing.turn — always turns to a different facing
        check(Facing.turn(from: .right, random: 0.0) != .right, "from right never stays right (r=0)")
        check(Facing.turn(from: .right, random: 0.99) != .right, "from right never stays right (r≈1)")
        check(Facing.turn(from: .left, random: 0.5) != .left, "from left never stays left")
        check(Facing.turn(from: .front, random: 0.5) != .front, "from front never stays front")
        check(Facing.turn(from: .right, random: 0.0) == .left, "from right, r=0 → left (first option)")
        check(Facing.turn(from: .front, random: 0.0) == .right, "from front, r=0 → right")
        var reachedFront = false, reachedLeft = false
        for i in 0..<100 {
            let f = Facing.turn(from: .right, random: Double(i) / 100.0)
            if f == .front { reachedFront = true }; if f == .left { reachedLeft = true }
        }
        check(reachedFront && reachedLeft, "from right, both left and front are reachable")

        // MARK: Cadence.fps / interval — the four (reduceMotion, calm) combinations
        check(Cadence.fps(reduceMotion: false, calm: false) == 30, "active: 30 FPS")
        check(Cadence.fps(reduceMotion: false, calm: true) == 5, "calm: 5 FPS")
        check(Cadence.fps(reduceMotion: true, calm: false) == 10, "Reduce Motion + active: 10 FPS")
        check(Cadence.fps(reduceMotion: true, calm: true) == 2, "Reduce Motion + calm: 2 FPS")
        check(abs(Cadence.interval(reduceMotion: false, calm: false) - 1.0 / 30.0) < 1e-9, "active: interval = 1/30s")
        check(abs(Cadence.interval(reduceMotion: true, calm: true) - 1.0 / 2.0) < 1e-9, "Reduce Motion + calm: interval = 1/2s")

        // MARK: Cadence — hidden/occluded polling is a fixed low rate, independent of mood/Reduce Motion
        check(Cadence.hiddenFPS == 5, "hidden/occluded: 5 FPS poll-only")
        check(abs(Cadence.hiddenInterval - 1.0 / 5.0) < 1e-9, "hidden/occluded: interval = 1/5s")

        // MARK: Cadence.isCalm — which moods are safe to throttle
        check(Cadence.isCalm(.idle), "idle is calm")
        check(Cadence.isCalm(.sleeping), "sleeping is calm")
        check(!Cadence.isCalm(.greet), "greet is not calm")
        check(!Cadence.isCalm(.thinking), "thinking is not calm")
        check(!Cadence.isCalm(.working), "working is not calm")
        check(!Cadence.isCalm(.happy), "happy is not calm")
        check(!Cadence.isCalm(.worried), "worried is not calm")

        // MARK: Pose.motionScale — default vs. Reduce Motion damping
        check(Pose.make(for: .idle, phase: 0, message: "").motionScale == 1, "motionScale defaults to 1")
        check(Pose.make(for: .idle, phase: 0, message: "", reduceMotion: true).motionScale == Pose.reducedMotionScale,
              "Reduce Motion sets motionScale to reducedMotionScale (~15%)")
        check(Pose.reducedMotionScale == 0.15, "reducedMotionScale is ~15%")

        // MARK: Reduce Motion — ambient wobble damped to ~15%, expressions untouched, per mood
        for mood: Mood in [.idle, .sleeping, .greet, .thinking, .working, .happy, .worried] {
            let phase = 0.35 // away from zero for every mood's oscillating field
            let normal = Pose.make(for: mood, phase: phase, message: "hello")
            let damped = Pose.make(for: mood, phase: phase, message: "hello", reduceMotion: true)

            check(abs(damped.bob) <= abs(normal.bob) * Pose.reducedMotionScale + 1e-9,
                  "\(mood): bob damped to ~15% under Reduce Motion")
            check(abs(damped.scaleY - 1) <= abs(normal.scaleY - 1) * Pose.reducedMotionScale + 1e-9,
                  "\(mood): breathing scale delta damped to ~15% under Reduce Motion")
            check(abs(damped.headTilt) <= abs(normal.headTilt) * Pose.reducedMotionScale + 1e-9,
                  "\(mood): headTilt damped to ~15% under Reduce Motion")
            check(abs(damped.headBob) <= abs(normal.headBob) * Pose.reducedMotionScale + 1e-9,
                  "\(mood): headBob damped to ~15% under Reduce Motion")
            check(abs(damped.tremble) <= abs(normal.tremble) * Pose.reducedMotionScale + 1e-9,
                  "\(mood): tremble damped to ~15% under Reduce Motion")

            check(damped.feat.eyes == normal.feat.eyes, "\(mood): eyes unchanged under Reduce Motion")
            check(damped.feat.mouth == normal.feat.mouth, "\(mood): mouth unchanged under Reduce Motion")
            check(damped.feat.wag == normal.feat.wag, "\(mood): wag speed unchanged under Reduce Motion")
            check(damped.feat.tailDown == normal.feat.tailDown, "\(mood): tailDown unchanged under Reduce Motion")
            check(damped.accessory == normal.accessory, "\(mood): accessory unchanged under Reduce Motion")
            check(damped.bubble == normal.bubble, "\(mood): bubble text unchanged under Reduce Motion")
        }
        // At least one mood must actually exercise a non-zero field for the damping checks above to be meaningful.
        check(Pose.make(for: .worried, phase: 0.35, message: "").tremble > 0, "worried: tremble is non-zero (sanity check for damping test)")

        print(failures == 0 ? "\n✓ ALL PASSED" : "\n✗ \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
