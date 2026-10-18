#!/bin/sh
# GPU identification, rule lookup and read-only hardware information.

GPU_PCI_IDS_FILE="/opt/pcinfo/gpu_pci_ids.txt"
GPU_PCI_SUBSYSTEM_IDS_FILE="/opt/pcinfo/gpu_pci_subsystem_ids.txt"
PCI_IDS_FILE="/opt/pcinfo/pci.ids"
GPU_DISAMBIGUATION_RULES_FILE="/opt/pcinfo/gpu_disambiguation_rules.txt"
GPU_AMD_CU_VRAM_RULES_FILE="/opt/pcinfo/gpu_amd_cu_vram_rules.txt"
GPU_NVIDIA_LITERAL_RULES_FILE="/opt/pcinfo/gpu_nvidia_literal_rules.txt"
GPU_NVIDIA_VRAM_RULES_FILE="/opt/pcinfo/gpu_nvidia_vram_rules.txt"

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

is_ambiguous_gpu_model_name() {
    local model="$1"
    case "$model" in
        *'/'*|*Series*|*series*)
            return 0
            ;;
    esac
    return 1
}

strip_pci_hex_prefix() {
    printf '%s\n' "${1#0x}"
}

get_pci_subsystem_label() {
    local pci_slot="$1"
    local pci_short=""

    pci_short=$(printf '%s\n' "$pci_slot" | sed 's/^0000://')
    command -v lspci >/dev/null 2>&1 || return 0
    lspci -v -s "$pci_short" 2>/dev/null | awk -F': ' '
        /^[[:space:]]*Subsystem:/ {
            sub(/^[[:space:]]+/, "", $2)
            print $2
            exit
        }
    '
}

lookup_pci_vendor_label() {
    local vendor_id="$1"

    [ -f "$PCI_IDS_FILE" ] || return 1
    vendor_id=$(printf '%s\n' "${vendor_id#0x}" | tr '[:upper:]' '[:lower:]')
    awk -v vendor="$vendor_id" '
        /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            id=tolower(substr($0, 1, 4))
            if (id == vendor) {
                name=substr($0, 7)
                sub(/^[[:space:]]+/, "", name)
                sub(/[[:space:]]+$/, "", name)
                print name
                exit
            }
        }
    ' "$PCI_IDS_FILE"
}

get_pci_subsystem_display_text() {
    local pci_slot="$1"
    local subsystem_vendor="$2"
    local subsystem_device="$3"
    local label=""

    if [ -n "$subsystem_vendor" ]; then
        label=$(lookup_pci_vendor_label "$subsystem_vendor" 2>/dev/null)
        if [ -n "$label" ]; then
            printf '%s\n' "$label"
            return 0
        fi
    fi

    label=$(get_pci_subsystem_label "$pci_slot")
    if [ -n "$label" ]; then
        label=$(printf '%s\n' "$label" | sed 's/[[:space:]]*Device[[:space:]].*$//')
        printf '%s\n' "$label"
        return 0
    fi

    if [ -n "$subsystem_vendor" ] && [ -n "$subsystem_device" ]; then
        printf '%s:%s\n' "$(strip_pci_hex_prefix "$subsystem_vendor")" "$(strip_pci_hex_prefix "$subsystem_device")"
    fi
}

