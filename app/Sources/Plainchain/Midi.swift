import CapnSession
import CoreMIDI
import Foundation

/// A CoreMIDI source the input can listen to.
struct MidiSource: Identifiable, Hashable {
    let uniqueID: Int32
    let name: String
    var id: Int32 { uniqueID }
}

/// The process's CoreMIDI client: the source list, setup-change
/// notifications, and the one virtual destination named "Plainchain" that
/// other apps can send to. Its events go to every `MidiInput` listening to
/// all sources, through the lock-free hub in `pc_midi.h`. Each session
/// window has its own `MidiInput`, a port on this client. Use from the main thread.
final class MidiSystem {
    static let destinationName = "Plainchain"

    private(set) var sources: [MidiSource] = []
    /// Called on the main thread when the source list changes.
    var onSourcesChanged: (([MidiSource]) -> Void)?
    /// The virtual destination other apps send to.
    private(set) var destination = MIDIEndpointRef()
    fileprivate var client = MIDIClientRef()
    /// Allocated once and never freed: the destination's receive block holds it.
    private let hub: UnsafeMutablePointer<pc_midi_hub> = pc_midi_hub_new()
    /// Fanouts of inputs that went away, for the next one. Never freed (a
    /// receive block may still be finishing), so they are reused instead.
    private var spare: [UnsafeMutablePointer<pc_midi_fanout>] = []
    private var inputs: [WeakInput] = []
    private struct WeakInput { weak var input: MidiInput? }

    init() {
        MIDIClientCreateWithBlock("Plainchain" as CFString, &client) { [weak self] note in
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.setupChanged() }
        }
        MIDIDestinationCreateWithProtocol(client, Self.destinationName as CFString, ._1_0, &destination, MidiInput.receiver(hub: hub))
        sources = Self.scan()
    }

    deinit { MIDIClientDispose(client) }

    /// A fanout for a new input, reached by the virtual destination (while the
    /// input enables it) unless more than `PC_MIDI_MAX_FANOUTS` exist at once.
    fileprivate func takeFanout() -> UnsafeMutablePointer<pc_midi_fanout> {
        if let f = spare.popLast() { return f }
        let f = pc_midi_fanout_new()!
        _ = pc_midi_hub_add(hub, f)
        return f
    }

    /// Reconnect `input` whenever the MIDI setup changes.
    fileprivate func attach(_ input: MidiInput) {
        inputs.removeAll { $0.input == nil }
        inputs.append(WeakInput(input: input))
    }

    /// Called from `MidiInput.deinit`, after its delivery is switched off.
    fileprivate func detach(_ fanout: UnsafeMutablePointer<pc_midi_fanout>) {
        spare.append(fanout)
    }

    /// Sources came or went: refresh the list and reconnect every input, so a source that comes back works again.
    private func setupChanged() {
        let s = Self.scan()
        if s != sources { sources = s; onSourcesChanged?(s) }
        inputs.removeAll { $0.input == nil }
        for i in inputs { i.input?.setupChanged() }
    }

    static func scan() -> [MidiSource] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let e = MIDIGetSource(i)
            guard e != 0 else { return nil }
            var id: Int32 = 0
            guard MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &name)
            return MidiSource(uniqueID: id, name: name.map { $0.takeRetainedValue() as String } ?? "MIDI source \(id)")
        }
    }
}

/// One session's MIDI input: an input port on the shared client, connected
/// to the chosen source (or every source, plus the shared virtual destination).
///
/// Nothing here calls into an Audio Unit. The receive blocks run on CoreMIDI's
/// thread and only push packed events into the lock-free rings of `fanout`
/// (`pc_midi.h`); the engine's render thread drains them into the instrument
/// and music effects. Use from the main thread.
final class MidiInput {
    static var destinationName: String { MidiSystem.destinationName }
    static let allSourcesName = "All MIDI Sources"

    let system: MidiSystem
    /// Never freed: CoreMIDI's receive blocks hold it. Reused by a later input once this one is gone.
    let fanout: UnsafeMutablePointer<pc_midi_fanout>
    private var port = MIDIPortRef()
    /// "" (none), "*" (all), or a source's unique ID.
    private var selection = ""
    private var connected: Set<MIDIEndpointRef> = []

