#!/bin/bash
# Plainchain's tests that need real (fake) audio hardware run in a Tart macOS
# guest, never on the host, where they would feed the live microphone into
# the live speakers. The guest is whatis's `whatis-tests` VM: its lifecycle
# (`up`, `down`) belongs to ~/projects/whatissoftware/tools/testvm.sh, and
# this script only borrows it. The Plainchain tree is not shared into the
# guest, so `push` copies the built bundle to ~/Plainchain.app there.
#
#   tools/testvm.sh status
#   tools/testvm.sh up | down            (delegated to whatis)
#   tools/testvm.sh run [--aqua] <cmd...> (ssh into the guest; --aqua runs in the console user's GUI session)
#   tools/testvm.sh push                 (build/Plainchain.app -> guest ~/Plainchain.app)
#   tools/testvm.sh hotplug              (push, then Plainchain --hotplug-test in the Aqua session; exit status passed through)
set -euo pipefail
cd "$(dirname "$0")/.."

vm=${TESTVM_NAME:-whatis-tests}
whatis=${WHATIS_DIR:-$HOME/projects/whatissoftware}
bundle=build/Plainchain.app

tart_bin="$(command -v tart || true)"
if [ -z "$tart_bin" ] && [ -x /opt/homebrew/bin/tart ]; then
    tart_bin=/opt/homebrew/bin/tart
fi
if [ -z "$tart_bin" ]; then
    echo "testvm: tart is not installed on this machine" >&2
    exit 1
fi
# Tart storage as whatis names it, so both scripts see the same VMs.
if [ -z "${TART_HOME:-}" ] && [ -f "$whatis/.tart_home" ]; then
    TART_HOME="$(head -n 1 "$whatis/.tart_home")"
    export TART_HOME
fi

# The address comes from tart at each call (a clone draws a fresh DHCP
# lease); the `tartvm` ssh host entry supplies the user and the key.
guest_ip() {
    "$tart_bin" ip "$vm" 2>/dev/null ||
        "$tart_bin" ip "$vm" --resolver arp 2>/dev/null
}

ssh_opts=(-o ConnectTimeout=20)

guest_ssh() {
    local ip
    ip="$(guest_ip)" || { echo "testvm: no address for $vm" >&2; return 1; }
    ssh "${ssh_opts[@]}" -o "HostName $ip" tartvm "$@"
}

require_up() {
    if ! "$tart_bin" get "$vm" --format json | grep -q '"State" *: *"running"'; then
        echo "testvm: $vm is not running; tools/testvm.sh up first" >&2
        exit 1
    fi
}

push() {
    require_up
    if [ ! -d "$bundle" ]; then
        echo "testvm: $bundle is missing; make bundle first" >&2
        exit 1
    fi
    local ip
    ip="$(guest_ip)"
    # Replace the whole bundle: the signature seals every file in it.
    guest_ssh -n 'rm -rf ~/Plainchain.app'
    rsync -a -e "ssh ${ssh_opts[*]} -o HostName=$ip" "$bundle/" "tartvm:Plainchain.app/"
}

# Every argument is quoted for the guest's shell.
run() {
    require_up
    if [ "${1:-}" = --aqua ]; then
        shift
        [ "$#" -gt 0 ] || { echo "testvm: run --aqua needs a command" >&2; exit 2; }
        # whatis's runner, fed to the guest's bash on stdin: it runs the
        # command as a launchd job in the console user's Aqua session.
        guest_ssh "bash -s -- $(printf '%q ' "$@")" < "$whatis/tools/run-in-aqua.sh"
    else
        [ "$#" -gt 0 ] || { echo "testvm: run needs a command" >&2; exit 2; }
        guest_ssh -n "$(printf '%q ' "$@")"
    fi
}

case "${1:-status}" in
status | up | down)
    exec "$whatis/tools/testvm.sh" "$1"
    ;;
run)
    shift
    run "$@"
    ;;
push)
    push
    ;;
hotplug)
    shift
    push
    # In the console user's Aqua session: over plain ssh the HAL attributes the
    # microphone to sshd, not to Plainchain, and coreaudiod waits on a prompt.
    run --aqua Plainchain.app/Contents/MacOS/Plainchain --hotplug-test
    ;;
*)
    echo "usage: tools/testvm.sh [status|up|down|push|hotplug|run [--aqua] <command> [args...]]" >&2
    exit 2
    ;;
esac
