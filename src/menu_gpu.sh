#!/bin/sh
# menu_gpu.sh - GPU Driver Test (offline, on-demand via USB .apk files)

. /opt/pcinfo/common.sh

# Detect GPU PCI vendor IDs present in the system
detect_gpu_vendors() {
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac
        cat "$dev/vendor" 2>/dev/null
    done | sort -u
}

# Install GPU drivers from pre-downloaded .apk files on USB
install_gpu_drivers() {
    local vendor="$1"
    local driver_dir=""
    local vendor_name=""

    case "$vendor" in
        0x10de) driver_dir="$USB_MOUNT/drivers/nvidia"; vendor_name="NVIDIA (nouveau)" ;;
        0x1002) driver_dir="$USB_MOUNT/drivers/amd";   vendor_name="AMD (amdgpu/radeon)" ;;
        0x8086) driver_dir="$USB_MOUNT/drivers/intel"; vendor_name="Intel (i915)" ;;
        *)
            printf "  Unknown vendor: %s\n" "$vendor"
            return 1
            ;;
    esac

    printf "  Vendor: ${BOLD}%s${RESET}\n" "$vendor_name"
    printf "  Driver dir: %s\n\n" "$driver_dir"

    if [ ! -d "$driver_dir" ]; then
        printf "  ${YELLOW}Directory not found: %s${RESET}\n" "$driver_dir"
        printf "  Please prepare .apk files using: apk fetch -R -o %s <packages>\n" "$driver_dir"
        return 1
    fi

    local apk_count
    apk_count=$(ls "$driver_dir"/*.apk 2>/dev/null | wc -l)
    if [ "$apk_count" -eq 0 ]; then
        printf "  ${YELLOW}No .apk files found in %s${RESET}\n" "$driver_dir"
        return 1
    fi

    printf "  Installing %d package(s) from USB...\n" "$apk_count"
    # Install all .apk files from the vendor's driver directory
    if apk add --allow-untrusted "$driver_dir"/*.apk 2>&1 | \
        grep -E '(Installing|Executing|ERROR|error:)' | sed 's/^/  /'; then
        printf "  ${GREEN}Install OK${RESET}\n"
        return 0
    else
        printf "  ${RED}Install failed${RESET}\n"
        return 1
    fi
}

# Load kernel module(s) for the detected vendor
load_gpu_module() {
    local vendor="$1"

    printf "\n  Loading kernel modules...\n"
    case "$vendor" in
        0x10de)
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            modprobe ttm 2>/dev/null
            if modprobe nouveau 2>/dev/null; then
                printf "  ${GREEN}nouveau: loaded${RESET}\n"
            else
                printf "  ${YELLOW}nouveau: skipped (may already be loaded)${RESET}\n"
            fi
            ;;
        0x1002)
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            modprobe ttm 2>/dev/null
            if modprobe amdgpu 2>/dev/null; then
                printf "  ${GREEN}amdgpu: loaded${RESET}\n"
            elif modprobe radeon 2>/dev/null; then
                printf "  ${GREEN}radeon: loaded${RESET}\n"
            else
                printf "  ${YELLOW}amd drm: skipped${RESET}\n"
            fi
            ;;
        0x8086)
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            if modprobe i915 2>/dev/null; then
                printf "  ${GREEN}i915: loaded${RESET}\n"
            else
                printf "  ${YELLOW}i915: skipped${RESET}\n"
            fi
            ;;
    esac
}

# Display GPU detection results
show_gpu_info() {
    printf "\n${BOLD}${CYAN}--- Detected GPUs ---${RESET}\n\n"

    local gpu_count=0
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac

        gpu_count=$((gpu_count + 1))
        local vendor device_id pci_slot vendor_name driver gpu_name

        vendor=$(cat "$dev/vendor" 2>/dev/null)
        device_id=$(cat "$dev/device" 2>/dev/null)
        pci_slot=$(basename "$dev")

        case "$vendor" in
            0x10de) vendor_name="NVIDIA" ;;
            0x1002) vendor_name="AMD" ;;
            0x8086) vendor_name="Intel" ;;
            *)      vendor_name="Unknown ($vendor)" ;;
        esac

        gpu_name=""
        if command -v lspci > /dev/null 2>&1; then
            pci_short=$(echo "$pci_slot" | sed 's/^0000://')
            gpu_name=$(lspci 2>/dev/null | grep "^$pci_short " | \
                sed 's/.*[Cc]ontroller[^:]*: //' | cut -c1-50)
        fi
        [ -z "$gpu_name" ] && gpu_name="${vendor_name} GPU (${device_id})"

        driver=""
        [ -L "$dev/driver" ] && driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)")

        printf "  ${BOLD}GPU %d: %s${RESET}\n" "$gpu_count" "$gpu_name"
        printf "    Slot   : %s\n" "$pci_slot"
        printf "    Vendor : %s   Device: %s\n" "$vendor" "$device_id"
        if [ -n "$driver" ]; then
            printf "    Driver : ${GREEN}%s (bound)${RESET}\n" "$driver"
        else
            printf "    Driver : ${RED}not loaded${RESET}\n"
        fi
        printf "\n"
    done

    [ "$gpu_count" -eq 0 ] && printf "  ${RED}No GPU detected${RESET}\n\n"

    printf "${BOLD}--- DRM Devices ---${RESET}\n\n"
    if ls /dev/dri/card* >/dev/null 2>&1; then
        for card in /dev/dri/card*; do
            local drm_drv=""
            local card_num
            card_num=$(basename "$card")
            [ -L "/sys/class/drm/$card_num/device/driver" ] && \
                drm_drv=$(basename "$(readlink /sys/class/drm/$card_num/device/driver 2>/dev/null)")
            printf "  %s -> ${GREEN}%s${RESET}\n" "$card" "${drm_drv:-present}"
        done
        printf "\n  ${GREEN}[OK] Graphics output available${RESET}\n"
    else
        printf "  ${RED}No DRM device found${RESET}\n"
        printf "  ${RED}[NG] Graphics output unavailable${RESET}\n"
    fi
}

# ----- Main -----
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[GPU Test]${RESET}\n\n"
    printf "  Detecting GPU...\n"
} > "$TTY"

vendors=$(detect_gpu_vendors)

if [ -z "$vendors" ]; then
    printf "\n  ${RED}No GPU detected in this system.${RESET}\n\n${SEP}\nPress q to return\n" > "$TTY"
    while true; do read_key; case "$key" in q|Q) exit 0 ;; esac; done
fi

# Mount USB
printf "  Mounting USB (LABEL=PCINFO)...\n" > "$TTY"
if ! mount_usb; then
    printf "  ${RED}USB not found. Cannot load drivers.${RESET}\n\n${SEP}\nPress q to return\n" > "$TTY"
    while true; do read_key; case "$key" in q|Q) exit 0 ;; esac; done
fi

# Install drivers for each detected GPU vendor
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[GPU Test - Installing Drivers]${RESET}\n\n"
    for v in $vendors; do
        install_gpu_drivers "$v"
        printf "\n"
    done

    printf "  Waiting for device initialization..."
    sleep 2
    printf " done\n"

    # Load modules
    for v in $vendors; do
        load_gpu_module "$v"
    done

    sleep 1
    printf "\n${SEP}\n"
    show_gpu_info
    printf "\n${SEP}\nPress q to return\n"
} > "$TTY"

unmount_usb

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
    esac
done
