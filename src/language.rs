/*
 * language.rs
 *
 * Central types and shared helpers for language backends.
 *
 * Each language lives in its own directory under src/languages/<name>/ with:
 *   config.rs — pub fn config() -> CompilerConfig         (required)
 *   deps.rs   — pub fn deps() -> DepSpec                  (package manager names)
 *   test.rs   — pub fn run_test() -> Result<(), String>   (bundled smoke test)
 *
 * build.rs scans src/languages/ for subdirectories at build time and generates
 * the module declarations + `all_languages()` / `all_dep_specs()` registries
 * (see OUT_DIR/language_registry.rs, included below). Adding a language is
 * just "drop a directory in there" — nothing to register by hand.
 */

use std::path::Path;
use std::process::Command;

/// How the compiled artifact is executed.
/// Most native languages just run the binary directly.
/// Managed runtimes (C#) need an interpreter/runtime prefix.
#[derive(Debug, Clone)]
pub enum ExecutionMode {
    /// Run the output path directly as a binary.
    Native,
    /// Prefix execution with a runtime command, e.g. `dotnet` or `mono`.
    Runtime(String),
}

/// Everything crun needs to know about compiling and running one language.
#[derive(Debug, Clone)]
pub struct CompilerConfig {
    /// Display name, used in error messages ("C++", "C#", etc.)
    pub name: &'static str,

    /// The compiler binary name as it appears on PATH (e.g. "gcc", "g++", "swiftc").
    pub compiler: &'static str,

    /// Flags always passed to the compiler, excluding -Wall/-Werror (added by compile.rs).
    /// Language-specific flags like -lstdc++ or --release go here.
    pub base_flags: &'static [&'static str],

    /// How the output binary (or bytecode) is executed after compilation.
    pub execution_mode: ExecutionMode,

    /// File extensions this config handles, without the leading dot.
    pub extensions: &'static [&'static str],

    /// If true, the compiler handles multiple source files natively in one invocation.
    /// If false, compile.rs will link them separately or error on multi-file input.
    pub supports_multi_file: bool,
}

/// Package name per package manager, used by `--deps`.
/// `None` means "this manager doesn't carry it / not applicable on this platform" —
/// install_for() skips it gracefully rather than erroring.
#[derive(Debug, Clone, Default)]
pub struct DepSpec {
    pub display: &'static str,    // human label, e.g. "Zig"
    pub arch: Option<&'static str>,
    pub apt: Option<&'static str>,
    pub dnf: Option<&'static str>,
    pub zypper: Option<&'static str>,
    pub brew: Option<&'static str>,
    pub winget: Option<&'static str>,
    pub choco: Option<&'static str>,
}

/// Which package manager to use, detected once by the caller and passed down.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PkgManager {
    Pacman,
    Apt,
    Dnf,
    Zypper,
    Brew,
    Winget,
    Choco,
}

impl PkgManager {
    /// Detect the right manager for the current platform. Linux distro detection
    /// reads /etc/os-release; Windows prefers winget over choco; macOS uses brew.
    pub fn detect() -> Result<Self, String> {
        if cfg!(target_os = "macos") {
            if command_exists("brew") {
                return Ok(PkgManager::Brew);
            }
            return Err("homebrew not found. Install it first: https://brew.sh".to_string());
        }

        if cfg!(target_os = "windows") {
            if command_exists("winget") {
                return Ok(PkgManager::Winget);
            }
            if command_exists("choco") {
                return Ok(PkgManager::Choco);
            }
            return Err("neither winget nor choco found. Install one first.".to_string());
        }

        // Linux: read /etc/os-release for the distro ID.
        let os_release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
        let id = os_release
            .lines()
            .find_map(|l| l.strip_prefix("ID="))
            .map(|v| v.trim_matches('"').to_lowercase())
            .unwrap_or_default();

        match id.as_str() {
            "arch" => Ok(PkgManager::Pacman),
            "ubuntu" | "debian" | "pop" | "mint" => Ok(PkgManager::Apt),
            "fedora" | "rhel" | "centos" => Ok(PkgManager::Dnf),
            _ if id.starts_with("opensuse") || id == "suse" => Ok(PkgManager::Zypper),
            _ => Err(format!(
                "unsupported or undetected Linux distribution (ID='{}'). Install manually.",
                id
            )),
        }
    }

