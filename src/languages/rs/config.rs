/*
 * languages/rust_lang.rs
 *
 * Compiler config for Rust (.rs files).
 * Uses rustc directly (not cargo) — crun is for single-file or flat-dir use,
 * not full Cargo projects. If a Cargo.toml is present, detect.rs will catch
 * that and use the build system path instead of this config.
 *
 * We use the 2021 edition by default. -C opt-level=0 keeps compile times fast
 * for the interactive/script use case (same reasoning as Swift above).
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "Rust",
        compiler: "rustc",
        base_flags: &[
            "--edition", "2021",
            "-C", "opt-level=0", // fast compile > fast binary for script use
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["rs"],
        // rustc doesn't naturally take multiple .rs files like gcc does —
        // multi-file Rust is cargo's job. For directories with multiple .rs
        // files and no Cargo.toml, compile.rs will look for main.rs as entry.
        supports_multi_file: false,
    }
}