// Copilot Pet — native macOS desktop companion overlay.
// Usage: pet <path-to-state.json>
// Reads a JSON state file and renders a pixel-art dachshund that reacts to Copilot activity.
// The pet is static and can be dragged around the desktop; its position persists.
//
// state.json: { "mood": String, "message": String, "seq": Int, "heartbeat": Double(ms) }

import Cocoa

// The pure model (Mood, Pose, DogFeatures, Accessory, EyeState, MouthState)
// lives in PetCore.swift and is compiled into the same module.

// MARK: - Shared animation state

final class PetState {
    var statePath: String
    var sessionsDir: String            // dir of per-session state files to arbitrate
    var lastKey: String = ""           // winner id + activity of the applied resolution
    var mood: Mood = .greet
    var message: String = ""
    var moodChangeTime: TimeInterval = Date().timeIntervalSince1970
    var heartbeat: Double = Date().timeIntervalSince1970 * 1000.0  // freshest controller
    var hadLiveSessions: Bool = false  // was any session live on the previous tick?
    var phase: Double = 0
    var lastPoll: TimeInterval = 0
    var facing: Facing = .front       // greet by looking at you
    var nextTurn: TimeInterval = 0    // when to next glance around
    var config = PetConfig()          // user settings (hot-reloaded from config.json)
    var configPath: String = ""
    var configMTime: Double = -1      // last-seen config.json mtime; -1 = absent
    var antic: Antic? = nil           // idle flourish currently playing (nil = plain idle)
    var lastAntic: Antic? = nil       // last antic played, so we don't repeat it back-to-back
    var anticStart: Double = 0        // phase clock when the current antic began
    var nextAntic: Double = 0         // phase clock at which the next antic fires (0 = disarmed)
    var gaze: Gaze = .none            // cursor-watching state this tick (nil-object when not near)

    init(statePath: String) {
        self.statePath = statePath
        self.sessionsDir = (statePath as NSString).deletingLastPathComponent + "/sessions"
    }
}

// MARK: - Pet view

final class PetView: NSView {
    let state: PetState
    let groundY: CGFloat = 40
    var petSize: CGFloat { state.config.size }   // user-configurable (config.json)
    var lastFrameTime: TimeInterval = Date().timeIntervalSince1970

    // Pupil offset (in cells) for the eyes this frame, resolved from `state.gaze`
    // for the current facing; (0,0) when the pet isn't watching the cursor.
    private var eyeLook: (x: Int, y: Int) = (0, 0)

    // Click-vs-drag tracking for the current mouse press. A press stays a
    // "click" (→ pet the dog) until the pointer travels past the drag threshold,
    // at which point it becomes a drag (→ reposition the window). See Interaction.
    private var pressAnchor: NSPoint = .zero   // cursor at mouseDown (screen coords)
    private var windowAnchor: NSPoint = .zero  // window origin at mouseDown
    private var pressTravel: CGFloat = 0       // greatest pointer travel seen this press
    private var isDraggingWindow = false
    // A single click's pet reaction is deferred briefly so a double-click (→ open
    // the host app) can cancel it — otherwise the first click of a double would
    // also pet. Cleared once it fires or is cancelled.
    private var petWork: DispatchWorkItem?
    // Set when a press opened the host app (double-click), so that press's own
    // trailing mouseUp doesn't schedule a pet on top of it.
    private var pressOpenedApp = false

