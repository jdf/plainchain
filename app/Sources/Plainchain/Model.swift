import AppKit
import AVFoundation
import Combine
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

/// One session window's state: its session, engine, plugin instances, and
/// editors. Session edits are autosaved and, when the engine is enabled,
/// pushed to the engine (bypass live; anything else rebuilds the graph).
/// Plugin instances live here and survive graph rebuilds, so reordering the
/// chain or switching devices keeps every plugin's settings. What windows
/// share (devices, plugins, MIDI sources) lives in `AppState`.
@MainActor
final class Model: ObservableObject {
    let app: AppState
    /// The window's session identity; also names its autosave file.
    let id: UUID
    @Published private(set) var session: Session
    @Published var enabled: Bool { didSet { enabled ? scheduleRestart() : stop() } }
    @Published private(set) var status = Engine.Status()
    @Published private(set) var error: String?
    /// A normal state worth pointing out, such as MIDI input with no instrument; not an error.
    @Published private(set) var hint: String?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var dirty = false
    /// Whether the autosave file is behind the session; cleared by each write.
    private var autosaveStale = true
    @Published private(set) var busy = false
    let levels = Levels()
    /// MIDI input; its rings feed the engine's instrument and music effects, and it costs nothing otherwise.
    let midi: MidiInput
    /// The window showing this session, once it is on screen.
    private(set) weak var window: NSWindow?
    private var closeGuard: WindowCloseGuard?
    /// The window was closed on purpose and everything is shut down.
    private(set) var closed = false
    /// The file the window was opened with, until a load resolves it; the restore list keeps it meanwhile.
    private var requestedPath: String?
    /// The session as created, before any restore or edit: `isPristine` compares against it,
    /// not the current system defaults, so plugging in headphones does not make a window "touched".
    private let initialSession: Session
    /// A load problem to keep showing once the engine is up (the rebuild otherwise clears `error`).
    private var loadNotice: String?
    private var midiReceived: UInt32 = 0
    private var midiQuietTicks = 0

    private var instances: [UUID: PluginInstance] = [:]
    /// A plugin change is waiting to be marked; further ones until then coalesce into it.
    private var pluginChangePending = false
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
    private var pollTask: Task<Void, Never>?
    /// Loading the session the window was opened with.
    private var restoreTask: Task<Void, Never>?
    private var appWatch: AnyCancellable?
    /// The engine is down only because a session device is missing, and comes back when it returns.
    private var awaitingDevice = false
    /// `DeviceIsAlive` listeners on the running engine's devices; dropped with the engine.
    private var aliveListeners: [HAL.Listener] = []
    /// A session load is swapping plugins and session; device changes wait for it.
    private var loading = false

    /// Touches no autosave file: no restore, no autosave (for headless tests).
    private let ephemeral: Bool

    var title: String {
        let name = sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return dirty ? "\(name) — Edited" : name
    }

