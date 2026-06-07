/*
 * testrun.rs
 *
 * Thin dispatcher for --test-compile / -t. The actual test logic (the embedded
 * source, compiling, running, reporting) lives per-language in
 * languages/<lang>/test.rs (pub fn run_test() -> Result<(), String>),
 * built on the shared language::run_bundled_test helper.
 *
 * This module just knows the run order and how to map CLI tokens/aliases to
 * the generated test-runner registry — both still derived without any
 * per-language registration beyond the directory existing.
 */

use crate::language;

/// Canonical ordering for "run all" — deterministic, roughly by complexity.
pub const LANG_ORDER: &[&str] = &["c", "cpp", "rs", "go", "zig", "objc", "swift", "cs"];

/// Map a language identifier (extension or alias) to its registry key
/// (the languages/<dir> name used by build.rs / all_test_runners()).
fn resolve_lang(lang: &str) -> Option<&'static str> {
    match lang.to_lowercase().as_str() {
        "c"                       => Some("c"),
        "cpp" | "cc" | "cxx" | "c++" => Some("cpp"),
        "cs" | "csharp" | "c#"    => Some("cs"),
        "go"                      => Some("go"),
        "zig"                     => Some("zig"),
        "rs" | "rust"             => Some("rs"),
        "swift"                   => Some("swift"),
        "m" | "objc"              => Some("objc"),
        _                         => None,
    }
}

/// Human-readable list of valid language identifiers.
pub fn available_langs() -> &'static str {
    "c, cpp, cs, go, zig, rs, swift, m  (aliases: c++, csharp, c#, rust, objc)"
}

/// Returns true if the given lang string means "run all languages".
pub fn is_run_all(lang: &str) -> bool {
    lang.to_lowercase() == "all"
}

/// Look up the test runner function for a resolved language key.
fn find_runner(key: &str) -> Option<fn() -> Result<(), String>> {
    language::all_test_runners()
        .into_iter()
        .find(|(k, _)| *k == key)
        .map(|(_, f)| f)
}

/// Run a single language's bundled test by CLI token (extension or alias).
pub fn run_one(lang: &str) -> Result<(), String> {
    let key = resolve_lang(lang).ok_or_else(|| {
        format!("unknown language '{}'. Valid: {}", lang, available_langs())
    })?;
    let runner = find_runner(key).ok_or_else(|| {
        format!("'{}' has no bundled test (no languages/{}/test.rs)", lang, key)
    })?;

    eprintln!("crun: test [{}]", key);
    runner().map_err(|e| format!("test [{}] failed: {}", key, e))
}

/// Run every language test in LANG_ORDER, continuing past failures, and
/// report a final pass/fail summary. Returns Err listing failed languages.
pub fn run_all() -> Result<(), String> {
    eprintln!("crun: running all language tests...\n");

    let mut passed = 0;
    let mut failed: Vec<&str> = Vec::new();

    for &key in LANG_ORDER {
        let Some(runner) = find_runner(key) else {
            eprintln!("  [{}] SKIP — no bundled test", key);
            continue;
        };

        eprintln!("  [{}] running...", key);
        match runner() {
            Ok(()) => {
                eprintln!("  [{}] PASS\n", key);
                passed += 1;
            }
            Err(e) => {
                eprintln!("  [{}] FAIL — {}\n", key, e);
                failed.push(key);
            }
        }
    }

    eprintln!("crun: tests done — {}/{} passed", passed, passed + failed.len());

    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("failed: {}", failed.join(", ")))
    }
}