    init(frame: NSRect, state: PetState) {
        self.state = state
        super.init(frame: frame)
        self.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // Only the pet body is a drag target; everywhere else the window is click-through.
    private func petBBox() -> NSRect {
        let cx = bounds.midX
        return NSRect(x: cx - petSize * 0.78, y: groundY - 12,
                      width: petSize * 1.56, height: petSize * 1.2)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return petBBox().contains(point) ? self : nil
    }

    // MARK: Mouse — click to pet, drag to reposition, double-click to open the host app.
    //
    // We take full control of the mouse (rather than the window's
    // `isMovableByWindowBackground`) so the three gestures can be told apart and
    // a double-click is *reliably* delivered to this view. `mouseDownCanMoveWindow
    // = false` keeps the window from moving itself; we move it by hand in
    // `mouseDragged`.
    //   • click (press that never travels past Interaction.dragThreshold) → pet
    //     the dog (the `loved` reaction), deferred slightly so a double-click can
    //     cancel it;
    //   • drag (travels further) → reposition the window; never pets;
    //   • double-click → open/focus the host app (openHostApp).
    override var mouseDownCanMoveWindow: Bool { false }

    // Let the very first click land on the pet even when the app is in the
    // background (it's an accessory app that never becomes key on its own).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Default host: the GitHub Copilot app that spawns the pet.
    private static let defaultHostBundleId = "com.github.githubapp"

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            petWork?.cancel(); petWork = nil   // the second click: cancel the pending pet
            pressOpenedApp = true              // …and don't let this press's mouseUp re-pet
            openHostApp()
            return
        }
        pressAnchor = NSEvent.mouseLocation
        windowAnchor = window?.frame.origin ?? .zero
        pressTravel = 0
        isDraggingWindow = false
        pressOpenedApp = false
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let dx = m.x - pressAnchor.x, dy = m.y - pressAnchor.y
        pressTravel = max(pressTravel, (dx * dx + dy * dy).squareRoot())
        if !isDraggingWindow, !Interaction.isClick(maxDisplacement: pressTravel) {
            isDraggingWindow = true
        }
        if isDraggingWindow {
            window?.setFrameOrigin(NSPoint(x: windowAnchor.x + dx, y: windowAnchor.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        // The trailing up of a double-click already opened the app — don't re-pet.
        if pressOpenedApp { pressOpenedApp = false; return }
        guard Interaction.isClick(maxDisplacement: pressTravel) else { return }
        // Defer the pet by the system double-click interval so a double-click
        // (→ open the host app) cancels it in mouseDown rather than also petting.
        petWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.petWork = nil; self?.petReaction() }
        petWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Play the local "petting" reaction: a brief delighted wriggle facing you.
    /// It auto-returns to idle (Mood.autoNext) and then re-syncs to the live
    /// session's mood (see advanceMood), so it never leaves the wire out of sync.
    private func petReaction() {
        state.mood = .loved
        state.message = ""
        state.moodChangeTime = Date().timeIntervalSince1970
        state.facing = .front            // turn to look at you when petted
        state.gaze = .none
        state.antic = nil; state.nextAntic = 0
        needsDisplay = true
    }

    /// Launch or focus the app configured by `openOnDoubleClick` (default: the
    /// GitHub Copilot host app). Launches it if it isn't running, otherwise
    /// brings it to the front.
    private func openHostApp() {
        switch state.config.doubleClickAction {
        case .disabled:
            return
        case .openDefaultHost:
            activateApp(bundleId: Self.defaultHostBundleId)
        case .openBundleId(let id):
            activateApp(bundleId: id)
        case .openApp(let nameOrPath):
            activateApp(nameOrPath: nameOrPath)
        }
    }

    private func activateApp(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        activate(url: url)
    }

    private func activateApp(nameOrPath: String) {
        let url: URL?
        if nameOrPath.hasSuffix(".app") || nameOrPath.contains("/") {
            url = URL(fileURLWithPath: nameOrPath)
        } else {
            // Bare app name: look in the standard Applications directories.
            let name = nameOrPath.hasSuffix(".app") ? nameOrPath : "\(nameOrPath).app"
            let dirs = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            url = dirs.map { $0.appendingPathComponent(name) }
                      .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let appURL = url, FileManager.default.fileExists(atPath: appURL.path) else { return }
        activate(url: appURL)
    }

    private func activate(url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }

    // MARK: Cadence — Reduce Motion + visibility

    /// Live read of the OS accessibility setting, checked every tick so the
    /// pet reacts immediately if the user flips it while running.
    private var osReduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Effective Reduce Motion: honors either the live OS accessibility setting
    /// or the user's `config.json` override — whichever asks for stillness wins.
    private var reduceMotionEnabled: Bool {
        osReduceMotionEnabled || state.config.reduceMotion
    }

    /// False while the window is hidden (`orderOut`) or occluded (covered by
    /// other windows / on another Space) — the two cases where redrawing and
    /// advancing the animation would burn CPU for pixels nobody can see.
    private var isVisibleOnScreen: Bool {
        guard let win = window else { return true }
        return win.isVisible && win.occlusionState.contains(.visible)
    }

    /// Seconds until the next tick should run. Computed fresh each call so it
    /// always reflects the latest mood, Reduce Motion setting, and window
    /// visibility — including changes `loadState()` just made this tick (e.g.
    /// a "hidden" mood ordering the window out).
    var nextTickInterval: TimeInterval {
        guard isVisibleOnScreen else { return Cadence.hiddenInterval }
        // A playing idle antic is real motion, so it runs at the active cadence
        // even though the mood itself (idle) is otherwise calm/throttled.
        let calm = Cadence.isCalm(state.mood) && state.antic == nil
        return Cadence.interval(reduceMotion: reduceMotionEnabled, calm: calm)
    }

    func tick() {
        let now = Date().timeIntervalSince1970
        let dt = min(0.1, now - lastFrameTime)
        lastFrameTime = now

        if now - state.lastPoll > 0.18 {
            state.lastPoll = now
            loadState()   // may hide/show the window (e.g. "hidden" mood)
            loadConfig()
        }

        let hbAgeMs = now * 1000.0 - state.heartbeat
        if hbAgeMs > 12_000 { NSApp.terminate(nil); return }

        // Re-check visibility after loadState() so a window it just hid/showed
        // is never animated or redrawn using stale pre-load visibility.
        let visible = isVisibleOnScreen

        // Only advance the animation clock while something can actually be
        // seen; a hidden/occluded pet still needs to poll state + heartbeat,
        // but there is nothing to animate or redraw.
        if visible { state.phase += dt }

        // Cursor gaze: while the pointer is near, the pet watches it — its eyes
        // track the cursor and its head turns via the three facings — instead of
        // glancing around on its own. It carries no motion budget of its own, so
        // it's gated behind the same `lookAround` behavior toggle and suppressed
        // under Reduce Motion, and only runs in calm idle (a real mood or a
        // playing antic keeps priority). Recomputed every visible tick.
        state.gaze = .none
        if visible, state.config.lookAround, !reduceMotionEnabled,
           state.mood == .idle, state.antic == nil {
            let g = cursorGaze()
            if g.active {
                state.gaze = g
                state.facing = g.facing
            }
        }

        // Occasionally turn to look right / left / at you (skip the first frame
        // so the initial facing sticks). Honors the lookAround behavior and
        // Reduce Motion (OS or config) — a still/hidden/occluded pet keeps
        // facing you; it's the most conspicuous "non-essential" motion. Skipped
        // while actively watching the cursor, so gaze isn't fought by a glance.
        if visible, state.config.lookAround, !reduceMotionEnabled, !state.gaze.active, now >= state.nextTurn {
            if state.nextTurn != 0 {
                state.facing = Facing.turn(from: state.facing, random: Double.random(in: 0..<1))
            }
            state.nextTurn = now + Double.random(in: state.config.lookAroundInterval)
        }

        advanceMood(now: now)
        if visible { updateAntics(); needsDisplay = true }
    }

    private func loadState() {
        let now = Date().timeIntervalSince1970
        let nowMs = now * 1000.0
        let sessions = readSessions()

        // The freshest controller heartbeat drives the shared watchdog: the pet
        // only self-terminates once *every* session has gone stale (checked in tick).
        if let freshest = sessions.map({ $0.heartbeat }).max() {
            state.heartbeat = freshest
        }

        let resolution = Arbitration.resolve(sessions, now: nowMs, hadLiveSessions: state.hadLiveSessions)
        state.hadLiveSessions = !Arbitration.liveSessions(sessions, now: nowMs).isEmpty

        guard let res = resolution else { return }  // no live session → keep current pose

        if case .quit = res.command { NSApp.terminate(nil); return }

        // React only when the driving session/event changes, so a session that
        // keeps re-writing the same mood doesn't reset local timers every poll.
        let key = "\(res.winner)#\(res.activity)"
        guard key != state.lastKey else { return }
        state.lastKey = key

        switch res.command {
        case .quit:
            return  // handled above
        case .hide:
            self.window?.orderOut(nil)
        case .show(let mood, let message):
            if let win = self.window, !win.isVisible { win.orderFrontRegardless() }
            state.mood = mood
            state.message = message
            state.moodChangeTime = now
            // On a fresh greeting, turn to face you for a moment.
            if state.mood == .greet {
                state.facing = .front
                state.nextTurn = now + 3
            }
        }
    }

    /// Read and parse every `*.json` session file, pruning long-dead ones so the
    /// directory doesn't grow without bound.
    private func readSessions() -> [SessionSnapshot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: state.sessionsDir) else { return [] }
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        var out: [SessionSnapshot] = []
        for name in names where name.hasSuffix(".json") {
            let full = state.sessionsDir + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let heartbeat = (obj["heartbeat"] as? Double) ?? 0
            // Well past the stale window: the controller is gone for good — clean up.
            if nowMs - heartbeat > 60_000 { try? fm.removeItem(atPath: full); continue }
            let id = (obj["id"] as? String) ?? (name as NSString).deletingPathExtension
            let mood = (obj["mood"] as? String) ?? "idle"
            let message = (obj["message"] as? String) ?? ""
            let activity = (obj["activity"] as? Double) ?? (obj["ts"] as? Double) ?? 0
            out.append(SessionSnapshot(id: id, mood: mood, message: message,
                                       activity: activity, heartbeat: heartbeat))
        }
        return out
    }

    // Poll config.json for changes (hot-reload). Cheap: only re-parses when the
    // file's mtime changes; an absent or unreadable file falls back to defaults.
    private func loadConfig() {
        let path = state.configPath
        guard !path.isEmpty else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        if mtime == state.configMTime { return }   // nothing changed
        state.configMTime = mtime

        let newConfig: PetConfig
        if mtime >= 0,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            newConfig = PetConfig.parse(obj)
        } else {
            newConfig = PetConfig()   // absent or broken → defaults
        }

        let oldSize = state.config.size
        state.config = newConfig
        if !newConfig.lookAround { state.facing = .front }   // stop mid-glance
        if newConfig.size != oldSize { resizeWindow() }
        needsDisplay = true
    }

    // Grow/shrink the window to fit the configured pet size. The pet is drawn
    // bottom-centered, so we keep the bottom edge and horizontal center fixed
    // (grow symmetrically about the center) so it doesn't jump when resized.
    private func resizeWindow() {
        guard let win = self.window else { return }
        let newSize = windowSize(for: petSize)
        var frame = win.frame
        frame.origin.x -= (newSize.width - frame.size.width) / 2   // keep center
        frame.size = newSize
        win.setFrame(frame, display: true)
        self.frame = CGRect(origin: .zero, size: newSize)
    }

    private func advanceMood(now: TimeInterval) {
        guard let n = state.mood.autoNext else { return }
        if now - state.moodChangeTime > n.after {
            let was = state.mood
            state.mood = n.to
            state.moodChangeTime = now
            // A local `loved` reaction overrode the wire; on the way back to
            // idle, clear lastKey so loadState re-applies whatever the live
            // session is actually doing (e.g. resume "working").
            if was == .loved { state.lastKey = "" }
        }
    }

    /// Schedule and expire idle antics. Antics enliven the calm `idle` mood only:
    /// any real mood — or Reduce Motion (OS setting or config override) — cancels
    /// the current antic and disarms the scheduler, which re-arms on the next
    /// return to idle. Timing runs on the animation `phase` clock so it matches
    /// the pose the renderer draws.
    private func updateAntics() {
        let clock = state.phase
        guard state.mood == .idle, !reduceMotionEnabled else {
            state.antic = nil
            state.nextAntic = 0
            return
        }
        if let a = state.antic {
            if clock - state.anticStart >= a.duration { state.antic = nil }   // finished → back to idle
        } else if state.nextAntic == 0 {
            state.nextAntic = clock + IdleAntics.nextGap(random: .random(in: 0..<1))   // arm the next gap
        } else if clock >= state.nextAntic {
            let a = IdleAntics.pick(random: .random(in: 0..<1), avoiding: state.lastAntic)
            state.antic = a
            state.lastAntic = a
            state.anticStart = clock
            state.nextAntic = 0    // re-armed once this antic ends
        }
    }

    /// The pet's gaze toward the current cursor position. Polls the global mouse
    /// location (works regardless of key/focus, since this is an accessory app)
    /// and measures it against the pet's head center in screen coordinates. The
    /// pure `Gaze` model decides whether the cursor is near, which way to face,
    /// and how far to shift the pupils.
    private func cursorGaze() -> Gaze {
        guard let win = window else { return .none }
        let m = NSEvent.mouseLocation                       // global screen coords
        // Head center in screen coords: the pet is drawn bottom-centered, with
        // the head sitting a little above the body center.
        let headX = win.frame.origin.x + bounds.midX
        let headY = win.frame.origin.y + groundY + petSize * 0.5 + petSize * 0.28
        return Gaze.toward(dx: m.x - headX, dy: m.y - headY, size: petSize)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let W = bounds.width
        let phase = state.phase
        let anticPhase = state.antic != nil ? max(0, phase - state.anticStart) : 0
        let pose = Pose.make(for: state.mood, phase: phase, message: state.message,
                             reduceMotion: reduceMotionEnabled,
                             antic: state.antic, anticPhase: anticPhase)

        // Resolve the pupil offset for this frame from the cursor gaze. It's
        // expressed in world space (+x = screen-right), so mirror the horizontal
        // component when the side sprite is drawn flipped for a left facing.
        eyeLook = (x: 0, y: 0)
        if state.gaze.active {
            let px = Int(state.gaze.pupil.dx.rounded())
            let py = Int(state.gaze.pupil.dy.rounded())
            eyeLook = (x: state.facing == .left ? -px : px, y: py)
        }

        let cx = bounds.midX
        let cy = groundY + petSize * 0.5 + pose.bob

        // Contact shadow — a crisp pixel oval hugging the paws on the ground
        // line. It shrinks and fades as the dog bounces up, so a jump reads as
        // leaving the ground rather than the whole dog floating.
        let scell = max(2, (petSize / 26).rounded())
        let ground = (groundY + petSize * 0.5 + (-0.44 * petSize).rounded()).rounded()
        let shrink = max(0.5, 1 - pose.bob / 34)
        let halfW = (petSize * 0.55 * shrink / scell).rounded() * scell
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.20 * shrink).cgColor)
        ctx.fill(CGRect(x: (cx - halfW).rounded(), y: ground - scell, width: halfW * 2, height: scell))
        ctx.fill(CGRect(x: (cx - halfW + scell).rounded(), y: ground - scell * 2,
                        width: (halfW - scell) * 2, height: scell))
        ctx.restoreGState()

