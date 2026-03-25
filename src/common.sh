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
GPU_PCI_IDS_FILE="/opt/pcinfo/gpu_pci_ids.txt"
GPU_PCI_SUBSYSTEM_IDS_FILE="/opt/pcinfo/gpu_pci_subsystem_ids.txt"

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

show_paged_blocks() {
    _tmpdir=$(mktemp -d /tmp/pcinfo-pages.XXXXXX 2>/dev/null)
    [ -n "$_tmpdir" ] || {
        show_paged
        return
    }
    _input="$_tmpdir/input.txt"
    cat > "$_input"

    awk -v max="$LINES_PER_PAGE" -v dir="$_tmpdir" '
        function is_blank(idx) {
            return lines[idx] ~ /^[[:space:]]*$/
        }
        function write_page(s, e,    file, i) {
            if (e < s) {
                return
            }
            page++
            file = sprintf("%s/page_%03d.txt", dir, page)
            for (i = s; i <= e; i++) {
                print lines[i] > file
            }
            close(file)
        }
        {
            lines[++n] = $0
        }
        END {
            start = 1
            while (start <= n && is_blank(start)) {
                start++
            }
            while (start <= n) {
                end = start + max - 1
                if (end >= n) {
                    write_page(start, n)
                    break
                }
                split_at = 0
                for (i = end; i > start; i--) {
                    if (is_blank(i)) {
                        split_at = i - 1
                        break
                    }
                }
                if (split_at < start) {
                    split_at = end
                }
                write_page(start, split_at)
                start = split_at + 1
                while (start <= n && is_blank(start)) {
                    start++
                }
            }
        }
    ' "$_input"

    _pages=$(find "$_tmpdir" -maxdepth 1 -name 'page_*.txt' | wc -l | tr -d ' ')
    if [ "$_pages" -eq 0 ]; then
        rm -rf "$_tmpdir"
        return
    fi

    _current=0
    for _page in "$_tmpdir"/page_*.txt; do
        [ -f "$_page" ] || continue
        _current=$((_current + 1))
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        cat "$_page" > "$TTY"
        if [ "$_current" -lt "$_pages" ]; then
            printf '\n%s\nPress Enter for more...\n' "$SEP" > "$TTY"
            read -r _dummy < "$TTY"
        else
            printf '\n%s\nPress q to return to menu\n' "$SEP" > "$TTY"
            while true; do
                read_key
                case "$key" in q|Q|'') break ;; esac
            done
        fi
    done

    rm -rf "$_tmpdir"
}

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

get_pci_vendor_name() {
    case "$1" in
        0x10de) printf '%s\n' 'NVIDIA' ;;
        0x1002) printf '%s\n' 'AMD' ;;
        0x8086) printf '%s\n' 'Intel' ;;
        *)      printf 'Unknown (%s)\n' "$1" ;;
    esac
}

lookup_pci_gpu_record() {
    [ -f "$GPU_PCI_IDS_FILE" ] || return 1
    awk -F '|' -v vendor="$1" -v device="$2" '
        $1 ~ /^#/ { next }
        $1 == vendor && $2 == device {
            print $0
            exit
        }
    ' "$GPU_PCI_IDS_FILE"
}

lookup_pci_gpu_field() {
    local record=""
    record=$(lookup_pci_gpu_record "$1" "$2") || return 1
    printf '%s\n' "$record" | awk -F '|' -v field="$3" '{ print $field }'
}

lookup_pci_gpu_subsystem_record() {
    [ -f "$GPU_PCI_SUBSYSTEM_IDS_FILE" ] || return 1
    awk -F '|' -v vendor="$1" -v device="$2" -v subvendor="$3" -v subdevice="$4" '
        $1 ~ /^#/ { next }
        $1 == vendor && $2 == device && $3 == subvendor && $4 == subdevice {
            print $0
            exit
        }
    ' "$GPU_PCI_SUBSYSTEM_IDS_FILE"
}

