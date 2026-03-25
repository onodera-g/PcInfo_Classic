#!/bin/sh
# menu_storage.sh - Storage Health Check (smartctl + nvme)

. /opt/pcinfo/common.sh

SEP='----------------------------------------'

section() {
    printf "${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

item() {
    local label="$1"
    local value="$2"
    printf "  %-22s: %b\n" "$label" "$value"
}

trim_value() {
    printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

value_or_na() {
    local value=""

    value=$(trim_value "$1")
    case "$value" in
        ''|Unknown) printf '%s\n' 'N/A' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

detect_storage_interface() {
    local dev="$1"
    local dev_name=""
    local sys_path=""

    dev_name=$(basename "$dev")
    sys_path=$(readlink -f "/sys/class/block/$dev_name/device" 2>/dev/null)
    case "$sys_path" in
        *"/nvme/"*) echo "NVMe" ;;
        *"/usb"*)   echo "USB" ;;
        *"/ata"*)   echo "SATA" ;;
        *"/sas/"*)  echo "SAS" ;;
        *"/mmc"*)   echo "MMC" ;;
        *"/virtio"*) echo "VirtIO" ;;
        *"/pci"*)   echo "PCIe" ;;
        *)          echo "Unknown" ;;
    esac
}

normalize_integer_token() {
    printf '%s\n' "$1" | awk '
        match($0, /0[xX][0-9A-Fa-f]+|[0-9][0-9,]*/) {
            value = substr($0, RSTART, RLENGTH)
            gsub(/,/, "", value)
            print value
            exit
        }
    '
}

to_decimal_value() {
    local value=""

    value=$(normalize_integer_token "$1")
    case "$value" in
        0[xX]*)
            printf '%s\n' "$((value))"
            ;;
        *[!0-9]*|'')
            printf '\n'
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

format_temperature() {
    local value=""

    value=$(to_decimal_value "$1")
    case "$value" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            printf '%s °C\n' "$value"
            ;;
    esac
}

format_hours() {
    local value=""

    value=$(to_decimal_value "$1")
    case "$value" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            printf '%s hours\n' "$value"
            ;;
    esac
}

format_count() {
    local value=""

    value=$(to_decimal_value "$1")
    case "$value" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            printf '%s count\n' "$value"
            ;;
    esac
}

format_percent() {
    local value=""

    value=$(to_decimal_value "$1")
    case "$value" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            [ "$value" -lt 0 ] && value=0
            [ "$value" -gt 100 ] && value=100
            printf '%s%%\n' "$value"
            ;;
    esac
}

format_decimal_bytes() {
    local bytes=""

    bytes=$(to_decimal_value "$1")
    case "$bytes" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            return 0
            ;;
    esac

    awk -v bytes="$bytes" '
        BEGIN {
            split("B KB MB GB TB PB", units, " ")
            value = bytes + 0
            unit = 1
            while (value >= 1000 && unit < 6) {
                value /= 1000
                unit++
            }
            if (unit == 1) {
                printf "%.0f %s\n", value, units[unit]
            } else {
                printf "%.2f %s\n", value, units[unit]
            }
        }
    '
}

format_unit_count_to_gb() {
    local raw="$1"
    local unit="$2"

    raw=$(to_decimal_value "$raw")
    case "$raw" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            return 0
            ;;
    esac

    awk -v raw="$raw" -v unit="$unit" '
        BEGIN {
            value = raw + 0
            if (unit == "lba512") {
                gb = (value * 512) / 1000000000
            } else if (unit == "32mib") {
                gb = (value * 33554432) / 1000000000
            } else if (unit == "gib") {
                gb = (value * 1073741824) / 1000000000
            } else if (unit == "nvme_data_unit") {
                gb = (value * 512000) / 1000000000
            } else {
                print "N/A"
                exit
            }

            if (gb > 0 && gb < 1) {
                gb = 1
            }
            printf "%.0f GB\n", gb
        }
    '
}

resolve_capacity_block_name() {
    local dev="$1"
    local dev_name=""
    local ns=""

    dev_name=$(basename "$dev")
    case "$dev_name" in
        nvme[0-9]*)
            for ns in /sys/class/nvme/"$dev_name"/"${dev_name}"n*; do
                [ -d "$ns" ] || continue
                basename "$ns"
                return 0
            done
            ;;
    esac

    printf '%s\n' "$dev_name"
}

