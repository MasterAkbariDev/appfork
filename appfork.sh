#!/usr/bin/env bash
# =============================================================================
# appfork.sh
#
# Create isolated second instances ("profiles") of desktop applications.
#
#   macOS : copies the .app, gives the copy its own bundle identifier and name,
#           re-signs it (ad-hoc), and builds a real launcher .app that starts the
#           copy's executable with a separate user-data directory.
#   Linux : creates a launcher script + a .desktop entry that starts the
#           existing executable with a separate user-data directory.
#
# IMPORTANT: the target application must itself support a command-line option
# that relocates its user data (for Electron/Chromium apps: --user-data-dir).
# This tool cannot make an application isolate itself; it only wires up the
# plumbing (separate bundle identity, launcher, argument, metadata).
#
# Design notes
#   * Shell syntax is kept portable (no arrays, no [[ ]], no printf -v, no
#     reliance on unquoted word splitting) so the script behaves the same when
#     started as `bash appfork.sh` or `zsh appfork.sh`.
#   * No eval, no user input is ever executed. Paths are single-quote escaped
#     before being written into generated launcher scripts.
#   * Nothing is deleted without validation; profile data is only ever deleted
#     after an explicit "DELETE" confirmation (or --delete-profile).
#   * Partial work is rolled back on failure, interrupt or termination.
# =============================================================================

if [ -n "${ZSH_VERSION:-}" ]; then
  emulate sh
fi
set -euo pipefail

APC_VERSION="1.0.0"
SCRIPT_NAME="${0##*/}"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-/nonexistent}" ]; then
  printf 'ERROR $HOME is not set or not a directory.\n' >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Global state (defaults)
# --------------------------------------------------------------------------
MODE="create"            # create | repair | list | remove | help | version
DRY_RUN=0
VERBOSE=0
QUIET=0
ASSUME_YES=0
NO_INPUT=0
COLOR_MODE="auto"        # auto | always | never

SOURCE=""                # macOS: .app bundle   Linux: executable
DESKTOP_SRC=""           # Linux: source .desktop file (optional)
INSTANCE_NAME=""
PROFILE_INPUT=""         # as typed by the user (name or path)
RUNTIME_ARG=""
ARG_STYLE=""             # separate | equals
EXTRA_ARGS=""            # newline separated
ICON_MODE=""             # original | custom | none
CUSTOM_ICON=""
DEST_DIR=""
DEST_DIR_EXPLICIT=0
WANT_DOCK=""             # yes | no | ""
ON_CONFLICT=""           # abort | reconfigure | replace-app | recreate
DELETE_PROFILE=0
LAUNCH_TEST=""           # yes | no | ""
REMOVE_TARGET=""
REPAIR_TARGET=""

PLATFORM=""
PLATFORM_LABEL=""
SLUG=""
PROFILE_DIR=""
CONFIG_DIR="${APPFORK_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/appfork}"
LEGACY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/app-profile-cloner"   # name used before the rename to appfork

# macOS-specific
SRC_PLIST=""
SRC_BUNDLE_ID=""
SRC_EXEC=""
SRC_APPNAME=""
SRC_ICON=""
SRC_BUNDLE_NAME=""
KEEP_BUNDLE_NAME=0
BUNDLE_ID=""
DEST_APP=""
LAUNCHER_APP=""
HAVE_CODESIGN=0

# Linux-specific
LAUNCHER_SCRIPT=""
DESKTOP_ENTRY=""
ICON_COPY=""
SRC_DESKTOP_NAME=""
SRC_DESKTOP_ICON=""
SRC_DESKTOP_CATEGORIES=""

# conflict handling
EXISTING_META=""
FOUND_APP=""
FOUND_LAUNCHER=""
CONFLICT_ACTION=""
PROFILE_DELETE_CONFIRMED=0
PROFILE_PRE_EXISTED=0

# rollback bookkeeping
SUCCESS=0
CLEAN_LIST=""
BACKUP_LIST=""
STEP_N=0
STEP_TOTAL=0
STEP_LABEL=""
STEP_OPEN=0
HEADER_DONE=0
OLD_PROFILE=""
DEF_PROFILE=""
DEF_ARG=""
EXTRA_ASKED=0

# output
C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
ESC=""; TTY_OUT=0
SYM_OK="OK"; SYM_WARN="!"; SYM_DRY="~"
BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
BOX_W=46

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
setup_output() {
  local use_color=0
  ESC=$(printf '\033')
  TTY_OUT=0
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    TTY_OUT=1
  fi
  case "$COLOR_MODE" in
    always) use_color=1 ;;
    never) use_color=0 ;;
    *)
      if [ "$TTY_OUT" = 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
        use_color=1
      fi
      ;;
  esac
  if [ "$use_color" = 1 ]; then
    C_RESET="${ESC}[0m"; C_BOLD="${ESC}[1m"; C_DIM="${ESC}[2m"
    C_RED="${ESC}[31m"; C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"
    C_BLUE="${ESC}[34m"; C_CYAN="${ESC}[36m"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*)
      SYM_OK="✓"; SYM_WARN="⚠"; SYM_DRY="~"
      BOX_TL="╔"; BOX_TR="╗"; BOX_BL="╚"; BOX_BR="╝"; BOX_H="═"; BOX_V="║"
      ;;
    *)
      SYM_OK="OK"; SYM_WARN="!"; SYM_DRY="~"
      BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
      ;;
  esac
}

log_info() {
  if [ "$QUIET" != 1 ]; then printf '%s\n' "${C_BLUE}INFO${C_RESET}  $*"; fi
}
log_ok() {
  if [ "$QUIET" != 1 ]; then printf '%s\n' "${C_GREEN}OK${C_RESET}    $*"; fi
}
log_warn() {
  printf '%s\n' "${C_YELLOW}WARN${C_RESET}  $*" >&2
}
log_verbose() {
  if [ "$VERBOSE" = 1 ] && [ "$QUIET" != 1 ]; then printf '%s\n' "${C_DIM}....  $*${C_RESET}"; fi
}
log_dry() {
  if [ "$QUIET" != 1 ]; then printf '%s\n' "${C_CYAN}DRY${C_RESET}   would: $*"; fi
}
say() {
  if [ "$QUIET" != 1 ]; then printf '%s\n' "$*"; fi
}

die() {
  if [ "$STEP_OPEN" = 1 ]; then printf '\r%s[K' "$ESC"; fi
  printf '%s\n' "${C_RED}ERROR${C_RESET} $1" >&2
  if [ -n "${2:-}" ]; then printf '%s\n' "      Fix: $2" >&2; fi
  exit 1
}

usage_error() {
  printf '%s\n' "${C_RED}ERROR${C_RESET} $1" >&2
  printf '%s\n' "      Run '$SCRIPT_NAME --help' for usage." >&2
  exit 2
}

spaces() { printf '%*s' "$1" ''; }

box_border() { # top|bottom
  local i=0
  if [ "$1" = top ]; then printf '%s' "$BOX_TL"; else printf '%s' "$BOX_BL"; fi
  while [ "$i" -lt "$BOX_W" ]; do printf '%s' "$BOX_H"; i=$((i + 1)); done
  if [ "$1" = top ]; then printf '%s\n' "$BOX_TR"; else printf '%s\n' "$BOX_BR"; fi
}

