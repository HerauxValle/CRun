<#
.SYNOPSIS
    Builds crun in release mode and copies the binary to $HOME\.local\bin
    so it's on PATH without needing administrator privileges.

.DESCRIPTION
    Usage:
        .\install.ps1               — interactive: asks what you want (bin-only,
                                       deps, custom name, ...) and does it
        .\install.ps1 -Copy          — copies the binary explicitly (default behavior on Windows)
        .\install.ps1 -Name NAME     — install under a custom name, e.g. -Name runfile
                                       -> $HOME\.local\bin\runfile.exe
        .\install.ps1 -Bin [PATH]    — just grab the portable binary, nothing else: no
                                       PATH setup, no deps, no repo clone. Downloads
                                       the tracked bin\crun.exe straight from GitHub
                                       (or copies it if already cloned) to
                                       PATH\crun.exe. PATH defaults to $HOME.
        .\install.ps1 -Uninstall     — removes the installed binary (respects -Name)
        .\install.ps1 -Deps          — builds crun, then runs `crun --deps` to install
                                       every supported language's toolchain
        .\install.ps1 -Deps -DepsTarget zig
                                     — same, but only the named language (`crun --deps zig`)
                                       Toolchain package names live in crun itself
                                       (languages/<lang>/deps.rs) — this script just
                                       builds crun and hands off to it.
#>

[CmdletBinding(DefaultParameterSetName="Install")]
param(
    [Parameter(ParameterSetName="Install")][switch]$Copy,
    [Parameter(ParameterSetName="Install")]
    [Parameter(ParameterSetName="Uninstall")]
    [string]$Name = "crun",
    [Parameter(ParameterSetName="Uninstall")][switch]$Uninstall,
    [Parameter(ParameterSetName="Deps")][switch]$Deps,
    [Parameter(ParameterSetName="Deps")][string]$DepsTarget = "",
    [Parameter(ParameterSetName="BinOnly")][string]$Bin = $null
)

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/HerauxValle/CRun.git"
$RawBinUrl = "https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/bin/crun.exe"
$RawBuiltOnUrl = "https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/bin/built-on.json"
$BinDir = Join-Path $HOME ".local\bin"

function Write-Info ($Message) {
    Write-Host "[crun install] $Message" -ForegroundColor Cyan
}

function Write-ErrorExit ($Message) {
    Write-Error "[crun install] error: $Message"
    Exit 1
}

# --- Clear-JsDelivrCache: invalidate jsDelivr's cache for a @main path ---
# jsDelivr fronts GitHub raw content and caches it; @main can otherwise serve
# a stale build for a while after a push. The purge endpoint is public —
# call it right before fetching so we always get the latest.
function Clear-JsDelivrCache ($Path) {
    try {
        Invoke-WebRequest -Uri "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/$Path" -UseBasicParsing -TimeoutSec 5 | Out-Null
    } catch {}
}

# --- detect `irm <url> | iex` style invocation (no script file on disk) ---
# When run via iex, $PSCommandPath is empty — there's no local install.ps1.
# We only NOTE this here — cloning is deferred until we know the repo is
# actually needed (building requires it; -Bin alone does not).
$IsPipedInvocation = [string]::IsNullOrEmpty($PSCommandPath)
$RepoDir = if (-not $IsPipedInvocation) { Split-Path -Parent $PSCommandPath } else { $null }

