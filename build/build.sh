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

    # profile.d: single-key input (no Enter needed) via stty cbreak + dd
    mkdir -p "$INITRD_WORK/etc/profile.d"
    cat > "$INITRD_WORK/etc/profile.d/pcinfo.sh" << 'PROFILE_EOF'
#!/bin/sh
FBPRINT=/usr/local/bin/fbprint
FONT=/usr/share/consolefonts/unifont_ja.psf.gz
FB=/dev/fb0
TTY=/dev/tty1

read_key() {
    _old=$(stty -g < "$TTY")
    stty -icanon -echo min 1 time 0 < "$TTY"
    key=$(dd bs=1 count=1 < "$TTY" 2>/dev/null)
    stty "$_old" < "$TTY"
}

if [ ! -e "$FB" ] || [ ! -x "$FBPRINT" ]; then
    /opt/pcinfo.sh
    printf "Press any key to exit..." > "$TTY"
    read_key
    return
fi

while true; do
    printf '\033[2J\033[H' > "$TTY" 2>/dev/null
    {
        printf " ____      ___        __          ____ _               _      \n"
        printf "|  _ \\___|_ _|_ __  / _| ___    / ___| | __ _ ___ ___(_) ___ \n"
        printf "| |_) / __|| || '_ \\| |_ / _ \\  | |   | |/ _\` / __/ __| |/ __|\n"
        printf "|  __/ (__ | || | | |  _| (_) | | |___| | (_| \\__ \\__ \\ | (__ \n"
        printf "|_|   \\___|___|_| |_|_|  \\___/   \\____|_|\\__,_|___/___/_|\\___|\n"
        printf "                                      Powered by Tiny Core Linux\n"
        printf "\n"
        printf "  1. PC情報\n"
        printf "  2. メモリテスト\n"
        printf "  3. GPUテスト\n"
        printf "  4. ストレージ情報\n"
        printf "  q. Quit\n"
        printf "\n  Select [1-4/q]: "
    } | "$FBPRINT" "$FONT" "$FB"

    read_key

    case "$key" in
        1)
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            {
                /opt/pcinfo.sh
                printf "\n  任意のキーで戻る...\n"
            } | "$FBPRINT" "$FONT" "$FB"
            read_key
            ;;
        2)
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "[メモリテスト]\n\n未実装\n\n任意のキーで戻る...\n" | "$FBPRINT" "$FONT" "$FB"
            read_key
            ;;
        3)
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "[GPUテスト]\n\n未実装\n\n任意のキーで戻る...\n" | "$FBPRINT" "$FONT" "$FB"
            read_key
            ;;
        4)
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "[ストレージ情報]\n\n未実装\n\n任意のキーで戻る...\n" | "$FBPRINT" "$FONT" "$FB"
            read_key
            ;;
        q|Q)
            break
            ;;
    esac
done
PROFILE_EOF
    chmod 755 "$INITRD_WORK/etc/profile.d/pcinfo.sh"

    log "Repacking initrd ..."
    find . | cpio -o -H newc --quiet | gzip -9 > "$INITRD_PATH"
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
        log "Patched isolinux.cfg with vga=794 nodhcp nozswap"
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

    # --- Build GRUB EFI bootloader ---
    log "Building GRUB EFI bootloader ..."
    mkdir -p "$ISO_EXTRACT/EFI/BOOT"

    # grub.cfg: load kernel and initrd from ISO
    cat > /tmp/grub_embed.cfg << 'GRUB_EOF'
set gfxmode=1024x768,800x600,auto
set gfxpayload=keep
set timeout=0
set default=0

# Find the device containing our ISO filesystem by searching for a known file
search --set=root --file /boot/vmlinuz64

menuentry "PcInfo Classic" {
    linux /boot/vmlinuz64 loglevel=3 quiet nomodeset=0 vga=794 nodhcp nozswap
    initrd /boot/corepure64.gz
}
GRUB_EOF

    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_EXTRACT/EFI/BOOT/bootx64.efi" \
        --modules="part_gpt part_msdos fat iso9660 linux normal echo all_video gfxterm gfxterm_background test search search_fs_file" \
        "boot/grub/grub.cfg=/tmp/grub_embed.cfg" 2>/dev/null \
    || die "Failed to build GRUB EFI"

    log "GRUB EFI bootloader created: EFI/BOOT/bootx64.efi"

    # Create EFI boot image (FAT img) for El Torito EFI entry
    # Use mtools (no loop mount needed) - image must be larger than bootx64.efi (~6MB)
    EFI_IMG="$ISO_EXTRACT/boot/efi.img"
    EFI_SIZE_MB=12  # 12MB: enough for bootx64.efi (~6MB) with FAT16
    dd if=/dev/zero of="$EFI_IMG" bs=1M count="$EFI_SIZE_MB" 2>/dev/null
    mformat -i "$EFI_IMG" :: 2>/dev/null
    mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT 2>/dev/null
    mcopy -i "$EFI_IMG" "$ISO_EXTRACT/EFI/BOOT/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null \
        && log "EFI files copied into efi.img via mtools" \
        || die "mcopy failed: cannot create EFI boot image"

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
    echo ""
    echo "============================================"
    echo "  ISO Build Complete!"
    echo "============================================"
    echo ""
    echo "  Output: $OUT_ISO"
    echo ""
    echo "  Write to USB (Linux/Mac):"
    echo "    sudo dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress && sync"
    echo "    (replace /dev/sdX with your USB device)"
    echo ""
    echo "  Write to USB (Windows):"
    echo "    Use Rufus: https://rufus.ie/"
    echo "    Select DD mode when prompted."
    echo ""
    echo "  Boot the USB, then pcinfo.sh runs automatically."
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