lookup_pci_gpu_subsystem_field() {
    local record=""
    record=$(lookup_pci_gpu_subsystem_record "$1" "$2" "$3" "$4") || return 1
    printf '%s\n' "$record" | awk -F '|' -v field="$5" '{ print $field }'
}

normalize_gpu_model_name() {
    local model="$1"

    case "$model" in
        *'['*']'*)
            model=$(printf '%s\n' "$model" | sed -n 's/.*\[\(.*\)\].*/\1/p')
            ;;
    esac

    [ -n "$model" ] && printf '%s\n' "$model"
}

join_display_fields() {
    local out=""

    while [ "$#" -gt 0 ]; do
        if [ -n "$1" ]; then
            if [ -n "$out" ]; then
                out="$out $1"
            else
                out="$1"
            fi
        fi
        shift
    done

    printf '%s\n' "$out"
}

normalize_pci_slot_label() {
    local value="$1"

    value=$(printf '%s\n' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$value" in
        ''|'Slot Unknown')
            printf '%s\n' "$value"
            return 0
            ;;
    esac

    value=$(printf '%s\n' "$value" | sed \
        -e 's/^[Ss]lot[[:space:]]\{1,\}[Ss]lot[[:space:]]*/Slot /' \
        -e 's/^[Ss]lot\([0-9][0-9]*\)$/Slot \1/' \
        -e 's/^[Ss]lot[[:space:]]*\([0-9][0-9]*\)$/Slot \1/')

    printf '%s\n' "$value"
}

get_pci_gpu_manufacturer() {
    local manufacturer=""
    manufacturer=$(lookup_pci_gpu_field "$1" "$2" 3 2>/dev/null)
    [ -n "$manufacturer" ] || manufacturer=$(get_pci_vendor_name "$1")
    printf '%s\n' "$manufacturer"
}

get_pci_gpu_model() {
    local pci_slot="$1"
    local vendor="$2"
    local device_id="$3"
    local vendor_name="$4"
    local subsystem_vendor="$5"
    local subsystem_device="$6"
    local pci_short=""
    local gpu_name=""

    pci_short=$(printf '%s\n' "$pci_slot" | sed 's/^0000://')

    if command -v lspci > /dev/null 2>&1; then
        gpu_name=$(lspci -s "$pci_short" 2>/dev/null | sed 's/.*[Cc]ontroller[^:]*: //')
        gpu_name=$(normalize_gpu_model_name "$gpu_name")

        [ -n "$gpu_name" ] || gpu_name=$(lspci -nn -s "$pci_short" 2>/dev/null | sed 's/.*[Cc]ontroller[^:]*: //' | sed 's/ \[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]$//')
        gpu_name=$(normalize_gpu_model_name "$gpu_name")
    fi

    [ -n "$gpu_name" ] || gpu_name=$(lookup_pci_gpu_subsystem_field "$vendor" "$device_id" "$subsystem_vendor" "$subsystem_device" 6 2>/dev/null)
    gpu_name=$(normalize_gpu_model_name "$gpu_name")

    [ -n "$gpu_name" ] || gpu_name=$(lookup_pci_gpu_field "$vendor" "$device_id" 4 2>/dev/null)
    gpu_name=$(normalize_gpu_model_name "$gpu_name")

    [ -n "$gpu_name" ] || gpu_name="${vendor_name} GPU (${device_id})"
    printf '%s\n' "$gpu_name"
}

format_gpu_vram_bytes() {
    local bytes="$1"
    local gb=$((1000 * 1000 * 1000))
    local mb=$((1000 * 1000))

    [ -n "$bytes" ] || return 1
    case "$bytes" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$bytes" -ge "$gb" ] && [ $((bytes % gb)) -eq 0 ]; then
        printf '%s GB\n' $((bytes / gb))
    else
        printf '%s MB\n' $((bytes / mb))
    fi
}

