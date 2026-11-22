// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. The screen is a board of six nodes and All settings, every setting as a card (LauncherBoard.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?
    @State private var selected = "saver"   // the node the readout describes
    @State private var allOpen = false
    @State private var cloudOpen = false
    @State private var padSaved = Int(dm_pad_layout_saved())   // the touch layout the next start takes (DmGamepad.m)

    private static let cols: [CGFloat] = [122, 234], rowsY: [CGFloat] = [122, 210, 298]   // the nodes' centres on the board, two columns of three
    private var nodes: [BoardNode] { BoardNode.all.filter { $0.env == nil || m.setting($0.env) != nil } }
    private var handheld: Bool { (m.values["DM_OPMODE"] ?? "1") == "0" }
    private var padNow: Int { padSaved == 2 && !handheld ? 0 : max(0, min(padSaved, 2)) }
    private var gameName: String { ((info("CFBundleDisplayName") as? String) ?? "Game").uppercased() }

    var body: some View {
        GeometryReader { g in
            let k = min(g.size.width / Board.size.width, g.size.height / Board.size.height)
            ZStack {
                LauncherBackdrop()
                board.frame(width: Board.size.width, height: Board.size.height).scaleEffect(k).frame(width: g.size.width, height: g.size.height)
                if allOpen { allSettings.transition(.opacity) }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(.easeOut(duration: 0.18), value: allOpen)
        .sheet(isPresented: $cloudOpen) {
            NavigationStack {
                List { CloudSavesSection() }
                    .navigationTitle("Cloud saves").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { cloudOpen = false } } }
            }
            .preferredColorScheme(.dark)
        }
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This iPhone's Save") { go("offline") }   // the mount does not wait for the cloud again
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone")) }
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // ---- The board (874 x 402 points, scaled to the screen) ----
    private var board: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            VStack(alignment: .leading, spacing: 4) {
                Text(gameName).font(Board.title(38)).tracking(12).foregroundStyle(Color(red: 246 / 255, green: 251 / 255, blue: 1))
                    .shadow(color: .black.opacity(0.7), radius: 7, y: 2).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    Rectangle().fill(Board.mint).frame(width: 5, height: 5).rotationEffect(.degrees(45))
                    Rectangle().fill(LinearGradient(colors: [Board.mint.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)).frame(width: 150, height: 1)
                }
                .accessibilityHidden(true)
            }
            .frame(width: 520, alignment: .leading)
            .offset(x: 62, y: 12)

            chips.frame(width: Board.size.width - 124, height: 30, alignment: .trailing).offset(x: 62, y: 12)

            ZStack(alignment: .topLeading) {
                Chamfer().fill(Board.panel.opacity(0.62))
                BoardGrid().clipShape(Chamfer())
                Chamfer().stroke(Board.mint.opacity(0.25), lineWidth: 1)
                Text("// ROUTE CONFIG").font(Board.mono(9)).tracking(1.5).foregroundStyle(Board.mint).offset(x: 12, y: 8)
            }
            .frame(width: 230, height: 300).offset(x: 62, y: 70)

            ForEach(Array(nodes.prefix(6).enumerated()), id: \.element.id) { i, n in
                node(n).offset(x: Self.cols[i % 2] - 50, y: Self.rowsY[i / 2] - 23)
            }

            readout.frame(width: Board.size.width - 62 - 650, height: 124).offset(x: 650, y: 66)

            Text(checking ? "SYNCING" : "PLAY").font(Board.title(18)).tracking(6).foregroundStyle(Board.white)
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                .frame(width: 140).offset(x: 672, y: 218).accessibilityHidden(true)
            PlayDiamond(busy: checking, tap: start).offset(x: 686, y: 262)
            if checking {
                Button { checking = false; go("offline") } label: {
                    Text("PLAY WITHOUT IT").font(Board.mono(10, .bold)).tracking(1).foregroundStyle(Board.white)
                        .padding(.horizontal, 10).frame(height: 30).background(Board.panel.opacity(0.55), ignoresSafeAreaEdges: [])
                        .overlay(Rectangle().strokeBorder(Board.white.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain).offset(x: 530, y: 303)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 10) {
            Text("● LINK").foregroundStyle(Board.mint)
            if let s = m.setting("DM_OPMODE") { Text(m.shown(s)) }
            if let s = m.setting("DM_FPS_TARGET") {
                let fg = m.setting("DM_FRAMEGEN").map { m.lit($0) } ?? false
                Text(m.shown(s) + (fg ? " → 60" : ""))
            }
            if memory > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory).uppercased() + " FREE")
                    .monospacedDigit().foregroundStyle(memory > 3 << 30 ? Board.dim : Board.amber)
            }
            Button { allOpen = true } label: {
                Text("ALL SETTINGS").font(Board.mono(10, .bold)).tracking(1).foregroundStyle(Color(red: 232 / 255, green: 241 / 255, blue: 250 / 255))
                    .padding(.horizontal, 12).frame(height: 30).background(Board.panel.opacity(0.55), ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().strokeBorder(Board.white.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .font(Board.mono(10)).foregroundStyle(Board.dim).lineLimit(1)
    }

    @ViewBuilder private func node(_ n: BoardNode) -> some View {
        if let s = m.setting(n.env) {
            NodeView(title: n.title, value: m.shown(s), icon: n.icon, lit: m.lit(s), selected: selected == n.id, locked: m.locked(s)) {
                m.step(s); selected = n.id; tick()
            }
        } else {
            NodeView(title: n.title, value: PadLayout.names()[padNow].uppercased(), icon: n.icon, lit: true, selected: selected == n.id, locked: false) {
                let l = PadLayout.next(handheld: handheld); dm_pad_layout_store(Int32(l)); padSaved = l; selected = n.id; tick()
            }
        }
    }

    private func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    private var readout: some View {
        let n = nodes.first { $0.id == selected } ?? nodes.first
        let s = m.setting(n?.env)
        let value = s.map { m.shown($0) } ?? PadLayout.names()[padNow].uppercased()
        var note = s == nil ? PadLayout.note : (n?.fallbackNote.isEmpty == false ? n!.fallbackNote : s!.note)
        if let s, m.locked(s) { note += " · " + m.lockNote(s) }
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Board.mint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("// NODE · \(n?.code ?? "")").font(Board.mono(9)).tracking(1.5).foregroundStyle(Board.mint)
                Text("\((n?.title ?? "").uppercased()) — \(value)").font(Board.title(14)).tracking(0.8).foregroundStyle(Board.white).lineLimit(2).minimumScaleFactor(0.8)
                Text(note).font(.system(size: 10.5)).foregroundStyle(Color(red: 195 / 255, green: 210 / 255, blue: 224 / 255)).lineSpacing(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Chamfer().fill(Board.panel.opacity(0.78)))
        .overlay(Chamfer().stroke(Board.white.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // ---- All settings: every launcher setting as a card, with the touch layout, Reset, cloud saves and the memory ----
    private var allSettings: some View {
        ZStack(alignment: .top) {
            Color(red: 4 / 255, green: 9 / 255, blue: 15 / 255).opacity(0.94).ignoresSafeArea()
            BoardGrid(opacity: 0.05).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("// SYSTEM CONFIG").font(Board.mono(10)).foregroundStyle(Board.mint)
                        Text("ALL SETTINGS").font(Board.title(22)).tracking(3).foregroundStyle(Board.white)
                    }
                    Spacer()
                    Button { allOpen = false } label: {
                        Text("DONE").font(Board.mono(10, .bold)).tracking(1).foregroundStyle(Color(red: 3 / 255, green: 16 / 255, blue: 21 / 255))
                            .padding(.horizontal, 16).frame(height: 34).background(Board.mint, ignoresSafeAreaEdges: [])
                    }
                    .buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 20, leading: 62, bottom: 10, trailing: 62))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 10) {
                        ForEach(m.sections, id: \.self) { section in
                            ForEach(m.rows(in: section)) { SettingCard(s: $0, m: m) }
                        }
                        ActionCard(group: "CONTROLS", title: "Touch layout", note: PadLayout.note, value: PadLayout.names()[padNow].uppercased(), on: true) {
                            let l = PadLayout.next(handheld: handheld); dm_pad_layout_store(Int32(l)); padSaved = l
                        }
                        ActionCard(group: "SAVES", title: "Cloud saves", note: "An iCloud Drive folder shared with the Mac app.", value: cloudFolder(), on: !cloudFolder().isEmpty) { cloudOpen = true }
                        ActionCard(group: "SYSTEM", title: "Memory available", note: "What iOS lets the game use now.",
                                   value: ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory), on: false, tap: nil)
                        ActionCard(group: "SYSTEM", title: "Reset to tested defaults", note: "Brings back all settings this game was tested with.", value: "", on: false,
                                   disabled: !m.changed) { m.reset() }
                    }
                    .padding(EdgeInsets(top: 4, leading: 62, bottom: 20, trailing: 62))
                }
            }
        }
    }

    private func cloudFolder() -> String {
        var stale: ObjCBool = false
        return (dm_cloud_saves_path(&stale) ?? "").split(separator: "/").last.map(String.init) ?? ""
    }
    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }

    /// Play, once the cloud's save is compared with this iPhone's (save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick, not the
    /// newer file's, and a cloud save that did not come is said so before the game starts without it.
    private func start() {
        check += 1; checking = true; asking = nil
        let mine = check
        dm_cloud_saves_env()   // DM_SAVE_SYNC from the picked folder, as the game's mount will read it (front_ios.m calls it again at the start)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice): go(choice)
                case let step: report = r; asking = step
                }
            }
        }
    }

    /// Blocks while the cloud's file downloads (SaveSyncReport.waitMs at most). nil: no report (the host then decides as it always did)
    private static func compare() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: main.m sets DM_SAVE and applies env.txt after that snapshot
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard save_sync_report(save, dm_save_title(), nil, SaveSyncReport.waitMs, &buf, buf.count) == 0 else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr)
            return nil
        }
        let line = String(cString: buf)
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    private func go(_ choice: String?) {
        asking = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }

}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(file.settings)
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
