#!/bin/bash
set -e

DSTACK_TAR_RELEASE=${DSTACK_TAR_RELEASE:-1}
ENABLE_GCP_IMAGE=${ENABLE_GCP_IMAGE:-1}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dist-name)
            DIST_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --dist-name NAME"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$DIST_NAME" ]; then
    echo "Error: --dist-name is required"
    exit 1
fi


if [[ "$DIST_NAME" == *-dev ]]; then
    IS_DEV=true
else
    IS_DEV=false
fi

BB_BUILD_DIR=$(realpath ${BB_BUILD_DIR:-build})
DIST_DIR=$(realpath ${DIST_DIR:-${BB_BUILD_DIR}/dist})

IMG_DIR=${BB_BUILD_DIR}/tmp/deploy/images/tdx
ROOTFS_IMAGE_NAME=${DIST_NAME}-rootfs

INITRAMFS_IMAGE=${IMG_DIR}/dstack-initramfs.cpio.gz
ROOTFS_IMAGE=${IMG_DIR}/${ROOTFS_IMAGE_NAME}-tdx.squashfs.verity
KERNEL_IMAGE=${IMG_DIR}/bzImage
OVMF_FIRMWARE=${IMG_DIR}/ovmf.fd
# Always use the work-shared directory which has the correct verity env
VERITY_ENV_FILE=${BB_BUILD_DIR}/tmp/work-shared/tdx/dm-verity/${ROOTFS_IMAGE_NAME}.squashfs.verity.env
echo "Loading verity env from ${VERITY_ENV_FILE}"
source ${VERITY_ENV_FILE}

DSTACK_VERSION=$(bitbake-getvar --value DISTRO_VERSION | tail -1)
OUTPUT_DIR=${OUTPUT_DIR:-"${DIST_DIR}/${DIST_NAME}-${DSTACK_VERSION}"}
IMAGE_TAR=${IMAGE_TAR:-"${DIST_DIR}/${DIST_NAME}-${DSTACK_VERSION}.tar.gz"}

verbose() {
    echo "$@"
    $@
}

align_up() {
    local value=$1
    local align=$2
    echo $(( ( (value + align - 1) / align ) * align ))
}

create_grub_bootstrap() {
    local target_dir="$1"
    local cfg_file
    cfg_file=$(mktemp)
cat <<EOF > "$cfg_file"
set default=0
set timeout=0
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

menuentry "DStack Guest" {
    search --file --no-floppy --set=root /bzImage
    linux /bzImage $KARG0 $KARG1 $KARG2
    initrd /initramfs.cpio.gz
}
EOF
    mkdir -p "$target_dir/EFI/BOOT"
    grub-mkstandalone \
        --disable-shim-lock \
        --modules="normal linux part_gpt fat search serial configfile" \
        -O x86_64-efi \
        -o "$target_dir/EFI/BOOT/BOOTX64.EFI" \
        "boot/grub/grub.cfg=$cfg_file"
    rm -f "$cfg_file"
    cp "$KERNEL_IMAGE" "$target_dir/bzImage"
    cp "$INITRAMFS_IMAGE" "$target_dir/initramfs.cpio.gz"
}

create_partitioned_rootfs() {
    local rootfs_img="$1"
    local output_img="$2"
    (
        set -e
        local align=$((1024 * 1024))
        local sector=512
        local rootfs_size=$(stat -c %s "$rootfs_img")
        local rootfs_size_aligned=$(align_up $rootfs_size $align)
        local rootfs_start=$align
        # Leave extra room for GPT headers (1MB at start, 1MB at end)
        local total_size=$(align_up $((rootfs_start + rootfs_size_aligned + align)) $align)

        truncate -s $total_size "$output_img"

        local root_start_sector=$((rootfs_start / sector))
        local root_end_sector=$((root_start_sector + (rootfs_size_aligned / sector) - 1))

        sgdisk --zap-all "$output_img" >/dev/null
        sgdisk --new=1:${root_start_sector}:${root_end_sector} --typecode=1:8300 --change-name=1:'dstack-rootfs' "$output_img" >/dev/null

        dd if="$rootfs_img" of="$output_img" bs=$align seek=$((rootfs_start / align)) conv=notrunc status=none
    )
}

