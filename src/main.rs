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
mod language;
mod run;
mod testrun;

use std::path::PathBuf;
use std::process;

use clap::{CommandFactory, Parser};

use args::Args;

fn main() {
    // No flags/args at all -> show usage instead of silently running on cwd.
    if std::env::args().count() == 1 {
        Args::command().print_help().ok();
        println!();
        process::exit(0);
    }

    let args = Args::parse();

    if let Err(e) = run_pipeline(args) {
        eprintln!("crun: {}", e);
        process::exit(1);
    }
}

fn run_pipeline(args: Args) -> Result<(), String> {
    if let Some(ref target) = args.deps {
        return run_deps(target);
    }

    if let Some(ref lang) = args.test_compile {
        if testrun::is_run_all(lang) {
            return testrun::run_all();
        } else {
            return testrun::run_one(lang);
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

/// Install toolchain dependencies. `target` is "all" (or empty) for every
/// language, or a specific language token (extension/alias) to install just one.
/// Delegates the actual package-manager invocation to language::install_dep,
/// using the DepSpec each languages/<lang>/deps.rs declares.
fn run_deps(target: &str) -> Result<(), String> {
    let mgr = language::PkgManager::detect()?;
    eprintln!("crun: installing dependencies via {:?}...", mgr);

    let specs = language::all_dep_specs();

    if target.is_empty() || target.eq_ignore_ascii_case("all") {
        let mut failed = Vec::new();
        for spec in &specs {
            if let Err(e) = language::install_dep(mgr, spec) {
                eprintln!("crun: failed to install {} — {}", spec.display, e);
                failed.push(spec.display);
            }
        }
        return if failed.is_empty() {
            Ok(())
        } else {
            Err(format!("failed to install: {}", failed.join(", ")))
        };
    }

    // Specific language: match by display name (case-insensitive substring)
    // since DepSpec doesn't carry the registry key — display names are
    // distinctive enough ("Zig", "C++ (g++)", ...) for this to be unambiguous.
    let needle = target.to_lowercase();
    let spec = specs
        .iter()
        .find(|s| s.display.to_lowercase().contains(&needle))
        .ok_or_else(|| format!("unknown language '{}' for --deps", target))?;

    language::install_dep(mgr, spec)
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