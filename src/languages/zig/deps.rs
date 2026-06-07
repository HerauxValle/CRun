/*
 * languages/zig/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps zig`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Zig",
        arch: Some("zig"),
        apt: Some("zig"),
        dnf: Some("zig"),
        zypper: Some("zig"),
        brew: Some("zig"),
        winget: Some("zig.zig"),
        choco: Some("zig"),
        ..Default::default()
    }
}
