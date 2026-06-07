/*
 * compile.rs
 *
 * Invokes the compiler for a given DetectResult and output path.
 * This is the only place that shells out to a compiler — all language-specific
 * knowledge lives in languages/, and compile.rs just reads CompilerConfig.
 *
 * Handles:
 *   - Native multi-file compilation (C, C++, Swift, Go, ObjC)
 *   - Single-entry compilation (Rust without Cargo)
 *   - Build system delegation (Make, CMake, Meson, Cargo, dotnet)
 *   - -Wall / -Werror injection (skipped for Go and C# which handle it differently)
 *   - Compiler existence check via `which` before attempting compilation
 *   - Stderr passthrough — compiler errors are printed directly so the user
 *     sees the full diagnostic output, not a crun wrapper summary.
 */

use std::path::{Path, PathBuf};
use std::process::Command;
use which::which;

use crate::detect::{BuildSystem, DetectResult};
use crate::language::ExecutionMode;

/// The result of a successful compilation, consumed by run.rs.
pub struct CompileOutput {
    /// Path to the compiled binary (or project dir for managed runtimes).
    pub binary_path: PathBuf,
    /// How to execute the output.
    pub execution_mode: ExecutionMode,
}

/// Compile the detected sources to the given output path.
/// Returns the path to the compiled binary on success.
pub fn compile(
    detect: &DetectResult,
    out_path: &Path,
    no_werror: bool,
) -> Result<CompileOutput, String> {
    match detect {
        DetectResult::BuildSystem(project_dir, build_system) => {
            compile_build_system(project_dir, build_system, out_path)
        }
        DetectResult::Sources { files, config, entry } => {
            // Verify the compiler is installed before we try to run it.
            // `which` checks PATH — this catches "you need to install gcc" early.
            which(config.compiler).map_err(|_| {
                format!(
                    "compiler '{}' not found in PATH. Is {} installed?",
                    config.compiler, config.name
                )
            })?;

            compile_sources(files, entry.as_deref(), config, out_path, no_werror)
        }
    }
}

/// Invoke a detected build system. The binary output location varies by system.
fn compile_build_system(
    project_dir: &Path,
    build_system: &BuildSystem,
    out_path: &Path,
) -> Result<CompileOutput, String> {
    match build_system {
        BuildSystem::Make => {
            // Make doesn't have a standard output flag — we just run `make`
            // and trust the Makefile to produce a binary. We can't easily
            // redirect where Make puts its output without parsing the Makefile.
            // Best effort: run make, then look for a binary named after the dir.
            run_command(
                Command::new("make").current_dir(project_dir),
                "make",
            )?;
            // Try to find the binary the Makefile produced
            let dir_name = project_dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("a.out");
            let guessed = project_dir.join(dir_name);
            if guessed.exists() {
                Ok(CompileOutput {
                    binary_path: guessed,
                    execution_mode: crate::language::ExecutionMode::Native,
                })
            } else {
                // Can't determine output — tell the user to use the Makefile directly
                Err("Make build succeeded but couldn't determine output binary location. \
                     Run `make` directly and execute the binary yourself.".to_string())
            }
        }

        BuildSystem::CMake => {
            // CMake two-step: configure then build.
            // We configure into a `build/` subdir inside out_path.
            let build_dir = out_path.join("cmake_build");
            std::fs::create_dir_all(&build_dir).map_err(|e| e.to_string())?;

            run_command(
                Command::new("cmake")
                    .arg(project_dir)
                    .arg(format!("-DCMAKE_RUNTIME_OUTPUT_DIRECTORY={}", out_path.display()))
                    .current_dir(&build_dir),
                "cmake (configure)",
            )?;
            run_command(
                Command::new("cmake")
                    .args(["--build", "."])
                    .current_dir(&build_dir),
                "cmake (build)",
            )?;

            find_binary_in(out_path)
        }

        BuildSystem::Meson => {
            let build_dir = out_path.join("meson_build");
            run_command(
                Command::new("meson")
                    .arg("setup")
                    .arg(&build_dir)
                    .current_dir(project_dir),
                "meson setup",
            )?;
            run_command(
                Command::new("meson")
                    .args(["compile", "-C"])
                    .arg(&build_dir),
                "meson compile",
            )?;
            find_binary_in(&build_dir)
        }

        BuildSystem::Cargo => {
            // `cargo build` into our tmp dir via CARGO_TARGET_DIR env var.
            run_command(
                Command::new("cargo")
                    .args(["build", "--release"])
                    .env("CARGO_TARGET_DIR", out_path)
                    .current_dir(project_dir),
                "cargo build",
            )?;
            // Cargo puts the binary at target/release/<package_name>
            find_binary_in(&out_path.join("release"))
        }

        BuildSystem::DotNet => {
                    run_command(
                        Command::new("dotnet")
                            .args(["build", "--nologo", "--configuration", "Release"])
                            .current_dir(project_dir),
                        "dotnet build",
                    )?;

                    // Recursively find the built .dll file inside the project directory or system fallback paths
                    if let Some(dll_path) = find_dll_in(project_dir) {
                        Ok(CompileOutput {
                            binary_path: dll_path,
                            execution_mode: ExecutionMode::Runtime("dotnet".to_string()),
                        })
                    } else {
                        // Fallback to checking user runtime profile cache if .NET 10 uses a centralized runfile cache
                        let user_home = std::env::var("HOME").unwrap_or_default();
                        let runfile_dir = Path::new(&user_home).join(".local/share/dotnet/runfile");
                        if let Some(dll_path) = find_dll_in(&runfile_dir) {
                            Ok(CompileOutput {
                                binary_path: dll_path,
                                execution_mode: ExecutionMode::Runtime("dotnet".to_string()),
                            })
                        } else {
                            Err("dotnet build succeeded but could not locate the compiled .dll assembly output.".to_string())
                        }
                    }
                }
    }
}

