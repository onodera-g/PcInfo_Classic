#!/bin/sh
# menu_gpu.sh - GPU Driver Test
#
# All GPU kernel modules (radeon, amdgpu, nouveau, i915) and their firmware
# are shipped inside Alpine's modloop-lts and pre-loaded at boot via the
# `modules=` kernel parameter and the radeon-specific quirks in cmdline
# (radeon.dpm=0, radeon.audio=0 etc.) defined in build_alpine.sh. This menu
# therefore only inspects the result.
#
# When the simple-framebuffer / efi-framebuffer platform driver still owns
# the aperture (and the PCI GPU is therefore not bound to its real driver
# yet), `recover_gpu_bindings` releases it and triggers a PCI re-probe so
# the appropriate DRM driver can take over.

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
    render_item_escaped "$label" "$val"
}

is_gpu_class() {
    case "$1" in
        0x030000|0x030001|0x030002|0x030200|0x038000) return 0 ;;
    esac
    return 1
}

detect_gpu_devices() {
    local dev=""
    local class=""

    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        is_gpu_class "$class" && printf '%s\n' "$dev"
    done
}

expected_module_for_vendor() {
    case "$1" in
        0x1002) printf '%s\n' 'amdgpu/radeon' ;;
        0x10de) printf '%s\n' 'nouveau' ;;
        0x8086) printf '%s\n' 'i915' ;;
        *)      printf '%s\n' 'unknown' ;;
    esac
}

bound_driver_for() {
    local dev_path="$1"
    [ -L "$dev_path/driver" ] || return 1
    basename "$(readlink "$dev_path/driver" 2>/dev/null)"
}

module_loaded() {
    grep -q "^$1[[:space:]]" /proc/modules 2>/dev/null
}

# Candidate kernel modules for a given PCI vendor.
candidate_modules_for_vendor() {
    case "$1" in
        0x1002) printf 'amdgpu radeon\n' ;;
        0x10de) printf 'nouveau\n' ;;
        0x8086) printf 'i915\n' ;;
    esac
}

# Resolve the right module for the device using its modalias when modprobe
# is available; fall back to the vendor-wide candidate list.
target_modules_for_device() {
    local dev_path="$1"
    local vendor=""
    local modalias=""
    local out=""

    vendor=$(cat "$dev_path/vendor" 2>/dev/null)
    if command -v modprobe >/dev/null 2>&1 && [ -r "$dev_path/modalias" ]; then
        modalias=$(cat "$dev_path/modalias" 2>/dev/null)
        if [ -n "$modalias" ]; then
            out=$(modprobe -R "$modalias" 2>/dev/null \
                | grep -E '^(amdgpu|radeon|nouveau|i915)$' \
                | tr '\n' ' ')
            if [ -n "$out" ]; then
                printf '%s\n' "${out% }"
                return 0
            fi
        fi
    fi
    candidate_modules_for_vendor "$vendor"
}

