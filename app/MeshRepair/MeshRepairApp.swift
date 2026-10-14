// Mesh Repair: a small native window around meshrepair.py.
// Drop model files on the window or the app icon; a progress ring shows the
// repair, then a report lists what was fixed. Built by app/build.sh.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

let supportedExtensions = ["stl", "3mf", "obj", "ply", "off", "glb"]

// MARK: - Engine events (JSON lines from `meshrepair.py --progress`)

struct MeshStats: Decodable, Equatable {
    var faces: Int
    var non_manifold_edges: Int
    var open_edges: Int
    var bodies: Int
}

struct EngineEvent: Decodable {
    var event: String
    var file: String
    var value: Double?
    var stage: String?
    var output: String?
    var ok: Bool?
    var message: String?
    var before: MeshStats?
    var after: MeshStats?
}

struct FileResult: Identifiable {
    let id = UUID()
    let input: URL
    var output: URL?
    var ok = false
    var error: String?
    var before: MeshStats?
    var after: MeshStats?
}

// MARK: - Model

@MainActor @Observable
final class RepairModel {
    enum Phase { case idle, running, finished }

    var phase = Phase.idle
    var progress = 0.0
    var started = false          // first progress event received (Python is loaded)
    var stage = ""
    var currentFile = ""
    var fileIndex = 0
    var fileCount = 0
    var results: [FileResult] = []
    var engineError: String?

    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false

    func enqueue(_ urls: [URL]) {
        let files = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { NSSound.beep(); return }
        queue.append(contentsOf: files)
        if phase != .running { runNextBatch(keepResults: false) }
    }

    func cancel() {
        cancelled = true
        queue.removeAll()
        process?.terminate()
    }

    func reset() {
        phase = .idle
        results = []
        engineError = nil
    }

    /// The engine bundled inside the app (PKG build), else the clone set up by install.sh.
    private func engine() -> (python: String, script: String)? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine") {
            let python = res.appendingPathComponent("python/bin/python3").path
            let script = res.appendingPathComponent("meshrepair.py").path
            if fm.isExecutableFile(atPath: python), fm.fileExists(atPath: script) { return (python, script) }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let python = info["MRPython"] as? String, let script = info["MRScript"] as? String,
              fm.isExecutableFile(atPath: python), fm.fileExists(atPath: script) else { return nil }
        return (python, script)
    }

    private func runNextBatch(keepResults: Bool) {
        let batch = queue
        queue.removeAll()
        guard !batch.isEmpty else { return }
        guard let engine = engine() else {
            engineError = "The repair engine was not found. Run install.sh again from the MeshRepair folder."
            phase = .finished
            return
        }

        if !keepResults { results = [] }
        phase = .running
        progress = 0
        started = false
        stage = "Starting…"
        fileIndex = 1
        fileCount = batch.count
        currentFile = batch[0].lastPathComponent
        cancelled = false

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: engine.python)
        proc.arguments = [engine.script, "--progress"] + batch.map(\.path)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONWARNINGS"] = "ignore"
        env["PYTHONNOUSERSITE"] = "1"         // ignore packages from the user's own Python
        env["PYTHONDONTWRITEBYTECODE"] = "1"  // never write inside the (signed) app bundle
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            engineError = "Could not start the repair engine: \(error.localizedDescription)"
            phase = .finished
            return
        }
        process = proc
        updateDock()

        // drain stderr in the background so a chatty engine never blocks on a full pipe
        let errHandle = err.fileHandleForReading
        let stderrTask = Task.detached { errHandle.readDataToEndOfFile() }

        Task {
            var seen = Set<String>()
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let ev = try? JSONDecoder().decode(EngineEvent.self, from: data) else { continue }
                    seen.insert(ev.file)
                    handle(ev, batch: batch)
                }
            } catch {}
            proc.waitUntilExit()
            let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
            finishBatch(batch: batch, seen: seen, stderr: stderr)
        }
    }

    private func handle(_ ev: EngineEvent, batch: [URL]) {
        let url = URL(fileURLWithPath: ev.file)
        switch ev.event {
        case "progress":
            started = true
            progress = max(progress, ev.value ?? 0)
            stage = ev.stage ?? ""
            currentFile = url.lastPathComponent
            fileIndex = (batch.firstIndex { $0.path == ev.file } ?? 0) + 1
            updateDock()
        case "result":
            results.append(FileResult(input: url, output: ev.output.map { URL(fileURLWithPath: $0) },
                                      ok: ev.ok ?? false, before: ev.before, after: ev.after))
        case "error":
            results.append(FileResult(input: url, error: ev.message ?? "Unknown error"))
        default:
            break
        }
    }

    private func finishBatch(batch: [URL], seen: Set<String>, stderr: String) {
        process = nil
        if cancelled {
            results.append(contentsOf: batch.filter { f in !results.contains { $0.input.path == f.path } }
                .map { FileResult(input: $0, error: "Cancelled") })
        } else if let crashed = batch.first(where: { f in !results.contains { $0.input.path == f.path } }) {
            // the engine died without reporting this file
            let detail = stderr.split(separator: "\n").last.map(String.init) ?? "the engine stopped unexpectedly"
            results.append(FileResult(input: crashed, error: detail))
        }
        progress = 1
        if !queue.isEmpty {
            runNextBatch(keepResults: true)
            return
        }
        phase = .finished
        updateDock()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        NSSound(named: results.allSatisfy(\.ok) ? "Glass" : "Basso")?.play()
    }

    private func updateDock() {
        NSApp.dockTile.badgeLabel = phase == .running ? "\(Int(progress * 100))%" : nil
    }
}

