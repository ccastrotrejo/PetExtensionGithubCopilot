// Copilot Pet — native macOS desktop companion overlay.
// Usage: pet <path-to-state.json>
// Reads a JSON state file and renders a pixel-art dachshund that reacts to Copilot activity.
// The pet is static and can be dragged around the desktop; its position persists.
//
// state.json: { "mood": String, "message": String, "seq": Int, "heartbeat": Double(ms) }

import Cocoa

// MARK: - Mood (typed vocabulary)
// Mirrors the MOODS manifest in extension.mjs and docs/state-protocol.md.
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
    var accessory: String? = nil
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
            p.accessory = "💤"
        case .greet:
            p.bob = abs(sin(phase * 8)) * 10
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 11)
            p.accessory = "👋"; p.bubble = "hi!"
        case .thinking:
            p.rot = sin(phase * 3) * 0.06
            p.feat = DogFeatures(eyes: .open, mouth: .neutral, wag: 1)
            p.accessory = "💭"; p.bubble = message.isEmpty ? "thinking…" : message
        case .working:
            p.bob = abs(sin(phase * 12)) * 6
            p.feat = DogFeatures(eyes: .open, mouth: .pant, wag: 5)
            p.accessory = "⚙️"; p.bubble = message.isEmpty ? "working…" : message
        case .happy:
            p.bob = abs(sin(phase * 10)) * 16
            p.feat = DogFeatures(eyes: .happy, mouth: .smile, wag: 13)
            p.accessory = "✨"; p.bubble = message.isEmpty ? "done!" : message
        case .worried:
            p.shakeX = sin(phase * 30) * 4
            p.feat = DogFeatures(eyes: .worried, mouth: .open, wag: 0, tailDown: true)
            p.accessory = "💦"; p.bubble = message.isEmpty ? "uh oh" : message
        }
        return p
    }
}

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

        // Ground shadow
        let shadowW = petSize * 1.05 * (1 - pose.bob / 220)
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.16).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - shadowW / 2, y: groundY - 8, width: shadowW, height: 9))
        ctx.restoreGState()

        // Pet body
        ctx.saveGState()
        ctx.translateBy(x: cx + pose.shakeX, y: cy)
        if pose.rot != 0 { ctx.rotate(by: pose.rot) }
        ctx.scaleBy(x: 1, y: pose.scaleY)
        drawDachshundPixel(size: petSize, feat: pose.feat, phase: phase)
        ctx.restoreGState()

        // Accessory (near head)
        if let acc = pose.accessory {
            let accBob = sin(phase * 4) * 3
            drawEmoji(acc, size: 24, centeredAt: CGPoint(x: cx + petSize * 0.36,
                                                         y: cy + petSize * 0.30 + accBob))
        }

        // Speech bubble
        if let text = pose.bubble, !text.isEmpty {
            drawBubble(text, petCenterX: cx, baseY: cy + petSize * 0.55 + 12, maxWidth: W)
        }
    }

    // MARK: Pixel-art dachshund

    private static let cOutline = NSColor(red: 0.20, green: 0.12, blue: 0.07, alpha: 1)
    private static let cBody    = NSColor(red: 0.63, green: 0.36, blue: 0.17, alpha: 1)
    private static let cShade   = NSColor(red: 0.50, green: 0.27, blue: 0.12, alpha: 1)
    private static let cDark    = NSColor(red: 0.40, green: 0.22, blue: 0.10, alpha: 1)
    private static let cTan     = NSColor(red: 0.87, green: 0.66, blue: 0.44, alpha: 1)
    private static let cNose    = NSColor(red: 0.14, green: 0.10, blue: 0.08, alpha: 1)
    private static let cEye     = NSColor(red: 0.12, green: 0.09, blue: 0.08, alpha: 1)
    private static let cTongue  = NSColor(red: 0.90, green: 0.42, blue: 0.45, alpha: 1)

    /// Draws a blocky, grid-aligned dachshund centred at the origin, facing right.
    /// Coordinates are in whole cells; y counts up from the feet.
    private func drawDachshundPixel(size s: CGFloat, feat: DogFeatures, phase: Double) {
        let cell = max(3, (s / 20).rounded())
        let footY = -0.44 * s

        func box(_ cx: Int, _ cy: Int, _ w: Int, _ h: Int, _ color: NSColor) {
            color.setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(cx) * cell, y: footY + CGFloat(cy) * cell,
                                      width: CGFloat(w) * cell, height: CGFloat(h) * cell)).fill()
        }

        // --- Tail (wags, or tucks when worried) ---
        let wo = feat.wag > 0 ? Int((sin(phase * feat.wag) * 1.4).rounded()) : 0
        if feat.tailDown {
            box(-10, 3, 1, 2, PetView.cDark)
            box(-11, 2, 1, 2, PetView.cDark)
        } else {
            box(-10, 6, 1, 2, PetView.cDark)
            box(-11 + wo, 8, 1, 2, PetView.cDark)
        }

        // --- Legs (static) ---
        for lx in [-7, -4, 2, 5] {
            box(lx, 0, 2, 4, PetView.cBody)
            box(lx, 0, 2, 1, PetView.cTan)      // paw
        }

        // --- Body ---
        box(-9, 3, 15, 5, PetView.cBody)
        box(-9, 3, 15, 1, PetView.cShade)       // underside shading
        box(-6, 4, 10, 2, PetView.cTan)         // belly

        // --- Head ---
        box(3, 4, 7, 6, PetView.cBody)
        box(3, 4, 7, 1, PetView.cShade)

        // --- Ear (long & droopy, hangs down the cheek) ---
        box(4, 2, 2, 7, PetView.cDark)

        // --- Muzzle + nose ---
        box(9, 5, 3, 2, PetView.cTan)
        box(11, 5, 1, 2, PetView.cNose)

        // --- Eye ---
        drawEye(feat.eyes, box: box)
        // --- Mouth ---
        drawMouth(feat.mouth, box: box, phase: phase)
    }

    private func drawEye(_ e: EyeState, box: (Int, Int, Int, Int, NSColor) -> Void) {
        switch e {
        case .open:
            box(6, 7, 2, 2, PetView.cEye)
            box(7, 8, 1, 1, .white)
        case .worried:
            box(6, 7, 2, 2, PetView.cEye)
            box(6, 8, 1, 1, .white)
            box(5, 9, 3, 1, PetView.cShade)     // raised brow
        case .closed:
            box(6, 7, 3, 1, PetView.cEye)       // gentle line
        case .happy:
            box(5, 7, 1, 1, PetView.cEye)       // ^ arc
            box(6, 8, 1, 1, PetView.cEye)
            box(7, 7, 1, 1, PetView.cEye)
        }
    }

    private func drawMouth(_ m: MouthState, box: (Int, Int, Int, Int, NSColor) -> Void, phase: Double) {
        switch m {
        case .neutral:
            box(9, 4, 2, 1, PetView.cNose)
        case .smile:
            box(9, 4, 1, 1, PetView.cNose)
            box(10, 3, 2, 1, PetView.cNose)
        case .pant, .open:
            box(10, 3, 2, 2, PetView.cNose)
            if m == .pant {
                let drop = Int((sin(phase * 8) * 0.5 + 0.5).rounded())
                box(10, 2 - drop, 1, 1 + drop, PetView.cTongue)
            }
        }
    }

    private func drawEmoji(_ s: String, size: CGFloat, centeredAt p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
        let ns = s as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: attrs)
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

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: pet <state.json>\n".data(using: .utf8)!)
    exit(2)
}
let statePath = CommandLine.arguments[1]
let posPath = (statePath as NSString).deletingLastPathComponent + "/pet.pos"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let state = PetState(statePath: statePath)

let winSize = CGSize(width: 200, height: 170)
var origin = CGPoint(x: 200, y: 200)
if let screen = NSScreen.main {
    let vf = screen.visibleFrame
    origin = CGPoint(x: vf.maxX - winSize.width - 40, y: vf.minY + 60)
}
if let saved = readPos(posPath) { origin = saved }

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

NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
    writePos(window.frame.origin, posPath)
}

let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in view.tick() }
RunLoop.main.add(timer, forMode: .common)

app.run()
