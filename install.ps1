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
                                       PATH setup, no deps. Copies the tracked
                                       bin\crun.exe if present (else builds first)
                                       to PATH\crun.exe. PATH defaults to $HOME.
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

# --- detect `irm <url> | iex` style invocation (no script file on disk) ---
# When run via iex, $PSCommandPath is empty — there is no local install.ps1 to find the repo from.
if ([string]::IsNullOrEmpty($PSCommandPath)) {
    Write-Host "[crun install] detected piped install (irm | iex) — cloning repo first" -ForegroundColor Cyan
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
    & (Join-Path $CloneDir "install.ps1") @PSBoundParameters
    Exit $LASTEXITCODE
}

$RepoDir = Split-Path -Parent $PSCommandPath
$BinDir = Join-Path $HOME ".local\bin"
$ReleaseBinary = Join-Path $RepoDir "target\release\crun.exe"
$InstallTarget = Join-Path $BinDir "$Name.exe"
$BinOnly = $PSBoundParameters.ContainsKey('Bin')
$BinOnlyPath = if ($Bin) { $Bin } else { $HOME }

function Write-Info ($Message) {
    Write-Host "[crun install] $Message" -ForegroundColor Cyan
}

function Write-ErrorExit ($Message) {
    Write-Error "[crun install] error: $Message"
    Exit 1
}

# --- bin-only mode ---
# Just deliver the binary to a path. No PATH setup, no deps. Prefers the
# tracked bin\crun.exe (no rebuild needed); falls back to building if absent.
function Invoke-BinOnly ($DestDir) {
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir | Out-Null
    }
    $Dest = Join-Path $DestDir "crun.exe"
    $TrackedBinary = Join-Path $RepoDir "bin\crun.exe"

    if (Test-Path $TrackedBinary) {
        Write-Info "using tracked portable binary at $TrackedBinary"
        Copy-Item $TrackedBinary $Dest -Force
    } else {
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            Write-ErrorExit "cargo not found. Install Rust via https://rustup.rs (needed to build crun — no portable binary present)"
        }
        Write-Info "no tracked portable binary found — building crun (release)..."
        $CargoToml = Join-Path $RepoDir "Cargo.toml"
        cargo build --release --manifest-path "$CargoToml"
        if (-not (Test-Path $ReleaseBinary)) {
            Write-ErrorExit "build succeeded but binary not found at $ReleaseBinary"
        }
        Copy-Item $ReleaseBinary $Dest -Force
    }
    Write-Info "binary copied to $Dest"
}

if ($BinOnly) {
    Invoke-BinOnly $BinOnlyPath
    Exit 0
}

# --- interactive prompt (no relevant flags given) ---
if (-not $Deps -and -not $Uninstall -and -not $BinOnly -and [Environment]::UserInteractive) {
    $reply = Read-Host "[crun install] just grab the portable binary, nothing else? [y/N]"
    if ($reply -match '^[Yy]') {
        $pathReply = Read-Host "[crun install] where to? [default: $HOME]"
        Invoke-BinOnly $(if ($pathReply) { $pathReply } else { $HOME })
        Exit 0
    }

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