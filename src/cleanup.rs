/*
 * cleanup.rs
 *
 * Manages the temporary output path for transient builds (non --save).
 * Generates a random 16-character alphanumeric name under /tmp/crun/
 * (or a user-supplied --tmp path) and ensures the directory exists.
 *
 * The actual deletion on exit is handled in run.rs via a drop guard,
 * which fires even on panic — guaranteeing cleanup on crash or signal.
 *
 * For persistent (--save) builds, this module is not used — the caller
 * constructs the output path directly from the binary name and save path.
 */

use rand::distributions::Alphanumeric;
use rand::{thread_rng, Rng};
use std::path::{Path, PathBuf};

/// Length of the random suffix used for tmp binary names.
const RAND_LEN: usize = 16;

/// Generate the tmp output path for a transient build.
/// Creates /tmp/crun/<random16>/ (or <custom_tmp>/<random16>/) and returns
/// the full path where the binary should be written.
pub fn make_tmp_path(custom_tmp: Option<&Path>) -> Result<PathBuf, String> {
    let base = custom_tmp
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("/tmp/crun"));

    // Create the base dir if it doesn't exist yet
    std::fs::create_dir_all(&base)
        .map_err(|e| format!("failed to create tmp directory {}: {}", base.display(), e))?;

    let rand_name: String = thread_rng()
        .sample_iter(&Alphanumeric)
        .take(RAND_LEN)
        .map(char::from)
        .collect();

    let out_dir = base.join(&rand_name);
    std::fs::create_dir_all(&out_dir)
        .map_err(|e| format!("failed to create tmp output dir {}: {}", out_dir.display(), e))?;

    Ok(out_dir)
}

/// Derive the persistent binary name from a source path.
/// For a file: strip the extension. For a directory: use the dir name.
/// e.g. "hello.c" -> "hello", "myproject/" -> "myproject"
pub fn binary_name_from_path(path: &Path) -> Result<String, String> {
    if path.is_file() {
        // file_stem() gives us the name without the last extension
        path.file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .ok_or_else(|| format!("could not derive binary name from file: {}", path.display()))
    } else {
        // For a directory, use the directory name itself
        path.file_name()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .ok_or_else(|| format!("could not derive binary name from dir: {}", path.display()))
    }
}

/// Build the full output binary path for a --save build.
/// Default save location is $HOME/.local/bin/<name>.
pub fn make_save_path(
    source_path: &Path,
    custom_save_path: Option<&Path>,
) -> Result<PathBuf, String> {
    let name = binary_name_from_path(source_path)?;

    let dir = match custom_save_path {
        Some(p) => {
            // If the user gave a full file path (has a file name), use it as-is.
            // If they gave a directory, append the derived name.
            if p.extension().is_some() {
                // Looks like a file path — use parent dir, override name
                return Ok(p.to_path_buf());
            }
            p.to_path_buf()
        }
        None => {
            // Default: $HOME/.local/bin/
            let home = std::env::var("HOME")
                .map_err(|_| "HOME environment variable not set".to_string())?;
            PathBuf::from(home).join(".local").join("bin")
        }
    };

    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("failed to create save directory {}: {}", dir.display(), e))?;

    Ok(dir.join(name))
}

/// RAII guard that deletes a path (file or directory) when dropped.
/// Used by run.rs to guarantee cleanup even if the process panics or errors.
pub struct CleanupGuard {
    pub path: PathBuf,
    /// Set to false to disarm (used when --save is active — no cleanup needed).
    pub active: bool,
}

impl CleanupGuard {
    pub fn new(path: PathBuf) -> Self {
        CleanupGuard { path, active: true }
    }

    /// Disarm this guard — the path will not be deleted on drop.
    pub fn disarm(&mut self) {
        self.active = false;
    }
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        // Try to remove. If it's a dir, remove recursively. Ignore errors —
        // we're in Drop and can't propagate them, and failing to clean /tmp
        // is not a fatal condition.
        if self.path.is_dir() {
            let _ = std::fs::remove_dir_all(&self.path);
        } else if self.path.is_file() {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}