#!/bin/sh
# menu_storage.sh - Storage Health Check (smartctl JSON + jq)

. /opt/pcinfo/common.sh

section() {
    printf "${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

item() {
    local label="$1"
    local value="$2"
    render_item_escaped "$label" "$value"
}

item_if_meaningful() {
    local label="$1"
    local value=""

    value=$(trim_value "$2")
    case "$value" in
        ''|N/A|Unknown) return 0 ;;
    esac
    item "$label" "$value"
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
            if command -v smartctl > /dev/null 2>&1; then
                local ctrl
                ctrl=$(printf '%s\n' "$dev" | sed 's/n[0-9]*$//')
                model=$(smartctl -i -d nvme "$ctrl" 2>/dev/null | \
                    sed -n 's/^Model Number:[[:space:]]*//p' | head -n 1)
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
            if [ -z "$model" ]; then
                local dev_name
                dev_name=$(basename "$dev")
                model=$(cat "/sys/class/block/$dev_name/device/model" 2>/dev/null | tr -d '\n')
                model=$(trim_value "$model")
            fi
            [ -n "$model" ] || model="SATA/SAS Drive"
            ;;
    esac

    printf '%s\n' "$model"
}

# Keep JSON and process status together; smartctl uses nonzero bits for faults too.
SMART_JSON=""
SMART_STATUS=0
read_smart_json() {
    local dev="$1" interface="$2" dtype="" first_dtype="" candidate="" status=0
    local target="$dev"
    SMART_JSON=""
    SMART_STATUS=0
    case "$interface" in
        NVMe) first_dtype="nvme"; target=$(printf '%s\n' "$dev" | sed 's/n[0-9]*$//') ;;
        SATA) first_dtype="ata" ;;
        SAS) first_dtype="scsi" ;;
    esac
    # Preserve the existing ATA/SAT/SCSI fallbacks. Do not retry past a real
    # failing-health response merely because smartctl returned nonzero.
    for dtype in "$first_dtype" auto sat sat,12 ata scsi; do
        [ -n "$dtype" ] || continue
        if [ "$dtype" = auto ]; then
            candidate=$(smartctl -a -j "$target" 2>/dev/null)
        else
            candidate=$(smartctl -a -j -d "$dtype" "$target" 2>/dev/null)
        fi
        status=$?
        SMART_JSON="$candidate"
        SMART_STATUS="$status"
        if printf '%s\n' "$candidate" | jq -e '
            type == "object" and
            ((.smart_status.passed | type) == "boolean" or
             (.ata_smart_attributes.table | type) == "array" or
             (.nvme_smart_health_information_log | type) == "object" or
             (.scsi_error_counter_log | type) == "object")' >/dev/null 2>&1; then
            return 0
        fi
        [ "$interface" = NVMe ] && break
    done
    return 1
}

show_smart_info() {
    local dev="$1" model="" capacity="" interface="" analysis=""
    local dev_name="" rotational="" drive_type="" tab=""
    interface=$(get_block_device_interface "$dev")
    item "Device" "$dev"
    if ! command -v smartctl >/dev/null 2>&1; then
        item "Health Status" "Unknown"
        item "Reason" "smartmontools is not installed"
        return
    fi
    if ! command -v jq >/dev/null 2>&1 || [ ! -r /opt/pcinfo/smart_health.jq ]; then
        item "Health Status" "Unknown"
        item "Reason" "SMART JSON parser is not installed"
        return
    fi
    read_smart_json "$dev" "$interface" || true
    if ! analysis=$(printf '%s\n' "$SMART_JSON" | jq -ec --argjson exit_status "$SMART_STATUS" \
        -f /opt/pcinfo/smart_health.jq 2>/dev/null); then
        analysis='{"health_status":"Unknown","reason":"SMART data is missing or invalid"}'
    fi
    model=$(printf '%s\n' "$analysis" | jq -r '.model // empty')
    [ -n "$model" ] || model=$(get_device_model "$dev")
    dev_name=$(basename "$dev")
    rotational=$(cat "/sys/class/block/$dev_name/queue/rotational" 2>/dev/null)
    case "$rotational" in 0) drive_type="SSD" ;; 1) drive_type="HDD" ;; esac
    [ -n "$drive_type" ] && model="$model ($drive_type)"
    item_if_meaningful "Model" "$model"
    capacity=$(get_device_capacity "$dev")
    item_if_meaningful "Capacity" "$capacity"
    item_if_meaningful "Interface" "$interface"
    tab=$(printf '\t')
    printf '%s\n' "$analysis" | jq -r 'to_entries[] | [.key, (if .value == null then "" else (.value | tostring) end)] | @tsv' \
      | while IFS="$tab" read -r field value; do
        case "$field" in
            health_status) item "Health Status" "$value" ;;
            reason) item "Reason" "$value" ;;
            remaining_percent) [ -n "$value" ] && item "Remaining Life" "$(format_percent "$value")" ;;
            temperature) [ -n "$value" ] && item "Temperature" "$(format_temperature "$value")" ;;
            total_host_writes_bytes) [ -n "$value" ] && item "Total Host Writes" "$(format_decimal_bytes "$value")" ;;
            power_cycles) [ -n "$value" ] && item "Power On Count" "$(format_count "$value")" ;;
            power_on_hours) [ -n "$value" ] && item "Power On Hours" "$(format_hours "$value")" ;;
            critical_warning) [ -n "$value" ] && item "Critical Warning" "$value" ;;
            available_spare) [ -n "$value" ] && item "Available Spare" "$(format_percent "$value")" ;;
            spare_threshold) [ -n "$value" ] && item "Spare Threshold" "$(format_percent "$value")" ;;
            reallocated) [ -n "$value" ] && item "Reallocated Sectors" "$value" ;;
            pending) [ -n "$value" ] && item "Pending Sectors" "$value" ;;
            reported_uncorrectable) [ -n "$value" ] && item "Reported Uncorrectable" "$value" ;;
            media_errors) [ -n "$value" ] && item "Media Errors" "$value" ;;
        esac
    done
}

# Main
{
    section "Storage Health"
    targets=""
    iface=""
    storage_index=0
    storage_seen=0
    storage_usb_skipped=0

    for d in $(list_storage_block_devices); do
        [ -b "$d" ] || continue
        storage_seen=$((storage_seen + 1))
        iface=$(get_block_device_interface "$d")
        if [ "$iface" = "USB" ]; then
            storage_usb_skipped=$((storage_usb_skipped + 1))
            continue
        fi
        if [ -n "$targets" ]; then
            targets="${targets}
$d"
        else
            targets="$d"
        fi
    done

    storage_total=$(printf '%s\n' "$targets" | awk 'NF { count++ } END { print count + 0 }')
    if [ "$storage_total" -gt 0 ]; then
        printf '%s\n' "$targets" | while IFS= read -r d; do
            [ -n "$d" ] || continue
            storage_index=$((storage_index + 1))
            show_smart_info "$d"
            [ "$storage_index" -lt "$storage_total" ] && printf "\n"
        done
    else
        if [ "$storage_seen" -gt 0 ] && [ "$storage_usb_skipped" -eq "$storage_seen" ]; then
            printf "Only USB storage detected (excluded from health check).\n"
        else
            printf "No storage devices found.\n"
        fi
    fi
} | show_paged_blocks
