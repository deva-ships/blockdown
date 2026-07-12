#!/bin/bash
# set-edition.sh — records the chosen Blockdown edition as a root-owned marker.
#
#   sudo bash scripts/set-edition.sh blockdown   # Blockdown: no removal-resistance
#   sudo bash scripts/set-edition.sh max         # Blockdown Max: schg + self-heal
#
# Marker file values stay "lite" / absent for install compatibility. The daemons
# and installers read /Library/Application Support/.cache/.bd-edition to decide
# whether to install the removal-resistance layer. Blockdown writes the marker;
# Max removes it. One predicate, bd_is_lite, gates every resistance step.

set -euo pipefail

CACHE="/Library/Application Support/.cache"
MARKER="${CACHE}/.bd-edition"
edition="${1:-max}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo bash scripts/set-edition.sh <blockdown|max>" >&2
    exit 1
fi

mkdir -p "$CACHE"
chflags noschg "$MARKER" 2>/dev/null || true

case "$edition" in
    blockdown|standard|lite)
        printf 'lite\n' > "$MARKER"
        chown root:wheel "$MARKER"
        chmod 644 "$MARKER"
        echo "  Edition set to Blockdown."
        ;;
    max|full|"")
        rm -f "$MARKER"
        echo "  Edition set to Blockdown Max."
        ;;
    *)
        echo "Unknown edition: $edition (expected 'blockdown' or 'max')" >&2
        exit 1
        ;;
esac
