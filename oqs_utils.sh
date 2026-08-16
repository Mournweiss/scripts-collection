#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Maxim Selin (Mournweiss) <info@mournweiss.ru>
#
# SPDX-License-Identifier: Apache-2.0

# oqs-utils: Post-Quantum Cryptography Utility
#
# Provides a simplified interface to the ghcr.io/mournweiss/oqs-openssl image
# for generating post-quantum keys, certificates, and KEM secrets.
#
# Usage:
#   ./oqs-utils.sh <command> [OPTIONS]
#
# Commands:
#   kem-generate        Generate KEM key (keypair or single private)
#   sig-generate        Generate signature key (keypair or single private)
#   cert-generate       Generate X.509 certificate with PQ algorithm
#   kem-encaps          Encapsulate shared secret for KEM
#   list-algorithms     List all available PQ algorithms
#   list-kems           List available KEM algorithms
#   list-sigs           List available signature algorithms
#   help                Show this help message
#
# Examples:
#   ./oqs-utils.sh kem-generate --algorithm mlkem768
#   ./oqs-utils.sh sig-generate --algorithm mldsa65 --output-dir ./keys
#   ./oqs-utils.sh cert-generate --algorithm mldsa87 --cn "My PQ CA" --days 730
#   ./oqs-utils.sh kem-encaps --algorithm mlkem768
#   ./oqs-utils.sh list-kems
#   ./oqs-utils.sh list-sigs
#
# Environment Variables:
#   OQS_ALGORITHM           PQ algorithm (default: mlkem768)
#   OQS_OUTPUT_DIR          Output directory (default: /tmp/)
#   OQS_PREFIX              File prefix (default: oqs)
#   OQS_MODE                Generation mode: keypair, single (default: keypair)
#   OQS_KEY_FORMAT          Key format for single mode: pem, der (default: pem)
#   OQS_KEY_TYPE            Key type: kem or sig (default: kem)
#   OQS_DAYS                Certificate validity (default: 365)
#   OQS_CN                  Common Name (default: OQS Test)
#   OQS_CONTAINER_IMAGE     Container image (default: ghcr.io/mournweiss/oqs-openssl:latest-alpine)
#   OQS_CONTAINER_ENGINE    Container engine: docker/podman (default: auto-detect)
#   OQS_CONTAINER_RUN_OPTS  Additional container run options
#   OQS_VERBOSE             Enable verbose output (default: false)
#   CONTAINER_ENGINE        Global container engine override
#

set -euo pipefail

# Load shell utilities for logging
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shell_utils.sh"

# Constants
DEFAULT_CONTAINER_IMAGE="ghcr.io/mournweiss/oqs-openssl:latest-alpine"
DEFAULT_OUTPUT_DIR="/tmp"
DEFAULT_PREFIX="oqs"
DEFAULT_ALGORITHM="mlkem768"
DEFAULT_MODE="keypair"
DEFAULT_KEY_FORMAT="pem"
DEFAULT_KEY_TYPE="kem"
DEFAULT_DAYS="365"
DEFAULT_CN="OQS Test"
DEFAULT_CONTAINER_ENGINE="docker"

# Variables
CONTAINER_ENGINE="${OQS_CONTAINER_ENGINE:-${CONTAINER_ENGINE:-$DEFAULT_CONTAINER_ENGINE}}"
CONTAINER_IMAGE="${OQS_CONTAINER_IMAGE:-$DEFAULT_CONTAINER_IMAGE}"
OUTPUT_DIR="${OQS_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
PREFIX="${OQS_PREFIX:-$DEFAULT_PREFIX}"
ALGORITHM="${OQS_ALGORITHM:-$DEFAULT_ALGORITHM}"
MODE="${OQS_MODE:-$DEFAULT_MODE}"
KEY_FORMAT="${OQS_KEY_FORMAT:-$DEFAULT_KEY_FORMAT}"
KEY_TYPE="${OQS_KEY_TYPE:-$DEFAULT_KEY_TYPE}"
DAYS="${OQS_DAYS:-$DEFAULT_DAYS}"
CN="${OQS_CN:-$DEFAULT_CN}"
CONTAINER_RUN_OPTS="${OQS_CONTAINER_RUN_OPTS:-}"
VERBOSE="${OQS_VERBOSE:-false}"
COMMAND=""

