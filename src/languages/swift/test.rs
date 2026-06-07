/*
 * languages/swift/test.rs
 *
 * Bundled smoke test for Swift. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal Swift test — requires swiftc on PATH (swift.org toolchain on Linux).
 */
import Foundation

print("crun: Swift compilation OK")"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "swift")
}
