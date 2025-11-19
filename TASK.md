# GCP Boot Enablement – Working Notes

## Latest Artifacts
- Current disk bundle: `gs://wuhan-workshop-dstack/images/dstack-0.5.4-20251025-182043-diskonly.tar.gz`, published as the GCP image `dstack-tdx-image-20251025-debug28`.
- Config bundle helper: `scripts/bin/gcp-stage-config.sh` now emits signed URLs and SHA-256 digests; latest public bundle `config-bundle-config-20251020-220414.tar` (sha256 `a21c66889e1ecbda1696d0feae408691780f37268922950180b74ee58f3a4bb9`).
- Stage1 debug build staged as `gs://wuhan-workshop-dstack/images/dstack-stage1-20251027-011753-diskonly.tar.gz`, imported to GCP as image `dstack-stage1-20251027-011829` (kernel cmdline includes `dstack.debug_shell=stage1`).
- Fresh Stage1 instrumentation builds:
  - `bb-build/dist/dstack-stage1-20251027-050412-diskonly.tar.gz` (top-level `disk.raw`), imported as `dstack-stage1-20251027-050412` (TDX enabled, 35 GiB boot disk requirement).
  - `bb-build/dist/dstack-stage1-20251027-054836-diskonly.tar.gz` (includes latest Stage0 switch_root instrumentation); imported as `dstack-stage1-20251027-054836`.
- Launch recipe reminder (enable serial port, attach data disk):
  ```
  gcloud compute instances create <name> \
    --zone=us-central1-a \
    --machine-type=n2-standard-4 \
    --image=dstack-stage1-20251026-234956 \
    --boot-disk-size=10GB --boot-disk-type=pd-ssd \
    --metadata=serial-port-enable=1,dstack-config-url=…,dstack-config-sha256=… \
    --create-disk=device-name=dstack-data,name=<name>-data,size=20GB,type=pd-ssd,mode=rw,boot=no,auto-delete=yes
  ```

## Recent Progress
- Stage0 serial console is live on GCP: kernel warning toned down via `0001-dma-direct-downgrade-coherent-pool-warning.patch`, and `SERIAL_CONSOLES` now matches GCP’s 38.4k baud with optional `systemd-serialgetty` wiring for dev images.
- Remote bundle tooling refreshed (`dstack-config-bundle`, `gcp-stage-config.sh`), and Stage0 detects `DSTACK_CONFIG_*` metadata or GCP attributes before falling back to virtio-9p.
- Stage1 sentinel wiring (`/run/dstack-debug-shell-stage1`) hooked up; needs validation once Stage0 flow is unblocked.
- Instrumented Stage1 prep runs on GCP confirm overlays succeed, remote bundle download works, and the data disk is detected via `/dev/disk/by-id/scsi-0Google_PersistentDisk_dstack-data -> /dev/sdb`; when TDX is unavailable the new optional-attestation path skips quote generation and Stage1 now finishes with warnings.

