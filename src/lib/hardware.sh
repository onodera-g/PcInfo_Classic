#!/bin/sh
# Read-only hardware snapshot, scoped to one PC Info invocation.

collect_hardware_snapshot() {
    PCINFO_LSCPU_AVAILABLE=0
    PCINFO_DMI_AVAILABLE=0
    PCINFO_LSCPU=""
    PCINFO_DMI_PROCESSOR=""
    PCINFO_DMI_BASEBOARD=""
    PCINFO_DMI_BIOS=""
    if command -v lscpu >/dev/null 2>&1; then
        PCINFO_LSCPU_AVAILABLE=1
        PCINFO_LSCPU=$(lscpu 2>/dev/null)
    fi
    if command -v dmidecode >/dev/null 2>&1; then
        PCINFO_DMI_AVAILABLE=1
        PCINFO_DMI_PROCESSOR=$(dmidecode -t 4 2>/dev/null)
        PCINFO_DMI_BASEBOARD=$(dmidecode -t 2 2>/dev/null)
        PCINFO_DMI_BIOS=$(dmidecode -t 0 2>/dev/null)
    fi
    return 0
}

first_lscpu_value() {
    [ "${PCINFO_LSCPU_AVAILABLE:-0}" -eq 1 ] || return 1
    printf '%s\n' "$PCINFO_LSCPU" | awk -F ':' -v key="$1" '
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
    '
}

first_dmidecode_value() {
    local kind="$1" key="$2" heading="" data=""
    [ "${PCINFO_DMI_AVAILABLE:-0}" -eq 1 ] || return 1
    case "$kind" in
        0) heading="BIOS Information"; data="$PCINFO_DMI_BIOS" ;;
        2) heading="Base Board Information"; data="$PCINFO_DMI_BASEBOARD" ;;
        4) heading="Processor Information"; data="$PCINFO_DMI_PROCESSOR" ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$data" | awk -F ':' -v key="$key" -v heading="$heading" '
        BEGIN { in_block=0 }
        $0 == heading { in_block=1; next }
        /^Handle / {
            if (in_block) exit
            next
        }
        in_block {
            field=$1
            sub(/^[[:space:]]+/, "", field)
            sub(/[[:space:]]+$/, "", field)
            if (field == key) {
                value=substr($0, index($0, ":") + 1)
                sub(/^[[:space:]]+/, "", value)
                print value
                exit
            }
        }
    '
}
