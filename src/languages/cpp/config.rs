/*
 * languages/cpp.rs
 *
 * Compiler config for C++ (all variants: .cpp, .cc, .cxx, .c++).
 * Uses g++. -std=c++17 is the sweet spot: modern features, broad compiler support.
 * If a directory has mixed .c and .cpp files, detect.rs will flag cpp and use this.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "C++",
        compiler: "g++",
        base_flags: &[
            "-std=c++17", // C++17 is well-supported and covers most modern idioms
            "-lm",
        ],
        execution_mode: ExecutionMode::Native,
        // All common C++ source extensions — .cc and .cxx are used in some projects
        extensions: &["cpp", "cc", "cxx", "c++"],
        supports_multi_file: true,
    }
}