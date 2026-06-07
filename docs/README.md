# crun docs

Deep-dive documentation for crun's internals, organized by topic. Start with
the project [README](../README.md) for the user-facing overview (install,
flags, language table); these docs cover the *why* and *how* behind the code.

- [architecture.md](architecture.md) — the four-stage pipeline, module map, data flow
- [languages.md](languages.md) — how language backends work and how to add one
- [language-packs.md](language-packs.md) — exact syntax reference for the 3 files in a language pack (config.rs / deps.rs / test.rs)
- [build-system-detection.md](build-system-detection.md) — directory detection, build system delegation
- [cli.md](cli.md) — every flag, what it does, and how paths are resolved
- [testing.md](testing.md) — the bundled test suite (`-t` / `--test-compile`)
- [installers.md](installers.md) — install.sh / install.ps1 internals, `--bin`, `--deps`, curl-pipe support
- [error-handling.md](error-handling.md) — error conventions, exit codes, edge cases
