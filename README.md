# Yocto support for DStack Guest

This project implements Yocto layer and the overall build scripts for DStack Base OS image.

## Build

See https://github.com/Dstack-TEE/dstack for more details.

## Runtime Kernel Parameters

The guest initramfs recognises a few `dstack.*` kernel cmdline parameters to drive early boot:

- `dstack.rootfs_hash` and `dstack.rootfs_size` are required to unlock the dm-verity protected squashfs rootfs.
- `dstack.rootfs_device` (optional) overrides the default `/dev/vda` block device that stores the verity data and hash. Set this when the root filesystem lives on a different disk or naming scheme (for example `/dev/sdb`, `PARTLABEL=dstack-rootfs`, or `/dev/disk/by-id/...`).
- `dstack.data_dev` (optional) overrides the persistent data disk picked by `dstack-prepare`. It accepts the same values as `dstack.rootfs_device` (absolute paths or `PARTLABEL=/PARTUUID=` selectors) and is useful on clouds that only expose NVMe namespaces.
- `coherent_pool=8M` (always added) ensures the DMA atomic pool is large enough for early NVMe/verity traffic on clouds that lack bounce buffers (for example GCP TDX).

## Google Cloud image output

`mkimage.sh` now emits a unified UEFI disk image that can be uploaded to Google Cloud Platform and used with Intel TDX guest VMs. After a successful build the following artifacts are produced in `images/<dist>-<ver>/gcp/`:

- `disk.raw`: raw GPT disk containing an EFI boot partition with a unified kernel image plus the dm-verity protected rootfs.
- `${DIST_NAME}-${DISTRO_VERSION}-gcp.tar.gz` (in the `images` directory) that wraps `disk.raw` in the format expected by `gcloud compute images import`.

Set `ENABLE_GCP_IMAGE=0` when invoking `mkimage.sh` if you need to disable the extra artifact generation.

## Reproducible Build The Guest Image

### Pre-requisites

- X86_64 Linux system with Docker installed

### Build commands

```bash
git clone https://github.com/Dstack-TEE/meta-dstack.git
cd meta-dstack/repro-build/
./repro-build.sh
```

## License

This project is licensed under the MIT License. See the LICENSE file for more details.
