#!/bin/bash

# SPDX-FileCopyrightText: © 2025 Phala Network <dstack@phala.network>
#
# SPDX-License-Identifier: Apache-2.0

set -e

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy a dstack VM to GCP TDX environment.

Required options:
  --vm-dir DIR          Path to the VM directory containing shared/ folder
  --project PROJECT     GCP project ID
  --zone ZONE           GCP zone (e.g., us-central1-a)

Optional options:
  --instance-name NAME  Instance name (default: dstack-vm)
  --machine-type TYPE   Machine type (default: c3-standard-4)
  --boot-image IMAGE    Boot disk image name (default: dstack-0-6-0)
  --boot-image-tar TAR  Local boot image tar.gz file (auto-uploads if newer than GCP image)
  --force-boot-image    Force re-upload and re-create boot image even if GCP image is up-to-date
  --force-attestation-mode MODE  Force guest attestation mode via startup-script (sets DSTACK_ATTESTATION_MODE for dstack-prepare.service)
  --data-image IMAGE    Data disk image name (default: dstack-data-disk)
  --data-size SIZE      Data disk size in GB (default: 20)
  --bucket BUCKET       GCS bucket for shared disk image (default: gs://<project>-dstack)
  --delete              Delete existing instance first
  -h, --help            Show this help message

Examples:
  $(basename "$0") --vm-dir ./run/vm/abc123 --project my-project --zone us-central1-a
  $(basename "$0") --vm-dir ./run/vm/abc123 --project my-project --zone us-central1-a --instance-name my-vm
EOF
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

error() {
    log "Error: $*"
    exit 1
}

VM_DIR=""
PROJECT=""
ZONE=""
INSTANCE_NAME="dstack-vm"
MACHINE_TYPE="c3-standard-4"
BOOT_IMAGE="dstack-0-6-0"
BOOT_IMAGE_TAR=""
FORCE_BOOT_IMAGE=false
FORCE_ATTESTATION_MODE=""
DATA_IMAGE="dstack-data-disk"
DATA_SIZE="20"
BUCKET=""
DELETE_EXISTING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-dir)
            VM_DIR="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --zone)
            ZONE="$2"
            shift 2
            ;;
        --instance-name)
            INSTANCE_NAME="$2"
            shift 2
            ;;
        --machine-type)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --boot-image)
            BOOT_IMAGE="$2"
            shift 2
            ;;
        --boot-image-tar)
            BOOT_IMAGE_TAR="$2"
            shift 2
            ;;
        --force-boot-image)
            FORCE_BOOT_IMAGE=true
            shift
            ;;
        --force-attestation-mode)
            FORCE_ATTESTATION_MODE="$2"
            shift 2
            ;;
        --data-image)
            DATA_IMAGE="$2"
            shift 2
            ;;
        --data-size)
            DATA_SIZE="$2"
            shift 2
            ;;
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --delete)
            DELETE_EXISTING=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

[[ -z "$VM_DIR" ]] && error "Missing required option: --vm-dir"
[[ -z "$PROJECT" ]] && error "Missing required option: --project"
[[ -z "$ZONE" ]] && error "Missing required option: --zone"

[[ -d "$VM_DIR" ]] || error "VM directory does not exist: $VM_DIR"
[[ -d "$VM_DIR/shared" ]] || error "shared/ directory not found in VM directory"
[[ -f "$VM_DIR/shared/app-compose.json" ]] || error "app-compose.json not found in shared/"
[[ -f "$VM_DIR/shared/.sys-config.json" ]] || error ".sys-config.json not found in shared/"

if [[ -z "$BUCKET" ]]; then
    BUCKET="gs://${PROJECT}-dstack"
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SHARED_IMAGE_NAME="${INSTANCE_NAME}-shared"

check_and_upload_boot_image() {
    local tar_file="$1"
    local image_name="$2"

    [[ -f "$tar_file" ]] || error "Boot image tar file not found: $tar_file"

    local local_mtime
    local_mtime=$(stat -c %Y "$tar_file")

    local gcp_creation_time
    gcp_creation_time=$(gcloud compute images describe "$image_name" \
        --project="$PROJECT" \
        --format='value(creationTimestamp)' 2>/dev/null || echo "")

    local need_upload=false
    if [[ "$FORCE_BOOT_IMAGE" == true ]]; then
        log "Force enabled: will re-upload boot image"
        need_upload=true
    fi
    if [[ -z "$gcp_creation_time" ]]; then
        log "GCP image '$image_name' does not exist, will upload"
        need_upload=true
    else
        local gcp_epoch
        gcp_epoch=$(date -d "$gcp_creation_time" +%s 2>/dev/null || echo "0")
        if [[ "$need_upload" != true && "$local_mtime" -gt "$gcp_epoch" ]]; then
            log "Local image is newer than GCP image, will re-upload"
            log "  Local: $(date -d @$local_mtime '+%Y-%m-%d %H:%M:%S')"
            log "  GCP:   $gcp_creation_time"
            need_upload=true
        elif [[ "$need_upload" != true ]]; then
            log "GCP image '$image_name' is up-to-date"
        fi
    fi

    if [[ "$need_upload" == true ]]; then
        log "Uploading boot image to GCS..."
        gsutil cp "$tar_file" "${BUCKET}/${image_name}.tar.gz"

        if [[ -n "$gcp_creation_time" ]]; then
            log "Deleting existing GCP image..."
            gcloud compute images delete "$image_name" \
                --project="$PROJECT" \
                --quiet
        fi

        log "Creating GCP image with TDX support..."
        gcloud compute images create "$image_name" \
            --project="$PROJECT" \
            --source-uri="${BUCKET}/${image_name}.tar.gz" \
            --guest-os-features=UEFI_COMPATIBLE,TDX_CAPABLE,GVNIC
    fi
}

