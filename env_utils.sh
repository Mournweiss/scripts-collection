#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Maxim Selin (Mournweiss) <info@mournweiss.ru>
#
# SPDX-License-Identifier: Apache-2.0

# Environment Utilities
#
# Provides functions for .env file management:
#   - read_env          : Read variables from a .env file
#   - make_env          : Create .env from template or sync existing
#   - set_env           : Export all variables from .env to current context
#

# Read environment variables from file and return them as a space-separated string
#
# Parameters:
# - $@: array - command-line arguments for specifying file and variables
#   --file|-f <file>: specify the environment file to read (default: .env)
#   --value|-v: return only values, not key=value pairs
#   other args: specific variable names to read (comma-separated)
#
# Returns:
# - string: space-separated environment variables in key=value format or just values if --value flag is used
read_env() {
    local env_file=""
    local vars_to_read=()
    local value_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --value|-v)
                value_only=true
                shift
                ;;
            --file|-f)
                if [[ -n "${2:-}" && "$2" != "--"* ]]; then
                    env_file="$2"
                    shift 2
                else
                    error "Missing file argument for --file flag"
                fi
                ;;
            --file=*)
                env_file="${1#*=}"
                shift
                ;;
            *)
                if [[ -n "$env_file" ]]; then
                    IFS=',' read -ra vars <<< "$1"
                    for var in "${vars[@]}"; do
                        vars_to_read+=("$var")
                    done
                else
                    env_file="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$env_file" ]]; then
        env_file=".env"
    fi

    if [[ ! -f "$env_file" ]]; then
        info "Environment file $env_file not found"
        return 1
    fi

    local env_args=""

    # Read and process each line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract variable name and value
        local var_name="${line%%=*}"
        local var_value="${line#*=}"

        # Remove trailing comments and trim whitespace
        var_value="${var_value%%#*}"
        var_name="$(echo "$var_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        var_value="$(echo "$var_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Skip if variable name is empty
        [[ -z "$var_name" ]] && continue

        # If specific variables are requested, check if this one matches
        if [[ ${#vars_to_read[@]} -gt 0 ]]; then
            local found=false
            for var in "${vars_to_read[@]}"; do
                if [[ "$var" == "$var_name" ]]; then
                    found=true
                    break
                fi
            done
            [[ "$found" == false ]] && continue
        fi

        # Handle output format based on value_only flag
        if [[ "$value_only" == true ]]; then
            echo "$var_value"
        else
            # Return key=value pairs
            if [[ -n "$env_args" ]]; then
                env_args="$env_args $var_name=$var_value"
            else
                env_args="$var_name=$var_value"
            fi
        fi
    done < "$env_file"

    # Output all variables
    if [[ "$value_only" == false ]]; then
        echo "$env_args"
    fi
}

# Creates .env from template with environment-specific overrides.
#
# Reads base variables from .env.example, applies overrides from envs/<env>.env,
# and writes the merged result to .env. If .env already exists, merges overrides
# into it while preserving any local-only variables.
#
# Parameters:
# - env_name: string - environment name (dev, test, prod). Default: "dev"
# - template_file: string - path to the template .env file (e.g., .env.example)
#
# Returns:
# - None
make_env() {
    local env_name="${1:-dev}"
    local template_file="${2:-.env.example}"
    local env_override_file="$PROJECT_ROOT/envs/${env_name}.env"

    [[ -f "$template_file" ]] || error "No template file found: $template_file"

    # Step 1: Load overrides into associative array using read_env
    declare -A overrides
    if [[ -f "$env_override_file" ]]; then
        info "Loading overrides from: $env_override_file"
        local override_raw
        override_raw=$(read_env -f "$env_override_file")
        for ov in $override_raw; do
            [[ -z "$ov" ]] && continue
            local ov_name="${ov%%=*}"
            overrides["$ov_name"]="${ov#*=}"
        done
    else
        warn "No override file found for '$env_name' at $env_override_file"
    fi

    # Step 2: Read base variables from template using read_env
    local base_vars
    base_vars=$(read_env -f "$template_file")

    # Step 3: Process each base variable, applying overrides
    local merged_vars=""
    local first=true
    for bv in $base_vars; do
        [[ -z "$bv" ]] && continue
        local bv_name="${bv%%=*}"

        if [[ -n "${overrides[$bv_name]+x}" ]]; then
            bv="$bv_name=${overrides[$bv_name]}"
        fi

        if [[ "$first" == true ]]; then
            merged_vars="$bv"
            first=false
        else
            merged_vars="$merged_vars $bv"
        fi
    done

    # Step 4: Write merged result to .env
    if [[ -f .env ]]; then
        info "Updating existing .env with $env_name overrides..."
    else
        info "Creating .env from $template_file with $env_name overrides..."
    fi
    echo "$merged_vars" | tr ' ' '\n' > .env

    success "Environment '$env_name' configured successfully"
}

# Read and export environment variables into current context.
#
# Parameters:
# - env_file: string (optional) - path to the .env file to export from (default: .env)
#
# Returns:
# - None
set_env() {
    local env_file="${1:-.env}"
    local env_args
    env_args=$(read_env -f "$env_file")

    # Export all variables to current context
    if [[ -n "$env_args" ]]; then
        export $env_args
    fi
}