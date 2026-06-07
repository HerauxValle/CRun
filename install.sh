#!/usr/bin/env bash
# install.sh
#
# Builds crun in release mode and symlinks (or copies) the binary to
# $HOME/.local/bin so it's on PATH without needing sudo.
#
# Usage:
#   ./install.sh               — interactive: asks what you want (bin-only, deps,
#                                custom name, ...) and does it
#   ./install.sh --copy        — copies instead of symlinking (useful if $HOME is a
#                                different filesystem than the repo)
#   ./install.sh --name NAME   — install the binary under a custom name,
#                                e.g. --name runfile -> $HOME/.local/bin/runfile
#                                (combine with --copy/--uninstall/--deps as needed)
#   ./install.sh --bin [PATH]  — just grab the portable binary, nothing else: no
#                                symlink, no PATH setup, no deps, no repo clone.
#                                Downloads the tracked bin/crun straight from
#                                GitHub (or copies it if already cloned) to
#                                PATH/crun. PATH defaults to $HOME.
#   ./install.sh --uninstall   — removes the installed binary (respects --name)
#   ./install.sh --deps        — builds crun, then runs `crun --deps` to install
#                                every supported language's toolchain
#   ./install.sh --deps zig    — same, but only the named language (`crun --deps zig`)
#                                Toolchain package names live in crun itself
#                                (languages/<lang>/deps.rs) — this script just
#                                builds crun and hands off to it.

set -euo pipefail

REPO_URL="https://github.com/HerauxValle/CRun.git"
RAW_BIN_URL="https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/bin/crun"
RAW_BUILT_ON_URL="https://cdn.jsdelivr.net/gh/HerauxValle/CRun@main/bin/built-on.json"
BIN_DIR="$HOME/.local/bin"

info()  { echo "[crun install] $*"; }
error() { echo "[crun install] error: $*" >&2; exit 1; }

# --- purge_jsdelivr: invalidate jsDelivr's cache for a @main path before fetching ---
# jsDelivr fronts GitHub raw content and caches it; @main can otherwise serve a
# stale build for a while after a push. Its purge endpoint is public or anyone
# to call — hit it right before downloading so we always get the latest.
purge_jsdelivr() {
    local path="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/$path" -o /dev/null 2>/dev/null || true
    elif command -v wget &>/dev/null; then
        wget -q "https://purge.jsdelivr.net/gh/HerauxValle/CRun@main/$path" -O /dev/null 2>/dev/null || true
    fi
}

# --- ask: prompt the user even when piped via `curl ... | bash` ---
# In that case stdin is the script source, not a terminal, so reads must go
# through /dev/tty directly. Returns 1 (no prompt asked) if no tty is reachable
# at all, e.g. fully non-interactive CI — callers should treat that as "no".
ask() {
    local __var="$1" __prompt="$2" __ans=""
    if exec 3<>/dev/tty 2>/dev/null; then
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
# We only NOTE this here — cloning is deferred until we know we actually need
# the repo (building requires it; --bin alone does not).
SOURCE_PATH="${BASH_SOURCE[0]:-}"
IS_CURL_PIPE=0
REPO_DIR=""
if [[ -z "$SOURCE_PATH" || ! -f "$SOURCE_PATH" || "$(basename "$SOURCE_PATH")" != "install.sh" ]]; then
    IS_CURL_PIPE=1
    # Purge install.sh/install.ps1 from jsDelivr's cache so the *next* curl|bash
    # always gets the version we're running right now (or newer), not a stale one.
    purge_jsdelivr "install.sh" &
    purge_jsdelivr "install.ps1" &
else
    REPO_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

# --- parse args ---
# Supports combining flags, e.g.: ./install.sh --copy --name runfile
DO_DEPS=0
DEPS_TARGET=""
DO_UNINSTALL=0
DO_COPY=0
INSTALL_NAME="crun"
DO_BIN_ONLY=0
BIN_ONLY_PATH=""
BIN_ONLY_PATH_GIVEN=0

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
        --name)
            i=$((i + 1))
            INSTALL_NAME="${args[$i]:-}"
            [[ -n "$INSTALL_NAME" ]] || { echo "[crun install] error: --name requires a name argument" >&2; exit 1; }
            ;;
        --bin)
            DO_BIN_ONLY=1
            # Optional value: --bin /some/dir (only consume next arg if it isn't another flag)
            next="${args[$((i + 1))]:-}"
            if [[ -n "$next" && "$next" != --* ]]; then
                BIN_ONLY_PATH="$next"
                BIN_ONLY_PATH_GIVEN=1
                i=$((i + 1))
            fi
            ;;
        *)
            echo "[crun install] error: unknown argument: ${args[$i]}" >&2
            exit 1
            ;;
    esac
    i=$((i + 1))
done

[[ $BIN_ONLY_PATH_GIVEN -eq 1 ]] || BIN_ONLY_PATH="$HOME"
INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"

