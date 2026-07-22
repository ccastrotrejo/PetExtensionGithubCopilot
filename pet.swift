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
    var lastSeq: Int = -1
    var mood: Mood = .greet
    var message: String = ""
    var moodChangeTime: TimeInterval = Date().timeIntervalSince1970
    var heartbeat: Double = Date().timeIntervalSince1970 * 1000.0
    var phase: Double = 0
    var lastPoll: TimeInterval = 0

    init(statePath: String) { self.statePath = statePath }
}

// MARK: - Pet view

final class PetView: NSView {
    let state: PetState
    let groundY: CGFloat = 40
    let petSize: CGFloat = 62
    var lastFrameTime: TimeInterval = Date().timeIntervalSince1970

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

    func tick() {
        let now = Date().timeIntervalSince1970
        let dt = min(0.1, now - lastFrameTime)
        lastFrameTime = now
        state.phase += dt

        if now - state.lastPoll > 0.18 {
            state.lastPoll = now
            loadState()
        }

        let hbAgeMs = now * 1000.0 - state.heartbeat
        if hbAgeMs > 12_000 { NSApp.terminate(nil); return }

        advanceMood(now: now)
        needsDisplay = true
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: state.statePath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let hb = obj["heartbeat"] as? Double { state.heartbeat = hb }
        let seq = (obj["seq"] as? Int) ?? Int((obj["seq"] as? Double) ?? -1)
        guard seq != state.lastSeq else { return }
        state.lastSeq = seq

        let raw = (obj["mood"] as? String) ?? "idle"
        if raw == "quit" { NSApp.terminate(nil); return }
        if let win = self.window {
            if raw == "hidden" { win.orderOut(nil) }
            else if !win.isVisible { win.orderFrontRegardless() }
        }
        if raw != "hidden" { state.mood = Mood(rawValue: raw) ?? .idle }
        state.message = (obj["message"] as? String) ?? ""
        state.moodChangeTime = Date().timeIntervalSince1970
    }

