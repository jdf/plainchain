import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// The realtime graph:
///
///     device input --HAL(bus 1)--> stage 0 --> effect 1 --> stage 1 --> ... --> effect N --> stage N --> HAL(bus 0) --> device output
///
/// One HAL output unit does both sides. When the chosen input and output are
/// different devices, they are joined in a private aggregate device first, so
/// CoreAudio handles clock drift and sample-rate differences.
///
/// Every hop is a pull: each unit's input is a render callback (a *stage*)
/// that renders its upstream unit straight into the downstream unit's buffers,
/// then applies that stage's trim gain and records the peak level. Stage `i`
/// feeds effect `i`; the last stage feeds the HAL output. There is no
/// intermediate buffer and no added latency beyond the device's own.
///
/// Plugin instances are owned by the caller; the engine only configures,
/// wires, and (un)initializes them.
final class Engine {
    struct Status: Equatable {
        var running = false
        var sampleRate = 0.0
        var width = 0
        var renderErrors: UInt64 = 0
        var deviceName = ""
        /// Device IO buffer, in frames.
        var bufferFrames = 0
        /// Device input latency plus safety offset, in frames.
        var inputLatencyFrames = 0
        /// Device output latency plus safety offset, in frames.
        var outputLatencyFrames = 0
        /// Sum of the plugins' reported latencies, in frames.
        var pluginLatencyFrames = 0

        var bufferMs: Double { ms(bufferFrames) }
        /// Input buffer + output buffer + device latencies + plugins, the way a round trip adds up.
        var roundTripFrames: Int { 2 * bufferFrames + inputLatencyFrames + outputLatencyFrames + pluginLatencyFrames }
        func ms(_ frames: Int) -> Double { sampleRate > 0 ? Double(frames) * 1000 / sampleRate : 0 }
    }

    struct Stage {
        var unit: AudioUnit
        var bypass: Bool
        var gainDb: Float
    }

    static let maxChannels = 32

    private let hal: AudioUnit
    private var aggregate: AudioObjectID = 0
    private let effects: [AudioUnit]
    /// One per effect, plus one feeding the HAL output.
    private let stages: UnsafeMutablePointer<StageContext>
    private let stageCount: Int
    private var tornDown = false
    private(set) var sampleRate = 0.0
    private(set) var width = 0
    private(set) var deviceName = ""
    private var latency = Status()
    /// The HAL device the graph runs on (a real device or the private aggregate).
    private(set) var device: AudioObjectID = 0
    private(set) var bufferSizeChoices: [Int] = []

    var status: Status {
        var s = latency
        s.running = true
        s.sampleRate = sampleRate
        s.width = width
        s.deviceName = deviceName
        s.renderErrors = 0
        for i in 0..<stageCount { s.renderErrors &+= stages[i].renderErrors }
        return s
    }