/// Compile a flat list of source files directly with the compiler.
fn compile_sources(
    files: &[PathBuf],
    entry: Option<&Path>,
    config: &crate::language::CompilerConfig,
    out_path: &Path,
    no_werror: bool,
) -> Result<CompileOutput, String> {
    // For --save builds, out_path is already the full binary path (e.g. ~/.local/bin/hello).
    // For tmp builds, out_path is a directory and we append a filename.
    let binary_path = if out_path.is_dir() {
        out_path.join("output")
    } else {
        out_path.to_path_buf()
    };

    let mut cmd = Command::new(config.compiler);

    // Language-specific base flags (e.g. -std=c++17, --edition 2021)
    cmd.args(config.base_flags);

    // Go uses a different flag structure: `go build -o <out> <sources>`
    // The "build" subcommand is already in base_flags.
    // -Wall/-Werror don't apply to Go (compiler enforces its own strictness).
    // C# via dotnet also handled separately above.
    let is_go = config.name == "Go";
    let is_csharp = config.name == "C#";
    // Zig's compiler is already strict (unused vars/imports are compile errors),
    // and `zig build-exe` doesn't accept -Wall/-Werror — same story as Go.
    let is_zig = config.name == "Zig";
    // Rust has its own lint system — -Wall/-Werror are not valid rustc flags.
    // Rustc's equivalent is #![deny(warnings)] in the crate root, or -D warnings.
    let is_rust = config.name == "Rust";
    // Swift uses -warnings-as-errors instead of -Werror, and -warn-long-... instead of -Wall.
    // We handle Swift warnings separately below.
    let is_swift = config.name == "Swift";

    if !is_go && !is_csharp && !is_rust && !is_swift && !is_zig {
        cmd.arg("-Wall");
        if !no_werror {
            cmd.arg("-Werror");
        }
    }

    // Rust equivalent of -Werror: -D warnings promotes all warnings to errors.
    if is_rust && !no_werror {
        cmd.args(["-D", "warnings"]);
    }

    // Swift uses -warnings-as-errors (swiftc is clang-based but doesn't accept -Werror).
    // No -Wall equivalent in swiftc; it enables most warnings by default anyway.
    if is_swift && !no_werror {
        cmd.arg("-warnings-as-errors");
    }

    // Output flag — most languages use -o; zig build-exe wants -femit-bin=<path>; C# has none.
    if is_zig {
        let mut emit = std::ffi::OsString::from("-femit-bin=");
        emit.push(binary_path.as_os_str());
        cmd.arg(emit);
    } else if !is_csharp {
        cmd.arg("-o").arg(&binary_path);
    }

    // Source file argument(s):
    if let Some(entry_file) = entry {
        // Single-entry languages (Rust without Cargo): only pass the entry point.
        cmd.arg(entry_file);
    } else if is_go {
        // Go special case: `go build` treats a directory as a package and will
        // choke on any non-.go files present (e.g. hello.c in the same tests/ dir).
        // When given a single file, pass it directly. When given a pure Go directory
        // (already validated as single-language by detect.rs), pass the directory.
        if files.len() == 1 {
            cmd.arg(&files[0]);
        } else if let Some(dir) = files[0].parent() {
            cmd.arg(dir);
        }
    } else {
        cmd.args(files);
    }

    run_command(&mut cmd, config.compiler)?;

    if is_csharp {
        // `dotnet build` of a loose .cs file lays out a self-contained app whose
        // .dll can't be executed directly (missing runtimeconfig next to it in our
        // requested location). `dotnet run <file.cs>` builds and runs it correctly,
        // so point execution at the source file itself.
        let source_path = entry.map(|p| p.to_path_buf()).unwrap_or_else(|| files[0].clone());
        return Ok(CompileOutput {
            binary_path: source_path,
            execution_mode: config.execution_mode.clone(),
        });
    }

    Ok(CompileOutput {
        binary_path,
        execution_mode: config.execution_mode.clone(),
    })
}

