<#
.SYNOPSIS
    Builds crun in release mode (in a tmp dir, never touching the repo's
    target\) and copies the binary to $HOME\.local\bin so it's on PATH
    without needing administrator privileges.

.DESCRIPTION
    Usage:
        .\install.ps1               — interactive: asks what you want (deps,
                                       custom name, ...) and does it
        .\install.ps1 -Name NAME     — install under a custom name, e.g. -Name runfile
                                       -> $HOME\.local\bin\runfile.exe
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
    [Parameter(ParameterSetName="Install")]
    [Parameter(ParameterSetName="Uninstall")]
    [string]$Name = "crun",
    [Parameter(ParameterSetName="Uninstall")][switch]$Uninstall,
    [Parameter(ParameterSetName="Deps")][switch]$Deps,
    [Parameter(ParameterSetName="Deps")][string]$DepsTarget = ""
)

$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/HerauxValle/CRun.git"
$BinDir = Join-Path $HOME ".local\bin"

function Write-Info ($Message) {
    Write-Host "[crun install] $Message" -ForegroundColor Cyan
}

function Write-ErrorExit ($Message) {
    Write-Error "[crun install] error: $Message"
    Exit 1
}

# --- self-purge: keep the jsDelivr-cached copies of these scripts fresh ---
# jsDelivr caches @main for up to 24h. Without this, users who irm the CDN
# URL can be stuck running a stale install.sh/install.ps1. Fire-and-forget,
# never blocks install on purge-network hiccups.
Start-Job -ScriptBlock {
    try { Invoke-RestMethod "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.sh"  -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Invoke-RestMethod "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.ps1" -ErrorAction SilentlyContinue | Out-Null } catch {}
} | Out-Null

# --- detect `irm <url> | iex` style invocation (no script file on disk) ---
# When run via iex, $PSCommandPath is empty — there's no local install.ps1.
$IsPipedInvocation = [string]::IsNullOrEmpty($PSCommandPath)
$RepoDir = if (-not $IsPipedInvocation) { Split-Path -Parent $PSCommandPath } else { $null }

$InstallTarget = Join-Path $BinDir "$Name.exe"

# --- interactive prompt (no relevant flags given) ---
# Ask everything up front, in one flow, identical whether piped or local.
if (-not $Deps -and -not $Uninstall) {
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

# --- overwrite check — ask BEFORE compiling, not after ---
# An existing file/reparse point at the target (e.g. a stale symlink left
# over from an older install) could break Copy-Item — confirm before
# clobbering it (and before wasting a build on a no-op).
if (-not $Uninstall -and (Test-Path $InstallTarget)) {
    $overwriteReply = Read-Host "[crun install] $InstallTarget already exists — overwrite? [y/N]"
    if ($overwriteReply -notmatch '^[Yy]') {
        Write-ErrorExit "aborted — $InstallTarget already exists"
    }
}

# --- clone if piped (we always need the repo — building is the only path now) ---
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

# --- check cargo ---
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-ErrorExit "cargo not found. Install Rust via https://rustup.rs"
}

# --- build into a tmp dir — never touches the repo's target\ ---
# crun is a small project; even a clean build from scratch is fast, so there's
# no real cost to always compiling fresh rather than tracking prebuilt binaries.
$BuildDir = Join-Path ([System.IO.Path]::GetTempPath()) "crun-build-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $BuildDir | Out-Null
try {
    Write-Info "building crun (release)..."
    $CargoToml = Join-Path $RepoDir "Cargo.toml"
    $env:CARGO_TARGET_DIR = $BuildDir
    cargo build --release --manifest-path "$CargoToml"
    Remove-Item Env:\CARGO_TARGET_DIR

    $ReleaseBinary = Join-Path $BuildDir "release\crun.exe"
    if (-not (Test-Path $ReleaseBinary)) {
        Write-ErrorExit "build succeeded but binary not found at $ReleaseBinary"
    }

    # --- dependency logic ---
    # Toolchain installation lives in crun itself (languages/<lang>/deps.rs +
    # `crun --deps`), so every language declares its own package names in one
    # place. This script's job is just: build crun, then ask it to install deps.
    if ($Deps) {
        if ($DepsTarget) {
            Write-Info "delegating to: crun --deps $DepsTarget"
            & $ReleaseBinary --deps $DepsTarget
        } else {
            Write-Info "delegating to: crun --deps"
            & $ReleaseBinary --deps
        }
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

    # --- install: always copy (never symlink — the build dir is ephemeral) ---
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir | Out-Null
    }
    # Already confirmed above (before compiling) if something exists here —
    # just clear it so Copy-Item doesn't choke on a stale reparse point.
    if (Test-Path $InstallTarget) {
        Remove-Item $InstallTarget -Force
    }
    Copy-Item $ReleaseBinary $InstallTarget -Force
    Write-Info "copied binary to $InstallTarget"

    # --- offer to clean up the cloned repo (piped installs only) ---
    # Default yes — most people who irm|iex this don't want a CRun\ checkout
    # left behind cluttering their cwd; the binary is already installed.
    if ($IsPipedInvocation) {
        $cleanupReply = Read-Host "[crun install] remove the cloned repo at $CloneDir? [Y/n]"
        if ($cleanupReply -notmatch '^[Nn]') {
            Remove-Item -Recurse -Force $CloneDir -ErrorAction SilentlyContinue
            Write-Info "removed $CloneDir"
        }
    }
} finally {
    Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue
}

# --- PATH reminder ---
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($CurrentPath -notlike "*$BinDir*") {
    Write-Info "note: $BinDir is not in your Windows PATH variable."
    Write-Info "run this inside your PowerShell profile config to add it permanent:"
    Write-Host "  `[Environment`]::SetEnvironmentVariable(`"PATH`", `$CurrentPath + `";$BinDir`", `"User`")" -ForegroundColor Yellow
}

Write-Info "done. run: $Name --help"