get_device_capacity() {
    local dev="$1"
    local block_name=""
    local sectors=""
    local bytes=""

    block_name=$(resolve_capacity_block_name "$dev")
    sectors=$(cat "/sys/class/block/$block_name/size" 2>/dev/null)
    sectors=$(to_decimal_value "$sectors")
    case "$sectors" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            bytes=$(awk -v sectors="$sectors" 'BEGIN { printf "%.0f\n", sectors * 512 }')
            format_decimal_bytes "$bytes"
            ;;
    esac
}

get_device_model() {
    local dev="$1"
    local model=""

    case "$dev" in
        /dev/nvme*)
            if command -v nvme > /dev/null 2>&1; then
                model=$(nvme id-ctrl "$dev" 2>/dev/null | sed -n 's/^mn[[:space:]]*:[[:space:]]*//p' | head -n 1)
                model=$(trim_value "$model")
            fi
            [ -n "$model" ] || model="NVMe Drive"
            ;;
        *)
            if command -v smartctl > /dev/null 2>&1; then
                model=$(smartctl -i "$dev" 2>/dev/null | sed -n \
                    -e 's/^Device Model:[[:space:]]*//p' \
                    -e 's/^Model Number:[[:space:]]*//p' \
                    -e 's/^Product:[[:space:]]*//p' | head -n 1)
                model=$(trim_value "$model")
            fi
            [ -n "$model" ] || model="SATA/SAS Drive"
            ;;
    esac

    printf '%s\n' "$model"
}

extract_smart_attr_raw() {
    local text="$1"
    local attr_id="$2"

    printf '%s\n' "$text" | awk -v id="$attr_id" '$1 == id { print $10; exit }'
}

extract_smart_temperature() {
    local text="$1"
    local raw=""

    for attr_id in 194 190; do
        raw=$(extract_smart_attr_raw "$text" "$attr_id")
        raw=$(to_decimal_value "$raw")
        case "$raw" in
            ''|*[!0-9]*) ;;
            *) printf '%s\n' "$raw"; return 0 ;;
        esac
    done

    printf '%s\n' 'N/A'
}

extract_smart_life_percent() {
    local text="$1"
    local match=""
    local display=""
    local raw=""
    local mode=""

    match=$(printf '%s\n' "$text" | awk '
        {
            name = tolower($2)
            if (name ~ /media_wearout_indicator|wear_leveling_count|percent_lifetime_remain|ssd_life_left|remaining_lifetime_persent|remaining_lifetime_pct/) {
                print "remaining\t" $4 "\t" $10
                exit
            }
            if (name ~ /perc_rated_life_used|percentage_used_reserved_block_count_total/) {
                print "used\t" $4 "\t" $10
                exit
            }
        }
    ')

    [ -n "$match" ] || {
        printf '%s\n' 'N/A'
        return 0
    }

    mode=$(printf '%s\n' "$match" | awk -F'\t' '{print $1}')
    display=$(printf '%s\n' "$match" | awk -F'\t' '{print $2}')
    raw=$(printf '%s\n' "$match" | awk -F'\t' '{print $3}')

    display=$(to_decimal_value "$display")
    raw=$(to_decimal_value "$raw")
    case "$display" in
        ''|*[!0-9]*) display="$raw" ;;
    esac

    case "$display" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            return 0
            ;;
    esac

    [ "$display" -lt 0 ] && display=0
    [ "$display" -gt 100 ] && display=100
    [ "$mode" = "used" ] && display=$((100 - display))
    [ "$display" -lt 0 ] && display=0
    printf '%s\n' "$display"
}

