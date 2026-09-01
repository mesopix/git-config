#!/usr/bin/env bash
# git-config-sync one-click installer / uninstaller.
# Cross-platform for macOS / Linux (and Git Bash on Windows) — only
# requires bash, git and curl.
#
# Usage:
#   bash install.sh                          download config/gitconfig from GitHub and install
#   bash install.sh /path/to/gitconfig       install from a local file
#   curl -fsSL <url> | bash                  remote install (downloads config/gitconfig from GitHub)
#   curl -fsSL <url> | bash -s -- --uninstall
#                                            remove the include.path entry and the managed gitconfig
set -u

REPO_RAW_BASE='https://raw.githubusercontent.com/mesopix/git-config/main'
TOOL_NAME='git-config-sync'

# Colors: only when writing to a terminal (and NO_COLOR is unset), so
# piped output and log files stay free of ANSI escape codes.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != 'dumb' ]; then
  GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi

# The install flow buffers its lines so a no-op run prints a single summary
# line rather than a multi-line report that reads like a failure.
NOTICES=()
ok_line() { printf '%s✓ %s%s' "$GREEN" "$1" "$RESET"; }
warn_line() { printf '%s⚠ %s%s' "$YELLOW" "$1" "$RESET"; }
notice_ok() { NOTICES+=("$(ok_line "$1")"); }
notice_warn() { NOTICES+=("$(warn_line "$1")"); }
flush_notices() {
  [ "${#NOTICES[@]}" -gt 0 ] || return
  printf '%s\n' "${NOTICES[@]}"
  NOTICES=()
}

die() {
  printf '%sError: %s%s\n' "$RED" "$1" "$RESET" >&2
  if [ -n "${DOWNLOADED_SELF:-}" ] && [ -f "$DOWNLOADED_SELF" ]; then
    printf '(the installer was kept at %s; fix the problem and re-run: bash install.sh)\n' "$DOWNLOADED_SELF" >&2
  fi
  exit 1
}

# A downloaded copy of this script ("curl -o install.sh && bash install.sh")
# is removed after success — but never one inside a repo clone.
DOWNLOADED_SELF=''
detect_downloaded_self() {
  local candidate dir
  candidate=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0") || return
  [ -f "$candidate" ] || return
  [ "$(basename "$candidate")" = 'install.sh' ] || return
  dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return
  [ "$dir" = "$(pwd -P)" ] || return
  [ -e "$dir/config/gitconfig" ] && return
  [ -e "$dir/.git" ] && return
  DOWNLOADED_SELF=$candidate
}
detect_downloaded_self

cleanup_downloaded_self() {
  [ -n "$DOWNLOADED_SELF" ] || return 0
  if rm -f -- "$DOWNLOADED_SELF" 2>/dev/null; then
    printf '%s✓ removed downloaded installer: %s%s\n' "$GREEN" "$DOWNLOADED_SELF" "$RESET"
  else
    printf '  (you can delete the installer manually: %s)\n' "$DOWNLOADED_SELF"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  bash install.sh                        download config/gitconfig from GitHub and install
  bash install.sh /path/to/gitconfig     install from a local file
  bash install.sh --uninstall            remove the include.path entry and the managed gitconfig
EOF
}

# ── git helpers ─────────────────────────────────────────
require_git() {
  command -v git >/dev/null 2>&1 || die 'git not found: sync and syntax validation both require it. Install from https://git-scm.com/downloads'
}

escape_regex() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|\\]/\\&/g'
}

# Existing include.path values (empty when the key is absent, exit code 1).
get_include_paths() {
  git config --global --get-all include.path 2>/dev/null || true
}

IS_WINDOWS=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac

same_path() {
  if [ "$IS_WINDOWS" = 1 ]; then
    [ "$(printf '%s' "$1" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$2" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')" ]
  else
    [ "$(printf '%s' "$1" | tr '\\' '/')" = "$(printf '%s' "$2" | tr '\\' '/')" ]
  fi
}

# Remove only the entries pointing at the managed file; include.path values
# belonging to other tools are preserved.
unset_include_entries() {
  local stored out status
  for stored in "$@"; do
    out=$(git config --global --unset-all include.path "^$(escape_regex "$stored")$" 2>&1)
    status=$?
    if [ "$status" -ne 0 ] && [ "$status" -ne 5 ]; then
      die "unable to update global include.path: $out"
    fi
  done
}

# ── Managed locations ───────────────────────────────────
# Same directories the previous installers used (Go's os.UserConfigDir
# semantics), so an existing include.path keeps pointing at the right file
# and is simply updated in place.
user_config_dir() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -z "${APPDATA:-}" ]; then
        die 'Environment variable APPDATA is not set; cannot determine the user config directory'
      fi
      printf '%s' "$APPDATA" | tr '\\' '/' ;;
    Darwin) printf '%s' "$HOME/Library/Application Support" ;;
    *) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
  esac
}

MANAGED_DIR="$(user_config_dir)/$TOOL_NAME"
MANAGED="$MANAGED_DIR/gitconfig"
# git stores include.path verbatim; forward slashes work on every platform.
MANAGED_INCLUDE=$(printf '%s' "$MANAGED" | tr '\\' '/')

