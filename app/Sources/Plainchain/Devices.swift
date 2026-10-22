import CoreAudio
import Foundation

/// One audio device as seen by the CoreAudio HAL.
struct Device: Identifiable, Hashable {
    /// Transient HAL object id; changes across reboots and hot-plugs.
    let id: AudioObjectID
    /// Stable identifier, suitable for saving in a session.
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let sampleRate: Double
    let defaultInput: Bool
    let defaultOutput: Bool
}

enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) throws -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { p in
            try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, p), "get \(FourCC.string(selector))")
        }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let cf: CFString? = try get(object, selector, kAudioObjectPropertyScopeGlobal, nil)
        return cf.map { $0 as String } ?? ""
    }

    static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> UInt32 {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "stream configuration size")
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "stream configuration")
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func sampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0.0)
    }

    /// Every device the HAL knows about, in HAL order.
    static func devices() throws -> [Device] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size), "device list size")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids), "device list")
        let defaultIn: AudioObjectID = try get(sys, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, 0)
        let defaultOut: AudioObjectID = try get(sys, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0)
        return try ids.map { id in
            Device(
                id: id,
                uid: try string(id, kAudioDevicePropertyDeviceUID),
                name: try string(id, kAudioObjectPropertyName),
                inputChannels: try channelCount(id, kAudioObjectPropertyScopeInput),
                outputChannels: try channelCount(id, kAudioObjectPropertyScopeOutput),
                sampleRate: try sampleRate(id),
                defaultInput: id == defaultIn,
                defaultOutput: id == defaultOut
            )
        }
    }

    /// The buffer sizes a device accepts, as powers of two within its reported range.
    static func bufferSizeChoices(_ device: AudioObjectID) -> [Int] {
        let range: AudioValueRange = (try? get(device, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, AudioValueRange())) ?? AudioValueRange(mMinimum: 32, mMaximum: 2048)
        var out: [Int] = []
        var n = 16
        while n <= Int(range.mMaximum) {
            if n >= Int(range.mMinimum) { out.append(n) }
            n *= 2
        }
        return out
    }

    static func setBufferSize(_ device: AudioObjectID, _ frames: Int) throws {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = UInt32(frames)
        try check(AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), "set buffer size")
    }

    /// UID prefix of the private aggregates this app creates.
    static let aggregatePrefix = "com.plainchain.aggregate."

    /// A private aggregate of two devices, with the output device as the clock
    /// master and drift compensation on the input. Returns the new device id.
    static func createAggregate(input: Device, output: Device) throws -> AudioObjectID {
        let description: [String: Any] = [
            "name": "Plainchain (\(input.name) → \(output.name))",
            "uid": aggregatePrefix + UUID().uuidString,
            "private": 1,
            "stacked": 0,
            "master": output.uid,
            "subdevices": [
                ["uid": input.uid, "drift": 1],
                ["uid": output.uid, "drift": 0],
            ],
        ]
        var id: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "create aggregate device")
        return id
    }

    static func destroyAggregate(_ id: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(id)
    }

    /// A property listener on a HAL object; removed when this is released.
    final class Listener {
        private let object: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        fileprivate init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) throws {
            self.object = object
            addr = HAL.address(selector)
            block = { _, _ in handler() }
            try check(AudioObjectAddPropertyListenerBlock(object, &addr, .main, block), "listen \(FourCC.string(selector))")
        }

        deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block) }
    }

    /// Call `handler` on the main queue whenever `selector` (global scope) of `object` changes.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) throws -> Listener {
        try Listener(object, selector, handler)
    }
}
