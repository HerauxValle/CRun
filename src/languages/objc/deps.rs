/*
 * languages/objc/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps objc`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Objective-C (clang)",
        arch: Some("clang"),
        apt: Some("clang"),
        dnf: Some("clang"),
        zypper: Some("clang"),
        brew: Some("llvm"),
        ..Default::default()
    }
}
