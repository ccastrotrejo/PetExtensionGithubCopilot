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

        // MARK: PetConfig.parse — defaults, merging, clamping, validation
        let defaults = PetConfig.parse(nil)
        check(defaults.size == 62 && defaults.lookAroundInterval == 4...9, "config: defaults when absent")
        check(defaults.behaviors == ["lookAround", "bubbles"] && !defaults.muted && !defaults.reduceMotion,
              "config: default behaviors, unmuted, motion on")
        check(defaults.lookAround && defaults.bubblesEnabled, "config: lookAround + bubbles on by default")
        check(PetConfig.parse([:]) == defaults, "config: empty object == defaults")

        // Partial config keeps defaults for the missing keys.
        let partial = PetConfig.parse(["size": 90.0])
        check(partial.size == 90 && partial.lookAroundInterval == 4...9, "config: partial keeps other defaults")

        // size clamps to a sane window range.
        check(PetConfig.parse(["size": 5.0]).size == 32, "config: size clamps up to 32")
        check(PetConfig.parse(["size": 999.0]).size == 160, "config: size clamps down to 160")

        // lookAroundInterval accepts a fixed number or a [min, max] pair.
        check(PetConfig.parse(["lookAroundInterval": 6.0]).lookAroundInterval == 6...6, "config: fixed interval")
        check(PetConfig.parse(["lookAroundInterval": [3.0, 8.0]]).lookAroundInterval == 3...8, "config: [min,max] interval")
        check(PetConfig.parse(["lookAroundInterval": [8.0, 3.0]]).lookAroundInterval == 3...8, "config: interval order-normalized")

        // muted suppresses bubbles even when the behavior is enabled.
        check(!PetConfig.parse(["muted": true]).bubblesEnabled, "config: muted suppresses bubbles")
        check(!PetConfig.parse(["enabledBehaviors": ["lookAround"]]).bubblesEnabled, "config: bubbles off when not listed")
        check(!PetConfig.parse(["enabledBehaviors": ["bubbles"]]).lookAround, "config: lookAround off when not listed")
        check(PetConfig.parse(["enabledBehaviors": ["bubbles", "bogus"]]).behaviors == ["bubbles"],
              "config: unknown behaviors ignored")

        check(PetConfig.parse(["reduceMotion": true]).reduceMotion, "config: reduceMotion parsed")
        check(PetConfig.parse(["breed": "corgi"]).breed == "corgi", "config: breed parsed (reserved)")
        check(PetConfig.parse(["palette": "gray"]).palette == "gray", "config: palette parsed (reserved)")

        // Wrong types fall back to defaults rather than crashing.
        check(PetConfig.parse(["size": "big"]).size == 62, "config: bad type falls back to default")

        // MARK: reduceMotion — flattens every motion field, keeps expression
        let calmHappy = Pose.make(for: .happy, phase: 0.25, message: "", reduceMotion: true)
        check(calmHappy.bob == 0 && calmHappy.scaleY == 1 && calmHappy.feat.wag == 0,
              "reduceMotion: happy holds still (no bob/scale/wag)")
        check(calmHappy.accessory == .sparkle && calmHappy.feat.eyes == .happy,
              "reduceMotion: keeps the happy expression")
        let calmThinking = Pose.make(for: .thinking, phase: 1.0, message: "", reduceMotion: true)
        check(calmThinking.headTilt == 0 && calmThinking.tremble == 0, "reduceMotion: no head tilt/tremble")
        check(calmThinking.accessory == .think && calmThinking.bubble == "thinking…",
              "reduceMotion: keeps thinking accessory + bubble")

        // MARK: Arbitration — multi-session, one shared pet
        let base = 1_000_000.0  // arbitrary "now" in ms
        func snap(_ id: String, _ mood: String, activity: Double, heartbeat: Double = 0, msg: String = "") -> SessionSnapshot {
            SessionSnapshot(id: id, mood: mood, message: msg, activity: activity, heartbeat: heartbeat)
        }

        // No sessions → nothing to show (caller keeps current pose).
        check(Arbitration.resolve([], now: base, hadLiveSessions: false) == nil, "arbitration: empty → nil")

        // A single live session drives the pet with its mood + message.
        let single = Arbitration.resolve(
            [snap("a", "working", activity: base, heartbeat: base, msg: "npm test")],
            now: base, hadLiveSessions: true)
        check(single?.command == .show(.working, message: "npm test") && single?.winner == "a",
              "arbitration: single live session shows its mood")

        // A session whose heartbeat is stale is ignored entirely.
        check(Arbitration.resolve([snap("dead", "working", activity: base, heartbeat: base - 20_000)],
                                  now: base, hadLiveSessions: true) == nil,
              "arbitration: stale session excluded → nil")
        check(Arbitration.liveSessions([snap("live", "idle", activity: base, heartbeat: base),
                                        snap("dead", "idle", activity: base, heartbeat: base - 13_000)],
                                       now: base).map { $0.id } == ["live"],
              "arbitration: liveSessions drops stale heartbeats")

        // Staleness boundary: a heartbeat exactly at the window is still live; one ms older is dead.
        check(Arbitration.liveSessions([snap("edge", "idle", activity: base,
                                             heartbeat: base - Arbitration.staleAfterMs)],
                                       now: base).count == 1,
              "arbitration: heartbeat exactly at staleAfterMs is still live")
        check(Arbitration.liveSessions([snap("edge", "idle", activity: base,
                                             heartbeat: base - Arbitration.staleAfterMs - 1)],
                                       now: base).isEmpty,
              "arbitration: heartbeat one ms past staleAfterMs is dead")

        // Most-recent-activity wins between two live sessions.
        let recent = Arbitration.resolve(
            [snap("old", "working", activity: base - 5_000, heartbeat: base, msg: "old"),
             snap("new", "thinking", activity: base, heartbeat: base, msg: "new")],
            now: base, hadLiveSessions: true)
        check(recent?.command == .show(.thinking, message: "new") && recent?.winner == "new",
              "arbitration: most-recent-activity wins")

        // Control signals from the winner are honored globally.
        check(Arbitration.resolve([snap("a", "quit", activity: base, heartbeat: base)],
                                  now: base, hadLiveSessions: true)?.command == .quit,
              "arbitration: winner 'quit' → quit")
        check(Arbitration.resolve([snap("a", "hidden", activity: base, heartbeat: base)],
                                  now: base, hadLiveSessions: true)?.command == .hide,
              "arbitration: winner 'hidden' → hide")
        // A quit/hide from a *stale* newer entry doesn't win; the live one does.
        let liveOverStaleQuit = Arbitration.resolve(
            [snap("a", "working", activity: base - 1_000, heartbeat: base, msg: "go"),
             snap("z", "quit", activity: base, heartbeat: base - 20_000)],
            now: base, hadLiveSessions: true)
        check(liveOverStaleQuit?.command == .show(.working, message: "go"),
              "arbitration: stale 'quit' is ignored, live worker wins")

        // Greet de-dup: honored on 0→N, downgraded to idle once sessions are live.
        check(Arbitration.resolve([snap("first", "greet", activity: base, heartbeat: base)],
                                  now: base, hadLiveSessions: false)?.command == .show(.greet, message: ""),
              "arbitration: greet honored on first live session")
        check(Arbitration.resolve([snap("nth", "greet", activity: base, heartbeat: base)],
                                  now: base, hadLiveSessions: true)?.command == .show(.idle, message: ""),
              "arbitration: greet de-duped once sessions are already live")

        // Unknown moods fall back to idle.
        check(Arbitration.resolve([snap("a", "bogus", activity: base, heartbeat: base)],
                                  now: base, hadLiveSessions: true)?.command == .show(.idle, message: ""),
              "arbitration: unknown mood → idle")

        // Tie on activity is broken deterministically (by id) — winner is stable.
        let tieA = Arbitration.resolve(
            [snap("a", "working", activity: base, heartbeat: base),
             snap("b", "thinking", activity: base, heartbeat: base)],
            now: base, hadLiveSessions: true)
        let tieB = Arbitration.resolve(
            [snap("b", "thinking", activity: base, heartbeat: base),
             snap("a", "working", activity: base, heartbeat: base)],
            now: base, hadLiveSessions: true)
        check(tieA == tieB && tieA?.winner == "b", "arbitration: activity tie broken deterministically by id")

        print(failures == 0 ? "\n✓ ALL PASSED" : "\n✗ \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
