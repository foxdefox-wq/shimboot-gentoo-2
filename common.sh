#!/bin/bash

# common.sh - Shared utilities for shimboot-gentoo-2
# Max verbosity, max debug output

set -e
if [ "$DEBUG" ]; then
  set -x
  export DEBUG=1
fi

# ─── ANSI Colors ──────────────────────────────────────────────────────────────
ANSI_CLEAR='\033[0m'
ANSI_BOLD='\033[1m'
ANSI_RED='\033[1;31m'
ANSI_GREEN='\033[1;32m'
ANSI_YELLOW='\033[1;33m'
ANSI_BLUE='\033[1;34m'
ANSI_CYAN='\033[1;36m'

# ─── Logging helpers ──────────────────────────────────────────────────────────
print_title() {
  printf "\n${ANSI_GREEN}════════════════════════════════════════════════════════${ANSI_CLEAR}\n"
  printf "${ANSI_GREEN}  >> ${1}${ANSI_CLEAR}\n"
  printf "${ANSI_GREEN}════════════════════════════════════════════════════════${ANSI_CLEAR}\n\n"
}

print_info() {
  printf "${ANSI_BOLD}[INFO]  ${1}${ANSI_CLEAR}\n"
}

print_warn() {
  printf "${ANSI_YELLOW}[WARN]  ${1}${ANSI_CLEAR}\n" >&2
}

print_error() {
  printf "${ANSI_RED}[ERROR] ${1}${ANSI_CLEAR}\n" >&2
}

print_debug() {
  if [ "$DEBUG" ] || [ "$VERBOSE" ]; then
    printf "${ANSI_CYAN}[DEBUG] ${1}${ANSI_CLEAR}\n"
  fi
}

print_step() {
  printf "\n${ANSI_BLUE}  ---> ${1}${ANSI_CLEAR}\n"
}

print_ts() {
  printf "${ANSI_BOLD}[$(date '+%H:%M:%S')] ${1}${ANSI_CLEAR}\n"
}

# ─── Dependency checking ───────────────────────────────────────────────────────
check_deps() {
  local needed_commands="$1"
  local missing=""
  for cmd in $needed_commands; do
    if ! command -v "$cmd" &>/dev/null; then
      missing="$missing\n  - $cmd"
    else
      print_debug "dep OK: $cmd -> $(command -v "$cmd")"
    fi
  done
  printf "%b" "$missing"
}

assert_deps() {
  local needed_commands="$1"
  print_step "Checking required dependencies: $needed_commands"
  local missing_commands
  missing_commands="$(check_deps "$needed_commands")"
  if [ -n "${missing_commands}" ]; then
    print_error "Missing dependencies required for this script:"
    printf "${ANSI_RED}%b${ANSI_CLEAR}\n" "${missing_commands}" >&2
    print_error "Please install the above commands and re-run."
    exit 1
  fi
  print_info "All dependencies satisfied."
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  declare -g -A args
  for argument in "$@"; do
    if [ "$argument" = "-h" ] || [ "$argument" = "--help" ]; then
      print_help
      exit 0
    fi

    local key
    key=$(echo "$argument" | cut -f1 -d=)
    local key_length=${#key}
    local value="${argument:$key_length+1}"
    args["$key"]="$value"
    print_debug "arg: $key = '$value'"
  done
}

assert_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (got EUID=$EUID)."
    exit 1
  fi
  print_debug "Running as root: OK"
}

assert_args() {
  if [ -z "$1" ]; then
    print_error "Required positional argument missing."
    print_help
    exit 1
  fi
}

# ─── Error trap ───────────────────────────────────────────────────────────────
# Prints a clean error report when a script exits due to 'set -e'.
# Only call this ONCE from the top-level script — not from sourced files.
setup_error_trap() {
  # Use EXIT trap rather than ERR so we only get one report per script,
  # not one per subshell / command substitution.
  # We stash the script name so the handler knows which file failed.
  _SHIMBOOT_SCRIPT="${BASH_SOURCE[1]:-$0}"

  trap '_shimboot_exit_handler $? "$_SHIMBOOT_SCRIPT"' EXIT
}

_shimboot_exit_handler() {
  local exit_code="$1"
  local script="$2"

  # Exit code 0 = success, 130 = Ctrl-C — don't report those as errors
  if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 130 ]; then
    return
  fi

  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  print_error "FATAL ERROR — script exited with code $exit_code"
  print_error "  Script : $script"
  print_error "  Hint   : Run with DEBUG=1 for full trace:"
  print_error "           sudo DEBUG=1 $script"
  print_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
