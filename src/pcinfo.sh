#!/bin/sh
# pcinfo.sh - PC情報収集ツール for Tiny Core Linux
# BusyBox compatible shell script

# autologin 経由で直接起動された場合に PATH が未設定の可能性があるため明示
export PATH="/usr/local/sbin:/usr/local/bin:/apps/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
SEP='----------------------------------------'

# ============================================================
# ユーティリティ
# ============================================================

item() {
    label="$1"
    val="$2"
    # 表示幅 = バイト数 - 継続バイト数/2
    # (全角1文字: 3バイト・2継続バイト → 表示幅2、ASCII: 1バイト → 表示幅1)
    byte_len=$(printf '%s' "$label" | LC_ALL=C wc -c | tr -d ' ')
    cont=$(printf '%s' "$label" | LC_ALL=C tr -cd '\200-\277' | wc -c | tr -d ' ')
    disp_w=$((byte_len - cont / 2))
    pad=$((17 - disp_w))
    [ "$pad" -lt 0 ] && pad=0
    printf "  %s%*s : %s\n" "$label" "$pad" "" "$val"
}

section() {
    printf "\n${BOLD}${CYAN}[%s]${RESET}\n" "$1"
}

sep() {
    echo "$SEP"
}

read_val() {
    [ -r "$1" ] && cat "$1" 2>/dev/null | tr -d '\n' || echo "N/A"
}

