# Upstream DISPLACE issues found while building displaceR

All verified against `frabas/DISPLACE_GUI` at commit
`7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de`, built on Ubuntu 24.04 (gcc 13.3,
glibc 2.39, CMake 3.28, Boost 1.83) and run against the
`frabas/DISPLACE_input_minitest` dataset at `22d98622`.

Each of these is worth reporting upstream. None of them is worked around by
forking: the two build failures are patched at build time by
`tools/build-displace.sh`, and the runtime crash is detected and handled in
`run_displace()`.

---

## 1. Does not compile: C++14 set, C++17 required — **blocks the build**

`cmake/compiler.cmake` contains a single line:

```cmake
set(CMAKE_CXX_STANDARD 14)
```

but `include/Population.h:392` declares

```cpp
mutable std::shared_mutex cache_mtx;
```

and `commons/Population.cpp` uses `std::shared_lock` / `std::unique_lock` over
it at lines 1252, 1262, 1280, 1289 and 1319. `std::shared_mutex` is C++17.

The build fails with:

```
error: 'shared_mutex' is not a member of 'std'
note: 'std::shared_mutex' is only available from C++17 onwards
```

The "only available from C++17 onwards" note is the tell: `<shared_mutex>` is
being included, but the standard level guards the declaration out.

**This cannot be worked around from the command line.** `-DCMAKE_CXX_STANDARD=17`
is silently ignored, because a plain `set()` creates a normal variable that
shadows the cache variable of the same name for the rest of the directory
scope. Editing the file is the only fix.

**Suggested upstream fix:** change the line to `set(CMAKE_CXX_STANDARD 17)`.
CLAUDE.md's Phase 0 notes claim this file already sets 17, so this may be a
regression rather than a long-standing state.

**How displaceR handles it:** `tools/build-displace.sh` rewrites the line at
build time, conditionally, so it becomes a no-op once upstream fixes it. The
patch is recorded in `build-info.json` under `build_patches`.

---

## 2. msqlitecpp's CMake package exports no include directories — **blocks the build**

`mSqliteCpp`'s installed `msqlitecppTargets-release.cmake` sets

```cmake
IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libmsqlitecpp.so.1.99.11.0"
```

but never `INTERFACE_INCLUDE_DIRECTORIES`. Linking `msqlitecpp::msqlitecpp`
therefore gets you the shared library and none of its headers, and DISPLACE
fails at `commons/readdata.cpp`:

```
include/db/ConfigTable.h:10:10: fatal error: msqlitecpp/v2/storage.h: No such file or directory
```

This is arguably an msqlitecpp bug rather than a DISPLACE one, but DISPLACE is
where it surfaces.

**Suggested fix:** in mSqliteCpp, add
`target_include_directories(msqlitecpp PUBLIC $<INSTALL_INTERFACE:include>)`
so the exported target carries its own include path.

**How displaceR handles it:** the build script passes
`-isystem $PREFIX/include` via `CMAKE_CXX_FLAGS`.

---

## 3. Segfault at exit whenever SQLite output is enabled — **affects every run**

After a completely successful simulation, the process crashes during static
destruction and exits with signal 11 (status 139).

```
Thread 1 "displace" received signal SIGSEGV, Segmentation fault.
0  sqlite3_finalize ()                            from libsqlite3.so.0
1  sqlite::SQLiteStatement::~SQLiteStatement ()    from libmsqlitecpp.so.1
2  MetadataTable::~MetadataTable ()                from libcommons.so
3  std::_Sp_counted_base<...>::_M_release ()
4  SQLiteOutputStorage::~SQLiteOutputStorage ()    from libcommons.so
5  std::shared_ptr<SQLiteOutputStorage>::~shared_ptr ()
6  __run_exit_handlers ()                          at stdlib/exit.c:108
7  __GI_exit ()
8  __libc_start_call_main ()
```

Frame 6 is the point: this is *after* `main()` returned 0. `main()` calls
`outSqlite->close()` at `simulator/main.cpp:3400`, and the global
`shared_ptr<SQLiteOutputStorage>` is then destroyed at exit, finalizing
statements against an already-closed database.

