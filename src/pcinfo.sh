#!/bin/sh
# pcinfo.sh - PC Information Collector (Alpine Linux / BusyBox compatible)

. /opt/pcinfo/common.sh
. /opt/pcinfo/lib/hardware.sh

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

item() {
    local label="$1" val="$2"
    render_item "$label" "$val"
}

group_title() {
    printf "%s\n" "$1"
}

indented_group_title() {
    printf " %s\n" "$1"
}

subitem() {
    local label="$1" val="$2"
    render_item "$label" "$val"
}

section() {
    printf "\n${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

na() { echo "N/A"; }

format_decimal_bytes() {
    local bytes="$1"

    [ -n "$bytes" ] || return 1
    case "$bytes" in
        ''|*[!0-9]*) return 1 ;;
    esac

    awk -v bytes="$bytes" '
        function out(val, unit) {
            if (val >= 10 || int(val) == val) {
                printf "%.0f %s\n", val, unit
            } else {
                printf "%.1f %s\n", val, unit
            }
        }
        BEGIN {
            if (bytes >= 1000000000000) out(bytes / 1000000000000, "TB")
            else if (bytes >= 1000000000) out(bytes / 1000000000, "GB")
            else if (bytes >= 1000000) out(bytes / 1000000, "MB")
            else printf "%d B\n", bytes
        }
    '
}

format_memory_total_bytes() {
    local bytes="$1"

    [ -n "$bytes" ] || return 1
    case "$bytes" in
        ''|*[!0-9]*) return 1 ;;
    esac

    awk -v bytes="$bytes" '
        function out(val, unit) {
            if (val >= 10 || int(val) == val) {
                printf "%.0f %s\n", val, unit
            } else {
                printf "%.1f %s\n", val, unit
            }
        }
        BEGIN {
            if (bytes >= 1099511627776) out(bytes / 1099511627776, "TB")
            else if (bytes >= 1073741824) out(bytes / 1073741824, "GB")
            else if (bytes >= 1048576) out(bytes / 1048576, "MB")
            else printf "%d B\n", bytes
        }
    '
}

normalize_capacity_text() {
    local value="$1"
    local number=""
    local unit=""
    local bytes=""

    value=$(trim_value "$value")
    case "$value" in
        Unknown|Shared|'') printf '%s\n' "$value"; return 0 ;;
    esac

    number=$(printf '%s\n' "$value" | awk '{print $1}')
    unit=$(printf '%s\n' "$value" | awk '{print $2}')

    case "$number:$unit" in
        *[!0-9.]*:*) printf '%s\n' "$value"; return 0 ;;
    esac

    case "$unit" in
        TB|TiB) bytes=$(awk -v n="$number" 'BEGIN{printf "%.0f", n * 1000000000000}') ;;
        GB|GiB) bytes=$(awk -v n="$number" 'BEGIN{printf "%.0f", n * 1000000000}') ;;
        MB|MiB) bytes=$(awk -v n="$number" 'BEGIN{printf "%.0f", n * 1000000}') ;;
        KB|KiB) bytes=$(awk -v n="$number" 'BEGIN{printf "%.0f", n * 1000}') ;;
        B) bytes=$(awk -v n="$number" 'BEGIN{printf "%.0f", n}') ;;
        *) printf '%s\n' "$value"; return 0 ;;
    esac

    format_decimal_bytes "$bytes"
}

normalize_speed_text() {
    local value="$1"
    local number=""

    value=$(trim_value "$value")
    case "$value" in
        Unknown*|'') printf '%s\n' "$value"; return 0 ;;
    esac

    number=$(printf '%s\n' "$value" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
    [ -n "$number" ] || { printf '%s\n' "$value"; return 0; }
    printf '%s MHz\n' "$number"
}

