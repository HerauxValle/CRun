/*
 * languages/zig.rs
 *
 * Compiler config for Zig (.zig files).
 * Uses `zig build-exe`, which compiles a single file straight to a native
 * executable — no project scaffolding required, a good fit for the
 * compile-and-run-like-a-script use case.
 *
 * -femit-bin is appended by compile.rs via the standard `-o <path>` flag path
 * (zig accepts `-o` as shorthand for `-femit-bin=`).
 *
 * Zig's compiler is already strict about unused vars/imports (compile errors,
 * not warnings), so -Wall/-Werror don't apply — same reasoning as Go.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "Zig",
        compiler: "zig",
        base_flags: &[
            "build-exe", // subcommand — `zig build-exe <file> -o <out>`
            "-OReleaseFast",
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["zig"],
        // zig build-exe takes a single root source file; multi-file Zig
        // projects use build.zig, which would be its own build-system path.
        supports_multi_file: false,
    }
}
