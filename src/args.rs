/*
 * args.rs
 *
 * Defines the CLI interface for crun using clap's derive macro.
 * All flags, their short forms, defaults, and help strings live here.
 * Keeping this isolated means adding a new flag never touches business logic.
 *
 * Flag summary:
 *   <path>              positional, optional — file or directory to compile (default: cwd)
 *   -s / --save         persist the binary instead of deleting it after exit
 *   -p / --path         target path for --save output (implies --save)
 *   -T / --tmp          override the tmp directory used when not saving (-T for tmpfs)
 *        --no-werror    drop -Werror so warnings don't abort compilation
 *   -t / --test-compile run bundled test(s); no value or "all" runs all languages in order
 *        --deps         install per-language toolchain deps; no value or "all" installs all
 */

use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "crun",
    version,
    about = "Compile and run C-family source files like scripts.",
    long_about = None,
)]
pub struct Args {
    /// File or directory to compile. Defaults to current working directory.
    /// Mutually exclusive with --test-compile.
    pub path: Option<PathBuf>,

    /// Save the compiled binary persistently instead of deleting it on exit.
    /// Binary is placed in $HOME/.local/bin/<name> unless --path overrides.
    #[arg(short = 's', long = "save")]
    pub save: bool,

    /// Destination path for the saved binary (implies --save).
    /// The binary name is derived from the source file/dir name.
    #[arg(short = 'p', long = "path", value_name = "TARGET_PATH")]
    pub save_path: Option<PathBuf>,

    /// Override the tmp directory for transient builds.
    /// Default is /tmp/crun/<random16>. Has no effect when --save is active.
    /// -T is mnemonic for tmpfs (common on Arch: /run/user/$UID or /tmp on tmpfs).
    #[arg(short = 'T', long = "tmp", value_name = "TMP_PATH")]
    pub tmp_path: Option<PathBuf>,

    /// Disable -Werror. Warnings will print but won't abort compilation.
    /// Useful when running third-party code you don't control.
    #[arg(long = "no-werror")]
    pub no_werror: bool,

    /// Compile and run bundled test file(s) for one or all languages (always transient).
    /// Pass a language extension to test one: -t cpp
    /// No value or "all" runs all in order: -t / -t all
    /// Valid: c, cpp, cs, go, zig, rs, swift, m  (aliases: c++, csharp, c#, rust, objc)
    #[arg(
        short = 't',
        long = "test-compile",
        value_name = "LANG",
        num_args = 0..=1,           // 0 = flag with no value (-t alone), 1 = -t cpp
        default_missing_value = "all", // -t with no value == -t all
        conflicts_with = "path",
    )]
    pub test_compile: Option<String>,

    /// Install per-language toolchain dependencies for the current platform.
    /// No value or "all" installs every supported language's toolchain.
    /// Pass a language name/extension to install just one: --deps zig
    #[arg(
        long = "deps",
        value_name = "LANG",
        num_args = 0..=1,
        default_missing_value = "all",
        conflicts_with = "path",
        conflicts_with = "test_compile",
    )]
    pub deps: Option<String>,
}

impl Args {
    /// Normalize: --path implies --save so callers don't have to check both.
    pub fn effective_save(&self) -> bool {
        self.save || self.save_path.is_some()
    }
}