#!/bin/sh
# pcinfo.sh - PC Information Collector (Alpine Linux / BusyBox compatible)

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
SEP='----------------------------------------'

item() {
    local label="$1" val="$2"
    printf "  %-22s: %s\n" "$label" "$val"
}

section() {
    printf "\n${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

na() { echo "N/A"; }

# ============================================================
# CPU
# ============================================================
section "CPU"

cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')
[ -z "$cpu_model" ] && cpu_model=$(uname -m)
item "Model" "$cpu_model"

cpu_cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
item "Logical Cores" "$cpu_cores"

cpu_phys=$(grep 'physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
[ "$cpu_phys" -eq 0 ] && cpu_phys=1
item "Physical Sockets" "$cpu_phys"

cpu_mhz=$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' | cut -d. -f1)
[ -n "$cpu_mhz" ] && item "Current MHz" "${cpu_mhz} MHz"

# Architecture info from lscpu
if command -v lscpu > /dev/null 2>&1; then
    virt=$(lscpu 2>/dev/null | awk -F': *' '/Virtualization:/{print $2}')
    [ -n "$virt" ] && item "Virtualization" "$virt"
    cache=$(lscpu 2>/dev/null | awk -F': *' '/L3 cache:/{print $2}')
    [ -z "$cache" ] && cache=$(lscpu 2>/dev/null | awk -F': *' '/L2 cache:/{print $2}')
    [ -n "$cache" ] && item "Cache (L3/L2)" "$cache"
fi

# ============================================================
# Memory
# ============================================================
section "Memory"

mem_total=$(awk '/MemTotal:/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)
mem_free=$(awk '/MemAvailable:/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)
item "Total" "$mem_total"
item "Available" "$mem_free"

# DMI memory slot info
if command -v dmidecode > /dev/null 2>&1; then
    slot=0
    dmidecode -t 17 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *"Memory Device"*)
                slot=$((slot + 1))
                ;;
            *"Size:"*)
                sz=$(echo "$line" | cut -d: -f2- | tr -d ' ')
                if [ "$sz" != "NoModuleInstalled" ] && [ "$sz" != "Unknown" ]; then
                    printf "  Slot %-17s: %s\n" "$slot" "$sz"
                fi
                ;;
            *"Type:"*)
                tp=$(echo "$line" | cut -d: -f2- | tr -d ' ')
                [ "$tp" = "Unknown" ] || printf "  Type %-17s: %s\n" "$slot" "$tp"
                ;;
            *"Speed:"*)
                sp=$(echo "$line" | cut -d: -f2- | tr -d ' ')
                [ "$sp" = "Unknown" ] || printf "  Speed %-16s: %s\n" "$slot" "$sp"
                ;;
        esac
    done
fi

# ============================================================
# Motherboard / System
# ============================================================
section "Motherboard / System"

if command -v dmidecode > /dev/null 2>&1; then
    mb_mfr=$(dmidecode -s baseboard-manufacturer 2>/dev/null | tr -d '\n')
    mb_prod=$(dmidecode -s baseboard-product-name 2>/dev/null | tr -d '\n')
    mb_ver=$(dmidecode -s baseboard-version 2>/dev/null | tr -d '\n')
    sys_mfr=$(dmidecode -s system-manufacturer 2>/dev/null | tr -d '\n')
    sys_prod=$(dmidecode -s system-product-name 2>/dev/null | tr -d '\n')
    bios_ver=$(dmidecode -s bios-version 2>/dev/null | tr -d '\n')
    bios_date=$(dmidecode -s bios-release-date 2>/dev/null | tr -d '\n')

    item "System Maker" "$sys_mfr"
    item "System Model" "$sys_prod"
    item "Board Maker" "$mb_mfr"
    item "Board Model" "$mb_prod"
    item "Board Version" "$mb_ver"
    item "BIOS Version" "$bios_ver"
    item "BIOS Date" "$bios_date"
else
    item "Board / BIOS" "dmidecode not available"
fi

# UEFI or BIOS
if [ -d /sys/firmware/efi ]; then
    item "Firmware" "UEFI"
else
    item "Firmware" "BIOS (Legacy)"
fi

# ============================================================
# GPU / Display
# ============================================================
section "GPU / Display"

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
    slot=$(basename "$dev" | sed 's/^0000://')

    case "$vendor" in
        0x10de) vname="NVIDIA" ;;
        0x1002) vname="AMD" ;;
        0x8086) vname="Intel" ;;
        *)      vname="Other($vendor)" ;;
    esac

    gpu_name=""
    if command -v lspci > /dev/null 2>&1; then
        gpu_name=$(lspci 2>/dev/null | grep "^$slot " | sed 's/.*[Cc]ontroller[^:]*: //' | cut -c1-48)
    fi
    [ -z "$gpu_name" ] && gpu_name="${vname} (${dev_id})"

    drv=""
    [ -L "$dev/driver" ] && drv=$(basename "$(readlink "$dev/driver" 2>/dev/null)")
    [ -z "$drv" ] && drv="none"

    item "GPU $gpu_count" "$gpu_name"
    item "  Driver" "$drv"
done
[ "$gpu_count" -eq 0 ] && item "GPU" "Not detected"

# ============================================================
# Storage
# ============================================================
section "Storage"

if command -v lsblk > /dev/null 2>&1; then
    printf "  %-10s %-8s %-6s %-6s %s\n" "NAME" "SIZE" "TYPE" "TRAN" "MODEL"
    printf "  %s\n" "$SEP"
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null | tail -n +2 | \
        while IFS= read -r line; do printf "  %s\n" "$line"; done
else
    for d in /dev/sd? /dev/nvme?; do
        [ -b "$d" ] || continue
        printf "  %s\n" "$d"
    done
fi

# ============================================================
# Network Interfaces
# ============================================================
section "Network Interfaces"

printf "  %-12s %-18s %-10s\n" "Interface" "IP Address" "State"
printf "  %s\n" "$SEP"
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    state=$(cat "$iface/operstate" 2>/dev/null)
    ip=$(ip addr show "$name" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    [ -z "$ip" ] && ip="(none)"
    printf "  %-12s %-18s %-10s\n" "$name" "$ip" "$state"
done

# ============================================================
# OS / Kernel
# ============================================================
section "OS / Kernel"

item "Kernel" "$(uname -r 2>/dev/null)"
item "Architecture" "$(uname -m 2>/dev/null)"
item "Hostname" "$(hostname 2>/dev/null)"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    item "OS Name" "${PRETTY_NAME:-${NAME:-Unknown}}"
fi

uptime_str=$(uptime 2>/dev/null | sed 's/^ //')
item "Uptime" "$uptime_str"

printf "\n"
