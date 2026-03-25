#!/bin/sh
# menu_gpu.sh - GPU Driver Test (offline, on-demand via USB .apk files)

. /opt/pcinfo/common.sh

section() {
    printf "\n${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

group_title() {
    printf " %s\n" "$1"
}

item() {
    local label="$1"
    local val="$2"
    printf "  %-22s: %b\n" "$label" "$val"
}

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

gpu_devices_by_vendor() {
    local want_vendor="$1"
    local dev=""
    local class=""
    local vendor=""

    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        [ "$vendor" = "$want_vendor" ] && printf '%s\n' "$dev"
    done
}

vendor_driver_bound() {
    local want_vendor="$1"
    local want_driver="$2"
    local dev=""
    local bound_driver=""

    for dev in $(gpu_devices_by_vendor "$want_vendor"); do
        if [ -L "$dev/driver" ]; then
            bound_driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)")
            [ "$bound_driver" = "$want_driver" ] && return 0
        fi
    done
    return 1
}

reprobe_vendor_devices() {
    local want_vendor="$1"
    local dev=""
    local slot=""

    [ -w /sys/bus/pci/drivers_probe ] || return 0
    for dev in $(gpu_devices_by_vendor "$want_vendor"); do
        [ -L "$dev/driver" ] && continue
        slot=$(basename "$dev")
        printf '%s\n' "$slot" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done
}

# Install GPU drivers from pre-downloaded .apk files on USB
install_firmware_apks() {
    local firmware_root="/lib/firmware"
    local firmware_apk=""
    local extract_dir=""

    [ "$#" -gt 0 ] || return 0

    printf "  Installing firmware payloads...\n"

    if [ -L "$firmware_root" ] || [ -f "$firmware_root" ]; then
        rm -f "$firmware_root" || {
            printf "  ${RED}Failed to prepare %s${RESET}\n" "$firmware_root"
            return 1
        }
    fi
    mkdir -p "$firmware_root" || {
        printf "  ${RED}Failed to create %s${RESET}\n" "$firmware_root"
        return 1
    }

    for firmware_apk in "$@"; do
        extract_dir=$(mktemp -d) || {
            printf "  ${RED}Failed to create temporary extraction directory${RESET}\n"
            return 1
        }

        if tar -xf "$firmware_apk" -C "$extract_dir" >/dev/null 2>&1 && [ -d "$extract_dir/lib/firmware" ]; then
            cp -a "$extract_dir/lib/firmware/." "$firmware_root"/ >/dev/null 2>&1 || {
                rm -rf "$extract_dir"
                printf "  ${RED}Failed to copy firmware from %s${RESET}\n" "$(basename "$firmware_apk")"
                return 1
            }
            printf "  Firmware OK: %s\n" "$(basename "$firmware_apk")"
        else
            rm -rf "$extract_dir"
            printf "  ${RED}Failed to extract firmware from %s${RESET}\n" "$(basename "$firmware_apk")"
            return 1
        fi

        rm -rf "$extract_dir"
    done

    return 0
}

