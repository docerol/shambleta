#!/usr/bin/env bash
set -euo pipefail

# TLS Certificate Provisioning Script for Shambleta
# Generates or validates TLS certificates for the game server.
#
# Usage:
#   ./provision_tls.sh --self-signed --domain example.com
#   ./provision_tls.sh --cert /path/to/cert.pem --key /path/to/key.pem
#
# Environment variables:
#   SHAMBLETA_USER_DATA - Godot user data directory (default: /data/.local/share/godot/app_userdata/Shambleta)
#   SHAMBLETA_CERT_DAYS  - Validity days for self-signed cert (default: 365)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SHAMBLETA_USER_DATA:-/data/.local/share/godot/app_userdata/Shambleta}"
CERT_PATH="${CERT_DIR}/server.crt"
KEY_PATH="${CERT_DIR}/server.key"
CERT_DAYS="${SHAMBLETA_CERT_DAYS:-365}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate or validate TLS certificates for Shambleta game server.

Options:
  --self-signed --domain DOMAIN   Generate self-signed certificate
  --cert PATH --key PATH          Use existing certificate and key files
  --check                         Check if certificates exist and are valid
  --help                          Show this help message

Examples:
  $(basename "$0") --self-signed --domain example.com
  $(basename "$0") --cert ./server.crt --key ./server.key
  $(basename "$0") --check
EOF
    exit 1
}

check_certificates() {
    echo "Checking TLS certificates..."

    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        echo "ERROR: Certificates not found at:"
        echo "  Cert: $CERT_PATH"
        echo "  Key:  $KEY_PATH"
        echo ""
        echo "Run with --self-signed to generate development certificates."
        exit 1
    fi

    # Check certificate validity
    if ! openssl x509 -in "$CERT_PATH" -noout >/dev/null 2>&1; then
        echo "ERROR: Invalid certificate at $CERT_PATH"
        exit 1
    fi

    if ! openssl rsa -in "$KEY_PATH" -check >/dev/null 2>&1; then
        echo "ERROR: Invalid private key at $KEY_PATH"
        exit 1
    fi

    # Show certificate info
    echo "Certificate found:"
    echo "  Subject: $(openssl x509 -in "$CERT_PATH" -noout -subject | sed 's/subject=//')"
    echo "  Issuer:  $(openssl x509 -in "$CERT_PATH" -noout -issuer | sed 's/issuer=//')"
    echo "  Valid until: $(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2)"

    # Check expiration (warn if < 30 days)
    expiry_epoch=$(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo "0")
    current_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

    if [ "$days_left" -lt 0 ]; then
        echo "ERROR: Certificate EXPIRED $((days_left * -1)) days ago!"
        exit 1
    elif [ "$days_left" -lt 30 ]; then
        echo "WARNING: Certificate expires in $days_left days. Consider renewing."
    else
        echo "OK: Certificate valid for $days_left more days."
    fi

    exit 0
}

generate_self_signed() {
    local domain="$1"

    echo "Generating self-signed TLS certificate..."
    echo "  Domain: $domain"
    echo "  Validity: $CERT_DAYS days"
    echo "  Output: $CERT_DIR"

    # Create directory if needed
    mkdir -p "$CERT_DIR"

    # Generate private key
    openssl genrsa -out "$KEY_PATH" 2048

    # Generate certificate signing request
    openssl req -new -key "$KEY_PATH" -out /tmp/csr.csr \
        -subj "/C=BR/ST=State/L=City/O=Shambleta/CN=$domain"

    # Generate self-signed certificate
    openssl x509 -req -days "$CERT_DAYS" \
        -in /tmp/csr.csr \
        -signkey "$KEY_PATH" \
        -out "$CERT_PATH"

    # Clean up CSR
    rm -f /tmp/csr.csr

    # Set permissions
    chmod 600 "$KEY_PATH"
    chmod 644 "$CERT_PATH"

    echo ""
    echo "TLS certificates generated successfully:"
    echo "  Cert: $CERT_PATH"
    echo "  Key:  $KEY_PATH"
    echo ""
    echo "Next steps:"
    echo "  1. Mount these files into the game container at $CERT_DIR"
    echo "  2. Set SHAMBLETA_PROXY_TLS=0 (or unset) to use direct TLS"
    echo "  3. Restart the game server"
}

copy_certificates() {
    local cert_src="$1"
    local key_src="$2"

    echo "Copying TLS certificates..."
    echo "  Source cert: $cert_src"
    echo "  Source key:  $key_src"
    echo "  Destination: $CERT_DIR"

    if [ ! -f "$cert_src" ]; then
        echo "ERROR: Certificate file not found: $cert_src"
        exit 1
    fi

    if [ ! -f "$key_src" ]; then
        echo "ERROR: Private key file not found: $key_src"
        exit 1
    fi

    # Validate files
    if ! openssl x509 -in "$cert_src" -noout >/dev/null 2>&1; then
        echo "ERROR: Invalid certificate file: $cert_src"
        exit 1
    fi

    if ! openssl rsa -in "$key_src" -check >/dev/null 2>&1; then
        echo "ERROR: Invalid private key file: $key_src"
        exit 1
    fi

    # Create directory and copy
    mkdir -p "$CERT_DIR"
    cp "$cert_src" "$CERT_PATH"
    cp "$key_src" "$KEY_PATH"

    # Set permissions
    chmod 600 "$KEY_PATH"
    chmod 644 "$CERT_PATH"

    echo ""
    echo "Certificates copied successfully:"
    echo "  Cert: $CERT_PATH"
    echo "  Key:  $KEY_PATH"
}

# Parse arguments
SELF_SIGNED=false
DOMAIN=""
CERT_SRC=""
KEY_SRC=""
CHECK_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --self-signed)
            SELF_SIGNED=true
            shift
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --cert)
            CERT_SRC="$2"
            shift 2
            ;;
        --key)
            KEY_SRC="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [ "$CHECK_ONLY" = true ]; then
    check_certificates
fi

if [ "$SELF_SIGNED" = true ]; then
    if [ -z "$DOMAIN" ]; then
        echo "ERROR: --domain is required with --self-signed"
        usage
    fi
    generate_self_signed "$DOMAIN"
    exit 0
fi

if [ -n "$CERT_SRC" ] && [ -n "$KEY_SRC" ]; then
    copy_certificates "$CERT_SRC" "$KEY_SRC"
    exit 0
fi

if [ -z "$CERT_SRC" ] && [ -z "$KEY_SRC" ] && [ "$CHECK_ONLY" = false ]; then
    echo "ERROR: No action specified. Use --self-signed, --cert/--key, or --check."
    usage
fi
