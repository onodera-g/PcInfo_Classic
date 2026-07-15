#!/bin/sh
# menu_memtest.sh - Memory Test screen

. /opt/pcinfo/common.sh

MEMTEST_FAIL=""

item() {
    render_item_escaped "$1" "$2"
}

# Write a 1024-byte GRUB environment block to $1 with memtest_next=$2
_write_grubenv() {
    local file="$1" val="$2"
    printf '# GRUB Environment Block\nmemtest_next=%s\n' "$val" > "$file" || return 1
    local used
    used=$(wc -c < "$file")
    local pad=$((1024 - used))
    [ "$pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$pad" 2>/dev/null | tr '\0' '#' >> "$file"
    return 0
}

# Find the mount point of the USB FAT32 filesystem already mounted by Alpine init.
_decode_mount_path() {
    printf '%s\n' "$1" | sed 's/\\040/ /g; s/\\011/\t/g; s/\\134/\\/g'
}

_find_pcinfo_device() {
    local dev=""
    if [ -e /dev/disk/by-label/PCINFO ]; then
        dev=$(readlink -f /dev/disk/by-label/PCINFO 2>/dev/null)
    fi
    if [ -z "$dev" ] && command -v findfs >/dev/null 2>&1; then
        dev=$(findfs LABEL=PCINFO 2>/dev/null)
    fi
    if [ -z "$dev" ] && command -v blkid >/dev/null 2>&1; then
        dev=$(blkid -L PCINFO 2>/dev/null)
    fi
    [ -n "$dev" ] && printf '%s\n' "$dev"
}

_find_usb_mountpoint() {
    local dev mp fstype _rest
    local decoded_mp=""
    local pcinfo_dev=""
    local first_vfat_mp=""
    local first_pcinfo_mp=""

    pcinfo_dev=$(_find_pcinfo_device)

    # 1) Prefer LABEL=PCINFO mount that already contains memtest.efi
    while read -r dev mp fstype _rest; do
        [ "$fstype" = "vfat" ] || continue
        decoded_mp=$(_decode_mount_path "$mp")

        [ -n "$first_vfat_mp" ] || first_vfat_mp="$decoded_mp"
        if [ -n "$pcinfo_dev" ] && [ "$dev" = "$pcinfo_dev" ]; then
            [ -n "$first_pcinfo_mp" ] || first_pcinfo_mp="$decoded_mp"
            if [ -f "$decoded_mp/boot/memtest.efi" ]; then
                printf '%s\n' "$decoded_mp"
                return 0
            fi
        fi
        if [ "$dev" = "LABEL=PCINFO" ]; then
            [ -n "$first_pcinfo_mp" ] || first_pcinfo_mp="$decoded_mp"
            if [ -f "$decoded_mp/boot/memtest.efi" ]; then
                printf '%s\n' "$decoded_mp"
                return 0
            fi
        fi
    done < /proc/mounts

    # 2) Fallback: prefer external-media style mountpoints with memtest.efi
    while read -r dev mp fstype _rest; do
        [ "$fstype" = "vfat" ] || continue
        decoded_mp=$(_decode_mount_path "$mp")
        case "$decoded_mp" in
            /media/*|/mnt/*)
                if [ -f "$decoded_mp/boot/memtest.efi" ]; then
                    printf '%s\n' "$decoded_mp"
                    return 0
                fi
                ;;
        esac
    done < /proc/mounts

    # 3) Last fallback: any vfat mount with memtest.efi
    while read -r dev mp fstype _rest; do
        [ "$fstype" = "vfat" ] || continue
        decoded_mp=$(_decode_mount_path "$mp")
        if [ -f "$decoded_mp/boot/memtest.efi" ]; then
            printf '%s\n' "$decoded_mp"
            return 0
        fi
    done < /proc/mounts

    # 4) Keep an explanatory error path if vfat is mounted but memtest.efi is missing
    [ -n "$first_pcinfo_mp" ] && { printf '%s\n' "$first_pcinfo_mp"; return 0; }
    [ -n "$first_vfat_mp" ] && { printf '%s\n' "$first_vfat_mp"; return 0; }

    return 1
}

run_memtest() {
    local usb_mp
    local verify_ok=0
    local sync_ok=0
    local header_ok=0
    local size_ok=0
    local grubenv_size=""
    usb_mp=$(_find_usb_mountpoint)
    if [ -z "$usb_mp" ]; then
        MEMTEST_FAIL="USB FAT32 not mounted (no vfat in /proc/mounts)"
        return 1
    fi

    if ! [ -f "$usb_mp/boot/memtest.efi" ]; then
        MEMTEST_FAIL="memtest.efi not found ($usb_mp/boot/memtest.efi)"
        return 1
    fi

    if ! mount -o remount,rw "$usb_mp" 2>/dev/null; then
        MEMTEST_FAIL="Cannot remount USB read-write ($usb_mp)"
        return 1
    fi

    _write_grubenv "$usb_mp/grubenv" 1
    local write_ok=$?
    if [ "$write_ok" -eq 0 ]; then
        if grep -q '^memtest_next=1$' "$usb_mp/grubenv" 2>/dev/null; then
            verify_ok=1
        fi
        if grep -q '^# GRUB Environment Block$' "$usb_mp/grubenv" 2>/dev/null; then
            header_ok=1
        fi
        grubenv_size=$(wc -c < "$usb_mp/grubenv" 2>/dev/null)
        case "$grubenv_size" in
            1024) size_ok=1 ;;
        esac
    fi

    if sync; then
        sync_ok=1
    fi
    mount -o remount,ro "$usb_mp" 2>/dev/null || true

    if [ "$write_ok" -ne 0 ]; then
        MEMTEST_FAIL="Failed to write grubenv to $usb_mp"
        return 1
    fi
    if [ "$verify_ok" -ne 1 ]; then
        MEMTEST_FAIL="grubenv verification failed on $usb_mp"
        return 1
    fi
    if [ "$header_ok" -ne 1 ] || [ "$size_ok" -ne 1 ]; then
        MEMTEST_FAIL="grubenv integrity check failed on $usb_mp"
        return 1
    fi
    if [ "$sync_ok" -ne 1 ]; then
        MEMTEST_FAIL="Failed to sync grubenv changes on $usb_mp"
        return 1
    fi

    reboot
    # reboot is async — block here so the script never reaches the error display
    while true; do sleep 1; done
}

# Get total RAM in human-readable form
_get_total_ram() {
    local kb
    kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$kb" ] && { printf 'Unknown'; return; }
    local gb=$(( (kb + 512 * 1024) / (1024 * 1024) ))
    if [ "$gb" -ge 1 ]; then
        printf '%s GB' "$gb"
    else
        printf '%s MB' $(( (kb + 512) / 1024 ))
    fi
}

# Main
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
    item "Total RAM" "$(_get_total_ram)"
    item "Test tool" "Memtest86+ 8.00"
    printf "\n"
    printf "  Reboots into Memtest86+.\n"
    printf "  Returns to PCInfo after test completes.\n"
    printf "\n${SEP}\n"
    printf "  Enter: Start   q: Back\n"
} > "$TTY"

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
        ''|' ')
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            {
                printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
                printf "  Rebooting into Memtest86+...\n"
            } > "$TTY"

            run_memtest

            # Only reached if run_memtest failed
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            {
                printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
                printf "  ${YELLOW}Memtest86+ could not be started.${RESET}\n\n"
                item "Error" "$MEMTEST_FAIL"
                printf "\n${SEP}\n"
                printf "  Press any key to return\n"
            } > "$TTY"
            wait_any_key
            break
            ;;
    esac
done