# KFD topology is device-scoped and can supply CU counts even without a log.
get_amd_cu_from_topology() {
    local pci="$1" address="" bus="" devfn="" dev_num=0 fn_num=0 domain=0 location=0 node="" result=""
    address=${pci#*:}
    bus=$(printf '%d' "0x${address%%:*}") || return 1
    devfn=${address#*:}
    domain=$(printf '%d' "0x${pci%%:*}") || return 1
    dev_num=$(printf '%d' "0x${devfn%.*}") || return 1
    fn_num=${devfn#*.}
    location=$((bus * 256 + dev_num * 8 + fn_num))
    for node in /sys/class/kfd/kfd/topology/nodes/*; do
        [ -r "$node/properties" ] && [ -r "$node/gpu_id" ] || continue
        [ "$(cat "$node/gpu_id" 2>/dev/null)" != 0 ] || continue
        result=$(awk -v domain="$domain" -v location="$location" '
            $1 == "domain" { d=$2; seen_d=1 }
            $1 == "location_id" { l=$2; seen_l=1 }
            $1 == "simd_count" { simd=$2 }
            $1 == "simd_per_cu" { per_cu=$2 }
            END {
                if (seen_d && seen_l && d == domain && l == location &&
                    simd > 0 && per_cu > 0 && simd % per_cu == 0)
                    printf "%.0f\n", simd / per_cu
            }' "$node/properties" 2>/dev/null)
        [ -n "$result" ] && { printf '%s\n' "$result"; return 0; }
    done
    return 1
}

get_amd_active_cu_count() {
    local pci_slot="$1"
    local pci_full="" drm_card="" cu_count="" dev="" amd_count=0 single=0
    case "$pci_slot" in
        ????:??:??.?) pci_full="$pci_slot" ;;
        ??:??.?) pci_full="0000:$pci_slot" ;;
        *) return 1 ;;
    esac
    pci_full=$(printf '%s\n' "$pci_full" | tr '[:upper:]' '[:lower:]')
    printf '%s\n' "$pci_full" | grep -Eq '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$' || return 1
    cu_count=$(get_amd_cu_from_topology "$pci_full" 2>/dev/null) || cu_count=""
    if [ -z "$cu_count" ]; then
        drm_card=$(find_drm_card_for_pci_device "/sys/bus/pci/devices/$pci_full" 2>/dev/null) || drm_card=""
        for dev in /sys/bus/pci/devices/*; do
            [ "$(cat "$dev/vendor" 2>/dev/null)" = 0x1002 ] || continue
            case "$(cat "$dev/class" 2>/dev/null)" in
                0x030000|0x030001|0x030002|0x030200|0x038000) amd_count=$((amd_count + 1)) ;;
            esac
        done
        [ "$amd_count" -eq 1 ] && single=1
        command -v jq >/dev/null 2>&1 || return 1
        # Retain both legacy log formats; never borrow a second GPU's CU count.
        cu_count=$(dmesg 2>/dev/null | jq -Rrs --arg pci "$pci_full" \
            --arg card "$drm_card" --arg single "$single" --arg mode cu -f /opt/pcinfo/gpu_logs.jq 2>/dev/null) || cu_count=""
    fi

    case "$cu_count" in
        ''|*[!0-9]*) return 1 ;;
    esac

    printf '%s\n' "$cu_count"
}

lookup_amd_gpu_model_from_cu_vram_rules() {
    local device_id="$1"
    local cu_count="$2"
    local vram_mb="$3"
    local rule_device=""
    local rule_cu_pattern=""
    local rule_vram_pattern=""
    local rule_name=""

    [ -f "$GPU_AMD_CU_VRAM_RULES_FILE" ] || return 1

    while IFS='|' read -r rule_device rule_cu_pattern rule_vram_pattern rule_name; do
        case "$rule_device" in
            ''|'#'*) continue ;;
        esac
        [ "$rule_device" = "$device_id" ] || continue
        [ -n "$rule_cu_pattern" ] || continue
        [ -n "$rule_vram_pattern" ] || continue
        [ -n "$rule_name" ] || continue

        case "$cu_count" in
            $rule_cu_pattern) ;;
            *) continue ;;
        esac
        case "$vram_mb" in
            $rule_vram_pattern) ;;
            *) continue ;;
        esac

        printf '%s\n' "$rule_name"
        return 0
    done < "$GPU_AMD_CU_VRAM_RULES_FILE"

    return 1
}

lookup_nvidia_literal_model_from_rules() {
    local device_id="$1"
    local gpu_name="$2"
    local rule_device=""
    local rule_name_regex=""
    local rule_name=""

    [ -f "$GPU_NVIDIA_LITERAL_RULES_FILE" ] || return 1

    while IFS='|' read -r rule_device rule_name_regex rule_name; do
        case "$rule_device" in
            ''|'#'*) continue ;;
        esac
        [ "$rule_device" = "$device_id" ] || continue
        [ -n "$rule_name_regex" ] || continue
        [ -n "$rule_name" ] || continue
        printf '%s\n' "$gpu_name" | grep -Eiq -- "$rule_name_regex" || continue

        printf '%s\n' "$rule_name"
        return 0
    done < "$GPU_NVIDIA_LITERAL_RULES_FILE"

    return 1
}

rule_field_matches() {
    local rule_value="$1"
    local actual_value="$2"

    case "$rule_value" in
        '*') return 0 ;;
        '') return 1 ;;
    esac

    [ "$rule_value" = "$actual_value" ]
}

parse_gpu_vram_text_to_mb() {
    local vram_text="$1"
    local vram_mb=""

    vram_mb=$(printf '%s\n' "$vram_text" | sed -n \
        -e 's/^\([0-9][0-9]*\)[[:space:]]*GB$/\1/p' \
        -e 's/^\([0-9][0-9]*\)[[:space:]]*MB$/\1/p')

    case "$vram_text" in
        *GB)
            vram_mb=$((vram_mb * 1000))
            ;;
    esac

    case "$vram_mb" in
        ''|*[!0-9]*) return 1 ;;
    esac

    printf '%s\n' "$vram_mb"
}

get_amd_gpu_model_from_cu_vram() {
    local device_id="$1"
    local pci_slot="$2"
    local vram_text="$3"
    local cu_count=""
    local vram_mb=""

    cu_count=$(get_amd_active_cu_count "$pci_slot" 2>/dev/null) || return 1
    vram_mb=$(parse_gpu_vram_text_to_mb "$vram_text" 2>/dev/null) || return 1

    lookup_amd_gpu_model_from_cu_vram_rules "$device_id" "$cu_count" "$vram_mb"
}

get_amd_gpu_model_from_runtime() {
    local pci_slot="$1"
    local vendor="$2"
    local device_id="$3"
    local dev_path=""
    local driver=""
    local vram_text=""
    local refined=""

    [ "$vendor" = "0x1002" ] || {
        return 1
    }

    case "$pci_slot" in ??:??.?) pci_slot="0000:$pci_slot" ;; esac
    dev_path="/sys/bus/pci/devices/$pci_slot"
    if [ -L "$dev_path/driver" ]; then
        driver=$(basename "$(readlink "$dev_path/driver" 2>/dev/null)")
    else
        driver="none"
    fi
    vram_text=$(get_pci_gpu_vram "$dev_path" "$pci_slot" "$vendor" "$device_id" "$driver" "" "")
    refined=$(get_amd_gpu_model_from_cu_vram "$device_id" "$pci_slot" "$vram_text" 2>/dev/null) || refined=""
    [ -n "$refined" ] || return 1
    printf '%s\n' "$refined"
}

lookup_nvidia_gpu_model_from_vram_rules() {
    local device_id="$1"
    local vram_mb="$2"
    local rule_device=""
    local rule_vram_pattern=""
    local rule_name=""

    [ -f "$GPU_NVIDIA_VRAM_RULES_FILE" ] || return 1

    while IFS='|' read -r rule_device rule_vram_pattern rule_name; do
        case "$rule_device" in
            ''|'#'*) continue ;;
        esac
        [ "$rule_device" = "$device_id" ] || continue
        [ -n "$rule_vram_pattern" ] || continue
        [ -n "$rule_name" ] || continue

        case "$vram_mb" in
            $rule_vram_pattern) ;;
            *) continue ;;
        esac

        printf '%s\n' "$rule_name"
        return 0
    done < "$GPU_NVIDIA_VRAM_RULES_FILE"

    return 1
}

get_nvidia_gpu_model_from_runtime() {
    local pci_slot="$1"
    local vendor="$2"
    local device_id="$3"
    local dev_path=""
    local driver=""
    local vram_text=""
    local vram_mb=""
    local refined=""

    [ "$vendor" = "0x10de" ] || return 1

    dev_path="/sys/bus/pci/devices/$pci_slot"
    if [ -L "$dev_path/driver" ]; then
        driver=$(basename "$(readlink "$dev_path/driver" 2>/dev/null)")
    else
        driver="none"
    fi

    vram_text=$(get_pci_gpu_vram "$dev_path" "$pci_slot" "$vendor" "$device_id" "$driver" "" "")
    vram_mb=$(parse_gpu_vram_text_to_mb "$vram_text" 2>/dev/null) || return 1
    refined=$(lookup_nvidia_gpu_model_from_vram_rules "$device_id" "$vram_mb" 2>/dev/null) || refined=""
    [ -n "$refined" ] || return 1
    printf '%s\n' "$refined"
}

resolve_gpu_model_by_rules() {
    local pci_slot="$1"
    local vendor="$2"
    local device_id="$3"
    local gpu_name="$4"
    local rule_vendor=""
    local rule_device=""
    local name_regex=""
    local rule_type=""
    local resolved_name=""
    local refined=""

    [ -f "$GPU_DISAMBIGUATION_RULES_FILE" ] || return 1

    while IFS='|' read -r rule_vendor rule_device name_regex rule_type resolved_name; do
        case "$rule_vendor" in
            ''|'#'*) continue ;;
        esac
        rule_field_matches "$rule_vendor" "$vendor" || continue
        rule_field_matches "$rule_device" "$device_id" || continue
        [ -n "$name_regex" ] || continue
        printf '%s\n' "$gpu_name" | grep -Eiq -- "$name_regex" || continue

        refined=""
        case "$rule_type" in
            literal)
                [ -n "$resolved_name" ] || continue
                printf '%s\n' "$resolved_name"
                return 0
                ;;
            amd_cu_vram)
                refined=$(get_amd_gpu_model_from_runtime "$pci_slot" "$vendor" "$device_id" 2>/dev/null) || refined=""
                [ -n "$refined" ] || continue
                printf '%s\n' "$refined"
                return 0
                ;;
            nvidia_vram)
                refined=$(get_nvidia_gpu_model_from_runtime "$pci_slot" "$vendor" "$device_id" 2>/dev/null) || refined=""
                [ -n "$refined" ] || continue
                printf '%s\n' "$refined"
                return 0
                ;;
            nvidia_literal_map)
                refined=$(lookup_nvidia_literal_model_from_rules "$device_id" "$gpu_name" 2>/dev/null) || refined=""
                [ -n "$refined" ] || continue
                printf '%s\n' "$refined"
                return 0
                ;;
        esac
    done < "$GPU_DISAMBIGUATION_RULES_FILE"

    return 1
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
    local pci_short=""
    local gpu_name=""
    local refined_name=""

    pci_short=$(printf '%s\n' "$pci_slot" | sed 's/^0000://')

    if command -v lspci > /dev/null 2>&1; then
        gpu_name=$(lspci -s "$pci_short" 2>/dev/null | sed 's/.*[Cc]ontroller[^:]*: //')
        gpu_name=$(normalize_gpu_model_name "$gpu_name")

        [ -n "$gpu_name" ] || gpu_name=$(lspci -nn -s "$pci_short" 2>/dev/null | sed 's/.*[Cc]ontroller[^:]*: //' | sed 's/ \[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]$//')
        gpu_name=$(normalize_gpu_model_name "$gpu_name")
    fi

    [ -n "$gpu_name" ] || gpu_name=$(lookup_pci_gpu_field "$vendor" "$device_id" 4 2>/dev/null)
    gpu_name=$(normalize_gpu_model_name "$gpu_name")

    [ -n "$gpu_name" ] || gpu_name="${vendor_name} GPU (${device_id})"
    if is_ambiguous_gpu_model_name "$gpu_name"; then
        refined_name=$(resolve_gpu_model_by_rules "$pci_slot" "$vendor" "$device_id" "$gpu_name" 2>/dev/null) || refined_name=""
        [ -n "$refined_name" ] && gpu_name="$refined_name"
    fi
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

    dev_path=$(readlink -f "$dev_path" 2>/dev/null) || return 1
    [ -n "$dev_path" ] || return 1
    for card in /sys/class/drm/card[0-9]*; do
        [ -e "$card" ] || continue
        case "$(basename "$card")" in *-*) continue ;; esac
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
    local pci_full="" dev="" gpu_count=0 single=0
    if [ "$vendor" = "0x8086" ]; then
        printf '%s\n' 'Shared'
        return 0
    fi

    card=$(find_drm_card_for_pci_device "$dev_path" 2>/dev/null)
    if [ -n "$card" ] && [ -r "/sys/class/drm/$card/device/mem_info_vram_total" ]; then
        vram_bytes=$(cat "/sys/class/drm/$card/device/mem_info_vram_total" 2>/dev/null)
        format_gpu_vram_bytes "$vram_bytes" && return 0
    fi

    case "$pci_slot" in ??:??.?) pci_full="0000:$pci_slot" ;; *) pci_full="$pci_slot" ;; esac
    if command -v dmesg > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
        for dev in /sys/bus/pci/devices/*; do
            case "$(cat "$dev/class" 2>/dev/null)" in
                0x030000|0x030001|0x030002|0x030200|0x038000) gpu_count=$((gpu_count + 1)) ;;
            esac
        done
        [ "$gpu_count" -eq 1 ] && single=1
        dmesg_line=$(dmesg 2>/dev/null | jq -Rrs --arg pci "$pci_full" \
            --arg card "$card" --arg single "$single" --arg mode vram -f /opt/pcinfo/gpu_logs.jq 2>/dev/null | tail -n 20)
        dmesg_line=$(parse_vram_from_dmesg "$dmesg_line")
        [ -n "$dmesg_line" ] && { printf '%s\n' "$dmesg_line"; return 0; }
    fi

    if [ -z "$driver" ] || [ "$driver" = "none" ]; then
        printf '%s\n' 'Unavailable (driver not loaded)'
        return 0
    fi

    printf '%s\n' 'Unknown'
}