if ($IsPipedInvocation) {
    # Purge install.sh/install.ps1 so the *next* irm|iex always gets the
    # version we're running right now (or newer), not a stale one.
    Start-Job -ScriptBlock {
        try { Invoke-WebRequest -Uri "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.ps1" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
        try { Invoke-WebRequest -Uri "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.sh"  -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
    } | Out-Null
}

$BinOnly = $PSBoundParameters.ContainsKey('Bin')
$BinOnlyPathGiven = $BinOnly -and $Bin
$BinOnlyPath = if ($BinOnlyPathGiven) { $Bin } else { $HOME }
$InstallTarget = Join-Path $BinDir "$Name.exe"

# --- interactive prompt (no relevant flags given) ---
# Ask everything up front, in one flow, identical whether piped or local —
# THEN decide what needs cloning/building based on the answers.
if (-not $Deps -and -not $Uninstall -and -not $BinOnly) {
    $reply = Read-Host "[crun install] just grab the portable binary, nothing else? [y/N]"
    if ($reply -match '^[Yy]') {
        $BinOnly = $true
        $pathReply = Read-Host "[crun install] where to? [default: $HOME]"
        if ($pathReply) { $BinOnlyPath = $pathReply }
    } else {
        $reply = Read-Host "[crun install] also install per-language toolchain dependencies via crun --deps? [y/N]"
        if ($reply -match '^[Yy]') {
            $Deps = $true
            $DepsTarget = Read-Host "[crun install] only one language (leave empty for all)?"
        }

        $nameReply = Read-Host "[crun install] install under a custom binary name instead of 'crun'? (leave empty to skip)"
        if ($nameReply) {
            $Name = $nameReply
            $InstallTarget = Join-Path $BinDir "$Name.exe"
        }
    }
}

# --- compatibility check: is a prebuilt binary safe to run on THIS machine? ---
# Compares built-on.json (written by whatever build produced the binary)
# against the current OS/arch. Returns $true (compatible) or $false (reject)
# and sets $script:CompatReason. Windows binaries link the MSVC runtime —
# only os/arch matter (no libc-version concept like glibc).
$script:CompatReason = ""
function Test-Compat ($JsonPath) {
    if (-not (Test-Path $JsonPath)) {
        $script:CompatReason = "no built-on.json found — can't verify compatibility"
        return $false
    }
    try {
        $info = Get-Content $JsonPath -Raw | ConvertFrom-Json
    } catch {
        $script:CompatReason = "built-on.json is unreadable/corrupt"
        return $false
    }

    $sysOs = "windows"
    $sysArch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }

    if ($info.os -ne $sysOs) {
        $script:CompatReason = "binary built for '$($info.os)', this machine is '$sysOs'"
        return $false
    }
    if ($info.arch -ne $sysArch) {
        $script:CompatReason = "binary built for '$($info.arch)', this machine is '$sysArch'"
        return $false
    }
    return $true
}

# --- reject: explain why, then offer to compile from source instead ---
function Deny-Incompatible ($Source) {
    Write-Info "prebuilt binary at $Source is NOT compatible with this machine:"
    Write-Info "  $script:CompatReason"
    Write-Info "rejecting — a copied binary would not run here."
    $reply = Read-Host "[crun install] compile from source instead? [Y/n]"
    if ($reply -match '^[Nn]') {
        Write-Info "aborted."
        Exit 1
    }
    Write-Info "compiling from source — this needs the full repo and a Rust toolchain (cargo)."
}

# --- bin-only mode: fetch just the binary — no clone, no build, no install ---
# If we already have a local checkout, copy the tracked bin\crun.exe from it;
# otherwise download it directly from GitHub. Either way: no `git clone`,
# since that would be enormously wasteful for "just give me the binary".
# Before using a prebuilt binary, checks built-on.json for compatibility —
# on mismatch, rejects and offers to compile instead (sets $script:NeedsCompile).
$script:NeedsCompile = $false
function Invoke-BinOnly ($DestDir) {
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir | Out-Null
    }
    $Dest = Join-Path $DestDir "crun.exe"
    $TrackedBinary = if ($RepoDir) { Join-Path $RepoDir "bin\crun.exe" } else { $null }
    $TrackedJson = if ($RepoDir) { Join-Path $RepoDir "bin\built-on.json" } else { $null }

    if ($TrackedBinary -and (Test-Path $TrackedBinary)) {
        if (-not (Test-Compat $TrackedJson)) {
            Deny-Incompatible $TrackedBinary
            $script:NeedsCompile = $true
            return
        }
        Write-Info "using tracked portable binary at $TrackedBinary"
        Copy-Item $TrackedBinary $Dest -Force
    } else {
        Clear-JsDelivrCache "bin/crun.exe"
        Clear-JsDelivrCache "bin/built-on.json"
        $JsonTmp = Join-Path ([System.IO.Path]::GetTempPath()) "crun-built-on-$([guid]::NewGuid()).json"
        try { Invoke-WebRequest -Uri $RawBuiltOnUrl -OutFile $JsonTmp -UseBasicParsing } catch {}
        if (-not (Test-Compat $JsonTmp)) {
            Deny-Incompatible $RawBinUrl
            Remove-Item $JsonTmp -ErrorAction SilentlyContinue
            $script:NeedsCompile = $true
            return
        }
        Remove-Item $JsonTmp -ErrorAction SilentlyContinue
        Write-Info "downloading portable binary from $RawBinUrl"
        try {
            Invoke-WebRequest -Uri $RawBinUrl -OutFile $Dest -UseBasicParsing
        } catch {
            Write-ErrorExit "download failed: $_"
        }
    }
    Write-Info "binary ready at $Dest"
}

if ($BinOnly) {
    Invoke-BinOnly $BinOnlyPath
    if (-not $script:NeedsCompile) { Exit 0 }
    # Incompatible prebuilt binary, user chose to compile — fall through to the
    # normal clone+build path below, installing as a copy to BinOnlyPath.
    $BinOnly = $false
    $Copy = $true
    $Name = "crun"
    $BinDir = $BinOnlyPath
    $InstallTarget = Join-Path $BinDir "$Name.exe"
}

