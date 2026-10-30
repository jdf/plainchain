import AVFoundation
import CapnSession
import ClapHost
import Combine
import CoreMIDI
import Foundation

/// `Plainchain --smoke [PC_IN=name] [PC_OUT=name] [plugin names...]`
/// Headless check: lists devices and plugins (CLAP plugins registered first),
/// builds the chain, runs it for two seconds, round-trips a session file and
/// checks the records (see `records`), runs the chain to None output
/// (see `none`), and runs it with a MIDI source beside the device input (see
/// `both`). A plugin is named by its name, its subtype, or its CLAP id; an
/// instrument among them heads the chain, and a note pushed into its MIDI
/// ring must sound. Exits nonzero on failure.
/// With `PC_MIDI=1` it checks MIDI input instead (see `midi`).
enum Smoke {
    /// The CLAP instrument the MIDI smoke plays when it is installed.
    static let nfp5 = "studio.whatissoftware.nfp5"

    static func run() {
        finish { try go() }
    }

    /// Runs a check, then deinitializes the CLAP bundles once its plugins are
    /// gone (the pool drained), and exits: nonzero when the check failed.
    private static func finish(_ check: () throws -> Void) -> Never {
        var failed = false
        do { try autoreleasepool { try check() } } catch { print("FAIL: \(error.localizedDescription)"); failed = true }
        print(Plugins.shutdownClap())
        exit(failed ? 1 : 0)
    }

    private static func go() throws {
        let env = ProcessInfo.processInfo.environment
        let devices = try HAL.devices()
        for d in devices {
            print(String(format: "%4d in %2d out %2d @%6.0f %@%@ %@", d.id, d.inputChannels, d.outputChannels, d.sampleRate,
                         d.defaultInput ? "I" : " ", d.defaultOutput ? "O" : " ", d.name))
        }
        Plugins.registerClap()
        let plugins = Plugins.installed()
        print("\(plugins.count) plugins, \(plugins.filter(\.id.isClap).count) of them CLAP")
        func pick(_ key: String, _ dflt: (Device) -> Bool) throws -> Device {
            if let n = env[key] {
                guard let d = devices.first(where: { $0.name.contains(n) }) else { throw EngineError("no device \(n)") }
                return d
            }
            guard let d = devices.first(where: dflt) else { throw EngineError("no default device") }
            return d
        }
        let out = try pick("PC_OUT", \.defaultOutput)
        if env["PC_MIDI"] != nil { try midi(devices, out, clap: plugins.first { $0.id.clapId == nfp5 }); return }
        let inp = try pick("PC_IN", \.defaultInput)
        let names = CommandLine.arguments.drop(while: { $0 != "--smoke" }).dropFirst()
        var units: [PluginInstance] = []
        var chain: [ChainItem] = []
        /// The plugins' names, in chain order.
        var labels: [String] = []
        for n in names {
            guard let p = plugins.first(where: { $0.name == n || $0.id.subtype == n || $0.id.clapId == n }) else { throw EngineError("no plugin \(n)") }
            let unit = try wait { try await PluginInstance.make(p.id) }
            let format = p.id.isClap ? "CLAP \(p.id.clapId) from \(p.id.clapPath) as \(p.id.type)" : p.id.type
            print("  \(p.name) (\(format)): \(describe(unit)); \(unit.parameterNames.count) params; gain reduction meter: \(Plugins.gainReductionMeter(unit.audioUnit).map { "param \($0.id)" } ?? "none")")
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
                for q in unit.avUnit?.auAudioUnit.parameterTree?.allParameters ?? [] {
                    print("    \(q.identifier) '\(q.displayName)' flags=\(String(q.flags.rawValue, radix: 16)) unit=\(q.unit.rawValue) [\(q.minValue)...\(q.maxValue)]")
                }
            }
            units.append(unit)
            chain.append(ChainItem(plugin: p.id, inputGainDb: -6))
            labels.append(p.name)
        }
        // An instrument heads the chain, as the app puts it there; the smoke takes one.
        let instruments = chain.indices.filter { chain[$0].plugin.isInstrument }
        guard instruments.count <= 1 else { throw EngineError("the smoke takes one instrument, not \(instruments.count)") }
        if let i = instruments.first, i != 0 {
            units.insert(units.remove(at: i), at: 0)
            chain.insert(chain.remove(at: i), at: 0)
            labels.insert(labels.remove(at: i), at: 0)
        }
        let instrumentHead = !instruments.isEmpty
        // In and out on one device with room to spare: out on 3-4, so a loopback device
        // (BlackHole in the test VM) does not feed the output back into the input.
        let outFirst: UInt32 = inp.uid == out.uid && out.outputChannels >= 4 ? 2 : 0
        let session = Session(
            input: Endpoint(deviceUid: inp.uid, channels: Array(0..<min(inp.inputChannels, 2))),
            output: Endpoint(deviceUid: out.uid, channels: Array(outFirst..<outFirst + min(out.outputChannels, 2))),
            chain: chain,
            bufferFrames: Int(env["PC_BUFFER"] ?? "") ?? 0
        )
        print("session: \(inp.name) \(session.input.channels) -> \(labels.joined(separator: " -> ")) -> \(out.name) \(session.output.channels)")
        // An instrument at the head is played by a note pushed straight into its MIDI ring.
        let fanout = pc_midi_fanout_new()!
        var engine: Engine! = try Engine(input: session.input, output: session.output, devices: devices, stages: engineStages(units, chain),
                                         bufferFrames: session.bufferFrames, midi: fanout)
        if instrumentHead {
            pc_store_u32(&fanout.pointee.active, UInt32(engine.midiRingCount))
            pc_midi_fanout_push(fanout, 0x90_3C64)  // note on, channel 1, note 60, velocity 100
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        print("status:", engine.status)
        let peaks = (0...units.count).map { engine.takePeaks($0) }
        print("peaks per stage:", peaks)
        if instrumentHead {
            pc_midi_fanout_push(fanout, 0x80_3C00)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            pc_store_u32(&fanout.pointee.active, 0)
            // The device input goes into the instrument's input bus; with none, it is unused.
            var buses: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioUnitGetProperty(units[0].audioUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &buses, &size) != noErr { buses = 0 }
            let peak = peaks[0].max() ?? 0
            print(String(format: "instrument %@ at the head: %u input buses, audio input unused %@, MIDI rings %d, a note into its ring peaked at %.3f, errors %d",
                         labels[0], buses, engine.audioInputUnused ? "yes" : "no", engine.midiRingCount, peak, engine.status.renderErrors))
            guard engine.audioInputUnused == (buses == 0), engine.midiRingCount >= 1, peak > 0.01, engine.status.renderErrors == 0 else {
                throw EngineError("the instrument \(labels[0]) did not play at the head of the chain")
            }
        }
        // A reorder moves the effects; an instrument stays at the head.
        let head = instrumentHead ? 1 : 0
        if units.count - head >= 2 {
            let order = Array(0..<head) + Array((head..<units.count).reversed())
            engine.reorder(order)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            print("reorder applied:", !engine.swapPending, "errors:", engine.status.renderErrors)
            engine.reorder(order)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            print("reorder back applied:", !engine.swapPending, "errors:", engine.status.renderErrors)
        }
        engine = nil

        // Session round trip with plugin state.
        var saved = session
        for i in saved.chain.indices { saved.chain[i].state = units[i].state }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke.plainchain")
        try SessionFile.write(saved, to: url)
        let back = try SessionFile.read(url)
        print("round trip:", back == saved ? "ok" : "MISMATCH", "state bytes:", back.chain.map { $0.state?.count ?? 0 }, "file:", url.path)
        try records()
        // The state loads into a fresh instance and reads back the same, without counting as a change.
        for (i, item) in back.chain.enumerated() {
            guard let data = item.state else { continue }
            let fresh = try wait { try await PluginInstance.make(item.plugin) }
            fresh.state = data
            var changes = 0
            fresh.onChange = { changes += 1 }
            fresh.startObserving()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            // Compared as dictionaries: binary plists of equal dictionaries can order their keys differently.
            func dict(_ d: Data?) -> NSDictionary? { d.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary } }
            let same = dict(fresh.state).map { $0.isEqual(dict(data)) } ?? false
            print("  state into a fresh \(labels[i]): reads back \(same ? "the same" : "DIFFERENT"), changes signalled: \(changes)")
            guard same, changes == 0 else { throw EngineError("plugin state did not round-trip quietly") }
            // A parameter edit through the AU parameter API is signalled.
            if let p = Plugins.v2Parameters(fresh.audioUnit).first(where: { AudioUnitParameterOptions(rawValue: $0.flags).contains(.flag_IsWritable) }) {
                var v: AudioUnitParameterValue = 0
                AudioUnitGetParameter(fresh.audioUnit, p.id, kAudioUnitScope_Global, 0, &v)
                var param = AudioUnitParameter(mAudioUnit: fresh.audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
                AUParameterSet(nil, nil, &param, v == p.min ? p.max : p.min, 0)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
                print("  parameter '\(p.name)' set: changes signalled: \(changes)")
                guard changes > 0 else { throw EngineError("a parameter change was not signalled") }
            }
        }
        try none(devices, inp, units, chain)
        try both(devices, inp, out, units, chain, instrument: try env["PC_INSTRUMENT"].map { n in
            guard let p = plugins.first(where: { $0.isInstrument && ($0.name == n || $0.id.subtype == n) }) else { throw EngineError("no instrument \(n)") }
            return p
        })
        print("stopped cleanly")
        if env["PC_LISTEN"] != nil { try listen(out) }
    }

