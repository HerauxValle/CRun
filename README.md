# crun

Run compiled languages like scripts.

```bash
crun hello.c          # compile, run, delete binary
crun myproject/       # detect build system or scan sources, run, delete
crun main.cpp -s      # compile and keep the binary in ~/.local/bin/
```

No leftover binaries. No manual `gcc -o /tmp/... && /tmp/... && rm /tmp/...`. That's the whole point.

---

## Install

### Quick install

No clone needed — the installer detects a piped run and clones the repo to `~/Projects/CRun` for you before building.

<table>
<tr><th>OS</th><th>Command</th></tr>
<tr><td>Linux</td><td>

```bash
curl -fsSL https://raw.githubusercontent.com/HerauxValle/CRun/main/install.sh | bash
```

</td></tr>
<tr><td>macOS</td><td>

```bash
curl -fsSL https://raw.githubusercontent.com/HerauxValle/CRun/main/install.sh | bash
```

</td></tr>
<tr><td>Windows</td><td>

```powershell
irm https://raw.githubusercontent.com/HerauxValle/CRun/main/install.ps1 | iex
```

</td></tr>
</table>

### Manual install

```bash
git clone https://github.com/HerauxValle/CRun
cd CRun
./install.sh        # Linux/macOS
.\install.ps1       # Windows (PowerShell)
```

Requires Rust (`cargo`). Builds a release binary and symlinks (Linux/macOS) or copies (Windows) it to `~/.local/bin/crun`.

Make sure `~/.local/bin` is on your `PATH`. In fish:
```fish
fish_add_path ~/.local/bin
```

### Toolchain dependencies

Don't have the per-language compilers/runtimes yet (rustc, dotnet, swiftc, ...)? The installer can fetch them for your platform:

```bash
./install.sh --deps        # Linux/macOS — distro package manager / homebrew
```
```powershell
.\install.ps1 -Deps        # Windows — winget or chocolatey
```

### Update / Uninstall

```bash
./install.sh              # rebuild — existing symlink picks it up automatically
./install.sh --uninstall  # remove the installed binary
```
```powershell
.\install.ps1             # Windows: rebuild and reinstall
.\install.ps1 -Uninstall  # Windows: remove the installed binary
```

---

## How it works

crun is a four-stage pipeline:

```
detect  →  compile  →  run  →  cleanup
```

**1. detect** (`src/detect.rs`)

Given a path (file or directory), detect figures out what to compile and with what.

- **File**: looks up the extension in the language registry and returns the matching compiler config.
- **Directory**: checks for a build system first (`Makefile` → `CMakeLists.txt` → `meson.build` → `Cargo.toml` → `.csproj`), in that priority order. If none found, scans for source files recursively, groups them by language, and errors on mixed-language directories.

**2. compile** (`src/compile.rs`)

Takes the detection result and an output path, invokes the right compiler.

- For direct source files: assembles the compiler command from the language's `CompilerConfig` (compiler binary, base flags, `-Wall`/`-Werror`), then shells out with stderr inherited — you see the full compiler output, colors and all, exactly as if you ran gcc yourself.
- For build systems: delegates to `make`, `cmake`, `cargo build`, etc. and locates the output binary afterward.
- Checks that the compiler is actually on `PATH` before trying to run it, so you get "gcc not found, is C installed?" instead of a cryptic OS error.

**3. run** (`src/run.rs`)

Executes the binary. Arms the cleanup guard first, so cleanup is guaranteed regardless of how the program exits (clean exit, crash, panic, signal). Passes through the child process's exit code exactly — crun is transparent to shell scripts and pipelines.

Managed runtimes (C#/dotnet) take a different path: instead of executing a binary directly, they invoke `dotnet run <file.cs>`.

**4. cleanup** (`src/cleanup.rs`)

The `CleanupGuard` is a RAII struct — it holds the tmp path and deletes it in its `Drop` implementation. This means cleanup is wired to Rust's ownership system rather than a `trap` or `atexit`, so it fires even on panic. For `--save` builds the guard is disarmed and nothing is deleted.

---

## Language support

| Language | Extensions | Compiler | Notes |
|---|---|---|---|
| C | `.c` | `gcc` | `-std=c11 -lm` |
| C++ | `.cpp` `.cc` `.cxx` `.c++` | `g++` | `-std=c++17` |
| C# | `.cs` | `dotnet` | Managed runtime, uses `dotnet run` |
| Objective-C | `.m` | `clang` | Links `-lobjc` |
| Swift | `.swift` | `swiftc` | No `-O` for fast compile |
| Rust | `.rs` | `rustc` | Single-file or `main.rs` entrypoint; use Cargo.toml for multi-file |
| Go | `.go` | `go build` | Full directory = one package, natively multi-file |

All languages except Go and C# get `-Wall` and `-Werror` by default. Use `--no-werror` to downgrade errors to warnings.

**Adding a language**: create `src/languages/mylang.rs`, implement `pub fn config() -> CompilerConfig`, add `pub mod mylang;` to `src/languages/mod.rs`, push `mylang::config()` into the `all_languages()` vec. Nothing else needs to change.

---

## Build system detection

When given a directory, crun checks for these files in order:

| File | System | Behavior |
|---|---|---|
| `Makefile` | Make | `make` in project dir |
| `CMakeLists.txt` | CMake | `cmake` configure + build into tmp |
| `meson.build` | Meson | `meson setup` + `meson compile` |
| `Cargo.toml` | Cargo | `cargo build --release` with `CARGO_TARGET_DIR` redirected to tmp |
| `*.csproj` | dotnet | `dotnet build --configuration Release` |

If none are found, falls back to source file scanning.

---

## Flags

```
USAGE:
    crun [OPTIONS] [PATH]

ARGS:
    [PATH]    File or directory to compile. Defaults to current directory.

OPTIONS:
    -s, --save              Keep the binary after exit (default: delete on exit)
    -p, --path <PATH>       Save binary to this path (implies --save)
    -t, --tmp <PATH>        Use this directory for the transient build instead of /tmp/crun/
        --no-werror         Warnings won't abort compilation
    -h, --help              Print help
    -V, --version           Print version
```

**Tmp path** (no `--save`): `/tmp/crun/<random16chars>/output`

**Save path** (with `--save`): `$HOME/.local/bin/<filename_without_extension>`

**Save path** (with `--save --path /some/dir`): `/some/dir/<filename_without_extension>`

---

## Edge cases

- **No source files in directory** → clear error, exits 1.
- **Mixed languages in directory** → error listing what was found. Use a Makefile.
- **Multi-file Rust without `Cargo.toml`** → error unless `main.rs` exists (used as entry point).
- **Compiler not on PATH** → "compiler 'gcc' not found. Is C installed?" before attempting anything.
- **Program crashes/segfaults** → cleanup still runs (RAII guard), exit code mirrors the crash.
- **`--path` given** → `--save` is implied, no need to pass both.
- **Make output location** → best-effort: looks for `<dirname>/<dirname>` binary. If your Makefile names the output differently, crun will tell you to run it directly.