normalize_memory_locator() {
    local value="$1"
    local parsed=""
    local channel=""
    local slot_index=""

    value=$(trim_value "$value")

    parsed=$(printf '%s\n' "$value" | sed -n 's/^Channel\([A-Za-z]\)-DIMM\([0-9][0-9]*\)$/\1|\2/p')
    if [ -n "$parsed" ]; then
        channel=${parsed%|*}
        slot_index=${parsed#*|}
        printf '%s-DIMM %s\n' "$channel" "$((slot_index + 1))"
        return 0
    fi

    parsed=$(printf '%s\n' "$value" | sed -n 's/^DIMM_\([A-Za-z]\)\([0-9][0-9]*\)$/\1|\2/p')
    if [ -n "$parsed" ]; then
        channel=${parsed%|*}
        slot_index=${parsed#*|}
        printf '%s-DIMM %s\n' "$channel" "$((slot_index + 1))"
        return 0
    fi

    parsed=$(printf '%s\n' "$value" | sed -n 's/^DIMM[ _]*\([A-Za-z]\)[ _]*\([0-9][0-9]*\)$/\1|\2/p')
    if [ -n "$parsed" ]; then
        channel=${parsed%|*}
        slot_index=${parsed#*|}
        printf '%s-DIMM %s\n' "$channel" "$((slot_index + 1))"
        return 0
    fi

    parsed=$(printf '%s\n' "$value" | sed -n 's/^Channel[[:space:]]*\([A-Za-z]\)[[:space:]]*DIMM[[:space:]]*\([0-9][0-9]*\)$/\1|\2/p')
    if [ -n "$parsed" ]; then
        channel=${parsed%|*}
        slot_index=${parsed#*|}
        printf '%s-DIMM %s\n' "$channel" "$((slot_index + 1))"
        return 0
    fi

    printf '%s\n' "$value"
}

normalize_vram_text() {
    local value="$1"
    local number=""
    local unit=""

    value=$(trim_value "$value")
    case "$value" in
        Unknown|Shared|'') printf '%s\n' "$value"; return 0 ;;
    esac

    number=$(printf '%s\n' "$value" | awk '{print $1}')
    unit=$(printf '%s\n' "$value" | awk '{print $2}')

    case "$number:$unit" in
        *[!0-9.]*:*) printf '%s\n' "$value"; return 0 ;;
    esac

    case "$unit" in
        TB|TiB) awk -v n="$number" 'BEGIN { printf "%.0f MB\n", n * 1024 * 1024 }' ;;
        GB|GiB) awk -v n="$number" 'BEGIN { printf "%.0f MB\n", n * 1024 }' ;;
        MB|MiB) awk -v n="$number" 'BEGIN { printf "%.0f MB\n", n }' ;;
        KB|KiB) awk -v n="$number" 'BEGIN { printf "%.0f MB\n", n / 1024 }' ;;
        B)      awk -v n="$number" 'BEGIN { printf "%.0f MB\n", n / 1048576 }' ;;
        *)      printf '%s\n' "$value" ;;
    esac
}

first_cpuinfo_value() {
    awk -F ':' -v key="$1" '
        {
            field=$1
            sub(/^[[:space:]]+/, "", field)
            sub(/[[:space:]]+$/, "", field)
        }
        field == key {
            value=substr($0, index($0, ":") + 1)
            sub(/^[[:space:]]+/, "", value)
            print value
            exit
        }
    ' /proc/cpuinfo 2>/dev/null
}

get_motherboard_model() {
    local manufacturer="" product="" value=""
    manufacturer=$(first_dmidecode_value 2 "Manufacturer")
    product=$(first_dmidecode_value 2 "Product Name")
    case "$manufacturer" in
        ''|'Not Specified'|'Unknown'|'To Be Filled By O.E.M.') manufacturer="" ;;
    esac
    case "$product" in
        ''|'Not Specified'|'Unknown'|'To Be Filled By O.E.M.') product="" ;;
    esac
    value=$(join_display_fields "$manufacturer" "$product")
    [ -n "$value" ] || value=$(na)
    trim_value "$value"
}

get_bios_version() {
    local value=""
    value=$(first_dmidecode_value 0 "Version")
    case "$value" in
        ''|'Not Specified'|'Unknown') value="" ;;
    esac
    [ -n "$value" ] || value=$(na)
    trim_value "$value"
}

