# Architecture

crun is a small Rust CLI built around a four-stage pipeline:

```
detect  →  compile  →  run  →  cleanup
```

## Module map

| Module | Responsibility |
|---|---|
| `main.rs` | Entry point. Parses args, dispatches to the pipeline or to the test runner, resolves output paths, prints final exit codes. |
| `args.rs` | clap `derive`-based CLI definition (`Args` struct). All flags and their docs live here. |
| `detect.rs` | Figures out *what* to compile from a path: single file, build-system directory, or scanned source tree. |
| `compile.rs` | Turns a detection result into a running compiler invocation; locates the resulting binary. |
| `run.rs` | Executes the compiled binary (or `dotnet run` for managed runtimes), arms cleanup, mirrors the exit code. |
| `cleanup.rs` | `CleanupGuard` — RAII wrapper that deletes the tmp build directory on `Drop`. |
| `language.rs` | Defines `CompilerConfig` / `ExecutionMode` / `DepSpec` / `PkgManager`, shared helpers (`install_dep`, `run_bundled_test`, `find_config`), and includes the build-time generated registry. |
| `languages/<lang>/` | One directory per supported language: `config.rs` (required), plus optional `deps.rs` (toolchain install) and `test.rs` (bundled smoke test). |
| `testrun.rs` | Thin dispatcher for `-t`/`--test-compile` — maps CLI tokens to each language's `run_test()` via the generated registry. |
| `build.rs` | Build-time codegen — scans `src/languages/*/` directories and generates the module registry (see [languages.md](languages.md)). |

## Data flow

1. `main.rs` parses `Args`. If `--test-compile` was passed, control goes to `testrun::run_all_tests` / a single-language run instead of the normal pipeline.
2. Otherwise, the path (or cwd) goes into `detect::detect`, which returns a `Detection` describing what was found (a `CompilerConfig` plus either a source file, a list of source files, or a build-system kind) and where it lives.
3. `compile::compile` takes the `Detection` and an output path (tmp or save target), assembles and runs the compiler/build-system command with stderr inherited (so you see compiler diagnostics exactly as-is), and returns the path to the resulting binary.
4. `run::run` arms a `CleanupGuard` for the build directory, executes the binary (or hands off to `dotnet run` for C#), waits for it, and returns its exit code.
5. When the guard drops — on success, early return, or panic — `cleanup.rs` removes the tmp directory. `--save` disarms the guard so the binary survives.
6. `main.rs` propagates the child's exit code as crun's own exit code, so crun is transparent in shell pipelines and scripts.

## Why RAII cleanup

Cleanup is tied to Rust's `Drop` rather than a `trap`/`atexit`/manual "remember to delete this" call. That means a panic anywhere in the run stage — or an early `?` return — still triggers deletion, because the guard's destructor runs during unwinding. `--save` simply calls `.disarm()` on the guard before it goes out of scope.

**A subtlety that bit this exact mechanism**: `run::run` arms the guard, runs the
program, then `drop(guard)`s it before exiting — but `run_native`/`run_with_runtime`
used to call `std::process::exit(code)` directly to mirror the child's exit code.
`process::exit` terminates the process immediately; it never returns, so the
`drop(guard)` a few lines later was dead code and every transient run leaked its
`/tmp/crun/<random>/` build directory. The fix: those helpers now *return* the
exit code instead of calling `process::exit` themselves, so `run()` can drop the
guard first and exit only afterward. (Fixed in v1.1.0 — see `src/run.rs`.)
