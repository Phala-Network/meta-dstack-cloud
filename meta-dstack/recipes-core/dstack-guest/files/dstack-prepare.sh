#!/bin/bash

# SPDX-FileCopyrightText: © 2025 Phala Network <dstack@phala.network>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DEBUG_STAGE1=0
DEBUG_LOG_PATH="/var/volatile/dstack/stage1-debug.log"

abort() {
    status=$?
    log "dstack-prepare aborted (status=${status}) at line ${BASH_LINENO[0]:-unknown} running \"${BASH_COMMAND}\""
    if [ "${DEBUG_STAGE1}" -eq 1 ]; then
        log "Stage1 debug shell (error path)"
        exec /bin/bash -i </dev/console >/dev/console 2>&1
    fi
    exit $status
}

trap abort ERR

WORK_DIR="/var/volatile/dstack"
DATA_MNT="$WORK_DIR/persistent"
STAGE1_SENTINEL="/run/dstack-debug-shell-stage1"

OVERLAY_TMP="/var/volatile/overlay"
OVERLAY_PERSIST="$DATA_MNT/overlay"
DATA_DEVICE_DEFAULT="/dev/vdb"

log() {
    echo "$@" >&2
}

dump_dmesg_tail() {
    if command -v dmesg >/dev/null 2>&1; then
        log "Kernel log tail:"
        dmesg | tail -n 20 | while IFS= read -r line; do
            log "  $line"
        done
    fi
}

ensure_overlay_ready() {
    if grep -qw overlay /proc/filesystems 2>/dev/null; then
        log "overlay filesystem support present"
        return 0
    fi
    log "overlay filesystem missing; attempting to load kernel module"
    if modprobe overlay 2>/dev/null; then
        log "overlay kernel module loaded"
        return 0
    fi
    log "failed to load overlay kernel module"
    dump_dmesg_tail
    return 1
}

resolve_data_device() {
    if [ -b "$DATA_DEVICE_DEFAULT" ]; then
        log "Using default data device ${DATA_DEVICE_DEFAULT}"
        printf '%s\n' "$DATA_DEVICE_DEFAULT"
        return 0
    fi

    local resolved symlink
    for symlink in /dev/disk/by-id/google-dstack-data /dev/disk/by-id/google-dstack-data-*; do
        [ -e "$symlink" ] || continue
        resolved=$(readlink -f "$symlink" 2>/dev/null || true)
        if [ -n "$resolved" ] && [ -b "$resolved" ]; then
            log "Resolved data device via ${symlink} -> ${resolved}"
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    for symlink in /dev/disk/by-id/scsi-0Google_PersistentDisk_*; do
        [ -e "$symlink" ] || continue
        case "$symlink" in
            */scsi-0Google_PersistentDisk_persistent-disk-0* ) continue ;;
            *-part[0-9]* ) continue ;;
        esac
        resolved=$(readlink -f "$symlink" 2>/dev/null || true)
        if [ -n "$resolved" ] && [ -b "$resolved" ]; then
            log "Resolved data device via ${symlink} -> ${resolved}"
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    return 1
}

log "Stage1 preparation starting (pid=$$)"

if [ -f "$STAGE1_SENTINEL" ]; then
    DEBUG_STAGE1=1
    rm -f "$STAGE1_SENTINEL"
fi

if [ "${DEBUG_STAGE1}" -eq 1 ]; then
    if command -v tee >/dev/null 2>&1; then
        : >"${DEBUG_LOG_PATH}"
        log "Stage1 debug sentinel found; mirroring output to ${DEBUG_LOG_PATH} and /dev/console"
        exec > >(tee -a "${DEBUG_LOG_PATH}" | tee /dev/console > /dev/null)
        exec 2>&1
    else
        : >"${DEBUG_LOG_PATH}"
        log "Stage1 debug sentinel found; tee unavailable, logging to ${DEBUG_LOG_PATH} only"
        exec >>"${DEBUG_LOG_PATH}"
        exec 2>>"${DEBUG_LOG_PATH}"
    fi
    export BASH_XTRACEFD=2
    set -x
    log "Stage1 debug instrumentation armed; interactive shell will follow completion"
fi

ensure_overlay_ready

mount_overlay() {
    local src=$1
    local base=$2
    local rel_src=${src#/}
    local dst="$base/$rel_src"

    log "Preparing overlay for ${src} (upper=${dst}/upper)"

    if [ ! -d "$src" ]; then
        log "Source ${src} missing; creating directory"
        mkdir -p "$src"
    fi
    mkdir -p "${dst}/upper" "${dst}/work"
    if ! mount -t overlay overlay -o "lowerdir=$src,upperdir=${dst}/upper,workdir=${dst}/work" "$src"; then
        log "overlay mount failed for ${src}"
        dump_dmesg_tail
        return 1
    fi
    log "Overlay ready for ${src}"
}
mount_overlay /etc/wireguard "$OVERLAY_TMP"
mount_overlay /etc/docker "$OVERLAY_TMP"
mount_overlay /usr/bin "$OVERLAY_TMP"
mount_overlay /home/root "$OVERLAY_TMP"

# Disable the containerd-shim-runc-v2 temporarily to prevent the containers from starting
# before docker compose removal orphans. It will be enabled in app-compose.sh
chmod -x /usr/bin/containerd-shim-runc-v2

# Make sure the system time is synchronized
log "Syncing system time..."
chronyc makestep

if modprobe tdx-guest 2>/dev/null; then
    log "Loaded tdx-guest kernel module"
else
    log "tdx-guest module unavailable; continuing without TDX driver"
    export DSTACK_ATTESTATION_OPTIONAL=1
fi

# Setup dstack system
log "Preparing dstack system..."
if DATA_DEVICE=$(resolve_data_device); then
    log "Persistent data device located at ${DATA_DEVICE}"
else
    log "Persistent data device not found; expected ${DATA_DEVICE_DEFAULT} or /dev/disk/by-id/google-dstack-data*"
    log "Attach a secondary disk (e.g., --create-disk=device-name=dstack-data,boot=no) before launching the VM"
    exit 1
fi
dstack-util setup --work-dir "$WORK_DIR" --device "$DATA_DEVICE" --mount-point "$DATA_MNT"

log "Mounting docker dirs to persistent storage"
mkdir -p "$DATA_MNT/var/lib/docker"
log "  rbind ${DATA_MNT}/var/lib/docker -> /var/lib/docker"
mount --rbind "$DATA_MNT/var/lib/docker" /var/lib/docker
log "  rbind ${WORK_DIR} -> /dstack"
mount --rbind "$WORK_DIR" /dstack
mount_overlay /etc/users "$OVERLAY_PERSIST"

log "Switching to /dstack work tree"
cd /dstack

if [ "$(jq 'has("init_script")' app-compose.json)" == true ]; then
    log "Running init script"
    dstack-util notify-host -e "boot.progress" -d "init-script" || true
    # shellcheck disable=SC1090
    source <(jq -r '.init_script' app-compose.json)
fi

log "Stage1 preparation complete"

if [ "${DEBUG_STAGE1}" -eq 1 ]; then
    log "Stage1 debug shell launching (success path)"
    exec /bin/bash -i </dev/console >/dev/console 2>&1
fi
