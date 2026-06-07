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

No clone needed — the installer detects a piped run and clones the repo into `./CRun` (in your current directory) before building, or skips cloning entirely if you just want the binary (see "Just the binary" below).

<table>
<tr><th>OS</th><th>Command</th></tr>
<tr><td>Linux</td><td>

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/install.sh | bash
```

</td></tr>
<tr><td>macOS</td><td>

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/install.sh | bash
```

</td></tr>
<tr><td>Windows</td><td>

```powershell
irm https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/install.ps1 | iex
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

Requires Rust (`cargo`). Builds a release binary in a temporary directory and copies it to `~/.local/bin/crun`.

Make sure `~/.local/bin` is on your `PATH`. In fish:
```fish
fish_add_path ~/.local/bin
```

### Toolchain dependencies

Don't have the per-language compilers/runtimes yet (rustc, dotnet, swiftc, ...)? The installer can fetch them for your platform:

```bash
./install.sh --deps        # Linux/macOS — every language's toolchain
./install.sh --deps zig    # ...or just one
```
```powershell
.\install.ps1 -Deps                    # Windows — every language's toolchain
.\install.ps1 -Deps -DepsTarget zig    # ...or just one
```

Each language declares its own package names for every package manager (pacman, apt, dnf, zypper, brew, winget, choco) right in its `src/languages/<lang>/deps.rs` — the installer scripts just build crun and hand off to `crun --deps [lang]`, which detects your platform's package manager and installs from there. You can also run it directly once crun is installed: `crun --deps` / `crun --deps zig`.

### Custom binary name

Want to invoke it as something other than `crun` (e.g. `runfile`)? Pass `--name`/`-Name` at install time — it controls what the installed copy is named, the actual `crun` build is untouched:

```bash
./install.sh --name runfile              # -> ~/.local/bin/runfile
./install.sh --uninstall --name runfile  # uninstall respects the custom name too
```
```powershell
.\install.ps1 -Name runfile              # -> ~\.local\bin\runfile.exe
.\install.ps1 -Name runfile -Uninstall   # uninstall respects the custom name too
```

### Update / Uninstall

```bash
./install.sh              # rebuild and reinstall — copies the fresh binary over the old one
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
| Zig | `.zig` | `zig build-exe` | Single root file; `-femit-bin` for output, `-OReleaseFast` |

C, C++, and Objective-C get `-Wall -Werror` by default. Go, Zig, and C# rely on their own compiler strictness (no warning flags injected). Rust gets `-D warnings` and Swift gets `-warnings-as-errors` as their equivalents. Pass `--no-werror` to drop the "promote warnings to errors" behavior across the board (C/C++/ObjC keep `-Wall`, Rust/Swift skip their strict flags).

**Adding a language**: drop a directory `src/languages/mylang/config.rs` implementing `pub fn config() -> CompilerConfig`. `build.rs` scans `src/languages/` at build time and auto-generates the module declarations and registry — nothing else to wire up. Optionally add `deps.rs` (toolchain package names, powers `crun --deps mylang`) and `test.rs` (bundled smoke test with its source inlined, powers `crun -t mylang`). See [docs/languages.md](docs/languages.md) for the overview, or [docs/language-packs.md](docs/language-packs.md) for the exact field-by-field syntax of all three files.

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
    [PATH]    File or directory to compile. Defaults to current working directory.

OPTIONS:
    -s, --save                  Keep the binary after exit (default: delete on exit)
    -p, --path <TARGET_PATH>    Destination for the saved binary (implies --save)
    -T, --tmp <TMP_PATH>        Override the tmp directory for transient builds (default: /tmp/crun)
        --no-werror             Disable -Werror — warnings print but don't abort compilation
    -t, --test-compile [<LANG>] Compile and run the bundled test(s); no value or "all" runs every
                                language in order. Valid: c, cpp, cs, go, zig, rs, swift, m
        --deps [<LANG>]         Install per-language toolchain dependencies; no value or "all"
                                installs every language, or name one to install just it
    -h, --help                  Print help
    -V, --version               Print version
```

**Tmp path** (no `--save`): `/tmp/crun/<random16chars>/` — the binary inside is named `output` for direct source-file builds, or located/derived from the build system or source file for build-system and C# targets.

**Save path** (with `--save`): `$HOME/.local/bin/<name>`, where `<name>` is the source file's stem (extension stripped) or the directory's name.

**Save path** (with `--save --path /some/dir`): `/some/dir/<name>` — or, if `--path` itself looks like a file (has an extension), that exact path is used as-is.

---

## Edge cases

- **No source files in directory** → clear error, exits 1.
- **Mixed languages in directory** → error listing what was found. Use a Makefile.
- **Multi-file Rust without `Cargo.toml`** → error unless `main.rs` exists (used as entry point).
- **Compiler not on PATH** → "compiler 'gcc' not found. Is C installed?" before attempting anything.
- **Program crashes/segfaults** → cleanup still runs (RAII guard), exit code mirrors the crash.
- **`--path` given** → `--save` is implied, no need to pass both.
- **Make output location** → best-effort: looks for `<dirname>/<dirname>` binary. If your Makefile names the output differently, crun will tell you to run it directly.