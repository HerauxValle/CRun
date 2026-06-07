/*
 * languages/swift.rs
 *
 * Compiler config for Swift (.swift files).
 * swiftc is available on both macOS and Linux (via swift.org toolchain).
 * On Linux, the Swift stdlib is dynamically linked — the user needs the
 * Swift runtime installed, but that's their problem, not ours.
 *
 * -O is intentionally omitted for faster compile times in the crun use case
 * (you're iterating on code, not shipping a release binary).
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "Swift",
        compiler: "swiftc",
        base_flags: &[
            // No -O: debug-speed compile is better for the script-like use case
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["swift"],
        // swiftc can take multiple .swift files: `swiftc a.swift b.swift -o out`
        supports_multi_file: true,
    }
}