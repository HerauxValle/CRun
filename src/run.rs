/*
 * run.rs
 *
 * Executes the compiled binary and manages cleanup after exit.
 * Handles both native binaries and managed runtime execution (C#/dotnet).
 *
 * The CleanupGuard from cleanup.rs is instantiated here so it lives
 * for the duration of run() — it drops (and deletes the tmp dir) after
 * the child process exits, whether cleanly, via panic, or via signal.
 *
 * Exit code passthrough: crun exits with the same code as the compiled
 * program so it behaves transparently in shell pipelines and scripts.
 */

use std::path::Path;
use std::process::Command;

use crate::cleanup::CleanupGuard;
use crate::compile::CompileOutput;
use crate::languages::ExecutionMode;

/// Execute the compiled output.
/// `cleanup_path` is the path that should be deleted after exit (the tmp dir).
/// Pass None for --save builds — nothing to clean up.
pub fn run(output: &CompileOutput, cleanup_path: Option<&Path>) -> Result<(), String> {
    // Arm the cleanup guard. It will fire when this function returns,
    // regardless of how (Ok, Err, or panic).
    // For --save builds, cleanup_path is None so we construct a disarmed guard.
    let guard = match cleanup_path {
        Some(p) => CleanupGuard::new(p.to_path_buf()),
        None => {
            // No cleanup needed — create a guard but immediately disarm it.
            // This keeps the code path uniform without branching everywhere.
            let mut g = CleanupGuard::new(Path::new("/dev/null").to_path_buf());
            g.disarm();
            g
        }
    };

    let exit_code = match &output.execution_mode {
        ExecutionMode::Native => {
            run_native(&output.binary_path)
        }
        ExecutionMode::Runtime(runtime) => {
            run_with_runtime(runtime, &output.binary_path)
        }
    };

    // The guard drops here, cleaning up tmp. We do this before exiting so
    // cleanup happens even if exit_code is an Err.
    drop(guard);

    exit_code
}

/// Execute a native binary directly.
fn run_native(binary_path: &Path) -> Result<(), String> {
    // Make sure the binary is executable. Compilers usually set this, but
    // if something went wrong in the copy/move, we'd get a confusing EACCES.
    set_executable(binary_path)?;

    let status = Command::new(binary_path)
        .status()
        .map_err(|e| format!("failed to execute {}: {}", binary_path.display(), e))?;

    // Propagate the exit code by calling std::process::exit directly.
    // We don't return to main() after this — we mirror the child's exit exactly.
    let code = status.code().unwrap_or(1);
    std::process::exit(code);
}

/// Execute output via a runtime (e.g. `dotnet run hello.cs`).
fn run_with_runtime(runtime: &str, project_path: &Path) -> Result<(), String> {
    let mut cmd = Command::new(runtime);
    if runtime == "dotnet" {
        cmd.arg("run").arg(project_path);
    } else {
        cmd.arg(project_path);
    }

    let status = cmd
        .status()
        .map_err(|e| format!("failed to execute runtime {}: {}", runtime, e))?;

    let code = status.code().unwrap_or(1);
    std::process::exit(code);
}

/// Ensure a file has the executable bit set (owner+group+other).
fn set_executable(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let meta = path
        .metadata()
        .map_err(|e| format!("could not stat {}: {}", path.display(), e))?;
    let mut perms = meta.permissions();
    // Add execute bits for user, group, other — same as chmod +x
    perms.set_mode(perms.mode() | 0o111);
    std::fs::set_permissions(path, perms)
        .map_err(|e| format!("could not chmod +x {}: {}", path.display(), e))?;
    Ok(())
}