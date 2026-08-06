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
# nproc is GNU coreutils and absent on macOS, where sysctl is the equivalent.
# Without this the build silently drops to 2 jobs on a machine with many cores.
JOBS="$( (nproc 2>/dev/null) || (sysctl -n hw.ncpu 2>/dev/null) || echo 2)"

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

HOST_OS="$(uname -s)"

for tool in git cmake c++; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# patchelf is ELF-only, so it is required on Linux and meaningless on macOS,
# where install_name_tool does the equivalent job and ships with Xcode.
if [ "$HOST_OS" = "Linux" ]; then
  command -v patchelf >/dev/null 2>&1 || die "missing required tool: patchelf"
fi

if [ "$HOST_OS" = "Darwin" ]; then
  cat >&2 <<'MACNOTE'
note: building on macOS.

  libc++ removed std::random_shuffle at C++17, which upstream still calls at
  six sites, so a compatibility shim is applied (patch "random-shuffle" below).
  It reproduces libstdc++'s permutation exactly and keeps drawing from rand(),
  so results follow the same seed as on Linux -- see tools/patches/ and
  docs/upstream-issues.md 14.

MACNOTE
fi

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

# ---------------------------------------------------------------------------
# 1b. Build-time patches
# ---------------------------------------------------------------------------
#
# Upstream does not build out of the box at 7f2656fb. These are the smallest
# changes that make it compile; they are applied to the checkout at build time,
# never committed anywhere, so this stays a build pipeline rather than a fork.
# Each one is conditional, so it becomes a no-op the moment upstream fixes it.
#
# Both should be reported upstream — see docs/upstream-issues.md.

PATCHES_APPLIED=""

# BSD sed (macOS) requires an argument to -i; GNU sed (Linux) requires that it
# be absent. One helper keeps every patch below identical on both.
sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

# Patch 1: C++ standard.
#
# cmake/compiler.cmake sets CMAKE_CXX_STANDARD to 14, but commons/Population.cpp
# and include/Population.h use std::shared_mutex and std::shared_lock, which are
# C++17. The build fails with "'shared_mutex' is not a member of 'std'" plus the
# telltale note "only available from C++17 onwards".
#
# This cannot be fixed with -DCMAKE_CXX_STANDARD=17 on the command line: a plain
# set() in compiler.cmake creates a normal variable that shadows the cache
# variable, so the -D is silently ignored. Editing the file is the only way.
if grep -q 'set(CMAKE_CXX_STANDARD 14)' "$WORKDIR/DISPLACE_GUI/cmake/compiler.cmake" 2>/dev/null; then
  log "patching cmake/compiler.cmake: C++14 -> C++17 (Population.cpp needs std::shared_mutex)"
  sed_i 's/set(CMAKE_CXX_STANDARD 14)/set(CMAKE_CXX_STANDARD 17)/' \
      "$WORKDIR/DISPLACE_GUI/cmake/compiler.cmake"
  PATCHES_APPLIED="${PATCHES_APPLIED}cxx17 "
fi

# Ask CMake whether a compiled Boost component is actually findable, rather
# than guessing at library paths. Probing /usr/lib for libboost_system.* is what
# an earlier version of this patch did, and it guessed wrong on Ubuntu 24.04 --
# firing the patch on a platform that did not need it and breaking a working
# build. CMake's own answer is the only one that matters here.
boost_component_exists() {
  local comp="$1" probe="$WORKDIR/.boost-probe"
  rm -rf "$probe"; mkdir -p "$probe"
  cat > "$probe/CMakeLists.txt" <<PROBE
cmake_minimum_required(VERSION 3.16)
project(boostprobe LANGUAGES CXX)
find_package(Boost COMPONENTS $comp)
if (NOT TARGET Boost::$comp)
    message(FATAL_ERROR "absent")
endif()
PROBE
  cmake -S "$probe" -B "$probe/build" >/dev/null 2>&1
}