    /// Pick the package name this spec offers for this manager, if any.
    fn package_name<'a>(&self, spec: &DepSpec) -> Option<&'static str> {
        match self {
            PkgManager::Pacman => spec.arch,
            PkgManager::Apt => spec.apt,
            PkgManager::Dnf => spec.dnf,
            PkgManager::Zypper => spec.zypper,
            PkgManager::Brew => spec.brew,
            PkgManager::Winget => spec.winget,
            PkgManager::Choco => spec.choco,
        }
    }

    /// Run the install command for one package name. Returns Ok even if the
    /// manager itself reports "nothing to do" — only a hard spawn failure errors.
    fn install(&self, pkg: &str) -> Result<(), String> {
        let status = match self {
            PkgManager::Pacman => Command::new("sudo")
                .args(["pacman", "-S", "--needed", "--noconfirm", pkg])
                .status(),
            PkgManager::Apt => Command::new("sudo")
                .args(["apt-get", "install", "-y", pkg])
                .status(),
            PkgManager::Dnf => Command::new("sudo")
                .args(["dnf", "install", "-y", pkg])
                .status(),
            PkgManager::Zypper => Command::new("sudo")
                .args(["zypper", "install", "-y", pkg])
                .status(),
            PkgManager::Brew => Command::new("brew").args(["install", pkg]).status(),
            PkgManager::Winget => Command::new("winget")
                .args(["install", "--id", pkg, "-e", "--source", "winget"])
                .status(),
            PkgManager::Choco => Command::new("choco").args(["install", pkg, "-y"]).status(),
        };

        match status {
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("package manager exited with status {}", s)),
            Err(e) => Err(format!("failed to run package manager: {}", e)),
        }
    }
}

fn command_exists(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

/// Install one language's dependency via the detected package manager.
/// Skips (with a message) if this spec has no package name for the detected manager.
pub fn install_dep(mgr: PkgManager, spec: &DepSpec) -> Result<(), String> {
    match mgr.package_name(spec) {
        Some(pkg) => {
            eprintln!("crun: installing {} ({})...", spec.display, pkg);
            mgr.install(pkg)
        }
        None => {
            eprintln!(
                "crun: no package mapping for {} on this platform — install it manually",
                spec.display
            );
            Ok(())
        }
    }
}

// Module declarations and `all_languages()` / `all_dep_specs()` / `all_test_runners()`
// (use the types above) — generated at build time by build.rs from the directories
// present in src/languages/.
include!(concat!(env!("OUT_DIR"), "/language_registry.rs"));

/// Find the compiler config for a given source file by its extension.
/// Returns None if the extension is not recognized.
pub fn find_config(path: &Path) -> Option<CompilerConfig> {
    let ext = path.extension()?.to_str()?.to_lowercase();
    all_languages().into_iter().find(|lang| {
        lang.extensions.iter().any(|e| *e == ext.as_str())
    })
}

/// Shared implementation for each language's `run_test()`.
///
/// `source` is the test program's source code, embedded at compile time via
/// `include_str!` from right next to the language module (e.g.
/// `include_str!("hello.zig")`) — no runtime file lookup, no separate tests/
/// tree to ship alongside the binary. We write it to a fresh tmp file, run it
/// through the real detect -> compile -> run pipeline, and report pass/fail.
/// Used by every languages/<lang>/test.rs.
pub fn run_bundled_test(source: &str, ext: &str) -> Result<(), String> {
    let work_dir = crate::cleanup::make_tmp_path(None)
        .map_err(|e| format!("could not create tmp dir: {}", e))?;
    std::fs::create_dir_all(&work_dir)
        .map_err(|e| format!("could not create tmp dir {}: {}", work_dir.display(), e))?;

    let source_path = work_dir.join(format!("hello.{}", ext));
    std::fs::write(&source_path, source)
        .map_err(|e| format!("could not write test source to {}: {}", source_path.display(), e))?;

    let out_path = crate::cleanup::make_tmp_path(None)
        .map_err(|e| format!("could not create tmp dir: {}", e))?;

    let result = (|| -> Result<i32, String> {
        let detect_result = crate::detect::detect(&source_path)?;
        let compile_output = crate::compile::compile(&detect_result, &out_path, false)?;
        Ok(crate::run::run_capturing_exit(&compile_output))
    })();

    let _ = std::fs::remove_dir_all(&out_path);
    let _ = std::fs::remove_dir_all(&work_dir);

    match result {
        Ok(0) => Ok(()),
        Ok(code) => Err(format!("test exited with code {}", code)),
        Err(e) => Err(e),
    }
}
