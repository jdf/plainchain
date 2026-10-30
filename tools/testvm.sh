#!/bin/bash
# Plainchain's tests that need real (fake) audio hardware run in a Tart macOS
# guest, never on the host, where they would feed the live microphone into
# the live speakers. The guest is Plainchain's own, `plainchain-tests`
# (TESTVM_NAME overrides it), and its lifecycle (`up`, `down`, `run`, booting
# it with `--no-audio`) belongs to the testvm repository at ~/projects/testvm
# (github.com/jdf/testvm); this script only adds Plainchain's steps. The
# Plainchain tree is not shared into the guest, so `push` copies the built
# bundle to ~/Plainchain.app there with the tool's `copy`.
#
# The guest is a clone of the tool's template, provisioned by
# tools/provision-testvm.sh. To make it again, from ~/projects/testvm:
#   ./testvm.sh create plainchain-tests --from testvm-template --cpu 2 --memory 4096
#   ./testvm.sh provision plainchain-tests ~/projects/plainchain/tools/provision-testvm.sh
#
# Audio stays inside the guest only because the tool boots it with `--no-audio`
# (otherwise its "Apple Virtual Sound Device" passes through to the host's
# speakers and microphone) and the provisioning installs the BlackHole 16ch
# loopback driver. Every audio run here targets BlackHole by name
# (PC_IN/PC_OUT, a name substring), never the default devices. BlackHole loops
# each output channel back into the same input channel, so the tests never
# write the channels they read: input 1-2, output 3-4 (and 5-6 for a second
# session). The provisioning also writes the microphone grant for
# com.plainchain.app into the guest's TCC database: BlackHole's input counts
# as a microphone.
#
#   tools/testvm.sh status | up | down | ip | ssh [args...]  (the testvm tool's own)
#   tools/testvm.sh run [--aqua] <cmd...>  (the tool's run; --aqua runs in the console user's GUI session)
#   tools/testvm.sh push                 (build/Plainchain.app -> guest ~/Plainchain.app)
#   tools/testvm.sh hotplug              (push, then Plainchain --hotplug-test in the Aqua session; exit status passed through)
#   tools/testvm.sh midi                 (push, then PC_MIDI=1 Plainchain --smoke in the Aqua session; exit status passed through)
#   tools/testvm.sh clap                 (push, copy ~/Library/Audio/Plug-Ins/CLAP/nfp5.clap to the guest's, then
#                                         Plainchain --smoke nfp5 on BlackHole in the Aqua session; exit status passed through)
set -euo pipefail
cd "$(dirname "$0")/.."

testvm=${TESTVM_DIR:-$HOME/projects/testvm}
if [ ! -x "$testvm/testvm.sh" ]; then
    echo "testvm: the testvm repository is not at $testvm; clone github.com/jdf/testvm there, or set TESTVM_DIR" >&2
    exit 1
fi
export TESTVM_NAME="${TESTVM_NAME:-plainchain-tests}"
bundle=build/Plainchain.app
# The CLAP instrument the smoke runs, from the host's CLAP directory into the guest's.
nfp5=$HOME/Library/Audio/Plug-Ins/CLAP/nfp5.clap

push() {
    if [ ! -d "$bundle" ]; then
        echo "testvm: $bundle is missing; make bundle first" >&2
        exit 1
    fi
    # The tool mirrors the whole bundle (rsync --delete), so nothing of an
    # older build survives to break the signature's seal. It refuses a guest
    # that is not up; ~/Plainchain.app is in the guest user's home, where the
    # tool's run starts.
    "$testvm/testvm.sh" copy "$bundle" Plainchain.app
}

case "${1:-status}" in
status | up | down | ip)
    exec "$testvm/testvm.sh" "$1"
    ;;
ssh)
    shift
    exec "$testvm/testvm.sh" ssh "$@"
    ;;
run)
    shift
    exec "$testvm/testvm.sh" run "$@"
    ;;
push)
    push
    ;;
hotplug)
    shift
    push
    # In the console user's Aqua session: over plain ssh the HAL attributes the
    # microphone to sshd, not to Plainchain, and coreaudiod waits on a prompt.
    exec "$testvm/testvm.sh" run --aqua /usr/bin/env PC_IN=BlackHole PC_OUT=BlackHole Plainchain.app/Contents/MacOS/Plainchain --hotplug-test
    ;;
midi)
    shift
    push
    exec "$testvm/testvm.sh" run --aqua /usr/bin/env PC_MIDI=1 PC_OUT=BlackHole Plainchain.app/Contents/MacOS/Plainchain --smoke
    ;;
clap)
    shift
    if [ ! -d "$nfp5" ]; then
        echo "testvm: $nfp5 is missing; build and install nfp5 first" >&2
        exit 1
    fi
    push
    # The guest's own CLAP directory, which the app scans; the copy mirrors the bundle.
    "$testvm/testvm.sh" copy "$nfp5" Library/Audio/Plug-Ins/CLAP/nfp5.clap
    exec "$testvm/testvm.sh" run --aqua /usr/bin/env PC_IN=BlackHole PC_OUT=BlackHole Plainchain.app/Contents/MacOS/Plainchain --smoke nfp5
    ;;
*)
    echo "usage: tools/testvm.sh [status|up|down|ip|ssh|push|hotplug|midi|clap|run [--aqua] <command> [args...]]" >&2
    exit 2
    ;;
esac
