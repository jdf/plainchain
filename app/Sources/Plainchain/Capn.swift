import CapnSession
import Foundation

/// Swift face of the Cap'n Proto records in schema/session.capnp.
enum Capn {
    static func encode(_ e: Endpoint) -> Data {
        let buf = e.channels.withUnsafeBufferPointer { pc_endpoint_encode(e.deviceUid, $0.baseAddress, $0.count, e.midiSource, e.midiSourceName) }
        defer { pc_buf_free(buf) }
        return Data(bytes: buf.bytes, count: buf.len)
    }

    static func decodeEndpoint(_ data: Data) throws -> Endpoint {
        guard let r = data.withUnsafeBytes({ pc_endpoint_read($0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count) }) else {
            throw EngineError("malformed endpoint record")
        }
        defer { pc_endpoint_free(r) }
        return Endpoint(
            deviceUid: String(cString: pc_endpoint_device_uid(r)),
            channels: (0..<pc_endpoint_channel_count(r)).map { pc_endpoint_channel(r, $0) },
            midiSource: String(cString: pc_endpoint_midi_source(r)),
            midiSourceName: String(cString: pc_endpoint_midi_source_name(r))
        )
    }

    static func encode(_ c: ChainItem) -> Data {
        let state = c.state ?? Data()
        let buf = state.withUnsafeBytes { s in
            pc_chain_item_encode(c.id.uuidString, c.plugin.type, c.plugin.subtype, c.plugin.manufacturer, c.bypass,
                                 s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count, c.inputGainDb)
        }
        defer { pc_buf_free(buf) }
        return Data(bytes: buf.bytes, count: buf.len)
    }

    static func decodeChainItem(_ data: Data) throws -> ChainItem {
        guard let r = data.withUnsafeBytes({ pc_chain_item_read($0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count) }) else {
            throw EngineError("malformed chain record")
        }
        defer { pc_chain_item_free(r) }
        let state = pc_chain_item_state(r)
        return ChainItem(
            id: UUID(uuidString: String(cString: pc_chain_item_id(r))) ?? UUID(),
            plugin: PluginId(
                type: String(cString: pc_chain_item_type(r)),
                subtype: String(cString: pc_chain_item_subtype(r)),
                manufacturer: String(cString: pc_chain_item_manufacturer(r))
            ),
            bypass: pc_chain_item_bypass(r),
            inputGainDb: pc_chain_item_input_gain_db(r),
            state: state.len > 0 ? Data(bytes: state.bytes, count: state.len) : nil
        )
    }

    static func encodeSettings(bufferFrames: Int) -> Data {
        let buf = pc_settings_encode(UInt32(max(bufferFrames, 0)))
        defer { pc_buf_free(buf) }
        return Data(bytes: buf.bytes, count: buf.len)
    }

    static func decodeSettings(_ data: Data) throws -> Int {
        var frames: UInt32 = 0
        let ok = data.withUnsafeBytes { pc_settings_decode($0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count, &frames) }
        guard ok else { throw EngineError("malformed settings record") }
        return Int(frames)
    }
}
