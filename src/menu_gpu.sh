#!/bin/sh
# menu_gpu.sh - GPUテスト画面

. /opt/common.sh

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

GPU_MODULES_DIR="/opt/gpu_modules"
KERNEL_VER=$(uname -r)

# モジュールをロード（.ko.gz対応）
load_module() {
    local name="$1"
    local path="$2"
    
    if [ ! -f "$path" ]; then
        echo "FILE_NOT_FOUND: $path" >> /tmp/gpu_debug.log
        return 1
    fi
    
    # .gzの場合は解凍してからロード
    if echo "$path" | grep -q '\.gz$'; then
        local tmpko="/tmp/${name}.ko"
        if ! zcat "$path" > "$tmpko" 2>/tmp/zcat_err.txt; then
            echo "ZCAT_FAIL: $path - $(cat /tmp/zcat_err.txt)" >> /tmp/gpu_debug.log
            return 1
        fi
        local err=$(insmod "$tmpko" 2>&1)
        local ret=$?
        if [ $ret -ne 0 ]; then
            echo "INSMOD_FAIL: $name - $err" >> /tmp/gpu_debug.log
        fi
        rm -f "$tmpko"
        return $ret
    else
        local err=$(insmod "$path" 2>&1)
        local ret=$?
        if [ $ret -ne 0 ]; then
            echo "INSMOD_FAIL: $name - $err" >> /tmp/gpu_debug.log
        fi
        return $ret
    fi
}

# GPUモジュールをインストールしてロード
load_gpu_drivers() {
    printf "\n${BOLD}${CYAN}[GPU診断]${RESET}\n\n"
    
    local MODDIR="$GPU_MODULES_DIR/$KERNEL_VER/kernel/drivers"
    
    if [ ! -d "$MODDIR" ]; then
        printf "${RED}GPUモジュールが見つかりません${RESET}\n"
        printf "  探索パス: $MODDIR\n\n"
        return 1
    fi
    
    printf "GPUドライバをロード中...\n\n"
    
    # 1. AGP (一部のGPUで必要)
    printf "  AGPサポート... "
    load_module "agpgart" "$MODDIR/char/agp/agpgart.ko.gz" && printf "${GREEN}OK${RESET}\n" || printf "${YELLOW}スキップ${RESET}\n"
    load_module "amd64-agp" "$MODDIR/char/agp/amd64-agp.ko.gz" 2>/dev/null
    
    # 2. DRM基盤（必須）
    printf "  DRM基盤... "
    if load_module "drm" "$MODDIR/gpu/drm/drm.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}失敗${RESET}\n"
        return 1
    fi
    
    # 3. DRM共通ヘルパー
    printf "  DRMヘルパー... "
    load_module "drm_kms_helper" "$MODDIR/gpu/drm/drm_kms_helper.ko.gz"
    load_module "drm_display_helper" "$MODDIR/gpu/drm/display/drm_display_helper.ko.gz"
    load_module "drm_buddy" "$MODDIR/gpu/drm/drm_buddy.ko.gz"
    load_module "drm_exec" "$MODDIR/gpu/drm/drm_exec.ko.gz"
    load_module "drm_shmem_helper" "$MODDIR/gpu/drm/drm_shmem_helper.ko.gz"
    load_module "drm_suballoc_helper" "$MODDIR/gpu/drm/drm_suballoc_helper.ko.gz"
    printf "${GREEN}OK${RESET}\n"
    
    # 4. TTM (メモリ管理、radeon/amdgpu/nouveauで必須)
    printf "  TTMメモリ管理... "
    if load_module "ttm" "$MODDIR/gpu/drm/ttm/ttm.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
        load_module "drm_ttm_helper" "$MODDIR/gpu/drm/drm_ttm_helper.ko.gz"
    else
        printf "${YELLOW}スキップ${RESET}\n"
    fi
    
    # 5. GPUスケジューラ (amdgpuで必要)
    printf "  GPUスケジューラ... "
    load_module "gpu-sched" "$MODDIR/gpu/drm/scheduler/gpu-sched.ko.gz" && printf "${GREEN}OK${RESET}\n" || printf "${YELLOW}スキップ${RESET}\n"
    
    # 5.5 drm_vram_helper (一部GPUで必要)
    load_module "drm_vram_helper" "$MODDIR/gpu/drm/drm_vram_helper.ko.gz" 2>/dev/null
    
    # 6. AMD radeon (R9 290X等、旧世代)
    printf "  radeon (AMD旧世代)... "
    if load_module "radeon" "$MODDIR/gpu/drm/radeon/radeon.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # 7. AMD amdgpu (新世代)
    printf "  amdgpu (AMD新世代)... "
    load_module "amdxcp" "$MODDIR/gpu/drm/amd/amdxcp/amdxcp.ko.gz"
    if load_module "amdgpu" "$MODDIR/gpu/drm/amd/amdgpu/amdgpu.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # 8. NVIDIA nouveau
    printf "  nouveau (NVIDIA)... "
    if load_module "nouveau" "$MODDIR/gpu/drm/nouveau/nouveau.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # 9. Intel i915
    printf "  i915 (Intel)... "
    if load_module "i915" "$MODDIR/gpu/drm/i915/i915.ko.gz"; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    printf "\nデバイス初期化待機中..."
    sleep 2
    
    # ロードされたモジュールを確認
    printf "\n\n${YELLOW}[DEBUG] lsmod (GPU関連):${RESET}\n"
    lsmod 2>/dev/null | grep -iE 'drm|radeon|amdgpu|nouveau|i915' | head -10
    
    # GPUデバイスにドライバをバインド
    printf "\n${YELLOW}GPUにドライバをバインド中...${RESET}\n"
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac
        
        # すでにドライバがバインドされていればスキップ
        [ -L "$dev/driver" ] && continue
        
        slot=$(basename "$dev")
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        
        # ベンダーに応じてドライバをバインド
        case "$vendor" in
            0x1002)  # AMD
                if [ -d /sys/bus/pci/drivers/radeon ]; then
                    echo "$slot" > /sys/bus/pci/drivers/radeon/bind 2>/dev/null && printf "  $slot -> radeon\n"
                elif [ -d /sys/bus/pci/drivers/amdgpu ]; then
                    echo "$slot" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null && printf "  $slot -> amdgpu\n"
                fi
                ;;
            0x10de)  # NVIDIA
                if [ -d /sys/bus/pci/drivers/nouveau ]; then
                    echo "$slot" > /sys/bus/pci/drivers/nouveau/bind 2>/dev/null && printf "  $slot -> nouveau\n"
                fi
                ;;
            0x8086)  # Intel
                if [ -d /sys/bus/pci/drivers/i915 ]; then
                    echo "$slot" > /sys/bus/pci/drivers/i915/bind 2>/dev/null && printf "  $slot -> i915\n"
                fi
                ;;
        esac
    done
    
    sleep 1
    printf " ${GREEN}完了${RESET}\n"
}

