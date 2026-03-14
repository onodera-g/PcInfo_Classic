#!/bin/bash
# build_alpine.sh - PCInfo Classic ビルドスクリプト (Alpine Linux版)
#
# GPUドライバの互換性問題を解決するため、Alpine Linuxをベースに使用
# メモリ診断機能と文字表示は変更なし

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"
WORK_DIR="$SCRIPT_DIR/work_alpine"
OUTPUT_DIR="$SCRIPT_DIR"

# Alpine Linux バージョン
ALPINE_VERSION="3.19"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# 出力ファイル名
ISO_NAME="pcinfo-classic.iso"
IMG_NAME="pcinfo-classic.img"

log() {
    echo "[build] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# 依存ツールチェック
check_dependencies() {
    local deps="wget tar gzip cpio grub-mkrescue xorriso mtools mkfs.fat mkfs.ext4 losetup"
    for dep in $deps; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            error "Required tool not found: $dep"
        fi
    done
}

# Alpine minirootfs ダウンロード
download_alpine() {
    local rootfs_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
    local rootfs_file="$WORK_DIR/alpine-minirootfs.tar.gz"
    
    if [ ! -f "$rootfs_file" ]; then
        log "Downloading Alpine Linux minirootfs..."
        wget -q -O "$rootfs_file" "$rootfs_url" || error "Failed to download Alpine minirootfs"
    fi
    echo "$rootfs_file"
}

# Alpine rootfs 構築
build_rootfs() {
    local rootfs_tar="$1"
    local rootfs_dir="$WORK_DIR/rootfs"
    
    log "Building Alpine rootfs..."
    
    rm -rf "$rootfs_dir"
    mkdir -p "$rootfs_dir"
    
    # minirootfs 展開
    tar -xzf "$rootfs_tar" -C "$rootfs_dir"
    
    # APK リポジトリ設定
    mkdir -p "$rootfs_dir/etc/apk"
    cat > "$rootfs_dir/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
    
    # DNS設定（apk用）
    cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf" 2>/dev/null || echo "nameserver 8.8.8.8" > "$rootfs_dir/etc/resolv.conf"
    
    # chroot環境でパッケージインストール
    log "Installing packages via apk..."
    
    # 必要なマウント
    mount --bind /dev "$rootfs_dir/dev" || true
    mount --bind /proc "$rootfs_dir/proc" || true
    mount --bind /sys "$rootfs_dir/sys" || true
    
    # パッケージインストール
    chroot "$rootfs_dir" /sbin/apk update
    chroot "$rootfs_dir" /sbin/apk add --no-cache \
        linux-lts \
        linux-firmware-amdgpu \
        linux-firmware-radeon \
        linux-firmware-nvidia \
        linux-firmware-i915 \
        linux-firmware-intel \
        pciutils \
        util-linux \
        eudev \
        kbd \
        kbd-misc \
        busybox \
        kmod \
        || error "Failed to install packages"
    
    # アンマウント
    umount "$rootfs_dir/sys" 2>/dev/null || true
    umount "$rootfs_dir/proc" 2>/dev/null || true
    umount "$rootfs_dir/dev" 2>/dev/null || true
    
    echo "$rootfs_dir"
}

# initramfs 作成
build_initramfs() {
    local rootfs_dir="$1"
    local initrd_dir="$WORK_DIR/initrd"
    local initrd_file="$WORK_DIR/initrd.gz"
    
    log "Building initramfs..."
    
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    
    # 基本ディレクトリ構造
    mkdir -p "$initrd_dir"/{bin,sbin,etc,proc,sys,dev,tmp,run,opt,lib,lib64,usr/bin,usr/sbin,usr/lib,mnt,root}
    mkdir -p "$initrd_dir/lib/modules"
    mkdir -p "$initrd_dir/lib/firmware"
    
    # busybox
    cp "$rootfs_dir/bin/busybox" "$initrd_dir/bin/"
    chroot "$initrd_dir" /bin/busybox --install -s /bin 2>/dev/null || \
        for cmd in sh ash cat cp dd df echo env grep head ln ls mkdir mknod mount mv rm rmdir sed sleep tail tar touch umount uname; do
            ln -sf busybox "$initrd_dir/bin/$cmd"
        done
    
    # 必要なバイナリをコピー
    for bin in lspci setfont kmod insmod modprobe lsmod depmod; do
        if [ -f "$rootfs_dir/usr/bin/$bin" ]; then
            cp "$rootfs_dir/usr/bin/$bin" "$initrd_dir/usr/bin/"
        elif [ -f "$rootfs_dir/sbin/$bin" ]; then
            cp "$rootfs_dir/sbin/$bin" "$initrd_dir/sbin/"
        elif [ -f "$rootfs_dir/bin/$bin" ]; then
            cp "$rootfs_dir/bin/$bin" "$initrd_dir/bin/"
        fi
    done
    
    # シンボリックリンク作成
    ln -sf /usr/bin/lspci "$initrd_dir/bin/lspci" 2>/dev/null || true
    ln -sf /sbin/kmod "$initrd_dir/sbin/insmod" 2>/dev/null || true
    ln -sf /sbin/kmod "$initrd_dir/sbin/modprobe" 2>/dev/null || true
    ln -sf /sbin/kmod "$initrd_dir/sbin/lsmod" 2>/dev/null || true
    ln -sf /sbin/kmod "$initrd_dir/sbin/depmod" 2>/dev/null || true
    
    # ライブラリをコピー
    log "Copying libraries..."
    copy_libs "$rootfs_dir" "$initrd_dir"
    
    # カーネルモジュールをコピー
    log "Copying kernel modules..."
    local kernel_ver=$(ls "$rootfs_dir/lib/modules" | head -1)
    if [ -n "$kernel_ver" ] && [ -d "$rootfs_dir/lib/modules/$kernel_ver" ]; then
        cp -r "$rootfs_dir/lib/modules/$kernel_ver" "$initrd_dir/lib/modules/"
        log "Kernel version: $kernel_ver"
    fi
    
    # ファームウェアをコピー（GPUのみ）
    log "Copying GPU firmware..."
    for fw_dir in amdgpu radeon nvidia i915; do
        if [ -d "$rootfs_dir/lib/firmware/$fw_dir" ]; then
            mkdir -p "$initrd_dir/lib/firmware/$fw_dir"
            cp -r "$rootfs_dir/lib/firmware/$fw_dir"/* "$initrd_dir/lib/firmware/$fw_dir/" 2>/dev/null || true
        fi
    done
    
    # PCInfo スクリプトをコピー（変更なし）
    log "Installing PCInfo scripts (unchanged)..."
    cp "$SRC_DIR/common.sh" "$initrd_dir/opt/"
    cp "$SRC_DIR/menu_main.sh" "$initrd_dir/opt/"
    cp "$SRC_DIR/menu_memtest.sh" "$initrd_dir/opt/"
    cp "$SRC_DIR/pcinfo.sh" "$initrd_dir/opt/"
    chmod +x "$initrd_dir/opt/"*.sh
    
    # GPU診断スクリプト（Alpine用に微調整）
    install_gpu_script "$initrd_dir" "$kernel_ver"
    
    # GPU ID データベース
    if [ -f "$SRC_DIR/amd_gpu.tsv" ]; then
        cp "$SRC_DIR/amd_gpu.tsv" "$initrd_dir/opt/"
    fi
    if [ -f "$SRC_DIR/nvidia_gpu.tsv" ]; then
        cp "$SRC_DIR/nvidia_gpu.tsv" "$initrd_dir/opt/"
    fi
    
    # フォント（変更なし）
    log "Installing font (unchanged)..."
    if [ -f "$SRC_DIR/unifont_ja.psf.gz" ]; then
        mkdir -p "$initrd_dir/usr/share/consolefonts"
        cp "$SRC_DIR/unifont_ja.psf.gz" "$initrd_dir/usr/share/consolefonts/"
    fi
    
    # fbprint ビルド（変更なし）
    log "Building fbprint (unchanged)..."
    build_fbprint "$initrd_dir"
    
    # meminfo ビルド
    build_meminfo "$initrd_dir"
    
    # init スクリプト
    create_init "$initrd_dir"
    
    # autologin
    create_autologin "$initrd_dir"
    
    # initramfs 作成
    log "Creating initramfs..."
    (cd "$initrd_dir" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_file")
    
    echo "$initrd_file"
}

# ライブラリコピー
copy_libs() {
    local src="$1"
    local dst="$2"
    
    # musl libc
    if [ -f "$src/lib/ld-musl-x86_64.so.1" ]; then
        cp "$src/lib/ld-musl-x86_64.so.1" "$dst/lib/"
        ln -sf ld-musl-x86_64.so.1 "$dst/lib/libc.musl-x86_64.so.1"
    fi
    
    # 必要なライブラリ
    for lib in libz.so libpci.so libkmod.so liblzma.so libzstd.so libcrypto.so libssl.so; do
        for f in "$src/lib/"${lib}* "$src/usr/lib/"${lib}*; do
            [ -f "$f" ] && cp "$f" "$dst/lib/" 2>/dev/null
        done
    done
}

# fbprint ビルド（TCL版と同一）
build_fbprint() {
    local initrd_dir="$1"
    
    if [ -f "$SRC_DIR/fbprint.c" ]; then
        gcc -O2 -static -o "$initrd_dir/opt/fbprint" "$SRC_DIR/fbprint.c" 2>/dev/null || \
        gcc -O2 -o "$initrd_dir/opt/fbprint" "$SRC_DIR/fbprint.c"
        chmod +x "$initrd_dir/opt/fbprint"
        log "fbprint built"
    fi
}

# meminfo ビルド（TCL版と同一）
build_meminfo() {
    local initrd_dir="$1"
    
    if [ -f "$SRC_DIR/meminfo.c" ]; then
        gcc -O2 -static -o "$initrd_dir/opt/meminfo" "$SRC_DIR/meminfo.c" 2>/dev/null || \
        gcc -O2 -o "$initrd_dir/opt/meminfo" "$SRC_DIR/meminfo.c"
        chmod +x "$initrd_dir/opt/meminfo"
        log "meminfo built"
    fi
}

# GPU診断スクリプト（Alpine用）
install_gpu_script() {
    local initrd_dir="$1"
    local kernel_ver="$2"
    
    # menu_gpu.sh をコピーして、モジュールパスを調整
    cp "$SRC_DIR/menu_gpu.sh" "$initrd_dir/opt/"
    
    # Alpineではモジュールは /lib/modules/ に標準配置されているため、
    # GPU_MODULES_DIR を /lib/modules/$kernel_ver に設定
    sed -i "s|GPU_MODULES_DIR=.*|GPU_MODULES_DIR=\"/lib/modules\"|" "$initrd_dir/opt/menu_gpu.sh"
    
    # Alpineではmodprobeが使える（カーネルとモジュールが同一ビルド）
    # load_module関数をmodprobe使用に簡略化
    cat > "$initrd_dir/opt/menu_gpu.sh" << 'GPUSCRIPT'
#!/bin/sh
# menu_gpu.sh - GPUテスト画面 (Alpine Linux版)

. /opt/common.sh

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# GPUドライバをロード（modprobe使用 - Alpineでは互換性保証）
load_gpu_drivers() {
    printf "\n${BOLD}${CYAN}[GPU診断]${RESET}\n\n"
    printf "GPUドライバをロード中...\n\n"
    
    # AMD (radeon)
    printf "  radeon (AMD旧世代)... "
    if modprobe radeon 2>/dev/null; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # AMD (amdgpu)
    printf "  amdgpu (AMD新世代)... "
    if modprobe amdgpu 2>/dev/null; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # NVIDIA (nouveau)
    printf "  nouveau (NVIDIA)... "
    if modprobe nouveau 2>/dev/null; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    # Intel (i915)
    printf "  i915 (Intel)... "
    if modprobe i915 2>/dev/null; then
        printf "${GREEN}OK${RESET}\n"
    else
        printf "${RED}スキップ${RESET}\n"
    fi
    
    printf "\nデバイス初期化待機中..."
    sleep 3
    printf " ${GREEN}完了${RESET}\n"
}

# GPU情報を収集して表示
show_gpu_info() {
    printf "\n${BOLD}${CYAN}[GPU診断]${RESET}\n\n"
    
    # /sys/bus/pci/devices/ からGPUを検出
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
        device_id=$(cat "$dev/device" 2>/dev/null)
        pci_slot=$(basename "$dev")
        
        case "$vendor" in
            0x10de) vendor_name="NVIDIA" ;;
            0x1002) vendor_name="AMD" ;;
            0x8086) vendor_name="Intel" ;;
            *) vendor_name="Unknown ($vendor)" ;;
        esac
        
        gpu_name=""
        if command -v lspci > /dev/null 2>&1; then
            pci_short=$(echo "$pci_slot" | sed 's/^0000://')
            gpu_name=$(lspci 2>/dev/null | grep "^$pci_short " | sed 's/.*[Cc]ontroller[^:]*: //')
        fi
        [ -z "$gpu_name" ] && gpu_name="${vendor_name} GPU ($device_id)"
        
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
    
    if ls /dev/dri/card* >/dev/null 2>&1; then
        for card in /dev/dri/card*; do
            card_num=$(basename "$card")
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
    read_key key
    case "$key" in
        q|Q) break ;;
    esac
done
GPUSCRIPT
    chmod +x "$initrd_dir/opt/menu_gpu.sh"
}

# init スクリプト作成
create_init() {
    local initrd_dir="$1"
    
    cat > "$initrd_dir/init" << 'INIT_EOF'
#!/bin/sh
# PCInfo Classic init (Alpine Linux版)

# マウント
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts none /dev/pts
mount -t tmpfs none /dev/shm
mount -t tmpfs none /tmp
mount -t tmpfs none /run

# モジュール依存関係を構築
depmod -a 2>/dev/null

# udev起動（利用可能な場合）
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon 2>/dev/null
    udevadm trigger 2>/dev/null
    udevadm settle 2>/dev/null
else
    # 手動でデバイスノード作成
    mknod -m 660 /dev/fb0 c 29 0 2>/dev/null
    mknod -m 666 /dev/tty0 c 4 0 2>/dev/null
    mknod -m 666 /dev/tty1 c 4 1 2>/dev/null
    mknod -m 666 /dev/console c 5 1 2>/dev/null
    mknod -m 666 /dev/null c 1 3 2>/dev/null
fi

# ホスト名
hostname pcinfo

# フォント設定（変更なし）
if [ -f /usr/share/consolefonts/unifont_ja.psf.gz ]; then
    setfont /usr/share/consolefonts/unifont_ja.psf.gz 2>/dev/null
fi

# getty起動
exec /sbin/getty -n -l /sbin/autologin 0 /dev/tty1
INIT_EOF
    chmod +x "$initrd_dir/init"
}

# autologin 作成
create_autologin() {
    local initrd_dir="$1"
    
    cat > "$initrd_dir/sbin/autologin" << 'AUTOLOGIN_EOF'
#!/bin/sh
export HOME=/root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt
export TERM=linux
export LANG=ja_JP.UTF-8
cd /root
exec /opt/menu_main.sh
AUTOLOGIN_EOF
    chmod +x "$initrd_dir/sbin/autologin"
}

# USB イメージ作成（TCL版と同一構造）
create_usb_image() {
    local kernel="$1"
    local initrd="$2"
    local img_file="$OUTPUT_DIR/$IMG_NAME"
    
    log "Building USB image..."
    
    # イメージサイズ計算
    local kernel_size=$(stat -c%s "$kernel" 2>/dev/null || echo 10000000)
    local initrd_size=$(stat -c%s "$initrd" 2>/dev/null || echo 50000000)
    local memtest_size=500000
    local total_size=$(( (kernel_size + initrd_size + memtest_size) * 2 + 50000000 ))
    local img_size_mb=$(( total_size / 1024 / 1024 + 20 ))
    
    [ $img_size_mb -lt 100 ] && img_size_mb=100
    
    log "Creating ${img_size_mb}MB USB image..."
    
    rm -f "$img_file"
    dd if=/dev/zero of="$img_file" bs=1M count=$img_size_mb status=none
    
    # パーティション作成
    parted -s "$img_file" mklabel gpt
    parted -s "$img_file" mkpart EFI fat32 1MiB 32MiB
    parted -s "$img_file" set 1 esp on
    parted -s "$img_file" mkpart DATA ext4 32MiB 100%
    
    # ループデバイス設定
    local loop=$(losetup -f --show "$img_file")
    partprobe "$loop" 2>/dev/null || sleep 1
    
    local efi_part="${loop}p1"
    local data_part="${loop}p2"
    
    # パーティションが見えない場合の対処
    if [ ! -b "$efi_part" ]; then
        losetup -d "$loop"
        loop=$(losetup -f --show -P "$img_file")
        efi_part="${loop}p1"
        data_part="${loop}p2"
    fi
    
    # フォーマット
    mkfs.fat -F32 "$efi_part"
    mkfs.ext4 -q "$data_part"
    
    # マウント
    local efi_mnt="$WORK_DIR/mnt_efi"
    local data_mnt="$WORK_DIR/mnt_data"
    mkdir -p "$efi_mnt" "$data_mnt"
    mount "$efi_part" "$efi_mnt"
    mount "$data_part" "$data_mnt"
    
    # EFI パーティション設定
    mkdir -p "$efi_mnt/EFI/BOOT"
    grub-mkimage -O x86_64-efi -o "$efi_mnt/EFI/BOOT/BOOTX64.EFI" \
        -p /EFI/BOOT \
        part_gpt part_msdos fat ext2 normal linux boot configfile \
        loopback chain efifwsetup efi_gop efi_uga ls search search_label \
        search_fs_uuid search_fs_file gfxterm gfxterm_background gfxterm_menu \
        test all_video loadenv
    
    # GRUB設定（TCL版と同一）
    cat > "$efi_mnt/EFI/BOOT/grub.cfg" << 'GRUB_EOF'
set timeout=0
set default="pcinfo"
load_env

if [ "${saved_entry}" ]; then
    set default="${saved_entry}"
fi

menuentry "PCInfo Classic" --id pcinfo {
    linux /boot/vmlinuz vga=794 quiet
    initrd /boot/initrd.gz
}

menuentry "Memtest86+" --id memtest {
    set saved_entry=pcinfo
    save_env saved_entry
    chainloader /EFI/BOOT/memtest.efi
}
GRUB_EOF
    
    # grubenv 初期化
    grub-editenv "$efi_mnt/EFI/BOOT/grubenv" create
    grub-editenv "$efi_mnt/EFI/BOOT/grubenv" set saved_entry=pcinfo
    
    # memtest86+ コピー
    if [ -f "$WORK_DIR/memtest.efi" ]; then
        cp "$WORK_DIR/memtest.efi" "$efi_mnt/EFI/BOOT/"
    elif [ -f "$SCRIPT_DIR/memtest.efi" ]; then
        cp "$SCRIPT_DIR/memtest.efi" "$efi_mnt/EFI/BOOT/"
    fi
    
    # DATA パーティション
    mkdir -p "$data_mnt/boot"
    cp "$kernel" "$data_mnt/boot/vmlinuz"
    cp "$initrd" "$data_mnt/boot/initrd.gz"
    
    # アンマウント
    umount "$efi_mnt"
    umount "$data_mnt"
    losetup -d "$loop"
    
    log "USB image created: $img_file"
    ls -lh "$img_file"
}

# memtest86+ ダウンロード
download_memtest() {
    local memtest_file="$WORK_DIR/memtest.efi"
    
    if [ ! -f "$memtest_file" ]; then
        log "Downloading memtest86+..."
        local memtest_url="https://memtest.org/download/v7.00/mt86plus_7.00_64.grub.efi"
        wget -q -O "$memtest_file" "$memtest_url" || log "WARNING: memtest86+ download failed"
    fi
}

# メイン処理
main() {
    log "PCInfo Classic Build Script (Alpine Linux版)"
    log "=============================================="
    
    check_dependencies
    
    mkdir -p "$WORK_DIR"
    
    # Alpine rootfs ダウンロード・構築
    local rootfs_tar=$(download_alpine)
    local rootfs_dir=$(build_rootfs "$rootfs_tar")
    
    # カーネル取得
    local kernel_ver=$(ls "$rootfs_dir/lib/modules" | head -1)
    local kernel="$rootfs_dir/boot/vmlinuz-lts"
    [ ! -f "$kernel" ] && kernel=$(ls "$rootfs_dir/boot/vmlinuz"* 2>/dev/null | head -1)
    
    if [ ! -f "$kernel" ]; then
        error "Kernel not found in Alpine rootfs"
    fi
    
    log "Using kernel: $kernel (version: $kernel_ver)"
    
    # initramfs 作成
    local initrd=$(build_initramfs "$rootfs_dir")
    
    # memtest86+ ダウンロード
    download_memtest
    
    # USB イメージ作成
    create_usb_image "$kernel" "$initrd"
    
    log ""
    log "=============================================="
    log "  Build Complete! (Alpine Linux版)"
    log "=============================================="
    log ""
    log "  Output: $OUTPUT_DIR/$IMG_NAME"
    log ""
}

main "$@"