# Unbind simpledrm/efi-framebuffer so the real GPU driver can claim the
# aperture on rebind.
release_simple_framebuffer() {
    local entry=""
    local sysfs_driver=""
    local id=""

    for entry in /sys/bus/platform/drivers/simple-framebuffer \
                 /sys/bus/platform/drivers/efi-framebuffer; do
        [ -d "$entry" ] || continue
        for id in "$entry"/*; do
            [ -L "$id" ] || continue
            case "$(basename "$id")" in bind|unbind|uevent|module) continue ;; esac
            printf '%s\n' "$(basename "$id")" > "$entry/unbind" 2>/dev/null || true
        done
    done

    # /sys/class/drm/card0 may also be backed by simpledrm; that is removed
    # automatically once the platform driver above is unbound.
    sysfs_driver=$(readlink /sys/class/drm/card0/device/driver 2>/dev/null | xargs basename 2>/dev/null)
    [ -n "$sysfs_driver" ] && printf '  simpledrm release attempted (was: %s)\n' "$sysfs_driver"
}

# Try to make the right kernel module bind to dev_path.
attempt_module_bind() {
    local dev_path="$1"
    local slot=""
    local mod=""
    local mods=""
    local bound=""
    local modprobe_err=""

    slot=$(basename "$dev_path")
    mods=$(target_modules_for_device "$dev_path")
    [ -n "$mods" ] || return 1
    modprobe_err=$(mktemp /tmp/menu_gpu.modprobe.XXXXXX 2>/dev/null)
    [ -n "$modprobe_err" ] || modprobe_err="/tmp/menu_gpu.modprobe.err.$$"

    for mod in $mods; do
        if module_loaded "$mod"; then
            printf '  %s: already loaded\n' "$mod"
        else
            printf '  modprobe %s ... ' "$mod"
            if modprobe "$mod" 2>"$modprobe_err"; then
                printf '%bok%b\n' "$GREEN" "$RESET"
            else
                printf '%bfail%b\n' "$RED" "$RESET"
                sed 's/^/    /' "$modprobe_err" 2>/dev/null
                continue
            fi
        fi

        bound=$(bound_driver_for "$dev_path" 2>/dev/null || true)
        if [ "$bound" = "$mod" ]; then
            printf '  %s: bound to %s\n' "$slot" "$mod"
            rm -f "$modprobe_err" 2>/dev/null || true
            return 0
        fi

        # Free the simple/efi framebuffer that might still own the aperture,
        # then ask the PCI core to (re-)probe this device.
        release_simple_framebuffer
        if [ -w /sys/bus/pci/drivers_probe ]; then
            printf '%s\n' "$slot" > /sys/bus/pci/drivers_probe 2>/dev/null || true
        fi
        bound=$(bound_driver_for "$dev_path" 2>/dev/null || true)
        if [ "$bound" = "$mod" ]; then
            printf '  %s: bound to %s after rebind\n' "$slot" "$mod"
            rm -f "$modprobe_err" 2>/dev/null || true
            return 0
        fi
        printf '  %s: %s loaded but did not bind\n' "$slot" "$mod"
    done
    rm -f "$modprobe_err" 2>/dev/null || true
    return 1
}

show_cmdline_and_modules() {
    section "Boot state"
    printf "  loaded GPU modules:"
    local loaded=""
    for m in amdgpu radeon nouveau i915 drm drm_kms_helper ttm simpledrm; do
        module_loaded "$m" && loaded="$loaded $m"
    done
    if [ -n "$loaded" ]; then
        printf '%s\n' "$loaded"
    else
        printf ' %bnone%b\n' "$RED" "$RESET"
    fi
}

show_dmesg_for_gpu() {
    local matches=""
    matches=$(dmesg 2>/dev/null \
        | grep -E '(radeon|amdgpu|nouveau|nvidia|i915|xe|drm|drm_kms_helper|kms|fbcon|simpledrm|simple-framebuffer|efifb|vesafb|vgaarb|framebuffer|gpu|vga|firmware)' \
        | tail -n 20)
    [ -n "$matches" ] || return 0
    section "dmesg (GPU related, tail 20)"
    printf '%s\n' "$matches" | sed 's/^/  /'
}

# Try to load missing modules and rebind unbound GPUs.
recover_gpu_bindings() {
    local dev driver vendor recovery_mode
    local gpu_detected=0
    local attempted_count=0
    local failed_count=0
    recovery_mode="${PCINFO_GPU_RECOVERY_MODE:-safe}"
    for dev in $(detect_gpu_devices); do
        gpu_detected=1
        driver=$(bound_driver_for "$dev" 2>/dev/null || true)
        if [ -n "$driver" ]; then
            case "$recovery_mode" in
                enforce)
                    vendor=$(cat "$dev/vendor" 2>/dev/null)
                    case "$vendor:$driver" in
                        0x1002:amdgpu|0x1002:radeon|0x10de:nouveau|0x8086:i915)
                            continue
                            ;;
                    esac
                    ;;
                *)
                    continue
                    ;;
            esac
        fi
        if [ "$attempted_count" -eq 0 ]; then
            section "Recovery attempt"
            printf "  mode: %s\n" "$recovery_mode"
        fi
        attempted_count=$((attempted_count + 1))
        printf "  Trying %s ...\n" "$(basename "$dev")"
        if ! attempt_module_bind "$dev"; then
            failed_count=$((failed_count + 1))
        fi
    done
    RECOVERY_ATTEMPTED_COUNT="$attempted_count"
    if [ "$gpu_detected" -eq 0 ] || [ "$attempted_count" -eq 0 ]; then
        return 0
    elif [ "$failed_count" -eq 0 ]; then
        printf "  ${GREEN}Recovery completed for %s GPU(s)${RESET}\n" "$attempted_count"
    else
        printf "  ${YELLOW}Recovery incomplete: %s/%s failed${RESET}\n" "$failed_count" "$attempted_count"
    fi
}

show_dri_devices() {
    section "DRM devices"
    SHOW_DRI_WARN_COUNT=0
    if ! ls /dev/dri/card* >/dev/null 2>&1; then
        if [ "${SHOW_GPUS_LAST_COUNT:-0}" -eq 0 ]; then
            printf "  ${YELLOW}[WARN] No GPU detected${RESET}\n"
            return 0
        fi
        printf "  ${RED}No /dev/dri/card* device found${RESET}\n"
        printf "  ${RED}[NG] No GPU driver bound at boot${RESET}\n"
        SHOW_DRI_WARN_COUNT=1
        return 1
    fi
    local card card_num drm_drv drv_color status_text
    local card_dev pci_slot vendor_id device_id pci_map_text
    local warn_count=0
    for card in /dev/dri/card*; do
        card_num=$(basename "$card")
        drm_drv=""
        pci_map_text=""
        card_dev=$(readlink -f "/sys/class/drm/$card_num/device" 2>/dev/null)
        [ -L "/sys/class/drm/$card_num/device/driver" ] && \
            drm_drv=$(basename "$(readlink "/sys/class/drm/$card_num/device/driver" 2>/dev/null)")
        if [ -n "$card_dev" ] && [ -r "$card_dev/vendor" ] && [ -r "$card_dev/device" ]; then
            pci_slot=$(basename "$card_dev")
            vendor_id=$(cat "$card_dev/vendor" 2>/dev/null)
            device_id=$(cat "$card_dev/device" 2>/dev/null)
            case "$pci_slot" in
                0000:*)
                    pci_map_text=" PCI ${pci_slot#0000:} ($(strip_pci_hex_prefix "$vendor_id"):$(strip_pci_hex_prefix "$device_id"))"
                    ;;
            esac
        fi
        case "$drm_drv" in
            amdgpu|radeon|nouveau|i915)
                drv_color="$GREEN"
                status_text="${GREEN}[OK] supported${RESET}"
                ;;
            simpledrm|simple-framebuffer|efifb)
                drv_color="$YELLOW"
                status_text="${YELLOW}[WARN] basic framebuffer${RESET}"
                warn_count=$((warn_count + 1))
                ;;
            '')
                drv_color="$YELLOW"
                status_text="${YELLOW}[WARN] unbound${RESET}"
                warn_count=$((warn_count + 1))
                ;;
            *)
                drv_color="$YELLOW"
                status_text="${YELLOW}[WARN] unsupported or unknown${RESET}"
                warn_count=$((warn_count + 1))
                ;;
        esac
        printf "  %s -> %b%s%b%s  %s\n" "$card" "$drv_color" "${drm_drv:-unbound}" "$RESET" "$pci_map_text" "$status_text"
    done
    SHOW_DRI_WARN_COUNT="$warn_count"
    return 0
}

show_framebuffer() {
    section "Framebuffer"
    if [ -r /proc/fb ] && [ -s /proc/fb ]; then
        sed 's/^/  /' /proc/fb
    else
        printf "  ${YELLOW}No framebuffer registered${RESET}\n"
    fi
}

get_gpu_max_sclk() {
    local dev="$1"
    local line=""
    [ -r "$dev/pp_dpm_sclk" ] || return 0
    line=$(awk '$0 ~ /[0-9]+[Mm][Hh][Zz]/ { last=$0 } END { print last }' "$dev/pp_dpm_sclk" 2>/dev/null)
    [ -n "$line" ] || return 0
    printf '%s\n' "$line" | sed -n 's/.*[: ]\([0-9]\{1,\}[Mm][Hh][Zz]\).*/\1/p'
}