        // Pet body — crisp pixels: anti-aliasing off, origin snapped to whole
        // device pixels so no cell lands on a half-pixel (which would blur it).
        // Left facing mirrors the side sprite; front is its own drawing.
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.translateBy(x: cx.rounded(), y: cy.rounded())
        ctx.scaleBy(x: (state.facing == .left ? -1 : 1) * pose.scaleX, y: pose.scaleY)
        if state.facing == .front {
            drawDachshundFront(size: petSize, pose: pose, phase: phase)
        } else {
            drawDachshundPixel(size: petSize, pose: pose, phase: phase)
        }
        ctx.restoreGState()

        // Accessory (pixel-art icon near head) — placed on the side the head
        // faces (mirrored for left, up-and-right for front).
        if let acc = pose.accessory {
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            let accBob = sin(phase * 4) * 3 * pose.motionScale
            let up = cy + petSize * (acc == .think ? 0.50 : 0.36) + accBob
            switch state.facing {
            case .right:
                let ax = (cx + petSize * (acc == .think ? 0.58 : 0.38)).rounded()
                drawAccessory(acc, at: CGPoint(x: ax, y: up.rounded()), phase: phase, motionScale: pose.motionScale)
            case .left:
                let ax = (cx - petSize * (acc == .think ? 0.58 : 0.38)).rounded()
                ctx.translateBy(x: ax, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -ax, y: 0)
                drawAccessory(acc, at: CGPoint(x: ax, y: up.rounded()), phase: phase, motionScale: pose.motionScale)
            case .front:
                let ax = (cx + petSize * 0.44).rounded()
                drawAccessory(acc, at: CGPoint(x: ax, y: (cy + petSize * 0.55 + accBob).rounded()), phase: phase, motionScale: pose.motionScale)
            }
            ctx.restoreGState()
        }

