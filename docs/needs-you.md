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

## 3. Should I file the upstream issues?

`docs/upstream-issues.md` documents twelve findings against
`frabas/DISPLACE_GUI` at `7f2656fb`, each with a reproduction and a suggested
fix. Several are significant:

- upstream does not compile at all unpatched (C++14 vs C++17)
- every SQLite run segfaults at exit
- an infinite loop in `export_popnodes_metrealtimeclosed`
- runs are not reproducible

Filing these would help the project and reduce what `displaceR` has to work
around. But it means posting publicly under your GitHub account, so it is your
call. Tell me and I will open them; say nothing and I will leave it.

The two build fixes are also a small, clean pull request if you would rather
contribute than just report.

---

## 4. Worth asking the maintainer two things

Both would meaningfully simplify this project.

**Would he publish headless Linux binaries in official releases?** That would
delete the entire build pipeline -- layer 2 of the architecture -- and leave
`displaceR` a pure-R package with nothing to maintain but the readers.

**How is `baseline.db` generated?** `minitest` ships the whole case study as 30
normalized SQLite tables, loadable with `--indb`. If that path were
trustworthy, one `RSQLite` writer would replace the ~150 text-file writers and
most of the remaining roadmap. It runs, but it does not reproduce the
text-input results (`PopValues` comes out empty), and I cannot tell whether the
shipped database is simply stale or the loader is incomplete. A database
regenerated from the current text inputs would settle it.

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
