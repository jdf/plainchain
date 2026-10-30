import AVFoundation
import ClapHost
import Foundation

/// An installed Audio Unit or CLAP plugin: an effect or an instrument. A CLAP
/// plugin's `id` carries its CLAP identity (`PluginId.clapId` and `clapPath`)
/// beside the component description it is registered under, and its
/// manufacturer is the CLAP vendor.
struct Plugin: Identifiable, Hashable {
    let id: PluginId
    let name: String
    let manufacturer: String
    let isInstrument: Bool
}

enum Plugins {
    /// Where CLAP plugins are installed, the user's own first: a plugin in both
    /// is registered from the user's.
    static var clapDirectories: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/CLAP").path,
         "/Library/Audio/Plug-Ins/CLAP"]
    }

    /// Registers every CLAP plugin under `clapDirectories` as an in-process
    /// Audio Unit. A plugin registered before stays as it is, so a rescan
    /// registers only what was installed since. Main thread.
    static func registerClap() {
        for directory in clapDirectories { _ = pc_clap_scan(directory) }
    }

    /// Every installed effect (`aufx`), music-effect (`aumf`), and instrument
    /// (`aumu`) Audio Unit, then every registered CLAP plugin. A plugin installed
    /// in both formats is listed once for each; the components registered for
    /// CLAP plugins are listed only as CLAP plugins.
    static func installed() -> [Plugin] {
        let manager = AVAudioUnitComponentManager.shared()
        var out: [Plugin] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect, kAudioUnitType_MusicDevice] {
            let wanted = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in manager.components(matching: wanted) {
                let d = c.audioComponentDescription
                var registered = pc_clap_plugin()
                if pc_clap_lookup(d.componentType, d.componentSubType, d.componentManufacturer, &registered) { continue }
                let id = PluginId(d)
                out.append(Plugin(id: id, name: c.name, manufacturer: c.manufacturerName, isInstrument: id.isInstrument))
            }
        }
        for i in 0..<pc_clap_count() {
            var p = pc_clap_plugin()
            guard pc_clap_plugin_at(i, &p) else { continue }
            let id = clapId(p)
            out.append(Plugin(id: id, name: String(cString: p.name), manufacturer: String(cString: p.vendor), isInstrument: id.isInstrument))
        }
        // Manufacturer, then name, then the Audio Unit before the CLAP plugin of the same name.
        return out.sorted {
            let m = $0.manufacturer.localizedCaseInsensitiveCompare($1.manufacturer)
            if m != .orderedSame { return m == .orderedAscending }
            let n = $0.name.localizedCaseInsensitiveCompare($1.name)
            if n != .orderedSame { return n == .orderedAscending }
            return !$0.id.isClap && $1.id.isClap
        }
    }

    /// Before the process exits, once every plugin instance is gone (CLAP
    /// probes included): deinitializes the CLAP bundles. Nothing does it at
    /// exit, when a bundle's static storage may already be destroyed. With a
    /// plugin still alive it does nothing; it says which happened.
    static func shutdownClap() -> String {
        pc_clap_shutdown() ? "CLAP bundles deinitialized" : "CLAP bundles left initialized: a plugin is still alive"
    }

    /// The identity of a registered CLAP plugin: the component description
    /// registered for it, its CLAP id, and the bundle it was registered from.
    private static func clapId(_ p: pc_clap_plugin) -> PluginId {
        PluginId(type: FourCC.string(p.type), subtype: FourCC.string(p.subtype), manufacturer: FourCC.string(p.manufacturer),
                 clapId: String(cString: p.clap_id), clapPath: String(cString: p.path))
    }

    /// The registered CLAP plugin with this CLAP id, as `installed()` lists it.
    static func registeredClap(_ clapId: String) -> PluginId? {
        for i in 0..<pc_clap_count() {
            var p = pc_clap_plugin()
            if pc_clap_plugin_at(i, &p), String(cString: p.clap_id) == clapId { return Self.clapId(p) }
        }
        return nil
    }

    /// The registered identity of the CLAP plugin `id` names, registering the
    /// bundle at its `clapPath` first when the registry lacks the plugin (a
    /// session naming a bundle outside `clapDirectories`, or one installed
    /// since the last scan). The CLAP id decides: the registry's component
    /// description and bundle path replace the ones `id` holds. Main thread.
    static func registerClap(_ id: PluginId) throws -> PluginId {
        if let registered = registeredClap(id.clapId) { return registered }
        guard !id.clapPath.isEmpty, FileManager.default.fileExists(atPath: id.clapPath) else {
            throw EngineError("\(id.fallbackName): CLAP plugin not installed")
        }
        guard pc_clap_register_bundle(id.clapPath) >= 0 else { throw EngineError("\(id.fallbackName): the CLAP bundle \(id.clapPath) could not be loaded") }
        guard let registered = registeredClap(id.clapId) else { throw EngineError("\(id.fallbackName): \(id.clapPath) holds no plugin \(id.clapId)") }
        return registered
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
}
