/*
 * languages/c/test.rs
 *
 * Bundled smoke test for C. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal C test — prints a line and exits 0.
 */
#include <stdio.h>

int main(void) {
    printf("crun: C compilation OK\n");
    return 0;
}"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "c")
}
