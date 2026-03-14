#!/bin/bash
# build.sh - Build a custom PCInfo Classic ISO with pcinfo.sh
# Uses TCL initrd + Debian netboot kernel (vesafb+fbcon built-in for BIOS framebuffer)
# Output: build/pcinfo-classic.iso

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_SCRIPT="$REPO_ROOT/src/pcinfo.sh"
SRC_FONT="$REPO_ROOT/src/unifont_ja.psf.gz"
WORK_DIR="$SCRIPT_DIR/work"
OUT_ISO="$SCRIPT_DIR/pcinfo-classic.iso"

# Tiny Core Linux (initrd + base system)
TCL_VERSION="15.0"
TCL_ISO_URL="http://tinycorelinux.net/15.x/x86_64/release/CorePure64-${TCL_VERSION}.iso"
TCL_ISO="$WORK_DIR/CorePure64.iso"

# Debian bookworm netboot kernel (vesafb=y + fbcon=y built-in)
# vga=794 -> vesafb creates /dev/fb0 immediately at boot, no modules needed
DEBIAN_VMLINUZ_URL="https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux"
DEBIAN_VMLINUZ="$WORK_DIR/vmlinuz-debian"

# ============================================================
log() { echo "[build] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

check_deps() {
    for cmd in wget xorriso cpio gzip find; do
        command -v "$cmd" > /dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

# ============================================================
# Step 1: Download ISOs
# ============================================================
download_iso() {
    mkdir -p "$WORK_DIR"
    if [ -f "$TCL_ISO" ]; then
        log "TCL ISO already downloaded: $TCL_ISO"
    else
        log "Downloading Tiny Core Linux ${TCL_VERSION} ..."
        wget -q --show-progress -O "$TCL_ISO" "$TCL_ISO_URL" \
            || die "Failed to download TCL ISO"
        log "TCL download complete."
    fi

    if [ -f "$DEBIAN_VMLINUZ" ]; then
        log "Debian kernel already downloaded: $DEBIAN_VMLINUZ"
    else
        log "Downloading Debian bookworm netboot kernel (vesafb+fbcon built-in) ..."
        wget -q --show-progress -O "$DEBIAN_VMLINUZ" "$DEBIAN_VMLINUZ_URL" \
            || die "Failed to download Debian kernel"
        log "Debian kernel downloaded ($(du -sh "$DEBIAN_VMLINUZ" | cut -f1))"
    fi
}

# ============================================================
# Step 2: Extract TCL ISO
# ============================================================
extract_iso() {
    ISO_EXTRACT="$WORK_DIR/iso_extract"
    rm -rf "$ISO_EXTRACT"
    mkdir -p "$ISO_EXTRACT"
    log "Extracting TCL ISO contents ..."
    xorriso -osirrox on -indev "$TCL_ISO" -extract / "$ISO_EXTRACT" 2>/dev/null \
        || die "Failed to extract ISO"

    # Locate initrd (CorePure64 uses boot/corepure64.gz or boot/core64.gz)
    INITRD_PATH=""
    for candidate in \
        "$ISO_EXTRACT/boot/corepure64.gz" \
        "$ISO_EXTRACT/boot/core64.gz" \
        "$ISO_EXTRACT/boot/core.gz"; do
        if [ -f "$candidate" ]; then
            INITRD_PATH="$candidate"
            break
        fi
    done
    [ -n "$INITRD_PATH" ] || die "Could not find initrd in extracted ISO"
    log "Found initrd: $INITRD_PATH"
    chmod -R u+w "$ISO_EXTRACT"
}

# ============================================================
# Step 3: Unpack initrd, inject pcinfo.sh, repack
# ============================================================
patch_initrd() {
    INITRD_WORK="$WORK_DIR/initrd_work"
    rm -rf "$INITRD_WORK"
    mkdir -p "$INITRD_WORK"

    log "Unpacking initrd ..."
    cd "$INITRD_WORK"
    zcat "$INITRD_PATH" | cpio -idm --quiet 2>/dev/null \
        || die "Failed to unpack initrd"

    log "Installing pcinfo.sh into /opt/ ..."
    cp "$SRC_SCRIPT" "$INITRD_WORK/opt/pcinfo.sh"
    chmod 755 "$INITRD_WORK/opt/pcinfo.sh"

    log "Installing menu scripts into /opt/ ..."
    for script in common.sh menu.sh menu_pcinfo.sh menu_memtest.sh menu_gpu.sh menu_storage.sh; do
        cp "$REPO_ROOT/src/$script" "$INITRD_WORK/opt/$script"
        chmod 755 "$INITRD_WORK/opt/$script"
    done

    log "Installing GPU ID databases into /opt/ ..."
    cp "$REPO_ROOT/src/pci_gpu.ids"  "$INITRD_WORK/opt/pci_gpu.ids"
    cp "$REPO_ROOT/src/vram_gpu.ids" "$INITRD_WORK/opt/vram_gpu.ids"

    log "Installing font (unifont_ja.psf.gz: PSF2 16x16 CJK) ..."
    mkdir -p "$INITRD_WORK/usr/share/consolefonts"
    cp "$SRC_FONT" "$INITRD_WORK/usr/share/consolefonts/unifont_ja.psf.gz"

    # Build fbprint: direct framebuffer renderer (bypasses setfont/KDFONTOP limitations)
    log "Building fbprint (framebuffer text renderer) ..."
    FBPRINT_SRC="$REPO_ROOT/src/fbprint.c"
    FBPRINT_BIN="$WORK_DIR/fbprint"
    if [ -f "$FBPRINT_SRC" ]; then
        if command -v gcc > /dev/null 2>&1 && command -v ar > /dev/null 2>&1; then
            gcc -O2 -static -o "$FBPRINT_BIN" "$FBPRINT_SRC" -lz 2>/dev/null \
                && log "fbprint built: $(du -sh "$FBPRINT_BIN" | cut -f1)" \
                || log "WARNING: fbprint build failed (will skip if already cached)"
        fi
    fi
    if [ -f "$FBPRINT_BIN" ]; then
        mkdir -p "$INITRD_WORK/usr/local/bin"
        cp "$FBPRINT_BIN" "$INITRD_WORK/usr/local/bin/fbprint"
        chmod 755 "$INITRD_WORK/usr/local/bin/fbprint"
        log "fbprint installed"
    else
        log "WARNING: fbprint not available"
    fi

    # meminfo: SMBIOS Type 17を直接パース（dmidecode不要、root不要）
    MEMINFO_SRC="$REPO_ROOT/src/meminfo.c"
    MEMINFO_BIN="$WORK_DIR/meminfo"
    if [ -f "$MEMINFO_SRC" ]; then
        if command -v gcc > /dev/null 2>&1; then
            gcc -O2 -static -o "$MEMINFO_BIN" "$MEMINFO_SRC" 2>/dev/null \
                && log "meminfo built: $(du -sh "$MEMINFO_BIN" | cut -f1)" \
                || log "WARNING: meminfo build failed"
        fi
    fi
    if [ -f "$MEMINFO_BIN" ]; then
        mkdir -p "$INITRD_WORK/usr/local/bin"
        cp "$MEMINFO_BIN" "$INITRD_WORK/usr/local/bin/meminfo"
        chmod 755 "$INITRD_WORK/usr/local/bin/meminfo"
        log "meminfo installed"
    else
        log "WARNING: meminfo not available"
    fi

    # memtester: ユーザー空間メモリテストツール
    MEMTESTER_URL="https://pyropus.ca./software/memtester/old-versions/memtester-4.6.0.tar.gz"
    MEMTESTER_BIN="$WORK_DIR/memtester"
    if [ ! -f "$MEMTESTER_BIN" ]; then
        log "Building memtester (user-space memory tester) ..."
        MEMTESTER_TAR="$WORK_DIR/memtester.tar.gz"
        if [ ! -f "$MEMTESTER_TAR" ]; then
            wget -q -O "$MEMTESTER_TAR" "$MEMTESTER_URL" || log "WARNING: memtester download failed"
        fi
        if [ -f "$MEMTESTER_TAR" ]; then
            MEMTESTER_SRC_DIR="$WORK_DIR/memtester-4.6.0"
            rm -rf "$MEMTESTER_SRC_DIR"
            tar xzf "$MEMTESTER_TAR" -C "$WORK_DIR"
            if [ -d "$MEMTESTER_SRC_DIR" ]; then
                echo 'cc -O2 -static' > "$MEMTESTER_SRC_DIR/conf-cc"
                echo 'cc -static' > "$MEMTESTER_SRC_DIR/conf-ld"
                make -C "$MEMTESTER_SRC_DIR" -j$(nproc) 2>/dev/null \
                    && cp "$MEMTESTER_SRC_DIR/memtester" "$MEMTESTER_BIN" \
                    && log "memtester built: $(du -sh "$MEMTESTER_BIN" | cut -f1)" \
                    || log "WARNING: memtester build failed"
            fi
        fi
    fi
    if [ -f "$MEMTESTER_BIN" ]; then
        mkdir -p "$INITRD_WORK/usr/local/bin"
        cp "$MEMTESTER_BIN" "$INITRD_WORK/usr/local/bin/memtester"
        chmod 755 "$INITRD_WORK/usr/local/bin/memtester"
        log "memtester installed"
    else
        log "WARNING: memtester not available"
    fi

    # kexec: カーネル/バイナリ切り替えツール（memtest86+起動用）
    KEXEC_URL="https://git.kernel.org/pub/scm/utils/kernel/kexec/kexec-tools.git/snapshot/kexec-tools-2.0.29.tar.gz"
    KEXEC_BIN="$WORK_DIR/kexec"
    if [ ! -f "$KEXEC_BIN" ]; then
        log "Building kexec (kernel execution tool) ..."
        KEXEC_TAR="$WORK_DIR/kexec-tools.tar.gz"
        if [ ! -f "$KEXEC_TAR" ]; then
            wget -q -O "$KEXEC_TAR" "$KEXEC_URL" || log "WARNING: kexec download failed"
        fi
        if [ -f "$KEXEC_TAR" ]; then
            KEXEC_SRC_DIR="$WORK_DIR/kexec-tools-2.0.29"
            rm -rf "$KEXEC_SRC_DIR"
            tar xzf "$KEXEC_TAR" -C "$WORK_DIR"
            if [ -d "$KEXEC_SRC_DIR" ]; then
                cd "$KEXEC_SRC_DIR"
                ./bootstrap >/dev/null 2>&1
                LDFLAGS="-static" ./configure --prefix=/tmp/kexec-install >/dev/null 2>&1
                make -j$(nproc) >/dev/null 2>&1 \
                    && cp build/sbin/kexec "$KEXEC_BIN" \
                    && log "kexec built: $(du -sh "$KEXEC_BIN" | cut -f1)" \
                    || log "WARNING: kexec build failed"
                cd "$REPO_ROOT"
            fi
        fi
    fi
    if [ -f "$KEXEC_BIN" ]; then
        mkdir -p "$INITRD_WORK/usr/local/bin"
        cp "$KEXEC_BIN" "$INITRD_WORK/usr/local/bin/kexec"
        chmod 755 "$INITRD_WORK/usr/local/bin/kexec"
        log "kexec installed"
    else
        log "WARNING: kexec not available"
    fi

    # memtest86+: スタンドアロンメモリテスト（kexecで起動）
    MEMTEST86_URL="https://memtest.org/download/v8.00/mt86plus_8.00.binaries.zip"
    MEMTEST86_BIN="$WORK_DIR/memtest86plus.bin"
    if [ ! -f "$MEMTEST86_BIN" ]; then
        log "Downloading memtest86+ ..."
        MEMTEST86_ZIP="$WORK_DIR/memtest86plus.zip"
        wget -q -O "$MEMTEST86_ZIP" "$MEMTEST86_URL" || log "WARNING: memtest86+ download failed"
        if [ -f "$MEMTEST86_ZIP" ]; then
            unzip -o -q "$MEMTEST86_ZIP" -d "$WORK_DIR" 2>/dev/null
            # x86_64 バイナリを使用
            if [ -f "$WORK_DIR/mt86p_800_x86_64" ]; then
                cp "$WORK_DIR/mt86p_800_x86_64" "$MEMTEST86_BIN"
                log "memtest86+ downloaded: $(du -sh "$MEMTEST86_BIN" | cut -f1)"
            fi
        fi
    fi
    if [ -f "$MEMTEST86_BIN" ]; then
        mkdir -p "$INITRD_WORK/boot"
        cp "$MEMTEST86_BIN" "$INITRD_WORK/boot/memtest86plus.bin"
        chmod 644 "$INITRD_WORK/boot/memtest86plus.bin"
        log "memtest86+ installed to /boot/"
    else
        log "WARNING: memtest86+ not available"
    fi

    # GPU kernel modules: graphics + nouveau from Tiny Core Linux
    # Store in /opt/gpu_modules/ instead of /lib/modules/ to prevent auto-loading
    TCL_TCZ_URL="http://tinycorelinux.net/15.x/x86_64/tcz"
    GPU_MODULES_DIR="$WORK_DIR/gpu_modules"
    if [ ! -d "$GPU_MODULES_DIR" ]; then
        mkdir -p "$GPU_MODULES_DIR"
        log "Downloading GPU kernel modules ..."
        # graphics-*.tcz contains: i915, radeon, amdgpu, drm
        wget -q -O "$GPU_MODULES_DIR/graphics.tcz" "$TCL_TCZ_URL/graphics-6.6.8-tinycore64.tcz" || log "WARNING: graphics.tcz download failed"
        # nouveau-*.tcz contains: nouveau
        wget -q -O "$GPU_MODULES_DIR/nouveau.tcz" "$TCL_TCZ_URL/nouveau-6.6.8-tinycore64.tcz" || log "WARNING: nouveau.tcz download failed"
    fi
    if [ -f "$GPU_MODULES_DIR/graphics.tcz" ]; then
        log "Installing GPU kernel modules (deferred load) ..."
        # .tcz is a squashfs image
        unsquashfs -f -d "$GPU_MODULES_DIR/graphics_extracted" "$GPU_MODULES_DIR/graphics.tcz" 2>/dev/null
        unsquashfs -f -d "$GPU_MODULES_DIR/nouveau_extracted" "$GPU_MODULES_DIR/nouveau.tcz" 2>/dev/null
        # Store modules in /opt/gpu_modules/ (NOT in /lib/modules/)
        mkdir -p "$INITRD_WORK/opt/gpu_modules"
        if [ -d "$GPU_MODULES_DIR/graphics_extracted/usr/local/lib/modules" ]; then
            cp -r "$GPU_MODULES_DIR/graphics_extracted/usr/local/lib/modules"/* "$INITRD_WORK/opt/gpu_modules/" 2>/dev/null
        fi
        if [ -d "$GPU_MODULES_DIR/nouveau_extracted/usr/local/lib/modules" ]; then
            cp -r "$GPU_MODULES_DIR/nouveau_extracted/usr/local/lib/modules"/* "$INITRD_WORK/opt/gpu_modules/" 2>/dev/null
        fi
        log "GPU kernel modules stored in /opt/gpu_modules/"
    else
        log "WARNING: GPU kernel modules not available"
    fi

    # GPU firmware: AMD (radeon/amdgpu), NVIDIA (nouveau), Intel (i915)
    FIRMWARE_DIR="$WORK_DIR/linux-firmware"
    if [ ! -d "$FIRMWARE_DIR" ]; then
        log "Downloading GPU firmware (linux-firmware) ..."
        git clone --depth 1 --filter=blob:none --sparse \
            https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
            "$FIRMWARE_DIR" 2>/dev/null || log "WARNING: firmware clone failed"
        if [ -d "$FIRMWARE_DIR" ]; then
            cd "$FIRMWARE_DIR"
            git sparse-checkout set amdgpu radeon nouveau i915 2>/dev/null
            cd "$REPO_ROOT"
        fi
    fi
    if [ -d "$FIRMWARE_DIR" ]; then
        log "Installing GPU firmware ..."
        mkdir -p "$INITRD_WORK/lib/firmware"
        # AMD
        [ -d "$FIRMWARE_DIR/amdgpu" ] && cp -r "$FIRMWARE_DIR/amdgpu" "$INITRD_WORK/lib/firmware/"
        [ -d "$FIRMWARE_DIR/radeon" ] && cp -r "$FIRMWARE_DIR/radeon" "$INITRD_WORK/lib/firmware/"
        # NVIDIA (nouveau)
        [ -d "$FIRMWARE_DIR/nouveau" ] && cp -r "$FIRMWARE_DIR/nouveau" "$INITRD_WORK/lib/firmware/"
        # Intel
        [ -d "$FIRMWARE_DIR/i915" ] && cp -r "$FIRMWARE_DIR/i915" "$INITRD_WORK/lib/firmware/"
        FW_SIZE=$(du -sh "$INITRD_WORK/lib/firmware" 2>/dev/null | cut -f1)
        log "GPU firmware installed: $FW_SIZE"
    else
        log "WARNING: GPU firmware not available"
    fi

    # bootlocal.sh (nothing to do - vesafb creates /dev/fb0 automatically with vga=794)
    cat > "$INITRD_WORK/opt/bootlocal.sh" << 'BOOTLOCAL_EOF'
#!/bin/sh
BOOTLOCAL_EOF
    chmod 755 "$INITRD_WORK/opt/bootlocal.sh"

    # autologin: 元の動作（login -f root 経由）に戻す
    cat > "$INITRD_WORK/sbin/autologin" << 'AUTOLOGIN_EOF'
#!/bin/busybox ash
if [ -f /var/log/autologin ] ; then
    exec /sbin/getty 38400 tty1
else
    touch /var/log/autologin
    exec login -f root
fi
AUTOLOGIN_EOF
    chmod 755 "$INITRD_WORK/sbin/autologin"

    # profile.d: menu.sh を呼び出すだけ
    mkdir -p "$INITRD_WORK/etc/profile.d"
    printf '#!/bin/sh\n/opt/menu.sh\n' > "$INITRD_WORK/etc/profile.d/pcinfo.sh"
    chmod 755 "$INITRD_WORK/etc/profile.d/pcinfo.sh"


    log "Repacking initrd ..."
    find . | cpio -o -H newc --quiet | gzip -1 > "$INITRD_PATH"
    cd "$REPO_ROOT"

    # Keep TCL original kernel: USB HID is built-in -> keyboard works
    # Debian netboot kernel lacks usbhid module in TCL initrd -> keyboard LED goes off
    log "Keeping TCL original kernel (USB HID built-in, vesafb built-in)"

    # Patch isolinux.cfg: enable vesafb framebuffer (vga=794 = 1024x768x16)
    # nodhcp: skip DHCP wait (TCL waits up to 60s for DHCP without this)
    ISOLINUX_CFG="$ISO_EXTRACT/boot/isolinux/isolinux.cfg"
    if [ -f "$ISOLINUX_CFG" ]; then
        sed -i 's/ vga=[0-9]*//' "$ISOLINUX_CFG"
        sed -i 's/ nodhcp//' "$ISOLINUX_CFG"
        sed -i 's/append loglevel=3/append loglevel=3 vga=794 nodhcp nozswap/' "$ISOLINUX_CFG"
        # memtest86+ エントリを追加
        if ! grep -q "memtest86plus" "$ISOLINUX_CFG"; then
            cat >> "$ISOLINUX_CFG" << 'ISOLINUX_MEMTEST'

LABEL memtest
    MENU LABEL Memtest86+ (Memory Test)
    KERNEL /boot/memtest86plus.bin
ISOLINUX_MEMTEST
        fi
        log "Patched isolinux.cfg with vga=794 nodhcp nozswap + memtest86+"
    fi
}

# ============================================================
# Step 4: Rebuild ISO (BIOS + UEFI dual boot, Ventoy compatible)
# ============================================================
rebuild_iso() {
    log "Rebuilding ISO with UEFI support ..."

    # Detect isolinux.bin
    ISOLINUX_BIN=""
    for candidate in \
        "$ISO_EXTRACT/boot/isolinux/isolinux.bin" \
        "$ISO_EXTRACT/isolinux/isolinux.bin"; do
        if [ -f "$candidate" ]; then
            ISOLINUX_BIN="$candidate"
            break
        fi
    done
    [ -n "$ISOLINUX_BIN" ] || die "Could not find isolinux.bin in extracted ISO"
    ISOLINUX_DIR=$(dirname "$ISOLINUX_BIN")
    ISOLINUX_RELDIR="${ISOLINUX_DIR#$ISO_EXTRACT/}"

    # --- Build USB Image (not ISO) ---
    # mtoolsを使用（コンテナ環境でも動作）
    # パーティション1: EFI System Partition (FAT32, 書き込み可能) - grubenv保存用
    # パーティション2: データパーティション (FAT32) - カーネル、initrd等
    
    log "Building USB image with writable EFI partition..."
    
    OUT_IMG="${OUT_ISO%.iso}.img"
    
    # サイズ計算: データ + EFI + 余裕
    DATA_SIZE=$(du -sm "$ISO_EXTRACT" | cut -f1)
    EFI_SIZE_MB=32   # EFI パーティション (GRUB + memtest86 + grubenv)
    TOTAL_SIZE_MB=$((DATA_SIZE + EFI_SIZE_MB + 16))  # 16MB余裕
    
    log "Creating ${TOTAL_SIZE_MB}MB USB image..."
    
    # 空のイメージ作成
    dd if=/dev/zero of="$OUT_IMG" bs=1M count="$TOTAL_SIZE_MB" status=none
    
    # GPTパーティションテーブル作成
    parted -s "$OUT_IMG" mklabel gpt
    parted -s "$OUT_IMG" mkpart ESP fat32 1MiB ${EFI_SIZE_MB}MiB
    parted -s "$OUT_IMG" set 1 esp on
    parted -s "$OUT_IMG" mkpart DATA fat32 ${EFI_SIZE_MB}MiB 100%
    
    # パーティションのオフセットを取得（セクタ単位、512バイト/セクタ）
    EFI_START_SEC=$(parted -s "$OUT_IMG" unit s print | grep "^ 1 " | awk '{print $2}' | tr -d 's')
    EFI_END_SEC=$(parted -s "$OUT_IMG" unit s print | grep "^ 1 " | awk '{print $3}' | tr -d 's')
    DATA_START_SEC=$(parted -s "$OUT_IMG" unit s print | grep "^ 2 " | awk '{print $2}' | tr -d 's')
    DATA_END_SEC=$(parted -s "$OUT_IMG" unit s print | grep "^ 2 " | awk '{print $3}' | tr -d 's')
    
    EFI_SIZE_SEC=$((EFI_END_SEC - EFI_START_SEC + 1))
    DATA_SIZE_SEC=$((DATA_END_SEC - DATA_START_SEC + 1))
    
    log "EFI partition: sectors $EFI_START_SEC-$EFI_END_SEC ($EFI_SIZE_SEC sectors)"
    log "DATA partition: sectors $DATA_START_SEC-$DATA_END_SEC ($DATA_SIZE_SEC sectors)"
    
    # 個別のFATイメージを作成してから結合
    EFI_PART="$WORK_DIR/efi_part.img"
    DATA_PART="$WORK_DIR/data_part.img"
    
    # EFIパーティションイメージ（FAT16を使用 - EFIは両方サポート）
    dd if=/dev/zero of="$EFI_PART" bs=512 count="$EFI_SIZE_SEC" status=none
    mformat -i "$EFI_PART" -v "EFI" ::
    
    # DATAパーティションイメージ（FAT16を使用）
    dd if=/dev/zero of="$DATA_PART" bs=512 count="$DATA_SIZE_SEC" status=none
    mformat -i "$DATA_PART" -v "PCINFO" ::
    
    # --- EFIパーティションの構築 ---
    mmd -i "$EFI_PART" ::/EFI
    mmd -i "$EFI_PART" ::/EFI/BOOT
    mmd -i "$EFI_PART" ::/boot
    mmd -i "$EFI_PART" ::/boot/grub
    
    # GRUB設定 (saved_entry対応)
    cat > /tmp/grub_embed.cfg << 'GRUB_EOF'
set gfxmode=1024x768,800x600,auto
set gfxpayload=keep
set timeout=0
set default=pcinfo

# grubenv を EFI パーティションから読み込み
search --set=efipart --file /boot/grub/grubenv
if [ -n "$efipart" ]; then
    set env_blk="($efipart)/boot/grub/grubenv"
    if load_env -f "$env_blk" saved_entry; then
        set default="$saved_entry"
    fi
fi

# データパーティションを探す
search --set=root --file /boot/vmlinuz64

menuentry "PcInfo Classic" --id pcinfo {
    search --set=efipart --file /boot/grub/grubenv
    set env_blk="($efipart)/boot/grub/grubenv"
    set saved_entry=pcinfo
    save_env -f "$env_blk" saved_entry
    linux /boot/vmlinuz64 loglevel=3 quiet nomodeset=0 vga=794 nodhcp nozswap
    initrd /boot/corepure64.gz
}

menuentry "Memtest86+ (Memory Test)" --id memtest {
    search --set=efipart --file /boot/grub/grubenv
    set env_blk="($efipart)/boot/grub/grubenv"
    set saved_entry=pcinfo
    save_env -f "$env_blk" saved_entry
    chainloader ($efipart)/EFI/BOOT/memtest86.efi
}
GRUB_EOF

    # GRUB EFI バイナリ作成
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="/tmp/bootx64.efi" \
        --modules="part_gpt part_msdos fat normal echo all_video gfxterm test search search_fs_file search_label chain loadenv" \
        "boot/grub/grub.cfg=/tmp/grub_embed.cfg" 2>/dev/null \
    || die "Failed to build GRUB EFI"
    
    mcopy -i "$EFI_PART" "/tmp/bootx64.efi" ::/EFI/BOOT/
    log "GRUB EFI bootloader created"
    
    # memtest86+ EFI
    if [ -f "$WORK_DIR/memtest86plus.bin" ]; then
        mcopy -i "$EFI_PART" "$WORK_DIR/memtest86plus.bin" ::/EFI/BOOT/memtest86.efi
        log "memtest86+ copied to EFI partition"
    fi
    
    # grubenv 初期化 (saved_entry=pcinfo)
    grub-editenv /tmp/grubenv create
    grub-editenv /tmp/grubenv set saved_entry=pcinfo
    mcopy -i "$EFI_PART" /tmp/grubenv ::/boot/grub/
    log "grubenv initialized with saved_entry=pcinfo"
    
    # --- データパーティションの構築 ---
    mmd -i "$DATA_PART" ::/boot
    mcopy -i "$DATA_PART" "$ISO_EXTRACT/boot/vmlinuz64" ::/boot/
    mcopy -i "$DATA_PART" "$ISO_EXTRACT/boot/corepure64.gz" ::/boot/
    log "Boot files copied to data partition"
    
    # パーティションイメージを結合
    dd if="$EFI_PART" of="$OUT_IMG" bs=512 seek="$EFI_START_SEC" conv=notrunc status=none
    dd if="$DATA_PART" of="$OUT_IMG" bs=512 seek="$DATA_START_SEC" conv=notrunc status=none
    
    # 一時ファイル削除
    rm -f "$EFI_PART" "$DATA_PART" /tmp/bootx64.efi /tmp/grubenv
    
    log "USB image created: $OUT_IMG"
    ls -lh "$OUT_IMG"
    
    # ISOも作成（互換性のため、ただしmemtest86+自動起動は非対応）
    log "Also creating ISO for compatibility (memtest86+ requires manual selection)..."
    
    # GRUB EFI for ISO (読み取り専用なのでsaved_entry無し)
    cat > /tmp/grub_iso.cfg << 'GRUB_EOF'
set gfxmode=1024x768,800x600,auto
set gfxpayload=keep
set timeout=0
set default=0

search --set=root --file /boot/vmlinuz64

menuentry "PcInfo Classic" {
    linux /boot/vmlinuz64 loglevel=3 quiet nomodeset=0 vga=794 nodhcp nozswap
    initrd /boot/corepure64.gz
}

menuentry "Memtest86+ (Memory Test)" {
    search --set=root --file /EFI/BOOT/memtest86.efi
    chainloader /EFI/BOOT/memtest86.efi
}
GRUB_EOF

    mkdir -p "$ISO_EXTRACT/EFI/BOOT"
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_EXTRACT/EFI/BOOT/bootx64.efi" \
        --modules="part_gpt part_msdos fat iso9660 linux normal echo all_video gfxterm test search search_fs_file chain" \
        "boot/grub/grub.cfg=/tmp/grub_iso.cfg" 2>/dev/null \
    || die "Failed to build GRUB EFI for ISO"
    
    # memtest86+ to ISO
    if [ -f "$WORK_DIR/memtest86plus.bin" ]; then
        cp "$WORK_DIR/memtest86plus.bin" "$ISO_EXTRACT/EFI/BOOT/memtest86.efi"
        cp "$WORK_DIR/memtest86plus.bin" "$ISO_EXTRACT/boot/memtest86plus.bin"
    fi
    
    EFI_IMG="$ISO_EXTRACT/boot/efi.img"
    EFI_SIZE_MB=12
    dd if=/dev/zero of="$EFI_IMG" bs=1M count="$EFI_SIZE_MB" 2>/dev/null
    mformat -i "$EFI_IMG" :: 2>/dev/null
    mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT 2>/dev/null
    mcopy -i "$EFI_IMG" "$ISO_EXTRACT/EFI/BOOT/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null
    if [ -f "$ISO_EXTRACT/EFI/BOOT/memtest86.efi" ]; then
        mcopy -i "$EFI_IMG" "$ISO_EXTRACT/EFI/BOOT/memtest86.efi" ::/EFI/BOOT/ 2>/dev/null
    fi

    # Build dual-boot ISO (Legacy BIOS via isolinux + UEFI via GRUB EFI)
    xorriso -as mkisofs \
        -o "$OUT_ISO" \
        -V "PCInfoClassic" \
        -r -J -joliet-long \
        -c "${ISOLINUX_RELDIR}/boot.cat" \
        -b "${ISOLINUX_RELDIR}/isolinux.bin" \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$ISO_EXTRACT" 2>/dev/null \
    || die "Failed to rebuild ISO"

    # Apply isohybrid MBR so the ISO is also bootable as raw USB image
    if command -v isohybrid > /dev/null 2>&1; then
        isohybrid --uefi "$OUT_ISO" 2>/dev/null \
            && log "isohybrid UEFI MBR applied" \
            || log "WARNING: isohybrid failed (non-fatal)"
    fi

    log "ISO created: $OUT_ISO"
    ls -lh "$OUT_ISO"
}

# ============================================================
# Step 5: USB write instructions
# ============================================================
show_usb_instructions() {
    OUT_IMG="${OUT_ISO%.iso}.img"
    echo ""
    echo "============================================"
    echo "  Build Complete!"
    echo "============================================"
    echo ""
    echo "  推奨: USB Image (memtest86+ 自動起動対応)"
    echo "    Output: $OUT_IMG"
    echo ""
    echo "    Write to USB (Linux/Mac):"
    echo "      sudo dd if=$OUT_IMG of=/dev/sdX bs=4M status=progress && sync"
    echo ""
    echo "    Write to USB (Windows):"
    echo "      Use Etcher: https://etcher.balena.io/"
    echo ""
    echo "  互換用: ISO (Ventoy対応、memtest86+手動選択)"
    echo "    Output: $OUT_ISO"
    echo ""
    echo "============================================"
}

# ============================================================
main() {
    log "=== PCInfo Classic ISO Builder ==="
    check_deps
    download_iso
    extract_iso
    patch_initrd
    rebuild_iso
    show_usb_instructions
}

main "$@"