# --- everything past this point needs the actual repo: clone now if piped ---
if ($IsPipedInvocation) {
    Write-Host "[crun install] detected piped install (irm | iex) — cloning repo" -ForegroundColor Cyan
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "[crun install] error: git not found. Install git and re-run."
        Exit 1
    }
    $CloneDir = Join-Path (Get-Location) "CRun"
    if (Test-Path (Join-Path $CloneDir ".git")) {
        Write-Host "[crun install] using existing clone at $CloneDir" -ForegroundColor Cyan
    } else {
        Write-Host "[crun install] cloning $RepoUrl to $CloneDir" -ForegroundColor Cyan
        git clone $RepoUrl $CloneDir
    }
    $RepoDir = $CloneDir
}

$ReleaseBinary = Join-Path $RepoDir "target\release\crun.exe"

# --- dependency logic ---
# Toolchain installation lives in crun itself (languages/<lang>/deps.rs +
# `crun --deps`), so every language declares its own package names (winget id,
# choco package, ...) in one place. This script's job is just: build crun,
# then ask it to install dependencies for this platform.
function Install-Dependencies {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-ErrorExit "cargo not found. Install Rust via https://rustup.rs (needed to build crun before it can install other deps)"
    }

    Write-Info "installing build platform components (Visual Studio BuildTools & SDK) needed to link Swift..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64" --source winget
    }

    Write-Info "building crun (release) so it can install its own dependencies..."
    $CargoToml = Join-Path $RepoDir "Cargo.toml"
    cargo build --release --manifest-path "$CargoToml"
    if (-not (Test-Path $ReleaseBinary)) {
        Write-ErrorExit "build succeeded but binary not found at $ReleaseBinary"
    }

    if ($DepsTarget) {
        Write-Info "delegating to: crun --deps $DepsTarget"
        & $ReleaseBinary --deps $DepsTarget
    } else {
        Write-Info "delegating to: crun --deps"
        & $ReleaseBinary --deps
    }
}

# --- check for deps flag ---
if ($Deps) {
    Install-Dependencies
    Write-Info "dependencies installed. please restart your terminal to reload environment variables, then run without flags."
    Exit 0
}

# --- uninstall ---
if ($Uninstall) {
    if (Test-Path $InstallTarget) {
        Remove-Item $InstallTarget -Force
        Write-Info "removed $InstallTarget"
    } else {
        Write-Info "nothing to remove at $InstallTarget"
    }
    Exit 0
}

# --- check cargo ---
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-ErrorExit "cargo not found. Install Rust via https://rustup.rs"
}

# --- build ---
Write-Info "building crun (release)..."
$CargoToml = Join-Path $RepoDir "Cargo.toml"
cargo build --release --manifest-path "$CargoToml"

if (-not (Test-Path $ReleaseBinary)) {
    Write-ErrorExit "build succeeded but binary not found at $ReleaseBinary"
}

# --- portable copy ---
# bin/crun.exe is a tracked, ready-to-grab copy of the freshly built binary —
# see bin/README.md. Refreshed on every install/rebuild; safe to overwrite,
# never the canonical artifact (that's always target/release/crun.exe).
$PortableBinDir = Join-Path $RepoDir "bin"
if (-not (Test-Path $PortableBinDir)) {
    New-Item -ItemType Directory -Path $PortableBinDir | Out-Null
}
Copy-Item $ReleaseBinary (Join-Path $PortableBinDir "crun.exe") -Force
Write-Info "refreshed portable binary at $(Join-Path $PortableBinDir 'crun.exe')"

# --- built-on.json ---
# Records ONLY what matters for binary compatibility, so -Bin can verify a
# prebuilt binary will actually run before copying it onto a target machine.
# On Windows the binary links against the MSVC runtime — arch/os match is
# what matters (no libc-version concept like glibc).
$PortableArch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
$BuiltOnJson = @{
    os = "windows"
    arch = $PortableArch
    libc = "msvc"
    libc_version = ""
} | ConvertTo-Json -Compress
Set-Content -Path (Join-Path $PortableBinDir "built-on.json") -Value $BuiltOnJson -NoNewline
Write-Info "wrote $(Join-Path $PortableBinDir 'built-on.json')"

# --- install ---
if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir | Out-Null
}

# Symlinks on Windows can require elevated Developer Mode access; copying is standard for local bins.
Copy-Item $ReleaseBinary $InstallTarget -Force
Write-Info "copied binary to $InstallTarget"

# --- PATH reminder ---
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($CurrentPath -notlike "*$BinDir*") {
    Write-Info "note: $BinDir is not in your Windows PATH variable."
    Write-Info "run this inside your PowerShell profile config to add it permanent:"
    Write-Host "  `[Environment`]::SetEnvironmentVariable(`"PATH`", `$CurrentPath + `";$BinDir`", `"User`")" -ForegroundColor Yellow
}

Write-Info "done. run: $Name --help"