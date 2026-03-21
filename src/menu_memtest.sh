#!/bin/sh
# menu_memtest.sh - Memory Test screen

. /opt/pcinfo/common.sh

# Set next UEFI boot entry to memtest via grub.cfg on USB
set_next_boot_memtest() {
    if ! mount_usb; then
        return 1
    fi

    local grubenv="$USB_MOUNT/EFI/BOOT/grubenv"
    if [ ! -f "$grubenv" ]; then
        unmount_usb
        return 1
    fi

    # Write 1024-byte grubenv block
    dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\000' '#' > "$grubenv"
    printf '# GRUB Environment Block\nsaved_entry=memtest\n' | \
        dd of="$grubenv" conv=notrunc 2>/dev/null
    sync
    unmount_usb
    return 0
}

# Main
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
    printf "  Run Memtest86+ to test system RAM.\n\n"
    printf "  - System will reboot into Memtest86+.\n"
    printf "  - After test, press Esc to return to PCInfo.\n\n"
    printf "  Enter: Start   q: Cancel\n"
} > "$TTY"

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
        ''|' ')
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\nPreparing...\n" > "$TTY"

            if set_next_boot_memtest; then
                sleep 1
                reboot
                exit 0
            else
                printf '\033[2J\033[H' > "$TTY" 2>/dev/null
                {
                    printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
                    printf "${YELLOW}Auto-boot not available.${RESET}\n\n"
                    printf "Please reboot manually and select\n"
                    printf "\"Memtest86+\" from the boot menu.\n\n"
                    printf "${SEP}\nPress q to return\n"
                } > "$TTY"
                while true; do read_key; case "$key" in q|Q) break 2 ;; esac; done
            fi
            ;;
    esac
done
