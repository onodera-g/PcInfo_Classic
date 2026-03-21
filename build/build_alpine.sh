#!/bin/bash
# build_alpine.sh - PCInfo Classic Build Script (Alpine Linux)
#
# Requirements:
#   Ubuntu 22.04 Docker container (no --privileged)
#   Tools: wget, mtools (mformat/mcopy/mmd), syslinux, grub-efi-amd64-bin,
#          grub-pc-bin, xorriso, p7zip-full
#
# Output:
#   build/pcinfo-classic.img  (single FAT32, no partition table)
#   Write to USB with Rufus DD mode.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"
WORK_DIR="$SCRIPT_DIR/work_alpine"
OUTPUT_IMG="$SCRIPT_DIR/pcinfo-classic.img"

# Alpine version and mirror
ALPINE_VER="3.21"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_ISO_URL="${ALPINE_MIRROR}/v${ALPINE_VER}/releases/${ALPINE_ARCH}/alpine-standard-${ALPINE_VER}.0-${ALPINE_ARCH}.iso"
ALPINE_REPO_MAIN="${ALPINE_MIRROR}/v${ALPINE_VER}/main/${ALPINE_ARCH}"
ALPINE_REPO_COMM="${ALPINE_MIRROR}/v${ALPINE_VER}/community/${ALPINE_ARCH}"

# USB image size (MB) - minimum required
IMG_SIZE_MB=512

# USB volume label - must match alpine_dev= kernel param
USB_LABEL="PCINFO"

# ---- Logging ----
log()   { echo "[build] $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---- Dependency check ----
check_deps() {
    local missing=""
    for cmd in wget mformat mcopy mmd syslinux grub-mkstandalone dd cpio gzip tar; do
        command -v "$cmd" > /dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -n "$missing" ] && error "Missing tools:$missing  (run: apt-get install mtools grub-efi-amd64-bin grub-pc-bin syslinux syslinux-utils)"

    # Check grub i386-pc modules
    if [ ! -d /usr/lib/grub/x86_64-efi ]; then
        error "grub x86_64-efi modules not found. Install: apt-get install grub-efi-amd64-bin"
    fi
    if [ ! -f /usr/lib/syslinux/mbr/mbr.bin ]; then
        error "syslinux mbr.bin not found. Install: apt-get install syslinux-utils"
    fi
}

# ---- Download helpers ----
download() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        log "Cached: $(basename "$dest")"
        return 0
    fi
    log "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url" || error "Download failed: $url"
}

# Download helper that returns 1 on failure (does NOT exit)
download_optional() {
    local url="$1" dest="$2"
    if [ -f "$dest" ] && [ -s "$dest" ]; then
        log "Cached: $(basename "$dest")"
        return 0
    fi
    rm -f "$dest"
    log "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url" 2>/dev/null && [ -s "$dest" ] && return 0
    rm -f "$dest"
    return 1
}

