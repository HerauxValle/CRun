# Installers (`install.sh` / `install.ps1`)

Both scripts do the same job for their platform: build crun in release mode and place the binary on `PATH` under `~/.local/bin` (or `~\.local\bin` on Windows), without requiring elevated privileges for the install step itself.

## Curl/irm-pipe detection

Both scripts detect when they're being executed via a pipe rather than as a local file, and bootstrap by cloning the repo first:

- **Bash**: checks `BASH_SOURCE[0]` — when piped through `curl ... | bash`, this is something like `bash` or `/dev/stdin`, not a real path ending in `install.sh`. If detected, clones to `~/Projects/CRun` (reusing an existing clone if present) and re-execs the local copy with `exec bash "$CLONE_DIR/install.sh" "$@"`.
- **PowerShell**: checks whether `$PSCommandPath` is empty — true when run via `irm <url> | iex`, since there's no script file on disk. Clones to `~/Projects/CRun` and re-invokes the local script, forwarding `@PSBoundParameters`.

This lets the one-line install commands in the README work without the user cloning manually first.

## Flags

| Flag (sh / ps1) | Effect |
|---|---|
| `--copy` / `-Copy` | Copy the binary instead of symlinking. Useful when `$HOME` is on a different filesystem than the repo (symlinks across filesystems to a moving release binary can be fragile); on Windows, copying is the default and only mode since symlinks need Developer Mode. |
| `--bin NAME` / `-Bin NAME` | Install under a custom name (e.g. `runfile`). Only the *installed artifact's* name changes — the actual `crun` binary that cargo produces is untouched, since Cargo binary names can't be parameterized at build time. The installer creates `~/.local/bin/<NAME>` as a symlink/copy/rename of the real `crun` binary. Combine freely with other flags. `--uninstall`/`-Uninstall` respects the custom name too. |
| `--uninstall` / `-Uninstall` | Remove the installed binary (the one matching the current `--bin` name, default `crun`). |
| `--deps [LANG]` / `-Deps [-DepsTarget LANG]` | Build crun, then delegate to `crun --deps [LANG]` to install toolchain dependencies (see below and [languages.md](languages.md#depsrs-toolchain-installation---deps)). |

## `--deps`: now owned by crun itself

Earlier versions of these installer scripts contained all the platform/package-manager
logic directly (a big distro `case` statement, hardcoded package name lists per OS).
That's been moved into crun: each language declares its own package names for every
manager in its `languages/<lang>/deps.rs` (a `DepSpec` — see [languages.md](languages.md)),
and `crun --deps [LANG]` detects the platform's package manager once and installs
from those specs.

This means **the installer scripts no longer know any package names** — their
`--deps` handling is now just:

1. Verify `cargo` is available (needed to build crun before it can do anything).
2. On Windows only: install Visual Studio 2022 Community + Windows 11 SDK + VC++
   tools via winget first — these are needed to link Swift, and aren't a normal
   "language toolchain" so they don't fit the `DepSpec` model cleanly.
3. `cargo build --release` to produce the crun binary.
4. Run `<crun-binary> --deps [LANG]` and let crun take it from there.

### Platform/manager detection (now inside crun — `PkgManager::detect`)

| Platform | Detection | Manager |
|---|---|---|
| macOS | `brew` on PATH | Homebrew |
| Windows | `winget`, then `choco` | winget / chocolatey |
| Linux | `/etc/os-release` `ID=` field | pacman (`arch`) / apt (`ubuntu`,`debian`,`pop`,`mint`) / dnf (`fedora`,`rhel`,`centos`) / zypper (`opensuse*`,`suse`) |

Unknown/undetected platforms produce a clear error rather than guessing.

### Why this moved out of the shell scripts

The old design meant adding a language required editing **four arrays in
install.sh** (`arch_deps`, `apt_deps`, `dnf_deps`, `zypper_deps`) plus **two
lines in install.ps1** (the winget block and the choco line) — five edit sites
across two files in two different languages, easy to miss one (which is exactly
what happened when Zig was first wired up: it landed in the arrays but the
underlying Arch transaction conflict masked the gap). Now a language's entire
dependency story — package names for every manager on every platform — lives in
one `deps.rs` file, discovered automatically the same way `config.rs` is.

### A note on the historical pacman-conflict bug

A real bug surfaced while wiring up Zig: `pacman -S pkg1 pkg2 ...` resolves its
whole transaction atomically, so a single conflict (`rustup` vs. a pre-existing
`rust` package, the common case) aborted the *entire* install — including
unrelated packages later in the list. `language::PkgManager::install` (the
current implementation backing `crun --deps`) installs **one package at a time**
and reports-but-continues on failure, which avoids this class of problem
entirely — exactly the fix that was first applied directly to install.sh's old
bulk `pacman -S` call, now generalized into the shared installer.

## Build & install steps (after `--deps`/`--uninstall` short-circuits)

1. Verify `cargo` is on `PATH`.
2. `cargo build --release --manifest-path <repo>/Cargo.toml`.
3. Verify the release binary exists.
4. Symlink (default on Linux/macOS) or copy (default on Windows, `--copy` on others) it to `<bin_dir>/<install_name>`.
5. If `<bin_dir>` isn't on `PATH`, print a platform-appropriate snippet to add it (fish `fish_add_path` on Unix, `[Environment]::SetEnvironmentVariable` on Windows).

Symlinking is preferred on Unix because it means `./install.sh` (no flags) after a `git pull` + rebuild updates the installed binary automatically — no reinstall step needed.
