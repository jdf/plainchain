#!/bin/sh
# Regenerate the C++ code for schema/session.capnp into the CapnSession target.
# Run after editing the schema; the output is committed so builds only need the
# capnp library, not the compiler.
set -eu
cd "$(dirname "$0")/.."
out=app/Sources/CapnSession
capnp compile -oc++:"$out" --src-prefix=schema schema/session.capnp
mv "$out/session.capnp.c++" "$out/session.capnp.cpp"   # SwiftPM does not recognize .c++
echo "generated $out/session.capnp.cpp and $out/session.capnp.h"