build_gcp_disk_image() {
    local disk_img="$1"
    local boot_source="$2"
    local rootfs_img="$3"
    (
        set -e
        local align=$((1024 * 1024))
        local sector=512
        local efi_size=$((256 * 1024 * 1024))
        local efi_size_aligned=$(align_up $efi_size $align)
        local rootfs_size=$(stat -c %s "$rootfs_img")
        local rootfs_size_aligned=$(align_up $rootfs_size $align)
        local efi_start=$align
        local rootfs_start=$((efi_start + efi_size_aligned))
        # Leave extra room for the backup GPT header
        local total_size=$(align_up $((rootfs_start + rootfs_size_aligned + align)) $align)

        truncate -s $total_size "$disk_img"

        local efi_start_sector=$((efi_start / sector))
        local efi_end_sector=$((efi_start_sector + (efi_size_aligned / sector) - 1))
        local root_start_sector=$((rootfs_start / sector))
        local root_end_sector=$((root_start_sector + (rootfs_size_aligned / sector) - 1))

        sgdisk --zap-all "$disk_img" >/dev/null
        sgdisk --new=1:${efi_start_sector}:${efi_end_sector} --typecode=1:ef00 --change-name=1:'EFI System Partition' "$disk_img" >/dev/null
        sgdisk --new=2:${root_start_sector}:${root_end_sector} --typecode=2:8300 --change-name=2:'dstack-rootfs' "$disk_img" >/dev/null

        local tmp_dir
        tmp_dir=$(mktemp -d)
        trap 'rm -rf "$tmp_dir"' EXIT
        local efi_img=${tmp_dir}/efi.img
        mkfs.vfat -F 32 -n DSTACKEFI -C "$efi_img" $((efi_size_aligned / 1024)) >/dev/null
        (cd "$boot_source" && mcopy -s -i "$efi_img" ./* ::) >/dev/null

        dd if="$efi_img" of="$disk_img" bs=$align seek=$((efi_start / align)) conv=notrunc status=none
        dd if="$rootfs_img" of="$disk_img" bs=$align seek=$((rootfs_start / align)) conv=notrunc status=none
    )
}

create_gcp_artifacts() {
    local gcp_dir="${OUTPUT_DIR}/gcp"
    local boot_src="${gcp_dir}/efi-root"
    mkdir -p "$boot_src"
    echo "Generating GRUB EFI loader for GCP at ${boot_src}"
    create_grub_bootstrap "$boot_src"

    local disk_img="${gcp_dir}/disk.raw"
    echo "Building raw disk image for GCP at ${disk_img}"
    build_gcp_disk_image "$disk_img" "$boot_src" "${OUTPUT_DIR}/rootfs.img.verity"

    local tarball="${DIST_DIR}/${DIST_NAME}-${DSTACK_VERSION}-gcp.tar.gz"
    echo "Archiving GCP disk image to ${tarball}"
    (cd "$gcp_dir" && tar -czvf "$tarball" disk.raw)
}

Q=verbose

$Q rm -rf ${OUTPUT_DIR}/
$Q mkdir -p ${OUTPUT_DIR}/
$Q cp $INITRAMFS_IMAGE ${OUTPUT_DIR}/initramfs.cpio.gz
$Q cp $KERNEL_IMAGE ${OUTPUT_DIR}/
$Q cp $OVMF_FIRMWARE ${OUTPUT_DIR}/
$Q cp $ROOTFS_IMAGE ${OUTPUT_DIR}/rootfs.img.verity

echo "Creating partitioned rootfs image at ${OUTPUT_DIR}/rootfs.img.parted.verity"
create_partitioned_rootfs "${OUTPUT_DIR}/rootfs.img.verity" "${OUTPUT_DIR}/rootfs.img.parted.verity"

GIT_REVISION=$(git rev-parse HEAD 2>/dev/null || echo "<unknown>")
echo "Generating metadata.json to ${OUTPUT_DIR}/metadata.json"

KARG0="console=ttyS0 init=/init panic=1 net.ifnames=0 biosdevname=0"
KARG1="mce=off oops=panic pci=noearly pci=nommconf random.trust_cpu=y random.trust_bootloader=n tsc=reliable no-kvmclock"
KARG2="dstack.rootfs_hash=$ROOT_HASH dstack.rootfs_size=$DATA_SIZE"

cat <<EOF > ${OUTPUT_DIR}/metadata.json
{
    "bios": "ovmf.fd",
    "kernel": "bzImage",
    "cmdline": "$KARG0 $KARG1 $KARG2",
    "initrd": "initramfs.cpio.gz",
    "rootfs": "rootfs.img.parted.verity",
    "version": "$DSTACK_VERSION",
    "git_revision": "$GIT_REVISION",
    "shared_ro": true,
    "is_dev": ${IS_DEV}
}
EOF

echo "Generating image digest to ${OUTPUT_DIR}/"
pushd ${OUTPUT_DIR}/
sha256sum ovmf.fd bzImage initramfs.cpio.gz metadata.json > sha256sum.txt
sha256sum sha256sum.txt | awk '{print $1}' > digest.txt
popd

if [ "$ENABLE_GCP_IMAGE" = "1" ]; then
    if command -v grub-mkstandalone >/dev/null && \
       command -v sgdisk >/dev/null && \
       command -v mkfs.vfat >/dev/null && \
        command -v mcopy >/dev/null; then
        create_gcp_artifacts
    else
        echo "Skipping GCP disk image creation because grub-mkstandalone/sgdisk/mtools are missing" >&2
    fi
fi

if [ x$DSTACK_TAR_RELEASE = x1 ]; then
    IMAGE_TAR_MR=${DIST_DIR}/mr_$(cat ${OUTPUT_DIR}/digest.txt | tr -d '\n').tar.gz
    IMAGE_TAR_NO_ROOTFS=${DIST_DIR}/${DIST_NAME}-${DSTACK_VERSION}-mr.tar.gz
    OUTPUT_DIR=$(realpath ${OUTPUT_DIR})
    rm -rf ${IMAGE_TAR} ${IMAGE_TAR_MR} ${IMAGE_TAR_NO_ROOTFS}
    echo "Archiving the output directory to ${IMAGE_TAR}"
    (cd $(dirname ${OUTPUT_DIR}) && tar -czvf ${IMAGE_TAR} $(basename $OUTPUT_DIR))
    echo
fi
