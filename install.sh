#!/usr/bin/env bash
# install.sh
#
# Builds crun in release mode (in a tmp dir, never touching the repo's
# target/) and copies the binary to $HOME/.local/bin so it's on PATH
# without needing sudo.
#
# Usage:
#   ./install.sh               — interactive: asks what you want (deps,
#                                custom name, ...) and does it
#   ./install.sh --name NAME   — install the binary under a custom name,
#                                e.g. --name runfile -> $HOME/.local/bin/runfile
#                                (combine with --uninstall/--deps as needed)
#   ./install.sh --uninstall   — removes the installed binary (respects --name)
#   ./install.sh --deps        — builds crun, then runs `crun --deps` to install
#                                every supported language's toolchain
#   ./install.sh --deps zig    — same, but only the named language (`crun --deps zig`)
#                                Toolchain package names live in crun itself
#                                (languages/<lang>/deps.rs) — this script just
#                                builds crun and hands off to it.

set -euo pipefail

REPO_URL="https://github.com/HerauxValle/CRun.git"
BIN_DIR="$HOME/.local/bin"

info()  { echo "[crun install] $*"; }
error() { echo "[crun install] error: $*" >&2; exit 1; }

# --- self-purge: keep the jsDelivr-cached copies of these scripts fresh ---
# jsDelivr caches @main for up to 24h. Without this, users who curl the CDN
# URL can be stuck running a stale install.sh/install.ps1 (as just happened —
# old script lacked the overwrite prompt). Fire-and-forget, never blocks
# install on purge-network hiccups.
{
    curl -fsS "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.sh"  >/dev/null 2>&1 || true
    curl -fsS "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/install.ps1" >/dev/null 2>&1 || true
} &
disown 2>/dev/null || true

# --- ask: prompt the user even when piped via `curl ... | bash` ---
# In that case stdin is the script source, not a terminal, so reads must go
# through /dev/tty directly. Returns 1 (no prompt asked) if no tty is reachable
# at all, e.g. fully non-interactive CI — callers should treat that as "no".
ask() {
    local __var="$1" __prompt="$2" __ans=""
    if [[ -e /dev/tty ]] && ( exec 3<>/dev/tty ) 2>/dev/null; then
        exec 3<>/dev/tty
        printf '%s' "$__prompt" >&3
        read -r __ans <&3
        exec 3<&-
    elif [[ -t 0 ]]; then
        read -r -p "$__prompt" __ans
    else
        return 1
    fi
    printf -v "$__var" '%s' "$__ans"
    return 0
}

# --- detect curl|bash style invocation (no real script file on disk) ---
# When piped via `curl ... | bash`, BASH_SOURCE[0] is something like "bash" or
# "/dev/stdin" rather than a path to this file inside a checked-out repo.
# Cloning is deferred until we actually need the repo (we always do now, since
# building is the only path — but this still avoids cloning into a weird spot
# when run locally from an existing checkout).
SOURCE_PATH="${BASH_SOURCE[0]:-}"
IS_CURL_PIPE=0
REPO_DIR=""
if [[ -z "$SOURCE_PATH" || ! -f "$SOURCE_PATH" || "$(basename "$SOURCE_PATH")" != "install.sh" ]]; then
    IS_CURL_PIPE=1
else
    REPO_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

# --- parse args ---
# Supports combining flags, e.g.: ./install.sh --name runfile --deps
DO_DEPS=0
DEPS_TARGET=""
DO_UNINSTALL=0
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
        --name)
            i=$((i + 1))
            INSTALL_NAME="${args[$i]:-}"
            [[ -n "$INSTALL_NAME" ]] || { echo "[crun install] error: --name requires a name argument" >&2; exit 1; }
            ;;
        *)
            echo "[crun install] error: unknown argument: ${args[$i]}" >&2
            exit 1
            ;;
    esac
    i=$((i + 1))
done

INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"

# --- interactive prompt (no relevant flags given) ---
# Ask everything up front, in one flow, identical whether curled or local.
if [[ $DO_DEPS -eq 0 && $DO_UNINSTALL -eq 0 ]]; then
    reply=""; ask reply "[crun install] also install per-language toolchain dependencies via crun --deps? [y/N] " || true
    if [[ "${reply:-}" =~ ^[Yy] ]]; then
        DO_DEPS=1
        DEPS_TARGET=""; ask DEPS_TARGET "[crun install] only one language (leave empty for all)? " || true
    fi

    name_reply=""; ask name_reply "[crun install] install under a custom binary name instead of 'crun'? (leave empty to skip) " || true
    if [[ -n "${name_reply:-}" ]]; then
        INSTALL_NAME="$name_reply"
        INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"
    fi
