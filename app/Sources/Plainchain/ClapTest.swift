import AppKit
import AudioToolbox
import AVFoundation
import ClapHost
import Foundation

/// `Plainchain --clap-test <bundle.clap>`
/// Headless check of the CLAP bridge that opens no audio device: registers
/// the bundle's plugins as in-process Audio Units, lists the directories the
/// app scans (a `CLAP_PATH` directory is scanned here too), checks the
/// component codes derived from CLAP ids, creates the bundle's first plugin
/// (an instrument) through `AVAudioUnit.instantiate` as `PluginInstance.make`
/// does, and drives it through the C API the engine uses: the stream format,
/// maximum frames, `AudioUnitInitialize`, `MusicDeviceMIDIEvent`, and
/// `AudioUnitRender`. Then its parameter tree, its full state on a fresh
/// instance, a parameter value reported from inside the plugin, and its own
/// editor. Prints each reading; exits nonzero on the first failure.
@MainActor
enum ClapTest {
    static let sampleRate = 48000.0
    static let blockFrames: UInt32 = 512
    /// The maximum frames per slice the engine sets.
    static let maxFrames: UInt32 = 4096
    static let blocksPerSecond = Int((sampleRate / Double(blockFrames)).rounded(.up))
    static let soundingDb: Float = -40
    static let silentDb: Float = -60
    static let noteOn: UInt32 = 0x90
    static let noteOff: UInt32 = 0x80
    static let middleC: UInt32 = 60
    static let velocity: UInt32 = 100
    static let observerWait: TimeInterval = 1

    static func run() {
        do {
            // The instances are gone when the pool drains, before the bundles are deinitialized.
            try autoreleasepool { try go() }
        } catch {
            print("FAIL: \(error.localizedDescription)")
            print(Plugins.shutdownClap())
            exit(1)
        }
        print(Plugins.shutdownClap())
        print("PASS")
        exit(0)
    }

    private static func expect(_ condition: Bool, _ failure: @autoclosure () -> String) throws {
        if !condition { throw EngineError(failure()) }
    }

