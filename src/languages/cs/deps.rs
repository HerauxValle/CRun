/*
 * languages/cs/deps.rs
 *
 * Package-manager name mappings for installing this language's toolchain.
 * Used by `crun --deps` / `crun --deps cs`. None means "no mapping for
 * this manager — install manually"; install_dep() skips those gracefully.
 */

use crate::language::DepSpec;

pub fn deps() -> DepSpec {
    DepSpec {
        display: "C# (.NET SDK)",
        arch: Some("dotnet-sdk"),
        apt: Some("dotnet-sdk-8.0"),
        dnf: Some("dotnet-sdk-8.0"),
        zypper: Some("dotnet-sdk"),
        brew: Some("dotnet-sdk"),
        winget: Some("Microsoft.DotNet.SDK.8"),
        choco: Some("dotnet-sdk"),
        ..Default::default()
    }
}
