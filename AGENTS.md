# Repository Guidelines

## Project Structure & Module Organization
Yocto layers live under `meta-dstack`, `meta-confidential-compute`, `meta-security`, and the `meta-openembedded` subsets; keep new recipes in the layer that matches their domain. Shared build scripts reside in `mk.d/` and `mkimage.sh`. Generated build state defaults to `bb-build/`, with reusable configuration stubs in `bb-build/conf/`. Reproducible pipelines live in `repro-build/`, and helper utilities are in `scripts/bin/`; update these when adding new developer tooling.

## Build, Test, and Development Commands
Run `source dev-setup` from the repo root to populate `BBPATH` and register all layers. Use `bitbake virtual/kernel dstack-initramfs dstack-ovmf dstack-rootfs` for a full local image build, or call `make dist` to build images and package them under `bb-build/dist/`. CI-style reproducible builds execute via `./repro-build/repro-build.sh`. Clean individual targets with `bitbake -c cleansstate <recipe>` (for example `bitbake -c cleansstate dstack-guest`).

## Coding Style & Naming Conventions
BitBake recipes use uppercase variable names, assignments aligned with a single space, and four-space indentation within functions (`do_install`, `do_compile`, etc.). Prefer hyphenated recipe identifiers (`dstack-guest`, `dstack-rootfs`). Shell scripts follow POSIX sh or bash with `set -euo pipefail` when feasible, and Makefiles retain GNU make default tab-indented rules. Run `bitbake-layers show-recipes` to confirm new metadata is discoverable before submitting.

## Testing Guidelines
When touching recipes or layer metadata, run the relevant `bitbake` task (`bitbake <recipe>` or `bitbake -c testimage dstack-rootfs`) to confirm builds succeed. For Rust components synced from `dstack/`, ensure upstream `cargo test --all` passes before re-vendoring. Attach build logs from `tmp/log/cooker/` or `tmp/work/.../temp/log.do_*` when reporting or fixing failures.

## Commit & Pull Request Guidelines
Use imperative, scope-prefixed commit subjects (`dstack-guest: add journald override`) and keep body text wrapped at ~72 columns with rationale and testing notes. Avoid merge commits in feature branches. Pull requests should reference related issues, summarize layer impacts, list tested `bitbake` targets, and include screenshots or log excerpts if they clarify runtime changes. Tag reviewers responsible for the affected layer so they can verify integration.

## Agent Knowledge: meta-dstack & dstack Overview
- `meta-dstack` hosts Yocto layers plus helper scripts for building confidential VMs; reusable configs live in `bb-build/`, build scripts in `mk.d/`, and reproducible pipelines under `repro-build/`.
- dstack platform services (shared via submodule `dstack/`) form a TDX-based confidential computing stack: `dstack-vmm` orchestrates CVMs, `dstack-kms` manages attestation & keys, `dstack-gateway` handles ingress/TLS/WireGuard, and `dstack-guest-agent` runs inside CVMs to bridge apps with KMS.
- Deployment flow: blockchain smart contracts (DstackKms/DstackApp) authorize compose hashes & device IDs → VMM provisions CVMs from `app-compose.json` + encrypted env → guest agent requests keys via RA-TLS and registers with gateway.
- Tooling highlights: `vmm-cli.py` and the VMM web console drive VM lifecycle; environment secrets are X25519+AES-GCM encrypted with KMS pubkeys; gateway generates per-instance dashboards via RA-TLS and WireGuard.
- Application dev loop: craft `app-compose.json` using repo guidelines, encrypt env vars, whitelist compose hash on-chain, then `CreateVm` (full build via `bitbake virtual/kernel dstack-rootfs` or `make dist`).
- Keep TDX security model in mind—attestation quotes embed compose/device data, KMS verifies OS image hashes, and RA-TLS certs chain to measured hardware state.

## Issue #125 Research Notes
- Targeted goal: run dstack OS on GCP/Azure while preserving separation of system (OS) and application layers; keep OS image MR static and let app MR cover compose/config data.
- Current release artifact (`mkimage.sh`) ships `bzImage`, `initramfs.cpio.gz`, `rootfs.img.verity`, `ovmf.fd`, `metadata.json`; needs to emit a single raw disk image + manifest digest for cloud import.
- dstack-vmm now writes `app-compose.json`, `sys-config.json`, encrypted env, etc. into `run/<vm>/shared/` and the guest pulls via virtio-9p; on cloud this must shift to a remote bundle (e.g. GCS object) fetched at boot with integrity verification.
- dstack-util Stage0 now detects remote bundle specs via `DSTACK_CONFIG_*` env vars or GCP metadata, fetches and verifies the archive, and falls back to `/tmp/.host-shared` when nothing is advertised.
- On GCP today we are still hitting the fallback path because no metadata/env is set; `dstack-prepare` fails when `host-shared` is absent. Next iteration needs to provide the remote bundle or relax the fallback.
- Helper: `scripts/bin/gcp-stage-config.sh` uploads `bb-build/dist/config-bundle.tar` to GCS, computes the SHA-256, and prints the `--metadata dstack-config-url=…,dstack-config-sha256=…` snippet; pass `-s 2h` to emit a signed URL if you don’t want the object public.
- Current public config bundle (Oct 20, 2025): `gs://wuhan-workshop-dstack/configs/config-bundle-config-20251020-220414.tar` (`https://storage.googleapis.com/wuhan-workshop-dstack/configs/config-bundle-config-20251020-220414.tar`, SHA-256 `a21c66889e1ecbda1696d0feae408691780f37268922950180b74ee58f3a4bb9`).
- dstack-mr supports `--profile gcp` with a `--gcp-launch-endorsement` binarypb, reusing Google’s `VmTdx.Measurement` MRTD for the configured RAM/early-accept combination and verifying the launch endorsement signature when `--gcp-signer-cert` is supplied.
- dstack-mr currently models QEMU/TDX baremetal; GCP publishes firmware launch endorsements (`gs://gce_tcb_integrity/.../<MRTD>.binarypb`). New profile should parse/verify protobuf and bake the measurement into the TDX machine builder.
- External discussion confirmed requirements and pointed to Google’s “Verify firmware” doc; no existing repo code for GCP profile.
- Risks: bootloader choice for raw image (UEFI) and ensuring app bundle integrity extends RTMR3 correctly when delivered remotely.