install_gpu_drivers() {
    local vendor="$1"
    local driver_dir=""
    local vendor_name=""
    local repo_file=""
    local apk_count=0
    local install_log=""
    local regular_apks=""
    local firmware_apks=""
    local apk=""

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

    set -- "$driver_dir"/*.apk
    if [ ! -e "$1" ]; then
        printf "  ${YELLOW}No .apk files found in %s${RESET}\n" "$driver_dir"
        return 1
    fi
    apk_count=$#
    if [ "$apk_count" -eq 0 ]; then
        printf "  ${YELLOW}No .apk files found in %s${RESET}\n" "$driver_dir"
        return 1
    fi

    printf "  Installing %d package(s) from USB...\n" "$apk_count"
    for apk in "$@"; do
        case "$(basename "$apk")" in
            linux-firmware-*.apk)
                firmware_apks="$firmware_apks $apk"
                ;;
            *)
                regular_apks="$regular_apks $apk"
                ;;
        esac
    done

    repo_file=$(mktemp) || {
        printf "  ${RED}Failed to create temporary repositories file${RESET}\n"
        return 1
    }
    install_log=$(mktemp) || {
        rm -f "$repo_file"
        printf "  ${RED}Failed to create temporary log file${RESET}\n"
        return 1
    }

    if [ -n "$regular_apks" ]; then
        # shellcheck disable=SC2086
        if apk add --allow-untrusted --force-non-repository --no-network --repositories-file "$repo_file" $regular_apks \
            >"$install_log" 2>&1; then
            grep -E '(Installing|Executing|OK:|WARNING:)' "$install_log" | sed 's/^/  /'
        else
            grep -E '(Installing|Executing|ERROR:|error:|WARNING:)' "$install_log" | sed 's/^/  /'
            printf "  ${RED}Install failed${RESET}\n"
            rm -f "$install_log" "$repo_file"
            return 1
        fi
    fi

    if [ -n "$firmware_apks" ]; then
        # shellcheck disable=SC2086
        if ! install_firmware_apks $firmware_apks; then
            printf "  ${RED}Install failed${RESET}\n"
            rm -f "$install_log" "$repo_file"
            return 1
        fi
    fi

    printf "  ${GREEN}Install OK${RESET}\n"
    rm -f "$install_log" "$repo_file"
    return 0
}

# Load kernel module(s) for the detected vendor
load_gpu_module() {
    local vendor="$1"
    local modprobe_log=""
    case "$vendor" in
        0x10de)
            modprobe_log=$(mktemp) || modprobe_log=""
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            modprobe ttm 2>/dev/null
            modprobe fbcon 2>/dev/null
            if modprobe nouveau >"${modprobe_log:-/dev/null}" 2>&1; then
                reprobe_vendor_devices "$vendor"
            fi
            if vendor_driver_bound "$vendor" nouveau; then
                printf "  ${GREEN}nouveau: loaded${RESET}\n"
            else
                printf "  ${YELLOW}nouveau: skipped${RESET}\n"
                [ -n "$modprobe_log" ] && grep -m1 -E '.' "$modprobe_log" | sed 's/^/    /'
            fi
            [ -n "$modprobe_log" ] && rm -f "$modprobe_log"
            ;;
        0x1002)
            modprobe_log=$(mktemp) || modprobe_log=""
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            modprobe ttm 2>/dev/null
            modprobe fbcon 2>/dev/null
            if modprobe amdgpu >"${modprobe_log:-/dev/null}" 2>&1; then
                reprobe_vendor_devices "$vendor"
            fi
            if vendor_driver_bound "$vendor" amdgpu; then
                printf "  ${GREEN}amdgpu: loaded${RESET}\n"
            else
                : > "${modprobe_log:-/dev/null}"
                if modprobe radeon >>"${modprobe_log:-/dev/null}" 2>&1; then
                    reprobe_vendor_devices "$vendor"
                fi
            fi
            if vendor_driver_bound "$vendor" radeon; then
                printf "  ${GREEN}radeon: loaded${RESET}\n"
            elif vendor_driver_bound "$vendor" amdgpu; then
                :
            else
                printf "  ${YELLOW}amd drm: skipped${RESET}\n"
                [ -n "$modprobe_log" ] && grep -m1 -E '.' "$modprobe_log" | sed 's/^/    /'
            fi
            [ -n "$modprobe_log" ] && rm -f "$modprobe_log"
            ;;
        0x8086)
            modprobe_log=$(mktemp) || modprobe_log=""
            modprobe drm 2>/dev/null
            modprobe drm_kms_helper 2>/dev/null
            modprobe fbcon 2>/dev/null
            if modprobe i915 >"${modprobe_log:-/dev/null}" 2>&1; then
                reprobe_vendor_devices "$vendor"
            fi
            if vendor_driver_bound "$vendor" i915; then
                printf "  ${GREEN}i915: loaded${RESET}\n"
            else
                printf "  ${YELLOW}i915: skipped${RESET}\n"
                [ -n "$modprobe_log" ] && grep -m1 -E '.' "$modprobe_log" | sed 's/^/    /'
            fi
            [ -n "$modprobe_log" ] && rm -f "$modprobe_log"
            ;;
    esac
}

# Display GPU detection results
show_gpu_info() {
    section "Result"

    if ls /dev/dri/card* >/dev/null 2>&1; then
        for card in /dev/dri/card*; do
            local drm_drv=""
            local card_num
            card_num=$(basename "$card")
            [ -L "/sys/class/drm/$card_num/device/driver" ] && \
                drm_drv=$(basename "$(readlink /sys/class/drm/$card_num/device/driver 2>/dev/null)")
            printf "  %s -> ${GREEN}%s${RESET}\n" "$card" "${drm_drv:-present}"
        done
        printf "  ${GREEN}[OK] Graphics output available${RESET}\n"
    else
        printf "  ${RED}No DRM device found${RESET}\n"
        printf "  ${RED}[NG] Graphics output unavailable${RESET}\n"
    fi

    printf "\n"

    local gpu_count=0
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac

        gpu_count=$((gpu_count + 1))
        local vendor device_id subsystem_vendor subsystem_device pci_slot vendor_name driver gpu_model gpu_vram gpu_slot_label driver_text

        vendor=$(cat "$dev/vendor" 2>/dev/null)
        device_id=$(cat "$dev/device" 2>/dev/null)
        subsystem_vendor=$(cat "$dev/subsystem_vendor" 2>/dev/null)
        subsystem_device=$(cat "$dev/subsystem_device" 2>/dev/null)
        pci_slot=$(basename "$dev")
        vendor_name=$(get_pci_vendor_name "$vendor")
        gpu_model=$(get_pci_gpu_model "$pci_slot" "$vendor" "$device_id" "$vendor_name" "$subsystem_vendor" "$subsystem_device")

        driver=""
        [ -L "$dev/driver" ] && driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)")
        gpu_vram=$(get_pci_gpu_vram "$dev" "$pci_slot" "$vendor" "$device_id" "$driver" "$subsystem_vendor" "$subsystem_device")
        gpu_slot_label=$(get_pci_slot_label "$dev" "$pci_slot")

        if [ -n "$driver" ]; then
            driver_text="${GREEN}${driver}${RESET}"
        else
            driver_text="${RED}not loaded${RESET}"
        fi

        group_title "GPU $gpu_count"
        item "Slot" "$gpu_slot_label"
        item "Model" "$gpu_model"
        item "VRAM" "$gpu_vram"
        item "Driver" "$driver_text"
        printf "\n"
    done

    [ "$gpu_count" -eq 0 ] && printf "  ${RED}No GPU detected${RESET}\n"
}

# ----- Main -----
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[GPU Test]${RESET}\n\n"
    printf "  Detecting GPU...\n"
} > "$TTY"

vendors=$(detect_gpu_vendors)

if [ -z "$vendors" ]; then
    printf "\n  ${RED}No GPU detected in this system.${RESET}\n\n${SEP}\nPress any key to return\n" > "$TTY"
    wait_any_key
    exit 0
fi

# Mount USB
printf "  Mounting USB (LABEL=PCINFO)...\n" > "$TTY"
if ! mount_usb; then
    printf "  ${RED}USB not found. Cannot load drivers.${RESET}\n\n${SEP}\nPress any key to return\n" > "$TTY"
    wait_any_key
    exit 0
fi

# Install drivers for each detected GPU vendor
{
    for v in $vendors; do
        install_gpu_drivers "$v"
    done

    printf "  Waiting for device initialization..."
    sleep 2
    printf " done\n"

    # Load modules
    printf "  Loading kernel modules...\n"
    for v in $vendors; do
        load_gpu_module "$v"
    done

    sleep 1
    printf "\n"
    show_gpu_info
    printf "\n${SEP}\nPress any key to return\n"
} > "$TTY"

unmount_usb

wait_any_key
