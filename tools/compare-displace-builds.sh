#!/usr/bin/env bash
#
# Run the same DISPLACE case study with two builds and check that every output
# file is byte-identical. This is how the speed patches were verified
# (docs/speedup.md); run it on the target server before trusting a new build
# there.
#
# Both builds must give reproducible runs for the comparison to mean anything:
# build both with --patch reproducible-diffusion if the scenario uses
# diffusePopN (otherwise its draws differ run to run, whatever the build).
#
# Usage:
#   tools/compare-displace-builds.sh --ref-bin DIR_OR_FILE --test-bin DIR_OR_FILE \
#       --input DIR --name INPUT_NAME [--scenario baseline] [--sim simu1] \
#       [--steps 2200] [--out DIR] [-- extra displace args]
#
# --ref-bin / --test-bin take a payload directory, an extracted tarball, or the
# displace executable itself. Extra arguments after -- go to both runs; the
# default matches the westcoast run settings (huge outputs, no SQLite, VMS
# export every 13 steps, one thread).
#
# Example (westcoast calibration 4.0, 3 months):
#   tools/compare-displace-builds.sh --ref-bin ~/displace-ref --test-bin ~/displace-fast \
#       --input $BOEM/DISPLACE_processed_inputs/DISPLACE_input_westcoast_calibration_4.0 \
#       --name westcoast_calibration_4.0 --steps 2200

set -euo pipefail

REF="" TEST="" INPUT="" NAME="" SCENARIO="baseline" SIM="simu1" STEPS=2200
OUT="$(pwd)/compare-builds"
EXTRA=(--num_threads 1 -e13 --huge=1 --disable-sqlite)

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref-bin)  REF="${2:?}"; shift 2 ;;
    --test-bin) TEST="${2:?}"; shift 2 ;;
    --input)    INPUT="${2:?}"; shift 2 ;;
    --name)     NAME="${2:?}"; shift 2 ;;
    --scenario) SCENARIO="${2:?}"; shift 2 ;;
    --sim)      SIM="${2:?}"; shift 2 ;;
    --steps)    STEPS="${2:?}"; shift 2 ;;
    --out)      OUT="${2:?}"; shift 2 ;;
    --)         shift; EXTRA=("$@"); break ;;
    -h|--help)  sed -n '2,27p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -n "$REF" ] && [ -n "$TEST" ] && [ -n "$INPUT" ] && [ -n "$NAME" ] ||
  die "--ref-bin, --test-bin, --input and --name are required (see --help)"

exe() { if [ -d "$1" ]; then echo "$1/displace"; else echo "$1"; fi; }
REF="$(exe "$REF")"; TEST="$(exe "$TEST")"
for b in "$REF" "$TEST"; do [ -x "$b" ] || die "not an executable: $b"; done
[ -d "$INPUT" ] || die "no input folder: $INPUT"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

run() {
  # run <label> <binary>
  local label="$1" bin="$2" dir="$OUT/$1"
  rm -rf "$dir"; mkdir -p "$dir"
  local start end
  start=$(date +%s)
  set +e
  "$bin" -f "$NAME" -F "$SCENARIO" -a "$INPUT" -O "$dir" -s "$SIM" -i "$STEPS" \
    "${EXTRA[@]}" --disable-crash-handler > "$dir/stdout.txt" 2>&1
  echo $? > "$dir/exit.txt"
  set -e
  end=$(date +%s)
  echo $((end - start)) > "$dir/seconds.txt"
}

echo "==> running $NAME / $SCENARIO / $SIM for $STEPS steps with both builds (in parallel)"
echo "    reference: $REF"
echo "    test:      $TEST"
run ref "$REF" &
run test "$TEST" &
wait

SUB="DISPLACE_outputs/$NAME/$SCENARIO"
A="$OUT/ref/$SUB"; B="$OUT/test/$SUB"
for d in "$A" "$B"; do [ -d "$d" ] || die "no outputs in $d (see $(dirname "$(dirname "$(dirname "$d")")")/stdout.txt)"; done

echo
echo "reference: $(cat "$OUT/ref/seconds.txt") s, exit $(cat "$OUT/ref/exit.txt")"
echo "test:      $(cat "$OUT/test/seconds.txt") s, exit $(cat "$OUT/test/exit.txt")"
echo "(an exit of 134 or 139 can be DISPLACE's known teardown crash after a complete run)"
echo

fa="$(cd "$A" && ls | sort)"; fb="$(cd "$B" && ls | sort)"
[ "$fa" = "$fb" ] || echo "WARNING: the two runs produced different sets of files"

same=0; total=0; differ=()
for f in $fa; do
  case "$f" in memstats_*) continue ;; esac   # memory use, differs on every run
  total=$((total + 1))
  if [ -f "$B/$f" ] && cmp -s "$A/$f" "$B/$f"; then same=$((same + 1)); else differ+=("$f"); fi
done

echo "files compared: $total (memstats excluded); identical: $same"
if [ ${#differ[@]} -eq 0 ]; then
  echo "RESULT: all outputs identical"
else
  echo "RESULT: ${#differ[@]} file(s) differ:"
  printf '  %s\n' "${differ[@]}"
  exit 1
fi
