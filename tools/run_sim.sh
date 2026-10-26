#!/usr/bin/env bash
# Build and run the TinyMaps testbenches under Verilator.
#
#   tools/run_sim.sh [testbench-name ...]     default: every sim/tb_*.sv
#
# SPDX-License-Identifier: MIT
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/sim"
mkdir -p "$out"
cd "$root"

names=("$@")
if [[ ${#names[@]} -eq 0 ]]; then
    for f in sim/tb_*.sv; do names+=("$(basename "$f" .sv)"); done
fi

rc=0
for n in "${names[@]}"; do
    echo "=== $n ==="
    srcs=$(grep -oE '`include "[^"]+"' "sim/$n.sv" 2>/dev/null | sed 's/`include "//; s/"//' | tr '\n' ' ' || true)
    verilator --binary --timing -j 0 -Wno-fatal -Wno-lint \
        --top-module "$n" -Mdir "$out/$n" \
        ${srcs:+$(for s in $srcs; do echo "$root/$s"; done)} \
        "sim/$n.sv" fpga/tinymaps/*.sv > "$out/$n.build.log" 2>&1 \
        || { echo "build failed, see $out/$n.build.log"; tail -20 "$out/$n.build.log"; rc=1; continue; }
    "$out/$n/V$n" 2>&1 | tee "$out/$n.run.log"
    grep -q "^RESULT: PASS" "$out/$n.run.log" || rc=1
done
exit $rc
