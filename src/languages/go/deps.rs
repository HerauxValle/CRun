/*
 * languages/go/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps go`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "Go",
        arch: Some("go"),
        apt: Some("golang-go"),
        dnf: Some("golang"),
        zypper: Some("go"),
        brew: Some("go"),
        winget: Some("GoLang.Go"),
        choco: Some("golang"),
        ..Default::default()
    }
}