get_bios_release_date() {
    local value=""
    value=$(first_dmidecode_value 0 "Release Date")
    case "$value" in
        ''|'Not Specified'|'Unknown') value="" ;;
    esac
    [ -n "$value" ] || value=$(na)
    trim_value "$value"
}

get_cpu_model_name() {
    local value=""

    value=$(first_lscpu_value "Model name")
    [ -n "$value" ] || value=$(first_cpuinfo_value "model name")
    [ -n "$value" ] || value=$(first_dmidecode_value 4 "Version")
    [ -n "$value" ] || value=$(first_cpuinfo_value "Hardware")
    [ -n "$value" ] || value=$(first_cpuinfo_value "Processor")
    [ -n "$value" ] || value=$(uname -m 2>/dev/null)

    trim_value "$value"
}

get_cpu_thread_count() {
    local value=""

    value=$(first_lscpu_value "CPU(s)")
    [ -n "$value" ] || value=$(first_dmidecode_value 4 "Thread Count")
    [ -n "$value" ] || value=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [ -n "$value" ] || value="1"

    trim_value "$value"
}

get_cpu_core_count() {
    local sockets="" cores_per_socket="" value=""

    sockets=$(first_lscpu_value "Socket(s)")
    cores_per_socket=$(first_lscpu_value "Core(s) per socket")
    case "$sockets:$cores_per_socket" in
        *[!0-9:]*|'':) ;;
        *)
            value=$((sockets * cores_per_socket))
            ;;
    esac

    [ -n "$value" ] || value=$(first_lscpu_value "Core(s) per cluster")
    [ -n "$value" ] || value=$(first_dmidecode_value 4 "Core Count")
    [ -n "$value" ] || value=$(first_cpuinfo_value "cpu cores")
    [ -n "$value" ] || value=$(get_cpu_thread_count)

    trim_value "$value"
}

get_cpu_stepping() {
    local value=""

    value=$(first_lscpu_value "Stepping")
    [ -n "$value" ] || value=$(first_cpuinfo_value "stepping")
    [ -n "$value" ] || value=$(first_cpuinfo_value "CPU revision")
    [ -n "$value" ] || value=$(na)

    trim_value "$value"
}

get_cpu_family_model() {
    local family="" model="" value=""

    family=$(first_lscpu_value "CPU family")
    [ -n "$family" ] || family=$(first_cpuinfo_value "cpu family")
    model=$(first_lscpu_value "Model")
    [ -n "$model" ] || model=$(first_cpuinfo_value "model")
    if [ -n "$family" ] || [ -n "$model" ]; then
        value=$(join_display_fields "Family" "$family" "/" "Model" "$model")
    fi

    [ -n "$value" ] || value=$(na)

    trim_value "$value"
}

format_memory_module_record() {
    local size="$1"
    local locator="$2"
    local bank="$3"
    local manufacturer="$4"
    local part="$5"
    local speed="$6"
    local configured="$7"
    local model=""
    local freq=""

    size=$(trim_value "$size")
    locator=$(trim_value "$locator")
    bank=$(trim_value "$bank")
    manufacturer=$(trim_value "$manufacturer")
    part=$(trim_value "$part")
    speed=$(trim_value "$speed")
    configured=$(trim_value "$configured")

    case "$size" in
        ""|"No Module Installed"|"Unknown") return 0 ;;
    esac

    if [ -z "$locator" ] || [ "$locator" = "Not Specified" ]; then
        locator="$bank"
    fi
    if [ -z "$locator" ] || [ "$locator" = "Not Specified" ]; then
        locator="Memory Slot"
    fi

    model="$part"
    if [ -z "$model" ] || [ "$model" = "Not Specified" ] || [ "$model" = "Unknown" ]; then
        model="$manufacturer"
    fi
    if [ -z "$model" ] || [ "$model" = "Not Specified" ] || [ "$model" = "Unknown" ]; then
        model="Unknown Module"
    fi

    freq="$configured"
    if [ -z "$freq" ] || [ "$freq" = "Not Specified" ] || [ "$freq" = "Unknown" ]; then
        freq="$speed"
    fi
    if [ -z "$freq" ] || [ "$freq" = "Not Specified" ] || [ "$freq" = "Unknown" ]; then
        freq="Unknown Speed"
    fi

    printf '%s|%s|%s|%s\n' "$locator" "$model" "$size" "$freq"
}

