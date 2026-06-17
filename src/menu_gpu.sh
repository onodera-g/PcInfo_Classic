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

    slot=$(basename "$dev_path")
    mods=$(target_modules_for_device "$dev_path")
    [ -n "$mods" ] || return 1

    for mod in $mods; do
        if module_loaded "$mod"; then
            printf '  %s: already loaded\n' "$mod"
        else
            printf '  modprobe %s ... ' "$mod"
            if modprobe "$mod" 2>/tmp/menu_gpu.modprobe.err; then
                printf '%bok%b\n' "$GREEN" "$RESET"
            else
                printf '%bfail%b\n' "$RED" "$RESET"
                sed 's/^/    /' /tmp/menu_gpu.modprobe.err 2>/dev/null
                continue
            fi
        fi

        bound=$(bound_driver_for "$dev_path" 2>/dev/null || true)
        if [ "$bound" = "$mod" ]; then
            printf '  %s: bound to %s\n' "$slot" "$mod"
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
            return 0
        fi
        printf '  %s: %s loaded but did not bind\n' "$slot" "$mod"
    done
    return 1
}

show_cmdline_and_modules() {
    section "Boot state"
    if [ -r /proc/cmdline ]; then
        printf "  cmdline: "
        tr -d '\n' < /proc/cmdline
        printf '\n'
    fi
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
    section "dmesg (GPU related, tail 40)"
    local matches=""
    matches=$(dmesg 2>/dev/null \
        | grep -E '(radeon|amdgpu|nouveau|i915|drm|simpledrm|simple-framebuffer|efifb|firmware)' \
        | tail -n 40)
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | sed 's/^/  /'
    else
        printf "  ${YELLOW}(no matching dmesg lines)${RESET}\n"
    fi
}

# Try to load missing modules and rebind unbound GPUs.
recover_gpu_bindings() {
    section "Recovery attempt"
    local dev driver
    local any_attempted=0
    for dev in $(detect_gpu_devices); do
        driver=$(bound_driver_for "$dev" 2>/dev/null || true)
        case "$driver" in
            amdgpu|radeon|nouveau|i915)
                continue
                ;;
        esac
        any_attempted=1
        printf "  Trying %s ...\n" "$(basename "$dev")"
        attempt_module_bind "$dev" || true
    done
    [ "$any_attempted" -eq 0 ] && printf "  ${GREEN}All GPUs already bound, nothing to do${RESET}\n"
}

show_dri_devices() {
    section "DRM devices"
    if ! ls /dev/dri/card* >/dev/null 2>&1; then
        printf "  ${RED}No /dev/dri/card* device found${RESET}\n"
        printf "  ${RED}[NG] No GPU driver bound at boot${RESET}\n"
        return 1
    fi
    local card card_num drm_drv
    for card in /dev/dri/card*; do
        card_num=$(basename "$card")
        drm_drv=""
        [ -L "/sys/class/drm/$card_num/device/driver" ] && \
            drm_drv=$(basename "$(readlink "/sys/class/drm/$card_num/device/driver" 2>/dev/null)")
        printf "  %s -> ${GREEN}%s${RESET}\n" "$card" "${drm_drv:-present}"
    done
    printf "  ${GREEN}[OK] DRM device(s) available${RESET}\n"
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

show_gpus() {
    section "Detected GPUs"

    local gpu_count=0
    local dev vendor device_id subsystem_vendor subsystem_device
    local pci_slot pci_short vendor_name gpu_model gpu_vram gpu_slot_label
    local driver expected driver_text
    local pci_id_text subsys_id_text subsys_label max_sclk

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
        gpu_vram=$(get_pci_gpu_vram "$dev" "$pci_slot" "$vendor" "$device_id" "$driver" "$subsystem_vendor" "$subsystem_device")
        gpu_slot_label=$(get_pci_slot_label "$dev" "$pci_slot")

        pci_id_text="$(strip_pci_hex_prefix "$vendor"):$(strip_pci_hex_prefix "$device_id")"
        if [ -n "$subsystem_vendor" ] && [ -n "$subsystem_device" ]; then
            subsys_id_text="$(strip_pci_hex_prefix "$subsystem_vendor"):$(strip_pci_hex_prefix "$subsystem_device")"
        else
            subsys_id_text=""
        fi
        subsys_label=$(get_pci_subsystem_label "$pci_short")
        max_sclk=$(get_gpu_max_sclk "$dev")

        if [ -n "$driver" ]; then
            driver_text="${GREEN}${driver}${RESET}"
        else
            driver_text="${RED}not bound (expected: ${expected})${RESET}"
        fi

        group_title "GPU $gpu_count"
        item "Slot"     "$gpu_slot_label"
        item "Model"    "$gpu_model"
        item "PCI ID"   "$pci_id_text"
        [ -n "$subsys_id_text" ] && item "Subsys ID"  "$subsys_id_text"
        [ -n "$subsys_label" ]   && item "Subsys"     "$subsys_label"
        item "VRAM"     "$gpu_vram"
        [ -n "$max_sclk" ]       && item "Max SCLK"   "$max_sclk"
        item "Driver"   "$driver_text"
        printf "\n"
    done

    [ "$gpu_count" -eq 0 ] && printf "  ${RED}No GPU detected${RESET}\n"
}

# ----- Main -----
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[GPU Test]${RESET}\n\n"
    printf "  Inspecting GPU driver state...\n\n"

    show_cmdline_and_modules
    show_gpus
    recover_gpu_bindings
    printf "\n"
    show_gpus
    show_dri_devices
    show_framebuffer
    show_dmesg_for_gpu

    printf "\n"
} > "$TTY" 2>&1

{
    printf "\n${SEP}\nPress any key to return\n"
} > "$TTY"
wait_any_key
exit 0