# ── include.path management ─────────────────────────────
# Idempotent: nothing is written when exactly one matching entry already
# exists. Duplicate or differently-spelled matches collapse into one.
ensure_include() {
  local -a matches=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    same_path "$p" "$MANAGED_INCLUDE" && matches+=("$p")
  done < <(get_include_paths)
  if [ "${#matches[@]}" -eq 1 ] && [ "${matches[0]}" = "$MANAGED_INCLUDE" ]; then
    notice_ok "global include.path already set: $MANAGED_INCLUDE"
    return 0
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    notice_warn "found ${#matches[@]} duplicate include.path entries; merging into one"
  fi
  if [ "${#matches[@]}" -gt 0 ]; then
    unset_include_entries "${matches[@]}"
  fi
  local out
  out=$(git config --global --add include.path "$MANAGED_INCLUDE" 2>&1)
  if [ $? -ne 0 ]; then die "unable to write global include.path: $out"; fi
  notice_ok "added include.path to global config: $MANAGED_INCLUDE"
  return 1
}

# ── Managed file install (temp + rename, atomic) ────────
# Validate the source via git BEFORE replacing anything, so a broken file
# aborts with the previous install untouched.
install_managed() {
  local source=$1
  if [ -f "$MANAGED" ] && cmp -s -- "$MANAGED" "$source"; then
    notice_ok "managed config is already up to date: $MANAGED"
    return 0
  fi
  if [ -f "$MANAGED" ]; then
    notice_warn 'existing managed config differs from the source and will be overwritten — local changes will be lost'
  fi
  mkdir -p -- "$MANAGED_DIR" || die "unable to create directory: $MANAGED_DIR"
  # die() exits without running cleanup, so remove the temp file explicitly
  # before dying — otherwise it blocks a later uninstall's rmdir.
  local temp="$MANAGED_DIR/.gitconfig-$$.tmp"
  cp -- "$source" "$temp" || die "unable to write: $temp"
  local check
  check=$(git config --file "$temp" --list 2>&1)
  if [ $? -ne 0 ]; then
    rm -f -- "$temp"
    die "invalid gitconfig source:
$check"
  fi
  mv -f -- "$temp" "$MANAGED" || die "unable to move $temp into place"
  notice_ok "installed managed config: $MANAGED"
  return 1
}

# ── Source resolution ───────────────────────────────────
resolve_source() {
  local explicit=$1
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] || die "file not found: $explicit"
    notice_ok "using local source: $explicit"
    SRC_FILE=$explicit
    SRC_TMP=''
    return
  fi
  command -v curl >/dev/null 2>&1 || die 'curl not found: downloading config/gitconfig requires it'
  SRC_FILE=$(mktemp) || die 'unable to create a temporary file for downloading'
  local code status hint
  hint='if the network is unavailable, download config/gitconfig manually, then run: bash install.sh /path/to/gitconfig'
  code=$(curl -sSL -o "$SRC_FILE" -w '%{http_code}' "$REPO_RAW_BASE/config/gitconfig" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -f -- "$SRC_FILE"; SRC_FILE=''
    die "download failed: $REPO_RAW_BASE/config/gitconfig
$hint"
  fi
  if [ "$code" != '200' ]; then
    rm -f -- "$SRC_FILE"; SRC_FILE=''
    die "download failed: HTTP $code ($REPO_RAW_BASE/config/gitconfig)
$hint"
  fi
  notice_ok 'fetched config/gitconfig from GitHub'
  SRC_TMP=1
}

# ── Install ─────────────────────────────────────────────
do_install() {
  require_git
  resolve_source "$1"
  install_managed "$SRC_FILE"; local file_changed=$?
  ensure_include; local inc_changed=$?
  if [ -n "${SRC_TMP:-}" ]; then rm -f -- "$SRC_FILE"; fi

  # Tailor the closing output: a no-op run prints one affirmative line,
  # so it can't be mistaken for a failure.
  if [ "$file_changed" -eq 0 ] && [ "$inc_changed" -eq 0 ]; then
    printf '%sAlready up to date — nothing to do.%s\n' "$GREEN" "$RESET"
  else
    flush_notices
    printf '%sSync complete. Managed config overrides same-name global settings and takes effect immediately.%s\n' "$GREEN" "$RESET"
  fi
  cleanup_downloaded_self
}

# ── Uninstall ───────────────────────────────────────────
do_uninstall() {
  require_git
  local -a matches=()
  local p changed=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    same_path "$p" "$MANAGED_INCLUDE" && matches+=("$p")
  done < <(get_include_paths)
  if [ "${#matches[@]}" -gt 0 ]; then
    unset_include_entries "${matches[@]}"
    printf '%s✓ removed include.path entry pointing to the managed file: %s%s\n' "$GREEN" "$MANAGED_INCLUDE" "$RESET"
    changed=1
  fi
  if [ -f "$MANAGED" ]; then
    rm -f -- "$MANAGED" || die "unable to delete $MANAGED"
    printf '%s✓ deleted %s%s\n' "$GREEN" "$MANAGED" "$RESET"
    rmdir "$MANAGED_DIR" 2>/dev/null || true
    changed=1
  fi
  if [ "$changed" = 1 ]; then
    printf '%sUninstall complete. Other global config and include.path entries were not touched.%s\n' "$GREEN" "$RESET"
  else
    printf '%sNothing to uninstall.%s\n' "$GREEN" "$RESET"
  fi
  cleanup_downloaded_self
}

# ── Main ────────────────────────────────────────────────
main() {
  local explicit='' uninstall=0 arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      -u|--uninstall) uninstall=1 ;;
      -*) die "unknown option: $arg" ;;
      *) explicit=$arg ;;
    esac
  done
  if [ "$uninstall" = 1 ]; then
    do_uninstall
    exit $?
  fi
  do_install "$explicit"
}

main "$@"