find_drm_card_for_pci_device() {
    local dev_path="$1"
    local card=""
    local card_dev=""

    for card in /sys/class/drm/card*; do
        [ -e "$card" ] || continue
        card_dev=$(readlink -f "$card/device" 2>/dev/null)
        [ "$card_dev" = "$dev_path" ] && { basename "$card"; return 0; }
    done
    return 1
}

parse_vram_from_dmesg() {
    local text="$1"
    local size=""
    size=$(printf '%s\n' "$text" | sed -n \
        -e 's/.*VRAM:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*GiB.*/\1 GB/p' \
        -e 's/.*VRAM:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*MiB.*/\1 MB/p' \
        -e 's/.*VRAM:[[:space:]]*\([0-9][0-9]*\)G.*/\1 GB/p' \
        -e 's/.*VRAM:[[:space:]]*\([0-9][0-9]*\)M.*/\1 MB/p' \
        -e 's/.*VRAM size[[:space:]]*\([0-9][0-9]*\)G.*/\1 GB/p' \
        -e 's/.*VRAM size[[:space:]]*\([0-9][0-9]*\)M.*/\1 MB/p' \
        -e 's/.*Detected VRAM RAM=\([0-9][0-9]*\)G.*/\1 GB/p' \
        -e 's/.*Detected VRAM RAM=\([0-9][0-9]*\)M.*/\1 MB/p' | head -n 1)
    [ -n "$size" ] && printf '%s\n' "$size"
}

lookup_pci_slot_label_once() {
    local dev_path="$1"
    local pci_slot="$2"
    local slot_name=""
    local slot_dir=""
    local address=""
    local dmi_slot=""

    if [ -r "$dev_path/physical_slot" ]; then
        slot_name=$(tr -d '\n' < "$dev_path/physical_slot" 2>/dev/null)
        [ -n "$slot_name" ] && {
            normalize_pci_slot_label "Slot $slot_name"
            return 0
        }
    fi

    for slot_dir in /sys/bus/pci/slots/*; do
        [ -d "$slot_dir" ] || continue
        [ -r "$slot_dir/address" ] || continue
        address=$(tr -d '\n' < "$slot_dir/address" 2>/dev/null)
        case "$pci_slot" in
            ${address#0000:}*|$address*)
                normalize_pci_slot_label "Slot $(basename "$slot_dir")"
                return 0
                ;;
        esac
    done

    if command -v dmidecode >/dev/null 2>&1; then
        dmi_slot=$(dmidecode -t 9 2>/dev/null | awk -v target="$pci_slot" '
            BEGIN {
                IGNORECASE = 1
                in_block = 0
                designation = ""
                bus = ""
            }
            function trim(s) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
                return s
            }
            function normalized_addr(s,    out) {
                out = toupper(trim(s))
                sub(/^0000:/, "", out)
                return out
            }
            function emit_if_match() {
                if (designation != "" && normalized_addr(bus) == normalized_addr(target)) {
                    print designation
                    exit
                }
            }
            /^Handle / {
                if (in_block) {
                    emit_if_match()
                }
                in_block = 0
                designation = ""
                bus = ""
                next
            }
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)
            }
            line == "System Slot Information" {
                in_block = 1
                next
            }
            !in_block { next }
            line ~ /^Designation:/ {
                designation = trim(substr(line, 13))
                next
            }
            line ~ /^Bus Address:/ {
                bus = trim(substr(line, 13))
                next
            }
            END {
                if (in_block) {
                    emit_if_match()
                }
            }
        ' | head -n 1)
        [ -n "$dmi_slot" ] && {
            normalize_pci_slot_label "Slot $dmi_slot"
            return 0
        }
    fi

    if command -v lspci >/dev/null 2>&1; then
        slot_name=$(lspci -s "${pci_slot#0000:}" -vmm 2>/dev/null | sed -n 's/^PhySlot:[[:space:]]*//p' | head -n 1)
        [ -n "$slot_name" ] && {
            normalize_pci_slot_label "Slot $slot_name"
            return 0
        }

        slot_name=$(lspci -s "${pci_slot#0000:}" -vv 2>/dev/null | sed -n 's/^[[:space:]]*Physical Slot:[[:space:]]*//p' | head -n 1)
        [ -n "$slot_name" ] && {
            normalize_pci_slot_label "Slot $slot_name"
            return 0
        }
    fi

    return 1
}