get_dmidecode_source_status() {
    if [ -r /sys/firmware/dmi/tables/DMI ]; then
        printf '%s\n' 'sysfs DMI'
        return 0
    fi
    if [ -c /dev/mem ]; then
        printf '%s\n' '/dev/mem fallback'
        return 0
    fi
    printf '%s\n' 'DMI unavailable'
}

get_dmidecode_command_status() {
    if command -v dmidecode >/dev/null 2>&1; then
        printf '%s\n' 'Installed'
    else
        printf '%s\n' 'Missing'
    fi
}

list_memory_modules() {
    local in_block=0
    local size=""
    local locator=""
    local bank=""
    local manufacturer=""
    local part=""
    local speed=""
    local configured=""
    local output=""

    command -v dmidecode >/dev/null 2>&1 || return 1

    while IFS= read -r raw_line; do
        line=$(trim_value "$raw_line")

        case "$line" in
            Handle\ *)
                if [ "$in_block" -eq 1 ]; then
                    record=$(format_memory_module_record "$size" "$locator" "$bank" "$manufacturer" "$part" "$speed" "$configured")
                    [ -n "$record" ] && output="${output}${record}
"
                fi
                in_block=0
                size=""
                locator=""
                bank=""
                manufacturer=""
                part=""
                speed=""
                configured=""
                ;;
            "Memory Device")
                in_block=1
                ;;
            *)
                [ "$in_block" -eq 1 ] || continue
                case "$line" in
                    Size:*)
                        size=${line#Size: }
                        ;;
                    Locator:*)
                        locator=${line#Locator: }
                        ;;
                    Bank\ Locator:*)
                        bank=${line#Bank Locator: }
                        ;;
                    Manufacturer:*)
                        manufacturer=${line#Manufacturer: }
                        ;;
                    Part\ Number:*)
                        part=${line#Part Number: }
                        ;;
                    Configured\ Memory\ Speed:*)
                        configured=${line#Configured Memory Speed: }
                        ;;
                    Speed:*)
                        speed=${line#Speed: }
                        ;;
                esac
                ;;
        esac
    done <<EOF
$(dmidecode -t 17 2>/dev/null)
EOF

    if [ "$in_block" -eq 1 ]; then
        record=$(format_memory_module_record "$size" "$locator" "$bank" "$manufacturer" "$part" "$speed" "$configured")
        [ -n "$record" ] && output="${output}${record}
"
    fi
    printf '%s' "$output"
}

sum_memory_module_capacity_bytes() {
    printf '%s\n' "$1" | awk -F '|' '
        function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
        }
        {
            size = trim($3)
            if (size == "" || size == "Unknown") {
                next
            }
            count = split(size, parts, /[[:space:]]+/)
            value = parts[1] + 0
            unit = toupper(parts[2])
            if (value <= 0) {
                next
            }
            if (unit == "TB" || unit == "TIB") {
                sum += value * 1000000000000
            } else if (unit == "GB" || unit == "GIB") {
                sum += value * 1000000000
            } else if (unit == "MB" || unit == "MIB") {
                sum += value * 1000000
            } else if (unit == "KB" || unit == "KIB") {
                sum += value * 1000
            } else if (unit == "B") {
                sum += value
            }
        }
        END {
            if (sum > 0) {
                printf "%.0f\n", sum
            }
        }
    '
}

get_total_memory_capacity() {
    local memory_modules="$1"
    local sum_bytes=""
    local mem_kb=""
    local bytes=""

    if [ -n "$memory_modules" ]; then
        sum_bytes=$(sum_memory_module_capacity_bytes "$memory_modules")
        case "$sum_bytes" in
            ''|*[!0-9]*) ;;
            *)
                format_decimal_bytes "$sum_bytes"
                return 0
                ;;
        esac
    fi

    mem_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
    case "$mem_kb" in
        ''|*[!0-9]*) echo "Unknown" ;;
        *)
            bytes=$((mem_kb * 1024))
            format_memory_total_bytes "$bytes"
            ;;
    esac
}

