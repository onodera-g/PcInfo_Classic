#!/bin/sh
# common.sh - Shared variables and functions (sourced by all menu scripts)

TTY=/dev/tty1
LINES_PER_PAGE=40

# ANSI colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

SEP='----------------------------------------'

# Read a single key from TTY (raw mode)
read_key() {
    if ! [ -c "$TTY" ] || ! stty -g < "$TTY" > /dev/null 2>&1; then
        key=""
        return 1
    fi
    _old=$(stty -g < "$TTY" 2>/dev/null)
    trap 'stty "$_old" < "$TTY" 2>/dev/null' INT TERM
    stty -icanon -echo min 1 time 0 < "$TTY" 2>/dev/null
    key=$(dd bs=1 count=1 < "$TTY" 2>/dev/null)
    stty "$_old" < "$TTY" 2>/dev/null
    trap - INT TERM
}

# Display stdin content page by page (LINES_PER_PAGE lines per page)
# Enter: next page / q: return to top on last page
show_paged() {
    _content=$(cat)
    _total=$(printf '%s\n' "$_content" | wc -l)
    _start=1
    while true; do
        _end=$((_start + LINES_PER_PAGE - 1))
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        _chunk=$(printf '%s\n' "$_content" | sed -n "${_start},${_end}p")
        if [ "$_end" -lt "$_total" ]; then
            printf '%s\n' "$_chunk" > "$TTY"
            printf '\n%s\nPress Enter for more...\n' "$SEP" > "$TTY"
            read -r _dummy < "$TTY"
            _start=$((_end + 1))
        else
            printf '%s\n' "$_chunk" > "$TTY"
            printf '\n%s\nPress q to return to menu\n' "$SEP" > "$TTY"
            while true; do
                read_key
                case "$key" in q|Q|'') return ;; esac
            done
        fi
    done
}

# Mount USB by label (PCINFO) to /mnt/usb
USB_MOUNT="/mnt/usb"
mount_usb() {
    if mountpoint -q "$USB_MOUNT" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$USB_MOUNT"
    mount -t vfat -L PCINFO "$USB_MOUNT" 2>/dev/null && return 0
    # Fallback: try common USB device paths
    for dev in /dev/sda /dev/sdb /dev/sdc /dev/sdd; do
        [ -b "$dev" ] || continue
        mount -t vfat "$dev" "$USB_MOUNT" 2>/dev/null && return 0
    done
    return 1
}

unmount_usb() {
    umount "$USB_MOUNT" 2>/dev/null || true
}
