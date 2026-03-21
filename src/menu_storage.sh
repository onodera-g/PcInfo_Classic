#!/bin/sh
# menu_storage.sh - Storage Health Check (smartctl + nvme)

. /opt/pcinfo/common.sh

SEP='----------------------------------------'

# List all storage devices and their type
list_devices() {
    local devs=""
    local i=1
    for d in /dev/nvme?; do
        [ -b "$d" ] || continue
        devs="$devs $i $d"
        i=$((i + 1))
    done
    for d in /dev/sd?; do
        [ -b "$d" ] || continue
        devs="$devs $i $d"
        i=$((i + 1))
    done
    echo "$devs"
}

# Show SMART info for a device
show_smart_info() {
    local dev="$1"

    case "$dev" in
        /dev/nvme*)
            printf "${BOLD}${CYAN}[NVMe SMART: %s]${RESET}\n\n" "$dev"
            if command -v nvme > /dev/null 2>&1; then
                nvme smart-log "$dev" 2>/dev/null || \
                    printf "${RED}nvme smart-log failed${RESET}\n"
                printf "\n${SEP}\n"
                printf "${BOLD}[NVMe Info]${RESET}\n"
                nvme id-ctrl "$dev" 2>/dev/null | grep -E '^(mn|sn|fr|tnvmcap|unvmcap)' | \
                    awk '{printf "  %-24s: %s\n", $1, substr($0, index($0,$2))}'
            else
                printf "${YELLOW}nvme-cli not installed${RESET}\n"
            fi
            ;;
        *)
            printf "${BOLD}${CYAN}[SMART: %s]${RESET}\n\n" "$dev"
            if command -v smartctl > /dev/null 2>&1; then
                printf "${BOLD}[Health]${RESET}\n"
                smartctl -H "$dev" 2>/dev/null | grep -E '(SMART overall|test result)'
                printf "\n${BOLD}[Attributes]${RESET}\n"
                smartctl -A "$dev" 2>/dev/null | \
                    awk 'NR>=8 && /^[ ]*[0-9]/ {printf "  %-40s %s\n", $2, $10}'
                printf "\n${BOLD}[Device Info]${RESET}\n"
                smartctl -i "$dev" 2>/dev/null | \
                    grep -E '(Device Model|Serial|Firmware|User Capacity|Rotation)' | \
                    sed 's/^/  /'
            else
                printf "${YELLOW}smartmontools not installed${RESET}\n"
            fi
            ;;
    esac
    printf "\n${SEP}\nPress q to return\n"
}

# Build dialog menu entries from available devices
build_menu() {
    local entries=""
    local i=1
    for d in /dev/nvme?; do
        [ -b "$d" ] || continue
        local model=""
        if command -v nvme > /dev/null 2>&1; then
            model=$(nvme id-ctrl "$d" 2>/dev/null | awk '/^mn /{gsub(/[[:space:]]+/," ",$0); print substr($0,5,20)}')
        fi
        [ -z "$model" ] && model="NVMe Drive"
        entries="$entries $i \"$d  $model\""
        i=$((i + 1))
    done
    for d in /dev/sd?; do
        [ -b "$d" ] || continue
        local model=""
        if command -v smartctl > /dev/null 2>&1; then
            model=$(smartctl -i "$d" 2>/dev/null | awk -F': ' '/Device Model/{gsub(/[[:space:]]+/," ",$2); print substr($2,1,20)}')
        fi
        [ -z "$model" ] && model="SATA/SAS Drive"
        entries="$entries $i \"$d  $model\""
        i=$((i + 1))
    done
    echo "$entries"
}

# Main
while true; do
    # Check if any storage devices exist
    found=0
    for d in /dev/nvme? /dev/sd?; do [ -b "$d" ] && found=1 && break; done

    if [ "$found" -eq 0 ]; then
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        printf "${BOLD}${CYAN}[Storage Health]${RESET}\n\nNo storage devices found.\n\n${SEP}\nPress q to return\n" > "$TTY"
        while true; do read_key; case "$key" in q|Q) return 2>/dev/null; exit 0 ;; esac; done
    fi

    # Build and show dialog menu
    CHOICE=$(eval dialog --clear \
        --backtitle '"PCInfo Classic"' \
        --title '"Storage Health"' \
        --menu '"Select a device to check:"' \
        15 60 8 \
        $(build_menu) \
        2>&1 > /dev/tty)

    [ $? -ne 0 ] && break

    # Map choice number to device path
    i=1
    selected=""
    for d in /dev/nvme? /dev/sd?; do
        [ -b "$d" ] || continue
        if [ "$i" -eq "$CHOICE" ]; then
            selected="$d"
            break
        fi
        i=$((i + 1))
    done

    [ -z "$selected" ] && break

    clear > "$TTY"
    show_smart_info "$selected" | show_paged
done
