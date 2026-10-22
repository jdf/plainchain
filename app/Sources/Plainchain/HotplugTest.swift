import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The fake interface's id, for the signal handler (which cannot capture).
private var hotplugFakeId: AudioObjectID = 0

/// `Plainchain --hotplug-test [PC_IN=name] [PC_OUT=name]`
/// Headless check of device hot-plug recovery, run in the test VM
/// (`make hotplug-test`). It fakes an audio interface with a public
/// aggregate device under a fixed UID: destroying it is an unplug, and
/// creating it again is a replug under a new object id. A `Model` running a
/// session on the fake must show "Waiting for …" while it is gone and come
/// back on its own when it returns. Exits nonzero on failure.
@MainActor
enum HotplugTest {
    static let fakeUid = "com.plainchain.test.fake-interface"
    static let fakeName = "Fake Interface"

    private static var subdevices: (input: Device, output: Device)!
    private static var model: Model!
    private static var watchers: Set<AnyCancellable> = []

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)  // over ssh stdout is a pipe; keep lines flowing
        // A HAL call that never returns would hang the main thread; give up from another.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            print("FAIL: watchdog: still running after 120 s")
            if hotplugFakeId != 0 { AudioHardwareDestroyAggregateDevice(hotplugFakeId) }
            _exit(1)  // not exit(): its atexit teardown can block on the same stuck HAL call
        }
        do { try go() } catch { fail(error.localizedDescription) }
        cleanUp()
        print("PASS")
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        cleanUp()
        exit(1)
    }

    private static func cleanUp() {
        model?.enabled = false  // drops the engine and any private aggregate it made
        if hotplugFakeId != 0 { AudioHardwareDestroyAggregateDevice(hotplugFakeId); hotplugFakeId = 0 }
        destroyStale()
    }

    private static func go() throws {
        let env = ProcessInfo.processInfo.environment
        // On a real Mac this would feed the microphone into the speakers.
        var vm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &vm, &size, nil, 0)
        guard vm == 1 || env["PC_HOTPLUG_ON_HOST"] != nil else {
            throw EngineError("not in a VM; run it with `make hotplug-test` (set PC_HOTPLUG_ON_HOST=1 to override)")
        }
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            signal(sig) { s in
                if hotplugFakeId != 0 { AudioHardwareDestroyAggregateDevice(hotplugFakeId) }
                _exit(128 + s)
            }
        }
        // Without a microphone grant coreaudiod asks TCC for a consent dialog that no
        // one answers in a headless guest, and creating the HAL unit blocks forever.
        // AVCaptureDevice's status is no help here: over ssh it reports "not
        // determined" even with the grant in place. So try the call that blocks,
        // on another thread, with a deadline.
        guard halUnitOpens(within: 10) else {
            throw EngineError("creating a HAL unit did not return within 10 s: microphone access for \(Bundle.main.bundleIdentifier ?? "this app") is probably not granted here, and the engine cannot start headless without it")
        }
        destroyStale()

        let devices = try listDevices()
        for d in devices {
            print(String(format: "%4d in %2d out %2d @%6.0f %@%@ %@", d.id, d.inputChannels, d.outputChannels, d.sampleRate,
                         d.defaultInput ? "I" : " ", d.defaultOutput ? "O" : " ", d.name))
        }
        func pick(_ key: String, _ dflt: (Device) -> Bool) throws -> Device {
            if let n = env[key] {
                guard let d = devices.first(where: { $0.name.contains(n) }) else { throw EngineError("no device \(n)") }
                return d
            }
            guard let d = devices.first(where: dflt) else { throw EngineError("no default device") }
            return d
        }
        subdevices = (try pick("PC_IN", \.defaultInput), try pick("PC_OUT", \.defaultOutput))
        print("fake interface wraps: in \(subdevices.input.name), out \(subdevices.output.name)")

        try createFake()
        print("created \(fakeName) id \(hotplugFakeId)")

        model = Model(ephemeral: true)
        // Invariants on every device list the model publishes.
        model.$devices.sink { list in
            let fakes = list.filter { $0.uid == fakeUid }.count
            if fakes > 1 { fail("\(fakeName) listed \(fakes) times in model.devices") }
            if let own = list.first(where: { $0.uid.hasPrefix(HAL.aggregatePrefix) }) { fail("model.devices lists a private aggregate: \(own.uid)") }
        }.store(in: &watchers)

        // 1. The fake as both input and output.
        try scenario("fake in, fake out", input: fakeUid, output: fakeUid, chain: [], cycles: 4, fast: true, storm: true)

        // 2. The same with an Apple effect in the chain.
        if let delay = model.plugins.first(where: { $0.id.subtype == "dely" && $0.id.manufacturer == "appl" }) {
            try scenario("fake in, AUDelay, fake out", input: fakeUid, output: fakeUid, chain: [ChainItem(plugin: delay.id)], cycles: 1)
        } else {
            print("\n== AUDelay not installed; skipping the chain variant")
        }

        // 3. Fake in, real out: Plainchain builds a private aggregate holding an aggregate.
        try scenario("fake in, real out (nested aggregate)", input: fakeUid, output: subdevices.output.uid, chain: [], cycles: 1, nested: true)
    }

    // MARK: Scenario

    private static func scenario(_ title: String, input: String, output: String, chain: [ChainItem], cycles: Int,
                                 fast: Bool = false, storm: Bool = false, nested: Bool = false) throws {
        print("\n== \(title)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hotplug-\(UUID().uuidString).plainchain")
        defer { try? FileManager.default.removeItem(at: url) }
        try SessionFile.write(Session(input: Endpoint(deviceUid: input, channels: [0, 1]),
                                      output: Endpoint(deviceUid: output, channels: [0, 1]), chain: chain), to: url)
        try wait { await model.open(url, quietly: true) }
        guard model.session.chain.count == chain.count else { throw EngineError("session loaded \(model.session.chain.count) of \(chain.count) plugins: \(model.error ?? "")") }

        // The status left over from the previous session reads "running" until the new graph is up,
        // so wait for the engine on this session's device.
        let expected = input == output ? fakeName : "\(fakeName) → \(model.device(uid: output)?.name ?? "")"
        let started = poll(5) { model.status.running && model.error == nil && model.status.deviceName == expected }
        guard let t = started else {
            if nested {
                print("NESTED AGGREGATE REFUSED: the engine did not start (\(describe())); not counted as a failure")
                return
            }
            throw EngineError("engine not running 5 s after open: \(describe())")
        }
        guard model.status.deviceName.contains(fakeName) else { throw EngineError("engine runs on '\(model.status.deviceName)', not \(fakeName)") }
        print(String(format: "running after %.0f ms on '%@'", t * 1000, model.status.deviceName))
        if nested { print("nested aggregate accepted: CoreAudio built a private aggregate containing \(fakeName)") }

        for cycle in 1...cycles { try cycleOnce("cycle \(cycle)") }
        if fast { try cycleOnce("fast cycle", gap: 0.05) }

        if storm {
            var flips = 0
            var errors: [String] = []
            let c1 = model.$status.map(\.running).removeDuplicates().dropFirst().sink { _ in flips += 1 }
            let c2 = model.$error.compactMap { $0 }.sink { errors.append($0) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
            c1.cancel(); c2.cancel()
            guard flips == 0, errors.isEmpty, model.status.running else {
                throw EngineError("restart storm: running flipped \(flips) times, errors \(errors) in 2 s after recovery")
            }
            print("steady for 2 s after recovery: running never flipped, no errors")
        }
    }

    /// Unplug the fake, see the model wait for it; replug it, see the model recover.
    private static func cycleOnce(_ label: String, gap: TimeInterval? = nil) throws {
        let before = model.device(uid: fakeUid)?.id ?? 0
        destroyFake()
        if let gap {
            // Back before the model has necessarily noticed it went.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: gap))
            try createFake()
            let t = try waitFor("\(label): running again", 5) { model.status.running && model.error == nil && model.device(uid: fakeUid) != nil }
            let after = model.device(uid: fakeUid)?.id ?? 0
            print(String(format: "%@: unplug + replug %.0f ms apart, running again %.0f ms after unplug; id %d -> %d",
                         label, gap * 1000, t * 1000, before, after))
            try checkHAL()
            return
        }
        let down = try waitFor("\(label): teardown", 3) { !model.status.running && (model.error ?? "").hasPrefix("Waiting for") }
        let shown = model.error ?? ""
        guard shown.contains(fakeName) else { throw EngineError("\(label): shows '\(shown)', not waiting for \(fakeName)") }
        let replugged = Date()
        try createFake()
        _ = try waitFor("\(label): recovery", 5) { model.status.running && model.error == nil }
        let up = Date().timeIntervalSince(replugged)
        let after = model.device(uid: fakeUid)?.id ?? 0
        print(String(format: "%@: torn down %.0f ms after unplug (\"%@\"); running %.0f ms after replug; id %d -> %d",
                     label, down * 1000, shown, up * 1000, before, after))
        guard after != 0, after != before else { throw EngineError("\(label): device id did not change (\(before) -> \(after))") }
        try checkHAL()
    }

    private static func checkHAL() throws {
        let n = try listDevices().filter { $0.uid == fakeUid }.count
        guard n == 1 else { throw EngineError("HAL lists \(fakeName) \(n) times") }
    }

    /// Whether a HAL output unit can be created (and disposed) within `seconds`.
    private nonisolated static func halUnitOpens(within seconds: Double) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            )
            var unit: AudioUnit?
            if let comp = AudioComponentFindNext(nil, &desc), AudioComponentInstanceNew(comp, &unit) == noErr, let unit {
                AudioComponentInstanceDispose(unit)
            }
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: The fake interface

    private static func createFake() throws {
        let (inp, out) = subdevices!
        var subs: [[String: Any]] = [["uid": out.uid, "drift": 0]]
        if inp.uid != out.uid { subs.insert(["uid": inp.uid, "drift": 1], at: 0) }
        let description: [String: Any] = [
            "name": fakeName,
            "uid": fakeUid,
            "private": 0,
            "stacked": 0,
            "master": out.uid,
            "subdevices": subs,
        ]
        var id: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "create \(fakeName)")
        hotplugFakeId = id
        _ = try waitFor("\(fakeName) listed by the HAL", 3) { ((try? HAL.devices()) ?? []).contains { $0.uid == fakeUid } }
    }

    private static func destroyFake() {
        let id = hotplugFakeId
        hotplugFakeId = 0
        let st = AudioHardwareDestroyAggregateDevice(id)
        if st != noErr { fail("destroy \(fakeName): \(FourCC.string(UInt32(bitPattern: st)))") }
    }

    /// A public aggregate outlives its process; remove one left by a run that crashed.
    private static func destroyStale() {
        for d in (try? listDevices()) ?? [] where d.uid == fakeUid {
            AudioHardwareDestroyAggregateDevice(d.id)
        }
    }

    /// `HAL.devices()`, retried: a device going away while it is listed fails the listing.
    private static func listDevices() throws -> [Device] {
        for _ in 0..<20 {
            if let d = try? HAL.devices() { return d }
            usleep(50_000)
        }
        return try HAL.devices()
    }

    // MARK: Waiting

    private static func describe() -> String {
        "running \(model.status.running), device '\(model.status.deviceName)', error \(model.error.map { "'\($0)'" } ?? "nil")"
    }

    /// Seconds until `cond` held, servicing the main run loop; nil after `timeout`.
    private static func poll(_ timeout: TimeInterval, _ cond: () -> Bool) -> TimeInterval? {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return nil }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return Date().timeIntervalSince(start)
    }

    private static func waitFor(_ what: String, _ timeout: TimeInterval, _ cond: () -> Bool) throws -> TimeInterval {
        guard let t = poll(timeout, cond) else {
            throw EngineError("\(what): not within \(timeout) s (\(model == nil ? "no model" : describe()))")
        }
        return t
    }

    /// Block the main thread on an async call while servicing the run loop.
    private static func wait<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { result = await Result { try await body() } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }
}
