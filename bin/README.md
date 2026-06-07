# bin/

This is the **portable crun binary** — a pre-built, ready-to-grab copy of the
release build, refreshed automatically every time `install.sh` / `install.ps1`
runs.

```
bin/crun             Linux/macOS
bin/crun.exe         Windows
bin/built-on.json    compatibility fingerprint of the binary above
```

`built-on.json` records only what matters for binary compatibility — `os`,
`arch`, `libc` (musl/glibc/msvc), and `libc_version` (glibc minimum, if
applicable). The installers' `--bin`/`-Bin` fetch path reads this before
copying a prebuilt binary onto a machine: if it's incompatible (wrong OS/arch,
or glibc too old), it rejects the copy and offers to compile from source
instead, so you never end up with a binary that silently won't run.

On Linux, the installer prefers building a fully **static musl** binary for
`bin/crun` when the `x86_64-unknown-linux-musl` target + `musl-gcc` are
available — that runs on any distro/libc version with zero compatibility
concerns. Falls back to a regular glibc build otherwise.

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