    /// `Plainchain --records-test`: `records` alone, which opens no device, so
    /// it runs on the host; there, with no scan before it, the CLAP plugin it
    /// reopens is registered from the chain item's bundle path. Exits nonzero on failure.
    static func runRecords() {
        finish { try records() }
    }

    /// The session records, with no device: a chain item naming a CLAP plugin
    /// by id and path round-trips at format version 5, and a file newer than
    /// `SessionFile.formatVersion` is refused, as a version 5 file is by a
    /// reader whose `formatVersion` is 4. Then reopening such an item: one
    /// whose bundle is gone is "not installed"; one naming nfp5 in the user's
    /// CLAP directory, when it is installed there, is made from the registry,
    /// registering the bundle from the item's path when the registry lacks it.
    /// The item's component description is a placeholder: the CLAP id decides.
    static func records() throws {
        let clap = PluginId(type: "aumu", subtype: "test", manufacturer: "test",
                            clapId: "studio.whatissoftware.nfp5", clapPath: "/Library/Audio/Plug-Ins/CLAP/nfp5.clap")
        let session = Session(input: .none, output: .none, chain: [ChainItem(plugin: clap, inputGainDb: -3)])
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("smoke-clap.plainchain")
        try SessionFile.write(session, to: url)
        let back = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        print("CLAP session round trip:", back == session ? "ok" : "MISMATCH", "format version:", version,
              "clap id:", back.chain.first?.plugin.clapId ?? "", "path:", back.chain.first?.plugin.clapPath ?? "")
        guard back == session, version == 5 else { throw EngineError("CLAP session did not round-trip at version 5") }
        // A reader refuses a file newer than its formatVersion: a copy one past this app's version stands for a version 5 file under a version 4 reader.
        let newer = dir.appendingPathComponent("smoke-clap-newer.plainchain")
        try? FileManager.default.removeItem(at: newer)
        try FileManager.default.copyItem(at: url, to: newer)
        defer { try? FileManager.default.removeItem(at: newer) }
        try DB(newer, create: false).exec("PRAGMA user_version = \(SessionFile.formatVersion + 1)")
        do {
            _ = try SessionFile.read(newer)
            throw EngineError("a session at format \(SessionFile.formatVersion + 1) was read by a format \(SessionFile.formatVersion) reader")
        } catch let e as EngineError where e.message.contains("newer than this app understands") {
            print("  at format \(SessionFile.formatVersion + 1) under format \(SessionFile.formatVersion): refused (\(e.message))")
        }

        let gone = PluginId(type: "aumu", subtype: "test", manufacturer: "test",
                            clapId: "studio.whatissoftware.absent", clapPath: dir.appendingPathComponent("absent.clap").path)
        do {
            _ = try wait { try await PluginInstance.make(gone) }
            throw EngineError("a CLAP plugin whose bundle is gone was made")
        } catch let e as EngineError where e.message == "absent: CLAP plugin not installed" {
            print("  reopening a CLAP item whose bundle is gone: \(e.message)")
        }
        let bundle = Plugins.standardClapDirectories[0] + "/nfp5.clap"
        guard FileManager.default.fileExists(atPath: bundle) else {
            print("  nfp5 is not installed at \(bundle); the reopen check is skipped")
            return
        }
        let registered = Plugins.registeredClap(nfp5) != nil
        let item = PluginId(type: "aumu", subtype: "test", manufacturer: "test", clapId: nfp5, clapPath: bundle)
        let unit = try wait { try await PluginInstance.make(item) }
        print("  reopening a CLAP item naming \(bundle), \(registered ? "registered by the scan" : "not registered: registered from its path"): "
              + "\(unit.id.type) \(unit.id.subtype) \(unit.id.manufacturer) from \(unit.id.clapPath), \(describe(unit))")
        guard unit.isV3, unit.id.clapId == nfp5, unit.id.clapPath == bundle, unit.id.isInstrument, Plugins.registeredClap(nfp5) == unit.id else {
            throw EngineError("a CLAP item did not reopen as the registered plugin")
        }
    }

