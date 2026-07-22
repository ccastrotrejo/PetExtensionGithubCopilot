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

        // loved: the click-to-pet reaction. A delighted wriggle — happy (blushing)
        // eyes, a fast wag and a ♥ — deliberately with NO accessory so it never
        // reads as the "done!" sparkle.
        check(Mood.loved.autoNext?.to == .idle && Mood.loved.autoNext?.after == 1.5, "loved → idle after 1.5s")
        let loved = Pose.make(for: .loved, phase: 0.2, message: "")
        check(loved.accessory == nil && loved.bubble == "♥", "loved: heart bubble, no accessory")
        check(loved.feat.eyes == .happy && loved.feat.mouth == .smile && loved.feat.wag >= 13, "loved: happy blushing face, fast wag")
        check(loved.bob > 0, "loved: hops with delight")
        check(Pose.make(for: .loved, phase: 0.2, message: "custom").bubble == "♥", "loved: ignores wire message (local-only reaction)")
        check(!Cadence.isCalm(.loved), "loved is not calm (animates at full cadence)")

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
        for mood: Mood in [.idle, .sleeping, .greet, .thinking, .working, .happy, .worried, .loved] {
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
        check(PetConfig.parse(["palette": "red"]).palette == "red", "config: palette parsed")

        // name: optional, defaults empty, clamped to a sane length.
        check(defaults.name == "" && defaults.speed == 1, "config: name empty + speed 1 by default")
        check(PetConfig.parse(["name": "Rex"]).name == "Rex", "config: name parsed")
        check(PetConfig.parse(["name": String(repeating: "x", count: 40)]).name.count == 24,
              "config: name clamped to 24 chars")

        // speed: clamped to 0.5…2.0.
        check(PetConfig.parse(["speed": 1.5]).speed == 1.5, "config: speed parsed")
        check(PetConfig.parse(["speed": 0.1]).speed == 0.5, "config: speed clamps up to 0.5")
        check(PetConfig.parse(["speed": 9.0]).speed == 2.0, "config: speed clamps down to 2.0")

        // resolvedPalette maps the name to a coat (unknown → default chestnut).
        check(PetConfig.parse(["palette": "cream"]).resolvedPalette == Palette.cream, "config: resolvedPalette maps name")
        check(PetConfig.parse(["palette": "nope"]).resolvedPalette == Palette.chestnut, "config: resolvedPalette falls back")

        // MARK: Palette — selectable coats + case-insensitive lookup + fallback
        check(Palette.all.count >= 3, "palette: at least 3 selectable coats")
        check(Palette.all.first == Palette.chestnut, "palette: chestnut is the default (first)")
        check(Palette.named("chestnut") == Palette.chestnut, "palette: exact name lookup")
        check(Palette.named("BLACK-AND-TAN") == Palette.blackAndTan, "palette: case-insensitive lookup")
        check(Palette.named("  red  ") == Palette.red, "palette: whitespace-trimmed lookup")
        check(Palette.named("bogus") == Palette.chestnut, "palette: unknown name falls back to chestnut")
        check(Palette.named("") == Palette.chestnut, "palette: empty name falls back to chestnut")
        check(Set(Palette.all.map { $0.name }).count == Palette.all.count, "palette: names are unique")

        // MARK: Sprite.cell — integer cell sizing keeps the sprite crisp at any size
        for s in stride(from: 32.0, through: 160.0, by: 1.0) {
            let cell = Sprite.cell(forSize: CGFloat(s))
            if cell != cell.rounded() || cell < 2 {
                check(false, "sprite: cell(\(s)) = \(cell) is a whole number >= 2"); break
            }
        }
        check(Sprite.cell(forSize: 62) == 2, "sprite: cell(62) == 2")
        check(Sprite.cell(forSize: 160) == 6, "sprite: cell(160) == 6")

        // openOnDoubleClick: default targets the host app; strings resolve to an action.
        check(defaults.doubleClickAction == .openDefaultHost, "config: double-click defaults to host app")
        check(PetConfig.parse(["openOnDoubleClick": ""]).doubleClickAction == .openDefaultHost,
              "config: empty double-click == host app")
        check(PetConfig.parse(["openOnDoubleClick": "none"]).doubleClickAction == .disabled,
              "config: 'none' disables double-click")
        check(PetConfig.parse(["openOnDoubleClick": "OFF"]).doubleClickAction == .disabled,
              "config: 'off' disables double-click (case-insensitive)")
        check(PetConfig.parse(["openOnDoubleClick": "com.github.githubapp"]).doubleClickAction
              == .openBundleId("com.github.githubapp"), "config: reverse-DNS parsed as bundle id")
        check(PetConfig.parse(["openOnDoubleClick": "/Applications/Copilot.app"]).doubleClickAction
              == .openApp("/Applications/Copilot.app"), "config: path parsed as app")
        check(PetConfig.parse(["openOnDoubleClick": "Visual Studio Code.app"]).doubleClickAction
              == .openApp("Visual Studio Code.app"), "config: .app name parsed as app")
        check(PetConfig.parse(["openOnDoubleClick": "Copilot"]).doubleClickAction
              == .openApp("Copilot"), "config: bare name parsed as app")
        check(PetConfig.parse(["openOnDoubleClick": 42]).openOnDoubleClick == "",
              "config: bad double-click type falls back to default")

        // Wrong types fall back to defaults rather than crashing.
        check(PetConfig.parse(["size": "big"]).size == 62, "config: bad type falls back to default")

        // MARK: reduceMotion — damps motion fields (~15%), keeps expression
        // (Comprehensive per-mood damping coverage lives in the loop above;
        // this just spot-checks two moods alongside the config/arbitration suite.)
        let calmHappy = Pose.make(for: .happy, phase: 0.25, message: "", reduceMotion: true)
        check(abs(calmHappy.bob) <= abs(Pose.make(for: .happy, phase: 0.25, message: "").bob) * Pose.reducedMotionScale + 1e-9,
              "reduceMotion: happy bob damped to ~15%")
        check(calmHappy.accessory == .sparkle && calmHappy.feat.eyes == .happy && calmHappy.feat.wag > 0,
              "reduceMotion: keeps the happy expression (wag speed untouched)")
        let calmThinking = Pose.make(for: .thinking, phase: 1.0, message: "", reduceMotion: true)
        check(abs(calmThinking.headTilt) <= abs(Pose.make(for: .thinking, phase: 1.0, message: "").headTilt) * Pose.reducedMotionScale + 1e-9,
              "reduceMotion: thinking headTilt damped to ~15%")
        check(calmThinking.accessory == .think && calmThinking.bubble == "thinking…",
              "reduceMotion: keeps thinking accessory + bubble")

        // MARK: Idle antics — pure selection, scheduling, and part-based motion
        for a in Antic.allCases {
            check(a.duration > 0, "antic \(a.rawValue): positive duration")
            check(a.weight > 0, "antic \(a.rawValue): positive weight")
        }

        // nextGap: clamped, monotonic, spans the relaxed [minGap, maxGap] range.
        check(IdleAntics.nextGap(random: 0) == IdleAntics.minGap, "antics: nextGap(0) == minGap")
        check(IdleAntics.nextGap(random: 1) == IdleAntics.maxGap, "antics: nextGap(1) == maxGap")
        check(IdleAntics.nextGap(random: 0.5) == (IdleAntics.minGap + IdleAntics.maxGap) / 2, "antics: nextGap(.5) is midpoint")
        check(IdleAntics.nextGap(random: -1) == IdleAntics.minGap && IdleAntics.nextGap(random: 2) == IdleAntics.maxGap,
              "antics: nextGap clamps out-of-range random")

        // pick: weighted, deterministic at the boundaries, never repeats `avoiding`.
        check(IdleAntics.pick(random: 0) == .stretch, "antics: pick(0) → first case (stretch)")
        check(IdleAntics.pick(random: 0.999) == .sit, "antics: pick(≈1) → last case (sit)")
        check(IdleAntics.pick(random: 0, avoiding: .stretch) == .yawn, "antics: pick(0) skips avoided first → yawn")
        for a in Antic.allCases {
            for i in 0..<50 {
                check(IdleAntics.pick(random: Double(i) / 50.0, avoiding: a) != a,
                      "antics: pick never returns avoided \(a.rawValue) (r=\(i))")
            }
        }
        var seen = Set<Antic>()
        for i in 0..<200 { seen.insert(IdleAntics.pick(random: Double(i) / 200.0)) }
        check(seen.count == Antic.allCases.count, "antics: every antic is reachable across the random range")

        // apply at anticPhase 0 is a no-op — identical to plain idle, so an antic
        // eases in from rest instead of snapping (never overlaps awkwardly).
        for a in Antic.allCases {
            let base = Pose.make(for: .idle, phase: 0.7, message: "")
            let start = Pose.make(for: .idle, phase: 0.7, message: "", antic: a, anticPhase: 0)
            check(start.scaleX == base.scaleX && start.scaleY == base.scaleY && start.headBob == base.headBob
                  && start.headTilt == base.headTilt && start.bob == base.bob && start.tremble == base.tremble
                  && start.feat.eyes == base.feat.eyes && start.feat.mouth == base.feat.mouth,
                  "antic \(a.rawValue): anticPhase 0 == plain idle (blends in from rest)")
        }

        // Per-antic behavior at its peak (anticPhase = duration/2, envelope = 1).
        func peak(_ a: Antic) -> Pose { Pose.make(for: .idle, phase: 0.85, message: "", antic: a, anticPhase: a.duration / 2) }
        check(peak(.stretch).scaleX > 1.1 && peak(.stretch).headBob < 0, "antic stretch: body extends, front bows down")
        check(peak(.yawn).feat.mouth == .yawn && peak(.yawn).feat.eyes == .closed && peak(.yawn).headBob > 0,
              "antic yawn: mouth gapes, eyes shut, head lifts")
        check(peak(.scratch).tremble > 0 && peak(.scratch).feat.eyes == .happy, "antic scratch: head buzzes, content eyes")
        check(peak(.sniff).headBob < 0, "antic sniff: nose to the ground")
        check(peak(.dig).headBob < 0 && peak(.dig).bob > 0, "antic dig: nose jabs down as the body bobs")
        check(peak(.chaseTail).headTilt > 0 && peak(.chaseTail).feat.wag >= 12, "antic chaseTail: head cranes back, fast wag")
        check(peak(.sit).scaleY < 1 && peak(.sit).headBob > 0, "antic sit: settles down, head held high")

        // Antics apply only in idle, and never under Reduce Motion.
        check(Pose.make(for: .working, phase: 0.85, message: "", antic: .stretch, anticPhase: 1.0).scaleX == 1,
              "antics: a real mood ignores antics (no scaleX)")
        let calmAntic = Pose.make(for: .idle, phase: 0.85, message: "", reduceMotion: true, antic: .stretch, anticPhase: 1.0)
        check(calmAntic.scaleX == 1 && calmAntic.headBob == 0, "antics: Reduce Motion suppresses antics")

        // MARK: Gaze — look-at cursor geometry (pure)
        let sz: CGFloat = 62
        check(!Gaze.toward(dx: sz * 10, dy: 0, size: sz).active, "gaze: cursor far outside range → inactive")
        check(!Gaze.toward(dx: 0, dy: 0, size: sz).active, "gaze: cursor exactly on the head → inactive (no direction)")
        let gRight = Gaze.toward(dx: sz * 2, dy: 0, size: sz)
        check(gRight.active && gRight.facing == .right && gRight.pupil.dx > 0, "gaze: cursor to the right → face right, pupils right")
        let gLeft = Gaze.toward(dx: -sz * 2, dy: 0, size: sz)
        check(gLeft.active && gLeft.facing == .left && gLeft.pupil.dx < 0, "gaze: cursor to the left → face left, pupils left")
        let gUp = Gaze.toward(dx: 0, dy: sz, size: sz)
        check(gUp.active && gUp.facing == .front && gUp.pupil.dy > 0, "gaze: cursor above center → face front (look at you), pupils up")
        let gDown = Gaze.toward(dx: sz * 0.3, dy: -sz * 0.8, size: sz)
        check(gDown.active && gDown.facing == .front && gDown.pupil.dy < 0, "gaze: cursor below within dead-zone → front, pupils down")
        // Pupil offset is clamped to [-1, 1] cells in each axis.
        let gClamp = Gaze.toward(dx: sz * 3, dy: 0, size: sz)
        check(gClamp.pupil.dx <= 1.0 + 1e-9 && gClamp.pupil.dx >= 1.0 - 1e-9, "gaze: pupil x clamps to 1 cell")
        check(Gaze.none.active == false && Gaze.none.pupil == .zero, "gaze: .none is inactive, centered")

        // MARK: Interaction — click vs. drag disambiguation (pure)
        check(Interaction.dragThreshold == 4, "interaction: 4pt drag threshold")
        check(Interaction.isClick(maxDisplacement: 0), "interaction: no travel is a click")
        check(Interaction.isClick(maxDisplacement: 3.9), "interaction: small jitter is still a click")
        check(Interaction.isClick(maxDisplacement: 4), "interaction: exactly the threshold is a click")
        check(!Interaction.isClick(maxDisplacement: 4.1), "interaction: past the threshold is a drag, not a pet")
        check(!Interaction.isClick(maxDisplacement: 50), "interaction: a real drag never pets")

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

        // MARK: - Behavior composition (issue #6) — pipeline reproduces moods and extends cleanly

        func bctx(_ mood: Mood, phase: Double = 0.4, message: String = "", rm: Bool = false,
                  antic: Antic? = nil, anticPhase: Double = 0) -> BehaviorContext {
            BehaviorContext(mood: mood, phase: phase, message: message, reduceMotion: rm,
                            motionScale: rm ? Pose.reducedMotionScale : 1,
                            antic: antic, anticPhase: anticPhase)
        }
        func samePose(_ a: Pose, _ b: Pose) -> Bool {
            a.bob == b.bob && a.scaleX == b.scaleX && a.scaleY == b.scaleY && a.headTilt == b.headTilt
                && a.headBob == b.headBob && a.tremble == b.tremble && a.motionScale == b.motionScale
                && a.walk == b.walk
                && a.accessory == b.accessory && a.bubble == b.bubble
                && a.feat.eyes == b.feat.eyes && a.feat.mouth == b.feat.mouth
                && a.feat.wag == b.feat.wag && a.feat.tailDown == b.feat.tailDown
        }

        // #1 No visual regression: the default pipeline reproduces Pose.make for
        // every mood — at rest and mid-animation, with/without Reduce Motion.
        for mood: Mood in [.idle, .sleeping, .greet, .thinking, .working, .happy, .worried] {
            for ph in [0.0, 0.4, 1.0] {
                for rm in [false, true] {
                    let viaMake = Pose.make(for: mood, phase: ph, message: "hi", reduceMotion: rm)
                    let viaPipe = PetBehaviors.render(bctx(mood, phase: ph, message: "hi", rm: rm))
                    check(samePose(viaMake, viaPipe), "behavior: pipeline reproduces \(mood) (phase \(ph), rm \(rm))")
                }
            }
        }
        // The idle antic overlay is reproduced through the pipeline too.
        check(samePose(Pose.make(for: .idle, phase: 0.85, message: "", antic: .stretch, anticPhase: 0.9),
                       PetBehaviors.render(bctx(.idle, phase: 0.85, antic: .stretch, anticPhase: 0.9))),
              "behavior: pipeline reproduces the idle antic overlay")

        // The default pipeline is exactly [MoodExpression, IdleAnticLayer, WalkCycle].
        check(PetBehaviors.pipeline.count == 3, "behavior: default pipeline has three behaviors")

        // #2 Extensibility: a brand-new behavior contributes to the frame without
        // any change to MoodExpression, IdleAnticLayer, or the renderer.
        struct TestBehavior: Behavior {
            func apply(to p: inout Pose, _ ctx: BehaviorContext) { p.bubble = "★"; p.scaleX += 0.5 }
        }
        let extended = PetBehaviors.render(bctx(.working, message: "npm test"),
                                           through: PetBehaviors.pipeline + [TestBehavior()])
        check(extended.bubble == "★", "behavior: appended behavior overrides the bubble")
        check(extended.accessory == .gear, "behavior: appended behavior leaves the mood expression intact")
        check(extended.scaleX == 1.5, "behavior: appended behavior contributes on top of the pose")

        // Composition is ordered: the antic only overlays when IdleAnticLayer runs
        // after the mood expression.
        check(PetBehaviors.render(bctx(.idle, phase: 0.85, antic: .stretch, anticPhase: 0.9),
                                  through: [MoodExpression()]).scaleX == 1,
              "behavior: without IdleAnticLayer, the antic is not applied")
        check(PetBehaviors.render(bctx(.idle, phase: 0.85, antic: .stretch, anticPhase: 0.9),
                                  through: [MoodExpression(), IdleAnticLayer()]).scaleX > 1,
              "behavior: IdleAnticLayer overlays the antic after the expression")

        // IdleAnticLayer keeps its gates: real moods and Reduce Motion suppress antics.
        check(PetBehaviors.render(bctx(.working, phase: 0.85, antic: .stretch, anticPhase: 0.9)).scaleX == 1,
              "behavior: a real mood ignores the idle antic layer")
        check(PetBehaviors.render(bctx(.idle, phase: 0.85, rm: true, antic: .stretch, anticPhase: 0.9)).scaleX == 1,
              "behavior: Reduce Motion suppresses the idle antic layer")

        // motionScale is seeded before behaviors run, so damping is uniform.
        check(PetBehaviors.render(bctx(.idle, rm: true)).motionScale == Pose.reducedMotionScale,
              "behavior: render seeds motionScale for Reduce Motion")
        check(PetBehaviors.render(bctx(.idle)).motionScale == 1, "behavior: render seeds motionScale = 1 normally")

        // MARK: Roam config — opt-in behavior flag
        check(!PetConfig().roam, "roam: off by default")
        check(!PetConfig().behaviors.contains("roam"), "roam: not in the default behavior set")
        check(PetConfig.knownBehaviors.contains("roam"), "roam: is a known behavior")
        let roamCfg = PetConfig.parse(["enabledBehaviors": ["roam", "bubbles"]])
        check(roamCfg.roam, "roam: enabled when listed in enabledBehaviors")
        check(!roamCfg.lookAround, "roam: enabling roam alone leaves lookAround off")

        // MARK: WalkCycle behavior — walk pose overlay
        let standing = Pose.make(for: .idle, phase: 0.4, message: "")
        check(standing.walk == 0, "walk: a standing pet has walk == 0")
        let walkingPose = Pose.make(for: .idle, phase: 0.4, message: "", walking: true, walkPhase: 0.5)
        check(walkingPose.walk == 0.5, "walk: walking publishes the walk-cycle phase")
        check(walkingPose.feat.mouth == .pant && walkingPose.feat.wag >= 6, "walk: walking shows a lively panting trot")
        check(Pose.make(for: .idle, phase: 0.4, message: "", walking: false, walkPhase: 0.5).walk == 0,
              "walk: walking:false keeps walk == 0 regardless of walkPhase")
        // A non-walking frame is unchanged whether or not WalkCycle is in the pipeline.
        check(samePose(Pose.make(for: .idle, phase: 0.4, message: ""),
                       PetBehaviors.render(bctx(.idle, phase: 0.4), through: [MoodExpression(), IdleAnticLayer()])),
              "walk: WalkCycle is a no-op while standing")

        // MARK: Roam physics — gravity, landing, wander, drag, edges
        let floorY: CGFloat = 100, minX: CGFloat = 0, maxX: CGFloat = 500
        let r0 = { () -> Double in 0.5 }   // fixed random for deterministic wander

        // Gravity: dropped above the floor, it accelerates downward.
        var falling = Roam()
        let f1 = falling.step(x: 200, y: 300, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                              speed: 1, wander: true, dragging: false, random: r0)
        check(f1.falling && !f1.walking && f1.y < 300, "roam: airborne pet falls under gravity")
        let f2 = falling.step(x: 200, y: f1.y, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                              speed: 1, wander: true, dragging: false, random: r0)
        check(falling.vy < 0 && f2.y < f1.y, "roam: fall speed builds up frame over frame")

        // Landing: it settles exactly on the floor and reports `landed` once.
        var lander = Roam()
        var y = floorY + 3.0
        var sawLanded = false, restedOnFloor = false
        for _ in 0..<240 {
            let f = lander.step(x: 200, y: y, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                speed: 1, wander: false, dragging: false, random: r0)
            y = f.y
            if f.landed { sawLanded = true }
            if !f.falling && abs(f.y - floorY) < 0.001 { restedOnFloor = true }
        }
        check(sawLanded, "roam: a drop reports a landing exactly once it touches down")
        check(restedOnFloor, "roam: it comes to rest exactly on the floor line")

        // Drag: physics is frozen while held, then falls on release.
        var dragged = Roam()
        let held = dragged.step(x: 200, y: 260, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                speed: 1, wander: true, dragging: true, random: r0)
        check(held.x == 200 && held.y == 260 && !held.falling, "roam: dragging freezes the pet where held")
        let released = dragged.step(x: 200, y: 260, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                    speed: 1, wander: true, dragging: false, random: r0)
        check(released.falling, "roam: releasing a lifted pet lets it fall")

        // Wander: grounded + idle → it strolls; not-wander → it stands still.
        var walker = Roam()
        var wx: CGFloat = 200
        var moved = false, stayedOnScreen = true
        for _ in 0..<600 {
            let f = walker.step(x: wx, y: floorY, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                speed: 1, wander: true, dragging: false, random: { Double.random(in: 0..<1) })
            if f.walking && f.x != wx { moved = true }
            if f.x < minX || f.x > maxX { stayedOnScreen = false }
            wx = f.x
        }
        check(moved, "roam: a grounded idle pet eventually strolls")
        check(stayedOnScreen, "roam: never strolls off-screen")

        var stander = Roam()
        let standFrame = stander.step(x: 200, y: floorY, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                      speed: 1, wander: false, dragging: false, random: r0)
        check(standFrame.x == 200 && !standFrame.walking, "roam: not wandering → stands on the floor")

        // Edge bounce: forced against the right edge, it clamps and turns around.
        var bouncer = Roam()
        bouncer.gait = .walking; bouncer.dir = 1; bouncer.timer = 100
        let atEdge = bouncer.step(x: maxX, y: floorY, dt: 1.0 / 60, floorY: floorY, minX: minX, maxX: maxX,
                                  speed: 1, wander: true, dragging: false, random: r0)
        check(atEdge.x == maxX && atEdge.dir == -1, "roam: hitting the right edge turns the pet around")

        print(failures == 0 ? "\n✓ ALL PASSED" : "\n✗ \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