# 安全な算術: 非数値は0として扱う
safe_int() {
    case "$1" in
        ''|*[!0-9-]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

# ============================================================
# CPU
# ============================================================
show_cpu() {
    if grep -q '^physical id' /proc/cpuinfo 2>/dev/null; then
        socket_ids=$(grep '^physical id' /proc/cpuinfo | awk '{print $NF}' | sort -un)
        num_sockets=$(printf '%s\n' "$socket_ids" | grep -c .)
    else
        socket_ids="X"
        num_sockets=1
    fi

    for sid in $socket_ids; do
        if [ "$num_sockets" -eq 1 ]; then
            section "CPU"
        else
            section "CPU$((sid + 1))"
        fi

        if [ "$sid" = "X" ]; then
            # physical id なし: 全体をそのまま使う
            cpublock=$(cat /proc/cpuinfo 2>/dev/null)
            threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
        else
            # RS="" でブロック単位読み込み → physical id が sid に一致する最初のブロック
            cpublock=$(awk -v sid="$sid" '
                BEGIN { RS=""; FS="\n" }
                {
                    phys=-1
                    for(i=1;i<=NF;i++){
                        if($i~/^physical id/){ v=$i; sub(/^[^:]*:[[:space:]]*/,"",v); phys=v+0 }
                    }
                    if(phys==sid+0){ print; exit }
                }
            ' /proc/cpuinfo 2>/dev/null)
            # スレッド数 = このソケットに属する processor エントリ数
            threads=$(grep '^physical id' /proc/cpuinfo 2>/dev/null | awk -v sid="$sid" '$NF==sid{c++} END{print c+0}')
        fi

        model=$(printf '%s\n' "$cpublock"    | awk '/^model name/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')
        cores=$(printf '%s\n' "$cpublock"    | awk '/^cpu cores/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')
        stepping=$(printf '%s\n' "$cpublock" | awk '/^stepping/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')
        model_num=$(printf '%s\n' "$cpublock" | awk '/^model[^[:alpha:]]/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')

        first_cpu=$(printf '%s\n' "$cpublock" | awk '/^processor/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}')
        max_mhz=""
        if [ -n "$first_cpu" ] && [ -r "/sys/devices/system/cpu/cpu${first_cpu}/cpufreq/cpuinfo_max_freq" ]; then
            max_khz=$(cat "/sys/devices/system/cpu/cpu${first_cpu}/cpufreq/cpuinfo_max_freq")
            max_mhz=$((max_khz / 1000))
        else
            max_mhz=$(printf '%s\n' "$cpublock" | awk '/^cpu MHz/{sub(/^[^:]*:[[:space:]]*/,""); print; exit}' | cut -d'.' -f1)
        fi

        item "名称" "${model:-N/A}"
        item "コア数" "${cores:-N/A}"
        item "スレッド数" "${threads:-N/A}"
        if [ -n "$max_mhz" ]; then
            item "最大クロック速度" "${max_mhz} MHz"
        else
            item "最大クロック速度" "N/A"
        fi
        item "リビジョン" "${model_num:-N/A}"
        item "ステッピング" "${stepping:-N/A}"
    done
}

# ============================================================
# メモリモジュール (SMBIOS Type 17 直接パース: /usr/local/bin/meminfo)
# ============================================================
show_memory() {
    MEMINFO_BIN="/usr/local/bin/meminfo"
    if [ ! -x "$MEMINFO_BIN" ]; then
        section "メモリ"
        item "Error" "meminfo not found"
        return
    fi

    idx=0
    "$MEMINFO_BIN" 2>/dev/null | while IFS='|' read size_mb pn speed dtype; do
        idx=$((idx + 1))
        section "メモリ${idx}"
        item "モデル番号" "${pn:-N/A}"
        if [ -n "$speed" ] && [ "$speed" != "0" ]; then
            item "クロック速度" "${dtype:+${dtype} }${speed} MHz"
        else
            item "クロック速度" "N/A"
        fi
        if [ "$size_mb" -ge 1024 ] 2>/dev/null; then
            sz=$(echo "$size_mb" | awk '{printf "%.0f GB", $1/1024}')
        else
            sz="${size_mb} MB"
        fi
        item "容量" "${sz:-N/A}"
    done
}

# ============================================================
# マザーボード (dmidecode)
# ============================================================
show_motherboard() {
    section "マザーボード"

    # /sys/class/dmi/id/ は root 不要で常に読める（dmidecode 不要）
    model="$(read_val /sys/class/dmi/id/board_vendor) $(read_val /sys/class/dmi/id/board_name)"
    bios_version=$(read_val /sys/class/dmi/id/bios_version)
    bios_date=$(read_val /sys/class/dmi/id/bios_date)

    item "モデル番号" "${model:-N/A}"
    item "BIOSバージョン" "${bios_version:-N/A}"
    item "BIOS更新日" "${bios_date:-N/A}"
}


# ============================================================
# GPU デバイスIDルックアップ (pci_gpu.ids ベース)
# AMD: HD 3800 / RV670 以降, NVIDIA: GT200 / GTX280 以降, Intel Arc
# ============================================================
gpu_lookup() {
    grep -m1 "^${1}:${2} " /opt/pci_gpu.ids | cut -d' ' -f2-
}

# GPU VRAM ルックアップ (vram_gpu.ids ベース)
# 同一デバイスIDで複数容量がある場合は代表値を記載
# R9 290X(4GB)/390X(8GB) のように共有IDは区別不可
gpu_vram_lookup() {
    grep -m1 "^${1}:${2} " /opt/vram_gpu.ids | awk '{print $2, $3}'
}

# ============================================================
# GPU
# ============================================================
show_gpu() {
    gpu_idx=0
    found_via_drm=0

    # /sys/class/drm から列挙（DRMドライバ使用時）
    for card_dir in /sys/class/drm/card[0-9] /sys/class/drm/card[0-9][0-9]; do
        [ -d "$card_dir/device" ] || continue
        dev="$card_dir/device"
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in 0x03*) ;; *) continue ;; esac

        gpu_idx=$((gpu_idx + 1))
        found_via_drm=1
        section "GPU${gpu_idx}"

        vendor=$(cat "$dev/vendor" 2>/dev/null)
        device=$(cat "$dev/device" 2>/dev/null)
        gpu_name=""

        # デバイスIDルックアップ（NVIDIA proc / amdgpu sysfs が使えない場合のフォールバック前に）
        looked_up=$(gpu_lookup "$vendor" "$device")
        [ -n "$looked_up" ] && gpu_name="$looked_up"

        # NVIDIA: /proc/driver/nvidia/gpus/*/information
        if [ -z "$gpu_name" ] && [ "$vendor" = "0x10de" ] && [ -d "/proc/driver/nvidia/gpus" ]; then
            for nv in /proc/driver/nvidia/gpus/*/information; do
                [ -r "$nv" ] || continue
                name=$(grep '^Model:' "$nv" 2>/dev/null | sed 's/Model:[ 	]*//')
                [ -n "$name" ] && gpu_name="$name" && break
            done
        fi

        # AMD: product_name sysfs (amdgpu driver)
        if [ -z "$gpu_name" ] && [ -r "$dev/product_name" ]; then
            gpu_name=$(cat "$dev/product_name" | tr -d '\n')
        fi

        # lspci (pciutilsがある場合)
        if [ -z "$gpu_name" ] && command -v lspci > /dev/null 2>&1; then
            pci_path=$(readlink -f "$dev" 2>/dev/null | sed 's|.*/||')
            pci_short=$(echo "$pci_path" | sed 's/^0000://')
            line=$(lspci 2>/dev/null | grep "^$pci_short ")
            [ -n "$line" ] && gpu_name=$(echo "$line" | sed 's/.*[Cc]ontroller[^:]*: //')
        fi

        # ベンダー名フォールバック
        if [ -z "$gpu_name" ]; then
            case "$vendor" in
                0x10de) pfx="NVIDIA" ;;
                0x1002) pfx="AMD Radeon" ;;
                0x8086) pfx="Intel Graphics" ;;
                *) pfx="GPU" ;;
            esac
            gpu_name="${pfx} (${device})"
        fi

        item "モデル番号" "$gpu_name"

        # VRAM: AMD amdgpu
        if [ -r "$dev/mem_info_vram_total" ]; then
            vram_b=$(cat "$dev/mem_info_vram_total")
            item "VRAM容量" "$(echo "$vram_b" | awk '{printf "%.2f GB", $1/1073741824}')"
        # VRAM: NVIDIA proc
        elif [ "$vendor" = "0x10de" ] && [ -d "/proc/driver/nvidia/gpus" ]; then
            for nv in /proc/driver/nvidia/gpus/*/information; do
                [ -r "$nv" ] || continue
                vram=$(grep '^Video Memory:' "$nv" 2>/dev/null | awk '{print $3, $4}')
                [ -n "$vram" ] && item "VRAM容量" "$vram" && break
            done
        else
            # デバイスIDルックアップによるVRAMフォールバック
            vram_lkup=$(gpu_vram_lookup "$vendor" "$device")
            [ -n "$vram_lkup" ] && item "VRAM容量" "$vram_lkup"
        fi
    done

    # DRMが使えない場合は /sys/bus/pci/devices フォールバック
    if [ "$found_via_drm" -eq 0 ]; then
        for dev in /sys/bus/pci/devices/*; do
            [ -e "$dev" ] || continue
            class=$(cat "$dev/class" 2>/dev/null)
            case "$class" in 0x03*) ;; *) continue ;; esac
            gpu_idx=$((gpu_idx + 1))
            section "GPU${gpu_idx}"
            vendor=$(cat "$dev/vendor" 2>/dev/null)
            device=$(cat "$dev/device" 2>/dev/null)
            gpu_name_fb=$(gpu_lookup "$vendor" "$device")
            if [ -z "$gpu_name_fb" ]; then
                case "$vendor" in
                    0x10de) pfx="NVIDIA" ;;
                    0x1002) pfx="AMD Radeon" ;;
                    0x8086) pfx="Intel Graphics" ;;
                    *) pfx="GPU" ;;
                esac
                gpu_name_fb="${pfx} (${device})"
            fi
            item "モデル番号" "$gpu_name_fb"
            if [ -r "$dev/mem_info_vram_total" ]; then
                vram_b=$(cat "$dev/mem_info_vram_total")
                item "VRAM容量" "$(echo "$vram_b" | awk '{printf "%.2f GB", $1/1073741824}')"
            else
                vram_lkup=$(gpu_vram_lookup "$vendor" "$device")
                [ -n "$vram_lkup" ] && item "VRAM容量" "$vram_lkup"
            fi
        done
    fi
}

# ============================================================
# ストレージ
# ============================================================
show_storage() {
    disk_idx=0
    for dev in /sys/block/sd* /sys/block/nvme* /sys/block/mmcblk* /sys/block/vd* /sys/block/hd*; do
        [ -e "$dev" ] || continue

        # ループデバイスは除外
        devname=$(basename "$dev")
        case "$devname" in
            loop*) continue ;;
        esac

        disk_idx=$((disk_idx + 1))
        section "ストレージ ディスク${disk_idx}"

        model=""
        for m in "$dev/device/model" "$dev/device/name"; do
            [ -r "$m" ] && model=$(cat "$m" | tr -d '\n' | sed 's/  */ /g; s/ *$//') && break
        done
        # NVMe: モデルはコントローラレベル (/sys/class/nvme/nvme0/model)
        if [ -z "$model" ]; then
            nvme_ctrl=$(echo "$devname" | sed 's/n[0-9]*$//')
            [ -r "/sys/class/nvme/${nvme_ctrl}/model" ] && \
                model=$(cat "/sys/class/nvme/${nvme_ctrl}/model" 2>/dev/null | tr -d '\n' | sed 's/  */ /g; s/ *$//')
        fi

        size_blocks=$(read_val "$dev/size")
        size_blocks=$(safe_int "$size_blocks")
        size_bytes=$((size_blocks * 512))
        if [ "$size_bytes" -ge 1073741824 ] 2>/dev/null; then
            size_str=$(echo "$size_bytes" | awk '{printf "%.2f GB", $1/1073741824}')
        elif [ "$size_bytes" -ge 1048576 ] 2>/dev/null; then
            size_str=$(echo "$size_bytes" | awk '{printf "%.2f MB", $1/1048576}')
        else
            size_str="${size_bytes} B"
        fi

        item "モデル番号" "${model:-N/A}"
        item "サイズ" "$size_str"
    done
}

# profile.d のメニューから呼ばれる: 情報を stdout に出力するだけ
show_cpu
show_memory
show_motherboard
show_gpu
show_storage
printf "\n"