# Resolve the available container engine (docker or podman).
# Automatically detects if the specified engine is available,
# falls back to docker, then podman.
#
# Parameters:
#   None
#
# Returns:
#   None (sets the CONTAINER_ENGINE global variable)
resolve_container_engine() {
    if command -v "$CONTAINER_ENGINE" &>/dev/null; then
        info "Using container engine: $CONTAINER_ENGINE"
        return 0
    fi

    # Auto-detect: try docker first
    if command -v docker &>/dev/null; then
        warn "Specified engine '$CONTAINER_ENGINE' not found, falling back to docker"
        CONTAINER_ENGINE="docker"
        return 0
    fi

    # Then try podman
    if command -v podman &>/dev/null; then
        warn "Specified engine '$CONTAINER_ENGINE' not found, falling back to podman"
        CONTAINER_ENGINE="podman"
        return 0
    fi

    error "Neither docker nor podman is installed. Please install one of them."
}

# Validate input parameters.
#
# Parameters:
#   None
#
# Returns:
#   None
validate_inputs() {
    # Attempt to create output directory if it does not exist
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        info "Output directory does not exist: $OUTPUT_DIR. Attempting to create..."
        if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
            error "Failed to create output directory: $OUTPUT_DIR"
        fi
        success "Output directory created: $OUTPUT_DIR"
    fi

    # Check required variables
    if [[ -z "$ALGORITHM" ]]; then
        error "Algorithm is not set. Use --algorithm or set OQS_ALGORITHM."
    fi
}

# Check if the container engine is available.
#
# Parameters:
#   None
#
# Returns:
#   None
check_container_engine() {
    if ! command -v "$CONTAINER_ENGINE" &>/dev/null; then
        error "Container engine '$CONTAINER_ENGINE' is not installed or not in PATH"
    fi
}

# List available KEM algorithms from the container.
#
# Parameters:
#   None
#
# Returns:
#   None
cmd_list_kems() {
    info "Listing KEM algorithms..."
    "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS "$CONTAINER_IMAGE" \
        openssl list -kem-algorithms -provider oqsprovider
}

# List available signature algorithms from the container.
#
# Parameters:
#   None
#
# Returns:
#   None
cmd_list_sigs() {
    info "Listing Signature algorithms..."
    "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS "$CONTAINER_IMAGE" \
        openssl list -signature-algorithms -provider oqsprovider
}

# Generate a key in DER format inside the container.
# Supports both private keys (genpkey) and public key extraction (pkey -pubout).
# All paths are automatically converted to container-internal paths (/output/...).
# The intermediate PEM file is never written to the host filesystem.
#
# Parameters:
#   $1: key_type        - "private" or "public"
#   $2: algorithm       - PQ algorithm name (required for "private" type)
#   $3: output_dir      - host output directory (for volume mount)
#   $4: prefix          - file prefix
#   $5: input_pem_path  - container-internal path to input PEM (for "public" type, optional)
#
# Returns:
#   None
_generate_der() {
    local key_type="$1"
    local algorithm="$2"
    local output_dir="$3"
    local prefix="$4"
    local input_pem_path="${5:-}"

    if [[ "$key_type" == "private" ]]; then
        # Generate private key directly in DER format
        "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
            -v "$output_dir:/output" \
            "$CONTAINER_IMAGE" \
            openssl genpkey -algorithm "$algorithm" \
            -outform DER \
            -out "/output/${prefix}-${algorithm}-private.der"

        chmod 0600 "${output_dir}/${prefix}-${algorithm}-private.der" 2>/dev/null || true
        success "Private key generated: ${output_dir}/${prefix}-${algorithm}-private.der"
    elif [[ "$key_type" == "public" ]]; then
        # Generate public key in DER format from existing private key
        "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
            -v "$output_dir:/output" \
            "$CONTAINER_IMAGE" \
            openssl pkey -in "$input_pem_path" \
            -pubout -outform DER \
            -out "/output/${prefix}-${algorithm}-public.der"

        chmod 0600 "${output_dir}/${prefix}-${algorithm}-public.der" 2>/dev/null || true
        success "Public key generated: ${output_dir}/${prefix}-${algorithm}-public.der"
    fi
}

# Generate private key using the containerized OpenSSL.
#
# Parameters:
#   $1: algorithm - PQ algorithm name
#   $2: output_dir - directory for output files
#   $3: prefix - file prefix
#   $4: key_format - output format (pem, der)
#
# Returns:
#   None
cmd_generate_private_key() {
    local algorithm="$1"
    local output_dir="$2"
    local prefix="$3"
    local key_format="${4:-pem}"

    local private_pem_file="${output_dir}/${prefix}-${algorithm}-private.pem"

    if [[ "$key_format" == "der" ]]; then
        _generate_der "private" "$algorithm" "$output_dir" "$prefix"
    else
        # Generate private key in PEM format
        "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
            -v "$output_dir:/output" \
            "$CONTAINER_IMAGE" \
            openssl genpkey -algorithm "$algorithm" \
            -out "/output/${prefix}-${algorithm}-private.pem"

        # Set restrictive permissions on private key
        chmod 0600 "$private_pem_file" 2>/dev/null || true
        success "Private key generated: $private_pem_file"
    fi
}

