# Language packs — exact syntax reference

A "language pack" is a directory under `src/languages/` that teaches crun how to
compile, run, install dependencies for, and self-test one language. This document
specifies the **exact** contract for each of its three files. If you're adding a
language, this is the page to copy from.

```
src/languages/<key>/
  config.rs   — REQUIRED  — pub fn config() -> CompilerConfig
  deps.rs     — optional  — pub fn deps() -> DepSpec
  test.rs     — optional  — pub fn run_test() -> Result<(), String>
```

`<key>` is the directory name — lowercase, short, matches what `crun -t <key>` /
`crun --deps <key>` resolve to (e.g. `zig`, `cpp`, `cs`, `objc`). It does not have
to match the file extension (e.g. `cs` for C#, `objc` for `.m` files).

**Nothing is registered by hand.** `build.rs` scans `src/languages/` at build
time: any directory containing `config.rs` is treated as a language pack, and
`deps.rs`/`test.rs` are wired in automatically if present. Drop the directory in,
rebuild, done.

---

## 1. `config.rs` — required

Defines how to invoke the compiler and run the result. Must export exactly:

```rust
pub fn config() -> CompilerConfig
```

### `CompilerConfig` fields

```rust
pub struct CompilerConfig {
    pub name: &'static str,
    pub compiler: &'static str,
    pub base_flags: &'static [&'static str],
    pub execution_mode: ExecutionMode,
    pub extensions: &'static [&'static str],
    pub supports_multi_file: bool,
}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | `&'static str` | Display name shown in errors and progress messages, e.g. `"Zig"`, `"C++"`, `"Objective-C"`. Also the string `compile.rs` matches against for language-specific special-casing (see below). |
| `compiler` | `&'static str` | The binary invoked, as it appears on `PATH` — `"gcc"`, `"zig"`, `"dotnet"`. Checked for existence before spawning; missing compilers produce `compiler '<x>' not found. Is <name> installed?`. |
| `base_flags` | `&'static [&'static str]` | Flags always passed, **in order**, before the output flag and source file(s). Do **not** include `-Wall`/`-Werror`/`-D warnings`/equivalents — `compile.rs` injects those centrally so `--no-werror` works uniformly. Subcommands count as flags too: Go's `&["build"]`, Zig's `&["build-exe", "-OReleaseFast"]`. |
| `execution_mode` | `ExecutionMode` | `Native` — run the produced binary directly. `Runtime("dotnet".to_string())` — prefix execution with a runtime/interpreter command (currently only C# uses this; `run.rs` special-cases `"dotnet"` to mean `dotnet run <path>`). |
| `extensions` | `&'static [&'static str]` | File extensions this pack handles, **without the leading dot**, lowercase: `&["cpp", "cc", "cxx", "c++"]`. `detect.rs` matches a file's extension against every pack's list (first match wins) to pick a config. |
| `supports_multi_file` | `bool` | `true` if the compiler natively accepts multiple source files / a whole directory in one invocation (gcc, g++, go build, swiftc, dotnet). `false` if it only takes a single root file (rustc, zig build-exe) — `detect.rs` then requires either a single source file or a `main.rs`-style entry point. |

### Minimal example

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

### When you need more than the contract allows

A few languages need behavior `CompilerConfig` can't express declaratively — a
non-standard output flag, different werror handling, etc. These live as
`config.name`-keyed special cases in `compile.rs` (search for `is_zig`, `is_go`,
`is_csharp`, `is_rust`, `is_swift`). Example: Zig requires a single joined
`-femit-bin=<path>` argument instead of `-o <path>`, so `compile.rs` checks
`config.name == "Zig"` and builds that argument with `OsString`. If your language
needs something like this, add a similar named check rather than growing
`CompilerConfig` — keep the struct purely declarative.

---

## 2. `deps.rs` — optional, enables `crun --deps <key>`

Exports exactly:

```rust
pub fn deps() -> DepSpec
```

### `DepSpec` fields

```rust
pub struct DepSpec {
    pub display: &'static str,
    pub arch: Option<&'static str>,
    pub apt: Option<&'static str>,
    pub dnf: Option<&'static str>,
    pub zypper: Option<&'static str>,
    pub brew: Option<&'static str>,
    pub winget: Option<&'static str>,
    pub choco: Option<&'static str>,
}
```

| Field | Package manager | Platform |
|---|---|---|
| `display` | — | Human label used in progress/error messages and as the match target for `crun --deps <name>` (case-insensitive substring match, e.g. `--deps zig` matches `display: "Zig"`, `--deps c++` matches `"C++ (g++)"`). |
| `arch` | pacman | Arch Linux |
| `apt` | apt-get | Debian/Ubuntu/Pop/Mint |
| `dnf` | dnf | Fedora/RHEL/CentOS |
| `zypper` | zypper | openSUSE/SUSE |
| `brew` | Homebrew | macOS |
| `winget` | winget | Windows |
| `choco` | Chocolatey | Windows (fallback if no winget) |

Each field is `Option<&'static str>` — the **package name as that manager knows
it**. Use `None` when there's no sensible mapping (e.g. Swift has no first-class
Arch package — it's normally installed from the AUR, which doesn't fit this
model). `language::install_dep` skips `None` entries with an "install manually"
message rather than failing.

### Example

```rust
use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Zig",
        arch: Some("zig"),
        apt: Some("zig"),
        dnf: Some("zig"),
        zypper: Some("zig"),
        brew: Some("zig"),
        winget: Some("zig.zig"),
        choco: Some("zig"),
        ..Default::default()
    }
}
```

Use `..Default::default()` to fill any fields you omit with `None` — `DepSpec`
derives `Default`.

### What happens at runtime

`crun --deps` (no language) detects the platform's package manager once via
`PkgManager::detect()` (reads `/etc/os-release` `ID=` on Linux; checks for
`brew`/`winget`/`choco` elsewhere), then calls `install_dep` for every pack's
`DepSpec`, continuing past individual failures and reporting a summary.
`crun --deps <name>` does the same for just the one matching pack.

---

## 3. `test.rs` — optional, enables `crun -t <key>`

Exports exactly:

```rust
pub fn run_test() -> Result<(), String>
```

The convention is to **inline the test program's source as a string constant**
right in this file, then hand it to the shared runner:

```rust
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

There is **no separate `tests/` directory and no file to ship alongside the
binary** — the source lives in this file as a `&'static str`, compiled directly
into the crun binary. Use a raw string literal (`r#"..."#`) so you don't have to
escape quotes inside the program.

### What `run_bundled_test` does for you

`language::run_bundled_test(source: &str, ext: &str) -> Result<(), String>`:

1. Creates a fresh tmp directory and writes `source` to `hello.<ext>` inside it.
2. Runs that file through the **real** `detect → compile → run` pipeline (the
   exact same code path a user's `crun hello.<ext>` would take) in its own tmp
   build directory.
3. Cleans up both tmp directories unconditionally.
4. Returns `Ok(())` on a clean (exit-0) run, or `Err(...)` describing what failed
   — a detect/compile error, or a non-zero exit code.

Your test program should print something recognizable and exit `0`. The
established convention is:

```
crun: <DisplayName> compilation OK
```

This is purely a smoke test for the compiler integration — it confirms the
toolchain is installed, the flags are valid, and the binary runs. It is not a
place for language feature coverage.

### Wiring into the test runner

`run_test` being present makes `crun -t <key>` work for that one language, but
**`crun -t` / `-t all` (run everything in order) and CLI aliases need one more
manual step** — `testrun.rs` still owns the run order and alias table:

1. Add `<key>` to `LANG_ORDER` in `src/testrun.rs` (controls `-t all` ordering —
   put cheap/fast compilers earlier, slow managed runtimes like C# last).
2. Add `<key>` (and any aliases — extensions, alternate spellings) to the
   `resolve_lang` match in the same file.
3. Add `<key>` to the `available_langs()` summary string (shown in `--help` and
   on resolution errors).
4. Update the "Valid: ..." doc comment on `--test-compile` in `src/args.rs` and
   the equivalent line in the README's flag table.

These four are the *only* places that still require manual edits when adding a
testable language — everything else (`config.rs`, `deps.rs`, the registry,
`all_test_runners()`) is fully auto-discovered.

---

## Summary checklist for a new language

- [ ] `src/languages/<key>/config.rs` with `pub fn config() -> CompilerConfig` — **this alone makes the language fully usable for compiling and running**
- [ ] *(optional)* `src/languages/<key>/deps.rs` with `pub fn deps() -> DepSpec` — enables `crun --deps <key>`, zero extra wiring
- [ ] *(optional)* `src/languages/<key>/test.rs` with `pub fn run_test()` + inlined `SOURCE` — enables `crun -t <key>`
- [ ] *(only if you added `test.rs`)* register `<key>` in `testrun.rs`'s `LANG_ORDER` + `resolve_lang` + `available_langs()`, and in `args.rs`'s doc comment + the README flag table
- [ ] *(only if the compiler needs non-standard handling)* add a `config.name`-keyed special case in `compile.rs`