**Reproduction**, minitest dataset, 20 steps:

| Command | Exit status |
|---|---|
| `displace -f fake -F baseline -a minitest -O out -s s1 -i 20 --disable-crash-handler` | **139** |
| ...same plus `--disable-sqlite` | **0** |

**The results are unaffected.** On the crashing run all 40 output files are
written, and the output database passes `PRAGMA integrity_check` with
`lastTStep` correctly reaching the requested horizon.

A secondary consequence: because the crash happens before the stdio exit
handler runs, **the tail of buffered stdout is lost**. The last lines a caller
sees are from early in the run, which makes the crash look like it happened
much earlier than it did.

**Suggested upstream fix:** make the `SQLiteOutputStorage` owner a
function-local static with controlled lifetime, or reset the global
`shared_ptr` at the end of `main()` after `close()`, so the destructor does not
run at static-destruction time.

**How displaceR handles it:** `run_displace()` detects a non-zero exit, then
verifies from the output database's `Metadata.lastTStep` that the run reached
its horizon and that the file passes an integrity check. If so it warns and
returns normally; otherwise it errors as usual. A real mid-run crash is still
reported as a failure.

---

## 4. Debug output left in the vessel features parser

`commons/myutils.cpp:1421`, inside the vessel-features parsing loop:

```cpp
std::cerr << "Line " << line_no << " bytes=" << line.size()
          << " back=" << (line.empty() ? 'X' : line.back()) << "\n";
```

This fires once per vessel per read, unconditionally, on stderr — it is not
behind `dout()`, `outc()` or a verbosity check like the rest of the codebase.
On a realistic fleet it is a lot of noise, and because it lands on stderr it
survives `-V 0`.

**Suggested fix:** remove it, or wrap it in the existing `dout()` macro.

---

## 5. Infinite loop in `export_popnodes_metrealtimeclosed`

`commons/Node.cpp:2210`:

```cpp
int i = 0;
int count = -1;
vector<bool> banned = this->mBannedMetiers;
while (i < banned.size()) {
    count++;
    if (banned.at(i) != 0) popnodes << ... << count << " " << "\n";
}
```

`i` is never incremented. Any node with a non-empty `mBannedMetiers` loops
forever, writing an unbounded file. It only terminates today because
`mBannedMetiers` is empty in the datasets tried.

**Suggested fix:** `++i` at the end of the loop body.

Not currently triggered by minitest, so displaceR does not work around it — but
a case study using metier closures would hang.

---

## 6. `export_popnodes_tariffs` writes ragged rows

`commons/Node.cpp:2231`:

```cpp
if (tariffs.at(0) > 1e-6) popnodes << " " << tstep << " " << node << " "
                                   << x << " " << y << " ";
while (met < tariffs.size()) {
    popnodes << tariffs.at(met) << " ";
    ++met;
}
popnodes << "\n";
```

The `tstep / node / long / lat` prefix is conditional, but the tariff values are
written unconditionally. Nodes whose first tariff is at or below `1e-6` emit a
line containing only tariff values, with no key columns. The resulting file has
two different row shapes and cannot be parsed by column position.

**Suggested fix:** put the whole row inside the condition.

displaceR's `popnodes_tariffs` layout assumes the well-formed shape and will
report a column-count mismatch on a file containing the short rows.

---

## 7. `export_popnodes_impact_per_szgroup` iterates the wrong vector

`commons/Node.cpp:2089`:

```cpp
vector<double> impact_per_szgroup = get_pressure_pops_at_szgroup(pop);
...
for (unsigned int sz = 0; sz < impact_per_pop.size(); sz++) {
    popnodes << " " << impact_per_pop.at(sz);
}
```

It fetches `impact_per_szgroup` and then never uses it, writing
`impact_per_pop` instead and sizing the loop by the number of populations. So
despite its name, `popnodes_impact_per_szgroup_*.dat` contains per-population
values, and the same values as `popnodes_impact_*.dat`.

**Suggested fix:** iterate and write `impact_per_szgroup`.