box_line() { # centered ASCII text
  local text="$1" len left right
  len=${#text}
  left=$(((BOX_W - len) / 2))
  right=$((BOX_W - len - left))
  printf '%s%s%s%s%s\n' "$BOX_V" "$(spaces "$left")" "$text" "$(spaces "$right")" "$BOX_V"
}

box() { # title [subtitle]
  if [ "$QUIET" = 1 ]; then return 0; fi
  printf '%s' "$C_BOLD"
  box_border top
  box_line "$1"
  if [ -n "${2:-}" ]; then box_line "$2"; fi
  box_border bottom
  printf '%s\n' "$C_RESET"
}

print_header() {
  box "APPFORK" "Create isolated app instances"
}

tildify() { # display helper: /Users/me/x -> ~/x
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

step_begin() {
  STEP_N=$((STEP_N + 1))
  STEP_LABEL="$1"
  if [ "$QUIET" != 1 ] && [ "$TTY_OUT" = 1 ] && [ "$VERBOSE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf '[%d/%d] %s...' "$STEP_N" "$STEP_TOTAL" "$STEP_LABEL"
    STEP_OPEN=1
  fi
}

step_end() {
  STEP_OPEN=0
  if [ "$QUIET" = 1 ]; then return 0; fi
  if [ "$TTY_OUT" = 1 ] && [ "$VERBOSE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf '\r%s[K' "$ESC"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '[%d/%d] %-28s %s%s%s\n' "$STEP_N" "$STEP_TOTAL" "$STEP_LABEL" "$C_CYAN" "$SYM_DRY" "$C_RESET"
  else
    printf '[%d/%d] %-28s %s%s%s\n' "$STEP_N" "$STEP_TOTAL" "$STEP_LABEL" "$C_GREEN" "$SYM_OK" "$C_RESET"
  fi
}

# --------------------------------------------------------------------------
# Generic helpers
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

slugify() {
  lower "$1" | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Single-quote a string for safe inclusion in a POSIX shell script.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

is_interactive() {
  [ "$NO_INPUT" = 0 ] && [ -t 0 ]
}

need_interactive() { # what-is-missing
  if ! is_interactive; then
    usage_error "Missing required option $1 and no terminal available to prompt for it."
  fi
}

expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

normalize_path() { # collapse // and strip trailing /
  local p
  p=$(printf '%s' "$1" | sed -e 's://*:/:g' -e 's:\(.\)/$:\1:')
  if [ -z "$p" ]; then p="/"; fi
  printf '%s' "$p"
}

# Reject characters that would break our metadata/launcher formats.
check_path_chars() { # path label
  case "$1" in
    *[[:cntrl:]]*) die "$2 contains control characters." "Use a plain path." ;;
    *"|"*) die "$2 contains a '|' character, which is not supported." "Rename the path." ;;
  esac
}

abspath_existing() { # path -> absolute physical path (path must exist)
  local p d b
  p=$(expand_tilde "$1")
  p=$(normalize_path "$p")
  if [ -d "$p" ]; then
    (cd -P -- "$p" && pwd -P)
  else
    d=$(dirname -- "$p")
    b=$(basename -- "$p")
    (cd -P -- "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  fi
}

is_protected_path() {
  case "$1" in
    ""|/|/Applications|/Library|/System|/Users|/Volumes|/bin|/sbin|/usr|/etc|/var|/opt|/tmp|/private|/home|/root|/dev|/proc|/sys|/boot|/lib|/lib64|/mnt|/media|/srv|/cores|/Network)
      return 0 ;;
  esac
  case "$1" in
    "$HOME"|"$HOME/Library"|"$HOME/Library/Application Support"|"$HOME/Library/Preferences"|"$HOME/Library/Caches"|"$HOME/Applications"|"$HOME/Desktop"|"$HOME/Documents"|"$HOME/Downloads"|"$HOME/.config"|"$HOME/.local"|"$HOME/.local/share"|"$HOME/.local/bin"|"$HOME/.cache"|"$HOME/.ssh"|"$HOME/.gnupg")
      return 0 ;;
  esac
  return 1
}

# The only function allowed to run rm -rf. Returns 1 (never dies) so it is safe
# inside the rollback path.
safe_rm_rf() { # path [required-suffix]
  local p suffix depth
  p=$(normalize_path "${1:-}")
  suffix="${2:-}"
  case "$p" in
    /*) : ;;
    *) log_warn "Refusing to delete non-absolute path: $p"; return 1 ;;
  esac
  case "/$p/" in
    */../*|*/./*) log_warn "Refusing to delete path with relative components: $p"; return 1 ;;
  esac
  if is_protected_path "$p"; then
    log_warn "Refusing to delete protected path: $p"
    return 1
  fi
  depth=$(printf '%s' "$p" | tr -cd '/' | wc -c | tr -d ' ')
  if [ "$depth" -lt 2 ]; then
    log_warn "Refusing to delete shallow path: $p"
    return 1
  fi
  if [ -n "$suffix" ]; then
    case "$p" in
      *"$suffix") : ;;
      *) log_warn "Refusing to delete '$p' (expected it to end with '$suffix')."; return 1 ;;
    esac
  fi
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 0; fi
  if [ "$DRY_RUN" = 1 ]; then log_dry "remove $p"; return 0; fi
  log_verbose "removing $p"
  rm -rf -- "$p"
}

# Run a mutating command, or only describe it in --dry-run mode.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    log_dry "$(quote_cmd "$@")"
    return 0
  fi
  log_verbose "+ $(quote_cmd "$@")"
  "$@"
}

quote_cmd() {
  local a out=""
  for a in "$@"; do out="$out$(sh_quote "$a") "; done
  printf '%s' "${out% }"
}

write_file() { # target [mode]   (content on stdin)
  local target="$1" mode="${2:-644}"
  if [ "$DRY_RUN" = 1 ]; then
    cat >/dev/null
    log_dry "write $target"
    return 0
  fi
  log_verbose "writing $target"
  cat >"$target"
  chmod "$mode" "$target"
}

track_path() { # kind(rmrf|file|rmdir) path
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  CLEAN_LIST="$1|$2
$CLEAN_LIST"
}

stash_existing() { # move an existing generated item aside so it can be restored
  local p="$1" bak
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 0; fi
  bak="$p.apc-backup.$$"
  run mv -- "$p" "$bak"
  if [ "$DRY_RUN" != 1 ]; then
    BACKUP_LIST="$p|$bak
$BACKUP_LIST"
  fi
}

discard_backups() {
  local orig bak
  while IFS='|' read -r orig bak; do
    if [ -n "$bak" ]; then safe_rm_rf "$bak" ".apc-backup.$$" || true; fi
  done <<EOF
$BACKUP_LIST
EOF
  BACKUP_LIST=""
}

rollback() {
  local kind p orig bak
  while IFS='|' read -r kind p; do
    if [ -z "$kind" ]; then continue; fi
    case "$kind" in
      rmrf) safe_rm_rf "$p" || true ;;
      file) rm -f -- "$p" 2>/dev/null || true ;;
      rmdir) rmdir -- "$p" 2>/dev/null || true ;;
    esac
  done <<EOF
$CLEAN_LIST
EOF
  while IFS='|' read -r orig bak; do
    if [ -z "$bak" ]; then continue; fi
    if [ -e "$bak" ] || [ -L "$bak" ]; then
      safe_rm_rf "$orig" || true
      if mv -- "$bak" "$orig"; then
        log_warn "Restored previous version: $orig"
      else
        log_warn "Could not restore $orig; your previous copy is at: $bak"
      fi
    fi
  done <<EOF
$BACKUP_LIST
EOF
}

cleanup_on_failure() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ "$rc" -ne 0 ] && [ "$SUCCESS" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    if [ -n "$CLEAN_LIST$BACKUP_LIST" ]; then
      printf '%s\n' "${C_YELLOW}WARN${C_RESET}  Operation did not complete; rolling back partial changes..." >&2
      rollback
      printf '%s\n' "${C_YELLOW}WARN${C_RESET}  Rollback finished. Your profile data was not touched." >&2
    fi
  fi
  exit "$rc"
}

# True if some running process command line contains $1 (ignores this tool).
is_running() {
  ps -ax -o command= 2>/dev/null | P="$1" awk '
    BEGIN { p = ENVIRON["P"] }
    index($0, p) && index($0, "appfork") == 0 { f = 1 }
    END { exit (f ? 0 : 1) }'
}

# --------------------------------------------------------------------------
# Prompts
# --------------------------------------------------------------------------
ask() { # label [default]  -> prints answer; UI goes to stderr
  local label="$1" def="${2:-}" ans=""
  if [ -n "$def" ]; then
    printf '\n%s%s%s %s[%s]%s\n> ' "$C_BOLD" "$label" "$C_RESET" "$C_DIM" "$def" "$C_RESET" >&2
  else
    printf '\n%s%s%s\n> ' "$C_BOLD" "$label" "$C_RESET" >&2
  fi
  if ! IFS= read -r ans; then
    printf '\n' >&2
    die "Input closed unexpectedly." "Re-run in a terminal, or pass all options on the command line."
  fi
  ans=$(trim "$ans")
  if [ -z "$ans" ]; then ans="$def"; fi
  printf '%s' "$ans"
}

# confirm "question" Y|N  -> 0 = yes
confirm() {
  local q="$1" def="${2:-Y}" hint ans
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  if ! is_interactive; then return 1; fi
  if [ "$def" = Y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while :; do
    printf '\n%s%s %s%s\n> ' "$C_BOLD" "$q" "$hint" "$C_RESET" >&2
    if ! IFS= read -r ans; then printf '\n' >&2; return 1; fi
    ans=$(lower "$(trim "$ans")")
    case "$ans" in
      "") if [ "$def" = Y ]; then return 0; else return 1; fi ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

choose() { # title option... -> prints chosen index (1-based)
  local title="$1" n=0 sel o max
  shift
  printf '\n%s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET" >&2
  for o in "$@"; do
    n=$((n + 1))
    printf '  %d) %s\n' "$n" "$o" >&2
  done
  max=$n
  while :; do
    sel=$(ask "Choice [1-$max]:")
    case "$sel" in
      ""|*[!0-9]*) continue ;;
    esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "$max" ]; then break; fi
  done
  printf '%s' "$sel"
}

display_app() {
  case "$1" in
    "$HOME"/Applications/*) printf '%s  (~/Applications)' "$(basename -- "$1")" ;;
    *) printf '%s' "$(basename -- "$1")" ;;
  esac
}

menu_select() { # newline-separated paths -> chosen path, or empty for "Other..."
  local list="$1" n=0 line sel other
  printf '\n%sSelect source application:%s\n\n' "$C_BOLD" "$C_RESET" >&2
  while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    n=$((n + 1))
    printf '  %d) %s\n' "$n" "$(display_app "$line")" >&2
  done <<EOF
$list
EOF
  other=$((n + 1))
  printf '  %d) Other...\n' "$other" >&2
  while :; do
    sel=$(ask "Choice [1-$other]:")
    case "$sel" in
      ""|*[!0-9]*) continue ;;
    esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "$other" ]; then break; fi
  done
  if [ "$sel" -eq "$other" ]; then return 0; fi
  n=0
  while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    n=$((n + 1))
    if [ "$n" -eq "$sel" ]; then printf '%s' "$line"; return 0; fi
  done <<EOF
$list
EOF
}

# --------------------------------------------------------------------------
# Metadata (simple key=value files; parsed with awk, never sourced)
# --------------------------------------------------------------------------
meta_file_for() { printf '%s/instances/%s.meta' "$CONFIG_DIR" "$1"; }

meta_get() { # file key
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

meta_get_all() { # file key
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"
}

emit_meta() {
  local a
  printf 'version=%s\n' "$APC_VERSION"
  printf 'platform=%s\n' "$PLATFORM"
  printf 'name=%s\n' "$INSTANCE_NAME"
  printf 'slug=%s\n' "$SLUG"
  printf 'created=%s\n' "$(now_iso)"
  printf 'source=%s\n' "$SOURCE"
  printf 'profile=%s\n' "$PROFILE_DIR"
  printf 'runtime_arg=%s\n' "$RUNTIME_ARG"
  printf 'arg_style=%s\n' "$ARG_STYLE"
  printf 'icon_mode=%s\n' "$ICON_MODE"
  printf 'custom_icon=%s\n' "$CUSTOM_ICON"
  while IFS= read -r a; do
    if [ -n "$a" ]; then printf 'extra_arg=%s\n' "$a"; fi
  done <<EOF
$EXTRA_ARGS
EOF
  if [ "$PLATFORM" = macos ]; then
    printf 'app=%s\n' "$DEST_APP"
    printf 'launcher=%s\n' "$LAUNCHER_APP"
    printf 'bundle_id=%s\n' "$BUNDLE_ID"
  else
    printf 'desktop_source=%s\n' "$DESKTOP_SRC"
    printf 'launcher=%s\n' "$LAUNCHER_SCRIPT"
    printf 'desktop_entry=%s\n' "$DESKTOP_ENTRY"
    printf 'icon_copy=%s\n' "$ICON_COPY"
  fi
}

register_instance() {
  local f ts
  f=$(meta_file_for "$SLUG")
  run mkdir -p "$CONFIG_DIR/instances" "$CONFIG_DIR/backups"
  if [ "$DRY_RUN" != 1 ]; then chmod 700 "$CONFIG_DIR" 2>/dev/null || true; fi
  if [ -f "$f" ]; then
    ts=$(date +%Y%m%d%H%M%S)
    run cp -p "$f" "$CONFIG_DIR/backups/$SLUG.meta.$ts"
  fi
  emit_meta | write_file "$f" 600
}

# --------------------------------------------------------------------------
# Platform detection / prerequisites
# --------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM="macos"; PLATFORM_LABEL="macOS" ;;
    Linux) PLATFORM="linux"; PLATFORM_LABEL="Linux" ;;
    *) die "Unsupported platform: $(uname -s)" "This tool supports macOS (Darwin) and Linux only." ;;
  esac
}

check_prerequisites() {
  if [ "$PLATFORM" = macos ]; then
    if [ ! -x "$PLISTBUDDY" ]; then
      die "$PLISTBUDDY not found." "It ships with macOS; your system installation looks damaged."
    fi
    have plutil || die "plutil not found." "It ships with macOS (/usr/bin/plutil)."
    if have codesign; then HAVE_CODESIGN=1; fi
  fi
}

# --------------------------------------------------------------------------
# plist helpers (macOS)
# --------------------------------------------------------------------------
plist_get() { # plist key
  "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null
}

plist_set() { # plist key value  (adds the key when missing)
  if [ "$DRY_RUN" = 1 ]; then
    log_dry "PlistBuddy: set $2 = $3"
    return 0
  fi
  log_verbose "PlistBuddy: set $2 = $3"
  if ! "$PLISTBUDDY" -c "Set :$2 $3" "$1" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Add :$2 string $3" "$1" >/dev/null
  fi
}

plist_delete() { # plist key  (missing key is fine)
  if [ "$DRY_RUN" = 1 ]; then
    log_dry "PlistBuddy: delete $2"
    return 0
  fi
  "$PLISTBUDDY" -c "Delete :$2" "$1" >/dev/null 2>&1 || true
}

# Find the icon file the bundle actually references. Prints its path.
detect_icon() { # app-bundle
  local app="$1" plist res icon f
  plist="$app/Contents/Info.plist"
  res="$app/Contents/Resources"
  icon=$(plist_get "$plist" CFBundleIconFile) || icon=""
  if [ -z "$icon" ]; then
    icon=$(plist_get "$plist" "CFBundleIconFiles:0") || icon=""
  fi
  if [ -n "$icon" ]; then
    for f in "$res/$icon" "$res/$icon.icns"; do
      if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
    done
  fi
  f=$(find "$res" -maxdepth 1 -name '*.icns' 2>/dev/null | sort | head -n 1 || true)
  if [ -n "$f" ] && [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  return 1
}

src_version_string() {
  printf '%s/%s' "$(plist_get "$SRC_PLIST" CFBundleShortVersionString || true)" \
    "$(plist_get "$SRC_PLIST" CFBundleVersion || true)"
}

# --------------------------------------------------------------------------
# Input validation
# --------------------------------------------------------------------------
validate_name() { # prints reason on failure
  local n="$1" s
  if [ -z "$n" ]; then echo "The name cannot be empty."; return 1; fi
  if [ "${#n}" -gt 80 ]; then echo "The name is too long (max 80 characters)."; return 1; fi
  case "$n" in
    *..*) echo "The name cannot contain '..'."; return 1 ;;
    */*) echo "The name cannot contain '/'."; return 1 ;;
    .*|-*) echo "The name cannot start with '.' or '-'."; return 1 ;;
    " "*|*" ") echo "The name cannot start or end with a space."; return 1 ;;
    *.app|*.App|*.APP) echo "Leave out the '.app' extension; it is added automatically."; return 1 ;;
    *[[:cntrl:]]*) echo "The name cannot contain control characters."; return 1 ;;
    *'\'*|*:*|*'*'*|*'?'*|*'"'*|*"'"*|*'<'*|*'>'*|*'|'*|*'$'*|*'`'*|*';'*)
      echo "The name cannot contain any of:  \\ : * ? \" ' < > | \$ \` ;"
      return 1
      ;;
  esac
  s=$(slugify "$n")
  if [ -z "$s" ]; then echo "The name must contain at least one letter (a-z) or digit."; return 1; fi
  return 0
}

default_profile_base() {
  if [ "$PLATFORM" = macos ]; then
    printf '%s/Library/Application Support' "$HOME"
  else
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}"
  fi
}

# Turn user input (name or path) into an absolute profile path; prints reason on failure.
resolve_profile() {
  local in="$1" p
  if [ -z "$in" ]; then echo "The profile directory cannot be empty."; return 1; fi
  case "$in" in
    *[[:cntrl:]]*) echo "The profile path cannot contain control characters."; return 1 ;;
    *"|"*) echo "The profile path cannot contain '|'."; return 1 ;;
  esac
  case "$in" in
    /*|"~"|"~/"*)
      p=$(normalize_path "$(expand_tilde "$in")")
      case "/$p/" in
        */../*|*/./*) echo "The profile path cannot contain '.' or '..' components."; return 1 ;;
      esac
      ;;
    *)
      case "$in" in
        */*) echo "A relative profile name cannot contain '/'. Use an absolute path instead."; return 1 ;;
        *..*) echo "The profile name cannot contain '..'."; return 1 ;;
        .*|-*) echo "The profile name cannot start with '.' or '-'."; return 1 ;;
        " "*|*" ") echo "The profile name cannot start or end with a space."; return 1 ;;
      esac
      p="$(default_profile_base)/$in"
      ;;
  esac
  if is_protected_path "$p"; then
    echo "'$p' is a system or home directory and cannot be used as a profile."
    return 1
  fi
  printf '%s' "$p"
}

# --------------------------------------------------------------------------
# Source application (macOS)
# --------------------------------------------------------------------------
list_macos_apps() {
  local d
  for d in /Applications "$HOME/Applications"; do
    if [ -d "$d" ]; then
      find "$d" -maxdepth 1 -name '*.app' \( -type d -o -type l \) 2>/dev/null
    fi
  done | sort -f
}

inspect_source_macos() {
  local disp m
  if [ ! -d "$SOURCE" ]; then
    die "Source application not found: $SOURCE" "Check the path (tip: drag the .app into Terminal to paste its path)."
  fi
  case "$SOURCE" in
    *.app) : ;;
    *) die "'$SOURCE' is not an application bundle (.app)." "Pass the path of a .app folder." ;;
  esac
  SRC_PLIST="$SOURCE/Contents/Info.plist"
  if [ ! -f "$SRC_PLIST" ]; then
    die "Not a valid app bundle: $SRC_PLIST is missing." "Pick the .app itself, not a folder containing it."
  fi
  if ! plutil -lint "$SRC_PLIST" >/dev/null 2>&1; then
    die "The source Info.plist is malformed: $SRC_PLIST" "Reinstall the application, then try again."
  fi
  SRC_BUNDLE_ID=$(plist_get "$SRC_PLIST" CFBundleIdentifier) || SRC_BUNDLE_ID=""
  if [ -z "$SRC_BUNDLE_ID" ]; then
    die "The source app has no CFBundleIdentifier." "This tool needs a standard bundle with a bundle identifier."
  fi
  SRC_EXEC=$(plist_get "$SRC_PLIST" CFBundleExecutable) || SRC_EXEC=""
  if [ -z "$SRC_EXEC" ]; then
    die "The source app has no CFBundleExecutable." "The bundle looks incomplete; reinstall the application."
  fi
  if [ ! -f "$SOURCE/Contents/MacOS/$SRC_EXEC" ] || [ ! -x "$SOURCE/Contents/MacOS/$SRC_EXEC" ]; then
    die "Executable not found or not executable: $SOURCE/Contents/MacOS/$SRC_EXEC" "Reinstall the application."
  fi
  SRC_APPNAME=$(basename -- "$SOURCE" .app)
  disp=$(plist_get "$SRC_PLIST" CFBundleDisplayName) || disp=""
  if [ -z "$disp" ]; then disp=$(plist_get "$SRC_PLIST" CFBundleName) || disp=""; fi
  if [ -z "$disp" ]; then disp="$SRC_APPNAME"; fi
  SRC_ICON=$(detect_icon "$SOURCE") || SRC_ICON=""
  # Electron (and similar) apps locate their helper apps as "<CFBundleName> Helper.app",
  # so CFBundleName must stay unchanged or the app aborts with "Unable to find helper app".
  SRC_BUNDLE_NAME=$(plist_get "$SRC_PLIST" CFBundleName) || SRC_BUNDLE_NAME=""
  KEEP_BUNDLE_NAME=0
  if [ -d "$SOURCE/Contents/Frameworks/Electron Framework.framework" ] \
    || { [ -n "$SRC_BUNDLE_NAME" ] && [ -d "$SOURCE/Contents/Frameworks/$SRC_BUNDLE_NAME Helper.app" ]; }; then
    KEEP_BUNDLE_NAME=1
    log_info "Electron-style app: CFBundleName is kept so its helper apps are still found."
  fi
  log_ok "Source application found"
  log_ok "Application bundle detected ($SRC_BUNDLE_ID)"
  if [ -d "$SOURCE/Contents/_MASReceipt" ]; then
    log_warn "This is a Mac App Store app. Copies re-signed ad-hoc usually fail receipt validation and refuse to start."
  fi
  if [ -z "$SRC_ICON" ]; then
    log_warn "Could not locate an .icns icon file (the app may use an asset catalog). The launcher will have no icon unless you pass --icon."
  fi
  for m in "$CONFIG_DIR"/instances/*.meta; do
    if [ -f "$m" ] && [ "$(meta_get "$m" app)" = "$SOURCE" ]; then
      log_warn "The source is itself an instance created by this tool."
    fi
  done
}

ask_source_app() {
  local list choice
  if [ "$PLATFORM" = macos ]; then
    if [ -z "$SOURCE" ]; then
      need_interactive "--source"
      list=$(list_macos_apps)
      choice=""
      if [ -n "$list" ]; then choice=$(menu_select "$list"); fi
      if [ -z "$choice" ]; then
        SOURCE=$(ask "Path to the application (.app bundle):")
      else
        SOURCE="$choice"
      fi
    fi
    if [ -z "$SOURCE" ]; then usage_error "No source application given."; fi
    check_path_chars "$SOURCE" "Source path"
    if [ ! -e "$(expand_tilde "$SOURCE")" ]; then
      die "Source application not found: $SOURCE" "Check the path (tip: drag the .app into Terminal to paste its path)."
    fi
    SOURCE=$(abspath_existing "$SOURCE")
    inspect_source_macos
  else
    ask_source_app_linux
  fi
}

# --------------------------------------------------------------------------
# Source application (Linux)
# --------------------------------------------------------------------------
desktop_get() { # file key  (first [Desktop Entry] group only)
  awk -v k="$2" '
    /^\[/ { if (seen) exit; seen = 1 }
    index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

find_desktop_for() { # executable -> prints a matching .desktop path
  local base d f
  base=$(basename -- "$1")
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}/applications" /usr/local/share/applications /usr/share/applications \
    /var/lib/flatpak/exports/share/applications "$HOME/.local/share/flatpak/exports/share/applications" \
    /var/lib/snapd/desktop/applications; do
    f="$d/$base.desktop"
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

ask_source_app_linux() {
  local p guess
  if [ -z "$SOURCE" ]; then
    need_interactive "--source"
    SOURCE=$(ask "Path or command name of the application executable:")
  fi
  if [ -z "$SOURCE" ]; then usage_error "No source executable given."; fi
  check_path_chars "$SOURCE" "Source path"
  case "$SOURCE" in
    */*|"~"*) p=$(expand_tilde "$SOURCE") ;;
    *) p=$(command -v "$SOURCE" 2>/dev/null || true) ;;
  esac
  if [ -z "$p" ] || [ ! -f "$p" ] || [ ! -x "$p" ]; then
    die "Executable not found or not executable: $SOURCE" "Give a full path, or a command that is on your PATH."
  fi
  SOURCE=$(abspath_existing "$p")
  log_ok "Source executable found: $SOURCE"

  if [ -z "$DESKTOP_SRC" ]; then
    guess=$(find_desktop_for "$SOURCE" || true)
    if [ -n "$guess" ]; then
      log_info "Found desktop entry: $guess"
      if confirm "Reuse name/icon information from it?" Y; then DESKTOP_SRC="$guess"; fi
    elif is_interactive; then
      DESKTOP_SRC=$(ask "Path to the application's .desktop file (optional, press Enter to skip):")
    fi
  fi
  if [ -n "$DESKTOP_SRC" ]; then
    check_path_chars "$DESKTOP_SRC" "Desktop file path"
    DESKTOP_SRC=$(expand_tilde "$DESKTOP_SRC")
    if [ ! -f "$DESKTOP_SRC" ]; then
      die "Desktop file not found: $DESKTOP_SRC" "Omit --desktop-file, or give a valid path."
    fi
    SRC_DESKTOP_NAME=$(desktop_get "$DESKTOP_SRC" Name || true)
    SRC_DESKTOP_ICON=$(desktop_get "$DESKTOP_SRC" Icon || true)
    SRC_DESKTOP_CATEGORIES=$(desktop_get "$DESKTOP_SRC" Categories || true)
    log_ok "Desktop entry read ($(basename -- "$DESKTOP_SRC"))"
  fi
  SRC_APPNAME="${SRC_DESKTOP_NAME:-$(basename -- "$SOURCE")}"
}

# --------------------------------------------------------------------------
# Questions
# --------------------------------------------------------------------------
ask_instance_name() {
  local reason def
  def=""
  if [ -n "$SRC_APPNAME" ]; then def="$SRC_APPNAME 2"; fi
  while :; do
    if [ -z "$INSTANCE_NAME" ]; then
      need_interactive "--name"
      INSTANCE_NAME=$(ask "New application name:" "$def")
    fi
    if reason=$(validate_name "$INSTANCE_NAME"); then break; fi
    if is_interactive; then
      printf '%s\n' "${C_RED}ERROR${C_RESET} $reason" >&2
      INSTANCE_NAME=""
    else
      die "Invalid name '$INSTANCE_NAME': $reason" "Choose a name made of letters, digits, spaces, '.', '-', '_'."
    fi
  done
  SLUG=$(slugify "$INSTANCE_NAME")
}

ask_profile_directory() {
  local reason def resolved
  def=$(printf '%s' "$INSTANCE_NAME" | tr ' ' '-')
  if [ -n "$DEF_PROFILE" ]; then def="$DEF_PROFILE"; fi
  while :; do
    if [ -z "$PROFILE_INPUT" ]; then
      need_interactive "--profile"
      PROFILE_INPUT=$(ask "Profile directory name (or absolute path):" "$def")
    fi
    if resolved=$(resolve_profile "$PROFILE_INPUT"); then
      PROFILE_DIR="$resolved"
      break
    fi
    reason="$resolved"
    if is_interactive; then
      printf '%s\n' "${C_RED}ERROR${C_RESET} $reason" >&2
      PROFILE_INPUT=""
    else
      die "Invalid profile '$PROFILE_INPUT': $reason" "Use a simple name or an absolute path."
    fi
  done
}

valid_runtime_arg() {
  case "$1" in
    -*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:]]*|*[[:cntrl:]]*|*"|"*) return 1 ;;
  esac
  return 0
}

ask_runtime_arguments() {
  local sel extra
  if [ -z "$RUNTIME_ARG" ]; then
    need_interactive "--arg"
    cat >&2 <<EOF

${C_BOLD}Runtime argument${C_RESET}
The application itself must support a command-line option that changes where
it keeps its user data. Electron/Chromium apps use  --user-data-dir ;
Firefox uses  -profile ; others differ. Check the app's documentation.
This tool cannot isolate an application that has no such option.
EOF
    RUNTIME_ARG=$(ask "Runtime argument:" "${DEF_ARG:---user-data-dir}")
  fi
  case "$RUNTIME_ARG" in
    *=) RUNTIME_ARG="${RUNTIME_ARG%=}"; if [ -z "$ARG_STYLE" ]; then ARG_STYLE="equals"; fi ;;
  esac
  while ! valid_runtime_arg "$RUNTIME_ARG"; do
    if is_interactive; then
      printf '%s\n' "${C_RED}ERROR${C_RESET} The argument must start with '-' and contain no spaces." >&2
      RUNTIME_ARG=$(ask "Runtime argument:" "--user-data-dir")
    else
      die "Invalid runtime argument '$RUNTIME_ARG'." "It must start with '-' and contain no whitespace, e.g. --user-data-dir."
    fi
  done
  if [ -z "$ARG_STYLE" ]; then
    if is_interactive; then
      sel=$(choose "Does this argument use the directory as the next argument?" \
        "Yes  ($RUNTIME_ARG \"\$PROFILE_DIR\")" \
        "No, use $RUNTIME_ARG=value")
      if [ "$sel" = 1 ]; then ARG_STYLE="separate"; else ARG_STYLE="equals"; fi
    else
      ARG_STYLE="equals"
    fi
  fi
  if [ -z "$EXTRA_ARGS" ] && is_interactive && [ "${EXTRA_ASKED:-0}" = 0 ]; then
    printf '\n%sAdditional arguments%s (optional, one per entry; press Enter on an empty line to finish)\n' "$C_BOLD" "$C_RESET" >&2
    while :; do
      extra=$(ask "Extra argument:")
      if [ -z "$extra" ]; then break; fi
      add_extra_arg "$extra"
    done
  fi
}

add_extra_arg() {
  case "$1" in
    *[[:cntrl:]]*) die "Extra arguments cannot contain control characters or newlines." ;;
  esac
  if [ -z "$EXTRA_ARGS" ]; then EXTRA_ARGS="$1"; else EXTRA_ARGS="$EXTRA_ARGS
$1"; fi
}

validate_icon_file() { # path -> prints reason on failure
  local f="$1" ext
  if [ ! -f "$f" ]; then echo "File not found: $f"; return 1; fi
  ext=$(lower "${f##*.}")
  if [ "$PLATFORM" = macos ]; then
    if [ "$ext" != icns ]; then echo "On macOS the icon must be an .icns file."; return 1; fi
    if [ "$(head -c 4 "$f" 2>/dev/null || true)" != "icns" ]; then echo "File does not look like a valid .icns icon."; return 1; fi
  else
    case "$ext" in png|svg|xpm) : ;; *) echo "On Linux the icon must be .png, .svg or .xpm."; return 1 ;; esac
  fi
  return 0
}

ask_icon_options() {
  local reason have_orig=0
  if [ "$PLATFORM" = macos ] && [ -n "$SRC_ICON" ]; then have_orig=1; fi
  if [ "$PLATFORM" = linux ] && [ -n "$SRC_DESKTOP_ICON" ]; then have_orig=1; fi

  if [ -n "$CUSTOM_ICON" ]; then
    ICON_MODE="custom"
  fi
  if [ -z "$ICON_MODE" ]; then
    if is_interactive; then
      if [ "$have_orig" = 1 ] && confirm "Use original application icon?" Y; then
        ICON_MODE="original"
      elif confirm "Use custom icon?" N; then
        ICON_MODE="custom"
      else
        ICON_MODE="none"
      fi
    else
      if [ "$have_orig" = 1 ]; then ICON_MODE="original"; else ICON_MODE="none"; fi
    fi
  fi
  if [ "$ICON_MODE" = original ] && [ "$have_orig" = 0 ]; then
    log_warn "No original icon could be determined; the instance will use a generic icon."
    ICON_MODE="none"
  fi
  if [ "$ICON_MODE" = custom ]; then
    while :; do
      if [ -z "$CUSTOM_ICON" ]; then
        need_interactive "--icon"
        CUSTOM_ICON=$(ask "Path to custom icon ($([ "$PLATFORM" = macos ] && echo '.icns' || echo '.png/.svg')):")
      fi
      CUSTOM_ICON=$(expand_tilde "$CUSTOM_ICON")
      check_path_chars "$CUSTOM_ICON" "Icon path"
      if reason=$(validate_icon_file "$CUSTOM_ICON"); then break; fi
      if is_interactive; then
        printf '%s\n' "${C_RED}ERROR${C_RESET} $reason" >&2
        CUSTOM_ICON=""
      else
        die "$reason" "Pass a valid icon with --icon."
      fi
    done
    CUSTOM_ICON=$(abspath_existing "$CUSTOM_ICON")
  fi
}

# --------------------------------------------------------------------------
# Destination (macOS) and naming
# --------------------------------------------------------------------------
generate_bundle_id() {
  local slug app_slug suffix
  slug=$(slugify "$INSTANCE_NAME")
  app_slug=$(slugify "$SRC_APPNAME")
  suffix="$slug"
  case "$slug" in
    "$app_slug"-*) suffix="${slug#"$app_slug"-}" ;;
  esac
  if [ -z "$suffix" ]; then suffix="$slug"; fi
  BUNDLE_ID="$SRC_BUNDLE_ID.$suffix"
}

choose_dest_dir() {
  if [ -n "$DEST_DIR" ]; then
    DEST_DIR=$(normalize_path "$(expand_tilde "$DEST_DIR")")
    check_path_chars "$DEST_DIR" "Destination directory"
    if [ ! -d "$DEST_DIR" ]; then
      die "Destination directory does not exist: $DEST_DIR" "Create it first, or omit --dest-dir."
    fi
    if [ ! -w "$DEST_DIR" ]; then
      die "Destination directory is not writable: $DEST_DIR" "Pick a directory you own, such as ~/Applications."
    fi
    return 0
  fi
  if [ -w /Applications ]; then
    DEST_DIR="/Applications"
    return 0
  fi
  log_warn "/Applications is not writable by your user (this tool never uses sudo)."
  if [ ! -d "$HOME/Applications" ]; then
    if confirm "Use ~/Applications instead (it will be created)?" Y; then :; else
      die "No writable destination available." "Re-run with --dest-dir <writable folder>."
    fi
    run mkdir -p "$HOME/Applications"
  else
    if confirm "Use ~/Applications instead?" Y; then :; else
      die "No writable destination available." "Re-run with --dest-dir <writable folder>."
    fi
  fi
  DEST_DIR="$HOME/Applications"
}

# --------------------------------------------------------------------------
# Duplicate protection
# --------------------------------------------------------------------------
# Phase 1: look for an existing instance with this name. May set CONFLICT_ACTION
# and pre-load stored settings.
check_duplicates() {
  local d app lau apps_seen="" found_meta="" sel owned=0 bid loc

  FOUND_APP=""; FOUND_LAUNCHER=""; EXISTING_META=""
  found_meta=$(meta_file_for "$SLUG")
  if [ -f "$found_meta" ]; then EXISTING_META="$found_meta"; fi

  if [ "$PLATFORM" = macos ]; then
    if [ -n "$EXISTING_META" ]; then
      app=$(meta_get "$EXISTING_META" app)
      lau=$(meta_get "$EXISTING_META" launcher)
      if [ -e "$app" ]; then FOUND_APP="$app"; fi
      if [ -e "$lau" ]; then FOUND_LAUNCHER="$lau"; fi
    fi
    for d in "$DEST_DIR" /Applications "$HOME/Applications"; do
      if [ -z "$d" ]; then continue; fi
      if [ -z "$FOUND_APP" ] && [ -e "$d/$INSTANCE_NAME.app" ]; then FOUND_APP="$d/$INSTANCE_NAME.app"; fi
      if [ -z "$FOUND_LAUNCHER" ] && [ -e "$d/$INSTANCE_NAME Launcher.app" ]; then FOUND_LAUNCHER="$d/$INSTANCE_NAME Launcher.app"; fi
    done
    if [ -n "$FOUND_APP" ] && [ "$DEST_DIR_EXPLICIT" = 0 ]; then DEST_DIR=$(dirname -- "$FOUND_APP"); fi
    if [ -z "$DEST_DIR" ]; then
      if [ -n "$FOUND_LAUNCHER" ] && [ "$DEST_DIR_EXPLICIT" = 0 ]; then DEST_DIR=$(dirname -- "$FOUND_LAUNCHER"); fi
    fi
  else
    DESKTOP_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/appfork-$SLUG.desktop"
    LAUNCHER_SCRIPT="${XDG_DATA_HOME:-$HOME/.local/share}/appfork/launchers/$SLUG.sh"
    if [ -e "$DESKTOP_ENTRY" ]; then FOUND_APP="$DESKTOP_ENTRY"; fi
    if [ -e "$LAUNCHER_SCRIPT" ]; then FOUND_LAUNCHER="$LAUNCHER_SCRIPT"; fi
  fi

  if [ -z "$EXISTING_META" ] && [ -z "$FOUND_APP" ] && [ -z "$FOUND_LAUNCHER" ]; then
    return 0
  fi

  # Ownership: never touch something this tool did not create.
  if [ -n "$EXISTING_META" ]; then
    owned=1
  elif [ "$PLATFORM" = macos ] && [ -n "$FOUND_APP" ]; then
    bid=$(plist_get "$FOUND_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
    if [ -n "$bid" ] && [ "$bid" = "$BUNDLE_ID" ]; then owned=1; fi
  elif [ "$PLATFORM" = linux ] && [ -n "$FOUND_APP" ]; then
    if grep -q -e '^X-Appfork=' -e '^X-AppProfileCloner=' "$FOUND_APP" 2>/dev/null; then owned=1; fi
  fi
  if [ "$owned" = 0 ]; then
    die "'${FOUND_APP:-$FOUND_LAUNCHER}' already exists but was not created by this tool." \
      "Choose a different name, or remove/rename the existing item yourself. It will not be overwritten."
  fi

  if [ "$QUIET" != 1 ]; then
    printf '\n%s%s An instance named "%s" already exists.%s\n\nDetected:\n' "$C_YELLOW" "$SYM_WARN" "$INSTANCE_NAME" "$C_RESET"
    if [ -n "$FOUND_APP" ]; then printf '  %-10s %s\n' "App:" "$(tildify "$FOUND_APP")"; fi
    if [ -n "$FOUND_LAUNCHER" ]; then printf '  %-10s %s\n' "Launcher:" "$(tildify "$FOUND_LAUNCHER")"; fi
    if [ -n "$EXISTING_META" ]; then
      loc=$(meta_get "$EXISTING_META" profile)
      printf '  %-10s %s\n' "Profile:" "$(tildify "$loc")"
      printf '  %-10s %s\n' "Metadata:" "$(tildify "$EXISTING_META")"
    fi
  fi

  if [ -z "$ON_CONFLICT" ]; then
    if ! is_interactive; then
      die "An instance named '$INSTANCE_NAME' already exists." \
        "Pass --on-conflict abort|reconfigure|replace-app|recreate, or choose another --name."
    fi
    if [ "$PLATFORM" = macos ]; then
      sel=$(choose "What would you like to do?" "Abort" "Reconfigure" "Replace application only" "Remove everything and recreate")
      case "$sel" in 1) ON_CONFLICT=abort ;; 2) ON_CONFLICT=reconfigure ;; 3) ON_CONFLICT=replace-app ;; 4) ON_CONFLICT=recreate ;; esac
    else
      sel=$(choose "What would you like to do?" "Abort" "Reconfigure (regenerate launcher and desktop entry)" "Remove everything and recreate")
      case "$sel" in 1) ON_CONFLICT=abort ;; 2) ON_CONFLICT=reconfigure ;; 3) ON_CONFLICT=recreate ;; esac
    fi
  fi
  CONFLICT_ACTION="$ON_CONFLICT"
  case "$CONFLICT_ACTION" in
    abort) die "Aborted; nothing was changed." ;;
    reconfigure|replace-app|recreate) : ;;
    *) usage_error "Invalid --on-conflict value '$CONFLICT_ACTION'." ;;
  esac
  if [ "$PLATFORM" = linux ] && [ "$CONFLICT_ACTION" = replace-app ]; then CONFLICT_ACTION="reconfigure"; fi

  # Pre-load stored settings (CLI flags always win).
  if [ -n "$EXISTING_META" ]; then load_stored_settings "$EXISTING_META"; fi

  if [ -n "$EXISTING_META" ]; then OLD_PROFILE=$(meta_get "$EXISTING_META" profile); fi
  if [ "$CONFLICT_ACTION" = recreate ]; then
    if [ -n "$EXISTING_META" ]; then
      loc=$(meta_get "$EXISTING_META" profile)
      if [ -d "$loc" ] && confirm_delete_profile "$loc"; then PROFILE_DELETE_CONFIRMED=1; fi
      if [ "$PROFILE_DELETE_CONFIRMED" = 0 ]; then log_info "The profile will be kept: $(tildify "$loc")"; fi
    fi
  fi
}

load_stored_settings() { # meta-file
  local f="$1" v
  # Reconfigure/recreate in a terminal: offer stored values as prompt defaults.
  if ! reuse_all_stored && is_interactive; then
    DEF_PROFILE=$(meta_get "$f" profile)
    DEF_ARG=$(meta_get "$f" runtime_arg)
    return 0
  fi
  if [ -z "$PROFILE_INPUT" ]; then
    v=$(meta_get "$f" profile); if [ -n "$v" ]; then PROFILE_INPUT="$v"; fi
  fi
  if [ -z "$RUNTIME_ARG" ]; then
    v=$(meta_get "$f" runtime_arg); if [ -n "$v" ]; then RUNTIME_ARG="$v"; fi
  fi
  if [ -z "$ARG_STYLE" ]; then
    v=$(meta_get "$f" arg_style); if [ -n "$v" ]; then ARG_STYLE="$v"; fi
  fi
  if [ -z "$EXTRA_ARGS" ]; then
    EXTRA_ARGS=$(meta_get_all "$f" extra_arg || true)
    EXTRA_ASKED=1
  fi
  if [ -z "$ICON_MODE" ] && [ -z "$CUSTOM_ICON" ]; then
    v=$(meta_get "$f" icon_mode); if [ -n "$v" ]; then ICON_MODE="$v"; fi
    v=$(meta_get "$f" custom_icon); if [ -n "$v" ]; then CUSTOM_ICON="$v"; fi
  fi
  if [ "$PLATFORM" = linux ] && [ -z "$DESKTOP_SRC" ]; then
    v=$(meta_get "$f" desktop_source); if [ -n "$v" ] && [ -f "$v" ]; then DESKTOP_SRC="$v"; fi
  fi
}

# "Replace application only" keeps every stored answer and asks nothing new.
reuse_all_stored() { [ "$CONFLICT_ACTION" = "replace-app" ]; }

confirm_delete_profile() { # path -> 0 when deletion is explicitly confirmed
  local ans
  if [ "$DELETE_PROFILE" = 1 ]; then return 0; fi
  if ! is_interactive; then return 1; fi
  printf '\n%s%s This permanently deletes the profile (logins, settings, history):%s\n  %s\n' \
    "$C_YELLOW" "$SYM_WARN" "$C_RESET" "$1" >&2
  ans=$(ask "Type DELETE to confirm (or press Enter to keep the profile):")
  [ "$ans" = "DELETE" ]
}

# Phase 2: conflicts that only become visible once every input is known.
validate_input() {
  local m other_bid hits h
  # Profile isolation sanity: the profile must not be the original app's own data.
  if [ "$PLATFORM" = macos ]; then
    for h in "$SRC_APPNAME" "$SRC_EXEC" "$SRC_BUNDLE_ID"; do
      if [ "$PROFILE_DIR" = "$HOME/Library/Application Support/$h" ]; then
        die "The profile '$PROFILE_DIR' is the original application's own data directory." \
          "Choose a different profile name so the instances are isolated."
      fi
    done
    case "$PROFILE_DIR" in
      "$SOURCE"/*|"$DEST_APP"/*) die "The profile cannot live inside an application bundle." "Choose a directory outside of /Applications." ;;
    esac
  fi

  # Is another instance already using this profile or bundle id?
  for m in "$CONFIG_DIR"/instances/*.meta; do
    if [ ! -f "$m" ] || [ "$m" = "$EXISTING_META" ]; then continue; fi
    if [ "$(meta_get "$m" profile)" = "$PROFILE_DIR" ]; then
      die "Profile '$PROFILE_DIR' is already used by instance '$(meta_get "$m" name)'." "Pick a different profile directory."
    fi
    if [ "$PLATFORM" = macos ]; then
      other_bid=$(meta_get "$m" bundle_id)
      if [ "$other_bid" = "$BUNDLE_ID" ]; then
        die "Bundle identifier '$BUNDLE_ID' is already used by instance '$(meta_get "$m" name)'." "Choose a different instance name."
      fi
    fi
  done

  # Bundle id registered elsewhere on this system (best effort via Spotlight).
  if [ "$PLATFORM" = macos ] && have mdfind; then
    hits=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)
    while IFS= read -r h; do
      if [ -z "$h" ] || [ "$h" = "$DEST_APP" ] || [ "$h" = "$FOUND_APP" ]; then continue; fi
      case "$h" in *.apc-backup.*) continue ;; esac
      die "Bundle identifier '$BUNDLE_ID' is already used by another application: $h" "Choose a different instance name."
    done <<EOF
$hits
EOF
  fi

  # Profile directory already there (and not from this instance)?
  if [ -e "$PROFILE_DIR" ]; then
    PROFILE_PRE_EXISTED=1
    if [ -z "$EXISTING_META" ]; then
      log_warn "The profile directory already exists: $PROFILE_DIR"
      log_warn "It will be reused as-is (its contents are not modified or deleted by this tool)."
      if ! confirm "Use the existing profile directory?" N; then
        die "Aborted; nothing was changed." "Choose another profile name, or pass --yes to reuse the existing directory."
      fi
    fi
  fi
}

# --------------------------------------------------------------------------
# macOS implementation
# --------------------------------------------------------------------------
clone_macos_app() {
  local before after links
  before=$(src_version_string)
  stash_existing "$DEST_APP"
  track_path rmrf "$DEST_APP"
  if have ditto; then
    run ditto "$SOURCE" "$DEST_APP"
  else
    run cp -R "$SOURCE" "$DEST_APP"
  fi
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  after=$(src_version_string)
  if [ "$before" != "$after" ]; then
    die "The source application changed while it was being copied ($before -> $after); it may be updating." \
      "Wait for the update to finish, then run the tool again."
  fi
  links=$(find "$DEST_APP" -type l 2>/dev/null | while IFS= read -r l; do
    t=$(readlink "$l" 2>/dev/null || true)
    if [ "${t#"$SOURCE"/}" != "$t" ]; then printf '%s\n' "$l"; fi
  done | wc -l | tr -d ' ')
  if [ "${links:-0}" -gt 0 ]; then
    log_warn "$links symlink(s) inside the copy point back into the original app; the copy is not fully self-contained."
  fi
}

update_localized_names() { # best effort: InfoPlist.strings may override the display name
  local f res="$DEST_APP/Contents/Resources" key
  if [ "$DRY_RUN" = 1 ] || [ ! -d "$res" ]; then return 0; fi
  find "$res" -maxdepth 2 -name InfoPlist.strings 2>/dev/null | while IFS= read -r f; do
    for key in CFBundleDisplayName CFBundleName; do
      if [ "$key" = CFBundleName ] && [ "$KEEP_BUNDLE_NAME" = 1 ]; then continue; fi
      if plutil -extract "$key" raw -o - "$f" >/dev/null 2>&1; then
        if ! plutil -replace "$key" -string "$INSTANCE_NAME" "$f" >/dev/null 2>&1; then
          log_warn "Could not update $key in localized strings: $f"
        fi
      fi
    done
  done
}

modify_macos_plist() { # id | name
  local plist="$DEST_APP/Contents/Info.plist"
  case "$1" in
    id)
      plist_set "$plist" CFBundleIdentifier "$BUNDLE_ID"
      ;;
    name)
      plist_set "$plist" CFBundleDisplayName "$INSTANCE_NAME"
      if [ "$KEEP_BUNDLE_NAME" != 1 ]; then
        plist_set "$plist" CFBundleName "$INSTANCE_NAME"
      fi
      update_localized_names
      ;;
  esac
}

apply_macos_icon() {
  local plist="$DEST_APP/Contents/Info.plist" res="$DEST_APP/Contents/Resources"
  case "$ICON_MODE" in
    original)
      log_verbose "keeping the original icon resources inside the copied bundle"
      ;;
    custom)
      run cp -- "$CUSTOM_ICON" "$res/AppProfileCloner.icns"
      plist_set "$plist" CFBundleIconFile "AppProfileCloner"
      plist_delete "$plist" CFBundleIconName
      ;;
    none)
      plist_delete "$plist" CFBundleIconFile
      plist_delete "$plist" CFBundleIconName
      ;;
  esac
}

create_macos_launcher() {
  local macos res plist script icon_src="" icon_key="" exec_line exe
  macos="$LAUNCHER_APP/Contents/MacOS"
  res="$LAUNCHER_APP/Contents/Resources"
  plist="$LAUNCHER_APP/Contents/Info.plist"
  script="$macos/Launcher"
  exe="$DEST_APP/Contents/MacOS/$SRC_EXEC"

  stash_existing "$LAUNCHER_APP"
  track_path rmrf "$LAUNCHER_APP"
  run mkdir -p "$macos" "$res"

  case "$ICON_MODE" in
    custom) icon_src="$CUSTOM_ICON" ;;
    original) icon_src="$SRC_ICON" ;;
  esac
  if [ -n "$icon_src" ]; then
    run cp -- "$icon_src" "$res/icon.icns"
    icon_key="  <key>CFBundleIconFile</key><string>icon</string>"
  fi

  exec_line="exec $(sh_quote "$exe") $(build_exec_args)"
  {
    printf '#!/bin/bash\n'
    printf '# Generated by appfork %s - regenerate with the tool instead of editing.\n' "$APC_VERSION"
    printf '%s\n' "$exec_line"
  } | write_file "$script" 755

  cat <<EOF | write_file "$plist" 644
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Launcher</string>
$icon_key
  <key>CFBundleIdentifier</key><string>$(xml_escape "$BUNDLE_ID.launcher")</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$(xml_escape "$INSTANCE_NAME")</string>
  <key>CFBundleDisplayName</key><string>$(xml_escape "$INSTANCE_NAME")</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
  if [ "$DRY_RUN" != 1 ]; then
    plutil -lint "$plist" >/dev/null || die "Generated launcher Info.plist is invalid." "Please report this as a bug."
  fi

  # Make sure the profile directory exists (the app normally creates it itself).
  if [ ! -e "$PROFILE_DIR" ]; then
    run mkdir -p "$PROFILE_DIR"
    track_path rmdir "$PROFILE_DIR"
  fi
}

# Quoted argument list for the exec line: the profile option, then extras.
build_exec_args() {
  local out a
  if [ "$ARG_STYLE" = separate ]; then
    out="$(sh_quote "$RUNTIME_ARG") $(sh_quote "$PROFILE_DIR")"
  else
    out="$(sh_quote "$RUNTIME_ARG=$PROFILE_DIR")"
  fi
  while IFS= read -r a; do
    if [ -n "$a" ]; then out="$out $(sh_quote "$a")"; fi
  done <<EOF
$EXTRA_ARGS
EOF
  printf '%s' "$out"
}

sign_macos_app() {
  local out
  if [ "$HAVE_CODESIGN" != 1 ]; then
    if [ "$(uname -m)" = arm64 ]; then
      die "codesign is not installed, and Apple Silicon refuses to run modified, unsigned apps." \
        "Install the Command Line Tools:  xcode-select --install"
    fi
    log_warn "codesign not found; skipping signing. The app may be rejected by macOS."
    return 0
  fi
  if have xattr; then run xattr -cr "$DEST_APP" || true; fi
  if [ "$DRY_RUN" = 1 ]; then
    log_dry "codesign --force --deep --sign - $DEST_APP"
    log_dry "codesign --force --sign - $LAUNCHER_APP"
    return 0
  fi
  log_verbose "+ codesign --force --deep --sign - $DEST_APP"
  if ! out=$(codesign --force --deep --sign - "$DEST_APP" 2>&1); then
    die "Code signing the copied application failed:
$out" "Make sure the app is not running, and that you own the destination. If it persists, the app may not support re-signing (e.g. Mac App Store apps)."
  fi
  log_verbose "$out"
  if ! out=$(codesign --force --sign - "$LAUNCHER_APP" 2>&1); then
    die "Code signing the launcher failed:
$out" "Report this as a bug; the launcher is a plain bundle."
  fi
}

validate_instance() {
  local plist bid exe
  if [ "$DRY_RUN" = 1 ]; then log_dry "validate the installation"; return 0; fi
  if [ "$PLATFORM" = macos ]; then
    plist="$DEST_APP/Contents/Info.plist"
    plutil -lint "$plist" >/dev/null 2>&1 || die "Validation failed: copied Info.plist is invalid." "Re-run; if it persists, the source bundle may be unusual."
    bid=$(plist_get "$plist" CFBundleIdentifier)
    if [ "$bid" != "$BUNDLE_ID" ]; then die "Validation failed: bundle identifier is '$bid', expected '$BUNDLE_ID'."; fi
    exe="$DEST_APP/Contents/MacOS/$SRC_EXEC"
    if [ ! -x "$exe" ]; then die "Validation failed: executable missing: $exe"; fi
    if [ "$HAVE_CODESIGN" = 1 ]; then
      if ! codesign --verify --deep --strict "$DEST_APP" >/dev/null 2>&1; then
        die "Validation failed: the code signature of the copy is not valid." \
          "Run 'codesign --verify --deep --strict -vv \"$DEST_APP\"' to see why."
      fi
    fi
    if [ ! -x "$LAUNCHER_APP/Contents/MacOS/Launcher" ]; then die "Validation failed: launcher executable missing."; fi
    plutil -lint "$LAUNCHER_APP/Contents/Info.plist" >/dev/null 2>&1 || die "Validation failed: launcher Info.plist is invalid."
    bash -n "$LAUNCHER_APP/Contents/MacOS/Launcher" || die "Validation failed: launcher script has a syntax error."
    if ! grep -F -q -- "$exe" "$LAUNCHER_APP/Contents/MacOS/Launcher" 2>/dev/null; then
      die "Validation failed: launcher does not reference the copied executable."
    fi
  else
    if [ ! -x "$LAUNCHER_SCRIPT" ]; then die "Validation failed: launcher script missing: $LAUNCHER_SCRIPT"; fi
    bash -n "$LAUNCHER_SCRIPT" || die "Validation failed: launcher script has a syntax error."
    if [ ! -f "$DESKTOP_ENTRY" ]; then die "Validation failed: desktop entry missing: $DESKTOP_ENTRY"; fi
    if have desktop-file-validate; then
      desktop-file-validate "$DESKTOP_ENTRY" >/dev/null 2>&1 || log_warn "desktop-file-validate reported issues for $DESKTOP_ENTRY"
    fi
  fi
}

# --------------------------------------------------------------------------
# Dock (macOS) - additive only; never resets or rewrites the whole Dock.
# --------------------------------------------------------------------------
add_launcher_to_dock() {
  local dock entry esc_path
  if ! have defaults || ! have killall; then
    log_warn "Dock tooling (defaults/killall) not available."
    say "      Drag \"$LAUNCHER_APP\" to the Dock manually."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then log_dry "add $LAUNCHER_APP to the Dock (append only) and restart the Dock"; return 0; fi
  dock=$(defaults read com.apple.dock persistent-apps 2>/dev/null || true)
  case "$dock" in
    *"$LAUNCHER_APP"*) log_info "The launcher is already in the Dock."; return 0 ;;
  esac
  esc_path=$(xml_escape "$LAUNCHER_APP")
  entry="<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$esc_path</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  if defaults write com.apple.dock persistent-apps -array-add "$entry" 2>/dev/null; then
    killall Dock >/dev/null 2>&1 || true
    log_ok "Launcher added to the Dock (existing items untouched)."
  else
    log_warn "Could not modify the Dock automatically."
    say "      Drag \"$LAUNCHER_APP\" to the Dock manually."
  fi
}

# --------------------------------------------------------------------------
# Linux implementation
# --------------------------------------------------------------------------
exec_field_quote() { # quote one argument for a .desktop Exec= line
  local s
  s=$(printf '%s' "$1" | sed -e 's/\\/\\\\\\\\/g' -e 's/"/\\\\"/g' -e 's/`/\\\\`/g' -e 's/\$/\\\\$/g' -e 's/%/%%/g')
  printf '"%s"' "$s"
}

create_linux_launcher() {
  local dir icondir ext
  dir=$(dirname -- "$LAUNCHER_SCRIPT")
  icondir="${XDG_DATA_HOME:-$HOME/.local/share}/appfork/icons"
  stash_existing "$LAUNCHER_SCRIPT"
  run mkdir -p "$dir"
  {
    printf '#!/bin/sh\n'
    printf '# Generated by appfork %s - regenerate with the tool instead of editing.\n' "$APC_VERSION"
    printf 'exec %s %s\n' "$(sh_quote "$SOURCE")" "$(build_exec_args)"
  } | write_file "$LAUNCHER_SCRIPT" 755
  track_path file "$LAUNCHER_SCRIPT"

  ICON_COPY=""
  if [ "$ICON_MODE" = custom ]; then
    ext=$(lower "${CUSTOM_ICON##*.}")
    ICON_COPY="$icondir/$SLUG.$ext"
    stash_existing "$ICON_COPY"
    run mkdir -p "$icondir"
    run cp -- "$CUSTOM_ICON" "$ICON_COPY"
    track_path file "$ICON_COPY"
  fi
  if [ ! -e "$PROFILE_DIR" ]; then
    run mkdir -p "$PROFILE_DIR"
    track_path rmdir "$PROFILE_DIR"
  fi
}

create_linux_desktop_entry() {
  local icon cats comment appdir
  appdir=$(dirname -- "$DESKTOP_ENTRY")
  case "$ICON_MODE" in
    custom) icon="$ICON_COPY" ;;
    original) icon="${SRC_DESKTOP_ICON:-application-x-executable}" ;;
    *) icon="application-x-executable" ;;
  esac
  cats="${SRC_DESKTOP_CATEGORIES:-Utility;}"
  case "$cats" in *\;) : ;; *) cats="$cats;" ;; esac
  comment="Isolated instance of $SRC_APPNAME (profile: $PROFILE_DIR)"
  stash_existing "$DESKTOP_ENTRY"
  run mkdir -p "$appdir"
  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Version=1.0\n'
    printf 'Name=%s\n' "$INSTANCE_NAME"
    printf 'Comment=%s\n' "$comment"
    printf 'Exec=%s\n' "$(exec_field_quote "$LAUNCHER_SCRIPT")"
    printf 'Icon=%s\n' "$icon"
    printf 'Terminal=false\n'
    printf 'Categories=%s\n' "$cats"
    printf 'StartupNotify=true\n'
    printf 'X-Appfork=true\n'
  } | write_file "$DESKTOP_ENTRY" 644
  track_path file "$DESKTOP_ENTRY"
  if [ "$DRY_RUN" != 1 ] && have update-desktop-database; then
    update-desktop-database "$appdir" >/dev/null 2>&1 || true
  fi
}

# --------------------------------------------------------------------------
# Plan / summary
# --------------------------------------------------------------------------
show_plan() {
  if [ "$QUIET" = 1 ]; then return 0; fi
  printf '\n%sPlan%s\n' "$C_BOLD" "$C_RESET"
  printf '  %-14s %s\n' "Source:" "$(tildify "$SOURCE")"
  printf '  %-14s %s\n' "Instance:" "$INSTANCE_NAME"
  if [ "$PLATFORM" = macos ]; then
    printf '  %-14s %s\n' "Application:" "$(tildify "$DEST_APP")"
    printf '  %-14s %s\n' "Launcher:" "$(tildify "$LAUNCHER_APP")"
    printf '  %-14s %s\n' "Bundle ID:" "$BUNDLE_ID"
  else
    printf '  %-14s %s\n' "Launcher:" "$(tildify "$LAUNCHER_SCRIPT")"
    printf '  %-14s %s\n' "Desktop entry:" "$(tildify "$DESKTOP_ENTRY")"
  fi
  printf '  %-14s %s\n' "Profile:" "$(tildify "$PROFILE_DIR")"
  printf '  %-14s %s\n' "Arguments:" "$(build_exec_args)"
  printf '  %-14s %s\n' "Icon:" "$ICON_MODE"
  if [ -n "$CONFLICT_ACTION" ]; then printf '  %-14s %s\n' "Existing:" "$CONFLICT_ACTION (profile data is kept)"; fi
  if [ "$PLATFORM" = macos ]; then
    printf '\n%sAbout signing:%s editing Info.plist invalidates the original code signature, so the copy is\nre-signed ad-hoc ("codesign --force --deep --sign -"). This does not use a developer\nidentity; it only lets macOS run the modified copy. The original app is never touched.\n' "$C_DIM" "$C_RESET"
  fi
  printf '\n'
}

print_summary() {
  local launch
  if [ "$QUIET" = 1 ]; then
    if [ "$PLATFORM" = macos ]; then printf '%s\n' "$LAUNCHER_APP"; else printf '%s\n' "$DESKTOP_ENTRY"; fi
    return 0
  fi
  printf '\n'
  if [ "$DRY_RUN" = 1 ]; then
    box "DRY RUN" "Nothing was changed"
    return 0
  fi
  box "SUCCESS"
  printf '%sInstance:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$INSTANCE_NAME"
  if [ "$PLATFORM" = macos ]; then
    printf '%sApplication:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$DEST_APP"
    printf '%sLauncher:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$LAUNCHER_APP"
    printf '%sProfile:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$(tildify "$PROFILE_DIR")"
    printf '%sBundle ID:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$BUNDLE_ID"
    launch="open $(sh_quote "$LAUNCHER_APP")"
    printf '%sLaunch command:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$launch"
  else
    printf '%sLauncher:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$LAUNCHER_SCRIPT"
    printf '%sDesktop entry:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$DESKTOP_ENTRY"
    printf '%sProfile:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$(tildify "$PROFILE_DIR")"
    printf '%sLaunch command:%s\n  %s\n\n' "$C_BOLD" "$C_RESET" "$(sh_quote "$LAUNCHER_SCRIPT")"
  fi
  if [ "$PLATFORM" = macos ]; then
    printf 'The original application was not modified.\n'
  else
    printf 'The original application was not modified. It may take a moment for the menu entry to appear.\n'
  fi
}

launch_test() {
  local i=0
  if [ "$DRY_RUN" = 1 ]; then log_dry "launch the launcher to test it"; return 0; fi
  log_info "Launching to test (the application will stay open)..."
  open "$LAUNCHER_APP" || { log_warn "Could not launch the launcher."; return 0; }
  while [ "$i" -lt 10 ]; do
    sleep 1
    if is_running "$DEST_APP/Contents/MacOS/"; then
      log_ok "The application is running with its separate profile."
      return 0
    fi
    i=$((i + 1))
  done
  log_warn "The application did not appear within 10 seconds."
  say "      Check that it supports '$RUNTIME_ARG', and try: open $(sh_quote "$LAUNCHER_APP")"
}

# --------------------------------------------------------------------------
# Top-level flows
# --------------------------------------------------------------------------
perform_macos() {
  STEP_N=0; STEP_TOTAL=7
  step_begin "Copying application";      clone_macos_app;        step_end
  step_begin "Updating application ID";  modify_macos_plist id;  step_end
  step_begin "Updating display name";    modify_macos_plist name; step_end
  step_begin "Copying icon";             apply_macos_icon;       step_end
  step_begin "Creating launcher";        create_macos_launcher;  step_end
  step_begin "Signing application";      sign_macos_app;         step_end
  step_begin "Validating installation";  validate_instance; register_instance; step_end
}

perform_linux() {
  STEP_N=0; STEP_TOTAL=5
  step_begin "Checking executable"
  if [ ! -x "$SOURCE" ]; then die "Executable disappeared: $SOURCE"; fi
  step_end
  step_begin "Preparing profile";        :;                      step_end
  step_begin "Creating launcher";        create_linux_launcher;  step_end
  step_begin "Creating desktop entry";   create_linux_desktop_entry; step_end
  step_begin "Validating installation";  validate_instance; register_instance; step_end
}

pre_flight_running_checks() {
  if [ "$PLATFORM" = macos ]; then
    if [ -n "$FOUND_APP" ] && is_running "$FOUND_APP/Contents/MacOS/"; then
      die "'$INSTANCE_NAME' is currently running." "Quit it first, then run the tool again."
    fi
    if is_running "$SOURCE/Contents/MacOS/"; then
      log_info "The source application is running; copying it is safe, the original is only read."
    fi
  fi
}

create_flow() {
  local sel
  if [ "$HEADER_DONE" != 1 ]; then print_header; fi
  say "Platform: $PLATFORM_LABEL"
  say ""
  check_prerequisites

  ask_source_app
  ask_instance_name

  if [ "$PLATFORM" = macos ]; then
    generate_bundle_id
    if [ -n "$DEST_DIR" ]; then DEST_DIR_EXPLICIT=1; choose_dest_dir; fi
  fi
  check_duplicates
  if [ "$PLATFORM" = macos ]; then
    choose_dest_dir
    if [ ! -w "$DEST_DIR" ] && [ -n "$FOUND_APP" ]; then
      die "Cannot modify the existing instance in $DEST_DIR (not writable)." \
        "Fix the folder permissions or remove the old instance manually. This tool never uses sudo."
    fi
    DEST_APP="$DEST_DIR/$INSTANCE_NAME.app"
    LAUNCHER_APP="$DEST_DIR/$INSTANCE_NAME Launcher.app"
    case "$DEST_APP$LAUNCHER_APP" in *"|"*) die "Destination path contains '|', which is not supported." ;; esac
  fi

  if reuse_all_stored; then
    ask_profile_directory
  else
    ask_profile_directory
    ask_runtime_arguments
    ask_icon_options
  fi
  # replace-app: stored values are used; fill in anything still missing defensively.
  if [ -z "$RUNTIME_ARG" ]; then ask_runtime_arguments; fi
  if [ -z "$ICON_MODE" ]; then ask_icon_options; fi
  if [ -z "$ARG_STYLE" ]; then ARG_STYLE="equals"; fi

  if [ "$PLATFORM" = macos ]; then
    if [ -z "$WANT_DOCK" ]; then
      if is_interactive && have defaults; then
        if confirm "Add launcher to Dock?" Y; then WANT_DOCK=yes; else WANT_DOCK=no; fi
      else
        WANT_DOCK=no
      fi
    fi
  fi

  validate_input
  pre_flight_running_checks
  show_plan
  if is_interactive && [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    if ! confirm "Proceed?" Y; then die "Aborted; nothing was changed."; fi
  fi

  say "Creating profile..."
  say ""
  if [ "$PLATFORM" = macos ]; then perform_macos; else perform_linux; fi

  # Everything worked: drop backups, then (only if confirmed) delete the old profile.
  SUCCESS=1
  discard_backups
  if [ "$PROFILE_DELETE_CONFIRMED" = 1 ]; then
    log_info "Deleting old profile as confirmed: $OLD_PROFILE"
    safe_rm_rf "$OLD_PROFILE" || log_warn "Profile was not deleted."
  fi

  say ""
  say "Done!"
  print_summary
  if [ "$PLATFORM" = macos ] && [ "$DRY_RUN" != 1 ]; then
    if [ "$WANT_DOCK" = yes ]; then
      add_launcher_to_dock
    else
      say "To pin it: drag \"$(tildify "$LAUNCHER_APP")\" to the Dock."
    fi
    if [ -z "$LAUNCH_TEST" ] && is_interactive; then
      if confirm "Launch it now to test?" N; then LAUNCH_TEST=yes; else LAUNCH_TEST=no; fi
    fi
    if [ "$LAUNCH_TEST" = yes ]; then launch_test; fi
  elif [ "$PLATFORM" = macos ]; then
    if [ "$WANT_DOCK" = yes ]; then add_launcher_to_dock; fi
  fi
  return 0
}

# ----- list -----
list_instances() {
  local dir="$CONFIG_DIR/instances" f n=0 st name plat target
  for f in "$dir"/*.meta; do
    if [ ! -f "$f" ]; then continue; fi
    if [ "$n" = 0 ]; then
      printf '%s%-26s %-7s %-8s %s%s\n' "$C_BOLD" "NAME" "OS" "STATUS" "PROFILE" "$C_RESET"
    fi
    n=$((n + 1))
    name=$(meta_get "$f" name)
    plat=$(meta_get "$f" platform)
    if [ "$plat" = macos ]; then
      target=$(meta_get "$f" app)
      if [ -d "$target" ] && [ -d "$(meta_get "$f" launcher)" ]; then st="ok"; else st="missing"; fi
    else
      target=$(meta_get "$f" desktop_entry)
      if [ -f "$target" ] && [ -f "$(meta_get "$f" launcher)" ]; then st="ok"; else st="missing"; fi
    fi
    printf '%-26s %-7s %-8s %s\n' "$name" "$plat" "$st" "$(tildify "$(meta_get "$f" profile)")"
    if [ "$VERBOSE" = 1 ]; then
      printf '    source:   %s\n    created:  %s\n    target:   %s\n    launcher: %s\n' \
        "$(meta_get "$f" source)" "$(meta_get "$f" created)" "$target" "$(meta_get "$f" launcher)"
    fi
  done
  if [ "$n" = 0 ]; then
    say "No instances created by $SCRIPT_NAME were found."
    say "(metadata directory: $CONFIG_DIR/instances)"
  fi
}

# ----- remove -----
# Let the user pick one of the instances created by this tool; prints its name.
pick_instance() { # verb (repair|remove)
  local verb="${1:-remove}" f n=0 names="" line sel
  for f in "$CONFIG_DIR"/instances/*.meta; do
    if [ ! -f "$f" ]; then continue; fi
    if [ -z "$names" ]; then names="$(meta_get "$f" name)"; else names="$names
$(meta_get "$f" name)"; fi
  done
  if [ -z "$names" ]; then die "No instances created by this tool were found." "Create one first (run without arguments)."; fi
  printf '\n%sSelect the instance to %s:%s\n\n' "$C_BOLD" "$verb" "$C_RESET" >&2
  while IFS= read -r line; do
    n=$((n + 1))
    printf '  %d) %s\n' "$n" "$line" >&2
  done <<EOF
$names
EOF
  while :; do
    sel=$(ask "Choice [1-$n]:")
    case "$sel" in ""|*[!0-9]*) continue ;; esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then break; fi
  done
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [ "$n" -eq "$sel" ]; then printf '%s' "$line"; return 0; fi
  done <<EOF
$names
EOF
}

# Repair = rebuild an existing instance (app + launcher + desktop entry) from the current
# original, keeping every stored setting and the profile data. Use it after the original
# app updated, or when an instance crashes/won't start.
repair_instance() {
  local slug f
  if [ -z "$REPAIR_TARGET" ]; then
    if ! is_interactive; then usage_error "--repair needs an instance name when not running in a terminal."; fi
    REPAIR_TARGET=$(pick_instance repair)
  fi
  slug=$(slugify "$REPAIR_TARGET")
  f=$(meta_file_for "$slug")
  if [ -z "$slug" ] || [ ! -f "$f" ]; then
    die "No instance named '$REPAIR_TARGET' was created by this tool." "Run '$SCRIPT_NAME --list' to see the known instances."
  fi
  if [ "$(meta_get "$f" platform)" != "$PLATFORM" ]; then
    die "'$REPAIR_TARGET' was created on $(meta_get "$f" platform); this machine is $PLATFORM."
  fi
  INSTANCE_NAME=$(meta_get "$f" name)
  if [ -z "$SOURCE" ]; then
    SOURCE=$(meta_get "$f" source)
    if [ ! -e "$SOURCE" ]; then
      log_warn "The original application is no longer at: $SOURCE"
      SOURCE=""
    fi
  fi
  ON_CONFLICT="replace-app"
  if [ -z "$WANT_DOCK" ]; then WANT_DOCK="no"; fi
  log_info "Repairing '$INSTANCE_NAME' (settings and profile data are kept)."
  create_flow
}

remove_instance() {
  local slug f name plat app launcher profile bid desk icon srcpath srcname actual ans
  if [ -z "$REMOVE_TARGET" ]; then
    if ! is_interactive; then usage_error "--remove needs an instance name when not running in a terminal."; fi
    REMOVE_TARGET=$(pick_instance remove)
  fi
  slug=$(slugify "$REMOVE_TARGET")
  f=$(meta_file_for "$slug")
  if [ -z "$slug" ] || [ ! -f "$f" ]; then
    die "No instance named '$REMOVE_TARGET' was created by this tool." "Run '$SCRIPT_NAME --list' to see the known instances."
  fi
  name=$(meta_get "$f" name)
  plat=$(meta_get "$f" platform)
  profile=$(meta_get "$f" profile)
  launcher=$(meta_get "$f" launcher)
  srcpath=$(meta_get "$f" source)
  if [ "$plat" != "$PLATFORM" ]; then
    die "'$name' was created on $plat; this machine is $PLATFORM." "Run the removal on the original platform."
  fi

  if [ "$HEADER_DONE" != 1 ]; then print_header; fi
  if [ "$PLATFORM" = macos ]; then
    app=$(meta_get "$f" app)
    bid=$(meta_get "$f" bundle_id)
    case "$app" in *.app) : ;; *) die "Recorded application path looks wrong: $app" "Edit/remove $f manually." ;; esac
    case "$launcher" in *.app) : ;; *) die "Recorded launcher path looks wrong: $launcher" "Edit/remove $f manually." ;; esac
    if [ -d "$app" ]; then
      actual=$(plist_get "$app/Contents/Info.plist" CFBundleIdentifier || true)
      if [ "$actual" != "$bid" ]; then
        die "$app does not have the recorded bundle identifier ($bid); refusing to delete it." \
          "It may have been replaced by something else. Remove it manually if you are sure."
      fi
      if is_running "$app/Contents/MacOS/"; then die "'$name' is running." "Quit it first."; fi
    fi
    say "This will remove:"
    say "  Application: $(tildify "$app")"
    say "  Launcher:    $(tildify "$launcher")"
  else
    desk=$(meta_get "$f" desktop_entry)
    icon=$(meta_get "$f" icon_copy)
    say "This will remove:"
    say "  Desktop entry: $(tildify "$desk")"
    say "  Launcher:      $(tildify "$launcher")"
    if [ -n "$icon" ]; then say "  Icon copy:     $(tildify "$icon")"; fi
    if is_running "$profile"; then die "'$name' appears to be running." "Quit it first."; fi
  fi
  say "  Metadata:    $(tildify "$f")  (a backup copy is kept)"
  say ""
  say "The profile (your data) is NOT removed unless you explicitly confirm:"
  say "  $(tildify "$profile")"

  if ! confirm "Remove instance '$name'?" N; then
    if is_interactive; then die "Aborted; nothing was removed."; fi
    die "Confirmation required." "Pass --yes to remove without prompting."
  fi

  if [ "$PLATFORM" = macos ]; then
    safe_rm_rf "$app" ".app" || die "Could not remove $app" "Remove it manually."
    safe_rm_rf "$launcher" ".app" || die "Could not remove $launcher" "Remove it manually."
  else
    if [ -e "$desk" ]; then run rm -f -- "$desk"; fi
    if [ -e "$launcher" ]; then run rm -f -- "$launcher"; fi
    if [ -n "$icon" ] && [ -e "$icon" ]; then run rm -f -- "$icon"; fi
    if [ "$DRY_RUN" != 1 ] && have update-desktop-database; then
      update-desktop-database "$(dirname -- "$desk")" >/dev/null 2>&1 || true
    fi
  fi

  # Profile: only after an explicit confirmation.
  if [ -d "$profile" ]; then
    srcname=$(basename -- "$srcpath" .app)
    if [ "$PLATFORM" = macos ] && [ "$profile" = "$HOME/Library/Application Support/$srcname" ]; then
      log_warn "The recorded profile is the ORIGINAL application's data directory; it will not be deleted."
    elif confirm_delete_profile "$profile"; then
      safe_rm_rf "$profile" || log_warn "Profile was not deleted."
      log_ok "Profile deleted."
    else
      log_info "Profile kept: $(tildify "$profile")"
    fi
  fi

  run mkdir -p "$CONFIG_DIR/backups"
  ans=$(date +%Y%m%d%H%M%S)
  run mv -- "$f" "$CONFIG_DIR/backups/$slug.meta.removed.$ans"
  log_ok "Instance '$name' removed."
  if [ "$PLATFORM" = macos ]; then
    say "If you pinned the launcher to the Dock, remove it: right-click it > Options > Remove from Dock."
  fi
}

# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
print_usage() {
  cat <<EOF
$SCRIPT_NAME $APC_VERSION - create isolated instances/profiles of desktop applications

USAGE
  $SCRIPT_NAME                          interactive menu: create / repair / remove / list
  $SCRIPT_NAME [options]                (non-interactive when all required options are given)
  $SCRIPT_NAME --list                   list instances created by this tool
  $SCRIPT_NAME --repair ["NAME"]        rebuild an instance from the current original (keeps settings + profile)
  $SCRIPT_NAME --remove ["NAME"]        remove an instance; without NAME pick from a list
                                        (the profile is only deleted after explicit confirmation)

REQUIRED FOR NON-INTERACTIVE USE
  --source PATH         macOS: the source .app bundle      Linux: the executable (path or command)
  --name NAME           name of the new application / launcher
  --profile NAME|PATH   profile directory name, or an absolute path
  --arg ARG             the application's option that sets its data dir (e.g. --user-data-dir)

OPTIONS
  --arg-style STYLE     'equals' (--arg=DIR, default) or 'separate' (--arg DIR)
  --extra ARG           additional launch argument (repeatable)
  --icon PATH           custom icon (.icns on macOS; .png/.svg/.xpm on Linux)
  --no-icon             do not use any icon (generic)
  --desktop-file PATH   Linux: .desktop file of the original app (name/icon/categories are reused)
  --dest-dir DIR        macOS: install into DIR instead of /Applications
  --dock / --no-dock    macOS: add the launcher to the Dock (append only) or not
  --launch-test         macOS: launch the new instance once and check that it starts
  --on-conflict MODE    if the instance exists: abort (default) | reconfigure | replace-app | recreate
  --delete-profile      allow deletion of profile data (with --remove, or --on-conflict recreate)
  -y, --yes             answer 'yes' to y/N questions (never skips the DELETE confirmation)
  --no-input            never prompt; fail when something is missing
  -n, --dry-run         show what would happen without changing anything
  -v, --verbose         show every step
  -q, --quiet           only print errors (and the result path)
  --no-color            disable ANSI colors (also honours NO_COLOR and non-tty output)
  -h, --help            show this help
  --version             show the version

NOTE
  The target application must support a command-line option that relocates its
  user data (Electron/Chromium: --user-data-dir). Without one, the instance will
  share (or fight over) the original data. Nothing here can change that.

EXAMPLES
  $SCRIPT_NAME --source /Applications/Claude.app --name "Claude Work" \\
      --profile Claude-Work --arg --user-data-dir
  $SCRIPT_NAME --dry-run --source /Applications/Discord.app --name "Discord Work" \\
      --profile Discord-Work --arg --user-data-dir --arg-style equals
  $SCRIPT_NAME --source /usr/bin/chromium --name "Chromium Work" --profile chromium-work \\
      --arg --user-data-dir
EOF
}

parse_args() {
  local opt val has_val
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) opt="${1%%=*}"; val="${1#*=}"; has_val=1 ;;
      *) opt="$1"; val=""; has_val=0 ;;
    esac
    case "$opt" in
      --remove)
        MODE="remove"
        if [ "$has_val" = 1 ]; then
          REMOVE_TARGET="$val"
        elif [ $# -ge 2 ]; then
          case "$2" in -*) : ;; *) REMOVE_TARGET="$2"; shift ;; esac
        fi
        ;;
      --repair)
        MODE="repair"
        if [ "$has_val" = 1 ]; then
          REPAIR_TARGET="$val"
        elif [ $# -ge 2 ]; then
          case "$2" in -*) : ;; *) REPAIR_TARGET="$2"; shift ;; esac
        fi
        ;;
      --source|--name|--profile|--arg|--arg-style|--extra|--icon|--desktop-file|--dest-dir|--on-conflict)
        if [ "$has_val" = 0 ]; then
          if [ $# -lt 2 ]; then usage_error "Option $opt requires a value."; fi
          val="$2"
          shift
        fi
        case "$opt" in
          --source) SOURCE="$val" ;;
          --name) INSTANCE_NAME="$val" ;;
          --profile) PROFILE_INPUT="$val" ;;
          --arg) RUNTIME_ARG="$val" ;;
          --arg-style)
            case "$val" in separate|equals) ARG_STYLE="$val" ;; *) usage_error "--arg-style must be 'separate' or 'equals'." ;; esac
            ;;
          --extra) add_extra_arg "$val"; EXTRA_ASKED=1 ;;
          --icon) CUSTOM_ICON="$val" ;;
          --desktop-file) DESKTOP_SRC="$val" ;;
          --dest-dir) DEST_DIR="$val" ;;
          --on-conflict)
            case "$val" in abort|reconfigure|replace-app|recreate) ON_CONFLICT="$val" ;; *) usage_error "--on-conflict must be abort, reconfigure, replace-app or recreate." ;; esac
            ;;
        esac
        ;;
      -h|--help) MODE="help" ;;
      --version) MODE="version" ;;
      --list) MODE="list" ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      -q|--quiet) QUIET=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --no-input) NO_INPUT=1 ;;
      --no-color) COLOR_MODE="never" ;;
      --no-icon) ICON_MODE="none" ;;
      --dock) WANT_DOCK="yes" ;;
      --no-dock) WANT_DOCK="no" ;;
      --launch-test) LAUNCH_TEST="yes" ;;
      --delete-profile) DELETE_PROFILE=1 ;;
      *) usage_error "Unknown option: $1" ;;
    esac
    shift
  done
  if [ "$VERBOSE" = 1 ] && [ "$QUIET" = 1 ]; then usage_error "--verbose and --quiet cannot be combined."; fi
}

# One-time move of metadata written under the tool's former name (app-profile-cloner).
migrate_legacy_config() {
  if [ -n "${APPFORK_CONFIG_DIR:-}" ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  if [ -d "$LEGACY_CONFIG_DIR/instances" ] && [ ! -e "$CONFIG_DIR" ]; then
    if mv -- "$LEGACY_CONFIG_DIR" "$CONFIG_DIR"; then
      log_info "Migrated instance metadata to $(tildify "$CONFIG_DIR")"
    else
      log_warn "Could not migrate $LEGACY_CONFIG_DIR to $CONFIG_DIR; existing instances will not be listed."
    fi
  fi
}

main() {
  local argc=$#
  setup_output
  parse_args "$@"
  setup_output
  case "$MODE" in
    help) print_usage; exit 0 ;;
    version) printf '%s %s\n' "$SCRIPT_NAME" "$APC_VERSION"; exit 0 ;;
  esac

  trap cleanup_on_failure EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  detect_platform
  migrate_legacy_config
  if [ "$argc" -eq 0 ] && is_interactive; then
    print_header
    case "$(choose "What would you like to do?" "Create a new isolated instance" "Repair an instance (rebuild it, keep the profile)" "Remove an instance" "List instances")" in
      2) MODE="repair" ;;
      3) MODE="remove" ;;
      4) MODE="list" ;;
    esac
    HEADER_DONE=1
  fi
  case "$MODE" in
    list) list_instances ;;
    remove) check_prerequisites; remove_instance ;;
    repair) repair_instance ;;
    create) create_flow ;;
  esac
  SUCCESS=1
}

main "$@"
