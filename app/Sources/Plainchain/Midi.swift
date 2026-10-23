import CapnSession
import CoreMIDI
import Foundation

/// A CoreMIDI source the input can listen to.
struct MidiSource: Identifiable, Hashable {
    let uniqueID: Int32
    let name: String
    var id: Int32 { uniqueID }
}

/// The app's MIDI input: one CoreMIDI client, one input port connected to the
/// chosen source (or every source), and a virtual destination named
/// "Plainchain" that other apps can send to, which counts as one more source
/// under "all sources".
///
/// Nothing here calls into an Audio Unit. The receive blocks run on CoreMIDI's
/// thread and only push packed events into the lock-free rings of `fanout`
/// (`pc_midi.h`); the engine's render thread drains them into the instrument
/// and music effects. Use from the main thread.
final class MidiInput {
    static let destinationName = "Plainchain"
    static let allSourcesName = "All MIDI Sources"

    /// Allocated once and never freed: CoreMIDI's receive blocks hold it.
    let fanout: UnsafeMutablePointer<pc_midi_fanout> = pc_midi_fanout_new()
    private(set) var sources: [MidiSource] = []
    /// Called on the main thread when the source list changes.
    var onSourcesChanged: (([MidiSource]) -> Void)?
    /// The virtual destination other apps send to.
    private(set) var destination = MIDIEndpointRef()
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// "" (none), "*" (all), or a source's unique ID.
    private var selection = ""
    private var connected: Set<MIDIEndpointRef> = []

    init() {
        MIDIClientCreateWithBlock("Plainchain" as CFString, &client) { [weak self] note in
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.setupChanged() }
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port, Self.receiver(fanout, virtual: false))
        MIDIDestinationCreateWithProtocol(client, Self.destinationName as CFString, ._1_0, &destination, Self.receiver(fanout, virtual: true))
        sources = Self.scan()
    }

    /// The fanout is left allocated: a receive block may still be finishing.
    deinit { MIDIClientDispose(client) }

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

    /// Sources came or went: refresh the list and reconnect, so a source that comes back works again.
    private func setupChanged() {
        let s = Self.scan()
        if s != sources { sources = s; onSourcesChanged?(s) }
        connected = connected.filter { e in (0..<MIDIGetNumberOfSources()).contains { MIDIGetSource($0) == e } }
        connect(selection)
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

    /// The receive block, on CoreMIDI's thread: no allocation and no Swift
    /// objects, only the fanout pointer. Takes MIDI 1.0 channel-voice messages
    /// (UMP type 2) and ignores everything else.
    private static func receiver(_ fanout: UnsafeMutablePointer<pc_midi_fanout>, virtual: Bool) -> MIDIReceiveBlock {
        // Packets are variable-length: read only `wordCount` words in place, never the declared 64.
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        return { list, _ in
            if virtual, pc_load_u32(&fanout.pointee.virtual_enabled) == 0 { return }
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let words = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    // status << 16 | data1 << 8 | data2, the group nibble dropped.
                    if w >> 28 == 2 { pc_midi_fanout_push(fanout, w & 0x00FF_7F7F) }
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
