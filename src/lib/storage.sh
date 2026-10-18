#!/bin/sh
# Shared block-device enumeration and read-only storage information.

get_block_device_size() {
    local dev_name="$1"
    local sectors=""

    [ -r "/sys/class/block/$dev_name/size" ] || return 1
    sectors=$(cat "/sys/class/block/$dev_name/size" 2>/dev/null)
    case "$sectors" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo $((sectors * 512))
}

get_block_device_model() {
    local dev_name="$1"
    local value=""

    for value in \
        "/sys/class/block/$dev_name/device/model" \
        "/sys/class/block/$dev_name/device/name"; do
        [ -r "$value" ] || continue
        value=$(tr -d '\n' < "$value" 2>/dev/null)
        value=$(trim_value "$value")
        [ -n "$value" ] && {
            printf '%s\n' "$value"
            return 0
        }
    done

    return 1
}

get_block_device_interface() {
    local dev_name="${1##*/}"
    local sys_path=""

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

storage_transport_name() {
    case "$1" in
        nvme) echo "NVMe" ;;
        sata) echo "SATA" ;;
        ata)  echo "SATA" ;;
        usb)  echo "USB" ;;
        sas)  echo "SAS" ;;
        spi)  echo "SPI" ;;
        mmc)  echo "MMC" ;;
        pci)  echo "PCIe" ;;
        *)    [ -n "$1" ] && printf '%s\n' "$1" || echo "Unknown" ;;
    esac
}

lsblk_pair_value() {
    local line="$1"
    local key="$2"

    printf '%s\n' "$line" | awk -v key="$key" '
        {
            pattern = key "=\""
            pos = index($0, pattern)
            if (pos == 0) {
                exit
            }
            start = pos + length(pattern)
            rest = substr($0, start)
            end = index(rest, "\"")
            if (end == 0) {
                print rest
            } else {
                print substr(rest, 1, end - 1)
            }
        }
    '
}

list_storage_block_devices() {
    local sys_dev=""
    local dev_name=""
    local dev_path=""

    for sys_dev in /sys/class/block/*; do
        [ -e "$sys_dev" ] || continue
        dev_name=$(basename "$sys_dev")
        printf '%s\n' "$dev_name" | grep -Eq '^(sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|vd[a-z]+|xvd[a-z]+)$' || continue
        [ -f "$sys_dev/partition" ] && continue
        dev_path="/dev/$dev_name"
        [ -b "$dev_path" ] || continue
        printf '%s\n' "$dev_path"
    done
}

# JSON is preferred; preserve lsblk's pairs output as the fallback.
STORAGE_RECORD_FORMAT=pairs
STORAGE_RECORDS=""
collect_storage_records() {
    local records=""
    STORAGE_RECORD_FORMAT=json
    if command -v jq >/dev/null 2>&1; then
        records=$(lsblk -d -b -J -o NAME,MODEL,SIZE,TRAN,TYPE 2>/dev/null \
            | jq -c -f /opt/pcinfo/storage_devices.jq 2>/dev/null) || records=""
    fi
    if [ -z "$records" ]; then
        STORAGE_RECORD_FORMAT=pairs
        records=$(lsblk -d -b -P -o NAME,MODEL,SIZE,TRAN,TYPE 2>/dev/null)
    fi
    STORAGE_RECORDS="$records"
}

storage_record_value() {
    local record="$1" field="$2"
    if [ "$STORAGE_RECORD_FORMAT" = json ]; then
        printf '%s\n' "$record" | jq -r --arg field "$field" '.[$field] // empty'
    else
        case "$field" in
            name) field=NAME ;; model) field=MODEL ;; size) field=SIZE ;;
            tran) field=TRAN ;; type) field=TYPE ;;
            *) return 1 ;;
        esac
        lsblk_pair_value "$record" "$field"
    fi
}

count_storage_records() {
    if [ "$STORAGE_RECORD_FORMAT" = json ]; then
        jq -s 'map(select(.type == "disk")) | length'
    else
        awk '
            match($0, /TYPE="[^"]*"/) {
                type = substr($0, RSTART + 6, RLENGTH - 7)
                if (type == "disk") {
                    count++
                }
            }
            END { print count + 0 }
        '
    fi
}
