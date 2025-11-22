#!/bin/bash

# Stage a dstack configuration bundle to GCS and print the metadata flags
# required for GCP instances.
#
# Usage:
#   scripts/bin/gcp-stage-config.sh [-p] [-s <duration>] <CONFIG_TAR> <GS_DEST>
#   scripts/bin/gcp-stage-config.sh [-p] [-s 2h] bb-build/dist/config-bundle.tar gs://my-bucket/configs/
#
# Flags:
#   -p    Make the uploaded object world-readable (gsutil iam ch allUsers:objectViewer …).
#   -s    Generate a signed URL (using `gcloud storage signed-url`) valid for the supplied duration (default: 1h).
#
# The script uploads the config bundle, computes its SHA256, and echoes the
# `--metadata` snippet to pass to `gcloud compute instances create`.

set -euo pipefail

make_public=false
want_signed=false
signed_duration="1h"
while getopts ":ps:" opt; do
    case "${opt}" in
        p) make_public=true ;;
        s) want_signed=true; signed_duration="${OPTARG}" ;;
        *) echo "Usage: $0 [-p] [-s <duration>] <CONFIG_TAR> <GS_DEST>" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -ne 2 ]; then
    echo "Usage: $0 [-p] [-s <duration>] <CONFIG_TAR> <GS_DEST>" >&2
    exit 1
fi

config_tar=$1
gs_dest=$2

if [ ! -f "$config_tar" ]; then
    echo "Config bundle '$config_tar' does not exist" >&2
    exit 1
fi

if [[ "$gs_dest" != gs://* ]]; then
    echo "Destination must be a gs:// URI (got '$gs_dest')" >&2
    exit 1
fi

timestamp=$(date +%Y%m%d-%H%M%S)
config_basename=$(basename "$config_tar")
config_object="${config_basename%.tar}-config-${timestamp}.tar"

if [[ "$gs_dest" == */ ]]; then
    gs_path="${gs_dest}${config_object}"
else
    gs_path="${gs_dest}"
fi

echo "Uploading ${config_tar} -> ${gs_path}"
gsutil cp "$config_tar" "$gs_path"

if $make_public; then
    echo "Making ${gs_path} world-readable"
   gsutil iam ch allUsers:objectViewer "$gs_path"
fi

signed_url=""
if $want_signed; then
    echo "Generating signed URL valid for ${signed_duration}"
    signed_url=$(gcloud storage sign-url "$gs_path" --http-verb GET --duration "${signed_duration}")
fi

sha256=$(sha256sum "$config_tar" | awk '{print $1}')
https_url="https://storage.googleapis.com/${gs_path#gs://}"

cat <<EOF

Config bundle uploaded:
  ${gs_path}

SHA-256:
  ${sha256}

Add the following to your instance metadata:
  --metadata dstack-config-url=${https_url},dstack-config-sha256=${sha256}

If you generated a signature, append:
  ,dstack-config-signature=<base64-url-signature>
EOF

if $want_signed; then
cat <<EOF

Signed URL (use in place of the public HTTPS link above):
  ${signed_url}
EOF
fi
