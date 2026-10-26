#!/usr/bin/env bash
# Build TinyMaps for the Tang Console 138K with the open flow: yosys (read_slang),
# the nextpnr-himbaechel fork built against the regenerated GW5AST-138C database,
# and the apicula fork's gowin_pack.  No Gowin EDA.
#
#   tools/maps_open/build.sh <design-tree> [out-dir]
#
#   NEXTPNR_BUILD  nextpnr-himbaechel fork  (default /home/vash/tools/nextpnr-mathieufro)
#   APICULA_FORK   fork apycula             (default /run/media/vash/GIT/apicula-mathieufro)
#   NEXTPNR_SEED   placement seed           (default 1)
#
# The gate this script enforces is setup and hold.  nextpnr is passed
# --timing-allow-fail, so it will report a violation and hand back a netlist
# anyway; packing that produces a bitstream that works by luck.  The flow
# refuses to pack one.
#
# Two gates from TinyTang's desktop flow are deliberately NOT here yet:
# its clock-topology comparison and its SPINE17 hop check.  Both are
# *regression* checks against a recorded profile of a hardware-proven build,
# and TinyMaps has no such build.  They go in once this core has been accepted
# on the board and a profile can be recorded from it; before then they would
# compare against another design's topology and mean nothing.
#
# SPDX-License-Identifier: MIT
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tree=${1:-}
out=${2:-}
[[ -n $tree && -d $tree ]] || { echo "usage: $0 <design-tree> [out-dir]" >&2; exit 2; }
tree=$(cd "$tree" && pwd)
out=${out:-$tree/.open-fs}

A=${APICULA_FORK:-/run/media/vash/GIT/apicula-mathieufro}
NPNR=${NEXTPNR_BUILD:-/home/vash/tools/nextpnr-mathieufro}
SEED=${NEXTPNR_SEED:-1}
export NEXTPNR_SEED=$SEED
PY=${PY:-/home/vash/oss-cad-suite/py3bin/python3}
PYDEPS=${PYDEPS:-/home/vash/tools/pydeps}
DEVICE_FAMILY="GW5AST-138C"

log() { printf '%s\n' "$*" >&2; }

if [[ -z ${OSS_CAD_SUITE_SOURCED:-} ]]; then
    for env in "$HOME/oss-cad-suite/environment" /opt/oss-cad-suite/environment; do
        [[ -f $env ]] && { source "$env"; SUITE=$(cd "$(dirname "$env")" && pwd); break; }
    done
fi
[[ -n ${SUITE:-} ]] && export PYTHONHOME="$SUITE"
export PYTHONPATH="$A:$PYDEPS:${PYTHONPATH:-}"
[[ -d $A/apycula ]] || { log "no fork apycula at $A"; exit 2; }
mkdir -p "$out"

log "=== 1. synthesis ==="
bash "$here/synth.sh" "$tree" "$tree/tinymaps-top-open.json"
[[ -f $tree/tinymaps-top-open.json ]] || { log "no netlist produced"; exit 1; }

log "=== 2. place and route (seed $SEED) ==="
bash "$here/pnr.sh" "$tree" "$tree/tinymaps-top-open.json"
[[ -f $tree/.open-pnr/pnr.json ]] || { log "no routed netlist produced"; exit 1; }

log "=== 3. timing gate: setup and hold ==="
if ! "$PY" "$here/pnr_timing.py" "$tree/.open-pnr/nextpnr.log" \
        --require-clock clk=21.49 \
        --require-clock hclk=74.25; then
    log ""
    log "REFUSING TO PACK: the place-and-route has setup or hold violations."
    exit 1
fi

log "=== 4. pack (gowin_pack, the fork's apycula) ==="
"$PY" -W ignore -m apycula.gowin_pack -d "$DEVICE_FAMILY" \
    -o "$out/tinymaps.fs" "$tree/.open-pnr/pnr.json" 2>&1 \
    | grep -vE "warnings.warn|UserWarning|DeprecationWarning" | sed 's/^/   /' || true
[[ -f $out/tinymaps.fs ]] || { log "NO BITSTREAM"; exit 1; }
ls -l "$out/tinymaps.fs" | sed 's/^/   /'

log "=== 5. provenance stamp ==="
"$PY" "$here/fs_to_bin.py" "$out/tinymaps.fs" -o "$out/tinymaps.bin" >/dev/null 2>&1 \
    || { log "bin conversion failed"; exit 1; }
short() { sha256sum "$1" | cut -c1-12; }
BINHASH=$(short "$out/tinymaps.bin"); FSHASH=$(short "$out/tinymaps.fs")
cp -f "$out/tinymaps.bin" "$out/tinymaps.$BINHASH.bin"
cp -f "$out/tinymaps.fs"  "$out/tinymaps.$FSHASH.fs"
log "   tinymaps.$BINHASH.bin   <- file for the card"
log "   tinymaps.$FSHASH.fs   <- file for openFPGALoader"