# Patch 1b: Boost::system no longer exists as a compiled component.
#
# Boost.System has been header-only since 1.69 and ships no compiled library, so
# Boost >= 1.87 (Homebrew 1.90) provides no boost_system config package and
# configure fails outright:
#
#   Could not find a package configuration file provided by "boost_system"
#
# Drop `system` and NOTHING else. Every other component in that line is real and
# still present on Boost 1.90 (probed), and several are genuinely linked:
# commons/CMakeLists.txt:198 links Boost::date_time, simulator/CMakeLists.txt:56
# links program_options and filesystem. An earlier version of this patch trimmed
# the list to what the simulator links directly and broke the Ubuntu build with
# "Target commons links to Boost::date_time but the target was not found".
#
# Guarded on a CMake probe, so on Ubuntu's Boost 1.83 -- where system still
# exists -- this is a no-op and the build stays byte-identical to the verified
# one. See docs/upstream-issues.md 15.
BOOST_LINE='COMPONENTS date_time filesystem system thread program_options log unit_test_framework'
BOOST_FIXED='COMPONENTS date_time filesystem thread program_options log unit_test_framework'
if grep -q "$BOOST_LINE" "$WORKDIR/DISPLACE_GUI/cmake/dependencies.cmake" 2>/dev/null &&
   ! boost_component_exists system; then
  log "patching cmake/dependencies.cmake: dropping Boost::system (header-only since 1.69)"
  sed_i "s/$BOOST_LINE/$BOOST_FIXED/" \
      "$WORKDIR/DISPLACE_GUI/cmake/dependencies.cmake"
  PATCHES_APPLIED="${PATCHES_APPLIED}boost-components "
fi

# Patch 1c: std::random_shuffle, removed in C++17.
#
# Upstream needs C++17 for std::shared_mutex (patch 1) but still calls
# std::random_shuffle, which C++17 removed. libstdc++ and MSVC keep it as an
# extension, so Linux and Windows are unaffected and this patch never fires
# there. libc++ does not, so on macOS the two requirements are mutually
# exclusive and the build cannot complete without this.
#
# Faithfulness matters more than the mechanics here. SimModel::initRandom()
# seeds the *global* rand() from the digits in the simulation name, and every
# other stochastic decision draws from that same rand(). Replacing these calls
# with std::shuffle + mt19937 -- the usual modernisation -- would decouple them
# from that seed and silently change results. The shim instead reproduces the
# historical libstdc++ algorithm exactly, still drawing from rand(), so the
# permutation for a given seed is unchanged.
#
# Guarded on a compile probe rather than on the OS, so it fires exactly when the
# standard library lacks the function and is a no-op everywhere else.
stdlib_has_random_shuffle() {
  local probe="$WORKDIR/.shuffle-probe.cpp"
  cat > "$probe" <<'PROBE'
#include <algorithm>
#include <vector>
int main() {
    std::vector<int> v{1, 2, 3};
    std::random_shuffle(v.begin(), v.end());
    return 0;
}
PROBE
  c++ -std=c++17 -fsyntax-only "$probe" >/dev/null 2>&1
}

if ! stdlib_has_random_shuffle; then
  log "patching random_shuffle: this standard library removed it at C++17"
  cp "$(dirname "$0")/patches/random_shuffle_compat.h" \
     "$WORKDIR/DISPLACE_GUI/include/random_shuffle_compat.h"

  for src in commons/diffusion.cpp commons/Vessel.cpp simulator/main.cpp; do
    f="$WORKDIR/DISPLACE_GUI/$src"
    [ -f "$f" ] || continue
    # Qualify the calls, then include the shim. The include goes after the last
    # existing #include so it cannot land inside the licence header.
    #
    # Both substitutions must be idempotent: --workdir is reused between runs,
    # so a second invocation sees an already-patched tree and would otherwise
    # produce displace_compat::displace_compat::random_shuffle. The negative
    # lookbehind is spelled out longhand because BSD sed has no \b or (?<!).
    sed_i 's/displace_compat::random_shuffle/@@ALREADY@@/g' "$f"
    sed_i 's/^\([^\/]*[^a-zA-Z_:]\)random_shuffle[[:space:]]*(/\1displace_compat::random_shuffle(/' "$f"
    sed_i 's/^random_shuffle[[:space:]]*(/displace_compat::random_shuffle(/' "$f"
    sed_i 's/@@ALREADY@@/displace_compat::random_shuffle/g' "$f"
    if ! grep -q 'random_shuffle_compat.h' "$f"; then
      # Anchor to the FIRST #include, not the last. simulator/main.cpp's last
      # include sits inside an `#ifdef NO_IPC` block, and IPC is deliberately
      # left enabled (DISABLE_IPC does not link upstream), so an include placed
      # there is preprocessed away -- the call is then qualified but the shim is
      # invisible. The first include is always at file scope.
      first_inc="$(grep -n '^#include' "$f" | head -1 | cut -d: -f1)"
      if [ -n "$first_inc" ]; then
        sed_i "${first_inc}i\\
