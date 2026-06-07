/*
 * languages/go.rs
 *
 * Compiler config for Go (.go files).
 * Uses `go build`. Go handles multi-file packages natively — all .go files
 * in a directory are one package, so we just point `go build` at the directory.
 *
 * Go doesn't use -Wall/-Werror (the compiler is already strict by default —
 * unused imports and variables are compile errors). compile.rs skips those
 * flags for Go specifically, based on the language name check.
 *
 * The output binary from `go build -o <out> <dir>` is a native executable,
 * so ExecutionMode::Native works fine.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "Go",
        compiler: "go",
        base_flags: &[
            "build",  // subcommand — `go build -o <out> <sources>`
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["go"],
        // Go's entire model is multi-file packages, so this is always true.
        supports_multi_file: true,
    }
}