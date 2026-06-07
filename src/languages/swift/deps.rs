/*
 * languages/swift/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps swift`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Swift",
        apt: Some("swiftlang"),
        dnf: Some("swift-lang"),
        brew: Some("swiftlang"),
        winget: Some("Swift.Toolchain"),
        choco: Some("swift"),
        ..Default::default()
    }
}
