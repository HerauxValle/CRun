/*
 * detect.rs
 *
 * Figures out what to compile and how, given a path (file or directory).
 * Responsible for:
 *   1. Validating the input path exists and is readable.
 *   2. If a directory: detecting build system (Makefile/CMake/meson) first,
 *      then falling back to source file scanning.
 *   3. If a file: identifying its language by extension.
 *   4. Detecting mixed-language directories and erroring cleanly.
 *   5. Detecting multi-file Rust directories (find main.rs as entry point).
 *
 * Returns a `DetectResult` that compile.rs consumes — fully decoupled.
 */

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use crate::language::{self, CompilerConfig};

/// The result of detection: what to compile, with which config.
#[derive(Debug)]
pub enum DetectResult {
    /// A known build system was found. Contains the project root and the
    /// build system type so compile.rs can invoke it correctly.
    BuildSystem(PathBuf, BuildSystem),

    /// Direct compiler invocation: one or more source files + their config.
    Sources {
        files: Vec<PathBuf>,
        config: CompilerConfig,
        /// For Rust: the entry point (main.rs) when multi-file isn't supported.
        entry: Option<PathBuf>,
    },
}

/// Recognized build systems, in priority order.
#[derive(Debug, Clone, PartialEq)]
pub enum BuildSystem {
    Make,    // Makefile present
    CMake,   // CMakeLists.txt present
    Meson,   // meson.build present
    Cargo,   // Cargo.toml present (Rust)
    DotNet,  // .csproj present
}

impl BuildSystem {
    #[allow(dead_code)] // used in future error messages / verbose output
    pub fn display(&self) -> &'static str {
        match self {
            BuildSystem::Make   => "Makefile",
            BuildSystem::CMake  => "CMakeLists.txt",
            BuildSystem::Meson  => "meson.build",
            BuildSystem::Cargo  => "Cargo.toml",
            BuildSystem::DotNet => ".csproj",
        }
    }
}

/// Entry point for detection. Returns an error string on failure so main.rs
/// can print it cleanly without unwrapping deep in business logic.
pub fn detect(path: &Path) -> Result<DetectResult, String> {
    if !path.exists() {
        return Err(format!("path does not exist: {}", path.display()));
    }

    if path.is_file() {
        detect_file(path)
    } else if path.is_dir() {
        detect_dir(path)
    } else {
        // Could be a symlink to something weird, a device file, etc.
        Err(format!("path is not a file or directory: {}", path.display()))
    }
}

/// Detection for a single source file.
fn detect_file(path: &Path) -> Result<DetectResult, String> {
    let config = language::find_config(path).ok_or_else(|| {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("<no extension>");
        format!(
            "unsupported file extension '.{}' — supported: c, cpp, cc, cxx, cs, m, swift, rs, go",
            ext
        )
    })?;

    Ok(DetectResult::Sources {
        entry: if !config.supports_multi_file { Some(path.to_path_buf()) } else { None },
        files: vec![path.to_path_buf()],
        config,
    })
}

/// Detection for a directory.
fn detect_dir(dir: &Path) -> Result<DetectResult, String> {
    // Step 1: check for a build system file, in priority order.
    // We prefer build systems over raw compilation because they encode
    // project-specific flags, link deps, etc. that we can't infer.
    let build_systems = [
        ("Makefile",       BuildSystem::Make),
        ("CMakeLists.txt", BuildSystem::CMake),
        ("meson.build",    BuildSystem::Meson),
        ("Cargo.toml",     BuildSystem::Cargo),
    ];

    for (filename, kind) in &build_systems {
        if dir.join(filename).exists() {
            return Ok(DetectResult::BuildSystem(dir.to_path_buf(), kind.clone()));
        }
    }

    // Check for a .csproj file (dotnet project) — these have arbitrary names
    if let Some(csproj) = find_file_with_ext(dir, "csproj") {
        return Ok(DetectResult::BuildSystem(csproj.parent().unwrap().to_path_buf(), BuildSystem::DotNet));
    }

    // Step 2: scan source files and group by language.
    let source_files = collect_source_files(dir)?;

    if source_files.is_empty() {
        return Err(format!(
            "no recognized source files found in: {}",
            dir.display()
        ));
    }

    // Group by which language config each file maps to.
    let mut by_language: std::collections::HashMap<&'static str, (CompilerConfig, Vec<PathBuf>)> =
        std::collections::HashMap::new();

    for file in &source_files {
        if let Some(cfg) = language::find_config(file) {
            by_language
                .entry(cfg.name)
                .or_insert_with(|| (cfg, vec![]))
                .1
                .push(file.clone());
        }
    }

    // Step 3: mixed-language check. We don't attempt to guess linking strategy
    // for mixed sources — that's a build system's job.
    if by_language.len() > 1 {
        let found: Vec<&str> = by_language.keys().cloned().collect();
        return Err(format!(
            "mixed source languages found in directory: {}. \
             Use a Makefile or CMakeLists.txt to manage multi-language builds. \
             Found: {}",
            dir.display(),
            found.join(", ")
        ));
    }

    let (config, files) = by_language.into_values().next().unwrap();

    // Step 4: Rust-specific multi-file handling.
    // rustc can't take multiple .rs files like gcc can. Look for main.rs.
    let entry = if !config.supports_multi_file && files.len() > 1 {
        let main = files.iter().find(|f| {
            f.file_name().and_then(|n| n.to_str()) == Some("main.rs")
        });
        match main {
            Some(m) => Some(m.clone()),
            None => {
                return Err(format!(
                    "multiple .rs files found but no main.rs in {}. \
                     For multi-file Rust projects, use a Cargo.toml.",
                    dir.display()
                ))
            }
        }
    } else {
        None
    };

    Ok(DetectResult::Sources { files, config, entry })
}

/// Recursively collect all files whose extension is handled by any language config.
fn collect_source_files(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let known_exts: HashSet<&'static str> = language::all_languages()
        .iter()
        .flat_map(|c| c.extensions.iter().cloned())
        .collect();

    let mut found = Vec::new();
    collect_recursive(dir, &known_exts, &mut found)
        .map_err(|e| format!("error scanning directory {}: {}", dir.display(), e))?;
    Ok(found)
}

fn collect_recursive(
    dir: &Path,
    known_exts: &HashSet<&'static str>,
    out: &mut Vec<PathBuf>,
) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            // Skip hidden dirs and common non-source dirs
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if name.starts_with('.') || name == "target" || name == "build" || name == "node_modules" {
                continue;
            }
            collect_recursive(&path, known_exts, out)?;
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if known_exts.contains(ext.to_lowercase().as_str()) {
                out.push(path);
            }
        }
    }
    Ok(())
}

/// Find first file with a given extension in a directory (non-recursive).
fn find_file_with_ext(dir: &Path, ext: &str) -> Option<PathBuf> {
    std::fs::read_dir(dir).ok()?.flatten().find_map(|e| {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) == Some(ext) {
            Some(p)
        } else {
            None
        }
    })
}