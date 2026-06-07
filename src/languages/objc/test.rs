/*
 * languages/objc/test.rs
 *
 * Bundled smoke test for Objective-C. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal Objective-C test — uses only the ObjC runtime, no Foundation/AppKit.
 * Avoids GNUstep dependency so it works on any Linux with clang + libobjc.
 */
#include <stdio.h>

int main(void) {
    printf("crun: Objective-C compilation OK\n");
    return 0;
}"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "m")
}
