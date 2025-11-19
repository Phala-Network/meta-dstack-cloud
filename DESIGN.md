# Design: Cloud-Compatible dstack OS Deployment (Issue #125)

## Goals
- Enable deployment of dstack OS on public clouds (initially GCP, Azure next) while keeping the system/app split intact, so OS images have stable measurements and apps ship separately.
- Replace the virtio-9p `host-shared` path with a remote configuration bundle (HTTP/GCS/S3/IPFS) that the guest downloads and verifies.
- Extend `dstack-mr` with cloud-specific profiles (start with GCP) so we can compute/whitelist expected measurements.
- Maintain an auditable, loophole-free trust chain from the build pipeline through VM launch and runtime attestation.

## Current Baseline
- `mkimage.sh` builds `bzImage`, `initramfs.cpio.gz`, `rootfs.img.verity`, `ovmf.fd`, `metadata.json`, and digest files; releases ship these in a tarball.
- `dstack-vmm` provisions a CVM by writing `app-compose.json`, `sys-config.json`, `encrypted-env`, `user-config`, and `instance-info` into `run/<vm-id>/shared/`; guest Stage0 mounts `/tmp/.host-shared` to fetch them.
- `dstack-util` Stage0 extends RTMR3 with compose hash, key provider info, etc., then Stage1 decrypts env and fetches keys from KMS.
- `dstack-mr` CLI builds a machine model for local/QEMU TDX firmware and outputs MRTD/RTMR₀₋₂; no cloud-specific handling yet.

## Cloud Deployment Requirements

### 1. Disk Image Packaging
- Produce a bootable disk image (GPT-based, raw or VHD), not just separate kernel/initramfs/rootfs files.
- Keep a JSON manifest mapping to the new image so dstack components and attestors know which OS build is running.
- Ensure the image boots under QEMU (for local testing) and is importable by GCP (raw tarball) and Azure (VHD requirement).

### 2. Remote App Configuration Delivery
- Create a signed config bundle (tarball) that contains `app-compose.json`, `sys-config.json`, `encrypted-env`, `user-config`, etc.
- Provide tooling to build the bundle, compute its hash, and upload to storage (GCS/S3/IPFS). Optionally sign with operator key.
- Replace guest Stage0’s dependency on `/tmp/.host-shared` with logic that fetches the bundle using VM metadata (while still supporting legacy virtfs for bare metal).
- After verification, Stage0 extracts the bundle into the usual paths and continues extending RTMR3, so the measurement story is unchanged.

### 3. Attestation Profiles
- Add `--profile` support to `dstack-mr`. The first profile covers GCP TDX:
  - Download Google’s `VMLaunchEndorsement` from `gs://gce_tcb_integrity/.../<MRTD>.binarypb`.
  - Parse the protobuf (`VMLaunchEndorsement { serialized_uefi_golden, signature }`).
  - Verify the signature against Google’s published key.
  - Incorporate the golden EFI measurement into the machine model and compute MRTD/RTMR values for the OS image.
- Document expectations for Azure (confidential VMs use AMD SEV-SNP today; TDX is on the roadmap). For our design, assume a similar `launch endorsement` exists; we’ll expose an extension hook so we can add an `--profile azure` later.

### 4. Trust Chain Strategy
- OS Image: sign/digest stored in `metadata.json` and preapproved by KMS; cloud-specific profiles ensure the computed MRTD matches the running firmware.
- Configuration Bundle: metadata keys include the bundle URL, SHA-256 hash, and optional signature. Stage0 refuses to proceed if verification fails.
- App Layer: same RTMR3 extensions as today, ensuring the compose hash that KMS sees is tied to the downloaded bundle.
- KMS Policy: continue whitelisting (OS image hash + compose hash) on-chain; KMS gates key delivery on a Remote Attestation report matching those values.
- Network/Metadata Security: leverage IMDS (GCP) or Instance Metadata Service (Azure) to pass configuration references. Harden further by signing metadata with a key already recorded in the blockchain whitelist.

## GCP-Specific Plan
1. Package `mkimage.sh` output into a raw disk image with the td guest rootfs and add a `version.json` or `metadata.json` pointing to digests.
2. Upload the disk image to GCS (or import into Compute Engine as custom image).
3. Build the config bundle, upload to GCS, and set VM metadata:
   - `dstack-config-url`
   - `dstack-config-sha256`
   - `dstack-config-signature` (optional)
