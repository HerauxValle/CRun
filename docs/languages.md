# Language backends

Every supported language lives in its own directory under `src/languages/<name>/`,
containing up to three files:

```
src/languages/zig/
  config.rs   — pub fn config() -> CompilerConfig          (required)
  deps.rs     — pub fn deps() -> DepSpec                   (optional — enables `--deps`)
  test.rs     — pub fn run_test() -> Result<(), String>    (optional — enables `-t`)
```

Shared types (`CompilerConfig`, `ExecutionMode`, `DepSpec`, `PkgManager`) and helpers
(`install_dep`, `run_bundled_test`, `find_config`) live in `src/language.rs` — note
the *singular* name, distinguishing the shared module from the `languages/` directory
of per-language backends it orchestrates.

## Zero-registration auto-discovery

`build.rs` runs at build time, scans `src/languages/` for subdirectories containing
a `config.rs`, and generates `OUT_DIR/language_registry.rs` with:

- `mod <name> { pub mod config; [pub mod deps;] [pub mod test;] }` declarations (using `#[path]` so they resolve correctly from `OUT_DIR`)
- `all_languages() -> Vec<CompilerConfig>`
- `all_dep_specs() -> Vec<DepSpec>` (only for languages with `deps.rs`)
- `all_test_runners() -> Vec<(&'static str, fn() -> Result<(), String>)>` (only for languages with `test.rs`)

This is `include!`d into `language.rs` after the shared types are defined. **Adding,
removing, or extending a language never touches build.rs, language.rs, or any
registry — drop a directory in, and it's discovered.**

## `config.rs`: the compiler contract

```rust
pub struct CompilerConfig {
    pub name: &'static str,             // display name, e.g. "Zig"
    pub compiler: &'static str,         // binary to invoke, e.g. "zig"
    pub base_flags: &'static [&'static str], // flags always passed, in order
    pub execution_mode: ExecutionMode,  // Native or Runtime(interpreter)
    pub extensions: &'static [&'static str], // file extensions this config handles
    pub supports_multi_file: bool,      // can a directory of these be compiled as one unit?
}
```

`ExecutionMode::Native` runs the produced binary directly; `ExecutionMode::Runtime(cmd)`
prefixes execution with an interpreter (C# is the only user today — `dotnet run <file.cs>`
compiles and runs in one step, so `run` hands off to it instead of executing a binary).

### Special cases handled centrally in `compile.rs`

Kept out of `CompilerConfig` to keep configs purely declarative — these are
exceptions, not part of the contract:

- **Warning/error promotion**: C/C++/Objective-C get `-Wall -Werror`, Rust gets
  `-D warnings`, Swift gets `-warnings-as-errors`. Go, Zig, and C# are excluded —
  their compilers already treat unused vars/imports as hard errors. `--no-werror`
  disables all of it uniformly.
- **Output flag**: most compilers accept `-o <path>`. C# has none (handled by
  `dotnet run`). Zig needs a single joined `-femit-bin=<path>` argument (built via
  `OsString` to avoid lossy path conversion) rather than a separate `-o` token.
- **Compiler-on-PATH check**: produces `compiler 'gcc' not found. Is C installed?`
  before spawning, instead of an opaque OS error.

These checks key off `config.name`, mirroring the existing `is_zig`/`is_go`/etc.
booleans in `compile.rs`.

## `deps.rs`: toolchain installation (`--deps`)

```rust
pub fn deps() -> DepSpec {
    DepSpec {
        display: "Zig",
        arch: Some("zig"), apt: Some("zig"), dnf: Some("zig"),
        zypper: Some("zig"), brew: Some("zig"),
        winget: Some("zig.zig"), choco: Some("zig"),
        ..Default::default()
    }
}
```

`DepSpec` is a flat table of package names, one field per package manager
(`arch` → pacman, `apt`, `dnf`, `zypper`, `brew`, `winget`, `choco`). `None` means
"no mapping for this manager — install manually," and `language::install_dep` skips
those gracefully with a message rather than erroring.

`crun --deps [LANG]`:
1. Detects the platform's package manager once (`PkgManager::detect` — reads
   `/etc/os-release` `ID=` on Linux, checks for `brew`/`winget`/`choco` elsewhere).
2. Collects every language's `DepSpec` via `all_dep_specs()`.
3. With no `LANG` (or `all`): installs every spec, continuing past individual
   failures and reporting which ones failed at the end.
4. With a `LANG`: matches it case-insensitively against `DepSpec::display` and
   installs just that one.

`install.sh --deps [lang]` / `install.ps1 -Deps [-DepsTarget lang]` no longer
contain any package-name knowledge themselves — they build crun (if needed) and
delegate straight to `crun --deps [lang]`. This means every language's dependency
story lives in exactly one place: its own `deps.rs`.

## `test.rs`: the bundled smoke test (`-t` / `--test-compile`)

The test source is **inlined directly as a string constant in `test.rs`** — no
separate `tests/` tree, no extra file shipped or located at runtime:

```rust
// src/languages/zig/test.rs
const SOURCE: &str = r#"
const std = @import("std");

pub fn main() void {
    std.debug.print("crun: Zig compilation OK\n", .{});
}
"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "zig")
}
```

A raw string literal (`r#"..."#`) avoids having to escape quotes inside the
program. As a plain `&'static str` it's compiled straight into the crun binary.

The shared `language::run_bundled_test(source, ext)` does the actual work: writes
`source` to a fresh tmp file, runs it through the real `detect → compile → run`
pipeline in its own tmp build directory, cleans both up, and reports
success/failure based on a clean exit. Each language's `test.rs` is a thin
wrapper naming its own embedded source and extension — kept per-language (rather
than fully generic) so a language with unusual test needs can override the body
freely without touching shared code.

`testrun.rs` is now a thin dispatcher: it knows the run order (`LANG_ORDER`), maps
CLI tokens/aliases to registry keys, and looks up each language's `run_test` via
the generated `all_test_runners()`.

## Adding a new language

Create `src/languages/mylang/config.rs`:

```rust
use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "MyLang",
        compiler: "mylangc",
        base_flags: &["-O2"],
        execution_mode: ExecutionMode::Native,
        extensions: &["ml"],
        supports_multi_file: false,
    }
}
```

That alone makes the language fully usable for compiling and running files.
Optionally add:

- `deps.rs` (see above) to make `crun --deps mylang` work.
- `test.rs` with the test source inlined as a `const SOURCE: &str = r#"..."#`
  to make `crun -t mylang` work — and add the registry key to `LANG_ORDER` /
  `resolve_lang` in `testrun.rs` and the "valid langs" doc strings in `args.rs`
  / the README.

If the language needs special compile-time handling (non-standard output flag,
different werror treatment, etc.), add it to `compile.rs` keyed off `config.name`.

**For the exact, authoritative syntax of all three files** — every field,
every type, what's required vs. optional — see [language-packs.md](language-packs.md).

## Currently supported

See the language table in the [project README](../README.md#language-support) —
duplicating it here would just rot.