#include <random_shuffle_compat.h>
" "$f"
      fi
    fi
  done
  PATCHES_APPLIED="${PATCHES_APPLIED}random-shuffle "
fi

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

# msqlitecpp's src/CMakeLists.txt links the imported target SQLite::SQLite3 but
# no CMakeLists in that project ever calls find_package(SQLite3). CMake then
# passes the literal string to the linker: "ld: library 'SQLite::SQLite3' not
# found". On Linux libsqlite3 is on the default link path so the symbols resolve
# anyway and nobody notices; where sqlite is keg-only (Homebrew) it fails.
#
# Define the target via CMAKE_PROJECT_INCLUDE, which CMake evaluates directly
# after project() and before src/ is processed. Harmless on Linux, where
# find_package(SQLite3) simply succeeds. See docs/upstream-issues.md 13.
#
# find_package(SQLite3) must actually succeed: if it does not, SQLite3_LIBRARY
# is empty and the imported target below points at nothing. That links cleanly
# and then fails at the very end with a wall of "_sqlite3_open_v2, referenced
# from ..." undefined symbols, which looks nothing like a missing dependency.
# REQUIRED turns that into an immediate, legible configure error.
cat > "$WORKDIR/sqlite-target-shim.cmake" <<'SHIM'
find_package(SQLite3 REQUIRED)
if (NOT TARGET SQLite::SQLite3)
    add_library(SQLite::SQLite3 UNKNOWN IMPORTED)
    set_target_properties(SQLite::SQLite3 PROPERTIES
        IMPORTED_LOCATION "${SQLite3_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${SQLite3_INCLUDE_DIR}")
endif()
message(STATUS "displaceR: sqlite3 -> ${SQLite3_LIBRARY}")
SHIM

# Homebrew's sqlite is keg-only, so it is deliberately absent from the default
# search path and find_package cannot see it without being told where to look.
# Harmless on Linux, where brew does not exist and this stays empty.
SQLITE_HINTS=""
if command -v brew >/dev/null 2>&1; then
  BREW_SQLITE="$(brew --prefix sqlite 2>/dev/null || true)"
  if [ -n "$BREW_SQLITE" ] && [ -d "$BREW_SQLITE" ]; then
    SQLITE_HINTS="$BREW_SQLITE"
    log "using Homebrew sqlite at $BREW_SQLITE (keg-only, so it needs an explicit hint)"
  fi
fi

log "building msqlitecpp"
cmake -S "$WORKDIR/mSqliteCpp" -B "$WORKDIR/mSqliteCpp/Build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_TEST=Off -DENABLE_PROFILER=Off \
      -DCMAKE_PROJECT_INCLUDE="$WORKDIR/sqlite-target-shim.cmake" \
      ${SQLITE_HINTS:+-DCMAKE_PREFIX_PATH="$SQLITE_HINTS"} \
      ${SQLITE_HINTS:+-DSQLite3_INCLUDE_DIR="$SQLITE_HINTS/include"} \
      ${SQLITE_HINTS:+-DSQLite3_LIBRARY="$SQLITE_HINTS/lib/libsqlite3.dylib"} \
      -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$WORKDIR/mSqliteCpp/Build" --target install -j "$JOBS"

