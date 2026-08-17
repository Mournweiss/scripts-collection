#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Maxim Selin (Mournweiss) <info@mournweiss.ru>
#
# SPDX-License-Identifier: Apache-2.0

# Git Submodules Management Utility
#
# Provides functions for managing git submodules:
#   - has_submodules    : Check if the current repository has submodules
#   - list_submodules   : List all connected submodules with their status
#   - update_submodules : Recursively check and update all submodules

set -euo pipefail

# Load shell utilities for logging
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shell_utils.sh"

# Check if the current repository has git submodules.
#
# Parameters:
#   None
#
# Returns:
#   0 (true) if submodules exist, 1 (false) otherwise
has_submodules() {
    if [[ -f ".gitmodules" ]]; then
        return 0
    else
        return 1
    fi
}

# List all connected git submodules with their status.
#
# Parameters:
#   None
#
# Returns:
#   0 on success, 1 if no submodules found
list_submodules() {
    if ! has_submodules; then
        warn "No git submodules found in the current repository"
        return 1
    fi

    info "Listing git submodules:"
    git submodule status 2>/dev/null || {
        error "Failed to list submodules. Make sure you are in a git repository."
    }
}

# Recursively check for updates in all git submodules and update them.
#
# Checks each submodule for new commits on the remote, pulls updates if available,
# and performs a recursive git submodule update with merge strategy.
#
# Parameters:
#   $1: branch (optional) - branch name to update submodules to (default: main or master)
#
# Returns:
#   0 on success, 1 if any errors occurred
update_submodules() {
    local branch="${1:-}"
    local has_updates=false
    local update_failed=false

    if ! has_submodules; then
        warn "No git submodules found in the current repository"
        return 0
    fi

    # Determine default branch name
    if [[ -z "$branch" ]]; then
        branch="main"
        if git rev-parse --verify "origin/master" &>/dev/null; then
            branch="master"
        fi
    fi

    info "Checking for submodule updates on branch: $branch"

    # Check each submodule for remote updates
    local submodule_paths
    submodule_paths=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

    if [[ -z "$submodule_paths" ]]; then
        warn "No submodule paths found in .gitmodules"
        return 0
    fi

    for path in $submodule_paths; do
        if [[ ! -d "$path" ]]; then
            warn "Submodule directory not found: $path (may not be initialized)"
            continue
        fi

        # Check if there are new commits on the remote
        if git -C "$path" fetch origin &>/dev/null; then
            local local_head remote_head
            local_head=$(git -C "$path" rev-parse HEAD 2>/dev/null)
            remote_head=$(git -C "$path" rev-parse "origin/$branch" 2>/dev/null)

            if [[ -n "$remote_head" && "$local_head" != "$remote_head" ]]; then
                info "Update available for submodule: $path"
                has_updates=true
            else
                info "Up to date: $path"
            fi
        else
            warn "Failed to fetch remote for submodule: $path"
        fi
    done

    # Perform recursive update with merge
    if [[ "$has_updates" == true ]]; then
        info "Performing recursive submodule update with merge..."
        if git submodule update --recursive --merge 2>/dev/null; then
            success "Submodules updated successfully"
        else
            warn "Some submodules failed to update. Check output above for details."
            update_failed=true
        fi
    else
        info "No updates available for any submodule"
    fi

    if [[ "$update_failed" == true ]]; then
        return 1
    fi
    return 0
}

# If this script is executed directly (not sourced), run update_submodules
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    update_submodules "${1:-}"
fi