# --- interactive prompt (no relevant flags given) ---
# Ask everything up front, in one flow, identical whether curled or local —
# THEN decide what needs cloning/building based on the answers.
if [[ $DO_DEPS -eq 0 && $DO_UNINSTALL -eq 0 && $DO_BIN_ONLY -eq 0 ]]; then
    if ask reply "[crun install] just grab the portable binary, nothing else? [y/N] "; then
        if [[ "$reply" =~ ^[Yy] ]]; then
            DO_BIN_ONLY=1
            ask path_reply "[crun install] where to? [default: $HOME] "
            [[ -n "${path_reply:-}" ]] && BIN_ONLY_PATH="$path_reply"
        else
            ask reply "[crun install] also install per-language toolchain dependencies via crun --deps? [y/N] "
            if [[ "$reply" =~ ^[Yy] ]]; then
                DO_DEPS=1
                ask DEPS_TARGET "[crun install] only one language (leave empty for all)? "
            fi

            ask name_reply "[crun install] install under a custom binary name instead of 'crun'? (leave empty to skip) "
            if [[ -n "${name_reply:-}" ]]; then
                INSTALL_NAME="$name_reply"
                INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"
            fi

            ask reply "[crun install] copy the binary instead of symlinking it? [y/N] "
            [[ "$reply" =~ ^[Yy] ]] && DO_COPY=1
        fi
    fi
fi

# --- compatibility check: is the prebuilt bin/crun safe to run on THIS machine? ---
# Reads built-on.json (written by the build that produced bin/crun) and compares
# it against the current OS/arch/libc. Returns 0 (compatible) or 1 (reject) and
# prints a reason via $COMPAT_REASON. musl binaries are universally compatible
# on Linux; glibc binaries need the system's glibc >= the build's glibc.
COMPAT_REASON=""
check_compat() {
    local json="$1"
    [[ -f "$json" ]] || { COMPAT_REASON="no built-on.json found — can't verify compatibility"; return 1; }

    local b_os b_arch b_libc b_libc_ver
    b_os="$(grep -o '"os"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" | grep -o '"[^"]*"$' | tr -d '"')"
    b_arch="$(grep -o '"arch"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" | grep -o '"[^"]*"$' | tr -d '"')"
    b_libc="$(grep -o '"libc"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" | grep -o '"[^"]*"$' | tr -d '"')"
    b_libc_ver="$(grep -o '"libc_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$json" | grep -o '"[^"]*"$' | tr -d '"')"

    local sys_os sys_arch
    sys_arch="$(uname -m)"
    case "$(uname -s)" in
        Linux)  sys_os="linux" ;;
        Darwin) sys_os="macos" ;;
        *)      sys_os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac

    [[ "$b_os" == "$sys_os" ]]     || { COMPAT_REASON="binary built for '$b_os', this machine is '$sys_os'"; return 1; }
    [[ "$b_arch" == "$sys_arch" ]] || { COMPAT_REASON="binary built for '$b_arch', this machine is '$sys_arch'"; return 1; }

    if [[ "$b_libc" == "musl" ]]; then
        return 0  # static musl binaries run on any Linux libc
    fi

    # glibc: the binary needs the system's glibc to be >= the build's glibc.
    if [[ "$sys_os" == "linux" && -n "$b_libc_ver" ]] && command -v ldd &>/dev/null; then
        local sys_ver
        sys_ver="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
        if [[ -n "$sys_ver" ]]; then
            local b_major b_minor s_major s_minor
            b_major="${b_libc_ver%%.*}"; b_minor="${b_libc_ver#*.}"
            s_major="${sys_ver%%.*}";    s_minor="${sys_ver#*.}"
            if (( s_major < b_major || (s_major == b_major && s_minor < b_minor) )); then
                COMPAT_REASON="binary needs glibc >= $b_libc_ver, this system has $sys_ver"
                return 1
            fi
        fi
    fi
    return 0
}

# --- bin-only mode: fetch just the binary — no clone, no build, no install ---
# If we already have a local checkout, copy the tracked bin/crun from it;
# otherwise download it directly from GitHub. Either way: no `git clone`,
# since that would be enormously wasteful for "just give me the binary".
# Before using a prebuilt binary (local or downloaded), checks built-on.json
# for compatibility — on mismatch, rejects and offers to compile instead.
fetch_bin_only() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    local dest="$dest_dir/crun"
    local json_tmp
    json_tmp="$(mktemp)"

    if [[ $IS_CURL_PIPE -eq 0 && -f "$REPO_DIR/bin/crun" ]]; then
        cp -f "$REPO_DIR/bin/built-on.json" "$json_tmp" 2>/dev/null || true
        if ! check_compat "$json_tmp"; then
            reject_incompatible "$REPO_DIR/bin/crun"
            rm -f "$json_tmp"
            return
        fi
        info "using tracked portable binary at $REPO_DIR/bin/crun"
        cp -f "$REPO_DIR/bin/crun" "$dest"
    elif command -v curl &>/dev/null || command -v wget &>/dev/null; then
        purge_jsdelivr "bin/crun"
        purge_jsdelivr "bin/built-on.json"
        if command -v curl &>/dev/null; then
            curl -fsSL "$RAW_BUILT_ON_URL" -o "$json_tmp" 2>/dev/null || true
        else
            wget -q "$RAW_BUILT_ON_URL" -O "$json_tmp" 2>/dev/null || true
        fi
        if ! check_compat "$json_tmp"; then
            reject_incompatible "$RAW_BIN_URL"
            rm -f "$json_tmp"
            return
        fi
        info "downloading portable binary from $RAW_BIN_URL"
        if command -v curl &>/dev/null; then
            curl -fsSL "$RAW_BIN_URL" -o "$dest" || error "download failed"
        else
            wget -q "$RAW_BIN_URL" -O "$dest" || error "download failed"
        fi
    else
        error "neither curl nor wget found — can't fetch the binary"
    fi
    rm -f "$json_tmp"
    chmod +x "$dest"
    info "binary ready at $dest"
}