## Outstanding Issues
- Stage0 drops into fallback `/tmp/.host-shared` because no metadata/env is provided; ensure GCP launches pass `dstack-config-url` and `dstack-config-sha256`.
- `dstack-debug-shell` GCP metadata currently has no effect because Stage0 reads only the `dstack.debug_shell` kernel parameter; need a plan to propagate the metadata into the kernel cmdline (mkimage flag) or consume it from Stage0.
- NVMe init still emits the downgraded DMA warning; confirm the patch does not hide a real allocation failure and pursue bounce-buffer plumbing if needed.
- Cloud launch must provide a persistent data disk; Stage1 now resolves `/dev/disk/by-id/google-dstack-data*` and Google’s `scsi-0Google_PersistentDisk_*` symlinks before falling back to `/dev/vdb`. Documentation/CLI still needs to surface the `--create-disk=device-name=dstack-data …` requirement.
- Attestation still unavailable on non-confidential (N2) instances (skipped gracefully); determine whether to enforce TDX-only machine types or keep the degraded path for smoke testing.
- Latest images staged with Stage0 debug loop: `gs://wuhan-workshop-dstack/images/dstack-stage1-20251027-082538-diskonly.tar.gz` (GCP image `dstack-stage1-20251027-082538`). Debug flow requires touching `/run/dstack-stage1-continue` in the pre-mount shell before Stage0 attempts the squashfs mount.
- Stage0 `mount -t squashfs /dev/mapper/rootfs /root` still never completes on TDX; even a `dd if=/dev/mapper/rootfs of=/dev/null bs=1M count=1` from the pre-mount shell blocks indefinitely, suggesting dm-verity I/O is hanging rather than the mount command itself. Initramfs lacks `timeout`, `lsblk`, and `blockdev`, but `/proc/filesystems` shows `squashfs` support is present.
- Fresh coherent-pool build: `bb-build/dist/dstack-stage1-20251027-215155-disk.tar.gz` (rootfs hash `bcb9ae006deca5f469b19774511e270080c591b6171f008f51bbc70c019332a1`, kernel cmdline now includes `coherent_pool=16M`). Imported as GCP image `dstack-stage1-20251027-215155` with guest OS features `TDX_CAPABLE, UEFI_COMPATIBLE, GVNIC, VIRTIO_SCSI_MULTIQUEUE`; new TDX instance `dstack-stage1-tdx-110401` launched in `us-west1-a`.
- Kernel rebuilt with `CONFIG_DMA_DIRECT_REMAP=y`/`CONFIG_DMA_COHERENT_POOL=y` in `dstack-tdx.cfg`; Stage1 image refreshed as `bb-build/dist/dstack-stage1-20251027-234938-disk.tar.gz` (rootfs hash `c9739060759e08b2b0f3014db476faee688edd6cbc4f808049e819df51cf29e3`). Imported to GCP as `dstack-stage1-20251027-234938` and relaunched `dstack-stage1-tdx-110401` (us-west1-a) with the required guest OS features.
- Added kernel patch `0002-x86-tdx-select-dma-direct-remap.patch` so `CONFIG_INTEL_TDX_GUEST` selects `DMA_DIRECT_REMAP`. Rebuilt artifacts: `bb-build/dist/dstack-stage1-20251028-001359-disk.tar.gz` (rootfs hash `d26c5fc008a565252d2785c1e03bf1cc7674f6dc696fa7121a160d7f7c6743a9`). Imported as image `dstack-stage1-20251028-001359`; launched `dstack-stage1-tdx-110401` (us-west1-a) with the same guest OS feature set—new boot logs now omit the `coherent_pool` warning.

## Next Validation Steps
- Rebuild with `bitbake virtual/kernel dstack-initramfs dstack-rootfs` (or `make dist`) after any further init tweaks, then restage the raw disk via `mkimage.sh`.
- Decide how to flip the debug shell at runtime (extend Stage0 to read metadata or regenerate the image with `DSTACK_DEBUG_SHELL=stage1`) and then re-run the Stage1 sentinel test once the flag can be toggled without rebuilding.
- Re-run validation on a TDX-capable machine type (e.g., C3D once available) or gate the attestation requirement when running on non-confidential hardware so Stage1 can complete its workflow.

## In-Flight Plan – 2025-10-27
1. Capture the Stage1 `dstack-prepare` trace from the running TDX VM via the serial console (or force it into the Stage1 debug shell) so we can see where execution stops.
2. Inspect the captured log to identify the blocking operation and decide whether we need additional instrumentation or a functional fix.
3. Patch Stage0/Stage1 as needed (e.g., auto-dumping `/tmp/run.log` to the console), rebuild the Stage1 image, and validate on the TDX instance.

