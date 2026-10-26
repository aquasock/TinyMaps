#!/usr/bin/env bash
# Stage fpga/tinymaps as a design tree and build it with the open flow.
#
#   tools/build_maps_core_open.sh [out-dir]
#
#   MAPS_BUILD_DIR  where fpga/tinymaps is staged (default build/tinymaps)
#   NEXTPNR_SEED    placement seed (default 1)
#   NEXTPNR_BUILD, APICULA_FORK, PY, PYDEPS  see tools/maps_open/build.sh
#
# SPDX-License-Identifier: MIT
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build="${MAPS_BUILD_DIR:-$root/build/tinymaps}"
export NEXTPNR_SEED="${NEXTPNR_SEED:-1}"
mkdir -p "$build"
tree="$build/tree"
rm -rf "$tree"
mkdir -p "$tree/src/tinymaps"
cp -r "$root/fpga/tinymaps/." "$tree/src/tinymaps/"
out="${1:-$build/open-s$NEXTPNR_SEED}"
exec "$root/tools/maps_open/build.sh" "$tree" "$out"