    /// Audio and MIDI together: a device input with a MIDI source builds and
    /// runs, with a ring per plugin that takes MIDI (the chain's instrument
    /// and music effects; none of Apple's effects take it); unless the chain
    /// has an instrument of its own, Apple's DLS synth heads it beside the
    /// device input, which it has no bus for, so the engine reports the audio
    /// input unused; `instrument` (`PC_INSTRUMENT`, one with an input bus,
    /// such as a vocoder) takes the device input on that bus; the session
    /// round-trips at format version 4 (5 with a CLAP plugin), and the same
    /// records under an older version read as MIDI instead of audio.
    private static func both(_ devices: [Device], _ inp: Device, _ out: Device, _ units: [PluginInstance], _ chain: [ChainItem], instrument: Plugin?) throws {
        let input = Endpoint(deviceUid: inp.uid, channels: Array(0..<min(inp.inputChannels, 2)), midiSource: "*", midiSourceName: MidiInput.allSourcesName)
        let outFirst: UInt32 = inp.uid == out.uid && out.outputChannels >= 4 ? 2 : 0
        let output = Endpoint(deviceUid: out.uid, channels: Array(outFirst..<outFirst + min(out.outputChannels, 2)))
        let fanout = pc_midi_fanout_new()!
        let musicEffects = units.filter { $0.id.type == "aumf" }.count
        let ownInstrument = chain.first?.plugin.isInstrument == true
        do {
            let engine = try Engine(input: input, output: output, devices: devices, stages: engineStages(units, chain), midi: fanout)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let s = engine.status
            let receivers = musicEffects + (ownInstrument ? 1 : 0)
            print("Audio and MIDI: \(inp.name) + MIDI -> \(chain.count) plugins -> \(out.name): rings \(engine.midiRingCount) for \(receivers) instruments and music effects, audio input unused \(engine.audioInputUnused), errors \(s.renderErrors)")
            guard engine.midiRingCount == receivers, s.renderErrors == 0 else { throw EngineError("Audio and MIDI: the chain did not run with both") }
        }
        var dls: PluginInstance?
        if ownInstrument {
            print("Audio and MIDI: the chain has its own instrument at the head; no DLS synth is put before it")
        } else {
            let synth = try wait { try await PluginInstance.make(PluginId(type: "aumu", subtype: "dls ", manufacturer: "appl")) }
            dls = synth
            let stages = [Engine.Stage(unit: synth.audioUnit, bypass: false, gainDb: 0, isInstrument: true)] + engineStages(units, chain)
            let engine = try Engine(input: input, output: output, devices: devices, stages: stages, midi: fanout)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            let s = engine.status
            print("Audio and MIDI: \(inp.name) + MIDI -> DLSMusicDevice -> \(chain.count) plugins -> \(out.name): rings \(engine.midiRingCount), audio input unused \(engine.audioInputUnused), errors \(s.renderErrors)")
            guard engine.audioInputUnused, engine.midiRingCount == 1 + musicEffects, s.renderErrors == 0 else {
                throw EngineError("Audio and MIDI: the DLS synth did not run beside the device input with it unused")
            }
        }
        if let instrument {
            // An instrument with an input bus: the device input goes into it.
            let unit = try wait { try await PluginInstance.make(instrument.id) }
            let engine = try Engine(input: input, output: output, devices: devices,
                                    stages: [Engine.Stage(unit: unit.audioUnit, bypass: false, gainDb: 0, isInstrument: true, owner: unit)], midi: fanout)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let s = engine.status
            print("Audio and MIDI: \(inp.name) + MIDI -> \(instrument.name) -> \(out.name): rings \(engine.midiRingCount), audio input unused \(engine.audioInputUnused), width \(s.width), errors \(s.renderErrors)")
            guard !engine.audioInputUnused, engine.midiRingCount == 1, s.renderErrors == 0 else {
                throw EngineError("Audio and MIDI: \(instrument.name) did not take the device input")
            }
        }
        withExtendedLifetime(units) {}
        withExtendedLifetime(dls) {}
        let session = Session(input: input, output: output, chain: chain)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-both.plainchain")
        try SessionFile.write(session, to: url)
        var back = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        let expected = chain.contains { $0.plugin.isClap } ? 5 : 4  // a CLAP plugin outranks audio and MIDI together
        print("Audio and MIDI session round trip:", back == session ? "ok" : "MISMATCH", "format version:", version)
        guard back == session, version == expected else { throw EngineError("Audio and MIDI session did not round-trip at version \(expected)") }
        // The same records under an older version: a MIDI source then meant no audio input.
        try DB(url, create: false).exec("PRAGMA user_version = 2")
        back = try SessionFile.read(url)
        print("  read as version 2: input \(back.input.isNone ? "None" : back.input.deviceUid), MIDI \(back.input.midiSource)")
        guard back.input == .midi("*", name: MidiInput.allSourcesName) else { throw EngineError("a pre-4 MIDI session did not read as MIDI without audio") }
    }

