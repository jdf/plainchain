# Plainchain

macOS-only SwiftUI app: input device → chain of Audio Unit effects → output device, with plugin editors and session files. Everything is in `app/Sources/Plainchain`; read `README.md` for the engine design and its constraints.

- After every change: `make install`, which builds, bundles, and replaces `/Applications/Plainchain.app` (quitting a running copy first). `make run` opens the build-tree bundle instead. Always run from a bundle; a bare binary cannot get microphone permission.
- Engine check without the UI: `make smoke` (see the Makefile for `PC_IN`/`PC_OUT`/`PLUGINS`). Run it after any change to `Engine.swift` or `Devices.swift`, once on the same device for input and output and once on two different devices (that exercises the aggregate path).
- The render callback in `Engine.swift` is realtime code: no allocation, locks, logging, or Swift object access. State shared with the UI thread goes through plain fields plus the release/acquire helpers in `CapnSession/pc_atomic.h`; graph rewiring happens only on the render thread, under the output-stage fade.
- Session files are SQLite with Cap'n Proto blobs (`Session.swift`, `Capn.swift`, `schema/session.capnp`). After editing the schema run `tools/gen-capnp.sh` and commit the generated C++. Only append fields to the schema; bump `SessionFile.formatVersion` for anything a reader could misinterpret.
- The bundle is signed with jdf's Developer ID certificate (found automatically by the Makefile) so the microphone grant survives rebuilds. It uses the hardened runtime with `app/Plainchain.entitlements`, which disables library validation (and allows unsigned executable memory) so third-party plugins can load in-process; keep those entitlements when touching the signing step.
- Needs Homebrew `capnp` installed; linked statically from `/opt/homebrew/lib`.
