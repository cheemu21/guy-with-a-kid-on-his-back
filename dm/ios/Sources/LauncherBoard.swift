// The launcher's look (Launcher.swift LauncherView): a picture behind everything (dm/launcher_bg.jpg when the app has one), the game's name at the top left, a board of six setting
// nodes on the left (each tap changes its setting; the readout at the right says what it does), Play as a diamond at the bottom right, and All settings: every launcher setting as a card.
// Laid out on an 874 x 402 point canvas (an iPhone Pro in landscape) scaled to the screen; the picture and All settings fill the whole screen.
import SwiftUI
import UIKit

enum Board {
    static let size = CGSize(width: 874, height: 402)
    static let mint = Color(red: 127 / 255, green: 245 / 255, blue: 210 / 255)
    static let white = Color(red: 242 / 255, green: 248 / 255, blue: 1)
    static let ink = Color(red: 4 / 255, green: 7 / 255, blue: 12 / 255)
    static let panel = Color(red: 4 / 255, green: 10 / 255, blue: 16 / 255)
    static let dim = Color(red: 169 / 255, green: 188 / 255, blue: 207 / 255)
    static let amber = Color(red: 1, green: 0.78, blue: 0.42)
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.condensed) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

/// A rectangle with its top-left and bottom-right corners cut off (the board's panels and cards)
struct Chamfer: Shape {
    var cut: CGFloat = 10
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + cut, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cut)); p.addLine(to: CGPoint(x: r.maxX - cut, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut)); p.closeSubpath()
        }
    }
}