# Download a single .apk from Alpine repository (with retry on mirror)
download_apk() {
    local pkg="$1" dest_dir="$2"
    local apk_file
    # Find latest version in APKINDEX
    local apkindex="$WORK_DIR/APKINDEX_main.tar.gz"
    if [ ! -f "$apkindex" ]; then
        wget -q -O "$apkindex" "${ALPINE_REPO_MAIN}/APKINDEX.tar.gz" || \
            wget -q -O "$apkindex" "${ALPINE_REPO_COMM}/APKINDEX.tar.gz" || \
            { warn "Cannot fetch APKINDEX"; return 1; }
    fi

    # Extract package filename from APKINDEX
    apk_file=$(tar -xOf "$apkindex" APKINDEX 2>/dev/null | \
        awk -v pkg="$pkg" '
          /^P:/{name=$0; sub(/^P:/,"",name)}
          /^V:/{ver=$0; sub(/^V:/,"",ver)}
          /^A:/{arch=$0; sub(/^A:/,"",arch)}
          /^$/{if(name==pkg) print name"-"ver"."arch".apk"; name=""; ver=""; arch=""}
        ' | head -1)

    if [ -z "$apk_file" ]; then
        # Try community repo
        local apkindex2="$WORK_DIR/APKINDEX_comm.tar.gz"
        if [ ! -f "$apkindex2" ]; then
            wget -q -O "$apkindex2" "${ALPINE_REPO_COMM}/APKINDEX.tar.gz" || return 1
        fi
        apk_file=$(tar -xOf "$apkindex2" APKINDEX 2>/dev/null | \
            awk -v pkg="$pkg" '
              /^P:/{name=$0; sub(/^P:/,"",name)}
              /^V:/{ver=$0; sub(/^V:/,"",ver)}
              /^A:/{arch=$0; sub(/^A:/,"",arch)}
              /^$/{if(name==pkg) print name"-"ver"."arch".apk"; name=""; ver=""; arch=""}
            ' | head -1)
    fi

    if [ -z "$apk_file" ]; then
        warn "Package not found in APKINDEX: $pkg"
        return 1
    fi

    local dest="$dest_dir/$apk_file"
    if [ -s "$dest" ]; then
        log "Cached apk: $apk_file"
        return 0
    fi

    log "Downloading apk: $apk_file"
    wget -q -O "$dest" "${ALPINE_REPO_MAIN}/${apk_file}" 2>/dev/null || \
    wget -q -O "$dest" "${ALPINE_REPO_COMM}/${apk_file}" 2>/dev/null || \
    { rm -f "$dest"; warn "Cannot download: $apk_file"; return 1; }
}

# ---- Step 1: Download Alpine standard ISO and extract boot files ----
# The standard ISO's initramfs includes USB storage drivers (netboot does not).
download_alpine_iso() {
    log "=== Downloading Alpine ${ALPINE_VER} standard ISO ==="
    local nb="$WORK_DIR/netboot"
    local iso="$WORK_DIR/alpine-standard.iso"
    mkdir -p "$nb"

    # Check if boot files already extracted
    if [ -s "$nb/vmlinuz-lts" ] && [ -s "$nb/initramfs-lts" ] && [ -s "$nb/modloop-lts" ]; then
        log "Cached: vmlinuz-lts, initramfs-lts, modloop-lts"
        return 0
    fi

    # Download ISO (cached)
    if [ ! -s "$iso" ]; then
        log "Downloading alpine-standard-${ALPINE_VER}.0-${ALPINE_ARCH}.iso (~240MB)..."
        wget -q --show-progress -O "$iso" "$ALPINE_ISO_URL" || \
            { rm -f "$iso"; error "Failed to download Alpine standard ISO"; }
    else
        log "Cached: alpine-standard.iso"
    fi

    # Extract boot files from ISO using 7z
    log "Extracting boot files from ISO..."
    7z e "$iso" -o"$nb" boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts -y > /dev/null 2>&1 || \
        error "Failed to extract boot files from ISO"

    [ -s "$nb/vmlinuz-lts" ]   || error "vmlinuz-lts not found in ISO"
    [ -s "$nb/initramfs-lts" ] || error "initramfs-lts not found in ISO"
    [ -s "$nb/modloop-lts" ]   || error "modloop-lts not found in ISO"

    log "  vmlinuz-lts:   $(du -sh "$nb/vmlinuz-lts"   | cut -f1)"
    log "  initramfs-lts: $(du -sh "$nb/initramfs-lts" | cut -f1)"
    log "  modloop-lts:   $(du -sh "$nb/modloop-lts"   | cut -f1)"
}

# ---- Step 2: Download memtest86+ ----
download_memtest() {
    log "=== Downloading Memtest86+ ==="
    local mt="$WORK_DIR/memtest.efi"

    # Already have it?
    if [ -f "$mt" ] && [ -s "$mt" ]; then
        log "Cached: memtest.efi"
        return 0
    fi

    # Try zip first (v7.20+)
    local zip="$WORK_DIR/memtest.zip"
    if download_optional \
        "https://memtest.org/download/v7.20/mt86plus_7.20_64.grub.efi.zip" "$zip"; then
        mkdir -p "$WORK_DIR/memtest_unzip"
        unzip -q -o "$zip" -d "$WORK_DIR/memtest_unzip/" 2>/dev/null || true
        local efi
        efi=$(find "$WORK_DIR/memtest_unzip" -name "*.efi" 2>/dev/null | head -1)
        if [ -n "$efi" ]; then
            cp "$efi" "$mt"
            log "  memtest86+ extracted: $(basename "$efi")"
            return 0
        fi
    fi

    # Try direct EFI (v7.00)
    if download_optional \
        "https://memtest.org/download/v7.00/mt86plus_7.00_64.grub.efi" "$mt"; then
        log "  memtest86+ downloaded (v7.00)"
        return 0
    fi

    warn "memtest86+ download failed - memory test will be unavailable (skipped)"
    return 0
}

# ---- Step 3: Download required .apk packages for offline use ----
download_apkcache() {
    log "=== Downloading offline APK cache ==="
    local cache_dir="$WORK_DIR/apkcache"
    mkdir -p "$cache_dir"

    # Required packages for PCInfo operation
    local pkgs="dialog smartmontools nvme-cli pciutils wireless-tools wpa_supplicant iw \
                hdparm util-linux blkid dmidecode eudev"

    for pkg in $pkgs; do
        download_apk "$pkg" "$cache_dir" || warn "Could not pre-cache: $pkg"
    done
}

# ---- Step 4: Create apkovl overlay ----
build_apkovl() {
    log "=== Building apkovl overlay ==="
    local ovl_dir="$WORK_DIR/apkovl"
    rm -rf "$ovl_dir"

    # Directory structure
    mkdir -p "$ovl_dir/etc/local.d"
    mkdir -p "$ovl_dir/etc/apk"
    mkdir -p "$ovl_dir/opt/pcinfo"
    mkdir -p "$ovl_dir/root"

    # Hostname
    echo "pcinfo" > "$ovl_dir/etc/hostname"

    # Auto-login on tty1 via inittab
    cat > "$ovl_dir/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

tty1::respawn:/sbin/agetty --autologin root --noclear tty1 linux
tty2::askfirst:/sbin/agetty --noclear tty2 linux
tty3::askfirst:/sbin/agetty --noclear tty3 linux

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # root profile: start menu after login
    cat > "$ovl_dir/root/.profile" << 'EOF'
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/pcinfo
export TERM=linux
export LANG=C
cd /root
exec /opt/pcinfo/menu.sh
EOF

    # APK repositories
    cat > "$ovl_dir/etc/apk/repositories" << EOF
${ALPINE_MIRROR}/v${ALPINE_VER}/main
${ALPINE_MIRROR}/v${ALPINE_VER}/community
EOF

    # Startup script: install packages from USB apkcache
    cat > "$ovl_dir/etc/local.d/00-pcinfo-setup.start" << 'SETUP_EOF'
#!/bin/sh
# Install required packages from USB apkcache (offline)
USB_MNT="/mnt/usb"
mkdir -p "$USB_MNT"

# Alpine diskless may have already mounted the USB at /media/usb
if mountpoint -q /media/usb 2>/dev/null; then
    mount --bind /media/usb "$USB_MNT" 2>/dev/null || USB_MNT="/media/usb"
else
    # Fallback: try to mount by label or device
    mount -t vfat -L PCINFO "$USB_MNT" 2>/dev/null || \
        mount -t vfat /dev/sda "$USB_MNT" 2>/dev/null || \
        mount -t vfat /dev/sdb "$USB_MNT" 2>/dev/null || true
fi

# Install non-empty APK files from USB cache (offline)
if mountpoint -q "$USB_MNT" 2>/dev/null && [ -d "$USB_MNT/apkcache" ]; then
    apks=""
    for apk in "$USB_MNT"/apkcache/*.apk; do
        [ -s "$apk" ] && apks="$apks $apk"
    done
    if [ -n "$apks" ]; then
        # shellcheck disable=SC2086
        apk add --allow-untrusted --no-network $apks 2>/dev/null || true
    fi
fi

# Keep USB mounted for driver access (menu_gpu.sh uses /mnt/usb)
exit 0
SETUP_EOF
    chmod +x "$ovl_dir/etc/local.d/00-pcinfo-setup.start"

    # Install PCInfo scripts
    local scripts="common.sh menu.sh menu_pcinfo.sh menu_storage.sh menu_gpu.sh menu_memtest.sh menu_network.sh pcinfo.sh"
    for s in $scripts; do
        if [ -f "$SRC_DIR/$s" ]; then
            cp "$SRC_DIR/$s" "$ovl_dir/opt/pcinfo/$s"
            chmod +x "$ovl_dir/opt/pcinfo/$s"
            log "  Installed: $s"
        else
            warn "  Missing source: $SRC_DIR/$s"
        fi
    done

    # Symlink: /opt/pcinfo/menu.sh as entrypoint
    ln -sf /opt/pcinfo/menu.sh "$ovl_dir/opt/pcinfo/start"

    # Pack as apkovl tarball
    local ovl_tar="$WORK_DIR/pcinfo.apkovl.tar.gz"
    tar -czf "$ovl_tar" -C "$ovl_dir" . 2>/dev/null
    log "  apkovl created: $ovl_tar ($(du -sh "$ovl_tar" | cut -f1))"
    echo "$ovl_tar"
}

# ---- Step 5: Create EFI bootloader (grub-mkstandalone) ----
build_efi_bootloader() {
    log "=== Building EFI bootloader ==="
    local efi_out="$WORK_DIR/BOOTX64.EFI"
    local stub_cfg="$WORK_DIR/grub_stub.cfg"

    # Stub config: search for USB by label, then load external grub.cfg
    cat > "$stub_cfg" << EOF
search --no-floppy --label --set=root ${USB_LABEL}
set prefix=(\$root)/EFI/BOOT
configfile (\$root)/EFI/BOOT/grub.cfg
EOF

    grub-mkstandalone \
        -O x86_64-efi \
        -o "$efi_out" \
        --modules="fat linux linuxefi normal boot chain configfile echo ls search search_label search_fs_uuid efi_gop efi_uga part_gpt part_msdos" \
        "boot/grub/grub.cfg=${stub_cfg}" \
        2>/dev/null

    log "  BOOTX64.EFI built: $(du -sh "$efi_out" | cut -f1)"
    echo "$efi_out"
}

# ---- Step 6: Create FAT32 image with mtools ----
build_fat32_image() {
    local nb="$1"       # netboot dir
    local ovl_tar="$2"  # apkovl.tar.gz
    local efi_bin="$3"  # BOOTX64.EFI

    log "=== Building FAT32 image ==="
    rm -f "$OUTPUT_IMG"

    # Create blank image
    dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count=$IMG_SIZE_MB status=progress 2>/dev/null
    log "  Created ${IMG_SIZE_MB}MB blank image"

    # Format as FAT32 with volume label
    mformat -i "$OUTPUT_IMG" -F -v "$USB_LABEL" -T 65536 :: 2>/dev/null || \
    mformat -i "$OUTPUT_IMG" -F -v "$USB_LABEL" ::
    log "  Formatted as FAT32 (label: ${USB_LABEL})"

    # Create directory structure
    mmd -i "$OUTPUT_IMG" ::/EFI          2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/EFI/BOOT     2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/boot         2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/apkcache     2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/drivers      2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/drivers/nvidia 2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/drivers/amd  2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/drivers/intel 2>/dev/null || true

    # Copy kernel files
    mcopy -i "$OUTPUT_IMG" "$nb/vmlinuz-lts"   ::/boot/vmlinuz-lts
    mcopy -i "$OUTPUT_IMG" "$nb/initramfs-lts" ::/boot/initramfs-lts
    mcopy -i "$OUTPUT_IMG" "$nb/modloop-lts"   ::/boot/modloop-lts
    log "  Kernel files copied"

    # Copy memtest86+
    if [ -f "$WORK_DIR/memtest.efi" ]; then
        mcopy -i "$OUTPUT_IMG" "$WORK_DIR/memtest.efi" ::/boot/memtest.efi
        log "  Memtest86+ copied"
    fi

    # Copy apkovl
    mcopy -i "$OUTPUT_IMG" "$ovl_tar" ::/"$(basename "$ovl_tar")"
    log "  apkovl copied"

    # Copy APK cache (skip 0-byte files from failed downloads)
    local apk_count=0
    for apk in "$WORK_DIR/apkcache/"*.apk; do
        [ -s "$apk" ] || continue
        mcopy -i "$OUTPUT_IMG" "$apk" ::/apkcache/"$(basename "$apk")"
        apk_count=$((apk_count + 1))
    done
    if [ "$apk_count" -eq 0 ]; then
        log "  APK cache: none (network unavailable during build - packages will be fetched on first boot)"
    else
        log "  APK cache: $apk_count package(s) copied"
    fi

    # EFI bootloader
    mcopy -i "$OUTPUT_IMG" "$efi_bin" ::/EFI/BOOT/BOOTX64.EFI
    log "  BOOTX64.EFI copied"

    # GRUB EFI config (external, modifiable for memtest reboot)
    local grub_cfg="$WORK_DIR/grub.cfg"
    local has_memtest=false
    [ -f "$WORK_DIR/memtest.efi" ] && has_memtest=true

    cat > "$grub_cfg" << GRUB_EOF
set default="pcinfo"
set timeout=5

if [ -f (\$root)/EFI/BOOT/grubenv ]; then
  load_env --file (\$root)/EFI/BOOT/grubenv
  set default=\${saved_entry}
fi

menuentry "PCInfo Classic" --id pcinfo {
    linuxefi  /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet alpine_dev=LABEL=${USB_LABEL}:vfat
    initrdefi /boot/initramfs-lts
}

GRUB_EOF

    if $has_memtest; then
        cat >> "$grub_cfg" << 'MEMTEST_EOF'
menuentry "Memtest86+" --id memtest {
    save_env --file (hd0)/EFI/BOOT/grubenv saved_entry=pcinfo
    chainloader /boot/memtest.efi
}
MEMTEST_EOF
    fi

    mcopy -i "$OUTPUT_IMG" "$grub_cfg" ::/EFI/BOOT/grub.cfg
    log "  grub.cfg copied"

    # Create grubenv (1024 bytes, padded with #)
    local grubenv_file="$WORK_DIR/grubenv"
    dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\000' '#' > "$grubenv_file"
    printf '# GRUB Environment Block\nsaved_entry=pcinfo\n' | \
        dd of="$grubenv_file" conv=notrunc 2>/dev/null
    mcopy -i "$OUTPUT_IMG" "$grubenv_file" ::/EFI/BOOT/grubenv
    log "  grubenv copied"

    # Syslinux config (BIOS boot)
    local syslinux_cfg="$WORK_DIR/syslinux.cfg"
    cat > "$syslinux_cfg" << SYSLINUX_EOF
DEFAULT pcinfo
TIMEOUT 50
PROMPT 1

LABEL pcinfo
  MENU LABEL PCInfo Classic (Alpine Linux)
  KERNEL /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  APPEND modules=loop,squashfs,sd-mod,usb-storage quiet alpine_dev=LABEL=${USB_LABEL}:vfat

SYSLINUX_EOF

    if $has_memtest; then
        cat >> "$syslinux_cfg" << 'SYSLINUX_MEMTEST_EOF'
LABEL memtest
  MENU LABEL Memtest86+
  KERNEL /boot/memtest.efi
SYSLINUX_MEMTEST_EOF
    fi

    mcopy -i "$OUTPUT_IMG" "$syslinux_cfg" ::/syslinux.cfg
    log "  syslinux.cfg copied"

    # Copy syslinux BIOS c32 modules (for menu display)
    local syslinux_bios_dir=""
    for d in /usr/lib/syslinux/modules/bios /usr/lib/syslinux/bios /usr/share/syslinux; do
        [ -d "$d" ] && syslinux_bios_dir="$d" && break
    done
    if [ -n "$syslinux_bios_dir" ]; then
        for mod in libcom32.c32 menu.c32 ldlinux.c32; do
            [ -f "$syslinux_bios_dir/$mod" ] && \
                mcopy -i "$OUTPUT_IMG" "$syslinux_bios_dir/$mod" "::/$mod" 2>/dev/null || true
        done
        log "  syslinux modules copied"
    fi

    log "  File copy complete."
}

# ---- Step 7: Install syslinux BIOS bootloader ----
install_syslinux() {
    log "=== Installing syslinux (BIOS boot) ==="

    # For a non-partitioned FAT32 image, syslinux installs its boot code
    # directly into the FAT32 VBR (sector 0).  BIOS executes sector 0
    # directly on a non-partitioned USB, so no mbr.bin is needed.
    if syslinux --install "$OUTPUT_IMG" 2>/dev/null; then
        log "  syslinux boot sector installed (BIOS boot ready)"
    else
        warn "  syslinux install failed - BIOS boot may not work"
        warn "  (UEFI boot via GRUB is still available)"
    fi
}

# ---- Main ----
main() {
    log "========================================"
    log " PCInfo Classic - Build Script"
    log " Alpine Linux ${ALPINE_VER} standard ISO / ${ALPINE_ARCH}"
    log "========================================"
    log ""

    check_deps

    mkdir -p "$WORK_DIR"

    download_alpine_iso
    download_memtest
    download_apkcache

    local ovl_tar
    ovl_tar=$(build_apkovl)

    local efi_bin
    efi_bin=$(build_efi_bootloader)

    build_fat32_image "$WORK_DIR/netboot" "$ovl_tar" "$efi_bin"
    install_syslinux

    log ""
    log "========================================"
    log " Build Complete!"
    log "========================================"
    log ""
    log " Output : $OUTPUT_IMG"
    log " Size   : $(du -sh "$OUTPUT_IMG" | cut -f1)"
    log ""
    log " Write to USB using Rufus (DD mode)"
    log " USB label must be: ${USB_LABEL}"
    log ""
    log " Before GPU test, place .apk files in:"
    log "   USB:/drivers/nvidia/"
    log "   USB:/drivers/amd/"
    log "   USB:/drivers/intel/"
    log " (fetch with: apk fetch -R -o <dir> <packages>)"
    log ""
}

main "$@"
