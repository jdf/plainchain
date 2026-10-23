import AudioToolbox
import AVFoundation
import Foundation

/// One loaded Audio Unit, owned by a session's model (and retained by any
/// engine wired to it, so it outlives the graph that renders it).
///
/// Version 2 components are created synchronously on the main thread with
/// `AudioComponentInstanceNew`, the way mainstream hosts do it. JUCE-based
/// and similar plugins take the thread that instantiates them as their
/// message thread, and their editors (shown on the main thread) misbehave if
/// that was some other thread. Version 3 components run out of process, so
/// they keep the asynchronous `AVAudioUnit` path.
///
/// Main-thread only: creation, state, observation, and disposal.
final class PluginInstance {
    let id: PluginId
    /// The raw handle the engine wires; for v3, the bridge `AVAudioUnit` offers.
    let audioUnit: AudioUnit
    /// Version 3 only: the instance as loaded through AVFoundation.
    let avUnit: AVAudioUnit?
    var isV3: Bool { avUnit != nil }
    /// Whether the component was created on the main thread (for v3, where its completion arrived).
    let createdOnMainThread: Bool

    /// Called on the main thread when the plugin reports a parameter or
    /// preset change, once observation has started.
    var onChange: (() -> Void)?

    private var listener: AUEventListenerRef?
    private var observerToken: AUParameterObserverToken?
    /// The last value seen per parameter, so notifications that change nothing
    /// (plugins send plenty around initialization and editor opening) are ignored.
    private var lastValues: [UInt64: Float] = [:]
    /// The state as of the last preset or state-change notification, for the same reason.
    private var lastState: NSDictionary?

    private init(id: PluginId, audioUnit: AudioUnit, avUnit: AVAudioUnit?, createdOnMainThread: Bool) {
        self.id = id
        self.audioUnit = audioUnit
        self.avUnit = avUnit
        self.createdOnMainThread = createdOnMainThread
    }

    deinit {
        if let listener { AUListenerDispose(listener) }
        if let observerToken { avUnit?.auAudioUnit.parameterTree?.removeParameterObserver(observerToken) }
        // The engine that used the unit has uninitialized it and is gone (it retains its plugins).
        if avUnit == nil { AudioComponentInstanceDispose(audioUnit) }
    }

