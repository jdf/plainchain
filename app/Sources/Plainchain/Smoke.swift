import AVFoundation
import Foundation

/// `Plainchain --smoke [PC_IN=name] [PC_OUT=name] [plugin names...]`
/// Headless check: lists devices and plugins, builds the chain, runs it for
/// two seconds, and round-trips a session file. Exits nonzero on failure.
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
        let inp = try pick("PC_IN", \.defaultInput)
        let out = try pick("PC_OUT", \.defaultOutput)
        let names = CommandLine.arguments.drop(while: { $0 != "--smoke" }).dropFirst()
        var units: [AVAudioUnit] = []
        var chain: [ChainItem] = []
        for n in names {
            guard let p = plugins.first(where: { $0.name == n || $0.id.subtype == n }) else { throw EngineError("no plugin \(n)") }
            let unit = try wait { try await Plugins.instantiate(p.id) }
            print("  \(p.name): \(Plugins.v2Parameters(unit.audioUnit).count) params; gain reduction meter: \(Plugins.gainReductionMeter(unit.audioUnit).map { "param \($0.id)" } ?? "none")")
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
            chain: chain
        )
        print("session: \(inp.name) \(session.input.channels) -> \(names.joined(separator: " -> ")) -> \(out.name) \(session.output.channels)")
        let stages = zip(units, chain).map { Engine.Stage(unit: $0.audioUnit, bypass: $1.bypass, gainDb: $1.inputGainDb) }
        let engine = try Engine(input: session.input, output: session.output, devices: devices, stages: stages)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        print("status:", engine.status)
        print("peaks per stage:", (0...units.count).map { engine.takePeaks($0) })
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
    }

    /// Block the main thread on an async call while servicing the run loop.
    private static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { result = await Result { try await body() } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }
}
