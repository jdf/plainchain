import Accelerate
import AudioToolbox
import CapnSession
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
/// Reordering is live: the output stage fades to silence, repoints every
/// stage's upstream on the render thread, and fades back in, so nothing is
/// uninitialized and plugin state carries through.
///
/// MIDI is independent of the audio input. Whatever the input, the
/// instrument and every music effect get a lock-free ring (`pc_midi.h`) that
/// the render thread drains into them; the caller connects a MIDI source to
/// the rings, or none.
///
/// An instrument (`aumu`) at the chain head is the source the effects pull
/// from; it renders into a pass-through `AUConverter`, so the stage between
/// them gives the instrument its own output trim and meter:
///
///     [device input --HAL(bus 1)--> instrument input stage -->] instrument --> instrument stage --> converter --> stage 0 --> effect 1 --> ... --> stage N --> HAL(bus 0)
///
/// With a device input, the instrument's input bus pulls the HAL input bus
/// through one more stage, so a vocoder gets the microphone beside its MIDI.
/// An instrument with no input bus (a synth) leaves the device input unpulled;
/// `audioInputUnused` says so.
///
/// None input (`input.isNone`): there is no device input. The chain head is
/// an instrument, which renders on its own, or an effect, which gets
/// silence. The output device is used directly, never an aggregate.
///
/// None output (`output.isNone`): nothing is written to a device. The output
/// stage renders into a private *sink* buffer instead of the HAL output bus,
/// pulled by whatever clocks the graph: with a device input, the HAL unit
/// runs input-only on that device and its input callback pulls the chain
/// each IO cycle; with no device at all (None or MIDI input), a realtime
/// thread pulls it on a timer at `clockSampleRate`.
///
/// Plugin instances are owned by the caller; the engine only configures,
/// wires, and (un)initializes them, and keeps their owners alive until it is torn down.
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
        /// A music device at the chain head, played by MIDI; it is the graph's source.
        var isInstrument = false
        /// Kept alive until the graph is torn down (the plugin instance that owns `unit`).
        var owner: AnyObject? = nil
    }

    static let maxChannels = 32

    /// The HAL unit; nil when no device is involved (None or MIDI input with None output).
    private let hal: AudioUnit?
    private var aggregate: AudioObjectID = 0
    /// The instrument at chain position 0, the converter it renders into, and
    /// the stage between them (pulls the instrument, feeds the converter).
    private let instrument: AudioUnit?
    private var converter: AudioUnit?
    private let instrumentStage: UnsafeMutablePointer<StageContext>?
    /// The stage feeding the instrument's input bus from the HAL input bus;
    /// nil without a device input, or when the instrument has no input bus.
    private var instrumentInput: UnsafeMutablePointer<StageContext>?
    /// A device input is chosen but the instrument at the head has no input bus to take it.
    private(set) var audioInputUnused = false
    /// The chain without the instrument.
    private let effects: [AudioUnit]
    /// The input is an audio device (as opposed to None).
    private let audioInput: Bool
    private let midi: UnsafeMutablePointer<pc_midi_fanout>?
    /// The MIDI ring of each effect that takes MIDI (music effects), by effect index.
    private var effectRings: [UnsafeMutablePointer<pc_midi_ring>?]
    /// Rings 0..<midiRingCount of the fanout are in use; the caller sets the fanout's `active` to this.
    private(set) var midiRingCount = 0
    /// One per effect, plus one feeding the HAL output.
    private let stages: UnsafeMutablePointer<StageContext>
    private let stageCount: Int
    /// Chain position -> stage slot. Slot i is the stage wired into effect i's
    /// input; after a reorder the slots are the same but their order differs.
    private var slots: [Int]
    /// None output: the sink the output stage renders into, and the thread
    /// clocking it when there is no device at all.
    private var sink: UnsafeMutablePointer<SinkContext>?
    private var clock: pthread_t?
    /// The device-free clock's sample rate and the buffer sizes it offers.
    static let clockSampleRate = 48000.0
    static let clockBufferChoices = [64, 128, 256, 512, 1024, 2048, 4096]
    private var tornDown = false
    /// The stages' owners, released only after `deinit` has torn the graph down.
    private let owners: [AnyObject]
    private var started = false
    private(set) var sampleRate = 0.0
    private(set) var width = 0
    private(set) var deviceName = ""
    private var latency = Status()
    /// The HAL device the graph runs on (a real device or the private aggregate); 0 when there is none.
    private(set) var device: AudioObjectID = 0
    /// The real input and output devices behind `device`, as they were when the graph was built; 0 for MIDI or None.
    private(set) var inputDevice: AudioObjectID = 0
    private(set) var outputDevice: AudioObjectID = 0
    private(set) var bufferSizeChoices: [Int] = []

    var status: Status {
        var s = latency
        s.running = true
        s.sampleRate = sampleRate
        s.width = width
        s.deviceName = deviceName
        s.renderErrors = 0
        for i in 0..<stageCount { s.renderErrors &+= stages[i].renderErrors }
        if let instrumentStage { s.renderErrors &+= instrumentStage.pointee.renderErrors }
        if let instrumentInput { s.renderErrors &+= instrumentInput.pointee.renderErrors }
        return s
    }

    /// None output: cycles pulled through the sink so far (for the headless checks).
    var sinkCycles: UInt64 { sink?.pointee.cycles ?? 0 }

    /// `midi` is the fanout whose rings feed the instrument and music effects; without it they get no MIDI.
    init(input: Endpoint, output: Endpoint, devices: [Device], stages chain: [Stage], bufferFrames: Int = 0,
         midi: UnsafeMutablePointer<pc_midi_fanout>? = nil) throws {
        let head = chain.first.flatMap { $0.isInstrument ? $0 : nil }
        let rest = Array(chain.dropFirst(head == nil ? 0 : 1))
        instrument = head?.unit
        effects = rest.map(\.unit)
        owners = chain.compactMap(\.owner)
        audioInput = input.isDevice
        self.midi = midi
        effectRings = Array(repeating: nil, count: rest.count)
        stageCount = rest.count + 1
        slots = Array(0..<rest.count)
        stages = .allocate(capacity: stageCount)
        for i in 0..<stageCount {
            let gainDb = i < rest.count ? rest[i].gainDb : 0
            stages.advanced(by: i).initialize(to: StageContext(gain: Engine.linear(gainDb)))
        }
        instrumentStage = head.map { h in
            let p = UnsafeMutablePointer<StageContext>.allocate(capacity: 1)
            p.initialize(to: StageContext(gain: Engine.linear(h.gainDb)))
            return p
        }
        hal = try (audioInput || !output.isNone) ? Engine.newHAL() : nil
        do {
            if rest.contains(where: \.isInstrument) { throw EngineError("an instrument can only be first in the chain") }
            if instrument != nil {
                converter = try Engine.newUnit(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter, "converter")
            }
            try build(input: input, output: output, devices: devices, bypass: rest.map(\.bypass), bufferFrames: bufferFrames)
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    static func linear(_ db: Float) -> Float { powf(10, db / 20) }

    /// Chain positions before the effects: 1 when an instrument is at position 0.
    private var headCount: Int { instrument == nil ? 0 : 1 }

    /// Chain position -> index into `effects`; nil for the instrument.
    private func effectIndex(_ position: Int) -> Int? {
        position >= headCount ? position - headCount : nil
    }

    /// The stage feeding the plugin at chain `position` (one past the end: the
    /// output stage); for the instrument, the stage after it.
    private func stage(_ position: Int) -> UnsafeMutablePointer<StageContext>? {
        guard let e = effectIndex(position) else { return instrumentStage }
        if e == effects.count { return stages.advanced(by: effects.count) }
        return slots.indices.contains(e) ? stages.advanced(by: slots[e]) : nil
    }

    /// Where the first effect pulls from: the instrument's converter, the HAL
    /// input bus, or nothing (None input without an instrument renders silence).
    private var source: (unit: AudioUnit?, bus: UInt32) {
        if let converter { return (converter, 0) }
        return audioInput ? (hal, 1) : (nil, 0)
    }

    /// Live trim change for the stage feeding the plugin at chain `position`
    /// (for the instrument, its output trim).
    func setGain(_ position: Int, db: Float) {
        stage(position)?.pointee.gain = Engine.linear(db)
    }

    /// Reorder the chain without rebuilding: `newOrder[p]` is the old position
    /// of the plugin now at position `p`; an instrument stays at position 0.
    /// The swap happens on the render thread under a short fade.
    func reorder(_ newOrder: [Int]) {
        guard newOrder.count == effects.count + headCount, newOrder.prefix(headCount).elementsEqual(0..<headCount) else { return }
        let order = newOrder.dropFirst(headCount).map { $0 - headCount }
        guard Set(order) == Set(0..<effects.count) else { return }
        let src = source
        let newSlots = order.map { slots[$0] }
        // A stage's MIDI ring belongs to the unit it pulls from, so it moves with `upstream`.
        for (p, i) in newSlots.enumerated() {
            stages[i].pendingUpstream = p == 0 ? src.unit : effects[newSlots[p - 1]]
            stages[i].pendingBus = p == 0 ? src.bus : 0
            stages[i].pendingMidiRing = p == 0 ? nil : effectRings[newSlots[p - 1]]
        }
        let out = stages.advanced(by: effects.count)
        out.pointee.pendingUpstream = newSlots.last.map { effects[$0] } ?? src.unit
        out.pointee.pendingBus = newSlots.isEmpty ? src.bus : 0
        out.pointee.pendingMidiRing = newSlots.last.flatMap { effectRings[$0] }
        slots = newSlots
        pc_store_u32(&out.pointee.swapRequested, 1)
    }

    /// True while a reorder is waiting for the render thread to apply it.
    var swapPending: Bool { pc_load_u32(&stages[stageCount - 1].swapRequested) != 0 }

    /// Peak level per channel since the last call, linear; resets the hold.
    /// For the instrument, its output level.
    func takePeaks(_ position: Int) -> [Float] {
        guard let ctx = stage(position) else { return [] }
        return (0..<ctx.pointee.width).map { c in
            let v = ctx.pointee.peaks[c]
            ctx.pointee.peaks[c] = 0
            return v
        }
    }

    /// A no-op for the instrument.
    func setBypass(_ position: Int, _ bypass: Bool) throws {
        guard let e = effectIndex(position) else { return }
        guard slots.indices.contains(e) else { throw EngineError("no plugin at \(position)") }
        var b: UInt32 = bypass ? 1 : 0
        try set(effects[slots[e]], kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &b, "bypass")
    }

    private static func newHAL() throws -> AudioUnit {
        try newUnit(kAudioUnitType_Output, kAudioUnitSubType_HALOutput, "HAL unit")
    }

    /// An Apple Audio Unit, owned by the engine.
    private static func newUnit(_ type: OSType, _ subtype: OSType, _ what: String) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: type, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EngineError("\(what) not found") }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "create \(what)")
        return unit!
    }

    /// True for a music effect (`aumf`), which takes MIDI alongside its audio.
    private static func isMusicEffect(_ unit: AudioUnit) -> Bool {
        var desc = AudioComponentDescription()
        guard AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &desc) == noErr else { return false }
        return desc.componentType == kAudioUnitType_MusicEffect
    }

    private func build(input: Endpoint, output: Endpoint, devices: [Device], bypass: [Bool], bufferFrames: Int) throws {
        // None input has no input device; None output has no output device.
        var inDev: Device?
        if audioInput {
            guard !input.channels.isEmpty else { throw EngineError("choose at least one input channel") }
            guard input.channels.count <= Engine.maxChannels else { throw EngineError("at most \(Engine.maxChannels) input channels") }
            guard let d = devices.first(where: { $0.uid == input.deviceUid }) else { throw EngineError("input device is not connected") }
            if let ch = input.channels.first(where: { $0 >= d.inputChannels }) { throw EngineError("\(d.name) has no input channel \(ch + 1)") }
            inDev = d
        }
        var outDev: Device?
        if !output.isNone {
            guard !output.channels.isEmpty else { throw EngineError("choose at least one output channel") }
            guard let d = devices.first(where: { $0.uid == output.deviceUid }) else { throw EngineError("output device is not connected") }
            if let ch = output.channels.first(where: { $0 >= d.outputChannels }) { throw EngineError("\(d.name) has no output channel \(ch + 1)") }
            outDev = d
        }
        inputDevice = inDev?.id ?? 0
        outputDevice = outDev?.id ?? 0

        // ---- Device: the device itself, a private aggregate of the two, or none at all.
        var device: AudioObjectID = 0
        var outputOffset: UInt32 = 0
        switch (inDev, outDev) {
        case let (inDev?, outDev?) where inDev.uid != outDev.uid:
            aggregate = try HAL.createAggregate(input: inDev, output: outDev)
            device = aggregate
            // Aggregate channels follow sub-device order: input device first.
            outputOffset = inDev.outputChannels
            deviceName = "\(inDev.name) → \(outDev.name)"
        case let (_, outDev?):
            device = outDev.id
            deviceName = outDev.name
        case let (inDev?, nil):
            device = inDev.id
            deviceName = "\(inDev.name) → none"
        case (nil, nil):
            deviceName = "timer"
        }
        self.device = device
        if device != 0 {
            if bufferFrames > 0 { try? HAL.setBufferSize(device, bufferFrames) }
            sampleRate = try HAL.sampleRate(device)
        } else {
            sampleRate = Engine.clockSampleRate
        }
        // Without a device input: stereo when at least two output channels are chosen (or there is no output), else mono.
        width = audioInput ? input.channels.count : (output.isNone || output.channels.count >= 2 ? 2 : 1)
        for i in 0..<stageCount { stages[i].width = width }
        instrumentStage?.pointee.width = 2  // the instrument always renders stereo
        // Output stage fades over 8 ms when the chain is rewired, and in from silence at start.
        stages[stageCount - 1].fadeStep = Float(1000.0 / (8.0 * sampleRate))
        stages[stageCount - 1].fade = 0
        stages[stageCount - 1].fadeTarget = 1
        stages[stageCount - 1].holdFrames = Int(0.08 * sampleRate)
        stages[stageCount - 1].isOutput = true
        stages[stageCount - 1].allStages = stages
        stages[stageCount - 1].stageCount = stageCount
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(width), mBitsPerChannel: 32, mReserved: 0
        )
        var maxFrames: UInt32 = 4096

        // ---- None output: the sink the output stage renders into, in place of the HAL output bus.
        if output.isNone {
            let s = UnsafeMutablePointer<SinkContext>.allocate(capacity: 1)
            s.initialize(to: SinkContext(stage: stages.advanced(by: stageCount - 1), width: width, capacity: Int(maxFrames),
                                         sampleRate: sampleRate, frames: UInt32(Engine.clockFrames(bufferFrames))))
            sink = s
        }

        // ---- HAL unit: input on bus 1, output on bus 0, both on `device`. A
        // side with no device stays off: its bus is never pulled.
        if let hal {
            var inputOn: UInt32 = audioInput ? 1 : 0
            var outputOn: UInt32 = output.isNone ? 0 : 1
            var deviceId = device
            try set(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inputOn, "enable input")
            try set(hal, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &outputOn, "enable output")
            try set(hal, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceId, "select device")
            if audioInput {
                var inMap = input.channels.map { Int32($0) }
                try set(hal, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &inMap, "input channel map")
                try set(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, "input stream format")
            }
            if let sink {
                // Input only: the input callback pulls the chain into the sink each IO cycle.
                var callback = AURenderCallbackStruct(inputProc: sinkInputProc, inputProcRefCon: UnsafeMutableRawPointer(sink))
                try set(hal, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "input callback")
            } else {
                let deviceOutputs = try HAL.channelCount(device, kAudioObjectPropertyScopeOutput)
                // A fresh aggregate can report fewer channels than its sub-devices for a moment,
                // for example while a sub-device that just reappeared is still joining it.
                if let ch = output.channels.max(), outputOffset + ch >= deviceOutputs {
                    throw EngineError("\(deviceName) has \(deviceOutputs) output channels, not yet \(outputOffset + ch + 1)")
                }
                // Device output channel -> chain channel; chain channels wrap so mono in can feed stereo out.
                var outMap = [Int32](repeating: -1, count: Int(deviceOutputs))
                for (i, ch) in output.channels.enumerated() { outMap[Int(outputOffset + ch)] = Int32(i % width) }
                try set(hal, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0, &outMap, "output channel map")
                try set(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "output stream format")
            }
            try set(hal, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "max frames")
        }

        // ---- Effects: same float format in and out.
        for (i, unit) in effects.enumerated() {
            let label = "plugin \(i + 1)"
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "\(label): input format")
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, "\(label): output format")
            try set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "\(label): max frames")
        }

        // ---- Instrument: output only, always stereo (some instruments offer nothing
        // else); the converter after it passes it through, downmixing when the chain is mono.
        if let instrument, let converter {
            var stereo = format
            stereo.mChannelsPerFrame = 2
            try set(instrument, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stereo, "instrument: output format")
            try set(instrument, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "instrument: max frames")
            try set(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stereo, "converter: input format")
            try set(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, "converter: output format")
            try set(converter, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "converter: max frames")
            // A device input goes into the instrument's input bus, when it has one (a vocoder's
            // carrier or sidechain); a synth has none, and the device input is then never pulled.
            if audioInput {
                var buses: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioUnitGetProperty(instrument, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &buses, &size) != noErr { buses = 0 }
                if buses > 0 {
                    try set(instrument, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, "instrument: input format")
                    let p = UnsafeMutablePointer<StageContext>.allocate(capacity: 1)
                    p.initialize(to: StageContext(gain: 1))
                    p.pointee.width = width
                    p.pointee.upstream = hal
                    p.pointee.upstreamBus = 1
                    instrumentInput = p
                    var callback = AURenderCallbackStruct(inputProc: stageRender, inputProcRefCon: UnsafeMutableRawPointer(p))
                    try set(instrument, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "instrument input callback")
                } else {
                    audioInputUnused = true
                }
            }
        }

        // ---- MIDI rings: ring k per MIDI-receiving unit, in chain order (the
        // instrument first, then each music effect), whatever the audio input.
        // A ring is drained by the stage whose `upstream` is its unit, right
        // before that unit renders: the instrument's by the instrument stage,
        // effect e's by the stage that pulls from it (stage e + 1 as built;
        // `reorder` moves it with `upstream`).
        if let midi {
            var k: UInt32 = 0
            func next() -> UnsafeMutablePointer<pc_midi_ring>? {
                guard let ring = pc_midi_fanout_ring(midi, k) else { return nil }
                pc_midi_ring_reset(ring)  // the producer is off (`active` is 0) while the graph is built
                k += 1
                return ring
            }
            if instrument != nil { instrumentStage?.pointee.midiRing = next() }
            for (e, unit) in effects.enumerated() where Engine.isMusicEffect(unit) { effectRings[e] = next() }
            midiRingCount = Int(k)
        }

        // ---- Wiring: stage i pulls from effect i-1 (or the source) and feeds effect i
        // (or the HAL output; with None output the last stage is pulled by the sink instead).
        for i in 0..<stageCount {
            let ctx = stages.advanced(by: i)
            if i == 0 {
                ctx.pointee.upstream = source.unit
                ctx.pointee.upstreamBus = source.bus
            } else {
                ctx.pointee.upstream = effects[i - 1]
                ctx.pointee.upstreamBus = 0
                ctx.pointee.midiRing = effectRings[i - 1]
            }
            let downstream: AudioUnit? = i < effects.count ? effects[i] : (sink == nil ? hal : nil)
            guard let downstream else { continue }
            var callback = AURenderCallbackStruct(inputProc: stageRender, inputProcRefCon: UnsafeMutableRawPointer(ctx))
            try set(downstream, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "render callback \(i)")
        }
        if let instrument, let converter, let ctx = instrumentStage {
            ctx.pointee.upstream = instrument
            ctx.pointee.upstreamBus = 0
            var callback = AURenderCallbackStruct(inputProc: stageRender, inputProcRefCon: UnsafeMutableRawPointer(ctx))
            try set(converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, "instrument render callback")
        }

        // ---- Initialize and start.
        if let instrument, let converter {
            try check(AudioUnitInitialize(instrument), "instrument: initialize")
            try check(AudioUnitInitialize(converter), "converter: initialize")
        }
        for (i, unit) in effects.enumerated() {
            try check(AudioUnitInitialize(unit), "plugin \(i + 1): initialize")
            var b: UInt32 = bypass[i] ? 1 : 0
            try? set(unit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &b, "bypass")
        }
        if let hal {
            try check(AudioUnitInitialize(hal), "HAL unit: initialize")
            try check(AudioOutputUnitStart(hal), "start")
        } else if let sink {
            // No device at all: a thread clocks the chain.
            var thread: pthread_t?
            guard pthread_create(&thread, nil, clockMain, UnsafeMutableRawPointer(sink)) == 0, let thread else {
                throw EngineError("could not start the clock thread")
            }
            clock = thread
        }
        started = true

        // ---- Latency bookkeeping (informational; failures here are not fatal).
        bufferSizeChoices = device != 0 ? HAL.bufferSizeChoices(device) : Engine.clockBufferChoices
        refreshLatency(device)
    }

    /// Change the device's IO buffer (or the clock's). Takes effect on the next cycle; no rebuild needed.
    func setBufferSize(_ frames: Int) throws {
        if device != 0 {
            try HAL.setBufferSize(device, frames)
        } else if let sink {
            pc_store_u32(&sink.pointee.frames, UInt32(Engine.clockFrames(frames)))
        }
        refreshLatency(device)
    }

    /// Frames per cycle of the device-free clock: the request, within the sink's capacity; 512 when there is none.
    private static func clockFrames(_ requested: Int) -> Int {
        requested > 0 ? min(max(requested, 16), 4096) : 512
    }

    private func refreshLatency(_ device: AudioObjectID) {
        let g = kAudioObjectPropertyScopeGlobal, i = kAudioObjectPropertyScopeInput, o = kAudioObjectPropertyScopeOutput
        if device == 0 {
            // The clock: its buffer, and no device latency on either side.
            latency.bufferFrames = sink.map { Int(pc_load_u32(&$0.pointee.frames)) } ?? 0
            latency.inputLatencyFrames = 0
            latency.outputLatencyFrames = 0
        } else {
            latency.bufferFrames = Int((try? HAL.get(device, kAudioDevicePropertyBufferFrameSize, g, UInt32(0))) ?? 0)
            latency.inputLatencyFrames = !audioInput ? 0 : Int(((try? HAL.get(device, kAudioDevicePropertyLatency, i, UInt32(0))) ?? 0)
                + ((try? HAL.get(device, kAudioDevicePropertySafetyOffset, i, UInt32(0))) ?? 0))
            latency.outputLatencyFrames = sink != nil ? 0 : Int(((try? HAL.get(device, kAudioDevicePropertyLatency, o, UInt32(0))) ?? 0)
                + ((try? HAL.get(device, kAudioDevicePropertySafetyOffset, o, UInt32(0))) ?? 0))
        }
        var seconds = 0.0
        for unit in effects + [instrument].compactMap({ $0 }) {
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
        if started {
            // Fade out before the device stops, so stopping is not a hard cut.
            let out = stages.advanced(by: stageCount - 1)
            pc_store_u32(&out.pointee.swapRequested, 0)
            out.pointee.fadeTarget = 0
            let deadline = Date(timeIntervalSinceNow: 0.1)
            while out.pointee.fade > 0, Date() < deadline { usleep(1000) }
        }
        // Stop whatever pulls the graph before anything the callbacks touch goes away.
        if let clock, let sink {
            pc_store_u32(&sink.pointee.stop, 1)
            pthread_join(clock, nil)
        }
        if let hal {
            AudioOutputUnitStop(hal)
            AudioUnitUninitialize(hal)
        }
        for unit in effects {
            AudioUnitUninitialize(unit)
            // Detach from units that are about to be disposed or rewired.
            var none = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        if let instrument {
            AudioUnitUninitialize(instrument)
            if instrumentInput != nil {
                var none = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
                AudioUnitSetProperty(instrument, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            }
        }
        if let converter {
            AudioUnitUninitialize(converter)
            AudioComponentInstanceDispose(converter)
        }
        if let hal { AudioComponentInstanceDispose(hal) }
        if aggregate != 0 { HAL.destroyAggregate(aggregate); aggregate = 0 }
        if let sink {
            for buffer in sink.pointee.buffers { buffer.mData?.deallocate() }
            free(sink.pointee.buffers.unsafeMutablePointer)
            sink.deinitialize(count: 1)
            sink.deallocate()
        }
        for stage in [instrumentStage, instrumentInput].compactMap({ $0 }) {
            stage.pointee.peaks.deallocate()
            stage.deinitialize(count: 1)
            stage.deallocate()
        }
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

    // Live rewiring. The UI thread fills `pending*` on every stage, then sets
    // `swapRequested` on the output stage; the output stage's callback fades
    // out, copies pending -> active for every stage, and fades back in.
    var pendingUpstream: AudioUnit?
    var pendingBus: UInt32 = 0
    /// MIDI for `upstream` when it is an instrument or music effect, drained into
    /// it just before it renders. Moves with `upstream` on a swap.
    var midiRing: UnsafeMutablePointer<pc_midi_ring>?
    var pendingMidiRing: UnsafeMutablePointer<pc_midi_ring>?
    var isOutput = false
    /// Output stage only: the whole stage array, for the swap.
    var allStages: UnsafeMutablePointer<StageContext>?
    var stageCount = 0
    var swapRequested: UInt32 = 0
    var fade: Float = 1
    var fadeTarget: Float = 1
    var fadeStep: Float = 0
    /// Output stage only: frames of enforced silence after start, while the
    /// plugins and the device input settle. Counts down on the render thread.
    var holdFrames: Int = 0

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
    if ctx.pointee.isOutput {
        if pc_load_u32(&ctx.pointee.swapRequested) != 0 {
            ctx.pointee.fadeTarget = 0
            if ctx.pointee.fade == 0, let all = ctx.pointee.allStages {
                // Silent: safe to repoint every stage.
                for i in 0..<ctx.pointee.stageCount {
                    all[i].upstream = all[i].pendingUpstream
                    all[i].upstreamBus = all[i].pendingBus
                    all[i].midiRing = all[i].pendingMidiRing
                }
                pc_store_u32(&ctx.pointee.swapRequested, 0)
                ctx.pointee.fadeTarget = 1
            }
        }
    }
    guard let upstream = ctx.pointee.upstream else { silence(ioData); return noErr }
    if let ring = ctx.pointee.midiRing {
        // MIDI that arrived since the last cycle, into the unit about to render, at
        // the start of this buffer. Events are packed status << 16 | data1 << 8 | data2.
        // Bounded: what was pending on entry, at most 256; the rest waits a cycle.
        var event: UInt32 = 0
        for _ in 0..<min(pc_midi_ring_count(ring), 256) where pc_midi_ring_pop(ring, &event) {
            MusicDeviceMIDIEvent(upstream, event >> 16, event >> 8 & 0x7F, event & 0x7F, 0)
        }
    }
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
    if ctx.pointee.isOutput, ctx.pointee.holdFrames > 0 {
        // Warm-up: everything upstream has rendered, but keep the output silent.
        ctx.pointee.holdFrames -= Int(frames)
        silence(ioData)
    } else if ctx.pointee.isOutput, ctx.pointee.fade != ctx.pointee.fadeTarget {
        // Linear ramp toward the target, continuing across buffers if needed.
        let start = ctx.pointee.fade
        let target = ctx.pointee.fadeTarget
        let maxDelta = ctx.pointee.fadeStep * Float(frames)
        let end = target > start ? min(start + maxDelta, target) : max(start - maxDelta, target)
        var step = (end - start) / Float(frames)
        for c in 0..<min(buffers.count, ctx.pointee.width) {
            guard let data = buffers[c].mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            var s = start  // vDSP_vrampmul advances `s` in place, so each channel needs its own copy
            vDSP_vrampmul(p, 1, &s, &step, p, 1, n)
        }
        ctx.pointee.fade = end
    } else if ctx.pointee.isOutput, ctx.pointee.fade == 0 {
        silence(ioData)
    }
    return noErr
}

/// None output: what the output stage renders into instead of the HAL output
/// bus, and the state of whatever pulls it (the HAL unit's input callback,
/// or the clock thread). Plain data only.
struct SinkContext {
    /// The output stage.
    let stage: UnsafeMutablePointer<StageContext>
    let width: Int
    /// `width` non-interleaved float buffers of `capacity` frames each.
    let buffers: UnsafeMutableAudioBufferListPointer
    let capacity: Int
    let sampleRate: Double
    /// Cycles pulled so far.
    var cycles: UInt64 = 0
    /// Clock thread only: frames per cycle, written by the UI thread.
    var frames: UInt32
    /// Clock thread only: set by the UI thread to end it.
    var stop: UInt32 = 0

    init(stage: UnsafeMutablePointer<StageContext>, width: Int, capacity: Int, sampleRate: Double, frames: UInt32) {
        self.stage = stage
        self.width = width
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.frames = frames
        buffers = AudioBufferList.allocate(maximumBuffers: width)
        let bytes = capacity * MemoryLayout<Float>.size
        for i in 0..<width {
            buffers[i].mNumberChannels = 1
            buffers[i].mDataByteSize = UInt32(bytes)
            buffers[i].mData = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        }
    }
}

/// Realtime: pull one cycle of `frames` through the output stage into the sink.
private func sinkRender(_ ctx: UnsafeMutablePointer<SinkContext>, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) {
    let sink = ctx.pointee
    guard Int(frames) <= sink.capacity else { sink.stage.pointee.renderErrors &+= 1; return }
    for i in 0..<sink.width { sink.buffers[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
    _ = stageRender(UnsafeMutableRawPointer(sink.stage), flags, timestamp, 0, frames, sink.buffers.unsafeMutablePointer)
    ctx.pointee.cycles &+= 1
}

/// Realtime: the HAL unit's input callback when there is no output device.
/// Each IO cycle it pulls the chain, whose first stage renders the HAL input bus.
private let sinkInputProc: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    sinkRender(refCon.assumingMemoryBound(to: SinkContext.self), flags, timestamp, frames)
    return noErr
}

/// The clock thread, when no device is involved: pulls the chain every
/// `frames` frames of wall-clock time at the sink's sample rate, under the
/// time-constraint scheduling policy CoreAudio's own IO thread uses. Touches
/// nothing but the sink.
private func clockMain(_ arg: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let ctx = arg.assumingMemoryBound(to: SinkContext.self)
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticksPerFrame = 1e9 * Double(timebase.denom) / Double(timebase.numer) / ctx.pointee.sampleRate
    let ticksPerSecond = UInt64(ticksPerFrame * ctx.pointee.sampleRate)
    // A cycle's work within half its period; best effort.
    let period = UInt32(clamping: UInt64(Double(pc_load_u32(&ctx.pointee.frames)) * ticksPerFrame))
    var policy = thread_time_constraint_policy(period: period, computation: period / 4, constraint: period / 2, preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
    withUnsafeMutablePointer(to: &policy) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            _ = thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    var next = mach_absolute_time()
    var sampleTime = 0.0
    while pc_load_u32(&ctx.pointee.stop) == 0 {
        let frames = pc_load_u32(&ctx.pointee.frames)
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mHostTime = next
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        var flags = AudioUnitRenderActionFlags()
        sinkRender(ctx, &flags, &timestamp, frames)
        sampleTime += Double(frames)
        next &+= UInt64(Double(frames) * ticksPerFrame)
        let now = mach_absolute_time()
        if next > now {
            mach_wait_until(next)
        } else if now &- next > ticksPerSecond {
            next = now  // over a second behind (the machine slept): skip ahead rather than catch up
        }
    }
    return nil
}

private func silence(_ abl: UnsafeMutablePointer<AudioBufferList>) {
    for buffer in UnsafeMutableAudioBufferListPointer(abl) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
}
