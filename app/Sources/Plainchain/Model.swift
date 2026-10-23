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
    /// MIDI arrived within the last ~150 ms.
    @Published var midiActive = false
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
    /// A normal state worth pointing out, such as MIDI input with no instrument; not an error.
    @Published private(set) var hint: String?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var dirty = false
    @Published private(set) var busy = false
    @Published private(set) var midiSources: [MidiSource] = []
    let levels = Levels()
    /// MIDI input; its rings feed the engine in MIDI mode, and it costs nothing otherwise.
    let midi = MidiInput()
    private var midiReceived: UInt32 = 0
    private var midiQuietTicks = 0

    private var instances: [UUID: AVAudioUnit] = [:]
    /// Read-only meter parameters that report gain reduction, where a plugin has one.
    private var reductionMeters: [UUID: Plugins.ReductionMeter] = [:]
    private var editors: [UUID: EditorWindow] = [:]
    private var engine: Engine? {
        // MIDI delivery stops before the graph that drains it goes away.
        willSet { if newValue !== engine { midi.active = 0 } }
        didSet { if engine !== oldValue { aliveListeners = [] } }
    }
    private var restartTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    /// The engine is down only because a session device is missing, and comes back when it returns.
    private var awaitingDevice = false
    /// Every device name seen since launch, by UID, for naming one that is gone.
    private var deviceNames: [String: String] = [:]
    /// HAL listeners for the device list and the system defaults.
    private var deviceListeners: [HAL.Listener] = []
    /// `DeviceIsAlive` listeners on the running engine's devices; dropped with the engine.
    private var aliveListeners: [HAL.Listener] = []
    /// A session load is swapping plugins and session; device changes wait for it.
    private var loading = false

    private static let sessionPathKey = "sessionPath"
    /// Touches neither UserDefaults nor the autosave file: no restore at launch, no autosave (for headless tests).
    private let ephemeral: Bool

    var title: String {
        let name = sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return dirty ? "\(name) — Edited" : name
    }

    init(ephemeral: Bool = false) {
        self.ephemeral = ephemeral
        let devices = (try? Self.scanDevices()) ?? []
        self.devices = devices
        for d in devices { deviceNames[d.uid] = d.name }
        plugins = Plugins.installed()
        midiSources = midi.sources
        session = Self.defaultSession(devices)
        enabled = true  // the engine runs from launch; the Run switch is for pausing
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // macOS registers newly installed Audio Units on its own; it tells us when the set changes.
        NotificationCenter.default.addObserver(forName: Notification.Name(kAudioComponentRegistrationsChangedNotification as String), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPlugins() }
        }
        // The HAL tells us when devices come and go, and when the system defaults change.
        let sys = AudioObjectID(kAudioObjectSystemObject)
        deviceListeners = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].compactMap {
            try? HAL.listen(sys, $0) { [weak self] in Task { @MainActor in self?.refreshDevices() } }
        }
        midi.onSourcesChanged = { [weak self] s in MainActor.assumeIsolated { self?.midiSources = s } }
        Task {
            if !ephemeral, let path = UserDefaults.standard.string(forKey: Self.sessionPathKey), FileManager.default.fileExists(atPath: path) {
                await open(URL(fileURLWithPath: path), quietly: true)
            } else if !ephemeral, let saved = try? SessionFile.read(SessionFile.autosaveURL) {
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
    var isMidi: Bool { session.input.isMidi }
    var hasInstrument: Bool { session.chain.first?.plugin.isInstrument == true }
    /// MIDI input with nothing to play it: the head slot waits for an instrument.
    var needsInstrument: Bool { isMidi && !hasInstrument }
    /// Channels flowing through the chain.
    var chainWidth: Int { isMidi ? (session.output.channels.count >= 2 ? 2 : 1) : session.input.channels.count }
    func name(of id: PluginId) -> String { plugin(id)?.name ?? "\(id.manufacturer) \(id.subtype)" }
    func isEditorOpen(_ id: UUID) -> Bool { editors[id] != nil }

    // MARK: Editing

    func update(_ mutate: (inout Session) -> Void) {
        var next = session
        mutate(&next)
        guard next != session else { return }
        // Another MIDI source in MIDI mode: reconnect, no rebuild.
        var sameButSource = next
        sameButSource.input.midiSource = session.input.midiSource
        sameButSource.input.midiSourceName = session.input.midiSourceName
        if sameButSource == session, next.input.isMidi, session.input.isMidi {
            session = next
            markDirty()
            if enabled {
                midi.releaseAll()
                midi.connect(next.input.midiSource)
            }
            return
        }
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
                if plugin.isInstrument, hasInstrument { throw EngineError("the chain already has an instrument") }
                let item = ChainItem(plugin: plugin.id)
                register(try await Plugins.instantiate(plugin.id), for: item.id)
                update { s in
                    guard plugin.isInstrument else { s.chain.append(item); return }
                    // An instrument heads the chain and needs MIDI input.
                    s.chain.insert(item, at: 0)
                    if !s.input.isMidi { s.input.midiSource = "*"; s.input.midiSourceName = MidiInput.allSourcesName }
                }
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

    /// Refuses any order that moves an instrument off position 0 or puts an effect before it.
    func move(from: IndexSet, to: Int) {
        var chain = session.chain
        chain.move(fromOffsets: from, toOffset: to)
        guard !chain.dropFirst().contains(where: \.plugin.isInstrument), chain.first?.plugin.isInstrument == hasInstrument else { return }
        update { $0.chain = chain }
    }

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

    /// The HAL's devices, less this process's own private aggregates.
    private static func scanDevices() throws -> [Device] {
        try HAL.devices().filter { !$0.uid.hasPrefix(HAL.aggregatePrefix) }
    }

    func refreshDevices() {
        guard let d = try? Self.scanDevices() else { return }
        for x in d { deviceNames[x.uid] = x.name }
        guard d != devices else { return }
        devices = d
        reconcileDevices()
    }

    private var inputName: String { deviceNames[session.input.deviceUid] ?? "input device" }
    private var outputName: String { deviceNames[session.output.deviceUid] ?? "output device" }

    /// The name of a session device that is not connected, if any. A MIDI input has no device.
    private var missingDevice: String? {
        if !isMidi, device(uid: session.input.deviceUid) == nil { return inputName }
        if device(uid: session.output.deviceUid) == nil { return outputName }
        return nil
    }

    /// Engine down until `name` is back.
    private func awaitDevice(_ name: String) {
        engine = nil
        awaitingDevice = true
        status.running = false
        error = "Waiting for \(name)…"
    }

    /// After a device-list change: drop an engine whose devices went away (or
    /// went and came back with new ids), and restart one that was waiting for
    /// them. Nothing else restarts the engine here, so a graph that fails to
    /// build for other reasons is not retried on every device change.
    private func reconcileDevices() {
        guard !loading else { return }  // `load` restarts on its own when it is done
        if let engine {
            if !isMidi, device(uid: session.input.deviceUid)?.id != engine.inputDevice {
                awaitDevice(inputName)
            } else if device(uid: session.output.deviceUid)?.id != engine.outputDevice {
                awaitDevice(outputName)
            }
        }
        if enabled && awaitingDevice && missingDevice == nil { scheduleRestart() }
    }

    /// Watch the engine's devices directly, so a device that dies and comes
    /// back under the same object id is still noticed.
    private func watchEngineDevices() {
        guard let engine else { return }
        aliveListeners = Set([engine.inputDevice, engine.outputDevice]).compactMap { id in
            try? HAL.listen(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in Task { @MainActor in self?.aliveChanged(id) } }
        }
    }

    private func aliveChanged(_ id: AudioObjectID) {
        guard let engine, id == engine.inputDevice || id == engine.outputDevice else { return }
        let alive: UInt32 = (try? HAL.get(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0
        guard alive == 0 else { return }
        awaitDevice(id == engine.outputDevice ? outputName : inputName)
        refreshDevices()
        reconcileDevices()
    }

    /// Re-read the installed Audio Units from the system registry.
    func refreshPlugins() {
        let p = Plugins.installed()
        if p != plugins { plugins = p }
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
        guard !ephemeral else { return }
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
            if !ephemeral { UserDefaults.standard.set(url.path, forKey: Self.sessionPathKey) }
        } catch {
            self.error = "could not save: \(error.localizedDescription)"
        }
    }

    /// Replace everything: stop, drop old plugins, instantiate the new chain with its saved state.
    private func load(_ incoming: Session, from url: URL?) async {
        busy = true
        loading = true
        defer { busy = false; loading = false }
        restartTask?.cancel()
        engine = nil
        status.running = false
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
        if !ephemeral {
            if let url { UserDefaults.standard.set(url.path, forKey: Self.sessionPathKey) } else { UserDefaults.standard.removeObject(forKey: Self.sessionPathKey) }
        }
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
        hint = nil
        if let missing = missingDevice { awaitDevice(missing); return }
        // A failed recovery build (device still settling) stays armed for the next device change.
        let recovering = awaitingDevice
        awaitingDevice = false
        let units = session.chain.compactMap { instances[$0.id]?.audioUnit }
        guard units.count == session.chain.count else { return }
        do {
            let stages = zip(units, session.chain).map {
                Engine.Stage(unit: $0, bypass: $1.bypass, gainDb: $1.inputGainDb, isInstrument: $1.plugin.isInstrument)
            }
            let engine = try Engine(input: session.input, output: session.output, devices: devices, stages: stages,
                                    bufferFrames: session.bufferFrames, midi: midi.fanout)
            self.engine = engine
            midi.active = engine.midiRingCount
            midi.connect(session.input.midiSource)
            error = nil
            hint = needsInstrument ? "Add an instrument to play MIDI into" : nil
            watchEngineDevices()
        } catch {
            self.error = error.localizedDescription
            awaitingDevice = recovering
        }
        if let engine { status = engine.status } else { status.running = false }
    }

    private func stop() {
        restartTask?.cancel()
        engine = nil
        midi.connect("")
        awaitingDevice = false
        status.running = false  // keep the last readings so the status bar stays put, just grayed
        hint = nil
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
                refreshDevices()  // fallback for missed notifications and rate or channel changes
            }
        }
    }

    private func pollLevels() {
        let received = midi.received
        midiQuietTicks = received != midiReceived ? 0 : midiQuietTicks + 1
        midiReceived = received
        if levels.midiActive != (midiQuietTicks < 3) { levels.midiActive.toggle() }
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