    init(input: Endpoint, output: Endpoint, devices: [Device], stages chain: [Stage]) throws {
        effects = chain.map(\.unit)
        stageCount = chain.count + 1
        stages = .allocate(capacity: stageCount)
        for i in 0..<stageCount {
            let gainDb = i < chain.count ? chain[i].gainDb : 0
            stages.advanced(by: i).initialize(to: StageContext(gain: Engine.linear(gainDb)))
        }
        hal = try Engine.newHAL()
        do {
            try build(input: input, output: output, devices: devices, bypass: chain.map(\.bypass))
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    static func linear(_ db: Float) -> Float { powf(10, db / 20) }

    /// Live trim change for the stage feeding effect `index`.
    func setGain(_ index: Int, db: Float) {
        guard index >= 0, index < stageCount else { return }
        stages[index].gain = Engine.linear(db)
    }

    /// Peak level per channel since the last call, linear; resets the hold.
    func takePeaks(_ index: Int) -> [Float] {
        guard index >= 0, index < stageCount else { return [] }
        let ctx = stages.advanced(by: index)
        return (0..<width).map { c in
            let v = ctx.pointee.peaks[c]
            ctx.pointee.peaks[c] = 0
            return v
        }
    }

    func setBypass(_ index: Int, _ bypass: Bool) throws {
        guard effects.indices.contains(index) else { throw EngineError("no plugin at \(index)") }
        var b: UInt32 = bypass ? 1 : 0
        try set(effects[index], kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &b, "bypass")
    }

    private static func newHAL() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EngineError("HAL output unit not found") }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "create HAL unit")
        return unit!
    }

    private func build(input: Endpoint, output: Endpoint, devices: [Device], bypass: [Bool]) throws {
        guard !input.channels.isEmpty else { throw EngineError("choose at least one input channel") }
        guard input.channels.count <= Engine.maxChannels else { throw EngineError("at most \(Engine.maxChannels) input channels") }
        guard !output.channels.isEmpty else { throw EngineError("choose at least one output channel") }
        guard let inDev = devices.first(where: { $0.uid == input.deviceUid }) else { throw EngineError("input device is not connected") }
        guard let outDev = devices.first(where: { $0.uid == output.deviceUid }) else { throw EngineError("output device is not connected") }
        if let ch = input.channels.first(where: { $0 >= inDev.inputChannels }) { throw EngineError("\(inDev.name) has no input channel \(ch + 1)") }
        if let ch = output.channels.first(where: { $0 >= outDev.outputChannels }) { throw EngineError("\(outDev.name) has no output channel \(ch + 1)") }

        // ---- Device: the device itself, or a private aggregate of the two.
        let device: AudioObjectID
        var outputOffset: UInt32 = 0
        if inDev.uid == outDev.uid {
            device = inDev.id
            deviceName = inDev.name
        } else {
            aggregate = try HAL.createAggregate(input: inDev, output: outDev)
            device = aggregate
            // Aggregate channels follow sub-device order: input device first.
            outputOffset = inDev.outputChannels
            deviceName = "\(inDev.name) → \(outDev.name)"
        }
        self.device = device
        sampleRate = try HAL.sampleRate(device)
        width = input.channels.count
        for i in 0..<stageCount { stages[i].width = width }
        let deviceOutputs = try HAL.channelCount(device, kAudioObjectPropertyScopeOutput)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(width), mBitsPerChannel: 32, mReserved: 0
        )
        var maxFrames: UInt32 = 4096

        // ---- HAL unit: input on bus 1, output on bus 0, both on `device`.
        var one: UInt32 = 1
        var deviceId = device
        try set(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, "enable input")
        try set(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, "enable output")
        try set(hal, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceId, "select device")
        var inMap = input.channels.map { Int32($0) }
        try set(hal, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &inMap, "input channel map")
        try set(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, "input stream format")
        // Device output channel -> chain channel; chain channels wrap so mono in can feed stereo out.
        var outMap = [Int32](repeating: -1, count: Int(deviceOutputs))
        for (i, ch) in output.channels.enumerated() { outMap[Int(outputOffset + ch)] = Int32(i % width) }
        try set(hal, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0, &outMap, "output channel map")
        try set(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "output stream format")
        try set(hal, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "max frames")

        // ---- Effects: same float format in and out.
        for (i, unit) in effects.enumerated() {
            let label = "plugin \(i + 1)"
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "\(label): input format")
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, "\(label): output format")
            try set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "\(label): max frames")
        }

        // ---- Wiring: stage i pulls from effect i-1 (or the HAL input) and feeds effect i (or the HAL output).
        for i in 0..<stageCount {
            let ctx = stages.advanced(by: i)
            if i == 0 {
                ctx.pointee.upstream = hal
                ctx.pointee.upstreamBus = 1
            } else {
                ctx.pointee.upstream = effects[i - 1]
                ctx.pointee.upstreamBus = 0
            }
            let downstream = i < effects.count ? effects[i] : hal
            var callback = AURenderCallbackStruct(inputProc: stageRender, inputProcRefCon: UnsafeMutableRawPointer(ctx))
            try set(downstream, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "render callback \(i)")
        }

        // ---- Initialize and start.
        for (i, unit) in effects.enumerated() {
            try check(AudioUnitInitialize(unit), "plugin \(i + 1): initialize")
            var b: UInt32 = bypass[i] ? 1 : 0
            try? set(unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &b, "bypass")
        }
        try check(AudioUnitInitialize(hal), "HAL unit: initialize")
        try check(AudioOutputUnitStart(hal), "start")

        // ---- Latency bookkeeping (informational; failures here are not fatal).
        bufferSizeChoices = HAL.bufferSizeChoices(device)
        refreshLatency(device)
    }

    /// Change the device's IO buffer. Takes effect on the next IO cycle; no rebuild needed.
    func setBufferSize(_ frames: Int) throws {
        try HAL.setBufferSize(device, frames)
        refreshLatency(device)
    }

    private func refreshLatency(_ device: AudioObjectID) {
        let g = kAudioObjectPropertyScopeGlobal, i = kAudioObjectPropertyScopeInput, o = kAudioObjectPropertyScopeOutput
        latency.bufferFrames = Int((try? HAL.get(device, kAudioDevicePropertyBufferFrameSize, g, UInt32(0))) ?? 0)
        latency.inputLatencyFrames = Int(((try? HAL.get(device, kAudioDevicePropertyLatency, i, UInt32(0))) ?? 0)
            + ((try? HAL.get(device, kAudioDevicePropertySafetyOffset, i, UInt32(0))) ?? 0))
        latency.outputLatencyFrames = Int(((try? HAL.get(device, kAudioDevicePropertyLatency, o, UInt32(0))) ?? 0)
            + ((try? HAL.get(device, kAudioDevicePropertySafetyOffset, o, UInt32(0))) ?? 0))
        var seconds = 0.0
        for unit in effects {
            var secs: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &secs, &size) == noErr { seconds += secs }
        }
        latency.pluginLatencyFrames = Int((seconds * sampleRate).rounded())
    }

    private func set<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout T, _ what: String) throws {
        try withUnsafePointer(to: &value) { p in
            try check(AudioUnitSetProperty(unit, prop, scope, element, p, UInt32(MemoryLayout<T>.size)), what)
        }
    }

    private func set<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout [T], _ what: String) throws {
        try value.withUnsafeMutableBufferPointer { buf in
            try check(AudioUnitSetProperty(unit, prop, scope, element, buf.baseAddress, UInt32(buf.count * MemoryLayout<T>.size)), what)
        }
    }

    /// Safe to call more than once: a failed `init` tears down and then `deinit` runs too.
    private func teardown() {
        guard !tornDown else { return }
        tornDown = true
        // Stop the IO thread before anything the callbacks touch goes away.
        AudioOutputUnitStop(hal)
        AudioUnitUninitialize(hal)
        for unit in effects {
            AudioUnitUninitialize(unit)
            // Detach from units that are about to be disposed or rewired.
            var none = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        AudioComponentInstanceDispose(hal)
        if aggregate != 0 { HAL.destroyAggregate(aggregate); aggregate = 0 }
        for i in 0..<stageCount { stages[i].peaks.deallocate() }
        stages.deinitialize(count: stageCount)
        stages.deallocate()
    }
}

