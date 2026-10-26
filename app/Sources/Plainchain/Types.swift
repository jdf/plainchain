import AudioToolbox
import Foundation

/// A four-character code as text, e.g. "aufx".
enum FourCC {
    static func string(_ code: UInt32) -> String {
        let bytes = withUnsafeBytes(of: code.bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return String(decoding: bytes, as: UTF8.self) }
        return String(format: "0x%08x", code)
    }

    static func code(_ s: String) -> UInt32 {
        if s.hasPrefix("0x"), let v = UInt32(s.dropFirst(2), radix: 16) { return v }
        let b = Array(s.utf8)
        guard b.count == 4 else { return 0 }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
}

/// Identifies an Audio Unit by component description; stored as text so session files stay readable.
struct PluginId: Hashable {
    var type: String
    var subtype: String
    var manufacturer: String

    init(type: String, subtype: String, manufacturer: String) {
        self.type = type; self.subtype = subtype; self.manufacturer = manufacturer
    }

    init(_ d: AudioComponentDescription) {
        type = FourCC.string(d.componentType)
        subtype = FourCC.string(d.componentSubType)
        manufacturer = FourCC.string(d.componentManufacturer)
    }

    /// A music device (`aumu`): a chain head that turns MIDI into audio.
    var isInstrument: Bool { type == "aumu" }
    /// Instruments and music effects (`aumf`) are sent the session's MIDI input.
    var receivesMidi: Bool { type == "aumu" || type == "aumf" }

    var description: AudioComponentDescription {
        AudioComponentDescription(
            componentType: FourCC.code(type), componentSubType: FourCC.code(subtype),
            componentManufacturer: FourCC.code(manufacturer), componentFlags: 0, componentFlagsMask: 0
        )
    }
}

/// An audio device plus the zero-based device channels in use, or the "None"
/// pseudo-device. The input endpoint also carries the session's MIDI source,
/// which is independent of its audio side: either can be on or off.
struct Endpoint: Equatable {
    /// The pseudo-device that means no audio device: an input that feeds the
    /// chain no audio, or an output that goes nowhere.
    static let noneUid = "com.plainchain.none"

    var deviceUid: String
    var channels: [UInt32]
    /// Input only: a CoreMIDI source's `kMIDIPropertyUniqueID` in decimal,
    /// "*" for every source, or "" for no MIDI.
    var midiSource = ""
    /// The source's display name when it was chosen, for showing it while it is gone.
    var midiSourceName = ""

    static let none = Endpoint(deviceUid: noneUid, channels: [])

    /// No audio, MIDI from `source`.
    static func midi(_ source: String, name: String) -> Endpoint {
        Endpoint(deviceUid: noneUid, channels: [], midiSource: source, midiSourceName: name)
    }

    /// Input only: a MIDI source is chosen.
    var hasMidi: Bool { !midiSource.isEmpty }
    /// "None": no audio device (an input may still have MIDI).
    var isNone: Bool { deviceUid == Self.noneUid }
    /// An audio device, present or not.
    var isDevice: Bool { !isNone }
}

struct ChainItem: Identifiable, Equatable {
    var id = UUID()
    var plugin: PluginId
    var bypass = false
    /// Trim applied before the plugin, in dB; after it, for an instrument.
    var inputGainDb: Float = 0
    /// The plugin's `fullState`, as a binary plist. Only populated while saving or loading.
    var state: Data?
}

/// Everything a session file holds.
struct Session: Equatable {
    var input: Endpoint
    var output: Endpoint
    var chain: [ChainItem] = []
    /// Requested device IO buffer in frames; 0 leaves the device's current size alone.
    var bufferFrames = 0
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turn an OSStatus into a thrown error with a readable hint.
func check(_ status: OSStatus, _ what: String) throws {
    guard status != noErr else { return }
    let hint: String
    switch status {
    case kAudioUnitErr_FormatNotSupported: hint = "format not supported (the plugin may not accept this channel count)"
    case kAudioUnitErr_FailedInitialization: hint = "failed to initialize"
    case kAudioUnitErr_InvalidProperty: hint = "invalid property"
    case kAudioUnitErr_InvalidElement: hint = "invalid element"
    case kAudioUnitErr_Uninitialized: hint = "uninitialized"
    case kAudioHardwareNotRunningError: hint = "device not running"
    case kAudioHardwareUnknownPropertyError: hint = "unknown property"
    case kAudioHardwareBadDeviceError: hint = "bad device"
    case kAudioHardwareUnsupportedOperationError: hint = "unsupported operation"
    default: hint = FourCC.string(UInt32(bitPattern: status))
    }
    throw EngineError("\(what) failed: \(hint) (\(status))")
}