# Generate public key from existing private key.
#
# Parameters:
#   $1: algorithm - PQ algorithm name
#   $2: output_dir - directory with private key
#   $3: prefix - file prefix
#   $4: key_format - output format (pem, der)
#
# Returns:
#   None
cmd_generate_public_key() {
    local algorithm="$1"
    local output_dir="$2"
    local prefix="$3"
    local key_format="${4:-pem}"

    local private_file="${output_dir}/${prefix}-${algorithm}-private.pem"
    local public_file="${output_dir}/${prefix}-${algorithm}-public.pem"
    local public_der_file="${output_dir}/${prefix}-${algorithm}-public.der"

    if [[ ! -f "$private_file" ]]; then
        error "Private key not found: $private_file. Generate it first using --mode keypair."
    fi

    if [[ "$key_format" == "der" ]]; then
        _generate_der "public" "$algorithm" "$output_dir" "$prefix" \
                      "/output/${prefix}-${algorithm}-private.pem"
    else
        # Generate public key in PEM format
        "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
            -v "$output_dir:/output" \
            "$CONTAINER_IMAGE" \
            openssl pkey -in "/output/${prefix}-${algorithm}-private.pem" \
            -pubout -out "/output/${prefix}-${algorithm}-public.pem"

        success "Public key generated: $public_file"
    fi
}

# Generate KEM key (keypair or single private key).
#
# Parameters:
#   None (uses global variables: ALGORITHM, OUTPUT_DIR, PREFIX, MODE, KEY_FORMAT)
#
# Returns:
#   None
cmd_kem_generate() {
    info "Generating KEM key with algorithm: $ALGORITHM"
    info "Container engine: $CONTAINER_ENGINE"
    info "Output directory: $OUTPUT_DIR"
    info "File prefix: $PREFIX"
    info "Mode: $MODE"
    info "Key format: $KEY_FORMAT"

    case "$MODE" in
        keypair)
            cmd_generate_private_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "pem"
            cmd_generate_public_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "pem"
            ;;
        single)
            cmd_generate_private_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "$KEY_FORMAT"
            ;;
        *)
            error "Unknown mode: $MODE. Allowed: keypair, single"
            ;;
    esac
}

# Generate signature key (signing/verification keys).
#
# Parameters:
#   None (uses global variables: ALGORITHM, OUTPUT_DIR, PREFIX, MODE, KEY_FORMAT)
#
# Returns:
#   None
cmd_sig_generate() {
    info "Generating Signature key with algorithm: $ALGORITHM"
    info "Container engine: $CONTAINER_ENGINE"
    info "Output directory: $OUTPUT_DIR"
    info "File prefix: $PREFIX"
    info "Mode: $MODE"
    info "Key format: $KEY_FORMAT"

    case "$MODE" in
        keypair)
            cmd_generate_private_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "pem"
            cmd_generate_public_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "pem"
            ;;
        single)
            cmd_generate_private_key "$ALGORITHM" "$OUTPUT_DIR" "$PREFIX" "$KEY_FORMAT"
            ;;
        *)
            error "Unknown mode: $MODE. Allowed: keypair, single"
            ;;
    esac
}

# Generate self-signed X.509 certificate with post-quantum algorithm.
#
# Parameters:
#   None (uses global variables: ALGORITHM, OUTPUT_DIR, PREFIX, CN, DAYS)
#
# Returns:
#   None
cmd_cert_generate() {
    local cert_file="${OUTPUT_DIR}/${PREFIX}-ca.crt"
    local key_file="${OUTPUT_DIR}/${PREFIX}-ca.key"

    info "Generating self-signed certificate with algorithm: $ALGORITHM"
    info "Container engine: $CONTAINER_ENGINE"
    info "Common Name: $CN"
    info "Validity: $DAYS days"
    info "Output directory: $OUTPUT_DIR"

    "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
        -v "$OUTPUT_DIR:/output" \
        "$CONTAINER_IMAGE" \
        openssl req -x509 -new -newkey "$ALGORITHM" \
        -keyout "/output/${PREFIX}-ca.key" \
        -out "/output/${PREFIX}-ca.crt" \
        -nodes \
        -subj "/CN=$CN" \
        -days "$DAYS"

    # Set restrictive permissions on private key
    chmod 0600 "$key_file" 2>/dev/null || true

    success "Certificate generated: $cert_file, $key_file"
}