render_storage_entry() {
    local storage_index="$1"
    local storage_total="$2"
    local dev_name="$3"
    local model="$4"
    local capacity="$5"
    local iface="$6"

    if [ "$storage_total" -gt 1 ]; then
        indented_group_title "Storage $storage_index"
        subitem "Device" "$dev_name"
        [ "$model" != "$dev_name" ] && subitem "Model" "$model"
        subitem "Capacity" "$capacity"
        [ -n "$iface" ] && [ "$iface" != "Unknown" ] && subitem "Interface" "$iface"
    else
        item "Device" "$dev_name"
        [ "$model" != "$dev_name" ] && item "Model" "$model"
        item "Capacity" "$capacity"
        [ -n "$iface" ] && [ "$iface" != "Unknown" ] && item "Interface" "$iface"
    fi
}

# ============================================================
# CPU
# ============================================================
collect_hardware_snapshot
section "CPU"

item "Model" "$(get_cpu_model_name)"
item "Cores" "$(get_cpu_core_count)"
item "Threads" "$(get_cpu_thread_count)"
item "Stepping" "$(get_cpu_stepping)"
item "Family / Model" "$(get_cpu_family_model)"

# ============================================================
# Motherboard
# ============================================================
section "Motherboard"

item "Model" "$(get_motherboard_model)"
item "BIOS Version" "$(get_bios_version)"
item "BIOS Date" "$(get_bios_release_date)"

# ============================================================
# Memory
# ============================================================
section "Memory"

memory_modules=$(list_memory_modules)
if [ -n "$memory_modules" ]; then
    first_memory=1
    memory_index=0
    memory_total=$(printf '%s\n' "$memory_modules" | awk 'NF { count++ } END { print count + 0 }')
    printf '%s\n' "$memory_modules" | while IFS='|' read -r locator model size freq; do
        [ "$first_memory" -eq 0 ] && printf '\n'
        first_memory=0
        memory_index=$((memory_index + 1))
        if [ "$memory_total" -gt 1 ]; then
            indented_group_title "Memory $memory_index"
            subitem "Slot" "$(normalize_memory_locator "$locator")"
            subitem "Model" "$model"
            subitem "Capacity" "$(normalize_capacity_text "$size")"
            subitem "Speed" "$(normalize_speed_text "$freq")"
        else
            item "Slot" "$(normalize_memory_locator "$locator")"
            item "Model" "$model"
            item "Capacity" "$(normalize_capacity_text "$size")"
            item "Speed" "$(normalize_speed_text "$freq")"
        fi
    done
else
    item "Memory" "No populated slot data"
fi

# ============================================================
# GPU / Display
# ============================================================
section "GPU / Display"

