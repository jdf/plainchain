import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A session window's identity, the value its `WindowGroup` presents.
/// `path` nil is an untitled session, autosaved under `id`.
struct SessionRef: Codable, Hashable {
    var id: UUID
    var path: String?

    init(id: UUID = UUID(), path: String? = nil) {
        self.id = id
        self.path = path
    }
}

/// What every session window shares, one per process: the device list and
/// its HAL listeners, the installed plugins, the CoreMIDI client and source
/// list, and the list of open sessions restored at launch. Each window's
/// `Model` reads these and is told when the device list changes.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var midiSources: [MidiSource] = []
    let midi: MidiSystem
    /// Every device name seen since launch, by UID, for naming one that is gone.
    private(set) var deviceNames: [String: String] = [:]
    /// HAL listeners for the device list and the system defaults.
    private var deviceListeners: [HAL.Listener] = []
    private var refreshTask: Task<Void, Never>?
    /// Live session models, in the order their windows opened.
    private var models: [WeakModel] = []
    private struct WeakModel { weak var model: Model? }
    /// Touches neither UserDefaults nor autosave files (for headless tests).
    let ephemeral: Bool

    /// Set once a window is up; opens further session windows.
    var openWindow: OpenWindowAction?
    /// The app is quitting: windows closing now stay in the restore list and keep their autosaves.
    var terminating = false
    /// Saved sessions still to be opened at launch, and those opened but not yet registered by their model.
    private var launchQueue: [SessionRef] = []
    private var pendingRefs: [SessionRef] = []
    private var launched = false
    /// Files asked for before the first window could open them.
    private var pendingURLs: [URL] = []
    /// The window SwiftUI opened at launch; a file opened before any window is key may load into it.
    private var launchID: UUID?
    /// The session window that was key most recently; Save falls back to it while a plugin editor is in front.
    @Published private(set) var lastFocusedID: UUID?
    var lastFocused: Model? { liveModels.first { $0.id == lastFocusedID } }

    private static let openSessionsKey = "openSessions"
    private static let legacySessionPathKey = "sessionPath"

    init(ephemeral: Bool = false, midi: MidiSystem = MidiSystem()) {
        self.ephemeral = ephemeral
        self.midi = midi
        if let d = try? Self.scanDevices() {
            devices = d
            for x in d { deviceNames[x.uid] = x.name }
        }
        plugins = Plugins.installed()
        midiSources = midi.sources
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
        // Fallback for missed notifications and rate or channel changes.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshDevices()
            }
        }
    }

    // MARK: Devices and plugins

    /// The HAL's devices, less this process's own private aggregates.
    private static func scanDevices() throws -> [Device] {
        try HAL.devices().filter { !$0.uid.hasPrefix(HAL.aggregatePrefix) }
    }

    func refreshDevices() {
        guard let d = try? Self.scanDevices() else { return }
        for x in d { deviceNames[x.uid] = x.name }
        guard d != devices else { return }
        devices = d
        for m in liveModels { m.devicesChanged() }
    }

    /// Re-read the installed Audio Units from the system registry.
    func refreshPlugins() {
        let p = Plugins.installed()
        if p != plugins { plugins = p }
    }

    // MARK: Session windows

    var liveModels: [Model] { models.compactMap(\.model) }

    func register(_ model: Model) {
        models.removeAll { $0.model == nil }
        models.append(WeakModel(model: model))
        pendingRefs.removeAll { $0.id == model.id }
        writeOpenSessions()
    }

    /// A window closed on purpose: it leaves the restore list.
    func unregister(_ model: Model) {
        models.removeAll { $0.model == nil || $0.model === model }
        if lastFocusedID == model.id { lastFocusedID = nil }
        writeOpenSessions()
    }

    /// The session for a window SwiftUI opened without one: at launch the
    /// first saved session (the others are queued for `windowAppeared`), else a new untitled one.
    func initialRef() -> SessionRef {
        guard !launched, !ephemeral else { return SessionRef() }
        launched = true
        let saved = savedRefs()
        launchQueue = Array(saved.dropFirst())
        pendingRefs = launchQueue
        let first = saved.first ?? SessionRef()
        launchID = first.id
        return first
    }

    func sessionBecameKey(_ model: Model) {
        if lastFocusedID != model.id { lastFocusedID = model.id }
    }

    /// A window is on screen: keep its `openWindow`, open the rest of the saved sessions, then any files asked for meanwhile.
    func windowAppeared(_ openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        let queue = launchQueue
        launchQueue = []
        for ref in queue { openWindow(value: ref) }
        let urls = pendingURLs
        pendingURLs = []
        for url in urls { open(url) }
    }

    func newSession() {
        openWindow?(value: SessionRef())
    }

    func openSessionPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SessionFile.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Open a session file: bring its window forward if it is open (or
    /// opening) already; load it into the key window, or at launch the first
    /// window, if that one is untitled and untouched; otherwise open a new window for it.
    func open(_ url: URL) {
        guard let openWindow else { pendingURLs.append(url); return }
        let path = url.standardizedFileURL.path
        if isOpen(path) { return }
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        let target = liveModels.first { $0.window != nil && $0.window === key } ?? liveModels.first { $0.id == launchID }
        guard let m = target else {
            openWindow(value: SessionRef(path: path))
            return
        }
        Task {
            await m.restored()
            guard !Task.isCancelled, !isOpen(path) else { return }
            if !m.closed, m.isPristine {
                await m.open(url, quietly: false)
            } else {
                openWindow(value: SessionRef(path: path))
            }
        }
    }

    /// Whether a window has `path` open, or is opening it; if so it is brought forward.
    private func isOpen(_ path: String) -> Bool {
        func same(_ p: String?) -> Bool { p.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }
        if let m = liveModels.first(where: { !$0.closed && same($0.ref.path) }) {
            m.window?.makeKeyAndOrderFront(nil)
            return true
        }
        return pendingRefs.contains { same($0.path) }
    }

    /// Before quitting: every session is autosaved and stays in the restore list.
    func shutdown() {
        terminating = true
        for m in liveModels { m.shutdown() }
        writeOpenSessions()
    }

    // MARK: Restore list

    /// The open sessions, in window order, for the next launch.
    func writeOpenSessions() {
        guard !ephemeral else { return }
        let refs = liveModels.filter { !$0.closed }.map(\.ref) + pendingRefs
        if let data = try? JSONEncoder().encode(refs) { UserDefaults.standard.set(data, forKey: Self.openSessionsKey) }
    }

    /// The sessions open at the last quit. The first launch after the move to
    /// session windows migrates the single remembered path, or the single
    /// autosave, into the list.
    private func savedRefs() -> [SessionRef] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.openSessionsKey), let refs = try? JSONDecoder().decode([SessionRef].self, from: data) {
            return refs
        }
        var refs: [SessionRef] = []
        let fm = FileManager.default
        if let path = defaults.string(forKey: Self.legacySessionPathKey), fm.fileExists(atPath: path) {
            refs = [SessionRef(path: path)]
        } else if fm.fileExists(atPath: SessionFile.legacyAutosaveURL.path) {
            let ref = SessionRef()
            if (try? fm.moveItem(at: SessionFile.legacyAutosaveURL, to: SessionFile.autosaveURL(for: ref.id))) != nil { refs = [ref] }
        }
        defaults.removeObject(forKey: Self.legacySessionPathKey)
        if let data = try? JSONEncoder().encode(refs) { defaults.set(data, forKey: Self.openSessionsKey) }
        return refs
    }
}
