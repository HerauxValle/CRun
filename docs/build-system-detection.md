# Detection (`src/detect.rs`)

`detect::detect(path)` is the first pipeline stage. It decides *what* to build and *how*, returning a `Detection` that downstream stages consume.

## File input

If `path` is a file, its extension is looked up against every registered language's `extensions` list. First match wins. No match → error naming the unrecognized extension.

## Directory input

`detect_dir` checks for build-system marker files, **in this priority order**:

1. `Makefile` → Make
2. `CMakeLists.txt` → CMake
3. `meson.build` → Meson
4. `Cargo.toml` → Cargo
5. `*.csproj` → dotnet

First match short-circuits — if a directory has both a `Makefile` and a `Cargo.toml`, Make wins (the assumption is that an explicit Makefile reflects deliberate build customization).

If none are present, detection falls back to **source scanning**:

- `collect_recursive` walks the tree, skipping `.` (hidden dirs), `target`, `build`, and `node_modules` — directories that are virtually always build artifacts or dependency trees rather than source.
- Files are grouped by the language they map to (via extension).
- **Exactly one language found** → proceed with that language's config; if it `supports_multi_file`, all files are passed to the compiler together (e.g. Go, which compiles a directory as one package).
- **Zero source files** → error, exit 1.
- **More than one language found** → error listing each language and its file count — crun refuses to guess; the fix is either to separate the directories or add a build system file.

## Special case: multi-file Rust without Cargo.toml

Rust files without a `Cargo.toml` are only compilable directly if there's a clear entry point. `detect` looks for `main.rs` specifically and uses it as the rustc entry; other `.rs` files in the same directory without `main.rs` produce an error directing the user to add a `Cargo.toml`.

## Why this order and these rules

- Build systems encode the author's intent precisely (compiler flags, dependencies, multi-crate layouts) — always prefer them over guessing.
- Mixed-language directories are almost always either accidental (stray files) or a case that needs a real build system — silently picking one language would produce confusing partial builds.
