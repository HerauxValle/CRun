/*
 * languages/rs/test.rs
 *
 * Bundled smoke test for Rust. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal Rust test — single file, no Cargo.toml, so rustc is invoked directly.
 */
fn main() {
    println!("crun: Rust compilation OK");
}"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "rs")
}
