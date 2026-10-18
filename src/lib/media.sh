#!/bin/sh
# PCInfo USB mount operations; preserve the existing search order.

# Mount USB by label (PCINFO) to /mnt/usb
USB_MOUNT="/mnt/usb"
USB_MOUNT_OWNED=0
mount_usb() {
    local dev mp

    if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
        USB_MOUNT_OWNED=0
        return 0
    fi
    mkdir -p "$USB_MOUNT"

    for mp in /media/usb /media/sd* /media/vd* /media/mmcblk* /media/nvme* /media/LABEL=PCINFO; do
        [ -d "$mp" ] || continue
        if mountpoint -q "$mp" 2>/dev/null && { [ -d "$mp/apks" ] || [ -d "$mp/drivers" ]; }; then
            mount --bind "$mp" "$USB_MOUNT" 2>/dev/null || continue
            USB_MOUNT_OWNED=1
            return 0
        fi
    done

    if [ -e /dev/disk/by-label/PCINFO ]; then
        dev=$(readlink -f /dev/disk/by-label/PCINFO 2>/dev/null)
        if [ -n "$dev" ] && mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi
    fi

    if command -v findfs >/dev/null 2>&1; then
        dev=$(findfs LABEL=PCINFO 2>/dev/null)
        if [ -n "$dev" ] && mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi
    fi

    if command -v blkid >/dev/null 2>&1; then
        dev=$(blkid -L PCINFO 2>/dev/null)
        if [ -n "$dev" ] && mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi

        dev=$(blkid -t LABEL=PCINFO -o device 2>/dev/null | head -n 1)
        if [ -n "$dev" ] && mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi
    fi

    # Fallback: try common partition device paths
    for dev in \
        /dev/sd[a-z][0-9] \
        /dev/vd[a-z][0-9] \
        /dev/mmcblk[0-9]p[0-9] \
        /dev/nvme[0-9]n[0-9]p[0-9]; do
        [ -b "$dev" ] || continue
        if mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi
    done

    # Final fallback: try whole-disk devices used by some removable media
    for dev in /dev/sd[a-z] /dev/vd[a-z]; do
        [ -b "$dev" ] || continue
        if mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null; then
            USB_MOUNT_OWNED=1
            return 0
        fi
    done
    return 1
}

unmount_usb() {
    if [ "${USB_MOUNT_OWNED:-0}" -eq 1 ]; then
        umount "$USB_MOUNT" 2>/dev/null || true
        USB_MOUNT_OWNED=0
    fi
}