displaceR names these columns `impact_sp0..N` after what the file actually
holds, not after the filename.

---

## 8. `fishfarmslogs` filename and width both differ from the documentation

Two separate mismatches in one file:

* **Filename.** `simulator/main.cpp:1843` writes `fishfarmslogs_<sim>.dat`, with
  an `s` on "farms". `docs/output_fileformats.md` calls it `fishfarmlogs_*.dat`,
  and so does the receiving parameter of
  `Fishfarm::export_fishfarms_indicators(ofstream& fishfarmlogs, ...)`. A reader
  written from the documentation silently never matches the file.
* **Width.** The documentation lists 10 columns, ending at
  `fishfarm_annualprofit`. The writer emits 14: it appends
  `net_discharge_N`, `net_discharge_P`, `cumul_net_discharge_N` and
  `cumul_net_discharge_P`. Confirmed against a real 3000-step run.

**Suggested fix:** update `docs/output_fileformats.md` for both, or rename the
output file to match the documented name.

---

## 9. `find_package(GDAL)` sits outside the `WITHOUT_GUI` guard

`cmake/dependencies.cmake` requires GDAL 1.11 unconditionally, so `libgdal-dev`
must be installed to *configure* a headless build — but GDAL does not appear in
the resulting binary's `ldd` output and is not needed at runtime. Confirmed on
this build.

**Suggested fix:** move the `find_package(GDAL REQUIRED 1.11)` line inside the
`if(NOT WITHOUT_GUI)` block. This would drop a heavy dependency (GDAL pulls in
PROJ, GEOS, libtiff and curl) from headless builds entirely.

---

## 10. `-DDISABLE_IPC=On` does not link

Inherited from CLAUDE.md Phase 0 and not re-tested here. The option excludes the
IPC sources, but `thread_vessels.cpp` and `biomodule2.cpp` still reference
`OutputQueueManager::enqueue`, `mOutQueue` and `guiSendUpdateCommand`, so the
link fails.

**Suggested fix:** guard those call sites, or keep the symbols in a stub
translation unit when IPC is disabled.

displaceR simply leaves IPC enabled; it is inert unless `--use-gui` is passed.

---

## 11. Runs are not reproducible

Two runs with identical inputs, an identical `sim_name` and an identical step
count produce different outputs. On a 2000-step minitest run, 13 of 39 text
output files differed between two invocations; the other 26 were stable across
repeated runs, so this is not a filesystem or timestamp artefact.

`main()` calls `simModel->initRandom(namesimu)`, which suggests the intent is a
name-seeded, reproducible run. Something outside that seeding -- plausibly the
threaded vessel movement -- is not covered.

**Why it matters:** it makes exact reproduction from inputs impossible, and it
means any regression test has to determine empirically which outputs are stable
before comparing them. `displaceR::check_displace_roundtrip()` does that by
running the reference twice.

Worth confirming upstream whether this is intended.

---

## 12. `--indb` runs but does not reproduce the text-input results

`minitest` ships `baseline.db` and `areaclosure.db`, SQLite databases holding
the whole case study in 30 normalized tables, loaded with `--indb`. The run
completes and produces the full set of outputs, so the path is wired up.

But on the same dataset, scenario and step count, the two input paths disagree:

| Output table | `--indb baseline.db` | text files |
|---|---|---|
| `VesselVmsLike` | 27 | 73 |
| `VesselLogLike` | 1 | 2 |
| `PopValues` | 0 | 123 |
| `NodesEnvt` | 41 | 41 |

`PopValues` being empty is the striking one — population dynamics appear not to
be recorded at all on the database path.

This may mean the shipped `baseline.db` is out of step with the text files
rather than that `DatabaseModelLoader` is incomplete; distinguishing the two
needs a database regenerated from the current text inputs.

**Why it matters:** the database schema is a far better R target than the ~150
text files, so whether this path is trustworthy decides a large part of
displaceR's roadmap. See `docs/roadmap.md`.

displaceR passes `--indb` through and skips text-tree validation when it is
used, but does not yet write such databases.