extract_smart_total_writes_gb() {
    local text="$1"
    local match=""
    local unit=""
    local raw=""

    match=$(printf '%s\n' "$text" | awk '
        {
            name = tolower($2)
            if (name ~ /host_writes_32mib|nand_writes_32mib/) {
                print "32mib\t" $10
                exit
            }
            if (name ~ /host_writes_gib|nand_writes_1gib|total_writes_gib|lifetime_writes_from_host/) {
                print "gib\t" $10
                exit
            }
            if (name ~ /total_lbas_written|lbas_written|host_writes/) {
                print "lba512\t" $10
                exit
            }
        }
    ')

    [ -n "$match" ] || {
        printf '%s\n' 'N/A'
        return 0
    }

    unit=$(printf '%s\n' "$match" | awk -F'\t' '{print $1}')
    raw=$(printf '%s\n' "$match" | awk -F'\t' '{print $2}')
    format_unit_count_to_gb "$raw" "$unit"
}

extract_sata_health_status() {
    local overall="$1"
    local remaining_percent="$2"
    local reallocated="$3"
    local pending="$4"
    local media_errors="$5"
    local status=""
    local label="Good"

    status=$(printf '%s\n' "$overall" | sed -n \
        -e 's/^SMART overall-health self-assessment test result:[[:space:]]*//p' \
        -e 's/^SMART Health Status:[[:space:]]*//p' | head -n 1)
    status=$(trim_value "$status")

    case "$status" in
        FAILED*|BAD*)
            label="Bad"
            ;;
        ''|Unknown)
            label="N/A"
            ;;
        *)
            case "$(to_decimal_value "$reallocated")" in
                ''|*[!0-9]*) ;;
                *) [ "$(to_decimal_value "$reallocated")" -gt 0 ] && label="Caution" ;;
            esac
            case "$(to_decimal_value "$pending")" in
                ''|*[!0-9]*) ;;
                *) [ "$(to_decimal_value "$pending")" -gt 0 ] && label="Caution" ;;
            esac
            case "$(to_decimal_value "$media_errors")" in
                ''|*[!0-9]*) ;;
                *) [ "$(to_decimal_value "$media_errors")" -gt 0 ] && label="Caution" ;;
            esac
            case "$(to_decimal_value "$remaining_percent")" in
                ''|*[!0-9]*) ;;
                *)
                    if [ "$(to_decimal_value "$remaining_percent")" -le 0 ]; then
                        label="Bad"
                    elif [ "$(to_decimal_value "$remaining_percent")" -le 10 ] && [ "$label" = "Good" ]; then
                        label="Caution"
                    fi
                    ;;
            esac
            ;;
    esac

    if [ "$label" = "N/A" ]; then
        printf '%s\n' 'N/A'
    elif [ "$remaining_percent" = "N/A" ] || [ -z "$remaining_percent" ]; then
        printf '%s\n' "$label"
    else
        printf '%s (%s)\n' "$label" "$(format_percent "$remaining_percent")"
    fi
}

extract_nvme_log_field() {
    local text="$1"
    local field="$2"

    printf '%s\n' "$text" | awk -F: -v field="$field" '
        $1 ~ "^[[:space:]]*" field "[[:space:]]*$" {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            print
            exit
        }
    '
}

extract_nvme_remaining_life() {
    local percentage_used="$1"
    local used=""

    used=$(to_decimal_value "$percentage_used")
    case "$used" in
        ''|*[!0-9]*)
            printf '%s\n' 'N/A'
            ;;
        *)
            [ "$used" -lt 0 ] && used=0
            [ "$used" -gt 100 ] && used=100
            printf '%s\n' "$((100 - used))"
            ;;
    esac
}

extract_nvme_health_status() {
    local critical_warning="$1"
    local remaining_percent="$2"
    local media_errors="$3"
    local label="Good"
    local warning_value=""
    local media_value=""

    warning_value=$(to_decimal_value "$critical_warning")
    media_value=$(to_decimal_value "$media_errors")

    case "$warning_value" in
        ''|*[!0-9]*)
            label="N/A"
            ;;
        0)
            label="Good"
            ;;
        *)
            label="Caution"
            ;;
    esac

    case "$media_value" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$media_value" -gt 0 ] && [ "$label" = "Good" ]; then
                label="Caution"
            fi
            ;;
    esac

    case "$(to_decimal_value "$remaining_percent")" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$(to_decimal_value "$remaining_percent")" -le 0 ]; then
                label="Bad"
            elif [ "$(to_decimal_value "$remaining_percent")" -le 10 ] && [ "$label" = "Good" ]; then
                label="Caution"
            fi
            ;;
    esac

    if [ "$label" = "N/A" ]; then
        printf '%s\n' 'N/A'
    elif [ "$remaining_percent" = "N/A" ] || [ -z "$remaining_percent" ]; then
        printf '%s\n' "$label"
    else
        printf '%s (%s)\n' "$label" "$(format_percent "$remaining_percent")"
    fi
}

