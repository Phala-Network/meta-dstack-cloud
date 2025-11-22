# Yocto support for DStack Guest

This project implements Yocto layer and the overall build scripts for DStack Base OS image.

## Build

See https://github.com/Dstack-TEE/dstack for more details.

## Runtime Kernel Parameters

The guest initramfs recognises a few `dstack.*` kernel cmdline parameters to drive early boot:

- `dstack.rootfs_hash` and `dstack.rootfs_size` are required to unlock the dm-verity protected squashfs rootfs.
- `dstack.rootfs_device` (optional) overrides the default `/dev/vda` block device that stores the verity data and hash. Set this when the root filesystem lives on a different disk or naming scheme (for example `/dev/sdb`, `PARTLABEL=dstack-rootfs`).

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