gpu_total=0
for dev in /sys/bus/pci/devices/*; do
    [ -d "$dev" ] || continue
    class=$(cat "$dev/class" 2>/dev/null)
    case "$class" in
        0x030000|0x030001|0x030002|0x030200|0x038000) gpu_total=$((gpu_total + 1)) ;;
    esac
done

gpu_count=0
for dev in /sys/bus/pci/devices/*; do
    [ -d "$dev" ] || continue
    class=$(cat "$dev/class" 2>/dev/null)
    case "$class" in
        0x030000|0x030001|0x030002|0x030200|0x038000) ;;
        *) continue ;;
    esac

    gpu_count=$((gpu_count + 1))
    vendor=$(cat "$dev/vendor" 2>/dev/null)
    dev_id=$(cat "$dev/device" 2>/dev/null)
    subsystem_vendor=$(cat "$dev/subsystem_vendor" 2>/dev/null)
    subsystem_device=$(cat "$dev/subsystem_device" 2>/dev/null)
    slot=$(basename "$dev")

    vname=$(get_pci_vendor_name "$vendor")
    gpu_model=$(get_pci_gpu_model "$slot" "$vendor" "$dev_id" "$vname" "$subsystem_vendor" "$subsystem_device")

    drv=""
    [ -L "$dev/driver" ] && drv=$(basename "$(readlink "$dev/driver" 2>/dev/null)")
    [ -z "$drv" ] && drv="none"
    gpu_vram=$(get_pci_gpu_vram "$dev" "$slot" "$vendor" "$dev_id" "$drv" "$subsystem_vendor" "$subsystem_device")
    gpu_subsys=$(get_pci_subsystem_display_text "$slot" "$subsystem_vendor" "$subsystem_device")
    gpu_slot_label=$(get_pci_slot_label "$dev" "$slot")
    gpu_link_width=$(get_pci_link_width "$dev" "$slot")
    [ "$gpu_count" -gt 1 ] && printf '\n'
    if [ "$gpu_total" -gt 1 ]; then
        indented_group_title "GPU $gpu_count"
        subitem "Slot" "$gpu_slot_label"
        subitem "Model" "$gpu_model"
        [ -n "$gpu_subsys" ] && subitem "Subsys" "$gpu_subsys"
        subitem "VRAM" "$(normalize_vram_text "$gpu_vram")"
        subitem "Driver" "$drv"
        subitem "PCIe Link" "$gpu_link_width"
    else
        item "Slot" "$gpu_slot_label"
        item "Model" "$gpu_model"
        [ -n "$gpu_subsys" ] && item "Subsys" "$gpu_subsys"
        item "VRAM" "$(normalize_vram_text "$gpu_vram")"
        item "Driver" "$drv"
        item "PCIe Link" "$gpu_link_width"
    fi
done
[ "$gpu_count" -eq 0 ] && item "GPU" "Not detected"

# ============================================================
# Storage
# ============================================================
section "Storage"

if command -v lsblk > /dev/null 2>&1; then
    storage_index=0
    collect_storage_records
    storage_lines="$STORAGE_RECORDS"
    storage_total=$(printf '%s\n' "$storage_lines" | count_storage_records)
    printf '%s\n' "$storage_lines" | while IFS= read -r line; do
        name=$(storage_record_value "$line" "name")
        model=$(storage_record_value "$line" "model")
        size=$(storage_record_value "$line" "size")
        tran=$(storage_record_value "$line" "tran")
        dtype=$(storage_record_value "$line" "type")
        [ "$dtype" = "disk" ] || continue
        [ -n "$name" ] || continue
        storage_index=$((storage_index + 1))
        model=$(trim_value "$model")
        tran=$(trim_value "$tran")
        [ -n "$model" ] || model="$name"
        iface=$(storage_transport_name "$tran")
        capacity_text=$(format_decimal_bytes "$size")
        [ -n "$capacity_text" ] || capacity_text="Unknown"
        [ "$storage_index" -gt 1 ] && printf '\n'
        render_storage_entry "$storage_index" "$storage_total" "$name" "$model" "$capacity_text" "$iface"
    done
    [ "$storage_total" -eq 0 ] && item "Storage" "Not detected"
else
    storage_index=0
    storage_total=0
    for d in $(list_storage_block_devices); do
        [ -b "$d" ] || continue
        storage_total=$((storage_total + 1))
    done
    for d in $(list_storage_block_devices); do
        [ -b "$d" ] || continue
        dev_name=$(basename "$d")
        size=$(get_block_device_size "$dev_name")
        model=$(get_block_device_model "$dev_name")
        [ -n "$model" ] || model="$dev_name"
        iface=$(get_block_device_interface "$dev_name")
        capacity="Unknown"
        if [ -n "$size" ]; then
            capacity_text=$(format_decimal_bytes "$size")
            [ -n "$capacity_text" ] && capacity="$capacity_text"
        fi
        storage_index=$((storage_index + 1))
        [ "$storage_index" -gt 1 ] && printf '\n'
        render_storage_entry "$storage_index" "$storage_total" "$dev_name" "$model" "$capacity" "$iface"
    done
fi

printf "\n"
