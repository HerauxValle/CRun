/*
 * languages/mod.rs
 *
 * Central registry for all supported language backends.
 * Each language module exposes a `config()` function returning a `CompilerConfig`.
 *
 * The module declarations and `all_languages()` just below are generated at
 * build time by build.rs, which scans this directory for *.rs files (see
 * OUT_DIR/language_registry.rs). To add a new language: drop
 * languages/mylang.rs implementing `pub fn config() -> CompilerConfig`
 * — that's the entire integration, nothing else to wire up.
 */

use std::path::Path;

/// How the compiled artifact is executed.
/// Most native languages just run the binary directly.
/// Managed runtimes (C#) need an interpreter/runtime prefix.
#[derive(Debug, Clone)]
pub enum ExecutionMode {
    /// Run the output path directly as a binary.
    Native,
    /// Prefix execution with a runtime command, e.g. `dotnet` or `mono`.
    Runtime(String),
}

/// Everything crun needs to know about compiling and running one language.
#[derive(Debug, Clone)]
pub struct CompilerConfig {
    /// Display name, used in error messages ("C++", "C#", etc.)
    pub name: &'static str,

    /// The compiler binary name as it appears on PATH (e.g. "gcc", "g++", "swiftc").
    pub compiler: &'static str,

    /// Flags always passed to the compiler, excluding -Wall/-Werror (added by compile.rs).
    /// Language-specific flags like -lstdc++ or --release go here.
    pub base_flags: &'static [&'static str],

    /// How the output binary (or bytecode) is executed after compilation.
    pub execution_mode: ExecutionMode,

    /// File extensions this config handles, without the leading dot.
    pub extensions: &'static [&'static str],

    /// If true, the compiler handles multiple source files natively in one invocation.
    /// If false, compile.rs will link them separately or error on multi-file input.
    pub supports_multi_file: bool,
}

// Module declarations and `all_languages()` (uses CompilerConfig above) — generated
// at build time by build.rs from the *.rs files present in this directory.
include!(concat!(env!("OUT_DIR"), "/language_registry.rs"));

/// Find the compiler config for a given source file by its extension.
/// Returns None if the extension is not recognized.
pub fn find_config(path: &Path) -> Option<CompilerConfig> {
    let ext = path.extension()?.to_str()?.to_lowercase();
    all_languages().into_iter().find(|lang| {
        lang.extensions.iter().any(|e| *e == ext.as_str())
    })
}