    /// None output: the input device clocks a chain that goes nowhere. Then
    /// None input too: with no device at all the timer clocks it, at its own
    /// rate, and follows a buffer size change live. Neither may have render
    /// errors. A None session round-trips at format version 3, or 5 with a CLAP plugin.
    private static func none(_ devices: [Device], _ inp: Device, _ units: [PluginInstance], _ chain: [ChainItem]) throws {
        let stages = engineStages(units, chain)
        let input = Endpoint(deviceUid: inp.uid, channels: Array(0..<min(inp.inputChannels, 2)))
        do {
            let engine = try Engine(input: input, output: .none, devices: devices, stages: stages)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let s = engine.status
            print("None output: \(inp.name) -> \(chain.count) plugins -> none: \(engine.sinkCycles) cycles in 1 s at \(s.bufferFrames) frames, "
                + "errors \(s.renderErrors), output latency \(s.outputLatencyFrames)")
            guard engine.sinkCycles > 0, s.renderErrors == 0, s.outputLatencyFrames == 0 else {
                throw EngineError("None output: the input device did not pull the chain cleanly")
            }
        }
        do {
            let engine = try Engine(input: .none, output: .none, devices: devices, stages: stages)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let s = engine.status
            let first = engine.sinkCycles
            print("No device: none -> \(chain.count) plugins -> none: \(first) cycles in 1 s at \(s.bufferFrames) frames, \(Int(s.sampleRate)) Hz, errors \(s.renderErrors)")
            func near(_ cycles: UInt64, _ frames: Int) -> Bool {
                let expected = Engine.clockSampleRate / Double(frames)
                return Double(cycles) > expected * 0.8 && Double(cycles) < expected * 1.2
            }
            guard s.sampleRate == Engine.clockSampleRate, s.bufferFrames == 512, s.width == 2, near(first, 512), s.renderErrors == 0 else {
                throw EngineError("No device: the clock did not run at its rate")
            }
            try engine.setBufferSize(128)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            let second = engine.sinkCycles - first
            print("  at 128 frames: \(second) cycles in 1 s, errors \(engine.status.renderErrors)")
            guard engine.status.bufferFrames == 128, near(second, 128), engine.status.renderErrors == 0 else {
                throw EngineError("No device: the clock did not follow the buffer size")
            }
        }
        withExtendedLifetime(units) {}
        let session = Session(input: .none, output: .none, chain: chain)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-none.plainchain")
        try SessionFile.write(session, to: url)
        let back = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        let expected = chain.contains { $0.plugin.isClap } ? 5 : 3  // a CLAP plugin outranks None
        print("None session round trip:", back == session ? "ok" : "MISMATCH", "format version:", version)
        guard back == session, version == expected else { throw EngineError("None session did not round-trip at version \(expected)") }
    }

