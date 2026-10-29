# CLAP plugins in Plainchain

Plainchain hosts Audio Units. This document is the plan for hosting
CLAP plugins beside them, in chunks an agent can take one at a time.
Every chunk names what it builds, what it needs, and the test that
shows it done. The first chunk is the proof of the approach; if it
fails, the plan changes before anything else is built.

## Terms

- **CLAP**: the CLever Audio Plug-in format, a C API (MIT, by
  free-audio). A CLAP plugin on macOS is a bundle with the `.clap`
  extension whose executable exports one symbol, `clap_entry`, a struct
  of function pointers. Installed bundles live in
  `~/Library/Audio/Plug-Ins/CLAP` and `/Library/Audio/Plug-Ins/CLAP`.
- **Entry, factory, descriptor, plugin**: `clap_entry` gives a plugin
  factory; the factory lists descriptors (an id string such as
  `studio.whatissoftware.nfp5`, a name, a vendor, and feature strings
  such as `instrument` or `audio-effect`) and creates a plugin from a
  descriptor's id. One bundle can hold several plugins.
- **Extension**: an optional interface a plugin or a host offers by
  name. The plugin extensions this plan uses: `clap.audio-ports` (the
  plugin's input and output ports and their channel counts),
  `clap.note-ports` (whether it takes notes, and in which dialect: CLAP
  note events or raw MIDI), `clap.params` (its parameters), `clap.state`
  (saving and loading its settings as bytes), `clap.latency`, and
  `clap.gui` (its editor, on macOS a Cocoa view the host gives a parent
  view). The host extensions a plugin may ask for: `clap.log`,
  `clap.thread-check`, `clap.params` (the plugin asks for a rescan or a
  flush), `clap.state` (the plugin says its state changed), `clap.gui`
  (the plugin asks to be resized or closed), `clap.latency`.
- **Process**: the plugin's audio call. The host hands it a block of
  input and output buffers, a list of input events (notes, MIDI,
  parameter values, each at a frame offset), and a list the plugin
  pushes output events into (parameter values its own editor changed,
  note ends).
- **In-process Audio Unit**: an `AUAudioUnit` subclass that
  `AUAudioUnit.registerSubclass` registers with the system under a
  component description, so `AudioComponentFindNext`,
  `AudioComponentInstanceNew`, and `AVAudioUnit.instantiate` find and
  create it like any installed unit, inside this process. The old C
  API the engine uses (`AudioUnitRender`, `AudioUnitSetProperty`,
  `MusicDeviceMIDIEvent`) reaches such a unit through Apple's bridge.
- **Bridged unit**: one CLAP plugin instance presented as one
  in-process Audio Unit, the class `ClapAudioUnit`.

## Design

Plainchain's engine wires Audio Units and nothing else: render
callbacks, `MakeConnection`, `MusicDeviceMIDIEvent`, bypass and
latency properties, `fullState`, parameter trees, and
`requestViewController`. The design keeps that true. At launch, and
on each rescan, the app scans the CLAP directories, loads each bundle,
reads its descriptors, and registers a `ClapAudioUnit` component for
every plugin, named `Vendor: Name`, under a component description
derived from the CLAP id. From then on a CLAP plugin is one more entry
in the plugin list, created through `PluginInstance.make` on the
version 3 path, wired by the engine as a version 3 unit, edited through
`requestViewController`, saved through `fullState`, and observed
through its parameter tree.

The component description: the type is `aumu` for a plugin whose
features include `instrument`, `aumf` for an audio effect with a note
input port, `aufx` otherwise; the subtype and manufacturer are two
32-bit halves of a 64-bit hash of the CLAP id, so a given plugin always
gets the same description and two plugins never share one in practice.
A registry in `ClapHost` maps each registered description back to the
bundle path and the CLAP id, and `ClapAudioUnit`'s initializer looks
its plugin up there.

The session file keeps the chain item's component description, as
today, and adds the CLAP id and bundle path beside it, so a session
read on another machine, or after a rescan, re-registers the same
plugin before instantiating it. A file whose chain holds a CLAP plugin
is written at format version 5: an older Plainchain would look up the
component description, find nothing, and report the plugin as not
installed, which is a failure it reports rather than a misreading, but
a version it refuses is clearer than a chain item it cannot explain.

What a bridged unit does:

- **Busses**: one output bus from the plugin's first output port, with
  that port's channel count as the only channel count it accepts, or
  stereo and mono for a port the plugin lets the host choose; an input
  bus from the first input port when there is one. The engine sets the
  chain's width as the stream format; a plugin whose port cannot take
  it fails `allocateRenderResources` with `kAudioUnitErr_FormatNotSupported`,
  which Plainchain already explains to the user.
- **Render**: `allocateRenderResources` activates the plugin at the
  sample rate and maximum frames; the render block pulls the input bus
  (for an effect), builds the input event list from the Audio Unit
  events of the slice (MIDI bytes become `clap_event_midi` when the
  note port takes MIDI, else note on and off events; parameter events
  become parameter value events), calls `process`, copies the first
  output port's channels into the output buffers, and reads the output
  events: a parameter value from the plugin goes into a lock-free
  queue the main thread drains into the parameter tree. The render
  block allocates nothing: every buffer and list is sized at
  `allocateRenderResources`.
- **Parameters**: an `AUParameterTree` built from `clap.params`, one
  `AUParameter` per parameter with the CLAP id as its address, its
  range, its name, and its module as the group name. A value the host
  sets reaches the plugin as a parameter value event at the start of
  the next block (a queue the render block drains), or through
  `params.flush` when the unit is not rendering. A value the plugin
  reports (its editor moved a knob) is set on the tree on the main
  thread, which is what `PluginInstance.startObserving` watches to
  mark the session edited.
- **State**: `fullState` is a dictionary holding the bytes of
  `clap.state` save under one key, beside the keys Apple's base class
  writes; setting it loads those bytes. The chain item's record stores
  it as a binary plist exactly as for any version 3 unit.
- **Latency**: `latency` from `clap.latency`, re-read when the plugin
  says it changed.
- **Editor**: `requestViewController` answers with a view controller
  whose view is the parent the plugin's `clap.gui` draws into, sized
  as the plugin asks, and resized when the plugin asks for it; closing
  the window destroys the GUI. A plugin without a GUI gets no view
  controller, and `EditorWindow` falls back to `AUGenericView` as it
  does today.
- **Bypass**: `shouldBypassEffect` is honored by copying input to
  output around the plugin, since CLAP has no bypass of its own.
- **Threads**: the plugin is created, activated, and destroyed on the
  main thread; `process` runs on whatever thread renders; `clap.log`
  goes to the console; `clap.thread-check` answers truthfully;
  `request_callback` runs the plugin's `on_main_thread` on the main
  queue.

## Layout

| Path | What |
|---|---|
| `app/Sources/ClapHost/include/clap/` | The CLAP headers, vendored unchanged from free-audio/clap 1.2 with their MIT license. |
| `app/Sources/ClapHost/include/clap_host.h` | The C face Swift uses: scan, the registry, and what a bridged unit needs. |
| `app/Sources/ClapHost/ClapLoader.mm` | Loading bundles, entries, factories, descriptors; the registry of registered components. |
| `app/Sources/ClapHost/ClapAudioUnit.mm` | The `AUAudioUnit` subclass: busses, render, parameters, state, latency, the host object. |
| `app/Sources/ClapHost/ClapEditor.mm` | The view controller that hosts the plugin's Cocoa GUI. |
| `app/Sources/Plainchain/Plugins.swift` | Lists CLAP plugins beside Audio Units. |
| `app/Sources/Plainchain/ClapTest.swift` | The headless check `--clap-test`, which needs no audio device. |

`ClapHost` is a second C++ target in `app/Package.swift`, Objective-C++
(`.mm`), depending on nothing but the system frameworks. Swift sees
it through the C header only.

## Chunks

### Chunk K1: the bridged unit, proven headless

Goal: `Plainchain --clap-test <bundle path>` loads a CLAP bundle,
registers its plugins, creates one through `AVAudioUnit.instantiate`
exactly as `PluginInstance.make` does, and proves the bridge the
engine depends on, all without an audio device.

Needs: nothing. Work: the `ClapHost` target with the vendored headers;
`ClapLoader.mm` (scan a directory, load a bundle, read its
descriptors, register a `ClapAudioUnit` per descriptor, the registry);
`ClapAudioUnit.mm` with busses, render, MIDI and note events,
parameters, state, and latency; `ClapTest.swift`.

Test, run on the host (no device is opened): with
`~/Library/Audio/Plug-Ins/CLAP/nfp5.clap`, `--clap-test` must show

- the plugin listed as `aumu` with a name and vendor;
- an instance created through `AVAudioUnit.instantiate`, whose
  `audioUnit` handle accepts a stereo float stream format on its
  output, `kAudioUnitProperty_MaximumFramesPerSlice`, and
  `AudioUnitInitialize`, as the engine sets them;
- `MusicDeviceMIDIEvent` note on, then `AudioUnitRender` through the C
  API for a second of blocks, yielding a peak above -40 dBFS; note
  off, then a second more, yielding silence below -60 dBFS at the end;
- the parameter tree lists the plugin's parameters; setting one
  through `AUParameterSet` and rendering a block makes the plugin
  report that value through `clap.params` get_value;
- `fullState` read, set on a fresh instance, read again, equal;
- a parameter the plugin changes from inside (simulated by the test
  through the host's own queue) fires a parameter-tree observer on the
  main thread.

Record in this document what the bridge does and does not deliver
(MIDI through `MusicDeviceMIDIEvent`, in particular). If the bridge
cannot deliver MIDI to an in-process version 3 unit, stop and record
it: the fallback is a render-callback stage in the engine that calls
`process` directly, and the plan is rewritten before chunk K3.

### Chunk K2: the records

Goal: a chain item can name a CLAP plugin, and a session with one
round-trips.

Needs: nothing (independent of K1). Work: `schema/session.capnp`
appends `clapId @7 :Text` and `clapPath @8 :Text` to `ChainItem`;
`tools/gen-capnp.sh` regenerates the C++, committed; `capn_session.h`
and `Capn.swift` carry the fields; `PluginId` gains an optional CLAP
identity (id and path) that `Plugin` and `ChainItem` carry;
`SessionFile.version(of:)` returns 5 for a chain with a CLAP item and
`formatVersion` becomes 5; the README's format table gains the fields
and the version.

Test: the smoke's session round trip, extended with a chain item that
names a CLAP plugin by id and path (no instance needed), reads back
equal at version 5; a file at version 5 is refused by `formatVersion`
4 code, which the test shows by checking the pragma.

### Chunk K3: CLAP plugins in the plugin list and the chain

Goal: the picker offers installed CLAP plugins, adding one works, and
a saved session with one reopens.

Needs: K1, K2. Work: `AppState` scans and registers CLAP plugins at
launch and on `refreshPlugins`, from the two standard directories;
`Plugins.installed()` appends them, each `Plugin` carrying its CLAP
identity; `PluginInstance.make` re-registers a chain item's plugin from
its path before instantiating when the registry lacks it, and reports
"not installed" when the bundle is gone; `Model.add`, `load`, and
`snapshot` carry the identity; the picker shows a `CLAP` tag beside
the name.

Test: `make smoke PLUGINS=nfp5` in the test VM (`tools/testvm.sh`
pushes `nfp5.clap` into the guest's `~/Library/Audio/Plug-Ins/CLAP`
beside the app): the chain builds with nfp5 as the instrument, the
session round-trips with its state, the state loads into a fresh
instance quietly, and a parameter set through the AU API is
signalled, as the existing smoke checks for Audio Units. The MIDI
smoke (`PC_MIDI=1`) gains a pass with nfp5 at the head in place of
the DLS synth, played by the virtual source.

### Chunk K4: the editor

Goal: double-clicking a CLAP plugin opens its own editor.

Needs: K1. Work: `ClapEditor.mm`, the view controller;
`ClapAudioUnit`'s `requestViewController` override; the host's
`clap.gui` extension (resize requests change the window's content
size; a close request closes the window); the editor is destroyed
when the window closes, and the plugin survives it.

Test: `--clap-test` gains a step that asks for the view controller,
checks its view's size matches `clap.gui` get_size, and releases it;
and, by hand, nfp5's panel in a Plainchain window on jdf's machine,
knobs moving the sound and marking the session edited.

### Chunk K5: the headless proof in the test VM and the README

Goal: the hosting is documented and gated.

Needs: K3, K4. Work: a README section, "CLAP plugins", in the register
of the rest: what is scanned, how a CLAP plugin appears, what the
bridge does, the session fields, the version; `CLAUDE.md` gains the
`--clap-test` rule beside `make smoke`; `tools/testvm.sh` gains
`clap`, which pushes the app and `nfp5.clap` and runs the smoke with
nfp5 in the guest.

Test: `make clap-test` (host, headless) and `tools/testvm.sh clap`
both pass.

## Rules for every chunk

- Read `CLAUDE.md` and `README.md` first; the render block and the
  engine's callbacks are realtime code, with no allocation, locks,
  logging, or Swift object access.
- Never `make install`, and never `make smoke` on the host: the first
  replaces the app jdf may be running, the second routes the live
  microphone to the speakers. `--clap-test` opens no device and runs
  on the host; everything with a device runs in the test VM through
  `tools/testvm.sh`.
- Work in a jj workspace of `~/projects/plainchain`, one commit per
  chunk with a message in the repository's register (what changed and
  where), on top of the working-copy commit that holds the None
  endpoints work.
- The CLAP headers are vendored unchanged; a change the host needs is
  made in `ClapHost`, never in them.

## Status

- 2026-10-29: plan written. K1 and K2 started.
- 2026-10-29: K1 done in `09efb44f`: `Plainchain --clap-test <bundle>`
  (`make clap-test`, nfp5 by default) passes on the host with no device
  opened. What the bridge delivers:
  - Registration: `AudioComponentFindNext` finds a registered plugin,
    with `kAudioComponentFlag_IsV3AudioUnit` set (flags 0x14), and
    `AVAudioUnitComponentManager` lists it. `AVAudioUnit.instantiate`
    makes an `AVAudioUnitMIDIInstrument` around the `ClapAudioUnit`; its
    completion and the plugin's creation both run on the main thread.
    philinabox, with no note port, is registered as `aufx` after a
    probe instance is asked for its note ports.
  - MIDI: `MusicDeviceMIDIEvent` on the unit's C handle reaches the
    render block as an `AURenderEventMIDI` through the base class's
    `scheduleMIDIEventBlock`; no override is needed. nfp5 takes CLAP note
    events: a note on peaks at -18.1 dBFS, and a second after the note
    off the output is digital silence.
  - Render: `AudioUnitRender` through the C API; with null `mData` the
    unit points the list at its own buffers. A mono output format is
    refused when it is set, with `kAudioUnitErr_FormatNotSupported`.
  - Parameter IDs: the C API's IDs (`kAudioUnitProperty_ParameterList`,
    `AudioUnitSetParameter`, `AUParameterSet`) are not the tree's
    addresses. AudioToolbox derives each from the parameter's key path
    and ignores the address: the IDs stayed the same with the addresses
    replaced by 0 to 49, and changed with the identifiers. The addresses
    stay the CLAP ids, and Plainchain already takes the C API's IDs from
    the unit's own list. A key path holds the group identifier ("g" and
    the module's position), so a plugin version that inserts a module
    changes those IDs; Plainchain stores none of them.
  - Parameter values: `AUParameterSet` on an initialized unit reaches
    the render block as an `AURenderEventParameter`, not through
    `implementorValueObserver`; on an uninitialized one it reaches
    `implementorValueObserver`, which flushes it to the plugin, and the
    tree's observers hear it. A value the plugin reports is set on the
    tree on the main thread and is not sent back to the plugin.
  - Observers: the tree calls its observers on an AudioToolbox thread,
    as Apple documents ("an arbitrary thread context"), with the
    parameter's current value, which the bridge reads from the plugin
    through `get_value`. The main thread is where the bridge sets the
    value; `PluginInstance.startObserving` already moves the
    notification to the main thread.
  - State: `fullState` holds `clap-state` (1755 bytes for nfp5) beside
    the base class's `data`, `manufacturer`, `subtype`, `type`, and
    `version`, and reads back equal from a fresh instance. While the
    bytes are present, the parameter values the base class restores
    stay in the tree and none reach the plugin.
  - Identifiers: `AUParameterTree` throws for two parameters at one
    address (an experiment aborted the test that way once). Parameters
    are "p" and the CLAP id, groups "g" and their position; a repeated
    CLAP id is left out, and a tree the framework refuses leaves the
    unit with no parameters, logged.
  - Not exercised by nfp5 (no input port, a fixed stereo output, no
    latency): pulling the input bus, bypass,
    `clap.configurable-audio-ports`, a latency change, and a parameter
    rescan.
- 2026-10-29: K2 done in `f26af4aae1a8`: `ChainItem` carries `clapId` and
  `clapPath`, `PluginId` holds them, and a chain with a CLAP plugin is
  written at format version 5. `Plainchain --records-test` (`make
  records-test`, also run by the smoke) round-trips such a session at
  version 5 and shows a newer file refused, with no device opened.
