#!/usr/bin/env bash
# Build the core at several placement seeds and report them as a table.
#
#   tools/build_seeds.sh 1 4 7              those seeds
#   tools/build_seeds.sh --range 1 8        seeds 1 to 8 inclusive
#   tools/build_seeds.sh --range 1 8 -j 4   four at a time
#
# Why this exists: the flow packs one seed at a time and refuses a netlist with
# setup or hold violations, so answering "does this design close timing" needs a
# sweep, and a sweep driven by hand from a shell that may not survive the call is
# a sweep that silently does not happen.  This runs the whole set in one process,
# writes what it started before it starts, and leaves a one-line-per-seed summary
# in build/seeds.txt whether it finishes or not.
#
# Each seed gets its own staged tree and output directory, because the flow
# re-stages the tree on every invocation and deletes the previous one; the
# flow's own PNR_WORK keeps the routed netlist and logs per tree, so seeds are
# safe to run in parallel.
#
# A seed that misses timing is not a failure of the sweep -- the interesting
# number is how many pass and what the spread is.  The exit status is 0 if at
# least one seed passed, 1 if none did, and 2 if the arguments were wrong.
#
# SPDX-License-Identifier: MIT
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

jobs=1
seeds=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--jobs) jobs="${2:?-j needs a count}"; shift 2 ;;
        --range)
            lo="${2:?--range needs a first seed}"; hi="${3:?--range needs a last seed}"
            shift 3
            for ((s = lo; s <= hi; s++)); do seeds+=("$s"); done ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) seeds+=("$1"); shift ;;
    esac
done

if [[ ${#seeds[@]} -eq 0 ]]; then
    echo "build_seeds: give at least one seed, or --range <first> <last>" >&2
    exit 2
fi
if ! [[ $jobs =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
    echo "build_seeds: -j wants a positive count" >&2
    exit 2
fi

summary="$root/build/seeds.txt"
mkdir -p "$root/build"
: > "$summary"
echo "# started $(date -Iseconds)  seeds: ${seeds[*]}  jobs: $jobs" >> "$summary"

run_one() {
    local s=$1 dir="$root/build/seed-$1" log="$root/build/seed-$1.log"
    MAPS_BUILD_DIR="$dir" NEXTPNR_SEED="$s" \
        "$root/tools/build_maps_core_open.sh" "$dir/open" > "$log" 2>&1
}

# print one seed's result from its log, and record it, as soon as it is done
report() {
    local s=$1 log="$root/build/seed-$1.log"
    local line artefact status hclk
    line=$(grep -oE "(PASS|FAIL) hclk +[0-9.]+ MHz" "$log" 2>/dev/null | tail -1)
    artefact=$(grep -oE "tinymaps\.[0-9a-f]+\.bin +<- file" "$log" 2>/dev/null | tail -1 \
               | awk '{print $1}')
    if [[ -z $line ]]; then
        printf '%-6s %-8s %-10s %s\n' "$s" "NONE" "-" "no timing report (see build/seed-$s.log)"
    else
        status=${line%% *}
        hclk=$(awk '{print $3}' <<<"$line")
        printf '%-6s %-8s %-10s %s\n' "$s" "$status" "$hclk MHz" "${artefact:-no artefact}"
    fi
}

running=0
for s in "${seeds[@]}"; do
    run_one "$s" &
    running=$((running + 1))
    if (( running >= jobs )); then
        wait -n 2>/dev/null || true
        running=$((running - 1))
    fi
done
wait

echo "---"
{
    printf '%-6s %-8s %-10s %s\n' seed status hclk artefact
    for s in "${seeds[@]}"; do
        report "$s"
    done
} | tee -a "$summary"

passed=0
for s in "${seeds[@]}"; do
    if grep -qE "PASS hclk" "$root/build/seed-$s.log" 2>/dev/null; then
        passed=$((passed + 1))
    fi
done

best=$(for s in "${seeds[@]}"; do
    grep -oE "PASS hclk +[0-9.]+" "$root/build/seed-$s.log" 2>/dev/null \
        | awk -v s="$s" '{print $3, s}'
done | sort -rn | head -1)

echo
echo "summary: $summary"
if [[ -n $best ]]; then
    echo "best: $(awk '{print $1}' <<<"$best") MHz at seed $(awk '{print $2}' <<<"$best"); $passed of ${#seeds[@]} passed"
    exit 0
fi
echo "no seed passed; ${#seeds[@]} tried"
exit 1