### Fresh Findings
- `dstack-stage1-tdx-040223` (us-west1-a, c3-standard-4, TDX) still halts serial output immediately after `veritysetup` completes; `gcloud compute instances get-serial-port-output` never shows `dstack-prepare` log lines.
- The console repeatedly shows helper hints (`bash -x /bin/dstack-prepare.sh >/tmp/run.log 2>&1`, `sed -n "1,200p" /tmp/run.log`), confirming Stage0 dropped into the Stage1 debug helper but the log is not emitted automatically.
- Attempting to push commands over `connect-to-serial-port` (e.g., `cat /tmp/run.log`) echoes the command but returns no content, suggesting the helper script never reaches an interactive shell or the log file stays empty.
- Instance metadata already includes `dstack-config-url` and `dstack-config-sha256`, so the failure is not due to missing remote bundle configuration.
- Instrumented `dstack-prepare.sh` to tee stdout/stderr to `/var/volatile/dstack/stage1-debug.log` and `/dev/console` when the Stage1 sentinel is present, and rebuilt the Stage1 image; however, even the new TDX launch (`dstack-stage1-tdx-050412`) emits only initramfs logs—no `Stage1 preparation starting` line—pointing to either a failure around `switch_root` or console handoff before systemd starts.
- Additional initramfs instrumentation (logging around `switch_root`, exporting `SYSTEMD_LOG_*` for systemd PID 1) is now baked into `dstack-stage1-20251027-054836`. Serial capture from `dstack-stage1-tdx-054836` still stops immediately after `[init] mounting verified rootfs from /dev/mapper/rootfs`; the follow-on `rootfs mount succeeded` and `invoking switch_root` messages never appear, so the hang is occurring during or right after the squashfs mount within Stage0.
- TDX guest NVMe I/O is stalling before dm-verity: even a 4 KiB `dd` against `/dev/nvme0n1p1` or `/dev/nvme0n1p2` never completes. `/sys/block/nvme0n1/stat` shows non-zero “in flight” counts that never drain. Kernel log only reports `dma-direct: coherent pool unavailable, falling back to page allocator`, indicating we still lack a shared DMA cache for the NVMe queues.
- GCP custom image was recreated as `dstack-stage1-20251027-110401a` with `TDX_CAPABLE`, `UEFI_COMPATIBLE`, `GVNIC`, and `VIRTIO_SCSI_MULTIQUEUE` guest OS features; the new VM `dstack-stage1-tdx-110401` is running with those tags, so the remaining blocker is the missing coherent DMA pool.

### Immediate To-Do (Oct 27)
1. Append `coherent_pool=<size>` to the kernel command line in `mkimage.sh` (make it tunable via env) so Stage0 allocates shared DMA memory even if the kernel config misses the pool.
2. Rebuild the Stage1 artifacts (`bitbake virtual/kernel dstack-initramfs dstack-rootfs` + `mkimage.sh`) and re-import the image to GCP.
3. Relaunch the TDX VM, re-run the Stage0 `dd` probe, and confirm dm-verity opens successfully before proceeding to Stage1 diagnostics.
- Latest compliant Stage1 bundle: `bb-build/dist/dstack-stage1-20251028-004521-disk.tar.gz` (rootfs hash `d26c5fc008a565252d2785c1e03bf1cc7674f6dc696fa7121a160d7f7c6743a9`, kernel cmdline `... coherent_pool=16M ...`).
 - TDX guest driver was disabled; enabling `CONFIG_TDX_GUEST_DRIVER=y` to allow bounce buffers to be shared with the host. Rebuild required. - Rebuilt with `CONFIG_TDX_GUEST_DRIVER=y`; new image `bb-build/dist/dstack-stage1-20251028-012410-disk.tar.gz` (rootfs hash `7f27308f4d28d8a9ff28b5ef9e4febe0aecd20c9705c3885b35a0c0c0ed0f541`).
 - GPT warning is expected: we expand the raw image to 30G (DISK_RAW_TARGET_SIZE), so the kernel sees the backup header at the old end (61, ... sectors). Nothing to fix unless GCP enforces GPT sanity.
 - mkimage now honors DSTACK_PANIC_TIMEOUT (default -1) so images boot with panic=-1 for debugging.
