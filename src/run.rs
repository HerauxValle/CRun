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
use crate::language::ExecutionMode;

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

    // Drop the guard BEFORE exiting — this is what actually fires cleanup.
    // (process::exit would otherwise terminate before any later code ran,
    // which is exactly why run_native/run_with_runtime return a code instead
    // of calling process::exit themselves.)
    drop(guard);

    let code = exit_code?;
    std::process::exit(code);
}

/// Execute a native binary directly. Returns its exit code (does not exit the process —
/// see `run()`, which must drop the cleanup guard first).
fn run_native(binary_path: &Path) -> Result<i32, String> {
    // Make sure the binary is executable. Compilers usually set this, but
    // if something went wrong in the copy/move, we'd get a confusing EACCES.
    set_executable(binary_path)?;

    let status = Command::new(binary_path)
        .status()
        .map_err(|e| format!("failed to execute {}: {}", binary_path.display(), e))?;

    Ok(status.code().unwrap_or(1))
}

/// Execute output via a runtime (e.g. `dotnet run hello.cs`). Returns its exit code
/// (does not exit the process — see `run()`, which must drop the cleanup guard first).
fn run_with_runtime(runtime: &str, project_path: &Path) -> Result<i32, String> {
    let mut cmd = Command::new(runtime);
    if runtime == "dotnet" {
        cmd.arg("run").arg(project_path);
    } else {
        cmd.arg(project_path);
    }

    let status = cmd
        .status()
        .map_err(|e| format!("failed to execute runtime {}: {}", runtime, e))?;

    Ok(status.code().unwrap_or(1))
}

/// Execute a compiled binary and return its exit code without calling process::exit.
/// Used by the test runner (run_all_tests / run_bundled_test) so execution can
/// continue after each test completes instead of terminating the process.
pub fn run_capturing_exit(output: &CompileOutput) -> i32 {
    let _ = set_executable(&output.binary_path);

    let status = match &output.execution_mode {
        ExecutionMode::Native => Command::new(&output.binary_path).status(),
        ExecutionMode::Runtime(runtime) => {
            let mut cmd = Command::new(runtime);
            if runtime == "dotnet" {
                cmd.arg("run").arg(&output.binary_path);
            } else {
                cmd.arg(&output.binary_path);
            }
            cmd.status()
        }
    };

    status.map(|s| s.code().unwrap_or(1)).unwrap_or(1)
}

/// Ensure a file has the executable bit set (owner+group+other).
/// No-op on Windows — there's no exec-bit concept; PE binaries are runnable
/// by extension alone.
#[cfg(unix)]
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

#[cfg(windows)]
fn set_executable(_path: &Path) -> Result<(), String> {
    Ok(())
}