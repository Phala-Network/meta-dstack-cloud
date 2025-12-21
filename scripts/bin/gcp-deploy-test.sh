#!/bin/bash

# SPDX-FileCopyrightText: © 2025 Phala Network <dstack@phala.network>
#
# SPDX-License-Identifier: Apache-2.0

# Quick deploy script for TPM test VM

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DSTACK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

#KMS_VM=d3392c8d-c949-4199-a936-2ad986879f4d
KMS_VM=19d9eca8-db67-40bf-bead-65dd8e3489ec
TPM_VM=34155fc6-8948-4ca2-a336-d984b40d32ed
IMG=dstack-0.6.0
IMG_FILE=${IMG}-gcp.tar.gz

usage() {
    cat << EOF
Usage: $(basename "$0") [PROFILE] [OPTIONS]

Quick deploy test VM to GCP.

Profile:
  kms                 Deploy KMS test VM (default)
  tpm                 Deploy TPM test VM

Options:
  --no-delete         Don't delete existing instance first
  --instance NAME     Instance name (overrides default)
  --image TAR         Boot image tar.gz (default: ${IMG_FILE})
  --force-boot-image  Force re-upload and re-create boot image even if GCP image is up-to-date
  --force-attestation-mode MODE  Force guest attestation mode via metadata startup-script
  -h, --help          Show this help

Examples:
  $(basename "$0")                           # Deploy KMS VM with defaults
  $(basename "$0") tpm                       # Deploy TPM VM
  $(basename "$0") kms --no-delete           # Deploy KMS VM without deleting existing
  $(basename "$0") tpm --instance my-test    # Deploy TPM VM with custom name
EOF
    exit 0
}

# Parse profile first (positional argument)
PROFILE="kms"
if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
    PROFILE="$1"
    shift
fi

# Set defaults based on profile
if [[ $PROFILE == "kms" ]]; then
    APP=$KMS_VM
    INSTANCE_NAME="dstack-kms-dev"
elif [[ $PROFILE == "tpm" ]]; then
    APP=$TPM_VM
    INSTANCE_NAME="dstack-tpm-test"
else
    echo "Error: Invalid profile '$PROFILE'. Must be 'kms' or 'tpm'."
    usage
fi

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-delete)
            DELETE=""
            shift
            ;;
        --force-boot-image)
            FORCE_BOOT_IMAGE="--force-boot-image"
            shift
            ;;
        --force-attestation-mode)
            FORCE_ATTESTATION_MODE="--force-attestation-mode $2"
            shift 2
            ;;
        --instance)
            INSTANCE_NAME="$2"
            shift 2
            ;;
        --image)
            BOOT_IMAGE_TAR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Defaults
VM_DIR="${META_DSTACK_DIR}/build/run/vm/$APP"
PROJECT="wuhan-workshop"
ZONE="us-central1-a"
# Find latest dev image unless explicitly specified
if [[ -z "${BOOT_IMAGE_TAR:-}" ]]; then
    BOOT_IMAGE_TAR="$(ls -t "${META_DSTACK_DIR}"/build/images/${IMG_FILE} 2>/dev/null | head -1)"
    if [[ -z "$BOOT_IMAGE_TAR" ]]; then
        echo "Error: No ${IMG_FILE} found in build/images/"
        exit 1
    fi
else
    if [[ ! -f "$BOOT_IMAGE_TAR" ]]; then
        echo "Error: Boot image tar not found: $BOOT_IMAGE_TAR"
        exit 1
    fi
fi
BUCKET="gs://wuhan-workshop-dstack"
DELETE="--delete"
FORCE_BOOT_IMAGE=${FORCE_BOOT_IMAGE:-""}
FORCE_ATTESTATION_MODE=${FORCE_ATTESTATION_MODE:-""}

exec "${SCRIPT_DIR}/gcp-deploy-vm.sh" \
    --vm-dir "$VM_DIR" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --instance-name "$INSTANCE_NAME" \
    --boot-image-tar "$BOOT_IMAGE_TAR" \
    --bucket "$BUCKET" \
    $FORCE_BOOT_IMAGE \
    $FORCE_ATTESTATION_MODE \
    $DELETE
