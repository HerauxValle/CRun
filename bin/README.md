# bin/

This is the **portable crun binary** — a pre-built, ready-to-grab copy of the
release build, refreshed automatically every time `install.sh` / `install.ps1`
runs.

```
bin/crun       Linux/macOS
bin/crun.exe   Windows
```

Copy it anywhere and run it directly — `crun` is fully self-contained with no
runtime dependency on this repo or its `target/` directory.

## Safety notes

- **Not the canonical artifact.** `target/release/crun(.exe)` is the real build
  output; this is just a checked-in copy of it. If you're hacking on crun
  itself, always rebuild and re-run the installer rather than trusting this
  copy to be current.
- **Platform/architecture specific.** The binary here was compiled for whoever
  last ran the installer — it will only run on machines with a matching OS,
  CPU architecture, and (on Linux) compatible glibc. It is *not* a
  cross-platform artifact; grab the one built on a matching system, or build
  your own with `cargo build --release`.
- **May go stale.** If `src/` changes and nobody re-runs the installer, this
  copy silently falls behind. Don't treat its presence as proof that it
  matches the current source — check the version with `bin/crun --version`
  against `Cargo.toml` if it matters.