4. Inside the guest, Stage0 reads metadata, downloads the bundle via authorized means (service account or signed URL), verifies it, unpacks, and proceeds to Stage1.
5. `dstack-mr --profile gcp` intake: pass the OS metadata + GCP launch endorsement to calculate expected MRTD/RTMR.
6. Update documentation with import/run steps and attestation verification instructions (using `gs://gce_tcb_integrity/...`).

## Azure Considerations (Future Work)
- Azure Confidential Computing currently offers AMD SEV-SNP; Intel TDX support is emerging. We avoid hardcoding QEMU-specific logic, so adding `--profile azure` is just a matter of adding the measurement source.
- Azure IMDS exposes similar metadata endpoints (`http://169.254.169.254/metadata/`). We can use the same bundle approach (signed URL or managed identity with Key Vault/Blob Storage).
- Document expectations: trust bundle is still downloaded by Stage0; the difference lies in which `launch endorsement` (Azure attestation token) we verify.
- Implementation details can wait until Azure support is customer-ready.

## Implementation Roadmap (Proof of Concepts)

### PoC 1 – Disk Image Packaging
- Extend `mkimage.sh` to emit `disk.raw` (GPT + EFI + root partition) and keep component metadata. Boot in local QEMU to confirm.
- Optionally run `gcloud compute images import` to smoke-test compatibility.
- Implementation detail: `mkimage.sh` now drives `wic` with a generated systemd-boot + rawcopy `.wks`, producing `disk.raw` and a fixed-size `disk.vhd`; metadata embeds hashes and command line, while Stage0 resolves the `dstack-rootfs` partition label before unlocking dm-verity.

### PoC 2 – Remote Config Fetch
- Stage0 now discovers a bundle spec via `DSTACK_CONFIG_*` env vars or GCP metadata (`dstack-config-{url,sha256,signature}`), downloads it with `reqwest`, enforces SHA-256 if provided, and unpacks into the host-shared cache; legacy virtio-9p is used as a fallback when no remote spec is present.
- Next validation: run a VM without host-shared and ensure the app boots, RTMR3 extends correctly, and KMS completes attestation.

### PoC 3 – GCP Measurement Support
- `dstack-mr` now accepts `--profile gcp --gcp-launch-endorsement <file>` and parses Google’s `VMLaunchEndorsement` protobuf, using the `VmTdx.Measurement` entry matching RAM/early-accept to override MRTD; pass `--gcp-signer-cert` with the trusted signer certificate to enforce signature checks.
- Validate against actual GCE TDX measurements (manually or via unit tests using fixture data); provenance/chain verification beyond the provided signer certificate remains follow-up work.

### PoC 4 – Metadata-Plumbed Boot
- Launch a GCE TDX VM with the new disk image, metadata keys, and config bundle URL; verify Stage0 fetches configs and the app launches.
- Collect an RA report to confirm MRTD/RTMR values match `dstack-mr --profile gcp` output.

Once all PoCs are validated, integrate changes:
- Update release tooling (`mkimage.sh`, `make dist`).
- Extend `dstack-vmm`/`vmm-cli.py` with a `--config-url` path for cloud deployments.
- Merge Stage0/Stage1 changes and add tests (unit/integration as appropriate).
- Document the cloud workflow (build → upload → set metadata → boot → attestation).

## Risks & Mitigations
- Bootloader/EFI complexity on cloud images.
  - Mitigation: Start with a simple GRUB or systemd-boot loader that hands off to our existing kernel + initramfs. Test in local QEMU and iterate.
- Bandwidth/SLA issues with fetching config bundles.
  - Mitigation: fail fast on checksum errors; consider mirroring or caching.
- Metadata tampering.
  - Mitigation: use signed metadata values and validate against on-chain or KMS-trusted key.
- Differences between virtualization stacks (firmware versions).
  - Mitigation: profile-based measurement calculation; treat any mismatch as a deployment killer until resolved.

## Next Steps
1. Prototype disk image (`mkimage.sh` branch).
2. Prototype Stage0 remote bundle download + RTMR3 extension.
3. Implement `dstack-mr --profile gcp` with launch endorsement parsing.
4. Wire metadata integration on GCP, update docs, and add integration tests or manual runbooks.
5. Document Azure expectations so future work can plug into the same architecture.
