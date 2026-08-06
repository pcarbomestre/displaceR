#!/usr/bin/env bash
#
# Build the headless DISPLACE simulator and stage a relocatable payload.
#
# This is layer 2 of the architecture described in CLAUDE.md: it is the only
# place the build recipe lives. CI (.github/workflows/build-displace.yml) and a
# human on a laptop run this same script, so the two can never drift.
#
# System dependencies (Debian/Ubuntu) — install these first, they are not
# installed here because that needs root and this script deliberately does not:
#
#   apt-get install -y build-essential cmake git patchelf \
#                      libboost-all-dev libgeographiclib-dev \
#                      libgdal-dev libsqlite3-dev
#
# libboost-all-dev is required rather than a subset: cmake/dependencies.cmake
# marks unit_test_framework REQUIRED even when WITH_TESTS=Off.
# libgdal-dev is a configure-time formality only — find_package(GDAL REQUIRED)
# sits outside the WITHOUT_GUI guard, but GDAL does not appear in the linked
# binary. See CLAUDE.md, "Hard-won findings".
#
# Usage:
#   tools/build-displace.sh --ref <upstream-git-ref> [--workdir DIR] [--outdir DIR]
#
# Produces $OUTDIR/payload/ containing the four runtime files with
# RPATH=$ORIGIN, plus $OUTDIR/build-info.json.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/frabas/DISPLACE_GUI.git}"
SPARSEPP_REPO="${SPARSEPP_REPO:-https://github.com/greg7mdp/sparsepp.git}"
MSQLITECPP_REPO="${MSQLITECPP_REPO:-https://github.com/studiofuga/mSqliteCpp.git}"

REF=""
WORKDIR="$(pwd)/.displace-build"
OUTDIR="$(pwd)/dist"
JOBS="$( (nproc 2>/dev/null) || echo 2)"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     REF="${2:?--ref needs a value}"; shift 2 ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --outdir)  OUTDIR="${2:?--outdir needs a value}"; shift 2 ;;
    --jobs)    JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[ -n "$REF" ] || die "--ref is required (an upstream tag, branch or commit SHA)"

for tool in git cmake c++ patchelf; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

mkdir -p "$WORKDIR" "$OUTDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
OUTDIR="$(cd "$OUTDIR" && pwd)"
PREFIX="$WORKDIR/local"

# ---------------------------------------------------------------------------
# 1. Sources
# ---------------------------------------------------------------------------

clone_at() {
  # clone_at <repo> <dir> [ref]
  local repo="$1" dir="$2" ref="${3:-}"
  if [ -d "$dir/.git" ]; then
    log "reusing $dir"
  else
    log "cloning $repo"
    git clone "$repo" "$dir"
  fi
  if [ -n "$ref" ]; then
    git -C "$dir" fetch --tags origin "$ref" 2>/dev/null || git -C "$dir" fetch --tags origin
    git -C "$dir" checkout --detach "$ref"
  fi
}

clone_at "$UPSTREAM_REPO"   "$WORKDIR/DISPLACE_GUI" "$REF"
clone_at "$SPARSEPP_REPO"   "$WORKDIR/sparsepp"
clone_at "$MSQLITECPP_REPO" "$WORKDIR/mSqliteCpp"

UPSTREAM_SHA="$(git -C "$WORKDIR/DISPLACE_GUI" rev-parse HEAD)"
log "upstream $REF -> $UPSTREAM_SHA"

# include/version.h hardcodes VERSION and is not derived from git tags, so two
# different commits usually report the same banner. Record it as informational
# only; the SHA above is the authoritative key.
DISPLACE_VERSION="$(
  sed -n 's/^#define VERSION "\(.*\)"$/\1/p' "$WORKDIR/DISPLACE_GUI/include/version.h" | head -1
)"
DISPLACE_BUILD="$(
  sed -n 's/^#define VERSION_BUILD \([0-9]*\)$/\1/p' "$WORKDIR/DISPLACE_GUI/include/version.h" | head -1
)"
log "reported version: ${DISPLACE_VERSION:-unknown} build ${DISPLACE_BUILD:-unknown}"

# ---------------------------------------------------------------------------
# 2. msqlitecpp — not packaged anywhere, must be built from source
# ---------------------------------------------------------------------------

log "building msqlitecpp"
cmake -S "$WORKDIR/mSqliteCpp" -B "$WORKDIR/mSqliteCpp/Build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_TEST=Off -DENABLE_PROFILER=Off \
      -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$WORKDIR/mSqliteCpp/Build" --target install -j "$JOBS"

