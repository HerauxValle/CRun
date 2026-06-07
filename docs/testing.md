# Bundled test suite (`-t` / `--test-compile`)

crun has a self-test mode that runs minimal real source files through the
*actual* pipeline (detect → compile → run → cleanup) for each supported language
— an integration smoke test for the compiler integrations themselves, not a unit-test framework.

**Everything for a language's test — source included — lives in one file**:
`src/languages/<lang>/test.rs`. There is no separate `tests/` tree, and no extra
source file to keep beside it. The test program's source is inlined directly as
a string constant:

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

The raw string literal (`r#"..."#`) means you don't need to escape quotes inside
the program. Being a plain `&'static str` constant, it's compiled directly into
the crun binary — nothing to locate at runtime, nothing extra to ship.

`language::run_bundled_test(source, ext)` (in `src/language.rs`) does the actual
work: writes `source` to a fresh tmp file named `hello.<ext>`, runs it through the
real `detect → compile → run` pipeline in its own tmp build dir, cleans both up
unconditionally, and turns a clean (exit-0) run into `Ok(())`. Each language's
`test.rs` is a thin wrapper naming its own inlined source and extension;
`src/testrun.rs` is just a dispatcher that knows the run order and resolves CLI
tokens to each language's `run_test` via the build-time-generated
`all_test_runners()` registry — no manual registration beyond the file existing.

For the complete, authoritative syntax of `test.rs` (and `config.rs`/`deps.rs`),
see [language-packs.md](language-packs.md).

## Layout

Each test's source is a `const SOURCE: &str = r#"..."#;` inlined in its
`test.rs`, e.g. inside `src/languages/zig/test.rs`, `src/languages/c/test.rs`.
Each program prints a recognizable string (`"crun: <Lang> compilation OK"`) so a
PASS/FAIL can be derived from successful compilation + a clean exit, without
needing to parse output beyond "did it run."

## Running it

```bash
crun -t          # run every language, in LANG_ORDER
crun -t all      # same as above
crun -t cpp      # run just the C++ test
crun -t zig      # run just the Zig test
```

`--test-compile` is mutually exclusive with passing a `[PATH]` (clap's `conflicts_with`).

## Resolution

`resolve_lang(token)` in `testrun.rs` maps a CLI token (extension or alias, e.g. `c++`, `csharp`, `c#`, `rust`, `objc`) to a registry key — the `languages/<key>/` directory name, e.g. `"cpp"` or `"cs"`. That key is then looked up in the build-time-generated `all_test_runners()` to find the language's `run_test` function. Unknown tokens produce an error listing valid options (kept in sync with `available_langs()`); keys with no `test.rs` produce a "no bundled test" error.

## Order

`LANG_ORDER` defines the sequence for `-t` / `-t all`:

```rust
&["c", "cpp", "rs", "go", "zig", "objc", "swift", "cs"]
```

Roughly: simplest/fastest compilers first, managed runtimes (C#) last, since `dotnet run` has the highest startup latency.

## Adding a test for a new language

1. Create `src/languages/<lang>/test.rs` with the source inlined and a `run_test` wrapper:
   ```rust
   const SOURCE: &str = r#"
   // a minimal program in <lang> that prints a clear OK string and exits 0
   "#;

   pub fn run_test() -> Result<(), String> {
       crate::language::run_bundled_test(SOURCE, "<ext>")
   }
   ```
   It's auto-discovered — no registry edits, no extra files.
2. Add the registry key to `LANG_ORDER` and to the `resolve_lang` match in `testrun.rs` (these still need manual sync — they encode *order* and *aliases*, not just presence).
3. Add it to the `available_langs()` summary string (shown on resolution errors and in `--help`).

This was done for Zig: `src/languages/zig/test.rs` with `SOURCE` holding the
Zig program inline and `run_bundled_test(SOURCE, "zig")`, `"zig"` inserted into
`LANG_ORDER` after `"go"`, and `"zig" => Some("zig")` added to `resolve_lang`.

For the complete `test.rs` contract (and `config.rs`/`deps.rs`), see
[language-packs.md](language-packs.md) — it's the canonical syntax reference.