    init(system: MidiSystem) {
        self.system = system
        fanout = system.takeFanout()
        MIDIInputPortCreateWithProtocol(system.client, "Input" as CFString, ._1_0, &port, Self.receiver(fanout: fanout))
        system.attach(self)
    }

    deinit {
        MIDIPortDispose(port)
        pc_store_u32(&fanout.pointee.virtual_enabled, 0)
        active = 0
        system.detach(fanout)
    }

    var sources: [MidiSource] { system.sources }

    /// Rings the receive blocks fill; 0 stops delivery (set before any engine teardown).
    var active: Int {
        get { Int(pc_load_u32(&fanout.pointee.active)) }
        set { pc_store_u32(&fanout.pointee.active, UInt32(min(max(newValue, 0), Int(PC_MIDI_MAX_RINGS)))) }
    }

    /// Events received since launch (wraps), for an activity light.
    var received: UInt32 { pc_load_u32(&fanout.pointee.received) }

    /// Listen to `selection` ("" for nothing, "*" for every source plus the
    /// virtual destination, or a source's unique ID), dropping the others.
    func connect(_ selection: String) {
        self.selection = selection
        pc_store_u32(&fanout.pointee.virtual_enabled, selection == "*" ? 1 : 0)
        var wanted: Set<MIDIEndpointRef> = []
        if selection == "*" {
            wanted = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.filter { $0 != 0 })
        } else if let id = Int32(selection) {
            var object = MIDIObjectRef()
            var type = MIDIObjectType.other
            if MIDIObjectFindByUniqueID(id, &object, &type) == noErr, type == .source { wanted = [object] }
        }
        for e in connected.subtracting(wanted) { MIDIPortDisconnectSource(port, e) }
        for e in wanted.subtracting(connected) where MIDIPortConnectSource(port, e, nil) != noErr { wanted.remove(e) }
        connected = wanted
    }

    /// All notes off (CC 123) and sustain off (CC 64) on every channel, through
    /// the rings like any event: nothing held on a source being left keeps sounding.
    func releaseAll() {
        for channel: UInt32 in 0..<16 {
            pc_midi_fanout_push(fanout, (0xB0 | channel) << 16 | 123 << 8)
            pc_midi_fanout_push(fanout, (0xB0 | channel) << 16 | 64 << 8)
        }
    }

    /// The MIDI setup changed: drop sources that are gone and reconnect.
    fileprivate func setupChanged() {
        connected = connected.filter { e in (0..<MIDIGetNumberOfSources()).contains { MIDIGetSource($0) == e } }
        connect(selection)
    }

    /// The receive block, on CoreMIDI's thread: no allocation and no Swift
    /// objects, only the fanout pointer (an input port's) or the hub pointer
    /// (the virtual destination's). Takes MIDI 1.0 channel-voice messages
    /// (UMP type 2) and ignores everything else.
    fileprivate static func receiver(fanout: UnsafeMutablePointer<pc_midi_fanout>? = nil, hub: UnsafeMutablePointer<pc_midi_hub>? = nil) -> MIDIReceiveBlock {
        // Packets are variable-length: read only `wordCount` words in place, never the declared 64.
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        return { list, _ in
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let words = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    // status << 16 | data1 << 8 | data2, the group nibble dropped.
                    if w >> 28 == 2 {
                        if let fanout { pc_midi_fanout_push(fanout, w & 0x00FF_7F7F) } else if let hub { pc_midi_hub_push(hub, w & 0x00FF_7F7F) }
                    }
                    i += umpWords(w >> 28)
                }
            }
        }
    }

    /// Length in words of a Universal MIDI Packet, by message type.
    private static func umpWords(_ type: UInt32) -> Int {
        switch type {
        case 0, 1, 2, 6, 7: return 1
        case 3, 4, 8, 9, 10: return 2
        case 11, 12: return 3
        default: return 4
        }
    }
}
