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
        .\install.ps1 -Deps          — installs all necessary toolchain dependencies
#>

[CmdletBinding(DefaultParameterSetName="Install")]
param(
    [Parameter(ParameterSetName="Install")][switch]$Copy,
    [Parameter(ParameterSetName="Install")]
    [Parameter(ParameterSetName="Uninstall")]
    [string]$Bin = "crun",
    [Parameter(ParameterSetName="Uninstall")][switch]$Uninstall,
    [Parameter(ParameterSetName="Deps")][switch]$Deps
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
function Install-Dependencies {
    Write-Info "detecting platform and installing windows dependencies..."
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "installing windows dependencies via winget..."
        
        # Windows requires Visual Studio C++ build tools and the WinSDK components to link Swift properly
        Write-Info "installing build platform components (Visual Studio BuildTools & SDK)..."
        winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64" --source winget
        
        Write-Info "installing core application toolchains (Rust, .NET SDK, Swift)..."
        winget install --id Rustlang.Rustup -e
        winget install --id Microsoft.DotNet.SDK.8 -e
        winget install --id Swift.Toolchain -e --source winget
        
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "installing windows dependencies via chocolatey..."
        choco install rustup.install dotnet-sdk swift -y
    } else {
        Write-ErrorExit "neither winget nor choco found. please install rustup, dotnet-sdk, and swift manually."
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