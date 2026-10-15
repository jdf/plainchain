import AVFoundation
import Foundation

/// An installed Audio Unit effect.
struct Plugin: Identifiable, Hashable {
    let id: PluginId
    let name: String
    let manufacturer: String
}

enum Plugins {
    /// Every installed effect (`aufx`) and music-effect (`aumf`) Audio Unit.
    static func installed() -> [Plugin] {
        let manager = AVAudioUnitComponentManager.shared()
        var out: [Plugin] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let wanted = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in manager.components(matching: wanted) {
                out.append(Plugin(id: PluginId(c.audioComponentDescription), name: c.name, manufacturer: c.manufacturerName))
            }
        }
        return out.sorted {
            let m = $0.manufacturer.localizedCaseInsensitiveCompare($1.manufacturer)
            return m == .orderedSame ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : m == .orderedAscending
        }
    }

    /// A read-only parameter that reports gain reduction, if the plugin has one.
    struct ReductionMeter {
        let unit: AudioUnit
        let id: AudioUnitParameterID
        /// True when the plugin reports reduction as a negative dB value rather than a positive amount.
        let negative: Bool

        /// Current reduction in dB, ≤ 0.
        var value: Float {
            var v: AudioUnitParameterValue = 0
            AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &v)
            return negative ? min(v, 0) : -abs(v)
        }
    }

    /// Looks for a meter flagged read-only (or simply not writable) whose name
    /// says gain reduction; failing that, any read-only meter in dB.
    static func gainReductionMeter(_ unit: AudioUnit) -> ReductionMeter? {
        let readOnly = v2Parameters(unit).filter {
            let f = AudioUnitParameterOptions(rawValue: $0.flags)
            return f.contains(.flag_MeterReadOnly) || !f.contains(.flag_IsWritable)
        }
        func named(_ p: V2Parameter) -> Bool {
            let n = p.name.lowercased()
            return n.contains("reduction") || n.contains("gain red") || n.contains("compression amount")
                || n.split(whereSeparator: { !$0.isLetter }).contains("gr")
        }
        guard let p = readOnly.first(where: named) ?? readOnly.first(where: { $0.unit == AudioUnitParameterUnit.decibels.rawValue }) else { return nil }
        return ReductionMeter(unit: unit, id: p.id, negative: p.min < 0)
    }

    struct V2Parameter {
        let id: AudioUnitParameterID
        let name: String
        let flags: UInt32
        let unit: UInt32
        let min: Float
        let max: Float
    }

    /// The v2 global parameter list with its info; includes read-only meters
    /// that the v3 parameter tree leaves out.
    static func v2Parameters(_ unit: AudioUnit) -> [V2Parameter] {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr, size > 0 else { return [] }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size) == noErr else { return [] }
        return ids.compactMap { id in
            var info = AudioUnitParameterInfo()
            var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &infoSize) == noErr else { return nil }
            let name: String
            if info.flags.contains(.flag_HasCFNameString), let cf = info.cfNameString {
                name = cf.takeUnretainedValue() as String
                if info.flags.contains(.flag_CFNameRelease) { cf.release() }
            } else {
                name = withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            return V2Parameter(id: id, name: name, flags: info.flags.rawValue, unit: info.unit.rawValue, min: info.minValue, max: info.maxValue)
        }
    }

    /// Instantiate a plugin. In-process when the plugin allows it, so the
    /// engine can wire its raw Audio Unit directly.
    static func instantiate(_ id: PluginId) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: id.description, options: []) { unit, error in
                if let unit { cont.resume(returning: unit) } else { cont.resume(throwing: error ?? EngineError("could not load plugin")) }
            }
        }
    }
}
