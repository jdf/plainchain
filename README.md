# Plainchain

A macOS app that does exactly three things:

1. Pick an audio input device and its channels.
2. Run that audio through an ordered chain of Audio Unit effects you can add, remove, reorder, bypass, and open the editor for.
3. Pick an output device and its channels.

Sessions (devices, chain, and every plugin's state) save to `.plainchain` files: SQLite databases whose rows are Cap'n Proto messages.

## Layout

| Path | What |
|---|---|
| `app/Package.swift` | SwiftPM package; the whole app is one executable target. |
| `app/Sources/Plainchain/Engine.swift` | The realtime graph. |
| `app/Sources/Plainchain/Devices.swift` | CoreAudio HAL enumeration and aggregate-device creation. |
| `app/Sources/Plainchain/Plugins.swift` | Audio Unit discovery and instantiation. |
| `app/Sources/Plainchain/Model.swift` | App state: session edits, plugin instances, engine restarts, autosave, session files. |
| `app/Sources/Plainchain/Session.swift` | Session files: SQLite container, with a small sqlite3 wrapper. |
| `app/Sources/Plainchain/Capn.swift` | Swift face of the Cap'n Proto records. |
| `app/Sources/CapnSession/` | C++ target: generated schema code plus a C API over it for Swift. |
| `schema/session.capnp` | The record schema. `tools/gen-capnp.sh` regenerates the C++ after edits. |
| `app/Sources/Plainchain/Editors.swift` | Plugin editor windows. |
| `app/Sources/Plainchain/ContentView.swift` | The one window. |
| `app/Sources/Plainchain/Smoke.swift` | Headless engine check (`--smoke`). |
| `Makefile` | Builds and assembles `build/Plainchain.app`. |

## Build and run

```sh
make run        # swift build, bundle, open
make smoke      # headless: default in -> out for 2 s, then a session round trip
PC_IN="Loopback" PC_OUT="MacBook Air Speakers" make smoke PLUGINS="AUDelay AUGraphicEQ"
```

Requires Xcode (Swift 6) and Homebrew's `capnp` (`brew install capnp`) for its static library and headers; the `capnp` compiler itself is only needed to regenerate code after a schema change. Cap'n Proto is linked statically, so the bundle has no Homebrew dependency at runtime. The app must run from the bundle so macOS can ask for microphone access.

## Distributing

```sh
make dist       # sign, notarize (waits for Apple), staple, zip -> build/Plainchain.zip
```

Needs a notarytool keychain profile, created once with `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>`. Signing uses the identity in the `DEVELOPER_ID_APPLICATION` environment variable (set it in your shell profile); without it builds are ad-hoc signed, which runs locally but cannot be notarized. The notary profile defaults to `plainchain`; override with `make dist PROFILE=<profile>`.

## How the engine works

One CoreAudio HAL output unit handles both input (bus 1) and output (bus 0). When the chosen input and output are the same device, it is used directly. When they differ, the app creates a private aggregate device of the two, with the output device as clock master and drift compensation on the input, so CoreAudio handles clock drift and differing sample rates. The aggregate is destroyed when the graph is torn down.

Effects are wired with `kAudioUnitProperty_MakeConnection`. The first effect's render callback pulls the current IO cycle's input straight from the HAL unit into the effect's own buffers, so there is no intermediate buffer and no added latency beyond the device's own.

Plugin instances are `AVAudioUnit`s owned by the model, not the engine. The engine only sets their formats, wires them, and initializes them, so rebuilding the graph (device or channel change, reorder) keeps every plugin's settings. Editor windows come from `AUAudioUnit.requestViewController`, with `AUGenericView` as the fallback. Plugin state is `AUAudioUnit.fullState`, stored as a binary plist inside the chain item's record.

## Session file format

A `.plainchain` file is a SQLite database (`PRAGMA application_id` = `PLCH`, `user_version` = format version):

| Table | Columns | Row |
|---|---|---|
| `meta` | `key`, `value` | `saved` timestamp, `app` |
| `endpoint` | `role`, `message` | one `Endpoint` message for `input` and one for `output` |
| `chain` | `position`, `message` | one `ChainItem` message per slot, in chain order |

Messages are flat (unpacked) Cap'n Proto, per `schema/session.capnp`, so the `capnp` CLI can decode them straight out of the database:

```sh
sqlite3 s.plainchain "SELECT quote(message) FROM chain WHERE position=0" | sed "s/^X'//;s/'$//" | xxd -r -p | capnp decode schema/session.capnp ChainItem
```

Saves write a fresh database beside the target and swap it in atomically.

Constraints:

- The chain runs at the width of the input selection: one input channel means mono through every plugin. Plugins that only accept stereo fail to initialize with "format not supported"; select two input channels.
- Changing devices, channels, or adding or removing a plugin tears down and rebuilds the graph (a brief dropout). Reordering is live: the output fades to silence over 8 ms, the stages are repointed on the render thread, and it fades back in. Bypass and trim are applied live.

The engine starts running at launch; the Run switch pauses it. State between launches lives in `~/Library/Application Support/Plainchain/Autosave.plainchain`; the path of the last explicitly opened or saved session is in `defaults read com.plainchain.app`.

## License

MIT. See `LICENSE`.
