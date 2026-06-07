/*
 * main.rs
 *
 * Entry point for crun. Thin dispatcher — parses args, resolves paths,
 * calls detect -> compile -> run in sequence, and prints human-readable
 * errors to stderr before exiting with a nonzero code on failure.
 *
 * Intentionally minimal: no business logic lives here. Each stage is
 * delegated to its own module so failures are traceable to one file.
 *
 * Exit codes:
 *   0   — compiled and ran successfully (mirrors child exit 0)
 *   1   — crun-level error (bad path, compile failure, etc.)
 *   N   — mirrors the child program's exit code (handled in run.rs)
 */

mod args;
mod cleanup;
mod compile;
mod detect;
mod languages;
mod run;
mod testrun;

use std::path::PathBuf;
use std::process;

use clap::Parser;

use args::Args;

fn main() {
    let args = Args::parse();

    if let Err(e) = run_pipeline(args) {
        eprintln!("crun: {}", e);
        process::exit(1);
    }
}

fn run_pipeline(args: Args) -> Result<(), String> {
    if let Some(ref lang) = args.test_compile {
        if testrun::is_run_all(lang) {
            // -t / -t all: run every language test in order, stop on first failure.
            return run_all_tests(&args);
        } else {
            // -t cpp / -t rs / etc: run a single language test.
            let test_path = testrun::resolve_test_path(lang)?;
            eprintln!("crun: test [{}] -> {}", lang, test_path.display());
            return run_single(test_path, &args);
        }
    }

    // Normal path: use provided path or cwd.
    let target = match args.path {
        Some(ref p) => p.clone(),
        None => std::env::current_dir()
            .map_err(|e| format!("could not determine current directory: {}", e))?,
    };
    let target = target.canonicalize().unwrap_or(target);
    run_single(target, &args)
}

/// Compile and run a single target path.
fn run_single(target: PathBuf, args: &Args) -> Result<(), String> {
    let target = target.canonicalize().unwrap_or(target.clone());

    let detect_result = detect::detect(&target)?;

    let (out_path, is_persistent) = resolve_output_path(args, &target)?;

    let compile_output = compile::compile(&detect_result, &out_path, args.no_werror)?;

    let cleanup_path: Option<&std::path::Path> = if is_persistent {
        None
    } else {
        Some(&out_path)
    };

    run::run(&compile_output, cleanup_path)
}

/// Run all bundled language tests in LANG_ORDER. Stops and reports on first failure.
fn run_all_tests(args: &Args) -> Result<(), String> {
    eprintln!("crun: running all language tests...\n");

    let mut passed = 0;
    let mut failed: Vec<&str> = Vec::new();

    for lang in testrun::LANG_ORDER {
        let test_path = match testrun::resolve_test_path(lang) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("  [{}] SKIP — {}", lang, e);
                continue;
            }
        };

        eprintln!("  [{}] compiling {}...", lang, test_path.display());

        // Each test gets its own fresh tmp dir so they don't stomp each other.
        let out_path = cleanup::make_tmp_path(args.tmp_path.as_deref())
            .map_err(|e| format!("could not create tmp dir: {}", e))?;

        let detect_result = match detect::detect(&test_path) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("  [{}] FAIL (detect) — {}\n", lang, e);
                failed.push(lang);
                continue;
            }
        };

        let compile_output = match compile::compile(&detect_result, &out_path, args.no_werror) {
            Ok(o) => o,
            Err(e) => {
                eprintln!("  [{}] FAIL (compile) — {}\n", lang, e);
                // Clean up the tmp dir even on compile failure
                let _ = std::fs::remove_dir_all(&out_path);
                failed.push(lang);
                continue;
            }
        };

        // run::run calls std::process::exit internally after the child exits,
        // which would kill the whole test run. For run-all we need to exec
        // and capture the exit code manually instead.
        let exit_code = run_capturing_exit(&compile_output, &out_path);
        let _ = std::fs::remove_dir_all(&out_path);

        if exit_code == 0 {
            eprintln!("  [{}] PASS\n", lang);
            passed += 1;
        } else {
            eprintln!("  [{}] FAIL (exit {})\n", lang, exit_code);
            failed.push(lang);
        }
    }

    eprintln!("crun: tests done — {}/{} passed", passed, passed + failed.len());

    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("failed: {}", failed.join(", ")))
    }
}

/// Execute a compiled binary and return its exit code without calling process::exit.
/// Used by run_all_tests so we can continue running after each test completes.
fn run_capturing_exit(output: &compile::CompileOutput, _out_path: &PathBuf) -> i32 {
    use std::process::Command;
    use crate::languages::ExecutionMode;

    // Ensure executable bit is set
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = output.binary_path.metadata() {
            let mut perms = meta.permissions();
            perms.set_mode(perms.mode() | 0o111);
            let _ = std::fs::set_permissions(&output.binary_path, perms);
        }
    }

    let status = match &output.execution_mode {
        ExecutionMode::Native => {
            Command::new(&output.binary_path).status()
        }
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

/// Determine where the compiled binary should be placed.
fn resolve_output_path(args: &Args, source_path: &PathBuf) -> Result<(PathBuf, bool), String> {
    if args.effective_save() {
        let out = cleanup::make_save_path(source_path, args.save_path.as_deref())?;
        eprintln!("crun: saving binary to {}", out.display());
        Ok((out, true))
    } else {
        let out = cleanup::make_tmp_path(args.tmp_path.as_deref())?;
        Ok((out, false))
    }
}