# ---------------------------------------------------------------------------
# 3. DISPLACE, headless
# ---------------------------------------------------------------------------
#
# WITHOUT_GUI=On drops Qt6 and CGAL entirely (they are gated behind it in
# cmake/dependencies.cmake) and skips QMapControl, qtcommons, qtgui, the
# editors, the scheduler and tests.
#
# DISABLE_IPC is deliberately NOT set: it is broken upstream. It excludes the
# IPC sources but thread_vessels.cpp and biomodule2.cpp still reference
# OutputQueueManager::enqueue, mOutQueue and guiSendUpdateCommand, so the link
# fails. IPC is inert unless --use-gui is passed.
#
# Upstream sets no RPATH (cmake/platform-linux.cmake is nearly empty), so we add
# $ORIGIN at configure time and re-assert it with patchelf below. Without it the
# tarball only works with LD_LIBRARY_PATH set.

log "configuring DISPLACE (headless)"
cmake -S "$WORKDIR/DISPLACE_GUI" -B "$WORKDIR/DISPLACE_GUI/Build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DWITHOUT_GUI=On \
      -DSPARSEPP_ROOT="$WORKDIR/sparsepp" \
      -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
      -DCMAKE_INSTALL_RPATH='$ORIGIN'

log "building displace (this is slow: commons is ~100 translation units)"
cmake --build "$WORKDIR/DISPLACE_GUI/Build" --target displace -j "$JOBS"

BINDIR="$WORKDIR/DISPLACE_GUI/Build/bin"
[ -x "$BINDIR/displace" ] || die "build produced no $BINDIR/displace"

# ---------------------------------------------------------------------------
# 4. Stage the payload
# ---------------------------------------------------------------------------
#
# commons and formats are built SHARED, which is why the .so files must ship
# alongside the executable.

PAYLOAD="$OUTDIR/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"

log "staging payload"
cp "$BINDIR/displace" "$PAYLOAD/"

stage_lib() {
  local pattern="$1" required="$2" found
  found="$(find "$WORKDIR/DISPLACE_GUI/Build" "$PREFIX" -name "$pattern" -type f 2>/dev/null | head -1)"
  if [ -z "$found" ]; then
    [ "$required" = "required" ] && die "could not find $pattern"
    log "optional library $pattern not found, skipping"
    return 0
  fi
  cp "$found" "$PAYLOAD/"
  # preserve the soname symlink chain for versioned libraries
  local base soname
  base="$(basename "$found")"
  soname="$(objdump -p "$found" 2>/dev/null | awk '/SONAME/ {print $2}' | head -1)"
  if [ -n "$soname" ] && [ "$soname" != "$base" ]; then
    ln -sf "$base" "$PAYLOAD/$soname"
  fi
}

stage_lib 'libcommons.so*'    required
stage_lib 'libformats.so*'    required
stage_lib 'libmsqlitecpp.so*' required

# Also cheap to ship: other headless tools with no Qt/GDAL/CGAL dependency.
for extra in avaifieldshuffler avaifieldupdater vmsmerger; do
  if [ -x "$BINDIR/$extra" ]; then
    cp "$BINDIR/$extra" "$PAYLOAD/"
    log "included optional tool: $extra"
  fi
done

log "setting RPATH=\$ORIGIN on staged files"
for f in "$PAYLOAD"/*; do
  [ -f "$f" ] || continue          # skip the soname symlinks
  [ -L "$f" ] && continue
  if file "$f" 2>/dev/null | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN' "$f"
  fi
done

chmod +x "$PAYLOAD/displace"

# ---------------------------------------------------------------------------
# 5. Verify relocatability in a clean environment
# ---------------------------------------------------------------------------
#
# This is the check that actually matters: if it passes with LD_LIBRARY_PATH
# unset and the build tree still present, it will pass on the user's server.

log "verifying with ldd (LD_LIBRARY_PATH unset)"
if env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace" | grep -q 'not found'; then
  env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace" >&2
  die "unresolved shared libraries in the staged payload"
fi
env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace"

log "smoke test: displace --help"
env -u LD_LIBRARY_PATH "$PAYLOAD/displace" --help > "$OUTDIR/displace-help.txt" 2>&1 \
  || die "displace --help failed"
head -3 "$OUTDIR/displace-help.txt"

# ---------------------------------------------------------------------------
# 6. Build metadata
# ---------------------------------------------------------------------------

GLIBC_VERSION="$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
OS_ID="$( (. /etc/os-release 2>/dev/null && echo "${ID}-${VERSION_ID}") || echo unknown)"

cat > "$OUTDIR/build-info.json" <<JSON
{
  "upstream_ref": "$REF",
  "upstream_sha": "$UPSTREAM_SHA",
  "displace_version": "${DISPLACE_VERSION:-unknown}",
  "displace_build": "${DISPLACE_BUILD:-unknown}",
  "built_on": "$OS_ID",
  "glibc": "${GLIBC_VERSION:-unknown}",
  "arch": "$(uname -m)",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "done"
cat "$OUTDIR/build-info.json"
ls -la "$PAYLOAD"