# GPU情報を収集して表示
show_gpu_info() {
    printf "\n${BOLD}${CYAN}[GPU診断]${RESET}\n\n"
    
    # /sys/bus/pci/devices/ からGPUを検出（lspciより確実）
    gpu_count=0
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        # VGA (0x030000), 3D (0x030200), Display (0x038000)
        case "$class" in
            0x030000|0x030001|0x030002|0x030200|0x038000) ;;
            *) continue ;;
        esac
        
        gpu_count=$((gpu_count + 1))
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        device_id=$(cat "$dev/device" 2>/dev/null)
        pci_slot=$(basename "$dev")
        
        # GPU名を取得（ベンダー名 + デバイスID）
        case "$vendor" in
            0x10de) vendor_name="NVIDIA" ;;
            0x1002) vendor_name="AMD" ;;
            0x8086) vendor_name="Intel" ;;
            *) vendor_name="Unknown ($vendor)" ;;
        esac
        
        # lspciで詳細名を取得（可能なら）
        gpu_name=""
        if command -v lspci > /dev/null 2>&1; then
            pci_short=$(echo "$pci_slot" | sed 's/^0000://')
            gpu_name=$(lspci 2>/dev/null | grep "^$pci_short " | sed 's/.*[Cc]ontroller[^:]*: //')
        fi
        [ -z "$gpu_name" ] && gpu_name="${vendor_name} GPU ($device_id)"
        
        # ドライバ情報
        driver=""
        [ -L "$dev/driver" ] && driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)")
        
        printf "${BOLD}GPU %d: %s${RESET}\n" "$gpu_count" "$gpu_name"
        printf "  スロット: %s\n" "$pci_slot"
        printf "  ベンダー: %s デバイス: %s\n" "$vendor" "$device_id"
        
        if [ -n "$driver" ]; then
            printf "  ドライバ: ${GREEN}%s${RESET}\n" "$driver"
            printf "  ステータス: ${GREEN}✓ 認識OK${RESET}\n"
        else
            printf "  ドライバ: ${RED}未ロード${RESET}\n"
            printf "  ステータス: ${RED}✗ ドライバ未バインド${RESET}\n"
        fi
        printf "\n"
    done
    
    if [ "$gpu_count" -eq 0 ]; then
        printf "  ${RED}GPUが検出されませんでした${RESET}\n\n"
    fi
    
    # DRMデバイス確認
    printf "${BOLD}[DRMデバイス]${RESET}\n"
    printf "\n"
    
    if ls /dev/dri/card* >/dev/null 2>&1; then
        for card in /dev/dri/card*; do
            card_num=$(basename "$card")
            # DRMのドライバ名を取得
            drm_driver=""
            if [ -L "/sys/class/drm/$card_num/device/driver" ]; then
                drm_driver=$(basename "$(readlink /sys/class/drm/$card_num/device/driver 2>/dev/null)")
            fi
            if [ -n "$drm_driver" ]; then
                printf "  %s: ${GREEN}%s${RESET}\n" "$card" "$drm_driver"
            else
                printf "  %s: ${GREEN}存在${RESET}\n" "$card"
            fi
        done
        printf "\n${GREEN}✓ グラフィックス出力可能${RESET}\n"
    else
        printf "  ${RED}DRMデバイスなし${RESET}\n"
        printf "\n${RED}✗ グラフィックス出力不可${RESET}\n"
        
        # デバッグ: モジュールロードエラー
        if [ -f /tmp/gpu_debug.log ]; then
            printf "\n${YELLOW}[DEBUG] モジュールロードエラー:${RESET}\n"
            cat /tmp/gpu_debug.log | tail -15
        fi
        
        # デバッグ: dmesgからGPUエラー確認
        printf "\n${YELLOW}[DEBUG] dmesg (radeon/drm):${RESET}\n"
        dmesg 2>/dev/null | grep -iE 'radeon|amdgpu|drm|firmware' | tail -8
    fi
    
    printf "\n----------------------------------------\n"
    printf "q でトップに戻る\n"
}

# メイン処理
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
load_gpu_drivers | "$FBPRINT" "$FONT" "$FB"
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
show_gpu_info | "$FBPRINT" "$FONT" "$FB"

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
    esac
done
