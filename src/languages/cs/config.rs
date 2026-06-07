/*
 * languages/csharp.rs
 *
 * Compiler config for C# (.cs files).
 * * Powered by .NET 10 File-Based App Engine.
 * We invoke `dotnet build` directly targeting the source files and direct
 * output layout configuration parameters.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "C#",
        compiler: "dotnet",
        base_flags: &[
            "build",
            "--nologo",
            "--configuration", "Release",
        ],
        execution_mode: ExecutionMode::Runtime("dotnet".to_string()),
        extensions: &["cs"],
        supports_multi_file: true,
    }
}