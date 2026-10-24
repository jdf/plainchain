#!/bin/bash
# Plainchain's tests that need real (fake) audio hardware run in a Tart macOS
# guest, never on the host, where they would feed the live microphone into
# the live speakers. The guest is the shared `whatis-tests` VM, and its
# lifecycle (`up`, `down`, `run`, booting it with `--no-audio`) belongs to the
# testvm repository at ~/projects/testvm (github.com/jdf/testvm); this script
# only adds Plainchain's steps. The Plainchain tree is not shared into the
# guest, so `push` copies the built bundle to ~/Plainchain.app there.
#
# Audio stays inside the guest only because the tool boots it with `--no-audio`
# (otherwise its "Apple Virtual Sound Device" passes through to the host's
# speakers and microphone) and it has the BlackHole 16ch loopback driver
# installed. Every audio run here targets BlackHole by name (PC_IN/PC_OUT, a
# name substring), never the default devices. BlackHole loops each output
# channel back into the same input channel, so the tests never write the
# channels they read: input 1-2, output 3-4 (and 5-6 for a second session).
# The guest also needs a microphone grant for com.plainchain.app in its TCC
# database: BlackHole's input counts as a microphone.
#
#   tools/testvm.sh status | up | down | ip  (the testvm tool's own)
#   tools/testvm.sh run [--aqua] <cmd...>  (the tool's run; --aqua runs in the console user's GUI session)
#   tools/testvm.sh push                 (build/Plainchain.app -> guest ~/Plainchain.app)
#   tools/testvm.sh hotplug              (push, then Plainchain --hotplug-test in the Aqua session; exit status passed through)
#   tools/testvm.sh midi                 (push, then PC_MIDI=1 Plainchain --smoke in the Aqua session; exit status passed through)
set -euo pipefail
cd "$(dirname "$0")/.."

testvm=${TESTVM_DIR:-$HOME/projects/testvm}
if [ ! -x "$testvm/testvm.sh" ]; then
    echo "testvm: the testvm repository is not at $testvm; clone github.com/jdf/testvm there, or set TESTVM_DIR" >&2
    exit 1
fi
bundle=build/Plainchain.app

push() {
    if [ ! -d "$bundle" ]; then
        echo "testvm: $bundle is missing; make bundle first" >&2
        exit 1
    fi
    # Replace the whole bundle: the signature seals every file in it. The
    # tool's run refuses a guest that is not up, and runs in the guest user's
    # home, where Plainchain.app lives.
    "$testvm/testvm.sh" run rm -rf Plainchain.app
    local ip
    ip="$("$testvm/testvm.sh" ip)"
    # The `tartvm` ssh host entry supplies the user and the key.
    rsync -a -e "ssh -o ConnectTimeout=20 -o HostName=$ip" "$bundle/" "tartvm:Plainchain.app/"
}

case "${1:-status}" in
status | up | down | ip)
    exec "$testvm/testvm.sh" "$1"
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
*)
    echo "usage: tools/testvm.sh [status|up|down|ip|push|hotplug|midi|run [--aqua] <command> [args...]]" >&2
    exit 2
    ;;
esac
