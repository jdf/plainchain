import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Live per-plugin readings, polled from the engine and plugins ~20×/s.
/// Kept separate from `Model` so only the rows that show them redraw.
@MainActor
final class Levels: ObservableObject {
    /// Input peak per channel, linear, with a visual decay.
    @Published var peaks: [UUID: [Float]] = [:]
    /// Gain reduction in dB (≤ 0), for plugins that expose a meter for it.
    @Published var reduction: [UUID: Float] = [:]
}

/// All app state. Session edits are autosaved and, when the engine is
/// enabled, pushed to the engine (bypass live; anything else rebuilds the graph).
/// Plugin instances live here and survive graph rebuilds, so reordering the
/// chain or switching devices keeps every plugin's settings.
@MainActor
final class Model: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var session: Session
    @Published var enabled: Bool { didSet { enabled ? scheduleRestart() : stop() } }
    @Published private(set) var status = Engine.Status()
    @Published private(set) var error: String?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var dirty = false
    @Published private(set) var busy = false
    let levels = Levels()

    private var instances: [UUID: AVAudioUnit] = [:]
    /// Read-only meter parameters that report gain reduction, where a plugin has one.
    private var reductionMeters: [UUID: Plugins.ReductionMeter] = [:]
    private var editors: [UUID: EditorWindow] = [:]
    private var engine: Engine?
    private var restartTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?

    private static let sessionPathKey = "sessionPath"

    var title: String {
        let name = sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return dirty ? "\(name) — Edited" : name
    }

    init() {
        let devices = (try? HAL.devices()) ?? []
        self.devices = devices
        plugins = Plugins.installed()
        session = Self.defaultSession(devices)
        enabled = true  // the engine runs from launch; the Run switch is for pausing
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        Task {
            if let path = UserDefaults.standard.string(forKey: Self.sessionPathKey), FileManager.default.fileExists(atPath: path) {
                await open(URL(fileURLWithPath: path), quietly: true)
            } else if let saved = try? SessionFile.read(SessionFile.autosaveURL) {
                await load(saved, from: nil)
            }
            await poll()
        }
    }

    private static func defaultSession(_ devices: [Device]) -> Session {
        let inp = devices.first { $0.defaultInput } ?? devices.first { $0.inputChannels > 0 }
        let out = devices.first { $0.defaultOutput } ?? devices.first { $0.outputChannels > 0 }
        return Session(
            input: Endpoint(deviceUid: inp?.uid ?? "", channels: Array(0..<min(inp?.inputChannels ?? 0, 2))),
            output: Endpoint(deviceUid: out?.uid ?? "", channels: Array(0..<min(out?.outputChannels ?? 0, 2)))
        )
    }

    // MARK: Lookups

    var inputDevices: [Device] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [Device] { devices.filter { $0.outputChannels > 0 } }
    func device(uid: String) -> Device? { devices.first { $0.uid == uid } }
    func plugin(_ id: PluginId) -> Plugin? { plugins.first { $0.id == id } }
    func name(of id: PluginId) -> String { plugin(id)?.name ?? "\(id.manufacturer) \(id.subtype)" }
    func isEditorOpen(_ id: UUID) -> Bool { editors[id] != nil }

    // MARK: Editing

    func update(_ mutate: (inout Session) -> Void) {
        var next = session
        mutate(&next)
        guard next != session else { return }
        let sameSetup = next.input == session.input && next.output == session.output && next.bufferFrames == session.bufferFrames
        let liveOnly = sameSetup && next.chain.map(\.id) == session.chain.map(\.id)
        // A pure reorder: same items, same settings, different order.
        let oldIds = session.chain.map(\.id)
        let reorder: [Int]? = sameSetup && Set(oldIds) == Set(next.chain.map(\.id)) && oldIds != next.chain.map(\.id)
            && next.chain.allSatisfy({ item in session.chain.contains { $0 == item } })
            ? next.chain.map { item in oldIds.firstIndex(of: item.id)! } : nil
        let changed = zip(session.chain, next.chain).enumerated().filter { $1.0 != $1.1 }
        session = next
        markDirty()
        guard enabled else { return }
        if let reorder, let engine {
            engine.reorder(reorder)
        } else if liveOnly, let engine {
            for (i, (old, item)) in changed {
                if old.bypass != item.bypass {
                    do { try engine.setBypass(i, item.bypass) } catch { self.error = error.localizedDescription }
                }
                if old.inputGainDb != item.inputGainDb { engine.setGain(i, db: item.inputGainDb) }
            }
        } else {
            scheduleRestart()
        }
    }

    private func register(_ unit: AVAudioUnit, for id: UUID) {
        instances[id] = unit
        reductionMeters[id] = Plugins.gainReductionMeter(unit.audioUnit)
    }

    func add(_ plugin: Plugin) {
        Task {
            busy = true
            defer { busy = false }
            do {
                let item = ChainItem(plugin: plugin.id)
                register(try await Plugins.instantiate(plugin.id), for: item.id)
                update { $0.chain.append(item) }
                // Some plugins only offer their view once initialized, so wait for the rebuild.
                await restartTask?.value
                openEditor(item)
            } catch {
                self.error = "\(plugin.name): \(error.localizedDescription)"
            }
        }
    }

    func remove(at offsets: IndexSet) {
        let ids = offsets.map { session.chain[$0].id }
        update { $0.chain.remove(atOffsets: offsets) }
        // The engine has been scheduled to rebuild without these units; drop them after it does.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            for id in ids {
                editors[id]?.close()
                instances[id] = nil
                reductionMeters[id] = nil
                levels.peaks[id] = nil
                levels.reduction[id] = nil
            }
        }
    }

    func move(from: IndexSet, to: Int) { update { $0.chain.move(fromOffsets: from, toOffset: to) } }

    /// Open the plugin's editor, or bring it forward if it is already open.
    func openEditor(_ item: ChainItem) {
        if let w = editors[item.id] { w.makeKeyAndOrderFront(nil); return }
        guard let unit = instances[item.id] else { return }
        EditorWindow.open(for: unit, title: name(of: item.plugin)) { [weak self] window in
            guard let self else { return }
            editors[item.id] = window
            window.onClose = { [weak self] in self?.editors[item.id] = nil; self?.objectWillChange.send() }
            objectWillChange.send()
        }
    }

    var bufferSizeChoices: [Int] { engine?.bufferSizeChoices ?? [] }

    func setBufferSize(_ frames: Int) {
        session.bufferFrames = frames
        markDirty()
        guard let engine else { return }
        do {
            try engine.setBufferSize(frames)
            status = engine.status
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshDevices() {
        if let d = try? HAL.devices(), d != devices { devices = d }
    }

    // MARK: Sessions

    /// The session with every plugin's current state captured.
    private func snapshot() -> Session {
        var s = session
        for i in s.chain.indices {
            guard let state = instances[s.chain[i].id]?.auAudioUnit.fullState else { continue }
            s.chain[i].state = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        }
        return s
    }

    private func markDirty() {
        dirty = true
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            autosave()
        }
    }

    func autosave() {
        try? SessionFile.write(snapshot(), to: SessionFile.autosaveURL)
    }

    func newSession() {
        Task { await load(Self.defaultSession(devices), from: nil) }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SessionFile.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url, quietly: false) }
    }

    func open(_ url: URL, quietly: Bool) async {
        do {
            let s = try SessionFile.read(url)
            await load(s, from: url)
        } catch {
            if !quietly { self.error = "could not open \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    func saveSession() {
        if let url = sessionURL { save(to: url) } else { saveSessionAs() }
    }

    func saveSessionAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SessionFile.fileExtension) ?? .json]
        panel.nameFieldStringValue = (sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + SessionFile.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    private func save(to url: URL) {
        do {
            try SessionFile.write(snapshot(), to: url)
            sessionURL = url
            dirty = false
            UserDefaults.standard.set(url.path, forKey: Self.sessionPathKey)
        } catch {
            self.error = "could not save: \(error.localizedDescription)"
        }
    }

    /// Replace everything: stop, drop old plugins, instantiate the new chain with its saved state.
    private func load(_ incoming: Session, from url: URL?) async {
        busy = true
        defer { busy = false }
        restartTask?.cancel()
        engine = nil
        for w in editors.values { w.close() }
        editors = [:]
        instances = [:]
        reductionMeters = [:]
        levels.peaks = [:]
        levels.reduction = [:]
        var s = incoming
        var failures: [String] = []
        var kept: [ChainItem] = []
        for var item in s.chain {
            do {
                let unit = try await Plugins.instantiate(item.plugin)
                if let data = item.state,
                   let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = state
                }
                item.state = nil
                register(unit, for: item.id)
                kept.append(item)
            } catch {
                failures.append(name(of: item.plugin))
            }
        }
        s.chain = kept
        session = s
        sessionURL = url
        dirty = false
        error = failures.isEmpty ? nil : "could not load: " + failures.joined(separator: ", ")
        if let url { UserDefaults.standard.set(url.path, forKey: Self.sessionPathKey) } else { UserDefaults.standard.removeObject(forKey: Self.sessionPathKey) }
        if enabled { scheduleRestart() }
    }

    // MARK: Engine

    /// Rebuild the graph, coalescing rapid edits (channel clicks, drags) into one restart.
    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            restart()
        }
    }

    private func restart() {
        engine = nil
        let units = session.chain.compactMap { instances[$0.id]?.audioUnit }
        guard units.count == session.chain.count else { return }
        do {
            let stages = zip(units, session.chain).map { Engine.Stage(unit: $0, bypass: $1.bypass, gainDb: $1.inputGainDb) }
            engine = try Engine(input: session.input, output: session.output, devices: devices, stages: stages, bufferFrames: session.bufferFrames)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if let engine { status = engine.status } else { status.running = false }
    }

    private func stop() {
        restartTask?.cancel()
        engine = nil
        status.running = false  // keep the last readings so the status bar stays put, just grayed
        error = nil
    }

    func shutdown() {
        autosave()
        engine = nil
    }

    private func poll() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            tick += 1
            pollLevels()
            if tick % 20 == 0 {
                if let engine { status = engine.status }
                refreshDevices()
            }
        }
    }

    private func pollLevels() {
        guard let engine else {
            if !levels.peaks.isEmpty { levels.peaks = [:]; levels.reduction = [:] }
            return
        }
        for (i, item) in session.chain.enumerated() {
            let fresh = engine.takePeaks(i)
            let old = levels.peaks[item.id] ?? []
            // Fall ~28 dB/s so brief peaks stay visible.
            levels.peaks[item.id] = fresh.enumerated().map { c, v in max(v, (c < old.count ? old[c] : 0) * 0.85) }
            if let m = reductionMeters[item.id] { levels.reduction[item.id] = m.value }
        }
    }
}
