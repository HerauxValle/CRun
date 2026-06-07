/*
 * languages/cs/test.rs
 *
 * Bundled smoke test for C#. The source is inlined right here as a string
 * constant — nothing to ship or locate at runtime. See language::run_bundled_test
 * for the shared pipeline-driving logic (write to tmp, detect -> compile -> run).
 */

const SOURCE: &str = r#"/*
 * Minimal C# test — requires dotnet SDK installed.
 * Note: crun will generate a temporary .csproj if none exists.
 */
using System;

class Hello {
    static void Main() {
        Console.WriteLine("crun: C# compilation OK");
    }
}"#;

pub fn run_test() -> Result<(), String> {
    crate::language::run_bundled_test(SOURCE, "cs")
}
