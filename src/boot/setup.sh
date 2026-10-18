#!/bin/sh
# Install PCInfo tools from pre-downloaded APKs on USB, then mount USB for GPU driver access.
# BIOS/UEFIのMemtest一回起動はGRUBのgrubenvで管理する。
. /opt/pcinfo/common.sh || exit 1
USB_MNT="/mnt/usb"
DEV=""

setup_failed() {
    printf '%s\n' "$1" > "$BOOT_STATUS_FILE"
    printf 'PCInfo setup failed: %s\n' "$1" >&2
    exit 1
}

# Clear any previous success before attempting preparation again.
mkdir -p "${BOOT_STATUS_FILE%/*}" || exit 1
printf '%s\n' 'Startup setup did not complete.' > "$BOOT_STATUS_FILE" || exit 1

is_mounted() {
    grep -Fqs " $1 " /proc/mounts 2>/dev/null
}

mkdir -p "$USB_MNT" || setup_failed 'Cannot create the USB mount directory.'

# Find where Alpine has already mounted the USB
for mp in /media/usb /media/sd* /media/vd* /media/mmcblk* /media/nvme* /media/LABEL=PCINFO; do
    [ -d "$mp" ] || continue
    if is_mounted "$mp" && { [ -d "$mp/apks" ] || [ -d "$mp/drivers" ]; }; then
        mount --bind "$mp" "$USB_MNT" 2>/dev/null && break
    fi
done

# Fallback: resolve by label, then mount by device
if ! is_mounted "$USB_MNT"; then
    if [ -e /dev/disk/by-label/PCINFO ]; then
        DEV=$(readlink -f /dev/disk/by-label/PCINFO 2>/dev/null)
    elif command -v findfs >/dev/null 2>&1; then
        DEV=$(findfs LABEL=PCINFO 2>/dev/null)
    elif command -v blkid >/dev/null 2>&1; then
        DEV=$(blkid -L PCINFO 2>/dev/null)
        [ -n "$DEV" ] || DEV=$(blkid -t LABEL=PCINFO -o device 2>/dev/null | head -n 1)
    fi
    [ -n "$DEV" ] && mount -t vfat "$DEV" "$USB_MNT" 2>/dev/null || true
fi

if ! is_mounted "$USB_MNT"; then
    for DEV in /dev/sd[a-z][0-9] /dev/vd[a-z][0-9] /dev/mmcblk[0-9]p[0-9] /dev/nvme[0-9]n[0-9]p[0-9]; do
        [ -b "$DEV" ] || continue
        mount -t vfat "$DEV" "$USB_MNT" 2>/dev/null && break
    done
fi

# Install pre-downloaded .apk files directly (bypass APKINDEX lookup)
APK_DIR="$USB_MNT/apks/x86_64"
is_mounted "$USB_MNT" || setup_failed 'The PCInfo USB could not be mounted.'
[ -d "$APK_DIR" ] || setup_failed 'The USB APK package directory is missing.'
set -- "$APK_DIR"/*.apk
[ -f "$1" ] || setup_failed 'No APK packages were found on the USB.'
for package in "$@"; do
    [ -r "$package" ] || setup_failed 'An APK package could not be read.'
done
command -v apk >/dev/null 2>&1 || setup_failed 'The APK package manager is missing.'
# 依存閉包の全APKを明示する。community由来のパッケージも通信なしで導入する。
apk add --allow-untrusted --force-non-repository --no-network "$@" \
    || setup_failed 'APK package installation failed.'
for tool in bash dialog smartctl nvme lspci dmidecode lsblk jq; do
    command -v "$tool" >/dev/null 2>&1 || setup_failed "A required tool is missing: $tool"
done
printf '%s\n' ready > "$BOOT_STATUS_FILE" || setup_failed 'Cannot record successful startup setup.'

exit 0