/// A faint 20-point grid (the board panel, All settings)
struct BoardGrid: View {
    var opacity = 0.08
    var body: some View {
        Canvas { c, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 20).forEach { x in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
            stride(from: 0, through: size.height, by: 20).forEach { y in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
            c.stroke(p, with: .color(Board.mint.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The picture behind the launcher: dm/launcher_bg.jpg (build_ipa.sh copies the profile's), shaded at the sides where the board and the readout sit; a dark gradient without one
struct LauncherBackdrop: View {
    static let picture: UIImage? = {
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        guard let url = dir?.appendingPathComponent("launcher_bg.jpg") else { return nil }
        return UIImage(contentsOfFile: url.path) ?? Bundle.main.resourceURL.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent("dm/launcher_bg.jpg").path) }
    }()

    var body: some View {
        GeometryReader { g in
            ZStack {
                Board.ink
                if let p = Self.picture {
                    Image(uiImage: p).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height, alignment: .top).clipped()
                        .accessibilityLabel("The Earth rising over the lunar surface")
                } else {
                    LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.15), Board.ink], startPoint: .top, endPoint: .bottom)
                }
                let shade = Color(red: 2 / 255, green: 5 / 255, blue: 9 / 255)
                LinearGradient(stops: [.init(color: shade.opacity(0.92), location: 0), .init(color: shade.opacity(0.78), location: 0.26),
                                       .init(color: shade.opacity(0.12), location: 0.46), .init(color: shade.opacity(0), location: 0.58),
                                       .init(color: shade.opacity(0.35), location: 0.70), .init(color: shade.opacity(0.88), location: 0.88)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [shade.opacity(0.35), .clear], startPoint: .bottom, endPoint: .center)
            }
        }
        .ignoresSafeArea()
    }
}

/// One of the board's nodes: a launcher setting (env), or the touch layout (env nil)
struct BoardNode: Identifiable {
    let id: String, env: String?, title: String, code: String, icon: String, fallbackNote: String
    static let all: [BoardNode] = [
        BoardNode(id: "fps", env: "DM_FPS_TARGET", title: "Frame Rate", code: "FR-01", icon: "speedometer", fallbackNote: "30 is steady in play; 60 can drop frames when the GPU is busy."),
        BoardNode(id: "fg", env: "DM_FRAMEGEN", title: "Frame Gen", code: "FG-02", icon: "waveform.path", fallbackNote: "60 frames shown while the game draws 30."),
        BoardNode(id: "mode", env: "DM_OPMODE", title: "Console", code: "CM-03", icon: "tv", fallbackNote: "Handheld: lower 3D resolution, less GPU work. Docked is sharper and heavier."),
        BoardNode(id: "saver", env: "DM_NVN_TEX_MIP_SKIP", title: "Tex Saver", code: "TX-04", icon: "checkmark.shield", fallbackNote: "Large textures leave out their finest levels: far less memory."),
        BoardNode(id: "hud", env: "DM_METAL_HUD", title: "Perf HUD", code: "HD-05", icon: "chart.xyaxis.line", fallbackNote: "Frame rate, GPU time and memory over the game."),
        BoardNode(id: "pad", env: nil, title: "Controls", code: "CT-06", icon: "gamecontroller", fallbackNote: ""),
    ]
}

extension LauncherModel {
    func setting(_ env: String?) -> Setting? { env.flatMap { e in settings.first { $0.env == e } } }
    func locked(_ s: Setting) -> Bool { fixed.contains(s.env) }
    func lockNote(_ s: Setting) -> String { fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file" }

    /// A setting's value as the board shows it: ON / OFF, a choice's label, a range's percentage; NEEDS <value> while the setting it needs has another value
    func shown(_ s: Setting) -> String {
        if !visible(s), let n = s.needs, let eq = n.firstIndex(of: "=") {
            let key = String(n[..<eq]), want = String(n[n.index(after: eq)...])
            let label = setting(key)?.options?.first { $0[0] == want }?[1] ?? want
            return "NEEDS " + label.uppercased()
        }
        let v = values[s.env] ?? s.def
        switch s.kind {
        case "toggle": return v == s.onValue ? "ON" : "OFF"
        case "choice": return (s.options?.first { $0[0] == v }?[1] ?? v).uppercased()
        case "range": return rangeLabel(s, Double(v) ?? 1)
        default: return v
        }
    }
    /// Lit on the board: a toggle that is on (and can act), any choice or range
    func lit(_ s: Setting) -> Bool { s.kind != "toggle" ? visible(s) : visible(s) && (values[s.env] ?? s.def) == s.onValue }

    /// A node's tap: a toggle flips, a choice steps to its next offered option, a range steps by a tenth and wraps
    func step(_ s: Setting) {
        guard !locked(s), visible(s) else { return }
        let v = values[s.env] ?? s.def
        switch s.kind {
        case "toggle": values[s.env] = v == s.onValue ? s.offValue : s.onValue
        case "choice":
            let opts = offeredOptions(s, current: v).map { $0[0] }
            guard !opts.isEmpty else { return }
            values[s.env] = opts[((opts.firstIndex(of: v) ?? -1) + 1) % opts.count]
        case "range":
            let lo = s.min ?? 0, hi = s.max ?? 1, n = (Double(v) ?? hi) + 0.1
            values[s.env] = String(format: "%.2f", n > hi + 1e-6 ? lo : n)
        default: break
        }
    }
}

/// The touch layout, as the gamepad saves it (DmGamepad.m DmPadLayout): 0 and 1 (with the D-pad), 2 Tap (handheld mode only)
enum PadLayout {
    static func names() -> [String] { dm_touch_style() == 1 ? ["Orbit", "Orbit + D-pad", "Tap"] : ["2D", "3D", "Tap"] }
    static func current(handheld: Bool) -> Int { let l = Int(dm_pad_layout_saved()); return l == 2 && !handheld ? 0 : max(0, min(l, 2)) }
    static func next(handheld: Bool) -> Int { (current(handheld: handheld) + 1) % (handheld ? 3 : 2) }
    static let note = "Orbit; Orbit + D-pad adds the large D-pad; Tap sends touches to the game (handheld mode only)."
}

/// A node's look: a white core in a mint ring when lit, dark with a dim ring when not; the selected one has the thicker ring
struct NodeView: View {
    let title: String, value: String, icon: String, lit: Bool, selected: Bool, locked: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 2) {
                ZStack {
                    if lit {
                        Circle().fill(Board.mint.opacity(selected ? 1 : 0.7)).frame(width: 50 + (selected ? 9 : 6), height: 50 + (selected ? 9 : 6))
                            .shadow(color: Board.mint.opacity(0.4), radius: 10)
                        Circle().fill(Board.ink).frame(width: 50, height: 50)
                        Circle().fill(Board.white).frame(width: 46, height: 46)
                    } else {
                        if selected { Circle().fill(Board.white.opacity(0.6)).frame(width: 56, height: 56); Circle().fill(Board.ink).frame(width: 50, height: 50) }
                        Circle().fill(Color(red: 10 / 255, green: 20 / 255, blue: 31 / 255)).frame(width: 46, height: 46)
                            .overlay(Circle().strokeBorder(Board.white.opacity(0.35), lineWidth: 1.5))
                    }
                    Image(systemName: locked ? "lock.fill" : icon).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(lit ? Color(red: 6 / 255, green: 16 / 255, blue: 25 / 255) : Color(red: 159 / 255, green: 178 / 255, blue: 198 / 255))
                }
                .frame(width: 66, height: 66).padding(.vertical, -10)
                Text(title.uppercased()).font(Board.title(12)).tracking(0.6).foregroundStyle(Board.white).lineLimit(1).fixedSize()
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                Text(value).font(Board.mono(9)).foregroundStyle(lit ? Board.mint : Color(red: 159 / 255, green: 178 / 255, blue: 198 / 255)).lineLimit(1).fixedSize()
            }
            .frame(width: 100).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// Play: a white diamond in a glowing mint one
struct PlayDiamond: View {
    let busy: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            ZStack {
                Rectangle().fill(Board.panel.opacity(0.35)).overlay(Rectangle().strokeBorder(Board.mint, lineWidth: 2))
                    .frame(width: 96, height: 96).rotationEffect(.degrees(45)).shadow(color: Board.mint.opacity(0.5), radius: 15)
                Rectangle().fill(busy ? Board.white.opacity(0.5) : Board.white).frame(width: 68, height: 68).rotationEffect(.degrees(45))
                if busy { ProgressView().tint(Board.ink) } else {
                    Image(systemName: "play.fill").font(.system(size: 28)).foregroundStyle(Color(red: 6 / 255, green: 16 / 255, blue: 25 / 255)).offset(x: 2)
                }
            }
            .frame(width: 112, height: 112).contentShape(Rectangle().rotation(.degrees(45)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(busy ? "Checking the cloud save" : "Play")
    }
}

/// One setting in All settings: a toggle flips on a tap, a choice opens its options, a range has its slider; one an env file set is shown, not changed
struct SettingCard: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.locked(s) }
    private var note: String {
        let n = s.note
        guard locked else { return n }
        return (n.isEmpty ? "" : n + " · ") + m.lockNote(s)
    }
    private var on: Bool { m.lit(s) }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Menu {
                    Picker(s.label, selection: m.binding(s)) {
                        ForEach(offeredOptions(s, current: m.values[s.env]), id: \.[0]) { Text($0[1]).tag($0[0]) }
                    }
                } label: { face(slider: false) }
            case "range": face(slider: true)
            default: Button { m.step(s) } label: { face(slider: false) }
            }
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.6 : 1)
        .accessibilityLabel("\(s.label): \(m.shown(s))")
    }

    @ViewBuilder private func face(slider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("// " + s.sectionTitle.uppercased()).font(Board.mono(9)).tracking(1).foregroundStyle(Color(red: 143 / 255, green: 166 / 255, blue: 189 / 255))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Board.white).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Pill(text: m.shown(s), on: on)
            }
            if slider {
                Slider(value: Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 }, set: { m.values[s.env] = String(format: "%.2f", $0) }),
                       in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05).tint(Board.mint)
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 10.5)).foregroundStyle(Board.dim).lineSpacing(1).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Chamfer().fill(on ? Board.mint.opacity(0.09) : Board.white.opacity(0.05)))
        .overlay(Chamfer().stroke(on ? Board.mint.opacity(0.4) : Board.white.opacity(0.14), lineWidth: 1))
        .contentShape(Chamfer())
    }
}

