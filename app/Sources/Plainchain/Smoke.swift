import AVFoundation
import Combine
import CoreMIDI
import Foundation

/// `Plainchain --smoke [PC_IN=name] [PC_OUT=name] [plugin names...]`
/// Headless check: lists devices and plugins, builds the chain, runs it for
/// two seconds, and round-trips a session file. Exits nonzero on failure.
/// With `PC_MIDI=1` it checks MIDI input instead (see `midi`).
enum Smoke {
    static func run() {
        do { try go() } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        exit(0)
    }

    private static func go() throws {
        let env = ProcessInfo.processInfo.environment
        let devices = try HAL.devices()
        for d in devices {
            print(String(format: "%4d in %2d out %2d @%6.0f %@%@ %@", d.id, d.inputChannels, d.outputChannels, d.sampleRate,
                         d.defaultInput ? "I" : " ", d.defaultOutput ? "O" : " ", d.name))
        }
        let plugins = Plugins.installed()
        print("\(plugins.count) plugins")
        func pick(_ key: String, _ dflt: (Device) -> Bool) throws -> Device {
            if let n = env[key] {
                guard let d = devices.first(where: { $0.name.contains(n) }) else { throw EngineError("no device \(n)") }
                return d
            }
            guard let d = devices.first(where: dflt) else { throw EngineError("no default device") }
            return d
        }
        let out = try pick("PC_OUT", \.defaultOutput)
        if env["PC_MIDI"] != nil { try midi(devices, out); return }
        let inp = try pick("PC_IN", \.defaultInput)
        let names = CommandLine.arguments.drop(while: { $0 != "--smoke" }).dropFirst()
        var units: [AVAudioUnit] = []
        var chain: [ChainItem] = []
        for n in names {
            guard let p = plugins.first(where: { $0.name == n || $0.id.subtype == n }) else { throw EngineError("no plugin \(n)") }
            let unit = try wait { try await Plugins.instantiate(p.id) }
            print("  \(p.name): \(Plugins.v2Parameters(unit.audioUnit).count) params; gain reduction meter: \(Plugins.gainReductionMeter(unit.audioUnit).map { "param \($0.id)" } ?? "none")")
            if env["PC_UI"] != nil {
                var size: UInt32 = 0
                var writable: DarwinBoolean = false
                let st = AudioUnitGetPropertyInfo(unit.audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable)
                print("    CocoaUI property: status \(st) size \(size)")
                if st == noErr, size > 0 {
                    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
                    defer { raw.deallocate() }
                    if AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr {
                        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
                        let url = info.mCocoaAUViewBundleLocation.takeUnretainedValue() as URL
                        let cls = info.mCocoaAUViewClass.takeUnretainedValue() as String
                        print("    UI bundle: \(url.path) class: \(cls)")
                        let bundle = Bundle(url: url)
                        var err: NSError?
                        let loaded = (try? bundle?.loadAndReturnError()) != nil
                        if let bundle, !loaded { do { try bundle.loadAndReturnError() } catch { err = error as NSError } }
                        print("    bundle loaded: \(loaded) \(err.map { "error: \($0)" } ?? "") class found: \(NSClassFromString(cls) != nil)")
                    }
                }
            }
            if env["PC_PARAMS"] != nil {
                for q in Plugins.v2Parameters(unit.audioUnit) {
                    print("    v2 \(q.id) '\(q.name)' flags=\(String(q.flags, radix: 16)) unit=\(q.unit) [\(q.min)...\(q.max)]")
                }
                for q in unit.auAudioUnit.parameterTree?.allParameters ?? [] {
                    print("    \(q.identifier) '\(q.displayName)' flags=\(String(q.flags.rawValue, radix: 16)) unit=\(q.unit.rawValue) [\(q.minValue)...\(q.maxValue)]")
                }
            }
            units.append(unit)
            chain.append(ChainItem(plugin: p.id, inputGainDb: -6))
        }
        let session = Session(
            input: Endpoint(deviceUid: inp.uid, channels: Array(0..<min(inp.inputChannels, 2))),
            output: Endpoint(deviceUid: out.uid, channels: Array(0..<min(out.outputChannels, 2))),
            chain: chain,
            bufferFrames: Int(env["PC_BUFFER"] ?? "") ?? 0
        )
        print("session: \(inp.name) \(session.input.channels) -> \(names.joined(separator: " -> ")) -> \(out.name) \(session.output.channels)")
        let stages = zip(units, chain).map { Engine.Stage(unit: $0.audioUnit, bypass: $1.bypass, gainDb: $1.inputGainDb) }
        let engine = try Engine(input: session.input, output: session.output, devices: devices, stages: stages, bufferFrames: session.bufferFrames)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        print("status:", engine.status)
        print("peaks per stage:", (0...units.count).map { engine.takePeaks($0) })
        if units.count >= 2 {
            engine.reorder(Array((0..<units.count).reversed()))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            print("reorder applied:", !engine.swapPending, "errors:", engine.status.renderErrors)
            engine.reorder(Array((0..<units.count).reversed()))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            print("reorder back applied:", !engine.swapPending, "errors:", engine.status.renderErrors)
        }
        _ = engine

        // Session round trip with plugin state.
        var saved = session
        for i in saved.chain.indices {
            if let st = units[i].auAudioUnit.fullState {
                saved.chain[i].state = try PropertyListSerialization.data(fromPropertyList: st, format: .binary, options: 0)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke.plainchain")
        try SessionFile.write(saved, to: url)
        let back = try SessionFile.read(url)
        print("round trip:", back == saved ? "ok" : "MISMATCH", "state bytes:", back.chain.map { $0.state?.count ?? 0 }, "file:", url.path)
        print("stopped cleanly")
        if env["PC_LISTEN"] != nil { try listen(out) }
    }

    /// `PC_MIDI=1`: a virtual MIDI source plays Apple's DLS synth, the chain
    /// head, into output channels 1-2 of `out`. Note 60 must sound at the
    /// instrument (stage 0 peaks) when sent from the source selected by its
    /// unique ID, from "all sources", and through the app's virtual
    /// destination; the destination must be ignored while one source is
    /// selected. Two effects follow the synth; reordering them live (the
    /// instrument stays at position 0) must keep the output sounding. Then a
    /// MIDI session round-trips through a file.
    private static func midi(_ devices: [Device], _ out: Device) throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("FAIL: watchdog: MIDI smoke still running after 60 s")
            _exit(1)
        }
        let input = MidiInput()
        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock("Plainchain smoke" as CFString, &client, nil), "MIDI client")
        var source = MIDIEndpointRef()
        try check(MIDISourceCreateWithProtocol(client, "Plainchain smoke" as CFString, ._1_0, &source), "virtual MIDI source")
        var sourceID: Int32 = 0
        try check(MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &sourceID), "source unique ID")
        var port = MIDIPortRef()
        try check(MIDIOutputPortCreate(client, "Plainchain smoke out" as CFString, &port), "MIDI output port")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        print("MIDI sources:", MidiInput.scan().map { "\($0.name) (\($0.uniqueID))" })

        let ids = [("dls ", "aumu"), ("dely", "aufx"), ("lpas", "aufx")].map { PluginId(type: $0.1, subtype: $0.0, manufacturer: "appl") }
        let units = try ids.map { id in try wait { try await Plugins.instantiate(id) } }
        let session = Session(
            input: Endpoint(deviceUid: "", channels: [], midiSource: "\(sourceID)", midiSourceName: "Plainchain smoke"),
            output: Endpoint(deviceUid: out.uid, channels: Array(0..<min(out.outputChannels, 2))),
            chain: ids.map { ChainItem(plugin: $0) }
        )
        let stages = zip(units, ids).map { Engine.Stage(unit: $0.audioUnit, bypass: false, gainDb: 0, isInstrument: $1.isInstrument) }
        var engine: Engine! = try Engine(input: session.input, output: session.output, devices: devices, stages: stages, midi: input.fanout)
        input.active = engine.midiRingCount
        print("session: MIDI \(sourceID) -> DLSMusicDevice -> AUDelay -> AULowpass -> \(out.name) \(session.output.channels); rings: \(engine.midiRingCount)")

        func send(_ word: UInt32, toDestination: Bool) {
            var list = MIDIEventList()
            var w = word
            withUnsafeMutablePointer(to: &list) { p in
                let packet = MIDIEventListInit(p, ._1_0)
                MIDIEventListAdd(p, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
                if toDestination { MIDISendEventList(port, input.destination, p) } else { MIDIReceivedEventList(source, p) }
            }
        }
        func run(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        /// The instrument's output level; the output stage's comes back in `lastOutput`.
        var lastOutput: Float = 0
        func peak() -> Float { lastOutput = engine.takePeaks(ids.count).max() ?? 0; return engine.takePeaks(0).max() ?? 0 }
        let noteOn: UInt32 = 0x2090_3C64, noteOff: UInt32 = 0x2080_3C00  // UMP MIDI 1.0, group 0, channel 1, note 60

        func play(_ label: String, selection: String, toDestination: Bool) throws {
            input.connect(selection)
            run(0.2)
            // Let the previous note die away, so this one is heard on its own.
            var quiet = false
            for _ in 0..<50 where !quiet { run(0.1); quiet = peak() < 0.001 }
            guard quiet else { throw EngineError("MIDI \(label): the instrument is still sounding before the note") }
            let before = input.received
            send(noteOn, toDestination: toDestination)
            run(1)
            let p = peak()
            send(noteOff, toDestination: toDestination)
            run(0.1)
            print(String(format: "MIDI %@: instrument peak %.3f, output peak %.3f, events received %u (total %u)", label, p, lastOutput, input.received &- before, input.received))
            guard p > 0.01 else { throw EngineError("MIDI \(label): no sound from the instrument") }
            guard lastOutput > 0.001 else { throw EngineError("MIDI \(label): no sound at the output") }
        }
        try play("by source ID", selection: "\(sourceID)", toDestination: false)
        try play("all sources", selection: "*", toDestination: false)
        try play("virtual destination", selection: "*", toDestination: true)
        engine.reorder([0, 2, 1])
        run(0.5)
        print("reorder (instrument, lowpass, delay) applied:", !engine.swapPending, "errors:", engine.status.renderErrors)
        try engine.setBypass(0, true)  // a no-op on the instrument
        try play("after reorder", selection: "*", toDestination: false)
        engine.reorder([1, 0, 2])  // would move the instrument: ignored
        print("reorder moving the instrument ignored:", !engine.swapPending)

        input.connect("\(sourceID)")
        run(0.2)
        let before = input.received
        send(noteOn, toDestination: true)
        run(0.5)
        send(noteOff, toDestination: true)
        run(0.1)
        print("MIDI virtual destination while one source is selected: events received \(input.received &- before)")
        guard input.received == before else { throw EngineError("the virtual destination was heard with a single source selected") }
        print("status:", engine.status)
        input.active = 0
        engine = nil  // tears down, uninitializing the plugins for the next graph
        withExtendedLifetime(units) {}  // the engine does not own its plugins

        // One output channel: the instrument still renders stereo; the converter downmixes.
        do {
            var mono = session
            mono.output.channels = [0]
            let engine = try Engine(input: mono.input, output: mono.output, devices: devices,
                                    stages: [Engine.Stage(unit: units[0].audioUnit, bypass: false, gainDb: 0, isInstrument: true)], midi: input.fanout)
            input.active = engine.midiRingCount
            input.connect("\(sourceID)")
            run(0.3)
            _ = engine.takePeaks(0); _ = engine.takePeaks(1)
            send(noteOn, toDestination: false)
            run(1)
            let inst = engine.takePeaks(0), outp = engine.takePeaks(1)
            send(noteOff, toDestination: false)
            run(0.1)
            input.active = 0
            print(String(format: "MIDI mono output: width %d, instrument peaks %@, output peak %.3f", engine.status.width,
                         inst.map { String(format: "%.3f", $0) }.joined(separator: "/"), outp.max() ?? 0))
            guard engine.status.width == 1, (outp.max() ?? 0) > 0.01 else { throw EngineError("MIDI mono output: no sound") }
            withExtendedLifetime(units) {}
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-midi.plainchain")
        try SessionFile.write(session, to: url)
        let back = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        print("MIDI session round trip:", back == session ? "ok" : "MISMATCH", "format version:", version)
        guard back == session, version == 2 else { throw EngineError("MIDI session did not round-trip") }
        try MainActor.assumeIsolated { try midiModel(url, source: source, sourceID: sourceID, session: session) }
        print("PASS")
    }

    /// The app model in MIDI mode: the empty-head hint, loading a MIDI session,
    /// playing it, switching sources without a rebuild, and refused moves.
    @MainActor
    private static func midiModel(_ url: URL, source: MIDIEndpointRef, sourceID: Int32, session: Session) throws {
        func run(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func until(_ what: String, _ seconds: Double, _ ok: () -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !ok() {
                guard Date() < deadline else { throw EngineError("model: \(what) (running \(model.status.running), error \(model.error ?? "nil"))") }
                run(0.05)
            }
        }
        func send(_ word: UInt32) {
            var list = MIDIEventList()
            var w = word
            withUnsafeMutablePointer(to: &list) { p in
                MIDIEventListAdd(p, MemoryLayout<MIDIEventList>.size, MIDIEventListInit(p, ._1_0), 0, 1, &w)
                MIDIReceivedEventList(source, p)
            }
        }
        let model = Model(ephemeral: true)
        model.update { $0.output = session.output; $0.input.midiSource = "\(sourceID)"; $0.input.midiSourceName = "Plainchain smoke" }
        try until("no instrument hint", 3) { model.status.running && model.error == nil && model.hint == "Add an instrument to play MIDI into" }
        print("model: MIDI input with no instrument runs silent with the hint")

        try wait { await model.open(url, quietly: false) }
        try until("MIDI session running", 3) { model.status.running && model.error == nil && model.hint == nil && model.session.chain.count == 3 }
        let head = model.session.chain[0].id
        func played(_ label: String) throws {
            try until("\(label): quiet", 5) { (model.levels.peaks[head]?.max() ?? 1) < 0.001 }
            send(0x2090_3C64)
            try until("\(label): instrument meter", 2) { (model.levels.peaks[head]?.max() ?? 0) > 0.01 && model.levels.midiActive }
            send(0x2080_3C00)
            print("model: \(label): instrument meter \(String(format: "%.3f", model.levels.peaks[head]?.max() ?? 0)), activity light on")
        }
        try played("loaded session")
        var flips = 0
        let watch = model.$status.map(\.running).removeDuplicates().dropFirst().sink { _ in flips += 1 }
        model.update { $0.input.midiSource = "*"; $0.input.midiSourceName = MidiInput.allSourcesName }
        try played("switched to all sources")
        // A note held on the source being left is released by the switch.
        try until("quiet before held note", 5) { (model.levels.peaks[head]?.max() ?? 1) < 0.001 }
        send(0x2090_3C64)  // no note-off follows
        try until("held note sounding", 2) { (model.levels.peaks[head]?.max() ?? 0) > 0.01 }
        run(0.5)
        let t0 = Date()
        model.update { $0.input.midiSource = "\(sourceID)"; $0.input.midiSourceName = "Plainchain smoke" }
        try until("held note released by the source switch", 3) { (model.levels.peaks[head]?.max() ?? 1) < 0.001 }
        print(String(format: "model: held note silent %.0f ms after a source switch", Date().timeIntervalSince(t0) * 1000))
        _ = watch
        guard flips == 0 else { throw EngineError("model: switching MIDI sources restarted the engine") }
        print("model: source switch reconnected without a rebuild")

        let order = model.session.chain.map(\.id)
        model.move(from: [1], to: 0)
        model.move(from: [0], to: 3)
        guard model.session.chain.map(\.id) == order else { throw EngineError("model: a move displaced the instrument") }
        model.move(from: [2], to: 1)
        guard model.session.chain.map(\.id) == [order[0], order[2], order[1]] else { throw EngineError("model: effects did not reorder") }
        print("model: moves that displace the instrument refused; effects reorder")

        model.remove(at: [0])
        try until("instrument removed", 3) { model.session.chain.count == 2 && model.hint == "Add an instrument to play MIDI into" && model.session.input.isMidi }
        print("model: removing the instrument leaves MIDI input with an empty head")
        model.enabled = false
        run(0.2)
    }

    /// Device-list listener check: create and destroy aggregates and see the
    /// callback arrive on the main queue. A public one must fire it; a private
    /// one is reported, along with whether it shows up in our own device list.
    private static func listen(_ out: Device) throws {
        var fired = 0
        let listener = try HAL.listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
            precondition(Thread.isMainThread, "listener called off the main thread")
            fired += 1
        }
        let description: [String: Any] = [
            "name": "Plainchain smoke",
            "uid": "com.plainchain.smoke." + UUID().uuidString,
            "private": 0,
            "subdevices": [["uid": out.uid]],
        ]
        var id: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "create public aggregate")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let created = fired
        AudioHardwareDestroyAggregateDevice(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        print("listener: public aggregate create fired \(created), destroy fired \(fired - created)")

        let before = fired
        let priv = try HAL.createAggregate(input: out, output: out)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        let listed = try HAL.devices().contains { $0.uid.hasPrefix(HAL.aggregatePrefix) }
        HAL.destroyAggregate(priv)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        print("listener: private aggregate fired \(fired - before), in our device list: \(listed)")
        _ = listener
        guard created > 0 else { throw EngineError("device-list listener never fired") }
    }

    /// Block the main thread on an async call while servicing the run loop.
    private static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { result = await Result { try await body() } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }
}