log "=== GCP TDX VM Deployment ==="
log "VM Directory: $VM_DIR"
log "Project: $PROJECT"
log "Zone: $ZONE"
log "Instance: $INSTANCE_NAME"
log "GCS Bucket: $BUCKET"

if [[ "$DELETE_EXISTING" == true ]]; then
    log ""
    log "Checking for existing instance..."
    if gcloud compute instances describe "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT" &>/dev/null; then
        log "Deleting existing instance: $INSTANCE_NAME"
        gcloud compute instances delete "$INSTANCE_NAME" \
            --zone="$ZONE" \
            --project="$PROJECT" \
            --quiet
    fi
fi

if [[ -n "$BOOT_IMAGE_TAR" ]]; then
    # Derive image name from tar file if not explicitly set
    if [[ "$BOOT_IMAGE" == "dstack-0-6-0" ]]; then
        # Extract name from tar file: dstack-dev-0.6.0-gcp.tar.gz -> dstack-dev-0-6-0
        tar_basename=$(basename "$BOOT_IMAGE_TAR" .tar.gz)
        tar_basename=${tar_basename%-gcp}  # Remove -gcp suffix
        BOOT_IMAGE=$(echo "$tar_basename" | tr '.' '-')  # Replace dots with dashes
    fi
    log ""
    log "Checking boot image..."
    check_and_upload_boot_image "$BOOT_IMAGE_TAR" "$BOOT_IMAGE"
fi

log ""
log "Step 1: Creating shared disk image..."

truncate -s 100M "$WORK_DIR/shared.raw"
mkfs.ext4 -L DSTACKSHR "$WORK_DIR/shared.raw" >/dev/null 2>&1

mkdir -p "$WORK_DIR/mount"
sudo mount -o loop "$WORK_DIR/shared.raw" "$WORK_DIR/mount"

sudo cp "$VM_DIR/shared/app-compose.json" "$WORK_DIR/mount/"
sudo cp "$VM_DIR/shared/.sys-config.json" "$WORK_DIR/mount/"

if [[ -f "$VM_DIR/shared/.instance_info" ]]; then
    sudo cp "$VM_DIR/shared/.instance_info" "$WORK_DIR/mount/"
fi
if [[ -f "$VM_DIR/shared/.encrypted-env" ]]; then
    sudo cp "$VM_DIR/shared/.encrypted-env" "$WORK_DIR/mount/"
fi
if [[ -f "$VM_DIR/shared/.user-config" ]]; then
    sudo cp "$VM_DIR/shared/.user-config" "$WORK_DIR/mount/"
fi

sudo umount "$WORK_DIR/mount"

mv "$WORK_DIR/shared.raw" "$WORK_DIR/disk.raw"
tar -C "$WORK_DIR" -czvf "$WORK_DIR/shared-disk.tar.gz" disk.raw >/dev/null

log "Uploading shared disk image to GCS..."
gsutil cp "$WORK_DIR/shared-disk.tar.gz" "${BUCKET}/${SHARED_IMAGE_NAME}.tar.gz"

log "Creating GCP image from shared disk..."
if gcloud compute images describe "$SHARED_IMAGE_NAME" \
    --project="$PROJECT" &>/dev/null; then
    log "Deleting existing shared disk image..."
    gcloud compute images delete "$SHARED_IMAGE_NAME" \
        --project="$PROJECT" \
        --quiet
fi

gcloud compute images create "$SHARED_IMAGE_NAME" \
    --project="$PROJECT" \
    --source-uri="${BUCKET}/${SHARED_IMAGE_NAME}.tar.gz" \
    --guest-os-features=GVNIC

log ""
log "Step 2: Creating TDX instance..."

METADATA_ARGS=()
if [[ -n "$FORCE_ATTESTATION_MODE" ]]; then
    log "Forcing guest attestation mode via metadata startup-script: $FORCE_ATTESTATION_MODE"
    startup_script_for_attestation_mode "$FORCE_ATTESTATION_MODE" > "$WORK_DIR/startup-script.sh"
    METADATA_ARGS+=(--metadata-from-file=startup-script="$WORK_DIR/startup-script.sh")
fi

gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --machine-type="$MACHINE_TYPE" \
    --confidential-compute-type=TDX \
    --image="$BOOT_IMAGE" \
    --boot-disk-size=10GB \
    --create-disk="name=${INSTANCE_NAME}-data,size=${DATA_SIZE}GB,type=pd-balanced,image=${DATA_IMAGE},auto-delete=yes" \
    --create-disk="name=${INSTANCE_NAME}-shared,size=1GB,type=pd-balanced,image=${SHARED_IMAGE_NAME},auto-delete=yes" \
    --maintenance-policy=TERMINATE \
    "${METADATA_ARGS[@]}"

log ""
log "=== Deployment Complete ==="
log "Instance: $INSTANCE_NAME"
log "External IP: $(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
log ""
log "To check serial output:"
log "  gcloud compute instances get-serial-port-output $INSTANCE_NAME --zone=$ZONE --project=$PROJECT"
log ""
log "To SSH into the instance:"
log "  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT"
