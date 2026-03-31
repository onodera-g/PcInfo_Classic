#!/bin/sh
# menu_memtest.sh - Memory Test screen

. /opt/pcinfo/common.sh

MEMTEST_FAIL=""

run_memtest() {
    local memtest_bin="$USB_MOUNT/boot/memtest.bin"

    if ! command -v kexec >/dev/null 2>&1; then
        MEMTEST_FAIL="kexec not found in PATH"
        return 1
    fi

    if ! mountpoint -q "$USB_MOUNT" 2>/dev/null; then
        MEMTEST_FAIL="USB not mounted at $USB_MOUNT"
        return 1
    fi

    if ! [ -f "$memtest_bin" ]; then
        MEMTEST_FAIL="memtest.bin not found: $memtest_bin"
        return 1
    fi

    local err
    # Try loading with various types. bzImage is the primary protocol for Memtest86+.
    for kexec_type in "" "--type=bzImage"; do
        # shellcheck disable=SC2086
        err=$(kexec -l $kexec_type "$memtest_bin" 2>&1)
        if [ $? -eq 0 ]; then
            kexec -e 2>/dev/null
            MEMTEST_FAIL="kexec -e returned unexpectedly"
            return 1
        fi
    done

    # Include memory map for diagnosis
    local iomem_low
    iomem_low=$(awk '/^0+0+-0*[89a][0-9a-f]/ {print $0}' /proc/iomem 2>/dev/null | head -5)
    MEMTEST_FAIL="kexec -l failed: $err"
    [ -n "$iomem_low" ] && MEMTEST_FAIL="$MEMTEST_FAIL
iomem(low): $iomem_low"

    return 1
}

# Main
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
    printf "  Run Memtest86+ to test system RAM.\n\n"
    printf "  - Memtest86+ starts immediately (no reboot required).\n"
    printf "  - After test completes, system reboots back to PCInfo.\n\n"
    printf "  Enter: Start   q: Cancel\n"
} > "$TTY"

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
        ''|' ')
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\nStarting Memtest86+...\n" > "$TTY"

            run_memtest

            # Only reached if kexec failed
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            {
                printf "\n${BOLD}${CYAN}[Memory Test]${RESET}\n\n"
                printf "${YELLOW}Memtest86+ could not be started.${RESET}\n\n"
                printf "Error: %s\n\n" "$MEMTEST_FAIL"
                printf "Please reboot manually and select\n"
                printf "\"Memtest86+\" from the boot menu.\n\n"
                printf "${SEP}\nPress any key to return\n"
            } > "$TTY"
            wait_any_key
            break
            ;;
    esac
done