/// Shared with the realtime callback; plain data only.
struct StageContext {
    var upstream: AudioUnit?
    var upstreamBus: UInt32 = 0
    var width = 0
    /// Linear trim; written by the UI thread, read by the render thread.
    var gain: Float
    /// Peak hold per channel; the render thread raises it, the UI thread resets it.
    var peaks: UnsafeMutablePointer<Float>
    var renderErrors: UInt64 = 0

    init(gain: Float) {
        self.gain = gain
        peaks = .allocate(capacity: Engine.maxChannels)
        peaks.initialize(repeating: 0, count: Engine.maxChannels)
    }
}

/// Realtime: render the upstream unit into the caller's buffers, apply the
/// trim, record the peak. Must not allocate, lock, or touch Swift objects.
private let stageRender: AURenderCallback = { refCon, flags, timestamp, _, frames, ioData in
    let ctx = refCon.assumingMemoryBound(to: StageContext.self)
    guard let ioData else { return noErr }
    guard let upstream = ctx.pointee.upstream else { silence(ioData); return noErr }
    let status = AudioUnitRender(upstream, flags, timestamp, ctx.pointee.upstreamBus, frames, ioData)
    if status != noErr {
        ctx.pointee.renderErrors &+= 1
        silence(ioData)
        return noErr
    }
    var gain = ctx.pointee.gain
    let n = vDSP_Length(frames)
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for c in 0..<min(buffers.count, ctx.pointee.width) {
        guard let data = buffers[c].mData else { continue }
        let p = data.assumingMemoryBound(to: Float.self)
        if gain != 1 { vDSP_vsmul(p, 1, &gain, p, 1, n) }
        var peak: Float = 0
        vDSP_maxmgv(p, 1, &peak, n)
        if peak > ctx.pointee.peaks[c] { ctx.pointee.peaks[c] = peak }
    }
    return noErr
}

private func silence(_ abl: UnsafeMutablePointer<AudioBufferList>) {
    for buffer in UnsafeMutableAudioBufferListPointer(abl) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
}