/// A card for something that is not a launcher setting (the touch layout, Reset, cloud saves, memory)
struct ActionCard: View {
    let group: String, title: String, note: String, value: String, on: Bool
    var disabled = false
    let tap: (() -> Void)?

    var body: some View {
        let face = VStack(alignment: .leading, spacing: 6) {
            Text("// " + group).font(Board.mono(9)).tracking(1).foregroundStyle(Color(red: 143 / 255, green: 166 / 255, blue: 189 / 255))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Board.white)
                Spacer(minLength: 4)
                if !value.isEmpty { Pill(text: value, on: on) }
            }
            if !note.isEmpty { Text(note).font(.system(size: 10.5)).foregroundStyle(Board.dim).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Chamfer().fill(on ? Board.mint.opacity(0.09) : Board.white.opacity(0.05)))
        .overlay(Chamfer().stroke(on ? Board.mint.opacity(0.4) : Board.white.opacity(0.14), lineWidth: 1))
        .contentShape(Chamfer())
        if let tap { Button(action: tap) { face }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.5 : 1) } else { face }
    }
}

struct Pill: View {
    let text: String, on: Bool
    var body: some View {
        Text(text).font(Board.mono(10)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(on ? Color(red: 3 / 255, green: 16 / 255, blue: 21 / 255) : Color(red: 207 / 255, green: 219 / 255, blue: 235 / 255))
            .background(on ? AnyShapeStyle(Board.mint) : AnyShapeStyle(Color.clear), ignoresSafeAreaEdges: [])
            .overlay(Rectangle().strokeBorder(on ? Color.clear : Board.white.opacity(0.35), lineWidth: 1))
    }
}
