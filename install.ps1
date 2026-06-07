<#
.SYNOPSIS
    Builds crun in release mode and copies the binary to $HOME\.local\bin
    so it's on PATH without needing administrator privileges.

.DESCRIPTION
    Usage:
        .\install.ps1               — installs to $HOME\.local\bin\crun.exe
        .\install.ps1 -Copy          — copies the binary explicitly (default behavior on Windows)
        .\install.ps1 -Bin NAME      — install under a custom name, e.g. -Bin runfile
                                       -> $HOME\.local\bin\runfile.exe
        .\install.ps1 -Uninstall     — removes the installed binary (respects -Bin)
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
    [string]$Bin = "crun",
    [Parameter(ParameterSetName="Uninstall")][switch]$Uninstall,
    [Parameter(ParameterSetName="Deps")][switch]$Deps,
    [Parameter(ParameterSetName="Deps")][string]$DepsTarget = ""
)

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/HerauxValle/CRun.git"

# --- detect `irm <url> | iex` style invocation (no script file on disk) ---
# When run via iex, $PSCommandPath is empty — there is no local install.ps1 to find the repo from.
if ([string]::IsNullOrEmpty($PSCommandPath)) {
    Write-Host "[crun install] detected piped install (irm | iex) — cloning repo first" -ForegroundColor Cyan
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "[crun install] error: git not found. Install git and re-run."
        Exit 1
    }
    $CloneDir = Join-Path $HOME "Projects\CRun"
    if (Test-Path (Join-Path $CloneDir ".git")) {
        Write-Host "[crun install] using existing clone at $CloneDir" -ForegroundColor Cyan
    } else {
        Write-Host "[crun install] cloning $RepoUrl to $CloneDir" -ForegroundColor Cyan
        New-Item -ItemType Directory -Force -Path (Split-Path $CloneDir) | Out-Null
        git clone $RepoUrl $CloneDir
    }
    & (Join-Path $CloneDir "install.ps1") @PSBoundParameters
    Exit $LASTEXITCODE
}

$RepoDir = Split-Path -Parent $PSCommandPath
$BinDir = Join-Path $HOME ".local\bin"
$ReleaseBinary = Join-Path $RepoDir "target\release\crun.exe"
$InstallTarget = Join-Path $BinDir "$Bin.exe"

function Write-Info ($Message) {
    Write-Host "[crun install] $Message" -ForegroundColor Cyan
}

function Write-ErrorExit ($Message) {
    Write-Error "[crun install] error: $Message"
    Exit 1
}

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

Write-Info "done. run: $Bin --help"