        // Speech bubble (suppressed when muted or the bubbles behavior is off)
        if state.config.bubblesEnabled, let text = pose.bubble, !text.isEmpty {
            drawBubble(text, petCenterX: cx, baseY: cy + petSize * 0.55 + 12, maxWidth: W)
        }
    }

    // MARK: Pixel-art dachshund

    private static let cOutline  = NSColor(red: 0.17, green: 0.10, blue: 0.07, alpha: 1)
    private static let cBody     = NSColor(red: 0.64, green: 0.37, blue: 0.18, alpha: 1)
    private static let cBodyHi   = NSColor(red: 0.77, green: 0.51, blue: 0.28, alpha: 1) // warm highlight
    private static let cShade    = NSColor(red: 0.44, green: 0.24, blue: 0.19, alpha: 1) // hue-shifted shadow
    private static let cDark     = NSColor(red: 0.38, green: 0.21, blue: 0.11, alpha: 1) // ears / tail
    private static let cTan      = NSColor(red: 0.91, green: 0.73, blue: 0.50, alpha: 1) // belly / muzzle / paws
    private static let cTanShade = NSColor(red: 0.78, green: 0.58, blue: 0.38, alpha: 1)
    private static let cNose     = NSColor(red: 0.15, green: 0.10, blue: 0.09, alpha: 1)
    private static let cEye      = NSColor(red: 0.13, green: 0.10, blue: 0.10, alpha: 1)
    private static let cTongue   = NSColor(red: 0.92, green: 0.44, blue: 0.47, alpha: 1)
    private static let cCheek    = NSColor(red: 0.95, green: 0.58, blue: 0.52, alpha: 0.55)
    private static let cSaddle   = NSColor(red: 0.33, green: 0.17, blue: 0.09, alpha: 1) // dark back marking

    /// Draws a chibi pixel-art dachshund centred at the origin, facing right.
    /// The body is drawn first, then the head as a separate group that can tilt,
    /// sniff (nose-down) or tremble — so moods animate real body parts rather
    /// than sliding the whole picture around.
    private func drawDachshundPixel(size s: CGFloat, pose: Pose, phase: Double) {
        let feat = pose.feat
        let cell = max(2, (s / 26).rounded())
        let footY = (-0.44 * s).rounded()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        func box(_ cx: Int, _ cy: Int, _ w: Int, _ h: Int, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(cx) * cell, y: footY + CGFloat(cy) * cell,
                                      width: CGFloat(w) * cell, height: CGFloat(h) * cell)).fill()
        }

        // Animated offsets: tail wag + ear flap (quicker when excited), damped
        // by pose.motionScale under Reduce Motion.
        let wag = feat.wag > 0 ? Int((sin(phase * feat.wag) * 1.8 * pose.motionScale).rounded()) : 0
        let ear = Int((sin(phase * (feat.wag > 6 ? 7 : 2.6)) * 1 * pose.motionScale).rounded())

        // ---- BODY: tail, legs, torso ----
        func bodySolids(_ dx: Int, _ dy: Int, _ flat: NSColor?) {
            func p(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ real: NSColor) { box(x + dx, y + dy, w, h, flat ?? real) }
            if feat.tailDown {
                p(-16, 2, 2, 3, PetView.cDark); p(-17, 1, 2, 2, PetView.cDark)
            } else {
                p(-16, 5, 2, 2, PetView.cDark); p(-17, 7, 2, 2, PetView.cDark)
                p(-18 + wag, 9, 2, 2, PetView.cDark)         // curled tip
            }
            for lx in [-13, -9, 5, 9] { p(lx, 0, 3, 3, PetView.cBody) }   // stubby legs
            p(-15, 3, 25, 5, PetView.cBody)                  // long low sausage
            p(-14, 8, 23, 1, PetView.cBody); p(-14, 2, 23, 1, PetView.cBody)
        }
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { bodySolids(ox, oy, PetView.cOutline) }
        bodySolids(0, 0, nil)
        box(-14, 6, 21, 3, PetView.cSaddle)         // dark saddle wraps the back
        box(-13, 8, 21, 1, PetView.cBodyHi)         // warm topline highlight
        box(-14, 2, 23, 2, PetView.cTan)            // tan belly (bottom rows)
        box(-14, 2, 23, 1, PetView.cTanShade)       // shadow at the very bottom edge
        for lx in [-13, -9, 5, 9] { box(lx, 0, 3, 1, PetView.cTan) }   // paws

        // ---- HEAD: head, snout, ear, face — animated around the neck pivot ----
        let jitter = pose.tremble > 0 ? CGFloat(Int((sin(phase * 34) * pose.tremble).rounded())) : 0
        let px = CGFloat(9) * cell, py = footY + CGFloat(6) * cell   // neck pivot
        ctx.saveGState()
        ctx.translateBy(x: px + jitter * cell, y: py + pose.headBob * cell)
        if pose.headTilt != 0 { ctx.rotate(by: pose.headTilt) }
        ctx.translateBy(x: -px, y: -py)

        func headSolids(_ dx: Int, _ dy: Int, _ flat: NSColor?) {
            func p(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ real: NSColor) { box(x + dx, y + dy, w, h, flat ?? real) }
            p(7, 5, 11, 9, PetView.cBody)                    // big round head
            p(8, 14, 9, 1, PetView.cBody); p(8, 4, 9, 1, PetView.cBody)
            p(16, 5, 6, 4, PetView.cBody); p(21, 6, 2, 2, PetView.cBody)   // long snout
            p(7 + ear, 3, 4, 10, PetView.cDark); p(8, 2, 3, 1, PetView.cDark)   // floppy ear
        }
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { headSolids(ox, oy, PetView.cOutline) }
        headSolids(0, 0, nil)
        box(5, 4, 12, 2, PetView.cTan)              // tan chest/neck (also hides the seam)
        box(8, 13, 8, 1, PetView.cBodyHi)           // head highlight
        box(16, 5, 6, 2, PetView.cTan)              // tan under the snout
        box(20, 5, 3, 3, PetView.cNose)             // nose at the snout tip
        if feat.eyes == .happy { box(15, 7, 2, 2, PetView.cCheek) }    // blush when delighted
        drawEye(feat.eyes, box: box, phase: phase)
        drawMouth(feat.mouth, box: box, phase: phase, motionScale: pose.motionScale)
        ctx.restoreGState()
    }

    /// Face-on view of the dachshund: round head, both floppy ears, two eyes,
    /// front paws. Symmetric around x = 0. Head group animates (tilt/sniff/tremble).
    private func drawDachshundFront(size s: CGFloat, pose: Pose, phase: Double) {
        let feat = pose.feat
        let cell = max(2, (s / 26).rounded())
        let footY = (-0.44 * s).rounded()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        func box(_ cx: Int, _ cy: Int, _ w: Int, _ h: Int, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(cx) * cell, y: footY + CGFloat(cy) * cell,
                                      width: CGFloat(w) * cell, height: CGFloat(h) * cell)).fill()
        }
        let ear = Int((sin(phase * (feat.wag > 6 ? 7 : 2.6)) * 1 * pose.motionScale).rounded())

        // ---- BODY: two front legs + chest ----
        func bodySolids(_ dx: Int, _ dy: Int, _ flat: NSColor?) {
            func p(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ real: NSColor) { box(x + dx, y + dy, w, h, flat ?? real) }
            p(-5, 0, 3, 4, PetView.cBody); p(2, 0, 3, 4, PetView.cBody)   // front legs
            p(-6, 2, 12, 6, PetView.cBody); p(-5, 8, 10, 1, PetView.cBody)   // chest
        }
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { bodySolids(ox, oy, PetView.cOutline) }
        bodySolids(0, 0, nil)
        box(-1, 2, 2, 6, PetView.cTan)              // tan chest blaze
        box(-5, 0, 3, 1, PetView.cTan); box(2, 0, 3, 1, PetView.cTan)   // paw tips
        box(-6, 8, 12, 1, PetView.cBodyHi)          // chest top highlight

        // ---- HEAD group: head, ears, face (tilts / bobs / trembles) ----
        let jitter = pose.tremble > 0 ? CGFloat(Int((sin(phase * 34) * pose.tremble).rounded())) : 0
        let px: CGFloat = 0, py = footY + CGFloat(7) * cell
        ctx.saveGState()
        ctx.translateBy(x: px + jitter * cell, y: py + pose.headBob * cell)
        if pose.headTilt != 0 { ctx.rotate(by: pose.headTilt) }
        ctx.translateBy(x: -px, y: -py)

        func headSolids(_ dx: Int, _ dy: Int, _ flat: NSColor?) {
            func p(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ real: NSColor) { box(x + dx, y + dy, w, h, flat ?? real) }
            p(-7, 7, 14, 9, PetView.cBody)                       // big round head
            p(-6, 16, 12, 1, PetView.cBody); p(-6, 6, 12, 1, PetView.cBody)
            p(-9, 8 + ear, 3, 8, PetView.cDark); p(6, 8 - ear, 3, 8, PetView.cDark)   // floppy ears
        }
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { headSolids(ox, oy, PetView.cOutline) }
        headSolids(0, 0, nil)
        box(-6, 15, 12, 1, PetView.cSaddle)         // dark cap on top of the head
        box(-5, 14, 10, 1, PetView.cBodyHi)         // head highlight
        box(-3, 8, 6, 3, PetView.cTan)              // tan muzzle
        box(-1, 9, 2, 2, PetView.cNose)             // nose (center)
        if feat.eyes == .happy { box(-6, 10, 2, 2, PetView.cCheek); box(4, 10, 2, 2, PetView.cCheek) }

        // Two eyes
        let blink = feat.eyes == .open && fmod(phase, 3.4) < 0.12
        // Both eyes shift together toward the cursor (0 when not watching). Front
        // is drawn un-mirrored, so the world-space offset applies directly.
        let lx = eyeLook.x, ly = eyeLook.y
        func frontEye(_ ex: Int) {
            switch feat.eyes {
            case .open, .worried:
                if blink { box(ex + lx, 12 + ly, 3, 1, PetView.cEye); return }
                box(ex + lx, 11 + ly, 3, 3, PetView.cOutline)
                box(ex + lx, 11 + ly, 2, 2, PetView.cEye)
                box(ex + 1 + lx, 12 + ly, 1, 1, .white)       // catchlight
            case .closed:
                box(ex, 12, 3, 1, PetView.cEye)
            case .happy:
                box(ex, 11, 1, 1, PetView.cEye); box(ex + 1, 12, 1, 1, PetView.cEye); box(ex + 2, 11, 1, 1, PetView.cEye)
            }
        }
        frontEye(-5); frontEye(2)
        if feat.eyes == .worried {                  // brows angled inward = fretting
            box(-5, 14, 2, 1, PetView.cOutline); box(3, 14, 2, 1, PetView.cOutline)
        }

        // Mouth (centered, below the nose)
        switch feat.mouth {
        case .neutral: box(-1, 8, 2, 1, PetView.cNose)
        case .smile:   box(-2, 8, 1, 1, PetView.cNose); box(-1, 7, 2, 1, PetView.cNose); box(1, 8, 1, 1, PetView.cNose)
        case .pant, .open:
            box(-1, 7, 2, 2, PetView.cNose)
            if feat.mouth == .pant {
                // Under Reduce Motion, freeze the tongue on a stable frame instead of
                // toggling 0/1 at full cadence (motionScale only damps amplitude, not rate).
                let drop = pose.motionScale < 1 ? 0 : Int(((sin(phase * 8) * 0.5) + 0.5).rounded())
                box(-1, 6 - drop, 2, 1 + drop, PetView.cTongue)
            }
        case .yawn:
            box(-2, 6, 4, 3, PetView.cNose)          // wide gaping muzzle
            box(-1, 6, 2, 1, PetView.cTongue)        // tongue at the base
        }
        ctx.restoreGState()
    }

    private func drawEye(_ e: EyeState, box: (Int, Int, Int, Int, NSColor) -> Void, phase: Double) {
        // Shift the whole eye toward the cursor (0 when not watching). The eye
        // moving as a unit reads as the pet looking that way, and preserves the
        // approved eye art rather than clipping a pupil inside a tiny rim.
        let lx = eyeLook.x, ly = eyeLook.y
        let blink = e == .open && fmod(phase, 3.4) < 0.12
        switch e {
        case .open, .worried:
            if blink { box(12 + lx, 10 + ly, 4, 1, PetView.cEye); return }
            box(12 + lx, 9 + ly, 4, 4, PetView.cOutline)          // eye rim
            box(12 + lx, 9 + ly, 3, 3, PetView.cEye)              // big round eye
            box(14 + lx, 11 + ly, 1, 1, .white); box(13 + lx, 12 + ly, 1, 1, .white)  // catchlight sparkle
            if e == .worried { box(11 + lx, 13 + ly, 4, 1, PetView.cOutline) }   // raised brow
        case .closed:
            box(12, 10, 4, 1, PetView.cEye)             // content lids
            box(11, 11, 1, 1, PetView.cEye); box(15, 11, 1, 1, PetView.cEye)
        case .happy:
            box(11, 10, 1, 1, PetView.cEye); box(12, 11, 1, 1, PetView.cEye)   // ^_^ arc
            box(14, 11, 1, 1, PetView.cEye); box(15, 10, 1, 1, PetView.cEye)
            box(13, 11, 1, 1, PetView.cEye)
        }
    }

    private func drawMouth(_ m: MouthState, box: (Int, Int, Int, Int, NSColor) -> Void, phase: Double, motionScale: CGFloat) {
        switch m {
        case .neutral:
            box(18, 4, 2, 1, PetView.cNose)
        case .smile:
            box(17, 4, 1, 1, PetView.cNose); box(18, 3, 3, 1, PetView.cNose)
        case .pant, .open:
            box(18, 3, 3, 2, PetView.cNose)
            if m == .pant {
                // Under Reduce Motion, freeze the tongue on a stable frame instead of
                // toggling 0/1 at full cadence (motionScale only damps amplitude, not rate).
                let drop = motionScale < 1 ? 0 : Int(((sin(phase * 8) * 0.5) + 0.5).rounded())
                box(18, 2 - drop, 2, 1 + drop, PetView.cTongue)
            }
        case .yawn:
            box(18, 2, 4, 3, PetView.cNose)          // wide gaping muzzle
            box(19, 2, 2, 1, PetView.cTongue)        // tongue at the base
        }
    }

    // MARK: Pixel-art accessories (drawn in view coords beside the head)

    private static let cGear      = NSColor(white: 0.62, alpha: 1)
    private static let cGearDark  = NSColor(white: 0.38, alpha: 1)
    private static let cSpark     = NSColor(red: 1.00, green: 0.83, blue: 0.28, alpha: 1)
    private static let cSweat     = NSColor(red: 0.33, green: 0.62, blue: 0.95, alpha: 1)
    private static let cCloud     = NSColor(white: 1.00, alpha: 0.97)
    private static let cCloudEdge = NSColor(white: 0.72, alpha: 1)
    private static let cZ         = NSColor(red: 0.22, green: 0.46, blue: 0.86, alpha: 1)
    private static let cPaw       = NSColor(red: 0.90, green: 0.70, blue: 0.48, alpha: 1)

    private func drawAccessory(_ a: Accessory, at c: CGPoint, phase: Double, motionScale: CGFloat) {
        let u: CGFloat = 3                      // same pixel unit as the dog body
        func b(_ gx: CGFloat, _ gy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: c.x + gx * u, y: c.y + gy * u,
                                      width: w * u, height: h * u)).fill()
        }
        switch a {
        case .gear:
            b(-1.5, -1.5, 3, 3, PetView.cGear)
            b(-0.5, -0.5, 1, 1, PetView.cGearDark)          // hub
            // Teeth alternate N/S/E/W ↔ corners to suggest spinning; frozen on
            // the N/S/E/W frame under Reduce Motion so the gear stays readable
            // without flickering.
            if motionScale < 1 || Int(phase * 4) % 2 == 0 {
                b(-0.5, 1.5, 1, 1, PetView.cGear); b(-0.5, -2.5, 1, 1, PetView.cGear)
                b(1.5, -0.5, 1, 1, PetView.cGear); b(-2.5, -0.5, 1, 1, PetView.cGear)
            } else {                                        // teeth on corners → spins
                b(1.5, 1.5, 1, 1, PetView.cGear); b(-2.5, 1.5, 1, 1, PetView.cGear)
                b(1.5, -2.5, 1, 1, PetView.cGear); b(-2.5, -2.5, 1, 1, PetView.cGear)
            }
        case .sparkle:
            // Pulses between two sizes normally; frozen at a mid-size under
            // Reduce Motion instead of continuing to flicker.
            let big: CGFloat = motionScale < 1 ? 1.7 : (sin(phase * 6) > 0 ? 2 : 1.4)
            b(-0.5, -big, 1, big * 2, PetView.cSpark)
            b(-big, -0.5, big * 2, 1, PetView.cSpark)
            b(1.8, 1.3, 0.8, 1.6, PetView.cSpark)           // small companion
            b(1.4, 1.7, 1.6, 0.8, PetView.cSpark)
        case .sweat:
            let d = CGFloat(sin(phase * 5)) * 0.3 * motionScale
            b(-1, -1 + d, 2, 2, PetView.cSweat)             // droplet
            b(-0.5, 1 + d, 1, 1, PetView.cSweat)            // tip
            b(1.4, 0.2 - d, 1, 1, PetView.cSweat)           // second bead
        case .think:
            let e = PetView.cCloudEdge                       // gray outline → visible on white
            b(-2.1, -0.1, 4.2, 1.7, e); b(-1.5, 0.9, 2.8, 1.2, e)
            b(-2.7, 0.1, 1.6, 1.3, e); b(1.1, 0.1, 1.4, 1.3, e)
            b(-2, 0, 4, 1.5, PetView.cCloud)
            b(-1.4, 1, 2.6, 1, PetView.cCloud)
            b(-2.6, 0.2, 1.4, 1.1, PetView.cCloud)
            b(1.2, 0.2, 1.2, 1.1, PetView.cCloud)
            b(-2.3, -1.8, 1.1, 1.1, e); b(-2.2, -1.7, 0.9, 0.9, PetView.cCloud)  // trailing puffs
            b(-3.1, -3.0, 0.9, 0.9, e); b(-3.0, -2.9, 0.7, 0.7, PetView.cCloud)
        case .sleep:
            let r = CGFloat(sin(phase * 2)) * 0.4 * motionScale
            b(-1.6, 1.4 + r, 3, 0.8, PetView.cZ)            // big Z
            b(0.2, 0.4 + r, 0.9, 0.9, PetView.cZ)
            b(-0.7, -0.4 + r, 0.9, 0.9, PetView.cZ)
            b(-1.6, -1.2 + r, 3, 0.8, PetView.cZ)
            b(1.7, 2.5 + r, 1.6, 0.6, PetView.cZ)           // small z
            b(2.0, 1.9 + r, 0.6, 0.6, PetView.cZ)
            b(1.7, 1.4 + r, 1.6, 0.6, PetView.cZ)
        case .wave:
            let dx = CGFloat(sin(phase * 7)) * 0.4 * motionScale   // waving paw
            b(-1.5 + dx, -1.5, 3, 3, PetView.cPaw)          // palm
            b(-1.5 + dx, 1.4, 0.8, 0.9, PetView.cPaw)       // toes
            b(-0.4 + dx, 1.4, 0.8, 0.9, PetView.cPaw)
            b(0.7 + dx, 1.4, 0.8, 0.9, PetView.cPaw)
            b(-2.4 + dx, -0.3, 0.9, 1.2, PetView.cPaw)      // thumb
            b(-1.0 + dx, -1.1, 0.7, 0.7, PetView.cShade)    // pad
        }
    }

    private func drawBubble(_ text: String, petCenterX: CGFloat, baseY: CGFloat, maxWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let ns = text as NSString
        var textSize = ns.size(withAttributes: attrs)
        textSize.width = min(textSize.width, 220)
        let padX: CGFloat = 12, padY: CGFloat = 8
        let bw = textSize.width + padX * 2
        let bh = textSize.height + padY * 2

        var bx = petCenterX - bw / 2
        bx = max(8, min(bx, maxWidth - bw - 8))
        let by = baseY

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: bx, y: by, width: bw, height: bh)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        let tailX = min(max(petCenterX, bx + 14), bx + bw - 14)
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: tailX - 7, y: by))
        tail.line(to: CGPoint(x: tailX + 7, y: by))
        tail.line(to: CGPoint(x: tailX, y: by - 9))
        tail.close()
        path.append(tail)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6,
                      color: NSColor(white: 0, alpha: 0.25).cgColor)
        NSColor(white: 1.0, alpha: 0.96).setFill()
        path.fill()
        ctx.restoreGState()

        ns.draw(in: CGRect(x: bx + padX, y: by + padY, width: textSize.width, height: textSize.height),
                withAttributes: attrs)
    }
}