get_pci_slot_label() {
    local dev_path="$1"
    local pci_slot="$2"
    local current_path=""
    local current_slot=""
    local current_base=""
    local result=""
    local next_path=""

    current_path=$(readlink -f "$dev_path" 2>/dev/null)
    [ -n "$current_path" ] || current_path="$dev_path"

    while [ -n "$current_path" ] && [ -d "$current_path" ]; do
        current_base=$(basename "$current_path")
        case "$current_base" in
            0000:*)
                current_slot="$current_base"
                result=$(lookup_pci_slot_label_once "$current_path" "$current_slot")
                if [ -n "$result" ]; then
                    printf '%s\n' "$result"
                    return 0
                fi
                ;;
        esac

        [ "$current_path" = "/sys/devices" ] && break
        next_path=$(dirname "$current_path")
        [ -n "$next_path" ] || break
        [ "$next_path" = "$current_path" ] && break
        current_path="$next_path"
    done

    printf '%s\n' 'Slot Unknown'
}

get_pci_link_width() {
    local dev_path="$1"
    local pci_slot="$2"
    local width=""

    if [ -r "$dev_path/current_link_width" ]; then
        width=$(tr -d '\n' < "$dev_path/current_link_width" 2>/dev/null)
        case "$width" in
            ''|*[!0-9]*) ;;
            *) printf 'x%s\n' "$width"; return 0 ;;
        esac
    fi

    if command -v lspci >/dev/null 2>&1; then
        width=$(lspci -s "${pci_slot#0000:}" -vv 2>/dev/null | sed -n 's/.*LnkSta:.*Width x\([0-9][0-9]*\).*/x\1/p' | head -n 1)
        [ -n "$width" ] && { printf '%s\n' "$width"; return 0; }
    fi

    printf '%s\n' 'Unknown'
}

get_pci_gpu_vram() {
    local dev_path="$1"
    local pci_slot="$2"
    local vendor="$3"
    local device_id="$4"
    local driver="$5"
    local subsystem_vendor="$6"
    local subsystem_device="$7"
    local card=""
    local vram_bytes=""
    local dmesg_line=""
    local pci_short=""
    if [ "$vendor" = "0x8086" ]; then
        printf '%s\n' 'Shared'
        return 0
    fi

    card=$(find_drm_card_for_pci_device "$dev_path" 2>/dev/null)
    if [ -n "$card" ] && [ -r "/sys/class/drm/$card/device/mem_info_vram_total" ]; then
        vram_bytes=$(cat "/sys/class/drm/$card/device/mem_info_vram_total" 2>/dev/null)
        format_gpu_vram_bytes "$vram_bytes" && return 0
    fi

    pci_short=$(printf '%s\n' "$pci_slot" | sed 's/^0000://')
    if command -v dmesg > /dev/null 2>&1; then
        dmesg_line=$(dmesg 2>/dev/null | grep -E "($pci_short|$driver).*VRAM|Detected VRAM RAM=|VRAM size" | tail -n 20)
        dmesg_line=$(parse_vram_from_dmesg "$dmesg_line")
        [ -n "$dmesg_line" ] && { printf '%s\n' "$dmesg_line"; return 0; }
    fi

    if [ -z "$driver" ] || [ "$driver" = "none" ]; then
        printf '%s\n' 'Unavailable (driver not loaded)'
        return 0
    fi

    printf '%s\n' 'Unknown'
}
