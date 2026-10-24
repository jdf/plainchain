#!/bin/bash
# Provisions plainchain-tests, Plainchain's own test guest, with what its
# audio tests need. It runs on the host, under the testvm tool, which
# boots the guest (without a share) before it and shuts it down after:
#
#   ~/projects/testvm/testvm.sh provision plainchain-tests tools/provision-testvm.sh
#
# The tool passes itself as TESTVM and the guest as TESTVM_NAME. The guest
# gets two things:
#
# - The BlackHole 16ch loopback driver, the only audio device the tests
#   use (by name; the guest's own default devices pass through to the
#   host's unless the tool boots it with --no-audio). The signed pkg comes
#   from Homebrew's cask cache on the host.
# - A microphone grant for com.plainchain.app in the guest user's TCC
#   database, because BlackHole's input counts as a microphone and no one
#   is there to answer the prompt. The row is the one a grant by hand
#   wrote in whatis-tests, column for column; its csreq is the compiled
#   designated requirement of the Developer ID-signed bundle (identifier
#   com.plainchain.app, Apple's Developer ID anchor, team 6RMZ7JM472), so
#   it holds only for bundles signed with that identity.
#
# Running it again changes nothing: the installer reinstalls the same
# driver, and the grant replaces any row for the same client and service.
set -euo pipefail
: "${TESTVM:?run this through testvm.sh provision}"
: "${TESTVM_NAME:?run this through testvm.sh provision}"

pkg="$(brew --cache --cask blackhole-16ch)"
if [ ! -f "$pkg" ]; then
    brew fetch --cask blackhole-16ch
fi
"$TESTVM" copy "$pkg" .provision/BlackHole16ch.pkg
"$TESTVM" run sudo installer -pkg .provision/BlackHole16ch.pkg -target /
"$TESTVM" run rm -rf .provision
echo "provision: installed $(basename "$pkg")"

csreq_hex=FADE0C00000000A000000001000000060000000200000012636F6D2E706C61696E636861696E2E6170700000000000060000000F000000060000000E000000010000000A2A864886F76364060206000000000000000000060000000E000000000000000A2A864886F7636406010D0000000000000000000B000000000000000A7375626A6563742E4F550000000000010000000A36524D5A374A4D3437320000
csreq="X'$csreq_hex'"
"$TESTVM" run /usr/bin/sqlite3 "Library/Application Support/com.apple.TCC/TCC.db" "
BEGIN;
DELETE FROM access WHERE service = 'kTCCServiceMicrophone' AND client = 'com.plainchain.app' AND client_type = 0;
INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version,
    csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
    indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid,
    last_reminded)
VALUES ('kTCCServiceMicrophone', 'com.plainchain.app', 0, 2, 0, 1,
    $csreq, NULL, NULL, 'UNUSED',
    NULL, 0, CAST(strftime('%s','now') AS INTEGER), NULL, NULL, 'UNUSED',
    CAST(strftime('%s','now') AS INTEGER));
COMMIT;"
echo "provision: granted com.plainchain.app the microphone"

# coreaudiod loads HAL drivers and reads TCC grants when it starts.
"$TESTVM" run sudo killall coreaudiod
found=0
for _ in $(seq 1 15); do
    if "$TESTVM" run /bin/bash -c 'system_profiler SPAudioDataType | grep -q "BlackHole 16ch"'; then
        found=1
        break
    fi
    sleep 2
done
if [ "$found" != 1 ]; then
    echo "provision: no BlackHole 16ch device in $TESTVM_NAME after restarting coreaudiod" >&2
    exit 1
fi
echo "provision: $TESTVM_NAME has a BlackHole 16ch device"
"$TESTVM" run /usr/bin/sqlite3 "Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, client_type, auth_value, auth_reason, auth_version,
        hex(csreq) = '$csreq_hex', quote(policy_id),
        quote(indirect_object_identifier_type), indirect_object_identifier,
        quote(indirect_object_code_identity), flags, quote(pid), quote(pid_version), boot_uuid
     FROM access WHERE client = 'com.plainchain.app'"