    private func advanceMood(now: TimeInterval) {
        guard let n = state.mood.autoNext else { return }
        if now - state.moodChangeTime > n.after {
            state.mood = n.to
            state.moodChangeTime = now
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let W = bounds.width
        let phase = state.phase
        let pose = Pose.make(for: state.mood, phase: phase, message: state.message)

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
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.translateBy(x: (cx + pose.shakeX).rounded(), y: cy.rounded())
        if pose.rot != 0 { ctx.rotate(by: pose.rot) }
        ctx.scaleBy(x: 1, y: pose.scaleY)
        drawDachshundPixel(size: petSize, feat: pose.feat, phase: phase)
        ctx.restoreGState()

        // Accessory (pixel-art icon near head) — same pixel unit as the dog.
        if let acc = pose.accessory {
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            let accBob = sin(phase * 4) * 3
            // Most icons hover just above the head; the thought cloud floats
            // up-and-right so it clears both the head and the speech bubble.
            let ax = (cx + petSize * (acc == .think ? 0.58 : 0.38)).rounded()
            let ay = (cy + petSize * (acc == .think ? 0.50 : 0.36) + accBob).rounded()
            drawAccessory(acc, at: CGPoint(x: ax, y: ay), phase: phase)
            ctx.restoreGState()
        }

        // Speech bubble
        if let text = pose.bubble, !text.isEmpty {
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
    /// Long low body, tiny legs, long snout, floppy ears — the sausage-dog look.
    /// Whole-cell coordinates; y counts up from the feet. A dark outline pass
    /// (silhouette offset in 4 directions) keeps it readable on any wallpaper.
    private func drawDachshundPixel(size s: CGFloat, feat: DogFeatures, phase: Double) {
        let cell = max(2, (s / 26).rounded())
        let footY = (-0.44 * s).rounded()

        func box(_ cx: Int, _ cy: Int, _ w: Int, _ h: Int, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(cx) * cell, y: footY + CGFloat(cy) * cell,
                                      width: CGFloat(w) * cell, height: CGFloat(h) * cell)).fill()
        }

        // Animated offsets: tail wags, ear flaps (faster when excited).
        let wag = feat.wag > 0 ? Int((sin(phase * feat.wag) * 1.8).rounded()) : 0
        let ear = Int((sin(phase * (feat.wag > 6 ? 7 : 2.6)) * 1).rounded())

        // Solid silhouette parts — reused for the dark outline pass and the fill.
        func solids(_ dx: Int, _ dy: Int, _ flat: NSColor?) {
            func p(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ real: NSColor) {
                box(x + dx, y + dy, w, h, flat ?? real)
            }
            // Tail — long & tapering, held up off the rump (wags side to side)
            if feat.tailDown {
                p(-16, 2, 2, 3, PetView.cDark); p(-17, 1, 2, 2, PetView.cDark)
            } else {
                p(-16, 5, 2, 2, PetView.cDark)
                p(-17, 7, 2, 2, PetView.cDark)
                p(-18 + wag, 9, 2, 2, PetView.cDark)     // curled tip
            }
            // Legs — very short & stubby (the dachshund signature)
            for lx in [-13, -9, 5, 9] { p(lx, 0, 3, 3, PetView.cBody) }
            // Body — long, low sausage
            p(-15, 3, 25, 5, PetView.cBody)
            p(-14, 8, 23, 1, PetView.cBody)              // rounded topline
            p(-14, 2, 23, 1, PetView.cBody)              // rounded underline
            // Head — big round chibi at the right end
            p(7, 5, 11, 9, PetView.cBody)
            p(8, 14, 9, 1, PetView.cBody); p(8, 4, 9, 1, PetView.cBody)
            // Long snout tapering out to the right
            p(16, 5, 6, 4, PetView.cBody)
            p(21, 6, 2, 2, PetView.cBody)
            // Ear — long & floppy, hangs down the cheek (sways)
            p(7 + ear, 3, 4, 10, PetView.cDark); p(8, 2, 3, 1, PetView.cDark)
        }

        // 1) dark outline
        for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { solids(ox, oy, PetView.cOutline) }
        // 2) flat fill
        solids(0, 0, nil)

        // 3) two-tone markings + shading (fill only, top-left light)
        box(-14, 6, 21, 3, PetView.cSaddle)         // dark saddle wraps the back
        box(-13, 8, 21, 1, PetView.cBodyHi)         // warm topline highlight
        box(8, 13, 8, 1, PetView.cBodyHi)           // head highlight
        // Tan underside: belly along the bottom + chest under the neck.
        box(-14, 2, 23, 2, PetView.cTan)            // belly (bottom rows, long)
        box(6, 4, 5, 3, PetView.cTan)               // chest under the head
        box(16, 5, 6, 2, PetView.cTan)              // tan under the snout
        box(-14, 2, 23, 1, PetView.cTanShade)       // shadow at the very bottom edge
        for lx in [-13, -9, 5, 9] { box(lx, 0, 3, 1, PetView.cTan) }   // paws
        box(20, 5, 3, 3, PetView.cNose)             // nose at the snout tip
        if feat.eyes == .happy { box(15, 7, 2, 2, PetView.cCheek) }    // blush when delighted

        drawEye(feat.eyes, box: box, phase: phase)
        drawMouth(feat.mouth, box: box, phase: phase)
    }

    private func drawEye(_ e: EyeState, box: (Int, Int, Int, Int, NSColor) -> Void, phase: Double) {
        let blink = e == .open && fmod(phase, 3.4) < 0.12
        switch e {
        case .open, .worried:
            if blink { box(12, 10, 4, 1, PetView.cEye); return }
            box(12, 9, 4, 4, PetView.cOutline)          // eye rim
            box(12, 9, 3, 3, PetView.cEye)              // big round eye
            box(14, 11, 1, 1, .white); box(13, 12, 1, 1, .white)  // catchlight sparkle
            if e == .worried { box(11, 13, 4, 1, PetView.cOutline) }   // raised brow
        case .closed:
            box(12, 10, 4, 1, PetView.cEye)             // content lids
            box(11, 11, 1, 1, PetView.cEye); box(15, 11, 1, 1, PetView.cEye)
        case .happy:
            box(11, 10, 1, 1, PetView.cEye); box(12, 11, 1, 1, PetView.cEye)   // ^_^ arc
            box(14, 11, 1, 1, PetView.cEye); box(15, 10, 1, 1, PetView.cEye)
            box(13, 11, 1, 1, PetView.cEye)
        }
    }

    private func drawMouth(_ m: MouthState, box: (Int, Int, Int, Int, NSColor) -> Void, phase: Double) {
        switch m {
        case .neutral:
            box(18, 4, 2, 1, PetView.cNose)
        case .smile:
            box(17, 4, 1, 1, PetView.cNose); box(18, 3, 3, 1, PetView.cNose)
        case .pant, .open:
            box(18, 3, 3, 2, PetView.cNose)
            if m == .pant {
                let drop = Int((sin(phase * 8) * 0.5 + 0.5).rounded())
                box(18, 2 - drop, 2, 1 + drop, PetView.cTongue)
            }
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

    private func drawAccessory(_ a: Accessory, at c: CGPoint, phase: Double) {
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
            if Int(phase * 4) % 2 == 0 {                    // teeth N/S/E/W
                b(-0.5, 1.5, 1, 1, PetView.cGear); b(-0.5, -2.5, 1, 1, PetView.cGear)
                b(1.5, -0.5, 1, 1, PetView.cGear); b(-2.5, -0.5, 1, 1, PetView.cGear)
            } else {                                        // teeth on corners → spins
                b(1.5, 1.5, 1, 1, PetView.cGear); b(-2.5, 1.5, 1, 1, PetView.cGear)
                b(1.5, -2.5, 1, 1, PetView.cGear); b(-2.5, -2.5, 1, 1, PetView.cGear)
            }
        case .sparkle:
            let big: CGFloat = sin(phase * 6) > 0 ? 2 : 1.4
            b(-0.5, -big, 1, big * 2, PetView.cSpark)
            b(-big, -0.5, big * 2, 1, PetView.cSpark)
            b(1.8, 1.3, 0.8, 1.6, PetView.cSpark)           // small companion
            b(1.4, 1.7, 1.6, 0.8, PetView.cSpark)
        case .sweat:
            let d = CGFloat(sin(phase * 5)) * 0.3
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
            let r = CGFloat(sin(phase * 2)) * 0.4
            b(-1.6, 1.4 + r, 3, 0.8, PetView.cZ)            // big Z
            b(0.2, 0.4 + r, 0.9, 0.9, PetView.cZ)
            b(-0.7, -0.4 + r, 0.9, 0.9, PetView.cZ)
            b(-1.6, -1.2 + r, 3, 0.8, PetView.cZ)
            b(1.7, 2.5 + r, 1.6, 0.6, PetView.cZ)           // small z
            b(2.0, 1.9 + r, 0.6, 0.6, PetView.cZ)
            b(1.7, 1.4 + r, 1.6, 0.6, PetView.cZ)
        case .wave:
            let dx = CGFloat(sin(phase * 7)) * 0.4          // waving paw
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

        let winSize = CGSize(width: 200, height: 170)
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
        window.isMovableByWindowBackground = true
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

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in view.tick() }
        RunLoop.main.add(timer, forMode: .common)

        app.run()
    }
}
