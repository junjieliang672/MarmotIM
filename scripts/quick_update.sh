#!/bin/bash
# Compatibility shim. This script was renamed to scripts/build_and_install.sh
# when it grew from "rebuild + reinstall the input method" into "provision
# everything MarmotIM needs", including the ASR server.
#
# It modifies nothing itself — every argument is forwarded verbatim to the new
# script, which is where the real behaviour (and the list of what it does and
# does not touch) lives.
set -e
set -o pipefail

echo "NOTE: scripts/quick_update.sh has been renamed to scripts/build_and_install.sh." >&2
echo "      Running it for you; please use the new name from now on." >&2
echo "" >&2

exec bash "$(dirname "$0")/build_and_install.sh" "$@"
