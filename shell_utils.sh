#!/usr/bin/env bash

# ANSI color codes
COLOR_INFO="\033[0m"       # White (default)
COLOR_WARN="\033[1;33m"    # Yellow
COLOR_ERROR="\033[1;31m"   # Red
COLOR_SUCCESS="\033[1;32m" # Green
COLOR_RESET="\033[0m"

# Timestamp format: [YYYY-MM-DD HH:MM:SS]
_timestamp() {
    date '+[%Y-%m-%d %H:%M:%S]'
}

info()    { echo -e "$(_timestamp) ${COLOR_INFO}[INFO]${COLOR_RESET} $1" >&2; }
warn()    { echo -e "$(_timestamp) ${COLOR_WARN}[WARN]${COLOR_RESET} $1" >&2; }
error()   { echo -e "$(_timestamp) ${COLOR_ERROR}[ERROR]${COLOR_RESET} $1" >&2; exit 1; }
success() { echo -e "$(_timestamp) ${COLOR_SUCCESS}[OK]${COLOR_RESET} $1" >&2; }