/// Run a command, streaming stderr directly to the terminal.
/// Returns Ok(()) if the process exits 0, Err with a message otherwise.
fn run_command(cmd: &mut Command, label: &str) -> Result<(), String> {
    // inherit stdout/stderr so compiler diagnostics print directly to the user's
    // terminal — we don't buffer them. This means -Wall output appears as the
    // compiler would normally print it, with colors intact if the compiler supports it.
    let status = cmd
        .status()
        .map_err(|e| format!("failed to launch {}: {}", label, e))?;

    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "{} exited with status {}",
            label,
            status.code().unwrap_or(-1)
        ))
    }
}

/// Scan a directory for the first executable file — used after CMake/Meson/Make
/// builds where we can't know the binary name ahead of time.
fn find_binary_in(dir: &Path) -> Result<CompileOutput, String> {
    let entries = std::fs::read_dir(dir)
        .map_err(|e| format!("could not read output dir {}: {}", dir.display(), e))?;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() && is_executable(&path) {
            return Ok(CompileOutput {
                binary_path: path,
                execution_mode: ExecutionMode::Native,
            });
        }
    }

    Err(format!(
        "build succeeded but no executable found in {}",
        dir.display()
    ))
}

/// Whether a file looks like a native executable — checked via the Unix
/// execute permission bits on Unix, or the `.exe` extension on Windows
/// (Windows has no exec-bit concept; PE binaries are identified by extension).
#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .map(|meta| meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(windows)]
fn is_executable(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
}

/// Helper to recursively search a directory tree for a compiled .dll file
fn find_dll_in(dir: &Path) -> Option<PathBuf> {
    if !dir.is_dir() {
        return None;
    }
    if let Ok(entries) = std::fs::read_dir(dir) {
        let mut subdirs = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Some(ext) = path.extension() {
                    if ext == "dll" && !path.to_string_lossy().contains("Microsoft.") {
                        return Some(path);
                    }
                }
            } else if path.is_dir() {
                subdirs.push(path);
            }
        }
        for subdir in subdirs {
            if let Some(path) = find_dll_in(&subdir) {
                return Some(path);
            }
        }
    }
    None
}