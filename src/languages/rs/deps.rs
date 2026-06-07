/*
 * languages/rs/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps rs`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Rust (rustup)",
        arch: Some("rustup"),
        apt: Some("rustup"),
        dnf: Some("rustup"),
        zypper: Some("rustup"),
        brew: Some("rustup-init"),
        winget: Some("Rustlang.Rustup"),
        choco: Some("rustup.install"),
        ..Default::default()
    }
}
