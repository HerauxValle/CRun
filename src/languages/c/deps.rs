/*
 * languages/c/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps c`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "C (gcc)",
        arch: Some("gcc"),
        apt: Some("build-essential"),
        dnf: Some("gcc-c++"),
        zypper: Some("gcc-c++"),
        brew: Some("gcc"),
        ..Default::default()
    }
}