# Patch 2: msqlitecpp's exported CMake target has no include directories.
#
# msqlitecppTargets-release.cmake sets IMPORTED_LOCATION but never
# INTERFACE_INCLUDE_DIRECTORIES, so linking msqlitecpp::msqlitecpp gets you the
# shared library and none of its headers. DISPLACE then fails with
# "msqlitecpp/v2/storage.h: No such file or directory" while compiling
# commons/readdata.cpp.
#
# Rather than rewrite the generated CMake package, put the prefix on the include
# path directly. -isystem also keeps msqlitecpp's own warnings out of the log.
MSQLITECPP_INCLUDE_FLAG="-isystem $PREFIX/include"
if [ ! -f "$PREFIX/include/msqlitecpp/v2/storage.h" ]; then
  die "msqlitecpp installed but $PREFIX/include/msqlitecpp/v2/storage.h is missing"
fi
PATCHES_APPLIED="${PATCHES_APPLIED}msqlitecpp-includes "

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

# On macOS the Homebrew prefixes must join the search path too: sqlite is
# keg-only and GeographicLib is not somewhere CMake looks by default. On Linux
# BREW_PREFIXES stays empty and this is exactly the previous invocation.
BREW_PREFIXES=""
if command -v brew >/dev/null 2>&1; then
  for pkg in sqlite boost geographiclib; do
    p="$(brew --prefix "$pkg" 2>/dev/null || true)"
    [ -n "$p" ] && [ -d "$p" ] && BREW_PREFIXES="${BREW_PREFIXES:+$BREW_PREFIXES;}$p"
  done
fi

# The token for "resolve relative to the executable" differs by loader:
# ELF/ld.so spells it $ORIGIN, dyld spells it @loader_path. Passing $ORIGIN on
# macOS produces a binary that links fine and then refuses to start with
# "Library not loaded: @rpath/libcommons.dylib", which reads as a missing
# library rather than a wrong RPATH.
if [ "$HOST_OS" = "Darwin" ]; then
  INSTALL_RPATH='@loader_path'
  LIBEXT="dylib"
else
  INSTALL_RPATH='$ORIGIN'
  LIBEXT="so"
fi

log "configuring DISPLACE (headless)"
cmake -S "$WORKDIR/DISPLACE_GUI" -B "$WORKDIR/DISPLACE_GUI/Build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DWITHOUT_GUI=On \
      -DSPARSEPP_ROOT="$WORKDIR/sparsepp" \
      -DCMAKE_PREFIX_PATH="$PREFIX${BREW_PREFIXES:+;$BREW_PREFIXES}" \
      -DCMAKE_CXX_FLAGS="$MSQLITECPP_INCLUDE_FLAG" \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
      -DCMAKE_INSTALL_RPATH="$INSTALL_RPATH"

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
  # Preserve the name the loader will actually ask for. A versioned library is
  # installed as libfoo.1.2.3.dylib / libfoo.so.1.2.3 but recorded in dependents
  # under its install-name / SONAME (libfoo.1.dylib, libfoo.so.1), so without
  # this symlink the payload has the file and still fails to load.
  local base linkname
  base="$(basename "$found")"
  if [ "$HOST_OS" = "Darwin" ]; then
    # otool -D prints the install name on the second line.
    linkname="$(basename "$(otool -D "$found" 2>/dev/null | sed -n '2p')" 2>/dev/null)"
  else
    linkname="$(objdump -p "$found" 2>/dev/null | awk '/SONAME/ {print $2}' | head -1)"
  fi
  if [ -n "$linkname" ] && [ "$linkname" != "$base" ]; then
    ln -sf "$base" "$PAYLOAD/$linkname"
  fi
}

# The two platforms put the version on opposite sides of the extension:
# libmsqlitecpp.so.1 on Linux, libmsqlitecpp.1.dylib on macOS. So the pattern
# needs a wildcard on both sides of $LIBEXT. Keeping the extension in it at all
# matters -- a bare "libcommons.*" would also match libcommons.a and stage a
# static archive that is no use at runtime.
stage_lib "libcommons*.$LIBEXT*"    required
stage_lib "libformats*.$LIBEXT*"    required
stage_lib "libmsqlitecpp*.$LIBEXT*" required