    /// A session window's model: `ref.path` is the session file, or nil for
    /// an untitled session. Either way an autosave under `ref.id`, if there is
    /// one, holds the latest state and wins.
    init(app: AppState, ref: SessionRef = SessionRef(), ephemeral: Bool = false) {
        self.app = app
        self.id = ref.id
        self.ephemeral = ephemeral
        midi = MidiInput(system: app.midi)
        let fresh = Self.defaultSession(app.devices)
        session = fresh
        initialSession = fresh
        requestedPath = ref.path
        enabled = true  // the engine runs from launch; the Run switch is for pausing
        // The views watch this model; shared lists changing redraw them too.
        appWatch = app.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        app.register(self)
        restoreTask = Task {
            guard !ephemeral else { return }
            let file = ref.path.map { URL(fileURLWithPath: $0) }
            if let saved = try? SessionFile.read(SessionFile.autosaveURL(for: ref.id)) {
                await load(saved, from: file)
                guard !Task.isCancelled, !closed else { return }
                if file != nil { dirty = true }  // a titled session's autosave holds edits not yet saved
                autosaveStale = false  // the autosave file is what was just loaded
            } else if let file {
                await open(file, quietly: false)
                guard !Task.isCancelled, !closed else { return }
                // The file could not be read: run the default session, with the error kept in view.
                if sessionURL == nil, enabled { loadNotice = error; scheduleRestart() }
            } else if enabled {
                scheduleRestart()  // a new untitled session runs on the default devices right away
            }
        }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                tick += 1
                pollLevels()
                if tick % 20 == 0, let engine { status = engine.status }  // picks up buffer size changes from other windows
            }
        }
    }

    /// For the restore list and window value. Until the window's file has
    /// loaded (or while it failed to and the window is untouched), the file it was opened with.
    var ref: SessionRef { SessionRef(id: id, path: sessionURL?.path ?? requestedPath) }

    /// Wait for the session the window opened with to finish loading.
    func restored() async { await restoreTask?.value }

    /// The default devices (or any with channels in the right direction); None where there is no device at all.
    private static func defaultSession(_ devices: [Device]) -> Session {
        let inp = devices.first { $0.defaultInput } ?? devices.first { $0.inputChannels > 0 }
        let out = devices.first { $0.defaultOutput } ?? devices.first { $0.outputChannels > 0 }
        return Session(
            input: inp.map { Endpoint(deviceUid: $0.uid, channels: Array(0..<min($0.inputChannels, 2))) } ?? .none,
            output: out.map { Endpoint(deviceUid: $0.uid, channels: Array(0..<min($0.outputChannels, 2))) } ?? .none
        )
    }

    // MARK: Lookups

    var devices: [Device] { app.devices }
    var plugins: [Plugin] { app.plugins }
    var midiSources: [MidiSource] { app.midiSources }
    var inputDevices: [Device] { devices.filter { $0.inputChannels > 0 } }
    var outputDevices: [Device] { devices.filter { $0.outputChannels > 0 } }
    func device(uid: String) -> Device? { devices.first { $0.uid == uid } }
    func plugin(_ id: PluginId) -> Plugin? { plugins.first { $0.id == id } }
    var hasMidi: Bool { session.input.hasMidi }
    var hasInstrument: Bool { session.chain.first?.plugin.isInstrument == true }
    /// The picker offers instruments while the head is open to one.
    var offersInstruments: Bool { !hasInstrument }
    /// A MIDI source is chosen and nothing in the chain takes MIDI.
    var midiUnused: Bool { hasMidi && !session.chain.contains { $0.plugin.receivesMidi } }
    /// What the status bar says about a chosen input that nothing takes; nil when both go somewhere.
    private var inputHint: String? {
        if midiUnused { return Self.midiUnusedHint }
        if engine?.audioInputUnused == true, let head = session.chain.first { return Self.audioUnusedHint(name(of: head.plugin)) }
        return nil
    }
    /// Channels flowing through the chain.
    var chainWidth: Int {
        if session.input.isDevice { return session.input.channels.count }
        return session.output.isNone || session.output.channels.count >= 2 ? 2 : 1
    }
    func name(of id: PluginId) -> String { plugin(id)?.name ?? "\(id.manufacturer) \(id.subtype)" }
    func isEditorOpen(_ id: UUID) -> Bool { editors[id] != nil }
    /// The loaded plugin for a chain item (for the headless checks).
    func instance(for id: UUID) -> PluginInstance? { instances[id] }

    // MARK: Editing

    func update(_ mutate: (inout Session) -> Void) {
        var next = session
        mutate(&next)
        guard next != session else { return }
        // Only the MIDI source changed (to another, to none, or from none): reconnect, no rebuild.
        var sameButSource = next
        sameButSource.input.midiSource = session.input.midiSource
        sameButSource.input.midiSourceName = session.input.midiSourceName
        if sameButSource == session {
            session = next
            markDirty()
            if enabled {
                midi.releaseAll()
                midi.connect(next.input.midiSource)
                if engine != nil { hint = inputHint }
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

    /// Keep a loaded plugin and watch it for changes made in its editor (or by
    /// MIDI), which mark the session edited. Call after any state is loaded into it.
    private func register(_ unit: PluginInstance, for id: UUID) {
        instances[id] = unit
        reductionMeters[id] = Plugins.gainReductionMeter(unit.audioUnit)
        unit.onChange = { [weak self] in self?.pluginChanged() }
        unit.startObserving()
    }

    private func pluginChanged() {
        guard !pluginChangePending, !loading, !closed else { return }
        pluginChangePending = true
        Task {
            pluginChangePending = false
            guard !loading, !closed else { return }
            markDirty()
        }
    }

    func add(_ plugin: Plugin) {
        Task {
            busy = true
            defer { busy = false }
            do {
                if plugin.isInstrument, hasInstrument { throw EngineError("the chain already has an instrument") }
                let item = ChainItem(plugin: plugin.id)
                let unit = try await PluginInstance.make(plugin.id)
                guard !closed else { return }
                register(unit, for: item.id)
                update { s in
                    guard plugin.isInstrument else { s.chain.append(item); return }
                    // An instrument heads the chain, played by every MIDI source unless one is chosen already.
                    s.chain.insert(item, at: 0)
                    if !s.input.hasMidi { s.input.midiSource = "*"; s.input.midiSourceName = MidiInput.allSourcesName }
                }
                // Some plugins only offer their view once initialized, so wait for the rebuild.
                await restartTask?.value
                guard !closed else { return }
                openEditor(item)
            } catch {
                self.error = "\(plugin.name): \(error.localizedDescription)"
            }
        }
    }

    func remove(at offsets: IndexSet) {
        let ids = offsets.map { session.chain[$0].id }
        let removed = ids.map { instances[$0] }
        update { $0.chain.remove(atOffsets: offsets) }
        // The engine has been scheduled to rebuild without these units; drop them after it does.
        // (An engine also retains its units, so one still running cannot outlive them.)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            // A session loaded meanwhile may reuse these ids (the same file again); leave its plugins alone.
            for (id, unit) in zip(ids, removed) where instances[id] === unit {
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
        guard !closed else { return }
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

    private var inputName: String { app.deviceNames[session.input.deviceUid] ?? "input device" }
    private var outputName: String { app.deviceNames[session.output.deviceUid] ?? "output device" }

    /// The name of a session device that is not connected, if any. A None endpoint has no device.
    private var missingDevice: String? {
        if session.input.isDevice, device(uid: session.input.deviceUid) == nil { return inputName }
        if session.output.isDevice, device(uid: session.output.deviceUid) == nil { return outputName }
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
    func devicesChanged() {
        guard !loading, !closed else { return }  // `load` restarts on its own when it is done
        if let engine {
            if session.input.isDevice, device(uid: session.input.deviceUid)?.id != engine.inputDevice {
                awaitDevice(inputName)
            } else if session.output.isDevice, device(uid: session.output.deviceUid)?.id != engine.outputDevice {
                awaitDevice(outputName)
            }
        }
        if enabled && awaitingDevice && missingDevice == nil { scheduleRestart() }
    }

    /// Watch the engine's devices directly, so a device that dies and comes
    /// back under the same object id is still noticed.
    private func watchEngineDevices() {
        guard let engine else { return }
        aliveListeners = Set([engine.inputDevice, engine.outputDevice]).subtracting([0]).compactMap { id in
            try? HAL.listen(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in Task { @MainActor in self?.aliveChanged(id) } }
        }
    }

    private func aliveChanged(_ id: AudioObjectID) {
        guard let engine, id == engine.inputDevice || id == engine.outputDevice else { return }
        let alive: UInt32 = (try? HAL.get(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0))) ?? 0
        guard alive == 0 else { return }
        awaitDevice(id == engine.outputDevice ? outputName : inputName)
        app.refreshDevices()
        devicesChanged()
    }

    /// Re-read the installed Audio Units from the system registry.
    func refreshPlugins() { app.refreshPlugins() }

    // MARK: Sessions

    /// The session with every plugin's current state captured.
    private func snapshot() -> Session {
        var s = session
        for i in s.chain.indices {
            s.chain[i].state = instances[s.chain[i].id]?.state
        }
        return s
    }

    private func markDirty() {
        dirty = true
        autosaveStale = true
        loadNotice = nil
        // An untitled window whose file failed to load becomes its own session once edited.
        if sessionURL == nil { requestedPath = nil }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            autosave()
        }
    }

    /// An untitled session is always autosaved; a titled one only while it
    /// has unsaved edits (its file holds the rest), so quitting never loses them.
    func autosave() {
        guard !ephemeral, !closed else { return }
        if sessionURL != nil && !hasUnsavedChanges { discardAutosave(); return }
        // Nothing changed since the last write: skip it, so quitting does not
        // read every plugin's state (an instrument's can take seconds).
        guard autosaveStale else { return }
        try? SessionFile.write(snapshot(), to: SessionFile.autosaveURL(for: id))
        autosaveStale = false
    }

    /// The titled session differs from its file: session edits and plugin
    /// changes (parameters, presets) mark it dirty, and so does restoring it
    /// from an autosave that held unsaved edits.
    var hasUnsavedChanges: Bool { sessionURL != nil && dirty }

    private func discardAutosave() {
        guard !ephemeral else { return }
        try? FileManager.default.removeItem(at: SessionFile.autosaveURL(for: id))
    }

    /// Untitled and untouched: nothing in the chain and the default devices.
    /// A file opened from the key window loads into such a window instead of a new one.
    var isPristine: Bool {
        sessionURL == nil && requestedPath == nil && !loading && session.chain.isEmpty
            && session.input == initialSession.input && session.output == initialSession.output
    }

    /// Closing would lose something: an untitled session with anything in it, or a titled one with unsaved changes.
    var needsSavePrompt: Bool { sessionURL == nil ? !isPristine : hasUnsavedChanges }

    func open(_ url: URL, quietly: Bool) async {
        do {
            let s = try SessionFile.read(url)
            await load(s, from: url)
            discardAutosave()
        } catch {
            if !quietly { self.error = "could not open \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    /// Whether the session was saved (false when the save panel was cancelled or the write failed).
    @discardableResult
    func saveSession() -> Bool {
        if let url = sessionURL { return save(to: url) } else { return saveSessionAs() }
    }

    @discardableResult
    func saveSessionAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SessionFile.fileExtension) ?? .json]
        panel.nameFieldStringValue = (sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + SessionFile.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // One window per file: two windows saving over each other would lose one's work.
        let path = url.standardizedFileURL.path
        if let other = app.liveModels.first(where: { $0 !== self && $0.ref.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }) {
            error = "could not save: “\(url.lastPathComponent)” is open in another window (\(other.title))"
            return false
        }
        return save(to: url)
    }

    private func save(to url: URL) -> Bool {
        do {
            try SessionFile.write(snapshot(), to: url)
            sessionURL = url
            requestedPath = nil
            dirty = false
            autosaveTask?.cancel()
            discardAutosave()
            app.writeOpenSessions()
            return true
        } catch {
            self.error = "could not save: \(error.localizedDescription)"
            return false
        }
    }

    /// Replace everything: stop, drop old plugins, instantiate the new chain with its saved state.
    private func load(_ incoming: Session, from url: URL?) async {
        busy = true
        loading = true
        defer { busy = false; loading = false }
        guard !closed else { return }
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
                let unit = try await PluginInstance.make(item.plugin)
                if let data = item.state { unit.state = data }
                item.state = nil
                register(unit, for: item.id)  // observes from here on, so loading the state does not count as an edit
                kept.append(item)
            } catch {
                failures.append(name(of: item.plugin))
            }
        }
        guard !closed else { return }  // the window closed meanwhile; the units die with the model
        s.chain = kept
        session = s
        sessionURL = url
        requestedPath = nil
        dirty = false
        loadNotice = failures.isEmpty ? nil : "could not load: " + failures.joined(separator: ", ")
        error = loadNotice
        app.writeOpenSessions()
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

    static let midiUnusedHint = "Add an instrument or music effect to play MIDI into"
    static func audioUnusedHint(_ instrument: String) -> String { "\(instrument) takes no audio; the audio input is unused" }

    private func restart() {
        guard !closed else { return }
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
            error = loadNotice
            hint = inputHint
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

    /// The app is quitting: autosave and stop, keeping the autosave for the next launch.
    /// Quit: write the autosave, then dispose every plugin before the process
    /// exits. A plugin left alive at exit runs its static destructors under
    /// live threads and aborts (Arturia's did).
    func shutdown() {
        autosave()
        pollTask?.cancel()
        restartTask?.cancel()
        engine = nil
        midi.connect("")
        for w in editors.values { w.close() }
        editors = [:]
        reductionMeters = [:]
        instances = [:]
    }

    /// The window was closed on purpose: stop everything, close the editors,
    /// and forget the session's autosave and its place in the restore list.
    func close() {
        guard !closed else { return }
        restartTask?.cancel()
        autosaveTask?.cancel()
        pollTask?.cancel()
        restoreTask?.cancel()
        engine = nil
        midi.connect("")
        for w in editors.values { w.close() }
        editors = [:]
        closed = true
        discardAutosave()
        app.unregister(self)
    }

    // MARK: Window

    /// The window is on screen: watch it for closing.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        closeGuard = WindowCloseGuard(window: window, model: self)
    }

    /// Asked by the window before it closes: false while the Save / Don't Save / Cancel sheet decides.
    fileprivate func windowShouldClose(_ window: NSWindow) -> Bool {
        guard !app.terminating, needsSavePrompt else { return true }
        let alert = NSAlert()
        let name = sessionURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        alert.messageText = "Do you want to save the changes made to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, let window else { return }
            switch response {
            case .alertFirstButtonReturn:
                // The sheet is gone before a save panel comes up.
                DispatchQueue.main.async { if self.saveSession() { window.close() } }
            case .alertThirdButtonReturn:
                window.close()  // close() skips windowShouldClose
            default:
                break
            }
        }
        return false
    }

    fileprivate func windowWillClose() {
        guard !app.terminating else { return }  // quitting: keep the session for the next launch
        close()
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

/// Asks the model before its window closes, and tells it when the window
/// does. SwiftUI owns the window's delegate (and sets it after the content is
/// in the window), so this stands in front of whatever delegate is set and
/// forwards everything else to it.
@MainActor
private final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var model: Model?
    private weak var original: NSWindowDelegate?
    private var observers: [NSObjectProtocol] = []
    private var delegateWatch: NSKeyValueObservation?

    init(window: NSWindow, model: Model) {
        self.model = model
        super.init()
        install(on: window)
        delegateWatch = window.observe(\.delegate) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.install(on: window) }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.windowWillClose() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let model = self?.model { model.app.sessionBecameKey(model) } }
            },
        ]
        if window.isKeyWindow { model.app.sessionBecameKey(model) }
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    private func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.windowShouldClose(sender) ?? true else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
