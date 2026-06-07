# Error handling & edge cases

crun favors **clear, actionable error messages over generic failures**, and exits with non-zero codes that mirror the underlying problem so it composes well in scripts.

## General conventions

- Errors print to stderr with enough context to act on (what was being attempted, what was found instead).
- Compiler/build-system stderr is **inherited**, not captured — you see exactly what `gcc`/`cargo`/`dotnet` would print, including colorized diagnostics, rather than crun re-formatting or hiding it.
- The final exit code is the *child process's* exit code wherever possible — crun is meant to be transparent in pipelines (`crun script.c && do_thing` works as expected; a crash propagates its real signal-derived code).

## Specific cases

| Situation | Behavior |
|---|---|
| Unrecognized file extension | Error naming the extension and that no language config handles it. |
| Empty/no-source directory | Error, exit 1 — nothing to compile. |
| Mixed languages in a directory (no build system) | Error listing each detected language and its file count; suggests adding a build system file (Makefile, Cargo.toml, ...) to disambiguate intent. |
| Multi-file Rust without `Cargo.toml` and without `main.rs` | Error explaining that an entry point is required; suggests adding `Cargo.toml` for real multi-file projects. |
| Compiler binary not on `PATH` | `compiler '<bin>' not found. Is <Language> installed?` — checked *before* attempting to spawn, so the failure mode is a clear message rather than an OS-level "No such file or directory" from `Command::spawn`. |
| Compilation fails (non-zero exit from compiler) | crun stops the pipeline; the compiler's own diagnostics (already streamed to stderr) explain why. crun does not try to re-interpret compiler errors. |
| Program under test crashes/segfaults/panics | The `CleanupGuard` still runs during unwinding — tmp directory is removed regardless. crun's exit code mirrors the child's (e.g. 134 for SIGABRT-derived). |
| `Makefile` builds produce an unexpected binary name | Best-effort lookup of `<dirname>/<dirname>`; if not found, crun reports that it can't locate the output and suggests running the Makefile's binary directly — it won't guess randomly through the build tree. |
| `--path` passed without `--save` | `--save` is implied automatically (`Args::effective_save`) — no error, just works as expected. |
| Both a `[PATH]` and `--test-compile` given | clap rejects this at parse time (`conflicts_with`), with its standard "cannot be used with" message. |

## Why inherit stderr instead of capturing

Capturing and re-printing compiler output risks losing formatting (color, column alignment) that make diagnostics readable, and adds a point where crun could swallow or mis-order output relative to the program's own. Inheriting stderr means "what you'd see running the compiler yourself" is exactly what you get — one less thing to debug when something goes wrong.
