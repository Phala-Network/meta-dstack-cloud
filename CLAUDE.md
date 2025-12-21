# CLAUDE.md

This file provides guidance to Claude Code when working with the meta-dstack Yocto layer.

## Build Commands

### Guest Image Build

Build guest images (rootfs, initramfs, kernel, UKI) using:

```bash
cd build/
../build.sh guest
```

This runs bitbake to build all guest components including:
- `dstack-rootfs` - Main rootfs with dm-verity
- `dstack-initramfs` - Initramfs for boot
- `dstack-uki` - Unified Kernel Image for GCP

### Host Components Build

```bash
../build.sh host
```

### Generate Config Files

```bash
../build.sh cfg
```

### Full Build

```bash
../build.sh all
```

## Directory Structure

- `meta-dstack/` - Main Yocto layer with dstack recipes
- `meta-confidential-compute/` - Base CVM layer (submodule)
- `poky/` - Yocto core (submodule)
- `build/` - Default build directory
- `mkimage.sh` - Script to package final images (called by Makefile)

## Key Configuration Files

- `build/conf/local.conf` - Local build configuration (MACHINE, DISTRO)
- `build/conf/bblayers.conf` - Layer configuration
- `meta-dstack/conf/distro/dstack.conf` - dstack distro configuration

## Image Packaging

After bitbake build completes, run:

```bash
make dist DIST_DIR=./images BB_BUILD_DIR=./build
```

Or use `mkimage.sh` directly:

```bash
./mkimage.sh --dist-name dstack
```

The packaging process automatically generates:
- `dstack-uki.efi.auth_hash.txt` - PE/COFF Authenticode hash of UKI for TPM Event Log verification

## GCP Deployment

Deploy GCP image using:

```bash
scripts/bin/gcp-deploy-image.sh --tar images/dstack-X.Y.Z-gcp.tar.gz
```

## SSH Access to Test Instances

**IMPORTANT**: Always use direct SSH commands, NOT gcloud compute ssh.

- GCP test instance: `ssh testgcp`
- DO NOT use: `gcloud compute ssh testgcp --zone=...`

## RA-TLS Feature Flags

The `ra-tls` library supports optional features:

- **`vtpm-quote`**: Enables vTPM quote collection functionality (requires native tpm-attest library)
  - **Device side** (generates quotes): Enable this feature (e.g., `guest-agent`)
  - **Verifier side** (verifies quotes): Do NOT enable this feature (avoids native library dependency)
  - Example: `ra-tls = { workspace = true, features = ["vtpm-quote"] }`

When `vtpm-quote` is disabled:
- vTPM quote **verification** still works (no native library needed)
- vTPM quote **generation** will return an error: "vTPM quote collection requires 'vtpm-quote' feature"

## Attestation Mode Detection

The `AttestationMode::detect()` function automatically detects the platform and selects the appropriate attestation mode:

**Detection Priority**:
1. **DMI Board Name** (from `/sys/class/dmi/id/board_name`):
   - `"dstack"` → TDX only mode (no vTPM)
   - `"Google Compute Engine"` → TDX + vTPM dual mode (GCP)
2. **Fallback to Device Detection** (if board name is unknown):
   - `/dev/tdx_guest` + `/dev/tpmrm0` → TDX + vTPM dual mode
   - `/dev/tdx_guest` only → TDX only mode
   - `/dev/tpmrm0` only → vTPM only mode

This ensures dstack platforms use TDX-only attestation even if vTPM hardware is present.

## GCP TPM Attestation

### Root CA Certificate

The GCP TPM root CA certificate is **embedded in the tpm-qvl library**:
```rust
use tpm_qvl::GCP_ROOT_CA;
```

**Certificate details**:
- Location: `dstack/tpm-qvl/certs/gcp-root-ca.pem` (embedded at compile time)
- Subject: `CN=EK/AK CA Root, OU=Google Cloud, O=Google LLC, L=Mountain View, ST=California, C=US`
- Issuer: Self-signed
- Valid: 2022-07-08 to 2122-07-08 (100 years)

The certificate is embedded in tpm-qvl (like dcap-qvl) due to its long validity period.
No external certificate file is needed on the verifier.

### Obtaining AK Certificate from GCP VM

The Attestation Key (AK) certificate can be read from TPM NVRAM on testgcp:

```bash
ssh testgcp "tpm2_nvread 0x1c00002 > ak_cert.der"
```

The certificate chain is:
1. **AK Certificate** (from TPM NVRAM 0x1c00002)
   - Issuer: `CN=EK/AK CA Intermediate`
2. **Intermediate CA** (from AIA URL in AK cert)
   - Issuer: `CN=EK/AK CA Root`
3. **Root CA** (stored in repository)
   - Issuer: Self-signed

**DO NOT** re-fetch the root CA certificate - it's already in the repository.

### TPM Event Log and Image Verification

TPM quotes include PCR 2 Event Log for verifying the boot chain. The verifier:

1. **Replays Event Log** to verify PCR values match the quote
2. **Extracts Event 28** (3rd event in PCR 2) which contains the UKI Authenticode hash
3. **Compares against expected hash** from `dstack-uki.efi.auth_hash.txt`

**IMPORTANT**: Extracting the 3rd event from PCR 2 is **GCP OVMF-specific behavior**.
On GCP, PCR 2 events are ordered as:
- Event 0: EV_SEPARATOR
- Event 1: EV_EFI_GPT_EVENT (GPT hash)
- Event 2: EV_EFI_BOOT_SERVICES_APPLICATION (UKI hash) ← **This is Event 28**
- Event 3: EV_EFI_BOOT_SERVICES_APPLICATION (Linux kernel hash)

Other platforms may have different event ordering.

See `dstack/docs/tpm/GCP_PCR_ANALYSIS.md` for detailed analysis of PCR measurements.

