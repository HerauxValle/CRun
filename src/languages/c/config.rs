/*
 * languages/c.rs
 *
 * Compiler config for the C language.
 * Uses gcc. -std=c11 is a reasonable modern default — not too new, widely supported.
 * -Wall and -Werror are injected by compile.rs, not here, so --no-werror works uniformly.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "C",
        compiler: "gcc",
        base_flags: &[
            "-std=c11",  // modern C, stable across all major gcc versions
            "-lm",       // link libm by default — almost every C program uses math.h
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["c"],
        supports_multi_file: true, // gcc accepts multiple .c files in one invocation
    }
}