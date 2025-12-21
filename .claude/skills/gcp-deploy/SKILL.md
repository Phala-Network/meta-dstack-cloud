---
name: gcp-deploy
description: Deploy dstack TDX VM images to GCP. Use when user asks to deploy VM to GCP, create GCP instance, or test dstack image on GCP TDX.
---

# GCP TDX VM Deployment

Deploy dstack images to Google Cloud Platform with TDX (Trust Domain Extensions) support.

## Prerequisites

- `gcloud` CLI configured with appropriate project access
- GCS bucket for storing images (default: `gs://<project>-dstack`)
- A VM directory with `shared/` folder containing:
  - `app-compose.json`
  - `.sys-config.json`

## Deployment Script

Use the deployment script at `scripts/bin/gcp-deploy-vm.sh`:

```bash
scripts/bin/gcp-deploy-vm.sh \
  --vm-dir <path-to-vm-directory> \
  --project <gcp-project-id> \
  --zone <gcp-zone> \
  [--instance-name <name>] \
  [--boot-image-tar <path-to-tar.gz>] \
  [--delete]
```

## Common Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--vm-dir` | Path to VM directory with shared/ folder | Required |
| `--project` | GCP project ID | Required |
| `--zone` | GCP zone (e.g., us-central1-a) | Required |
| `--instance-name` | Instance name | dstack-vm |
| `--machine-type` | Machine type | c3-standard-4 |
| `--boot-image` | Boot disk image name | dstack-0-6-0 |
| `--boot-image-tar` | Local tar.gz to auto-upload | - |
| `--data-size` | Data disk size in GB | 20 |
| `--bucket` | GCS bucket | gs://<project>-dstack |
| `--delete` | Delete existing instance first | false |

## Typical Workflow

### 1. Find the VM directory

VM directories are in the meta-dstack build directory:
```bash
# List all VMs in the build run directory
ls -la build/run/vm/

# If user provides a VM ID, construct the path directly:
# build/run/vm/<vm-id>
```

The VM directory path pattern is: `<meta-dstack-root>/build/run/vm/<vm-id>/`

### 2. Find the boot image

Boot images are built by meta-dstack:
```bash
ls -la build/images/dstack-*-gcp.tar.gz
```

### 3. Deploy

```bash
scripts/bin/gcp-deploy-vm.sh \
  --vm-dir build/run/vm/<vm-id> \
  --project wuhan-workshop \
  --zone us-central1-a \
  --instance-name dstack-test \
  --boot-image-tar build/images/dstack-0.6.0-gcp.tar.gz \
  --delete
```

## Post-Deployment

### Check serial output
```bash
gcloud compute instances get-serial-port-output <instance-name> \
  --zone=<zone> --project=<project>
```

### SSH into instance
```bash
gcloud compute ssh <instance-name> --zone=<zone> --project=<project>
```

### Check dstack-setup service logs
```bash
gcloud compute ssh <instance-name> --zone=<zone> --project=<project> \
  --command="sudo journalctl -u dstack-setup -f"
```

### Get external IP
```bash
gcloud compute instances describe <instance-name> \
  --zone=<zone> --project=<project> \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

## Troubleshooting

### Instance creation fails
- Check if boot image exists: `gcloud compute images list --project=<project> | grep dstack`
- Check if data disk image exists: `gcloud compute images describe dstack-data-disk --project=<project>`

### Boot image upload
The script auto-uploads boot image if `--boot-image-tar` is provided and:
- GCP image doesn't exist, or
- Local tar.gz is newer than GCP image

### Delete and recreate
Use `--delete` flag to remove existing instance before creating new one.
