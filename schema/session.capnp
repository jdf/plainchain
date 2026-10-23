# Plainchain session records. Each struct is stored as one flat Cap'n Proto
# message in a blob column of the session's SQLite file (see Session.swift).
@0xb7e1c4a2d9f36051;

struct Endpoint {
  deviceUid @0 :Text;
  channels  @1 :List(UInt32);   # zero-based device channels in use
  midiSource @2 :Text;          # input only: non-empty means MIDI input; a CoreMIDI source's
                                # kMIDIPropertyUniqueID in decimal, or "*" for all sources
  midiSourceName @3 :Text;      # that source's display name when it was chosen
}

struct ChainItem {
  id           @0 :Text;        # UUID, stable across reorders within a session
  type         @1 :Text;        # Audio Unit component type, as a four-character code
  subtype      @2 :Text;
  manufacturer @3 :Text;
  bypass       @4 :Bool;
  state        @5 :Data;        # AUAudioUnit.fullState as a binary plist; empty if none
  inputGainDb  @6 :Float32;     # trim applied before the plugin, in dB (0 = unity)
}

struct Settings {
  bufferFrames @0 :UInt32;      # requested device IO buffer; 0 leaves the device's current size
}