# Also cheap to ship: other headless tools with no Qt/GDAL/CGAL dependency.
for extra in avaifieldshuffler avaifieldupdater vmsmerger; do
  if [ -x "$BINDIR/$extra" ]; then
    cp "$BINDIR/$extra" "$PAYLOAD/"
    log "included optional tool: $extra"
  fi
done

log "setting RPATH=$INSTALL_RPATH on staged files"
for f in "$PAYLOAD"/*; do
  [ -f "$f" ] || continue          # skip the soname symlinks
  [ -L "$f" ] && continue
  if file "$f" 2>/dev/null | grep -q 'ELF'; then
    patchelf --set-rpath '$ORIGIN' "$f"
  elif file "$f" 2>/dev/null | grep -q 'Mach-O'; then
    # dyld resolves @rpath entries against the LC_RPATH list. CMake already set
    # it at link time, but re-assert it here for the same reason patchelf runs
    # on Linux: staging must not depend on the build tree. A duplicate entry is
    # harmless, so ignore the error when it is already present.
    install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
  fi
done

chmod +x "$PAYLOAD/displace"

# ---------------------------------------------------------------------------
# 5. Verify relocatability in a clean environment
# ---------------------------------------------------------------------------
#
# This is the check that actually matters: if it passes with LD_LIBRARY_PATH
# unset and the build tree still present, it will pass on the user's server.

if [ "$HOST_OS" = "Darwin" ]; then
  # otool -L lists what the binary asks for; whether dyld can satisfy it is only
  # really answered by running the thing, which the smoke test below does.
  log "verifying with otool -L"
  otool -L "$PAYLOAD/displace"
else
  log "verifying with ldd (LD_LIBRARY_PATH unset)"
  if env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace" | grep -q 'not found'; then
    env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace" >&2
    die "unresolved shared libraries in the staged payload"
  fi
  env -u LD_LIBRARY_PATH ldd "$PAYLOAD/displace"
fi

# The real relocatability check on both platforms: run the staged binary with
# the loader's search path cleared. If this works, it works on a user's machine.
log "smoke test: displace --help"
env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH \
  "$PAYLOAD/displace" --help > "$OUTDIR/displace-help.txt" 2>&1 \
  || die "displace --help failed"
head -3 "$OUTDIR/displace-help.txt"

# ---------------------------------------------------------------------------
# 6. Build metadata
# ---------------------------------------------------------------------------

if [ "$HOST_OS" = "Darwin" ]; then
  # glibc is a Linux concept; the macOS equivalent constraint is the deployment
  # target, and the arch matters because a binary built on arm64 will not run on
  # an Intel Mac without Rosetta.
  GLIBC_VERSION=""
  OS_ID="macos-$(sw_vers -productVersion 2>/dev/null || echo unknown)-$(uname -m)"
else
  GLIBC_VERSION="$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
  OS_ID="$( (. /etc/os-release 2>/dev/null && echo "${ID}-${VERSION_ID}") || echo unknown)"
fi

cat > "$OUTDIR/build-info.json" <<JSON
{
  "upstream_ref": "$REF",
  "upstream_sha": "$UPSTREAM_SHA",
  "displace_version": "${DISPLACE_VERSION:-unknown}",
  "displace_build": "${DISPLACE_BUILD:-unknown}",
  "built_on": "$OS_ID",
  "glibc": "${GLIBC_VERSION:-unknown}",
  "arch": "$(uname -m)",
  "build_patches": "$(echo "$PATCHES_APPLIED" | sed 's/[[:space:]]*$//')",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# Keep a copy inside the payload as well, so a tarball carries its own
# provenance: install_displace(from = "…tar.gz") reads it to record which
# upstream commit the binary came from.
cp "$OUTDIR/build-info.json" "$PAYLOAD/build-info.json"

log "done"
cat "$OUTDIR/build-info.json"
ls -la "$PAYLOAD"