# Encapsulate a shared secret using KEM.
# Requires a previously generated keypair.
# Uses `openssl pkeyutl -encap` with `-kemop encap` for KEM encapsulation.
#
# Parameters:
#   None (uses global variables: ALGORITHM, OUTPUT_DIR, PREFIX)
#
# Returns:
#   None
cmd_kem_encaps() {
    local private_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-private.pem"
    local public_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-public.pem"
    local encaps_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-encapsulated"
    local shared_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-shared-secret"

    info "Encapsulating KEM secret with algorithm: $ALGORITHM"
    info "Container engine: $CONTAINER_ENGINE"
    info "Output directory: $OUTPUT_DIR"

    # Check if required keys exist
    if [[ ! -f "$private_file" ]]; then
        warn "Private key not found: $private_file. Generate keys first using kem-generate."
        return 1
    fi

    if [[ ! -f "$public_file" ]]; then
        warn "Public key not found: $public_file. Generate keys first using kem-generate."
        return 1
    fi

    "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
        -v "$OUTPUT_DIR:/output" \
        "$CONTAINER_IMAGE" \
        openssl pkeyutl -encap \
        -inkey "/output/${PREFIX}-${ALGORITHM}-private.pem" \
        -kemop encap \
        -pubin -in "/output/${PREFIX}-${ALGORITHM}-public.pem" \
        -out "/output/${PREFIX}-${ALGORITHM}-encapsulated" \
        -secret "/output/${PREFIX}-${ALGORITHM}-shared-secret"

    success "KEM encapsulation completed: $encaps_file, $shared_file"
}

# Decapsulate a shared secret using KEM.
# Requires a previously generated keypair and an encapsulated secret.
# Uses `openssl pkeyutl -decap` with `-kemop decap` for KEM decapsulation.
#
# Parameters:
#   None (uses global variables: ALGORITHM, OUTPUT_DIR, PREFIX)
#
# Returns:
#   None
cmd_kem_decaps() {
    local private_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-private.pem"
    local encaps_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-encapsulated"
    local shared_file="${OUTPUT_DIR}/${PREFIX}-${ALGORITHM}-shared-secret-decap"

    info "Decapsulating KEM secret with algorithm: $ALGORITHM"
    info "Container engine: $CONTAINER_ENGINE"
    info "Output directory: $OUTPUT_DIR"

    # Check if required files exist
    if [[ ! -f "$private_file" ]]; then
        warn "Private key not found: $private_file. Generate keys first using kem-generate."
        return 1
    fi

    if [[ ! -f "$encaps_file" ]]; then
        warn "Encapsulated secret not found: $encaps_file. Encapsulate first using kem-encaps."
        return 1
    fi

    "$CONTAINER_ENGINE" run --rm $CONTAINER_RUN_OPTS \
        -v "$OUTPUT_DIR:/output" \
        "$CONTAINER_IMAGE" \
        openssl pkeyutl -decap \
        -inkey "/output/${PREFIX}-${ALGORITHM}-private.pem" \
        -kemop decap \
        -in "/output/${PREFIX}-${ALGORITHM}-encapsulated" \
        -out "/output/${PREFIX}-${ALGORITHM}-shared-secret-decap"

    success "KEM decapsulation completed: $shared_file"
}

# Display help message with usage instructions.
#
# Parameters:
#   None
#
# Returns:
#   None
show_help() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

OQS Utils - Post-Quantum Cryptography Utility

Provides a simplified interface to the oqs-openssl container image
for generating post-quantum keys, certificates, and KEM secrets.

Commands:
    kem-generate        Generate KEM key (encapsulation/decapsulation)
    sig-generate        Generate signature key (sign/verify)
    cert-generate       Generate X.509 certificate with PQ algorithm
    kem-encaps          Encapsulate shared secret for KEM
    kem-decaps          Decapsulate shared secret for KEM
    list-algorithms     List all available PQ algorithms
    list-kems           List available KEM algorithms
    list-sigs           List available signature algorithms
    help                Show this help message