extract_nvme_total_writes_gb() {
    local smart="$1"
    local value=""

    value=$(extract_nvme_log_field "$smart" "data_units_written")
    format_unit_count_to_gb "$value" "nvme_data_unit"
}

extract_sata_media_errors() {
    local text="$1"
    local value=""

    value=$(extract_smart_attr_raw "$text" 198)
    value=$(to_decimal_value "$value")
    case "$value" in
        ''|*[!0-9]*) printf '%s\n' 'N/A' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

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
    local smart=""
    local overall=""
    local value=""
    local model=""
    local capacity=""
    local interface=""
    local remaining=""
    local media_errors=""
    local reallocated=""
    local pending=""
    local health=""

    case "$dev" in
        /dev/nvme*)
            section "Storage Health"
            if command -v nvme > /dev/null 2>&1; then
                smart=$(nvme smart-log "$dev" 2>/dev/null)
                if [ -z "$smart" ]; then
                    printf "  ${RED}nvme smart-log failed${RESET}\n"
                    return 0
                fi

                model=$(get_device_model "$dev")
                capacity=$(get_device_capacity "$dev")
                remaining=$(extract_nvme_remaining_life "$(extract_nvme_log_field "$smart" "percentage_used")")
                media_errors=$(extract_nvme_log_field "$smart" "media_errors")
                health=$(extract_nvme_health_status "$(extract_nvme_log_field "$smart" "critical_warning")" "$remaining" "$media_errors")

                item "Device" "$dev"
                item "Model" "$model"
                item "Capacity" "$capacity"
                item "Interface" "NVMe"
                item "Health Status" "$health"
                value=$(extract_nvme_log_field "$smart" "temperature")
                item "Temperature" "$(format_temperature "$value")"
                item "Total Host Writes" "$(extract_nvme_total_writes_gb "$smart")"
                value=$(extract_nvme_log_field "$smart" "power_cycles")
                item "Power On Count" "$(format_count "$value")"
                value=$(extract_nvme_log_field "$smart" "power_on_hours")
                item "Power On Hours" "$(format_hours "$value")"
                item "Reallocated Sectors" "N/A"
                item "Pending Sectors" "N/A"
                item "Media Errors" "$(value_or_na "$media_errors")"
            else
                printf "${YELLOW}nvme-cli not installed${RESET}\n"
            fi
            ;;
        *)
            section "Storage Health"
            if command -v smartctl > /dev/null 2>&1; then
                smart=$(smartctl -A "$dev" 2>/dev/null)
                overall=$(smartctl -H "$dev" 2>/dev/null)
                model=$(get_device_model "$dev")
                capacity=$(get_device_capacity "$dev")
                interface=$(detect_storage_interface "$dev")
                remaining=$(extract_smart_life_percent "$smart")
                reallocated=$(extract_smart_attr_raw "$smart" 5)
                pending=$(extract_smart_attr_raw "$smart" 197)
                media_errors=$(extract_sata_media_errors "$smart")
                health=$(extract_sata_health_status "$overall" "$remaining" "$reallocated" "$pending" "$media_errors")

                item "Device" "$dev"
                item "Model" "$model"
                item "Capacity" "$capacity"
                item "Interface" "$interface"
                item "Health Status" "$health"
                item "Temperature" "$(format_temperature "$(extract_smart_temperature "$smart")")"
                item "Total Host Writes" "$(extract_smart_total_writes_gb "$smart")"
                value=$(extract_smart_attr_raw "$smart" 12)
                item "Power On Count" "$(format_count "$value")"
                value=$(extract_smart_attr_raw "$smart" 9)
                item "Power On Hours" "$(format_hours "$value")"
                item "Reallocated Sectors" "$(value_or_na "$reallocated")"
                item "Pending Sectors" "$(value_or_na "$pending")"
                item "Media Errors" "$(value_or_na "$media_errors")"
            else
                printf "${YELLOW}smartmontools not installed${RESET}\n"
            fi
            ;;
    esac
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
        printf "${BOLD}${CYAN}[Storage Health]${RESET}\n\nNo storage devices found.\n\n${SEP}\nPress any key to return\n" > "$TTY"
        wait_any_key
        return 2>/dev/null
        exit 0
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
