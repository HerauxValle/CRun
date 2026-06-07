#!/usr/bin/env bash
# install.sh
#
# Builds crun in release mode and symlinks (or copies) the binary to
# $HOME/.local/bin so it's on PATH without needing sudo.
#
# Usage:
#   ./install.sh               — installs to $HOME/.local/bin/crun
#   ./install.sh --copy        — copies instead of symlinking (useful if $HOME is a
#                                different filesystem than the repo)
#   ./install.sh --bin NAME    — install the binary under a custom name,
#                                e.g. --bin runfile -> $HOME/.local/bin/runfile
#                                (combine with --copy/--uninstall/--deps as needed)
#   ./install.sh --uninstall   — removes the installed binary (respects --bin)
#   ./install.sh --deps        — builds crun, then runs `crun --deps` to install
#                                every supported language's toolchain
#   ./install.sh --deps zig    — same, but only the named language (`crun --deps zig`)
#                                Toolchain package names live in crun itself
#                                (languages/<lang>/deps.rs) — this script just
#                                builds crun and hands off to it.

set -euo pipefail

REPO_URL="https://github.com/HerauxValle/CRun.git"

# --- detect curl|bash style invocation (no real script file on disk) ---
# When piped via `curl ... | bash`, BASH_SOURCE[0] is something like "bash" or
# "/dev/stdin" rather than a path to this file inside a checked-out repo.
SOURCE_PATH="${BASH_SOURCE[0]:-}"
if [[ -z "$SOURCE_PATH" || ! -f "$SOURCE_PATH" || "$(basename "$SOURCE_PATH")" != "install.sh" ]]; then
    echo "[crun install] detected curl-piped install (no local script file found)"
    if ! command -v git &>/dev/null; then
        echo "[crun install] error: git not found. Install git and re-run." >&2
        exit 1
    fi
    CLONE_DIR="$HOME/Projects/CRun"
    if [[ -d "$CLONE_DIR/.git" ]]; then
        echo "[crun install] using existing clone at $CLONE_DIR"
    else
        echo "[crun install] cloning $REPO_URL to $CLONE_DIR"
        mkdir -p "$(dirname "$CLONE_DIR")"
        git clone "$REPO_URL" "$CLONE_DIR"
    fi
    exec bash "$CLONE_DIR/install.sh" "$@"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
RELEASE_BINARY="$REPO_DIR/target/release/crun"

# --- parse args ---
# Supports combining flags, e.g.: ./install.sh --copy --bin runfile
DO_DEPS=0
DEPS_TARGET=""
DO_UNINSTALL=0
DO_COPY=0
INSTALL_NAME="crun"

args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        --deps)
            DO_DEPS=1
            # Optional value: --deps zig (only consume next arg if it isn't another flag)
            next="${args[$((i + 1))]:-}"
            if [[ -n "$next" && "$next" != --* ]]; then
                DEPS_TARGET="$next"
                i=$((i + 1))
            fi
            ;;
        --uninstall)  DO_UNINSTALL=1 ;;
        --copy)       DO_COPY=1 ;;
        --bin)
            i=$((i + 1))
            INSTALL_NAME="${args[$i]:-}"
            [[ -n "$INSTALL_NAME" ]] || { echo "[crun install] error: --bin requires a name argument" >&2; exit 1; }
            ;;
        *)
            echo "[crun install] error: unknown argument: ${args[$i]}" >&2
            exit 1
            ;;
    esac
    i=$((i + 1))
done

INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"

# --- helpers ---
info()  { echo "[crun install] $*"; }
error() { echo "[crun install] error: $*" >&2; exit 1; }

# --- dependency logic ---
# Toolchain installation now lives in crun itself (languages/<lang>/deps.rs +
# `crun --deps`), so every language declares its own package names in one
# place. The installer's job is just: build crun, then ask it to install deps.
install_dependencies() {
    if ! command -v cargo &>/dev/null; then
        error "cargo not found. Install Rust via https://rustup.rs (needed to build crun before it can install other deps)"
    fi
    info "building crun (release) so it can install its own dependencies..."
    cargo build --release --manifest-path "$REPO_DIR/Cargo.toml"
    [[ -f "$RELEASE_BINARY" ]] || error "build succeeded but binary not found at $RELEASE_BINARY"

    if [[ -n "$DEPS_TARGET" ]]; then
        info "delegating to: crun --deps $DEPS_TARGET"
        "$RELEASE_BINARY" --deps "$DEPS_TARGET"
    else
        info "delegating to: crun --deps"
        "$RELEASE_BINARY" --deps
    fi
}


# --- check for --deps flag ---
if [[ $DO_DEPS -eq 1 ]]; then
    install_dependencies
fi

# --- uninstall ---
if [[ $DO_UNINSTALL -eq 1 ]]; then
    if [[ -e "$INSTALL_TARGET" || -L "$INSTALL_TARGET" ]]; then
        rm "$INSTALL_TARGET"
        info "removed $INSTALL_TARGET"
    else
        info "nothing to remove at $INSTALL_TARGET"
    fi
    exit 0
fi

# --- check cargo ---
if ! command -v cargo &>/dev/null; then
    error "cargo not found. Install Rust via https://rustup.rs"
fi

# --- build ---
info "building crun (release)..."
cargo build --release --manifest-path "$REPO_DIR/Cargo.toml"

[[ -f "$RELEASE_BINARY" ]] || error "build succeeded but binary not found at $RELEASE_BINARY"

# --- install ---
mkdir -p "$BIN_DIR"

if [[ $DO_COPY -eq 1 ]]; then
    cp "$RELEASE_BINARY" "$INSTALL_TARGET"
    info "copied binary to $INSTALL_TARGET"
else
    # Symlink: updates automatically when you rebuild without reinstalling.
    ln -sf "$RELEASE_BINARY" "$INSTALL_TARGET"
    info "symlinked $INSTALL_TARGET -> $RELEASE_BINARY"
fi

# --- PATH reminder ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    info "note: $BIN_DIR is not in your PATH."
    info "add this to your config.fish:"
    info "  fish_add_path $BIN_DIR"
fi

info "done. run: $INSTALL_NAME --help"