Options:
    --algorithm ALG             PQ algorithm (default: mlkem768)
    --output-dir DIR            Output directory (default: /tmp/)
    --prefix PREFIX             File prefix (default: oqs)
    --mode MODE                 Generation mode: keypair, single (default: keypair)
    --key-format FMT            Key format for single mode: pem, der (default: pem)
    --key-type TYPE             Key type: kem or sig (default: kem)
    --days DAYS                 Certificate validity (default: 365)
    --cn CN                     Common Name for certificate (default: OQS Test)
    --container-image IMG       Container image (default: ghcr.io/mournweiss/oqs-openssl:latest-alpine)
    --container-engine ENGINE   Container engine: docker/podman (default: auto-detect)
    --container-run-opts OPTS   Additional container run options
    --verbose                   Enable verbose output
    --help, -h                  Show this help message

Environment Variables:
    OQS_ALGORITHM             PQ algorithm
    OQS_OUTPUT_DIR            Output directory
    OQS_PREFIX                File prefix
    OQS_MODE                  Generation mode (keypair/single)
    OQS_KEY_FORMAT            Key format for single mode (pem/der)
    OQS_KEY_TYPE              Key type (kem/sig)
    OQS_DAYS                  Certificate validity
    OQS_CN                    Common Name
    OQS_CONTAINER_IMAGE       Container image
    OQS_CONTAINER_ENGINE      Container engine (docker/podman)
    OQS_CONTAINER_RUN_OPTS    Additional container run options
    OQS_VERBOSE               Enable verbose output
    CONTAINER_ENGINE          Global container engine override

Examples:
    # Generate full keypair (default)
    $(basename "$0") kem-generate --algorithm mlkem768
    $(basename "$0") sig-generate --algorithm mldsa65 --output-dir ./keys

    # Generate only private key in PEM format (single mode)
    $(basename "$0") kem-generate --algorithm mlkem768 --mode single

    # Generate only private key in DER format (single mode)
    $(basename "$0") kem-generate --algorithm mlkem768 --mode single --key-format der

    # Generate self-signed certificate
    $(basename "$0") cert-generate --algorithm mldsa87 --cn "My PQ CA" --days 730

    # List available algorithms
    $(basename "$0") list-kems
    $(basename "$0") list-sigs

    # Using Podman:
    CONTAINER_ENGINE=podman $(basename "$0") kem-generate --algorithm mlkem768
    $(basename "$0") --container-engine podman kem-generate --algorithm mlkem768

    # Using custom image:
    OQS_CONTAINER_IMAGE=myregistry.com/oqs-openssl:latest $(basename "$0") kem-generate
    $(basename "$0") --container-image myregistry.com/oqs-openssl:latest kem-generate

EOF
}

# Parse command-line arguments and set global variables.
#
# Parameters:
#   $@: array - command-line arguments
#
# Returns:
#   None (sets global variables: ALGORITHM, OUTPUT_DIR, PREFIX, MODE, KEY_FORMAT, etc.)
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --algorithm)
                ALGORITHM="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --prefix)
                PREFIX="$2"
                shift 2
                ;;
            --mode)
                MODE="$2"
                case "$MODE" in
                    keypair|single) ;;
                    *) error "Invalid mode: $MODE. Allowed: keypair, single" ;;
                esac
                shift 2
                ;;
            --key-format)
                KEY_FORMAT="$2"
                case "$KEY_FORMAT" in
                    pem|der) ;;
                    *) error "Invalid key format: $KEY_FORMAT. Allowed: pem, der" ;;
                esac
                shift 2
                ;;
            --key-type)
                KEY_TYPE="$2"
                shift 2
                ;;
            --days)
                DAYS="$2"
                shift 2
                ;;
            --cn)
                CN="$2"
                shift 2
                ;;
            --container-image)
                CONTAINER_IMAGE="$2"
                shift 2
                ;;
            --container-engine)
                CONTAINER_ENGINE="$2"
                shift 2
                ;;
            --container-run-opts)
                CONTAINER_RUN_OPTS="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$COMMAND" ]]; then
                    COMMAND="$1"
                else
                    warn "Unknown argument: $1"
                fi
                shift
                ;;
        esac
    done
}

# Main
main() {
    parse_args "$@"
    validate_inputs
    resolve_container_engine
    check_container_engine

    case "${COMMAND:-help}" in
        kem-generate)   cmd_kem_generate ;;
        sig-generate)   cmd_sig_generate ;;
        cert-generate)  cmd_cert_generate ;;
        kem-encaps)     cmd_kem_encaps ;;
        kem-decaps)     cmd_kem_decaps ;;
        list-kems)      cmd_list_kems ;;
        list-sigs)      cmd_list_sigs ;;
        list-algorithms)
            cmd_list_kems
            cmd_list_sigs
            ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