get_gpu_max_mclk() {
    local dev="$1"
    local line=""
    [ -r "$dev/pp_dpm_mclk" ] || return 0
    line=$(awk '$0 ~ /[0-9]+[Mm][Hh][Zz]/ { last=$0 } END { print last }' "$dev/pp_dpm_mclk" 2>/dev/null)
    [ -n "$line" ] || return 0
    printf '%s\n' "$line" | sed -n 's/.*[: ]\([0-9]\{1,\}[Mm][Hh][Zz]\).*/\1/p'
}

get_gpu_cu_count() {
    local vendor="$1"
    local pci_slot="$2"
    [ "$vendor" = "0x1002" ] || return 0
    get_amd_active_cu_count "$pci_slot" 2>/dev/null
}

get_gpu_sp_estimate_from_cu() {
    local cu_count="$1"
    case "$cu_count" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # AMD (GCN/RDNA) は 1CU = 64 SP のため概算値として表示する。
    printf '%s\n' $((cu_count * 64))
}

show_gpus() {
    local mode="${1:-full}"
    local suppress_no_gpu="${2:-0}"
    if [ "$mode" = "summary" ]; then
        section "Detected GPUs"
    else
        section "Detected GPUs (after)"
    fi

    local gpu_count=0
    local dev vendor device_id subsystem_vendor subsystem_device
    local pci_slot pci_short vendor_name gpu_model gpu_vram gpu_slot_label
    local driver expected driver_text
    local pci_id_text subsys_id_text subsys_label max_sclk max_mclk
    local cu_count sp_estimate pcie_link_width clock_text
    local gpu_total=0

    gpu_total=$(detect_gpu_devices | awk 'NF { count++ } END { print count + 0 }')

    for dev in $(detect_gpu_devices); do
        gpu_count=$((gpu_count + 1))

        vendor=$(cat "$dev/vendor" 2>/dev/null)
        device_id=$(cat "$dev/device" 2>/dev/null)
        subsystem_vendor=$(cat "$dev/subsystem_vendor" 2>/dev/null)
        subsystem_device=$(cat "$dev/subsystem_device" 2>/dev/null)
        pci_slot=$(basename "$dev")
        pci_short=${pci_slot#0000:}
        vendor_name=$(get_pci_vendor_name "$vendor")
        gpu_model=$(get_pci_gpu_model "$pci_slot" "$vendor" "$device_id" "$vendor_name" "$subsystem_vendor" "$subsystem_device")

        driver=$(bound_driver_for "$dev" 2>/dev/null || true)
        expected=$(expected_module_for_vendor "$vendor")
        if [ "$mode" != "summary" ]; then
            gpu_vram=$(get_pci_gpu_vram "$dev" "$pci_slot" "$vendor" "$device_id" "$driver" "$subsystem_vendor" "$subsystem_device")
            gpu_slot_label=$(get_pci_slot_label "$dev" "$pci_slot")

            pci_id_text="$(strip_pci_hex_prefix "$vendor"):$(strip_pci_hex_prefix "$device_id")"
            if [ -n "$subsystem_vendor" ] && [ -n "$subsystem_device" ]; then
                subsys_id_text="$(strip_pci_hex_prefix "$subsystem_vendor"):$(strip_pci_hex_prefix "$subsystem_device")"
            else
                subsys_id_text=""
            fi
            subsys_label=$(get_pci_subsystem_display_text "$pci_slot" "$subsystem_vendor" "$subsystem_device")
            max_sclk=$(get_gpu_max_sclk "$dev")
            max_mclk=$(get_gpu_max_mclk "$dev")
            cu_count=$(get_gpu_cu_count "$vendor" "$pci_slot")
            sp_estimate=$(get_gpu_sp_estimate_from_cu "$cu_count")
            pcie_link_width=$(get_pci_link_width "$dev" "$pci_slot")
            clock_text=""
            [ -n "$max_sclk" ] && clock_text="SCLK ${max_sclk}"
            if [ -n "$max_mclk" ]; then
                if [ -n "$clock_text" ]; then
                    clock_text="${clock_text} / MCLK ${max_mclk}"
                else
                    clock_text="MCLK ${max_mclk}"
                fi
            fi
        fi

            if [ -z "$driver" ]; then
                driver_text="${RED}not bound (expected: ${expected})${RESET}"
            else
                case "$vendor:$driver" in
                    0x1002:amdgpu|0x1002:radeon|0x10de:nouveau|0x8086:i915)
                        driver_text="${GREEN}${driver}${RESET}"
                        ;;
                    *)
                        driver_text="${YELLOW}${driver}${RESET} (unexpected; expected: ${expected})"
                        ;;
                esac
            fi

        group_title "GPU $gpu_count"
        if [ "$mode" = "summary" ]; then
            item "Model"  "$gpu_model"
        else
            item "Slot"     "$gpu_slot_label"
            item "Model"    "$gpu_model"
            item "PCI ID"   "$pci_id_text"
            [ -n "$subsys_id_text" ] && item "Subsys ID"  "$subsys_id_text"
            [ -n "$subsys_label" ]   && item "Subsys"     "$subsys_label"
            item "VRAM"     "$gpu_vram"
            [ -n "$cu_count" ]       && item "CU"         "$cu_count"
            [ -n "$sp_estimate" ]    && item "SP (est.)"  "$sp_estimate"
            [ -n "$clock_text" ]     && item "Clock"      "$clock_text"
            item "PCIe Bus" "$pcie_link_width"
            item "Driver"   "$driver_text"
        fi
        [ "$gpu_count" -lt "$gpu_total" ] && printf "\n"
    done

    if [ "$gpu_count" -eq 0 ] && [ "$suppress_no_gpu" -eq 0 ]; then
        printf "  ${RED}No GPU detected${RESET}\n"
    fi
    SHOW_GPUS_LAST_COUNT="$gpu_count"
}

# ----- Main -----
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[GPU Test]${RESET}\n\n"
    printf "  Inspecting GPU driver state...\n\n"

    show_gpus summary
    if [ "${SHOW_GPUS_LAST_COUNT:-0}" -gt 0 ]; then
        recover_gpu_bindings
        if [ "${RECOVERY_ATTEMPTED_COUNT:-0}" -gt 0 ]; then
            printf "\n"
            show_gpus full 1
        fi
        show_dri_devices
        if [ "${RECOVERY_ATTEMPTED_COUNT:-0}" -gt 0 ] || [ "${SHOW_DRI_WARN_COUNT:-0}" -gt 0 ]; then
            show_cmdline_and_modules
            show_framebuffer
            show_dmesg_for_gpu
        fi
    fi

    printf "\n"
} > "$TTY" 2>&1

{
    printf "\n${SEP}\nPress any key to return\n"
} > "$TTY"
wait_any_key
exit 0