// MARK: - Views

struct ContentView: View {
    @Bindable var model: RepairModel
    @State private var targeted = false

    var body: some View {
        ZStack {
            switch model.phase {
            case .idle: IdleView(model: model, targeted: targeted)
            case .running: RunningView(model: model)
            case .finished: ReportView(model: model)
            }
        }
        .frame(width: 440, height: 400)
        .animation(.smooth(duration: 0.3), value: model.phase)
        .dropDestination(for: URL.self) { urls, _ in
            model.enqueue(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct IdleView: View {
    let model: RepairModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: targeted)
            VStack(spacing: 6) {
                Text("Drop 3D models here").font(.title2.weight(.semibold))
                Text("STL, 3MF, OBJ or PLY · repaired copies are saved next to the originals")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Choose Files…") { chooseFiles(model) }
                .controlSize(.large)
                .keyboardShortcut("o")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: 18)
                    .fill(Color.accentColor.opacity(targeted ? 0.08 : 0)))
                .padding(16)
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    let started: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
            if started {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AngularGradient(colors: [.teal, .blue, .teal], center: .center),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                Text("\(Int((progress * 100).rounded(.down)))%")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
                    .animation(.default, value: progress)
            } else {
                // Python is still loading: spinning arc until the first progress event
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.teal, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .frame(width: 150, height: 150)
    }
}

// shown in random order instead of a plain "Repairing"
let repairingPhrases = [
    "Doing Stuff…",
    "Applying Magic…",
    "Reticulating Splines…",
    "Herding Triangles…",
    "Duct-Taping Vertices…",
    "Asking the Normals Nicely…",
    "Convincing Edges to Behave…",
    "Untangling Polygons…",
    "Plugging Leaks…",
    "Consulting the Mesh Wizard…",
    "Sweeping Holes Under the Rug…",
    "Summoning Watertightness…",
]

struct RunningView: View {
    let model: RepairModel
    @State private var phrase = repairingPhrases.randomElement()!

    private var stageText: String { model.stage == "Repairing" ? phrase : model.stage }

    var body: some View {
        VStack(spacing: 22) {
            ProgressRing(progress: model.progress, started: model.started)
            VStack(spacing: 4) {
                Text(model.currentFile).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if model.started { ProgressView().controlSize(.small) }
                    Text(stageText)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: stageText)
                    if model.fileCount > 1 { Text("· file \(model.fileIndex) of \(model.fileCount)") }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .task {
            // pick a new phrase every few seconds, never the same twice in a row
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                phrase = repairingPhrases.filter { $0 != phrase }.randomElement()!
            }
        }
    }
}

struct ReportView: View {
    let model: RepairModel

    var body: some View {
        VStack(spacing: 14) {
            if let error = model.engineError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).padding(.top, 24)
                Spacer()
            } else {
                summary.padding(.top, 20)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.results) { ResultRow(result: $0) }
                    }
                    .padding(.horizontal, 20)
                }
            }
            HStack {
                Button("Repair More…") { model.reset(); chooseFiles(model) }
                Spacer()
                let outputs = model.results.compactMap(\.output)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                    .disabled(outputs.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private var summary: some View {
        let good = model.results.filter(\.ok).count
        let all = model.results.count
        let symbol = good == all ? "checkmark.circle.fill"
            : model.results.contains { $0.error != nil } ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
        let color: Color = good == all ? .green : model.results.contains { $0.error != nil } ? .red : .orange
        return VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(color)
                .symbolEffect(.bounce, value: all)
            Text(good == all ? (all == 1 ? "Ready to print" : "All \(all) files ready to print")
                 : "\(good) of \(all) files fully repaired")
                .font(.title3.weight(.semibold))
        }
    }
}

struct ResultRow: View {
    let result: FileResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.error != nil ? "xmark.circle.fill"
                  : result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.error != nil ? .red : result.ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.output?.lastPathComponent ?? result.input.lastPathComponent)
                    .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let error = result.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                } else if let b = result.before, let a = result.after {
                    Text(details(b, a)).font(.caption).foregroundStyle(.secondary)
                    if !result.ok {
                        Text("Improved, but some issues remain").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func details(_ b: MeshStats, _ a: MeshStats) -> String {
        var parts: [String] = []
        if b.non_manifold_edges + a.non_manifold_edges > 0 {
            parts.append("non-manifold edges \(b.non_manifold_edges) → \(a.non_manifold_edges)")
        }
        if b.open_edges + a.open_edges > 0 { parts.append("hole edges \(b.open_edges) → \(a.open_edges)") }
        if parts.isEmpty { parts.append("no defects found") }
        parts.append("\(a.bodies) bod\(a.bodies == 1 ? "y" : "ies")")
        parts.append("\(a.faces.formatted()) triangles")
        return parts.joined(separator: " · ")
    }
}

@MainActor
func chooseFiles(_ model: RepairModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    panel.message = "Choose 3D models to repair"
    if panel.runModal() == .OK { model.enqueue(panel.urls) }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RepairModel()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Mesh Repair"
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.setFrameAutosaveName("MeshRepairWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // files dropped on the app icon / Dock icon, or opened with "Open With"
    func application(_ application: NSApplication, open urls: [URL]) {
        model.enqueue(urls)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model.cancel() }

    @objc func openDocument(_ sender: Any?) { chooseFiles(model) }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mesh Repair",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mesh Repair", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Mesh Repair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }
}

@main
enum MeshRepairMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
