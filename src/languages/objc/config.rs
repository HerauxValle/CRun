/*
 * languages/objc.rs
 *
 * Compiler config for Objective-C (.m files).
 * Objective-C is compiled with clang. Requires linking against the
 * Objective-C runtime (-lobjc) and on Linux also GNUstep if using Foundation.
 *
 * Note: Full AppKit/UIKit is macOS/iOS only. On Linux, only the runtime
 * and GNUstep's Foundation equivalent are available. We don't abstract
 * that here — if GNUstep isn't installed, the compile error will be clear.
 */

use crate::language::{CompilerConfig, ExecutionMode};

pub fn config() -> CompilerConfig {
    CompilerConfig {
        name: "Objective-C",
        compiler: "clang",
        base_flags: &[
            "-lobjc",    // link the ObjC runtime — always needed
            // GNUstep flags would go here if we auto-detected it,
            // but we leave that to the user via their source #imports.
        ],
        execution_mode: ExecutionMode::Native,
        extensions: &["m"],
        supports_multi_file: true,
    }
}