    private static func go() throws {
        guard let path = CommandLine.arguments.drop(while: { $0 != "--clap-test" }).dropFirst().first else {
            throw EngineError("usage: Plainchain --clap-test <bundle.clap>")
        }

        // ---- Registration and the registry.
        let registered = pc_clap_register_bundle(path)
        print("registered \(path): \(registered) plugin(s)")
        try expect(registered > 0, "the bundle registered no plugin")
        let directory = (path as NSString).deletingLastPathComponent
        let scanned = pc_clap_scan(directory)
        print("scan of \(directory): \(scanned) plugin(s)")
        try expect(scanned >= registered, "the scan found fewer plugins than the bundle holds")
        try checkDirectories()
        var mine: [pc_clap_plugin] = []
        for i in 0..<pc_clap_count() {
            var p = pc_clap_plugin()
            guard pc_clap_plugin_at(i, &p) else { continue }
            print("  \(FourCC.string(p.type)) \(FourCC.string(p.subtype)) \(FourCC.string(p.manufacturer))  \(String(cString: p.vendor)): \(String(cString: p.name))  [\(String(cString: p.clap_id))] \(String(cString: p.path))")
            if String(cString: p.path) == path { mine.append(p) }
        }
        guard let plugin = mine.first else { throw EngineError("the registry lists nothing from \(path)") }
        let name = String(cString: plugin.name)
        let vendor = String(cString: plugin.vendor)
        try expect(FourCC.string(plugin.type) == "aumu", "\(name) is listed as \(FourCC.string(plugin.type)), not aumu")
        try expect(!name.isEmpty && !vendor.isEmpty, "the plugin has no name or no vendor")
        print("plugin: \(vendor): \(name), listed as aumu")
        var found = pc_clap_plugin()
        try expect(pc_clap_lookup(plugin.type, plugin.subtype, plugin.manufacturer, &found)
                   && String(cString: found.clap_id) == String(cString: plugin.clap_id), "the lookup by description does not find the plugin")
        print("lookup by description: \(String(cString: found.clap_id)) in \(String(cString: found.path))")
        try checkCodes(plugin)

        var desc = AudioComponentDescription(componentType: plugin.type, componentSubType: plugin.subtype,
                                             componentManufacturer: plugin.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw EngineError("AudioComponentFindNext does not find the registered component") }
        var registeredDesc = AudioComponentDescription()
        try check(AudioComponentGetDescription(component, &registeredDesc), "reading the component's description")
        var componentName: Unmanaged<CFString>?
        AudioComponentCopyName(component, &componentName)
        let isV3 = registeredDesc.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
        print("AudioComponentFindNext: \"\(componentName?.takeRetainedValue() as String? ?? "")\", flags 0x\(String(registeredDesc.componentFlags, radix: 16)) (v3 flag \(isV3 ? "set" : "not set"))")
        let managed = AVAudioUnitComponentManager.shared().components(matching: desc).count
        print("AVAudioUnitComponentManager lists it: \(managed > 0 ? "yes" : "no")")

        // ---- An instance, set up through the C API as the engine sets an instrument up.
        let (av, completionOnMain) = try instantiate(desc)
        let unit = av.audioUnit
        let au = av.auAudioUnit
        let handle = Unmanaged.passUnretained(au).toOpaque()
        var info = pc_clap_unit_info()
        try expect(pc_clap_unit_read_info(handle, &info), "the instance is a \(type(of: au)), not a ClapAudioUnit")
        print("instance: \(type(of: au)) via \(type(of: av)), completion \(completionOnMain ? "on" : "off") the main thread, plugin created \(info.created_on_main_thread ? "on" : "off") the main thread")
        print("  ports: \(info.input_channels) in, \(info.output_channels) out; notes as \(["nothing", "CLAP note events", "MIDI"][Int(info.note_dialect)])")

        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var mono = floatFormat(channels: 1)
        let monoStatus = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &mono, formatSize)
        print("mono output format: \(monoStatus == noErr ? "accepted" : "refused (\(monoStatus))")")
        var stereo = floatFormat(channels: 2)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stereo, formatSize), "stereo output format")
        var frames = maxFrames
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size)), "max frames")
        try check(AudioUnitInitialize(unit), "initialize")
        pc_clap_unit_read_info(handle, &info)
        try expect(info.active, "the plugin is not active after AudioUnitInitialize")
        print("stereo float output at \(Int(sampleRate)) Hz, \(maxFrames) max frames, initialized: plugin active, latency \(info.latency_frames) frames (\(au.latency) s)")

        // ---- A note through MusicDeviceMIDIEvent, rendered through AudioUnitRender.
        let renderer = Renderer(unit: unit, frames: blockFrames)
        defer { renderer.free() }
        let before = try renderer.render(blocks: 4)
        print("before the note: peak \(db(before.max()!)) dBFS")
        let held = try play(renderer, unit, on: true)
        pc_clap_unit_read_info(handle, &info)
        print("note on, \(blocksPerSecond) blocks: peak \(db(held.max()!)) dBFS; MIDI render events \(info.midi_render_events), CLAP notes sent \(info.note_events), process calls \(info.process_calls)")
        try expect(info.midi_render_events > 0, "MusicDeviceMIDIEvent reached the render block as no AURenderEventMIDI")
        try expect(db(held.max()!) > soundingDb, "the note peaked at \(db(held.max()!)) dBFS, not above \(soundingDb)")
        let inPlace = try renderer.render(blocks: 4, unitBuffers: true)
        print("with null mData (rendered in place into the unit's buffers): peak \(db(inPlace.max()!)) dBFS")
        try expect(db(inPlace.max()!) > soundingDb, "rendering in place yielded \(db(inPlace.max()!)) dBFS")
        let released = try play(renderer, unit, on: false)
        pc_clap_unit_read_info(handle, &info)
        print("note off, \(blocksPerSecond) blocks: last block peak \(db(released.last!)) dBFS; MIDI render events \(info.midi_render_events), CLAP notes sent \(info.note_events)")
        try expect(db(released.last!) < silentDb, "a second after note off the output is \(db(released.last!)) dBFS, not below \(silentDb)")

        // ---- Parameters: the tree, and a value set through AUParameterSet by
        // the C API's own parameter ID, as the engine and the smoke address one.
        guard let tree = au.parameterTree else { throw EngineError("the unit has no parameter tree") }
        let parameters = tree.allParameters
        print("parameter tree: \(parameters.count) parameters, \(tree.children.filter { $0 is AUParameterGroup }.count) groups")
        try expect(!parameters.isEmpty, "the parameter tree is empty")
        for p in parameters.prefix(8) {
            print("  \(p.address) \(p.keyPath) '\(p.displayName)' [\(p.minValue)...\(p.maxValue)] = \(p.string(fromValue: nil))")
        }
        let listed = Plugins.v2Parameters(unit)
        let sameIds = listed.filter { v2 in parameters.contains { $0.address == AUParameterAddress(v2.id) } }.count
        print("C API parameter list: \(listed.count) IDs, \(sameIds) of them equal to a tree address")
        try expect(listed.count == parameters.count, "the C API lists \(listed.count) parameters, the tree \(parameters.count)")
        guard let chosen = listed.first(where: {
            AudioUnitParameterOptions(rawValue: $0.flags).contains(.flag_IsWritable) && $0.unit != AudioUnitParameterUnit.indexed.rawValue && $0.min < $0.max
        }) else { throw EngineError("no writable continuous parameter") }
        func pluginValues() -> [AUParameterAddress: Double] {
            var values: [AUParameterAddress: Double] = [:]
            for p in parameters {
                var v = Double.nan
                pc_clap_unit_param_value(handle, UInt32(p.address), &v)
                values[p.address] = v
            }
            return values
        }
        let start = pluginValues()
        var current: AudioUnitParameterValue = 0
        try check(AudioUnitGetParameter(unit, chosen.id, kAudioUnitScope_Global, 0, &current), "AudioUnitGetParameter")
        let target = chosen.max - current > current - chosen.min ? chosen.max : chosen.min
        let eventsBefore = (info.host_parameter_events, info.parameter_render_events)
        var auParameter = AudioUnitParameter(mAudioUnit: unit, mParameterID: chosen.id, mScope: kAudioUnitScope_Global, mElement: 0)
        try check(AUParameterSet(nil, nil, &auParameter, target, 0), "AUParameterSet")
        let unrendered = pluginValues()
        _ = try renderer.render(blocks: 1)
        let rendered = pluginValues()
        pc_clap_unit_read_info(handle, &info)
        // The tree parameter AUParameterSet reached is the one whose value in the plugin moved.
        let moved = parameters.filter { rendered[$0.address] != start[$0.address] }
        let movedEarly = parameters.filter { unrendered[$0.address] != start[$0.address] }.count
        print("'\(chosen.name)' (C API ID \(chosen.id)) set from \(current) to \(target) by AUParameterSet: before a block \(movedEarly) plugin value(s) moved, after one \(moved.map { "\($0.address) '\($0.displayName)' = \(rendered[$0.address]!)" }); reached the plugin as \(info.host_parameter_events - eventsBefore.0) tree-observer value(s), \(info.parameter_render_events - eventsBefore.1) render event(s)")
        guard moved.count == 1, let parameter = moved.first, parameter.displayName == chosen.name else {
            throw EngineError("AUParameterSet moved \(moved.count) plugin values, not exactly '\(chosen.name)'")
        }
        let id = UInt32(parameter.address)
        let reported = rendered[parameter.address]!
        try expect(abs(reported - Double(target)) <= 1e-5 * max(1, Double(chosen.max - chosen.min)), "the plugin reports \(reported), not \(target)")

        // ---- State: fullState read, set on a fresh instance, read again.
        let saved = au.fullState ?? [:]
        let stateBytes = (saved["clap-state"] as? Data)?.count ?? 0
        print("fullState keys: \(saved.keys.sorted().joined(separator: ", ")); clap-state \(stateBytes) bytes")
        try expect(stateBytes > 0, "fullState holds no clap-state bytes")
        let (fresh, _) = try instantiate(desc)
        fresh.auAudioUnit.fullState = saved
        let back = fresh.auAudioUnit.fullState ?? [:]
        let freshHandle = Unmanaged.passUnretained(fresh.auAudioUnit).toOpaque()
        var freshValue = 0.0
        pc_clap_unit_param_value(freshHandle, id, &freshValue)
        let same = NSDictionary(dictionary: saved).isEqual(to: back)
        var freshInfo = pc_clap_unit_info()
        pc_clap_unit_read_info(freshHandle, &freshInfo)
        print("state into a fresh instance: reads back \(same ? "equal" : "DIFFERENT"); its '\(parameter.displayName)' is \(freshValue); values the base class's restore sent to the plugin: \(freshInfo.host_parameter_events)")
        if !same {
            for key in Set(saved.keys).union(back.keys).sorted() {
                let a = saved[key] as AnyObject?, b = back[key] as AnyObject?
                if !(a?.isEqual(b) ?? (b == nil)) { print("  differs: \(key)") }
            }
        }
        try expect(same, "fullState did not round-trip")
        try expect(freshValue == Double(target), "the fresh instance's '\(parameter.displayName)' is \(freshValue), not \(target)")
        try expect(freshInfo.host_parameter_events == 0, "the base class's restore sent \(freshInfo.host_parameter_events) values beside the plugin's own state")
        // As the smoke does after loading state: a value set through the C API on the
        // fresh instance, which is not initialized, reaches the plugin and its observers.
        // The C API's IDs come from the parameters' key paths, so they are the same in every instance.
        guard let freshTree = fresh.auAudioUnit.parameterTree else { throw EngineError("the fresh instance has no parameter tree") }
        var freshHeard: [AUParameterAddress] = []
        let freshToken = freshTree.token(byAddingParameterObserver: { address, _ in
            DispatchQueue.main.async { freshHeard.append(address) }
        })
        defer { freshTree.removeParameterObserver(freshToken) }
        let freshEvents = freshInfo.host_parameter_events
        var freshParameter = AudioUnitParameter(mAudioUnit: fresh.audioUnit, mParameterID: chosen.id, mScope: kAudioUnitScope_Global, mElement: 0)
        let freshTarget = freshValue == Double(chosen.max) ? chosen.min : chosen.max
        try check(AUParameterSet(nil, nil, &freshParameter, freshTarget, 0), "AUParameterSet on the fresh instance")
        let freshDeadline = Date(timeIntervalSinceNow: observerWait)
        while !freshHeard.contains(parameter.address) && Date() < freshDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        var freshAfter = Double.nan
        pc_clap_unit_param_value(freshHandle, id, &freshAfter)
        pc_clap_unit_read_info(freshHandle, &freshInfo)
        print("AUParameterSet on the uninitialized fresh instance, '\(chosen.name)' to \(freshTarget): get_value \(freshAfter), flushed \(freshInfo.host_parameter_events - freshEvents) value(s), observer \(freshHeard.contains(parameter.address) ? "heard it" : "heard nothing")")
        try expect(freshAfter == Double(freshTarget), "the uninitialized plugin reports \(freshAfter), not \(freshTarget)")
        try expect(freshHeard.contains(parameter.address), "no observer heard the value set on the uninitialized instance")

        // ---- A value the plugin changes from inside reaches the tree's observers.
        let inside = target == chosen.max ? chosen.min : chosen.max
        var heard: [(address: AUParameterAddress, value: AUValue, onMain: Bool)] = []
        let token = tree.token(byAddingParameterObserver: { address, value in
            let onMain = Thread.isMainThread
            DispatchQueue.main.async { heard.append((address, value, onMain)) }
        })
        defer { tree.removeParameterObserver(token) }
        // Observers are throttled; notifications of the changes above arrive first.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        heard.removeAll()
        try expect(pc_clap_unit_post_plugin_param(handle, id, Double(inside)), "the bridge's parameter queues are full")
        // The block in which the plugin takes the value, before the main thread drains its report.
        _ = try renderer.render(blocks: 1)
        pc_clap_unit_read_info(handle, &info)
        let hostEvents = info.host_parameter_events
        let deadline = Date(timeIntervalSinceNow: observerWait)
        while !heard.contains(where: { $0.address == parameter.address }) && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        _ = try renderer.render(blocks: 1)
        pc_clap_unit_read_info(handle, &info)
        var holds = Double.nan
        pc_clap_unit_param_value(handle, id, &holds)
        guard let call = heard.first(where: { $0.address == parameter.address }) else {
            throw EngineError("no parameter-tree observer heard the plugin's value within \(observerWait) s")
        }
        print("plugin moved '\(parameter.displayName)' to \(inside) (get_value \(holds)) and reported it: observer heard \(call.value), called on \(call.onMain ? "the main thread" : "another thread"); sent back to the plugin: \(info.host_parameter_events - hostEvents) value(s)")
        try expect(call.value == inside, "the observer heard \(call.value), not \(inside)")
        try expect(info.host_parameter_events == hostEvents, "the plugin's own value was sent back to it")

        try checkEditor(au, unit, handle, renderer)

        try check(AudioUnitUninitialize(unit), "uninitialize")
        pc_clap_unit_read_info(handle, &info)
        print("uninitialized: plugin \(info.active ? "STILL ACTIVE" : "deactivated"); dropped events \(info.dropped_events)")
        try expect(!info.active, "the plugin is still active after AudioUnitUninitialize")
        try expect(info.dropped_events == 0, "\(info.dropped_events) events were dropped")
    }

    /// A `CLAP_PATH` value with an empty entry, a trailing slash, a `..`, a
    /// repeat, and a standard directory, and the directories it adds.
    static let syntheticClapPath = "/Volumes/A/CLAP::/Volumes/B/CLAP/:/Volumes/A/CLAP:/Volumes/C/x/../CLAP:/Library/Audio/Plug-Ins/CLAP"
    static let syntheticClapPathAdds = ["/Volumes/A/CLAP", "/Volumes/B/CLAP", "/Volumes/C/CLAP"]

    /// The directories the app scans: the standard two, then `CLAP_PATH`'s,
    /// each listed; a directory only `CLAP_PATH` names is scanned here as
    /// well. Then the reading of a made-up `CLAP_PATH`.
    private static func checkDirectories() throws {
        let clapPath = ProcessInfo.processInfo.environment["CLAP_PATH"]
        let directories = Plugins.clapDirectories
        print("directories the app scans (CLAP_PATH \(clapPath.map { "\"\($0)\"" } ?? "unset")):")
        for directory in directories {
            let standard = Plugins.standardClapDirectories.contains(directory)
            print("  \(directory)\(standard ? "" : ": \(pc_clap_scan(directory)) plugin(s)")")
        }
        try expect(Array(directories.prefix(2)) == Plugins.standardClapDirectories, "the standard directories are not scanned first")
        let read = Plugins.clapDirectories(clapPath: syntheticClapPath)
        print("CLAP_PATH \"\(syntheticClapPath)\" adds \(read.dropFirst(2))")
        try expect(read == Plugins.standardClapDirectories + syntheticClapPathAdds, "CLAP_PATH read as \(read)")
    }

    /// Synthetic CLAP ids whose component codes the check derives; among them
    /// are ids whose hash maps to a code beginning "0x".
    static let syntheticIds = 4096
    static let syntheticIdFormat = "studio.plainchain.synthetic-%d"

    /// The component codes the registry derives from a CLAP id: the plugin's
    /// own as registered, and for `syntheticIds` made-up ids, none beginning
    /// "0x" (which FourCC reads as hexadecimal), none holding a byte outside
    /// '!' through '~', and each the same after FourCC's text and back.
    private static func checkCodes(_ plugin: pc_clap_plugin) throws {
        var subtype: UInt32 = 0, manufacturer: UInt32 = 0
        pc_clap_component_codes(plugin.clap_id, &subtype, &manufacturer)
        print("component codes of \(String(cString: plugin.clap_id)): \(FourCC.string(subtype)) \(FourCC.string(manufacturer))")
        try expect(subtype == plugin.subtype && manufacturer == plugin.manufacturer, "the registered codes are not the ones derived from the CLAP id")
        var moved = 0
        var hex: [String] = []
        var unprintable: [String] = []
        var unreadable: [String] = []
        for i in 0..<syntheticIds {
            let id = String(format: syntheticIdFormat, i)
            if pc_clap_component_codes(id, &subtype, &manufacturer) { moved += 1 }
            for code in [subtype, manufacturer] {
                let bytes = withUnsafeBytes(of: code.bigEndian) { Array($0) }
                if bytes[0] == UInt8(ascii: "0") && bytes[1] == UInt8(ascii: "x") { hex.append(id) }
                if !bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) { unprintable.append(id) }
                if FourCC.code(FourCC.string(code)) != code { unreadable.append(id) }
            }
        }
        print("component codes of \(syntheticIds) synthetic ids: \(moved) moved off \"0x\", \(hex.count) beginning \"0x\", \(unprintable.count) with a byte outside '!'...'~', \(unreadable.count) changed by FourCC's text and back")
        try expect(moved > 0, "no synthetic id's code would have begun \"0x\"; the check exercises nothing")
        try expect(hex.isEmpty, "codes beginning \"0x\": \(hex.prefix(5))")
        try expect(unprintable.isEmpty, "codes with a byte outside '!'...'~': \(unprintable.prefix(5))")
        try expect(unreadable.isEmpty, "codes changed by FourCC's text and back: \(unreadable.prefix(5))")
    }

    /// Middle C on or off through `MusicDeviceMIDIEvent`, then a second of
    /// blocks; each block's peak.
    private static func play(_ renderer: Renderer, _ unit: AudioUnit, on: Bool) throws -> [Float] {
        if on {
            try check(MusicDeviceMIDIEvent(unit, noteOn, middleC, velocity, 0), "note on")
        } else {
            try check(MusicDeviceMIDIEvent(unit, noteOff, middleC, 0, 0), "note off")
        }
        return try renderer.render(blocks: blocksPerSecond)
    }

    /// The plugin's own editor, asked for as `EditorWindow.open` asks a v3
    /// unit: the view controller arrives on the main thread, its view the size
    /// `clap.gui` get_size reports. Put in a window that is never ordered
    /// front, the window's content takes that size, fixed when the GUI cannot
    /// resize; closing the window destroys the GUI, the controller goes away
    /// when released, and the plugin still plays a note.
    private static func checkEditor(_ au: AUAudioUnit, _ unit: AudioUnit, _ handle: UnsafeMutableRawPointer, _ renderer: Renderer) throws {
        // No Dock icon and no activation for the window below.
        NSApplication.shared.setActivationPolicy(.prohibited)
        weak var gone: NSViewController?
        try autoreleasepool {
            var answer: (controller: NSViewController?, onMain: Bool)?
            au.requestViewController { controller in answer = (controller, Thread.isMainThread) }
            let deadline = Date(timeIntervalSinceNow: observerWait)
            while answer == nil && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            guard let answer else { throw EngineError("requestViewController did not answer within \(observerWait) s") }
            guard let controller = answer.controller else { throw EngineError("requestViewController answered no view controller") }
            let view = controller.view
            var width: UInt32 = 0, height: UInt32 = 0
            var resizable = false
            try expect(pc_clap_unit_gui_size(handle, &width, &height, &resizable), "clap.gui get_size reports no size while the editor is open")
            var info = pc_clap_unit_info()
            pc_clap_unit_read_info(handle, &info)
            let size = NSSize(width: Double(width), height: Double(height))
            print("editor: \(type(of: controller)) answered \(answer.onMain ? "on" : "off") the main thread; GUI \(info.editor_open ? "open" : "NOT OPEN"); view bounds \(view.bounds.size), clap.gui get_size \(width) x \(height), \(resizable ? "resizable" : "fixed size")")
            try expect(answer.onMain, "the view controller arrived off the main thread")
            try expect(info.editor_open, "the plugin's GUI is not open in the editor's view")
            try expect(view.bounds.size == size, "the view is \(view.bounds.size), the GUI \(size)")
            var secondAnswered = false
            var second: NSViewController?
            au.requestViewController { controller in second = controller; secondAnswered = true }
            let secondDeadline = Date(timeIntervalSinceNow: observerWait)
            while !secondAnswered && Date() < secondDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            print("a second request while the editor is open: \(!secondAnswered ? "NO ANSWER" : second == nil ? "no view controller" : "ANOTHER VIEW CONTROLLER")")
            try expect(secondAnswered && second == nil, "a second request while the editor is open did not answer nil")
            // A few frames of the GUI's own drawing.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            let content = window.contentRect(forFrameRect: window.frame).size
            print("in a window never ordered front: content \(content), min \(window.contentMinSize), max \(window.contentMaxSize); visible \(window.isVisible)")
            try expect(!window.isVisible, "the window is on screen")
            try expect(content == size, "the window's content is \(content), the GUI \(size)")
            if !resizable {
                try expect(window.contentMinSize == size && window.contentMaxSize == size, "the window of a fixed-size GUI can be resized")
            }
            window.close()
            pc_clap_unit_read_info(handle, &info)
            print("window closed: GUI \(info.editor_open ? "STILL OPEN" : "destroyed")")
            try expect(!info.editor_open, "closing the window left the plugin's GUI open")
            window.contentViewController = nil
            gone = controller
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        print("editor released: view controller \(gone == nil ? "gone" : "STILL ALIVE")")
        try expect(gone == nil, "the view controller outlived its release")

        let held = try play(renderer, unit, on: true)
        let released = try play(renderer, unit, on: false)
        print("after the editor: note on peak \(db(held.max()!)) dBFS, a second after note off \(db(released.last!)) dBFS")
        try expect(db(held.max()!) > soundingDb, "after the editor the note peaked at \(db(held.max()!)) dBFS, not above \(soundingDb)")
        try expect(db(released.last!) < silentDb, "after the editor a second after note off is \(db(released.last!)) dBFS, not below \(silentDb)")
    }

    /// `AVAudioUnit.instantiate`, as `PluginInstance.make` calls it, waited for
    /// on the main run loop; also whether its completion ran on the main thread.
    private static func instantiate(_ desc: AudioComponentDescription) throws -> (AVAudioUnit, Bool) {
        var result: Result<(AVAudioUnit, Bool), Error>?
        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
            let onMain = Thread.isMainThread
            DispatchQueue.main.async {
                if let unit { result = .success((unit, onMain)) } else { result = .failure(error ?? EngineError("could not instantiate the plugin")) }
            }
        }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return try result!.get()
    }

    private static func floatFormat(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
    }

    private static func db(_ peak: Float) -> Float { 20 * log10(max(peak, 1e-12)) }

    /// Pulls blocks out of a unit through `AudioUnitRender` into a stereo
    /// float non-interleaved buffer list, with the sample time advancing.
    private final class Renderer {
        let unit: AudioUnit
        let frames: UInt32
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let channels: [UnsafeMutablePointer<Float>]
        var sampleTime: Float64 = 0

        init(unit: AudioUnit, frames: UInt32) {
            self.unit = unit
            self.frames = frames
            channels = (0..<2).map { _ in .allocate(capacity: Int(frames)) }
        }

        func free() {
            channels.forEach { $0.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }

        /// Each block's peak over both channels. With `unitBuffers` the list's
        /// data pointers are null, for the unit to point at its own buffers.
        func render(blocks: Int, unitBuffers: Bool = false) throws -> [Float] {
            var peaks: [Float] = []
            for _ in 0..<blocks {
                for c in 0..<2 {
                    list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: unitBuffers ? nil : UnsafeMutableRawPointer(channels[c]))
                }
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = sampleTime
                timestamp.mFlags = .sampleTimeValid
                var flags = AudioUnitRenderActionFlags()
                try check(AudioUnitRender(unit, &flags, &timestamp, 0, frames, list.unsafeMutablePointer), "render")
                var peak: Float = 0
                for c in 0..<2 {
                    guard let data = list[c].mData else { throw EngineError("the render left channel \(c) without data") }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(frames) { peak = max(peak, abs(samples[i])) }
                }
                peaks.append(peak)
                sampleTime += Float64(frames)
            }
            return peaks
        }
    }
}
