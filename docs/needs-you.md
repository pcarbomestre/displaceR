# Decisions and actions that need you

Everything that could be done without you has been done. This is what is left,
most valuable first.

---

## 1. Run the build workflow, then publish a release

**Why it needs you:** it needs repository write access and a decision about
publishing binaries under your name.

The build recipe is proven -- `tools/build-displace.sh` was executed end to end
in a container and produced a working, relocatable `displace 1.6.6` that passes
`ldd` with `LD_LIBRARY_PATH` unset and runs the minitest dataset. What has not
run is the same script inside GitHub Actions.

1. Actions -> **Build DISPLACE binary** -> Run workflow
   - `upstream_ref`: `7f2656fb7cd4180a2c74a8e3fe4b82400fd4a0de`
   - `release_tag`: leave **empty** for the first run
2. Read the step summary. Expect the smoke test to report exit 139 and a
   warning -- that is the known upstream teardown crash and the workflow
   verifies the run completed anyway.
3. When green, run it again with `release_tag` set (e.g.
   `displace-7f2656fb`), then paste the manifest entry from the step summary
   into `inst/manifest.json` and set `default` to that version.

After that `install_displace()` works with no arguments and the package is
complete for a normal user.

**Note on licensing before you publish:** DISPLACE is GPL-2, so distributing
its binaries obliges you to offer corresponding source. The workflow already
puts the upstream commit and the build recipe commit into the release notes,
which satisfies that. `LICENSE.note` explains it. Nothing to do beyond being
aware of it.

---

## 2. Tell me your server's platform

```bash
cat /etc/os-release; ldd --version; uname -m
```

The workflow currently builds for both glibc 2.35 (Ubuntu 22.04) and 2.39
(24.04), and `install_displace()` picks the newest one your host can run, so a
wrong guess is recoverable. Knowing the answer just halves the CI time and
removes the risk entirely.

A binary built on a **newer** glibc will not start on an older host; the
reverse is fine. If your server is older than 22.04, say so -- the matrix needs
another entry.

---

## 3. Upstream is read-only — settled, nothing to decide

`frabas/DISPLACE_GUI` is never modified: no issues, no pull requests, no
branches. Same for `studiofuga/mSqliteCpp` and `greg7mdp/sparsepp`. Every fix
lives in this repository, as a conditional build-time patch against a throwaway
checkout. See the hard constraint at the top of `CLAUDE.md`.

`docs/upstream-issues.md` therefore reads as an **engineering record** of what
is worked around and why, not as a queue of reports. Its value is that when a
build breaks after an upstream bump, the failure is already described.

The practical consequence: problems that would "obviously" be fixed upstream --
`DISABLE_IPC` not linking, `find_package(GDAL)` outside the `WITHOUT_GUI`
guard, `random_shuffle` at C++17 -- are all handled here instead, and each patch
self-disables if upstream ever changes on its own.

---

## 4. Two questions that must be answered from our side

Both were previously framed as things to ask the maintainer. Under the
read-only rule they become work for this repository.

**Binary distribution is ours to run.** There is no route where upstream
publishes headless binaries for us, so the build pipeline in
`.github/workflows/build-displace.yml` is permanent infrastructure rather than
a stopgap. Linux is green; macOS builds locally; Windows is drafted.

**`baseline.db` and the `--indb` path.** `minitest` ships the whole case study
as 30 normalized SQLite tables, and one `RSQLite` writer would replace ~150
text-file formatters -- a large prize. But `--indb` does not reproduce the
text-input results (`PopValues` comes out empty), and asking how the shipped
database was generated is not available to us. Settling it means generating a
database from the current text inputs ourselves and diffing the two runs. That
is a concrete, self-contained experiment; it just has to be done here.

---

## 5. Scope question: how far should the input writers go?

Right now the package can read every input file in a real case study, and can
safely *write* the ones verified against the simulator: `config.dat`, the
scenario file, the graph triple, and the `harboursspe_` / `benthosspe_` /
`fishfarmsspe_` / `windmillsspe_` / `metiersspe_` / `popsspe_` families.

`vesselsspe_` and `shipsspe_` still change the model when rewritten and need
per-file work. Beyond that, building a case study *from scratch* -- rather than
modifying an existing one -- is a much bigger job.

Which do you actually need?

- **(a) Modify an existing case study from R** -- change vessel counts, effort,
  closures, then run. Needs `vesselsspe_` and `shipsspe_` finished. Days, not
  weeks, now that `check_displace_roundtrip()` can verify each step.
- **(b) Build a case study from scratch in R** -- the full ~150 files. This is
  what `frabas/DISPLACE_R_inputs` does; porting it is the real work, and it
  needs your own data to validate against.
- **(c) Neither** -- you already have case studies and only need to run them
  and read results. That works today.

I have assumed (a) is the likely answer and stopped at the boundary rather than
guessing further.