// MARK: - Position persistence

func readPos(_ path: String) -> CGPoint? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { return nil }
    return CGPoint(x: parts[0], y: parts[1])
}

func writePos(_ o: CGPoint, _ path: String) {
    try? "\(o.x),\(o.y)".write(toFile: path, atomically: true, encoding: .utf8)
}

/// Window dimensions sized to fit the pet (config `size`), with a floor that
/// keeps speech bubbles readable for small pets.
func windowSize(for petSize: CGFloat) -> CGSize {
    CGSize(width: max(200, (petSize * 3.3).rounded()),
           height: max(170, (petSize * 2.8).rounded()))
}

// MARK: - App bootstrap

@main
enum PetApp {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write("usage: pet <state.json>\n".data(using: .utf8)!)
            exit(2)
        }
        let statePath = CommandLine.arguments[1]
        let posPath = (statePath as NSString).deletingLastPathComponent + "/pet.pos"
        // Optional user settings file (argv[2]); the pet also hot-reloads it.
        let configPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : ""

        // Single-instance: hold an exclusive lock for the process lifetime. A second
        // pet (from a restart race or a concurrent session) fails to acquire it and
        // exits immediately, so only one dog is ever on screen.
        let lockPath = (statePath as NSString).deletingLastPathComponent + "/pet.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = PetState(statePath: statePath)
        state.configPath = configPath
        // Read the config once up front so the initial window is the right size.
        if !configPath.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state.config = PetConfig.parse(obj)
            let attrs = try? FileManager.default.attributesOfItem(atPath: configPath)
            state.configMTime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        }

        let winSize = windowSize(for: state.config.size)
        var origin = CGPoint(x: 200, y: 200)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            origin = CGPoint(x: vf.maxX - winSize.width - 40, y: vf.minY + 60)
        }
        // Restore the saved position only if it still lands on a connected screen —
        // otherwise a pet persisted off a now-disconnected display would be unreachable.
        if let saved = readPos(posPath),
           NSScreen.screens.contains(where: { $0.frame.intersects(CGRect(origin: saved, size: winSize)) }) {
            origin = saved
        }

        let window = NSWindow(contentRect: CGRect(origin: origin, size: winSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = false
        // Drag, click-to-pet, and double-click-to-open are all handled by PetView
        // (see its Mouse section); the window's own background-drag would swallow
        // those distinctions, so it's left off and PetView moves the window itself.
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = PetView(frame: CGRect(origin: .zero, size: winSize), state: state)
        window.contentView = view
        window.orderFrontRegardless()

        // Persist the position after the drag settles (debounced), not on every frame.
        var posSaveWork: DispatchWorkItem?
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
            posSaveWork?.cancel()
            let work = DispatchWorkItem { writePos(window.frame.origin, posPath) }
            posSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        // Animation cadence is dynamic — Reduce Motion, calm moods, and window
        // visibility/occlusion all throttle it (see PetView.nextTickInterval) —
        // so each tick reschedules its own one-shot timer instead of relying on
        // a single fixed 30 FPS repeating timer. Because tick() runs loadState()
        // before this returns, the next interval always reflects any visibility
        // change (e.g. a "hidden" mood ordering the window out) from this tick.
        func scheduleNextTick() {
            let t = Timer(timeInterval: view.nextTickInterval, repeats: false) { _ in
                MainActor.assumeIsolated {
                    view.tick()
                    scheduleNextTick()
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
        scheduleNextTick()

        app.run()
    }
}