fi

# --- overwrite check — ask BEFORE compiling, not after ---
# An existing file/symlink at the target (e.g. a dangling symlink left over
# from an older symlink-based install) would make cp fail outright — confirm
# before clobbering it (and before wasting a multi-second build on a no-op).
if [[ $DO_UNINSTALL -eq 0 ]] && [[ -e "$INSTALL_TARGET" || -L "$INSTALL_TARGET" ]]; then
    overwrite_reply=""; ask overwrite_reply "[crun install] $INSTALL_TARGET already exists — overwrite? [y/N] " || true
    if [[ ! "${overwrite_reply:-}" =~ ^[Yy] ]]; then
        error "aborted — $INSTALL_TARGET already exists"
    fi
fi

# --- clone if curled (we always need the repo — building is the only path now) ---
if [[ $IS_CURL_PIPE -eq 1 ]]; then
    echo "[crun install] detected curl-piped install (no local script file found)"
    if ! command -v git &>/dev/null; then
        echo "[crun install] error: git not found. Install git and re-run." >&2
        exit 1
    fi
    CLONE_DIR="$PWD/CRun"
    if [[ -d "$CLONE_DIR/.git" ]]; then
        echo "[crun install] using existing clone at $CLONE_DIR"
    else
        echo "[crun install] cloning $REPO_URL to $CLONE_DIR"
        git clone "$REPO_URL" "$CLONE_DIR"
    fi
    REPO_DIR="$CLONE_DIR"
fi

# --- check cargo ---
if ! command -v cargo &>/dev/null; then
    error "cargo not found. Install Rust via https://rustup.rs"
fi

# --- build into a tmp dir — never touches the repo's target/ ---
# crun is a small project; even a clean build from scratch is fast, so there's
# no real cost to always compiling fresh rather than tracking prebuilt binaries.
BUILD_DIR="$(mktemp -d -t crun-build-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

info "building crun (release)..."
CARGO_TARGET_DIR="$BUILD_DIR" cargo build --release --manifest-path "$REPO_DIR/Cargo.toml"

RELEASE_BINARY="$BUILD_DIR/release/crun"
[[ -f "$RELEASE_BINARY" ]] || error "build succeeded but binary not found at $RELEASE_BINARY"

# --- dependency logic ---
# Toolchain installation lives in crun itself (languages/<lang>/deps.rs +
# `crun --deps`), so every language declares its own package names in one
# place. The installer's job is just: build crun, then ask it to install deps.
if [[ $DO_DEPS -eq 1 ]]; then
    if [[ -n "$DEPS_TARGET" ]]; then
        info "delegating to: crun --deps $DEPS_TARGET"
        "$RELEASE_BINARY" --deps "$DEPS_TARGET"
    else
        info "delegating to: crun --deps"
        "$RELEASE_BINARY" --deps
    fi
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

# --- install: always copy (never symlink — the build dir is ephemeral) ---
mkdir -p "$BIN_DIR"
# Already confirmed above (before compiling) if something exists here —
# just clear it so cp doesn't choke on a dangling symlink.
rm -f "$INSTALL_TARGET"
cp "$RELEASE_BINARY" "$INSTALL_TARGET"
chmod +x "$INSTALL_TARGET"
info "copied binary to $INSTALL_TARGET"

# --- offer to clean up the cloned repo (curl-pipe installs only) ---
# Default yes — most people who curl|bash this don't want a CRun/ checkout
# left behind cluttering their cwd; the binary is already installed.
if [[ $IS_CURL_PIPE -eq 1 ]]; then
    cleanup_reply=""; ask cleanup_reply "[crun install] remove the cloned repo at $CLONE_DIR? [Y/n] " || true
    if [[ ! "${cleanup_reply:-}" =~ ^[Nn] ]]; then
        rm -rf "$CLONE_DIR"
        info "removed $CLONE_DIR"
    fi
fi

# --- PATH reminder ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    info "note: $BIN_DIR is not in your PATH."
    info "add this to your config.fish:"
    info "  fish_add_path $BIN_DIR"
fi

info "done. run: $INSTALL_NAME --help"
