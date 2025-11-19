#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOU'
Usage: gcp-deploy-image.sh [options]

Flags (all optional, reasonable defaults inferred when omitted):
  --tar <path>            Local GCP image tarball to upload (default: newest images/*-gcp.tar.gz)
  --gcs <uri>             Destination GCS URI (default: gs://wuhan-workshop-dstack/images/<image>/<tar>)
  --image <name>          GCP image name to create/update (default: tar base name)
  --project <id>          GCP project (defaults to current gcloud config)
  --zone <zone>           Compute Engine zone for instance creation (default: us-central1-b)
  --machine <type>        Machine type when creating an instance (default: c3-standard-4)
  --instance <name>       If set, delete/create this instance after the image is ready
  --boot-disk-size <GB>   Boot disk size for the instance (default: 40)
  --boot-disk-type <type> Boot disk type (default: pd-balanced)
  --data-disk-size <GB>   Extra PD size attached as data disk (default: 20, 0 disables)
  --data-disk-type <type> Extra PD type (default: pd-balanced)
  --config-url <url>      Value for metadata key dstack-config-url
  --config-sha <sha256>   Value for metadata key dstack-config-sha256
EOU
    exit 1
}

TAR_PATH=""
GCS_URI=""
IMAGE_NAME="dstack-dev-060-gcp"
PROJECT="$(gcloud config get-value core/project --quiet 2>/dev/null || true)"
ZONE="us-central1-b"
MACHINE_TYPE="c3-standard-4"
INSTANCE_NAME="dstack-tdx-guest"
BOOT_DISK_SIZE=40
BOOT_DISK_TYPE="pd-balanced"
DATA_DISK_SIZE=20
DATA_DISK_TYPE="pd-balanced"
CONFIG_URL=""
CONFIG_SHA=""

DEFAULT_BUCKET="${DSTACK_GCS_BUCKET:-gs://wuhan-workshop-dstack}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tar) TAR_PATH="$2"; shift 2 ;;
        --gcs) GCS_URI="$2"; shift 2 ;;
        --image) IMAGE_NAME="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --zone) ZONE="$2"; shift 2 ;;
        --machine) MACHINE_TYPE="$2"; shift 2 ;;
        --instance) INSTANCE_NAME="$2"; shift 2 ;;
        --boot-disk-size) BOOT_DISK_SIZE="$2"; shift 2 ;;
        --boot-disk-type) BOOT_DISK_TYPE="$2"; shift 2 ;;
        --data-disk-size) DATA_DISK_SIZE="$2"; shift 2 ;;
        --data-disk-type) DATA_DISK_TYPE="$2"; shift 2 ;;
        --config-url) CONFIG_URL="$2"; shift 2 ;;
        --config-sha) CONFIG_SHA="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown flag: $1" >&2; usage ;;
    esac
done

if [[ -z "$TAR_PATH" ]]; then
    TAR_PATH="$(find images -maxdepth 1 -name '*-gcp.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
fi

if [[ -z "$GCS_URI" ]]; then
    SUBDIR="${IMAGE_NAME:-latest}"
    GCS_URI="${DEFAULT_BUCKET}/images/${SUBDIR}/${IMAGE_NAME}.tar.gz"
fi

if [[ -n "$TAR_PATH" ]]; then
    echo "Uploading $TAR_PATH -> $GCS_URI"
    gsutil cp "$TAR_PATH" "$GCS_URI"
fi

if [[ -n "$IMAGE_NAME" && -n "$GCS_URI" ]]; then
    [[ -n "$PROJECT" ]] || { echo "gcloud project not set; pass --project" >&2; exit 1; }

    if gcloud --project="$PROJECT" compute images describe "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "Deleting existing image $IMAGE_NAME"
        gcloud --project="$PROJECT" compute images delete "$IMAGE_NAME" --quiet
    fi

    echo "Creating image $IMAGE_NAME"
    gcloud --project="$PROJECT" compute images create "$IMAGE_NAME" \
        --source-uri="$GCS_URI" \
        --guest-os-features=UEFI_COMPATIBLE,TDX_CAPABLE \
        --storage-location=us
fi

if [[ -n "$INSTANCE_NAME" ]]; then
    if gcloud --project="$PROJECT" compute instances describe "$INSTANCE_NAME" --zone="$ZONE" >/dev/null 2>&1; then
        echo "Deleting existing instance $INSTANCE_NAME"
        gcloud --project="$PROJECT" compute instances delete "$INSTANCE_NAME" --zone="$ZONE" --quiet
    fi

    METADATA="serial-port-enable=1"
    [[ -n "$CONFIG_URL" ]] && METADATA+=",dstack-config-url=$CONFIG_URL"
    [[ -n "$CONFIG_SHA" ]] && METADATA+=",dstack-config-sha256=$CONFIG_SHA"

    CREATE_DISK_ARGS=()
    if [[ "$DATA_DISK_SIZE" != "0" ]]; then
        CREATE_DISK_ARGS+=("--create-disk=name=${INSTANCE_NAME}-data,size=${DATA_DISK_SIZE}GB,type=${DATA_DISK_TYPE},auto-delete=yes")
    fi

    echo "Creating instance $INSTANCE_NAME"
    gcloud --project="$PROJECT" compute instances create "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --confidential-compute-type=TDX \
        --maintenance-policy=TERMINATE \
        --image="$IMAGE_NAME" \
        --image-project="$PROJECT" \
        --boot-disk-size="${BOOT_DISK_SIZE}GB" \
        --boot-disk-type="$BOOT_DISK_TYPE" \
        --no-shielded-secure-boot \
        --shielded-vtpm \
        --shielded-integrity-monitoring \
        --metadata="$METADATA" \
        "${CREATE_DISK_ARGS[@]}"
fi
