#!/bin/bash
# install-cli.sh — Install Blockdown system CLI + hidden teardown bundle.
# Run as root from other install scripts.
#
# Layout:
#   /usr/local/bin/blockdown|pin|ban        public CLI (no uninstall in help)
#   /usr/local/libexec/.bd/reconcile        gated teardown (schg on Max)
#   /usr/local/libexec/.bd/mint-teardown-token   one-time token writer (schg on Max)
# No /usr/local/lib/blockdown/ or repo-path pointer is written. Blockdown (non-Max)
# installs the same files but leaves them unlocked (teardown is ungated).

set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
LIBEXEC="/usr/local/libexec/.bd"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo bash scripts/install-cli.sh" >&2
    exit 1
fi

CACHE="/Library/Application Support/.cache"
BD_EDITION_MARKER="${CACHE}/.bd-edition"
bd_is_lite() { [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]; }

mkdir -p /usr/local/bin "$LIBEXEC"

install -m 755 -o root -g wheel "${REPO}/files/blockdown" /usr/local/bin/blockdown
install -m 755 -o root -g wheel "${REPO}/files/pin" /usr/local/bin/pin
install -m 755 -o root -g wheel "${REPO}/files/ban" /usr/local/bin/ban

# Hidden teardown bundle. Unlock any prior schg copy so a reinstall can overwrite,
# install fresh, then re-lock. schg blocks modification/deletion, not execution.
for f in reconcile mint-teardown-token; do
    chflags noschg "${LIBEXEC}/${f}" 2>/dev/null || true
done
install -m 755 -o root -g wheel "${REPO}/scripts/uninstall-all.sh" "${LIBEXEC}/reconcile"
install -m 755 -o root -g wheel "${REPO}/files/mint-teardown-token" "${LIBEXEC}/mint-teardown-token"
# Blockdown locks nothing: the teardown bundle stays removable like everything else.
if ! bd_is_lite; then
    chflags schg "${LIBEXEC}/reconcile" 2>/dev/null || true
    chflags schg "${LIBEXEC}/mint-teardown-token" 2>/dev/null || true
fi

echo "  Installed blockdown CLI at /usr/local/bin/blockdown"
echo "  Installed hidden teardown bundle at ${LIBEXEC}"
echo "  (pin/ban remain as aliases)"
