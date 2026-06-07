/*
 * languages/go/test.rs
 *
 * Bundled smoke test for Go. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal Go test — single file, package main.
 * Note: Go requires the file to declare package main and have a main() func.
 */
package main

import "fmt"

func main() {
	fmt.Println("crun: Go compilation OK")
}
"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "go")
}
