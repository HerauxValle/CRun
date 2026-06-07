# CLI reference (`src/args.rs`)

```
crun [OPTIONS] [PATH]
```

| Flag | Short | Description |
|---|---|---|
| `[PATH]` | — | File or directory to compile/run. Defaults to the current working directory. Mutually exclusive with `--test-compile`. |
| `--save` | `-s` | Keep the compiled binary instead of deleting it after the program exits. |
| `--path <TARGET_PATH>` | `-p` | Destination for the saved binary. Implies `--save`. If the path looks like a file (has an extension), it's used verbatim; otherwise it's treated as a directory and the binary is named after the source. |
| `--tmp <TMP_PATH>` | `-T` | Override the transient build directory (default `/tmp/crun/<random16>`). No effect with `--save`. Mnemonic: "T for tmpfs" — point it at a RAM-backed mount for faster iteration. |
| `--no-werror` | — | Disable promoting warnings to errors. C/C++/ObjC keep `-Wall` (warnings still print) but drop `-Werror`; Rust/Swift skip their strict-mode flags entirely. |
| `--test-compile [<LANG>]` | `-t` | Compile and run bundled test file(s). No value, or `all`, runs every supported language in `LANG_ORDER`. A specific language (or alias) runs just that one. Always transient (ignores `--save`). |
| `--deps [<LANG>]` | — | Install per-language toolchain dependencies for the current platform via the detected package manager. No value, or `all`, installs every language with a `deps.rs`. A specific language name/extension installs just that one. Mutually exclusive with `[PATH]` and `--test-compile`. |
| `--help` | `-h` | Print help. |
| `--version` | `-V` | Print version. |

## Path resolution details

**Transient (no `--save`)**: binary lives at `<tmp_root>/<random16chars>/<name>`. For direct single-file builds the binary is conventionally named `output`; for build-system and managed-runtime targets the name is derived from the build system's own output or the source filename.

**Saved, no `--path`**: `$HOME/.local/bin/<name>`, where `<name>` is the source file's stem (extension stripped) for files, or the directory's basename for directories.

**Saved, `--path /some/dir`**: `/some/dir/<name>` using the same name-derivation rules — unless `/some/dir` itself looks like a file path (has an extension), in which case it's used as the exact output path.

## `--test-compile` language tokens

Accepts the language's primary extension or a recognizable alias, resolved by `resolve_lang` in `src/testrun.rs`:

`c, cpp (c++), cs (csharp/c#), go, zig, rs (rust), swift, m (objc)`

See [testing.md](testing.md) for how the test runner uses these.