# --- reject_incompatible: explain why, then offer to compile from source instead ---
reject_incompatible() {
    local source="$1"
    info "prebuilt binary at $source is NOT compatible with this machine:"
    info "  $COMPAT_REASON"
    info "rejecting — a copied binary would not run here."
    if ask reply "[crun install] compile from source instead? [Y/n] "; then
        [[ "$reply" =~ ^[Nn] ]] && { info "aborted."; exit 1; }
    fi
    info "compiling from source — this needs the full repo and a Rust toolchain (cargo)."
    DO_BIN_ONLY=0
}

if [[ $DO_BIN_ONLY -eq 1 ]]; then
    fetch_bin_only "$BIN_ONLY_PATH"
    [[ $DO_BIN_ONLY -eq 1 ]] && exit 0
    # fetch_bin_only flipped DO_BIN_ONLY off (incompatible binary, user chose to compile) —
    # fall through to the normal clone+build path below, installing as --copy to BIN_ONLY_PATH.
    DO_COPY=1
    INSTALL_NAME="crun"
    BIN_DIR="$BIN_ONLY_PATH"
    INSTALL_TARGET="$BIN_DIR/$INSTALL_NAME"
fi

# --- everything past this point needs the actual repo: clone now if curled ---
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

RELEASE_BINARY="$REPO_DIR/target/release/crun"

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

# --- portable copy ---
# bin/crun is a tracked, ready-to-grab copy of the freshly built binary —
# see bin/README.md. Refreshed on every install/rebuild; safe to overwrite,
# never the canonical artifact (that's always target/release/crun).
#
# When the musl target + musl-gcc are available, we prefer building a fully
# static musl binary for bin/ — it runs on any Linux distro/libc version
# without compatibility concerns, which is exactly what a portable binary
# should be. Falls back to the regular glibc build if musl isn't set up.
PORTABLE_BINARY="$RELEASE_BINARY"
PORTABLE_LIBC="glibc"
PORTABLE_LIBC_VERSION=""
MUSL_TARGET="x86_64-unknown-linux-musl"
if command -v rustup &>/dev/null && command -v musl-gcc &>/dev/null \
   && rustup target list --installed 2>/dev/null | grep -qx "$MUSL_TARGET"; then
    info "musl target detected — building fully static portable binary..."
    if cargo build --release --target "$MUSL_TARGET" --manifest-path "$REPO_DIR/Cargo.toml"; then
        MUSL_BINARY="$REPO_DIR/target/$MUSL_TARGET/release/crun"
        if [[ -f "$MUSL_BINARY" ]]; then
            PORTABLE_BINARY="$MUSL_BINARY"
            PORTABLE_LIBC="musl"
        fi
    fi
fi

if [[ "$PORTABLE_LIBC" == "glibc" ]] && command -v ldd &>/dev/null; then
    PORTABLE_LIBC_VERSION="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
fi

mkdir -p "$REPO_DIR/bin"
cp -f "$PORTABLE_BINARY" "$REPO_DIR/bin/crun"
chmod +x "$REPO_DIR/bin/crun"
info "refreshed portable binary at $REPO_DIR/bin/crun (libc: $PORTABLE_LIBC${PORTABLE_LIBC_VERSION:+ $PORTABLE_LIBC_VERSION})"

# --- built-on.json ---
# Records ONLY what matters for binary compatibility, so --bin can check a
# prebuilt binary will actually run before copying it onto a target machine:
#   os    — linux/macos (must match exactly)
#   arch  - x86_64/aarch64/... (must match exactly)
#   libc  - musl (universally compatible on Linux) or glibc (needs >= version)
#   libc_version - minimum glibc version this binary requires (glibc only)
PORTABLE_ARCH="$(uname -m)"
PORTABLE_OS="linux"
case "$(uname -s)" in
    Darwin) PORTABLE_OS="macos" ;;
esac
cat > "$REPO_DIR/bin/built-on.json" <<EOF
{
  "os": "$PORTABLE_OS",
  "arch": "$PORTABLE_ARCH",
  "libc": "$PORTABLE_LIBC",
  "libc_version": "$PORTABLE_LIBC_VERSION"
}
EOF
info "wrote $REPO_DIR/bin/built-on.json"

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
