/*
 * languages/zig/test.rs
 *
 * Bundled smoke test for Zig. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"// languages/zig/hello.zig
// Minimal Zig test — single file, std.debug.print to stderr-free stdout via Writer.

const std = @import("std");

pub fn main() void {
    std.debug.print("crun: Zig compilation OK\n", .{});
}
"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "zig")
}