    /// `PC_MIDI=1`: a virtual MIDI source plays Apple's DLS synth, the chain
    /// head, into output channels 1-2 of `out`. Note 60 must sound at the
    /// instrument (stage 0 peaks) when sent from the source selected by its
    /// unique ID, from "all sources", and through the app's virtual
    /// destination; the destination must be ignored while one source is
    /// selected. Two effects follow the synth; reordering them live (the
    /// instrument stays at position 0) must keep the output sounding. Then
    /// the None endpoints, a MIDI source beside a device input, and a MIDI
    /// session round-tripping through a file. When `clap` (nfp5) is installed,
    /// it heads the chain in place of the DLS synth for one more pass, and
    /// the app model adds it, plays it, saves it, and reopens it.
    private static func midi(_ devices: [Device], _ out: Device, clap: Plugin?) throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("FAIL: watchdog: MIDI smoke still running after 60 s")
            _exit(1)
        }
        let system = MidiSystem()
        let input = MidiInput(system: system)
        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock("Plainchain smoke" as CFString, &client, nil), "MIDI client")
        var source = MIDIEndpointRef()
        try check(MIDISourceCreateWithProtocol(client, "Plainchain smoke" as CFString, ._1_0, &source), "virtual MIDI source")
        var sourceID: Int32 = 0
        try check(MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &sourceID), "source unique ID")
        var port = MIDIPortRef()
        try check(MIDIOutputPortCreate(client, "Plainchain smoke out" as CFString, &port), "MIDI output port")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        print("MIDI sources:", MidiSystem.scan().map { "\($0.name) (\($0.uniqueID))" })

        let ids = [("dls ", "aumu"), ("dely", "aufx"), ("lpas", "aufx")].map { PluginId(type: $0.1, subtype: $0.0, manufacturer: "appl") }
        let units = try ids.map { id in try wait { try await PluginInstance.make(id) } }
        for u in units { print("  \(u.id.subtype): \(describe(u))") }
        let session = Session(
            input: .midi("\(sourceID)", name: "Plainchain smoke"),
            output: Endpoint(deviceUid: out.uid, channels: Array(0..<min(out.outputChannels, 2))),
            chain: ids.map { ChainItem(plugin: $0) }
        )
        let stages = zip(units, ids).map { Engine.Stage(unit: $0.audioUnit, bypass: false, gainDb: 0, isInstrument: $1.isInstrument, owner: $0) }
        var engine: Engine! = try Engine(input: session.input, output: session.output, devices: devices, stages: stages, midi: input.fanout)
        input.active = engine.midiRingCount
        print("session: MIDI \(sourceID) -> DLSMusicDevice -> AUDelay -> AULowpass -> \(out.name) \(session.output.channels); rings: \(engine.midiRingCount)")

        func send(_ word: UInt32, toDestination: Bool) {
            var list = MIDIEventList()
            var w = word
            withUnsafeMutablePointer(to: &list) { p in
                let packet = MIDIEventListInit(p, ._1_0)
                MIDIEventListAdd(p, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
                if toDestination { MIDISendEventList(port, system.destination, p) } else { MIDIReceivedEventList(source, p) }
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

        // A CLAP instrument in place of the DLS synth: the source's note reaches it through
        // its ring, MusicDeviceMIDIEvent, and the bridge, which sends it CLAP note events.
        if let clap {
            let synth = try wait { try await PluginInstance.make(clap.id) }
            print("  \(clap.name) (CLAP \(clap.id.clapId)): \(describe(synth))")
            let stages = [Engine.Stage(unit: synth.audioUnit, bypass: false, gainDb: 0, isInstrument: true, owner: synth)]
                + units.dropFirst().map { Engine.Stage(unit: $0.audioUnit, bypass: false, gainDb: 0, owner: $0) }
            engine = try Engine(input: session.input, output: session.output, devices: devices, stages: stages, midi: input.fanout)
            input.active = engine.midiRingCount
            try play("\(clap.name) (CLAP) by source ID", selection: "\(sourceID)", toDestination: false)
            run(0.2)
            var info = pc_clap_unit_info()
            guard let av = synth.avUnit, pc_clap_unit_read_info(Unmanaged.passUnretained(av.auAudioUnit).toOpaque(), &info) else {
                throw EngineError("MIDI: \(clap.name) is not a bridged CLAP plugin")
            }
            print("  \(clap.name): MIDI render events \(info.midi_render_events), CLAP note events \(info.note_events), dropped \(info.dropped_events), render errors \(engine.status.renderErrors)")
            guard info.midi_render_events >= 2, info.note_events >= 2, info.dropped_events == 0, engine.status.renderErrors == 0 else {
                throw EngineError("MIDI: the note did not reach \(clap.name) as CLAP note events")
            }
            input.active = 0
            engine = nil
            withExtendedLifetime(units) {}
        } else {
            print("MIDI: nfp5 (CLAP) is not installed; the pass with it at the head is skipped")
        }

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

        // No device at all: MIDI into the instrument, out to nothing; the timer clocks it.
        do {
            let engine = try Engine(input: session.input, output: .none, devices: devices,
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
            let s = engine.status
            print(String(format: "MIDI with None output: %d cycles at %d frames, %d Hz, width %d, instrument peaks %@, sink peak %.3f, errors %d",
                         engine.sinkCycles, s.bufferFrames, Int(s.sampleRate), s.width,
                         inst.map { String(format: "%.3f", $0) }.joined(separator: "/"), outp.max() ?? 0, s.renderErrors))
            guard s.sampleRate == Engine.clockSampleRate, s.width == 2, engine.sinkCycles > 0, (outp.max() ?? 0) > 0.01, s.renderErrors == 0 else {
                throw EngineError("MIDI with None output: the note did not reach the sink")
            }
            withExtendedLifetime(units) {}
        }

        // None input with an instrument and no MIDI source: it has its ring, nothing feeds it, silence.
        do {
            let engine = try Engine(input: .none, output: session.output, devices: devices,
                                    stages: [Engine.Stage(unit: units[0].audioUnit, bypass: false, gainDb: 0, isInstrument: true)], midi: input.fanout)
            run(0.5)
            let outp = engine.takePeaks(1)
            print(String(format: "None input with an instrument: rings %d, output peak %.3f, errors %d", engine.midiRingCount, outp.max() ?? 0, engine.status.renderErrors))
            guard engine.midiRingCount == 1, (outp.max() ?? 0) < 0.001, engine.status.renderErrors == 0 else {
                throw EngineError("None input with an instrument: did not run silent")
            }
            withExtendedLifetime(units) {}
        }

        // A device input with a MIDI source: the effects run on the device, with no ring (none takes MIDI).
        if out.inputChannels >= 2 {
            let both = Endpoint(deviceUid: out.uid, channels: [0, 1], midiSource: "\(sourceID)", midiSourceName: "Plainchain smoke")
            do {
                let engine = try Engine(input: both, output: session.output, devices: devices,
                                        stages: units.dropFirst().map { Engine.Stage(unit: $0.audioUnit, bypass: false, gainDb: 0) }, midi: input.fanout)
                run(0.5)
                print("Audio and MIDI: \(out.name) 1-2 + MIDI -> AUDelay -> AULowpass -> \(out.name): rings \(engine.midiRingCount), width \(engine.status.width), errors \(engine.status.renderErrors)")
                guard engine.midiRingCount == 0, engine.status.width == 2, engine.status.renderErrors == 0 else {
                    throw EngineError("Audio and MIDI: the effects did not run on the device")
                }
                withExtendedLifetime(units) {}
            }  // torn down here, so the effects are free for the next graph
            // The instrument at the head beside the device input: it has no input bus, so the
            // device input is unused, but the MIDI still plays it through the effects.
            let withInstrument = try Engine(input: both, output: session.output, devices: devices, stages: stages, midi: input.fanout)
            input.active = withInstrument.midiRingCount
            input.connect("\(sourceID)")
            run(0.3)
            _ = withInstrument.takePeaks(0); _ = withInstrument.takePeaks(ids.count)
            send(noteOn, toDestination: false)
            run(1)
            let inst = withInstrument.takePeaks(0), outp = withInstrument.takePeaks(ids.count)
            send(noteOff, toDestination: false)
            run(0.1)
            input.active = 0
            print(String(format: "Audio and MIDI: %@ 1-2 + MIDI -> DLSMusicDevice -> AUDelay -> AULowpass: rings %d, audio input unused %@, width %d, instrument peak %.3f, output peak %.3f, errors %d",
                         out.name, withInstrument.midiRingCount, withInstrument.audioInputUnused ? "yes" : "no", withInstrument.status.width,
                         inst.max() ?? 0, outp.max() ?? 0, withInstrument.status.renderErrors))
            guard withInstrument.midiRingCount == 1, withInstrument.audioInputUnused, withInstrument.status.width == 2,
                  (inst.max() ?? 0) > 0.01, (outp.max() ?? 0) > 0.001, withInstrument.status.renderErrors == 0 else {
                throw EngineError("Audio and MIDI: the instrument did not play beside the device input")
            }
            withExtendedLifetime(units) {}
        } else {
            print("Audio and MIDI: \(out.name) has no inputs; skipping the engine check")
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-midi.plainchain")
        try SessionFile.write(session, to: url)
        let back = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        print("MIDI session round trip:", back == session ? "ok" : "MISMATCH", "format version:", version)
        guard back == session, version == 2 else { throw EngineError("MIDI session did not round-trip") }
        try MainActor.assumeIsolated { try midiModel(url, system: system, source: source, sourceID: sourceID, session: session, out: out, clap: clap) }
        print("PASS")
    }

    /// The app model with MIDI: the unused-MIDI hint, loading a MIDI session,
    /// playing it, switching sources (and off) without a rebuild, refused
    /// moves, the None endpoints, and a MIDI source beside a device input.
    /// With `clap`, the CLAP instrument is added from the model's plugin list,
    /// plays, is saved with a parameter changed, and reopens with it.
    @MainActor
    private static func midiModel(_ url: URL, system: MidiSystem, source: MIDIEndpointRef, sourceID: Int32, session: Session, out: Device, clap: Plugin?) throws {
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
        let model = Model(app: AppState(ephemeral: true, midi: system), ephemeral: true)
        model.update { $0.output = session.output; $0.input.midiSource = "\(sourceID)"; $0.input.midiSourceName = "Plainchain smoke" }
        try until("unused MIDI hint", 3) { model.status.running && model.error == nil && model.hint == Model.midiUnusedHint }
        print("model: a MIDI source with nothing to play runs with the hint (audio input \(model.session.input.isDevice ? "device" : "None"))")

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
        try until("held note released by the source switch", 6) { (model.levels.peaks[head]?.max() ?? 1) < 0.001 }
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
        try until("instrument removed", 3) { model.session.chain.count == 2 && model.hint == Model.midiUnusedHint && model.session.input.hasMidi }
        print("model: removing the instrument leaves the MIDI source unused, with the hint")
        try wait { await model.open(url, quietly: false) }
        try until("MIDI session reloaded", 3) { model.status.running && model.session.chain.count == 3 && !model.dirty }
        run(0.5)  // let any plugin notifications from loading state and building the graph arrive
        guard !model.dirty, !model.hasUnsavedChanges, !model.needsSavePrompt else {
            throw EngineError("model: loading a session marked it edited (dirty \(model.dirty), unsaved \(model.hasUnsavedChanges), prompt \(model.needsSavePrompt))")
        }
        print("model: loading the session and building the graph left it unedited")
        // A parameter changed as an editor would change it marks the session edited. Done
        // last, on a fresh load (the checks above edited the session), so the MIDI timing is undisturbed.
        guard let effect = model.instance(for: model.session.chain[1].id),
              let p = Plugins.v2Parameters(effect.audioUnit).first(where: { AudioUnitParameterOptions(rawValue: $0.flags).contains(.flag_IsWritable) })
        else { throw EngineError("model: no writable effect parameter to change") }
        do {
            var v: AudioUnitParameterValue = 0
            AudioUnitGetParameter(effect.audioUnit, p.id, kAudioUnitScope_Global, 0, &v)
            var param = AudioUnitParameter(mAudioUnit: effect.audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
            AUParameterSet(nil, nil, &param, v == p.min ? p.max : p.min, 0)
            try until("a parameter change marks the session edited", 2) { model.dirty && model.needsSavePrompt }
            print("model: changing \(effect.id.subtype) '\(p.name)' marked the session edited")
        }

        // MIDI off under None input: no rebuild, the instrument stays (it runs on its own), and the
        // picker still offers only effects; once the instrument is gone the head is open to either kind.
        var offFlips = 0
        let offWatch = model.$status.map(\.running).removeDuplicates().dropFirst().sink { _ in offFlips += 1 }
        model.update { $0.input.midiSource = ""; $0.input.midiSourceName = "" }
        run(0.5)
        offWatch.cancel()
        guard offFlips == 0, model.status.running, model.error == nil, model.hint == nil, !model.hasMidi, model.session.input.isNone else {
            throw EngineError("model: MIDI off: flips \(offFlips), running \(model.status.running), hint \(model.hint ?? "nil"), MIDI \(model.hasMidi)")
        }
        guard model.session.chain.count == 3, !model.offersInstruments, model.chainWidth == 2 else {
            throw EngineError("model: None input with an instrument offers instruments \(model.offersInstruments), width \(model.chainWidth)")
        }
        model.remove(at: [0])
        try until("instrument removed under None input", 3) { model.session.chain.count == 2 && model.status.running && model.error == nil }
        guard model.offersInstruments, model.hint == nil else {
            throw EngineError("model: None input with an open head offers instruments \(model.offersInstruments), hint \(model.hint ?? "nil")")
        }
        print("model: MIDI off is no rebuild and keeps the instrument; with the head open under None input the picker offers instruments")
        // None output too: no device at all.
        model.update { $0.output = .none }
        // BlackHole runs at the clock's rate too, so the clock's own buffer list is what tells the new engine from the old.
        try until("no device running", 3) { model.status.running && model.error == nil && model.bufferSizeChoices == Engine.clockBufferChoices }
        guard model.status.sampleRate == Engine.clockSampleRate else { throw EngineError("model: no device: sample rate \(model.status.sampleRate)") }
        run(0.5)
        guard model.status.renderErrors == 0 else { throw EngineError("model: no device: \(model.status.renderErrors) render errors") }
        print("model: None in and out runs on the timer at \(Int(model.status.sampleRate)) Hz, buffer \(model.status.bufferFrames), no errors")

        // Audio and MIDI together: a device input with a MIDI source. Nothing in the chain takes
        // MIDI (two effects), so the hint says so, but the activity light still shows the notes;
        // MIDI off is no rebuild; an instrument added beside the device input plays, with the
        // device input unused (the DLS synth has no input bus) and the hint saying so.
        model.update {
            $0.input = Endpoint(deviceUid: out.uid, channels: [0, 1], midiSource: "\(sourceID)", midiSourceName: "Plainchain smoke")
            $0.output = session.output
        }
        try until("audio and MIDI running", 3) {
            model.status.running && model.error == nil && model.status.deviceName == out.name && model.hint == Model.midiUnusedHint
        }
        guard model.hasMidi, model.session.input.isDevice, model.offersInstruments, model.chainWidth == 2 else {
            throw EngineError("model: audio and MIDI: MIDI \(model.hasMidi), device \(model.session.input.isDevice), offers instruments \(model.offersInstruments), width \(model.chainWidth)")
        }
        send(0x2090_3C64)
        try until("MIDI light beside a device input", 2) { model.levels.midiActive }
        send(0x2080_3C00)
        run(0.5)
        guard model.status.renderErrors == 0 else { throw EngineError("model: audio and MIDI: \(model.status.renderErrors) render errors") }
        var bothFlips = 0
        let bothWatch = model.$status.map(\.running).removeDuplicates().dropFirst().sink { _ in bothFlips += 1 }
        model.update { $0.input.midiSource = ""; $0.input.midiSourceName = "" }
        run(0.3)
        bothWatch.cancel()
        guard bothFlips == 0, model.status.running, model.hint == nil, !model.hasMidi, model.session.input.isDevice else {
            throw EngineError("model: MIDI off beside a device input: flips \(bothFlips), hint \(model.hint ?? "nil"), MIDI \(model.hasMidi)")
        }
        print("model: a device input with a MIDI source runs on \(out.name) with the unused-MIDI hint and a live activity light; MIDI off is no rebuild")
        guard let dls = model.plugins.first(where: { $0.id.subtype == "dls " && $0.id.manufacturer == "appl" }) else { throw EngineError("model: DLSMusicDevice not installed") }
        model.add(dls)
        try until("instrument added beside a device input", 5) {
            model.session.chain.count == 3 && model.status.running && model.error == nil && model.hint == Model.audioUnusedHint(dls.name)
        }
        guard model.hasInstrument, !model.offersInstruments, model.hasMidi, model.session.input.isDevice, model.chainWidth == 2 else {
            throw EngineError("model: instrument beside a device input: MIDI \(model.hasMidi), offers instruments \(model.offersInstruments), width \(model.chainWidth)")
        }
        let added = model.session.chain[0].id
        _ = model.levels.peaks[added]
        send(0x2090_3C64)
        try until("instrument plays beside a device input", 3) { (model.levels.peaks[added]?.max() ?? 0) > 0.01 }
        send(0x2080_3C00)
        run(0.3)
        guard model.status.renderErrors == 0 else { throw EngineError("model: instrument beside a device input: \(model.status.renderErrors) render errors") }
        // MIDI off again: still no rebuild, and the hint about the unused audio input stays.
        var addedFlips = 0
        let addedWatch = model.$status.map(\.running).removeDuplicates().dropFirst().sink { _ in addedFlips += 1 }
        model.update { $0.input.midiSource = ""; $0.input.midiSourceName = "" }
        run(0.3)
        addedWatch.cancel()
        guard addedFlips == 0, model.status.running, model.hint == Model.audioUnusedHint(dls.name), !model.hasMidi else {
            throw EngineError("model: MIDI off with an instrument beside a device input: flips \(addedFlips), hint \(model.hint ?? "nil")")
        }
        print("model: an instrument added beside a device input plays, with the hint \"\(model.hint ?? "")\"; MIDI off is no rebuild and keeps it")
        if let clap { try midiModelClap(model, clap, url: url, send: send, until: until) }
        model.enabled = false
        run(0.2)
    }

    /// The CLAP instrument `clap` in the app model, in place of the DLS synth at
    /// the head beside the device input: the model's plugin list offers it,
    /// adding it plays it, and the session saved with one of its parameters
    /// changed reopens with that value, unedited, and plays again.
    @MainActor
    private static func midiModelClap(_ model: Model, _ clap: Plugin, url: URL, send: (UInt32) -> Void,
                                      until: (String, Double, () -> Bool) throws -> Void) throws {
        func run(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        guard let listed = model.plugins.first(where: { $0.id.clapId == clap.id.clapId }), listed.isInstrument else {
            throw EngineError("model: the plugin list does not offer \(clap.name) as an instrument")
        }
        model.remove(at: [0])
        // The guest has no accelerated OpenGL renderer, and nfp5's GUI (baseview)
        // aborts the process when it cannot create its OpenGL context; the editor
        // path is checked on the host by --clap-test.
        model.opensEditorOnAdd = false
        defer { model.opensEditorOnAdd = true }
        try until("DLS synth removed", 3) { model.session.chain.count == 2 && !model.hasInstrument && model.status.running && model.error == nil }
        model.add(listed)
        try until("\(clap.name) added", 5) {
            model.session.chain.count == 3 && model.session.chain[0].plugin == listed.id && model.status.running && model.error == nil
                && model.hint == Model.audioUnusedHint(clap.name)
        }
        guard model.hasMidi, model.name(of: model.session.chain[0].plugin) == clap.name else {
            throw EngineError("model: \(clap.name) added: MIDI \(model.hasMidi), named \(model.name(of: model.session.chain[0].plugin))")
        }
        func played(_ label: String) throws {
            let head = model.session.chain[0].id
            try until("\(label): quiet", 5) { (model.levels.peaks[head]?.max() ?? 1) < 0.001 }
            send(0x2090_3C64)
            try until("\(label): \(clap.name) meter", 3) { (model.levels.peaks[head]?.max() ?? 0) > 0.01 }
            let meter = model.levels.peaks[head]?.max() ?? 0
            send(0x2080_3C00)
            print(String(format: "model: %@: %@ (CLAP) meter %.3f", label, clap.name, meter))
        }
        try played("added from the plugin list")

        // A parameter changed through the C API, as the smoke's chain check sets one, is in the saved state.
        guard let unit = model.instance(for: model.session.chain[0].id),
              let p = Plugins.v2Parameters(unit.audioUnit).first(where: {
                  AudioUnitParameterOptions(rawValue: $0.flags).contains(.flag_IsWritable) && $0.unit != AudioUnitParameterUnit.indexed.rawValue && $0.min < $0.max
              })
        else { throw EngineError("model: \(clap.name) has no writable continuous parameter") }
        var before: AudioUnitParameterValue = 0
        AudioUnitGetParameter(unit.audioUnit, p.id, kAudioUnitScope_Global, 0, &before)
        let target = p.max - before > before - p.min ? p.max : p.min
        var param = AudioUnitParameter(mAudioUnit: unit.audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
        AUParameterSet(nil, nil, &param, target, 0)
        run(0.3)
        // Saved to the session file the model has open; an untitled one would put up a save panel.
        guard model.sessionURL == url else { throw EngineError("model: the session open is not \(url.lastPathComponent)") }
        guard model.saveSession() else { throw EngineError("model: saving the session with \(clap.name): \(model.error ?? "failed")") }
        let saved = try SessionFile.read(url)
        let version = try DB(url, create: false).scalarInt("PRAGMA user_version")
        guard saved.chain.first?.plugin == listed.id, saved.chain.first?.state != nil, version == 5 else {
            throw EngineError("model: the saved session does not hold \(clap.name) with its state at version 5 (version \(version))")
        }
        print("model: saved with \(clap.name) at format version \(version), '\(p.name)' set from \(before) to \(target)")

        try wait { await model.open(url, quietly: false) }
        try until("session with \(clap.name) reopened", 5) {
            model.status.running && model.error == nil && model.session.chain.count == 3 && model.session.chain[0].plugin == listed.id && !model.dirty
        }
        run(0.5)  // let any plugin notifications from loading state and building the graph arrive
        guard let reopened = model.instance(for: model.session.chain[0].id), reopened !== unit else {
            throw EngineError("model: \(clap.name) was not made again when the session reopened")
        }
        var after: AudioUnitParameterValue = 0
        AudioUnitGetParameter(reopened.audioUnit, p.id, kAudioUnitScope_Global, 0, &after)
        guard after == target, !model.dirty else {
            throw EngineError("model: reopened \(clap.name) has '\(p.name)' \(after), not \(target) (edited \(model.dirty))")
        }
        print("model: the session reopened with \(clap.name), '\(p.name)' \(after), unedited")
        // Back to where it was, so the note below sounds as the first one did (a long attack would be slow to reach the meter).
        var restored = AudioUnitParameter(mAudioUnit: reopened.audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
        AUParameterSet(nil, nil, &restored, before, 0)
        run(0.3)
        try played("reopened")
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

    /// The engine's stages for a chain, an instrument at its head marked as one.
    private static func engineStages(_ units: [PluginInstance], _ chain: [ChainItem]) -> [Engine.Stage] {
        zip(units, chain).map {
            Engine.Stage(unit: $0.audioUnit, bypass: $1.bypass, gainDb: $1.inputGainDb, isInstrument: $1.plugin.isInstrument, owner: $0)
        }
    }

    private static func describe(_ unit: PluginInstance) -> String {
        "\(unit.isV3 ? "v3" : "v2"), created \(unit.createdOnMainThread ? "on the main thread" : "off the main thread")"
    }

    /// Block the main thread on an async call while servicing the run loop.
    private static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { result = await Result { try await body() } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }
}