    /// Load a plugin: v2 synchronously here on the main thread, v3 through AVFoundation.
    @MainActor
    static func make(_ id: PluginId) async throws -> PluginInstance {
        if let v2 = try makeV2(id) { return v2 }
        let (av, onMain): (AVAudioUnit, Bool) = try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: id.description, options: []) { unit, error in
                if let unit { cont.resume(returning: (unit, Thread.isMainThread)) } else { cont.resume(throwing: error ?? EngineError("could not load plugin")) }
            }
        }
        return PluginInstance(id: id, audioUnit: av.audioUnit, avUnit: av, createdOnMainThread: onMain)
    }

    /// A v2 component, created right here (the main thread); nil for a v3 one.
    @MainActor
    private static func makeV2(_ id: PluginId) throws -> PluginInstance? {
        precondition(Thread.isMainThread, "v2 plugins are instantiated on the main thread")
        var desc = id.description
        guard let component = AudioComponentFindNext(nil, &desc) else { throw EngineError("\(id.subtype): plugin not installed") }
        var found = AudioComponentDescription()
        try check(AudioComponentGetDescription(component, &found), "reading the plugin's description")
        guard found.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue == 0 else { return nil }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "loading the plugin")
        guard let unit else { throw EngineError("could not load plugin") }
        return PluginInstance(id: id, audioUnit: unit, avUnit: nil, createdOnMainThread: Thread.isMainThread)
    }

    // MARK: State

    /// The plugin's full state as a binary plist: `kAudioUnitProperty_ClassInfo`
    /// for v2, `AUAudioUnit.fullState` for v3 (which for a v2 unit is the same
    /// ClassInfo dictionary, so older session files load either way).
    var state: Data? {
        get {
            guard let dict = stateDictionary else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        }
        set {
            guard let newValue, let dict = try? PropertyListSerialization.propertyList(from: newValue, format: nil) as? [String: Any] else { return }
            if let avUnit {
                avUnit.auAudioUnit.fullState = dict
            } else {
                var plist: CFPropertyList = dict as CFDictionary
                _ = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, UInt32(MemoryLayout<CFPropertyList>.size))
            }
        }
    }

    private var stateDictionary: [String: Any]? {
        if let avUnit { return avUnit.auAudioUnit.fullState }
        var plist: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, &size) == noErr, let plist else { return nil }
        return plist.takeRetainedValue() as? [String: Any]
    }

    // MARK: Parameters

    /// Global parameters as (address, name), for listings.
    var parameterNames: [(UInt64, String)] {
        if let avUnit { return (avUnit.auAudioUnit.parameterTree?.allParameters ?? []).map { ($0.address, $0.displayName) } }
        return Plugins.v2Parameters(audioUnit).map { (UInt64($0.id), $0.name) }
    }

    // MARK: Change signal

    /// Start calling `onChange` for parameter and preset changes. Call once the
    /// host has finished setting the plugin up (state loaded), so the host's own
    /// changes do not count.
    func startObserving() {
        precondition(Thread.isMainThread)
        guard listener == nil, observerToken == nil else { return }
        if let tree = avUnit?.auAudioUnit.parameterTree {
            for p in tree.allParameters { lastValues[p.address] = p.value }
            observerToken = tree.token(byAddingParameterObserver: { [weak self] address, value in
                DispatchQueue.main.async { self?.parameterChanged(address, value) }
            })
            return
        }
        guard avUnit == nil else { return }
        var created: AUEventListenerRef?
        let interval: Float32 = 0.1
        guard AUEventListenerCreateWithDispatchQueue(&created, interval, interval, .main, { [weak self] _, event, _, value in
            self?.event(event.pointee, value)
        }) == noErr, let created else { return }
        listener = created
        for p in Plugins.v2Parameters(audioUnit) {
            var v: AudioUnitParameterValue = 0
            if AudioUnitGetParameter(audioUnit, p.id, kAudioUnitScope_Global, 0, &v) == noErr { lastValues[UInt64(p.id)] = v }
            var e = AudioUnitEvent(mEventType: .parameterValueChange, mArgument: .init(mParameter: AudioUnitParameter(
                mAudioUnit: audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)))
            _ = AUEventListenerAddEventType(created, nil, &e)
        }
        // There is no "preset changed" property; a preset choice shows up as PresentPreset, a wholesale state change as ClassInfo.
        lastState = stateDictionary as NSDictionary?
        for prop in [kAudioUnitProperty_PresentPreset, kAudioUnitProperty_ClassInfo] {
            var e = AudioUnitEvent(mEventType: .propertyChange, mArgument: .init(mProperty: AudioUnitProperty(
                mAudioUnit: audioUnit, mPropertyID: prop, mScope: kAudioUnitScope_Global, mElement: 0)))
            _ = AUEventListenerAddEventType(created, nil, &e)
        }
    }

    private func event(_ e: AudioUnitEvent, _ value: AudioUnitParameterValue) {
        switch e.mEventType {
        case .parameterValueChange:
            parameterChanged(UInt64(e.mArgument.mParameter.mParameterID), value)
        case .propertyChange:
            // Compared as dictionaries: equal states can serialize with their keys in another order.
            let now = stateDictionary as NSDictionary?
            guard now != lastState else { return }
            lastState = now
            onChange?()
        default:
            break
        }
    }

    private func parameterChanged(_ address: UInt64, _ value: Float) {
        // A parameter that could not be read when observation started (DLSMusicDevice's,
        // before it is initialized) takes its first notification as its baseline.
        guard let old = lastValues[address] else { lastValues[address] = value; return }
        guard old != value else { return }
        lastValues[address] = value
        onChange?()
    }
}
