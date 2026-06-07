/*
 * testrun.rs
 *
 * Resolves and optionally runs the bundled test files for each language.
 * Used by --test-compile / -t.
 *
 * Three modes driven from main.rs:
 *   -t cpp     → compile+run tests/cpp/hello.cpp (single)
 *   -t         → compile+run all languages in LANG_ORDER, stop on first failure
 *   -t all     → same as above
 *
 * Test file resolution strategy:
 *   The binary may be a symlink (install.sh: ~/.local/bin/crun -> target/release/crun).
 *   We canonicalize() to follow all symlinks to the real binary, then walk UP the
 *   directory tree until we find a directory containing tests/<lang>/hello.<ext>.
 *   This means tests/ is found at the repo root regardless of symlink depth.
 *
 *   Fallback: cwd-relative tests/ for `cargo run` / dev use.
 */

use std::path::PathBuf;

/// Canonical ordering for "run all" — deterministic, roughly by complexity.
pub const LANG_ORDER: &[&str] = &["c", "cpp", "rs", "go", "m", "swift", "cs"];

/// Map a language identifier (extension or alias) to (subdir, file_extension).
fn resolve_lang(lang: &str) -> Option<(&'static str, &'static str)> {
    match lang.to_lowercase().as_str() {
        "c"                     => Some(("c",     "c")),
        "cpp" | "cc" | "cxx" |
        "c++"                   => Some(("cpp",   "cpp")),
        "cs" | "csharp" | "c#" => Some(("cs",    "cs")),
        "go"                    => Some(("go",    "go")),
        "rs" | "rust"           => Some(("rs",    "rs")),
        "swift"                 => Some(("swift", "swift")),
        "m"  | "objc"           => Some(("objc",  "m")),
        _                       => None,
    }
}

/// Human-readable list of valid language identifiers.
pub fn available_langs() -> &'static str {
    "c, cpp, cs, go, rs, swift, m  (aliases: c++, csharp, c#, rust, objc)"
}

/// Resolve the full path to the test file for a given language string.
pub fn resolve_test_path(lang: &str) -> Result<PathBuf, String> {
    let (subdir, ext) = resolve_lang(lang).ok_or_else(|| {
        format!("unknown language '{}'. Valid: {}", lang, available_langs())
    })?;

    let filename = format!("hello.{}", ext);

    // Walk up from the real binary (canonicalize follows the symlink chain).
    // install.sh symlinks ~/.local/bin/crun -> .../target/release/crun, so
    // current_exe() without canonicalize() gives us the symlink location,
    // not the repo. After canonicalize we get the true path and can walk up
    // to the repo root where tests/ lives.
    if let Ok(exe) = std::env::current_exe() {
        let real = exe.canonicalize().unwrap_or(exe);
        let mut search_dir = real.parent().map(|p| p.to_path_buf());
        while let Some(dir) = search_dir {
            let candidate = dir.join("tests").join(subdir).join(&filename);
            if candidate.exists() {
                return Ok(candidate);
            }
            // Stop at filesystem root to avoid infinite loop
            search_dir = dir.parent().map(|p| p.to_path_buf());
        }
    }

    // Fallback: cwd-relative for `cargo run` / dev
    let cwd_candidate = PathBuf::from("tests").join(subdir).join(&filename);
    if cwd_candidate.exists() {
        return Ok(cwd_candidate);
    }

    Err(format!(
        "test file for '{}' not found — expected tests/{}/{}.\n\
         Make sure the tests/ directory is present alongside the crun binary.",
        lang, subdir, filename
    ))
}

/// Returns true if the given lang string means "run all languages".
pub fn is_run_all(lang: &str) -> bool {
    lang.to_lowercase() == "all"
}