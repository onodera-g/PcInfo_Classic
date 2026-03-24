#!/bin/bash
# build_alpine.sh - PCInfo Classic Build Script (Alpine Linux)
#
# Requirements:
#   Ubuntu 22.04 container / host
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
GPU_DRIVERS_DIR="$SCRIPT_DIR/drivers"
GPU_PCI_IDS_BUILD_FILE="$WORK_DIR/gpu_pci_ids.txt"
GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE="$WORK_DIR/gpu_pci_subsystem_ids.txt"
GPU_VRAM_HINTS_SOURCE_FILE="$SRC_DIR/gpu_vram_hints.txt"

# Alpine version and mirror
ALPINE_VER="3.21"
ALPINE_ARCH="x86_64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_ISO_URL="${ALPINE_MIRROR}/v${ALPINE_VER}/releases/${ALPINE_ARCH}/alpine-standard-${ALPINE_VER}.0-${ALPINE_ARCH}.iso"
ALPINE_REPO_MAIN="${ALPINE_MIRROR}/v${ALPINE_VER}/main/${ALPINE_ARCH}"
ALPINE_REPO_COMM="${ALPINE_MIRROR}/v${ALPINE_VER}/community/${ALPINE_ARCH}"

# USB image size (MB) - minimum required
IMG_SIZE_MB=512

# USB volume label - used by the generated FAT32 image
USB_LABEL="PCINFO"
BOOT_MODULES="loop,squashfs,sd-mod,usb-storage,vfat,fat,nls_cp437,nls_iso8859-1,amdgpu,radeon,nouveau,i915,fbcon"

# ---- Logging ----
log()   { echo "[build] $*" >&2; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

calc_image_size_mb() {
    local ovl_tar="$1" efi_bin="$2"
    local payload_bytes=0
    local image_mb="$IMG_SIZE_MB"
    local memtest_bytes=0

    [ -d "$WORK_DIR/netboot" ] && payload_bytes=$((payload_bytes + $(du -sb "$WORK_DIR/netboot" | cut -f1)))
    [ -d "$WORK_DIR/apks" ] && payload_bytes=$((payload_bytes + $(du -sb "$WORK_DIR/apks" | cut -f1)))
    [ -d "$GPU_DRIVERS_DIR" ] && payload_bytes=$((payload_bytes + $(du -sb "$GPU_DRIVERS_DIR" | cut -f1)))
    [ -f "$ovl_tar" ] && payload_bytes=$((payload_bytes + $(stat -c '%s' "$ovl_tar")))
    [ -f "$efi_bin" ] && payload_bytes=$((payload_bytes + $(stat -c '%s' "$efi_bin")))
    [ -f "$WORK_DIR/memtest.efi" ] && memtest_bytes=$(stat -c '%s' "$WORK_DIR/memtest.efi")
    payload_bytes=$((payload_bytes + memtest_bytes))

    image_mb=$((((payload_bytes * 13) / 10 + 64 * 1024 * 1024 + 1024 * 1024 - 1) / (1024 * 1024)))
    [ "$image_mb" -lt "$IMG_SIZE_MB" ] && image_mb="$IMG_SIZE_MB"
    printf '%s\n' "$image_mb"
}

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
ensure_apk_indexes() {
    local apkindex="$WORK_DIR/APKINDEX_main.tar.gz"
    if [ ! -s "$apkindex" ]; then
        wget -q -O "$apkindex" "${ALPINE_REPO_MAIN}/APKINDEX.tar.gz" || \
            { warn "Cannot fetch main APKINDEX"; return 1; }
    fi
    local apkindex2="$WORK_DIR/APKINDEX_comm.tar.gz"
    if [ ! -s "$apkindex2" ]; then
        wget -q -O "$apkindex2" "${ALPINE_REPO_COMM}/APKINDEX.tar.gz" || \
            { warn "Cannot fetch community APKINDEX"; return 1; }
    fi
}

build_apk_catalog() {
    local catalog="$WORK_DIR/apk_catalog.tsv"
    ensure_apk_indexes || return 1

    {
        tar -xOf "$WORK_DIR/APKINDEX_main.tar.gz" APKINDEX 2>/dev/null | \
            awk -v repo="main" '
                BEGIN { RS=""; FS="\n"; OFS="\t" }
                {
                    name=""; ver=""; deps=""; prov=""
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^P:/) name = substr($i, 3)
                        else if ($i ~ /^V:/) ver = substr($i, 3)
                        else if ($i ~ /^D:/) deps = substr($i, 3)
                        else if ($i ~ /^p:/) prov = substr($i, 3)
                    }
                    if (deps == "") deps = "-"
                    if (prov == "") prov = "-"
                    if (name != "" && ver != "") print repo, name, ver, deps, prov
                }'

        tar -xOf "$WORK_DIR/APKINDEX_comm.tar.gz" APKINDEX 2>/dev/null | \
            awk -v repo="community" '
                BEGIN { RS=""; FS="\n"; OFS="\t" }
                {
                    name=""; ver=""; deps=""; prov=""
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^P:/) name = substr($i, 3)
                        else if ($i ~ /^V:/) ver = substr($i, 3)
                        else if ($i ~ /^D:/) deps = substr($i, 3)
                        else if ($i ~ /^p:/) prov = substr($i, 3)
                    }
                    if (deps == "") deps = "-"
                    if (prov == "") prov = "-"
                    if (name != "" && ver != "") print repo, name, ver, deps, prov
                }'
    } > "$catalog"
}

ensure_apk_catalog() {
    build_apk_catalog || return 1
}

normalize_apk_dep() {
    local dep="$1"
    dep="${dep#!}"
    dep="${dep%@*}"
    dep="${dep%%[<>=~]*}"
    printf '%s\n' "$dep"
}

resolve_apk_record() {
    local token="$1"
    ensure_apk_catalog || return 1
    awk -F '\t' -v key="$token" '
        function normalize(dep, out) {
            out = dep
            sub(/^!/, "", out)
            sub(/@.*/, "", out)
            sub(/[<>=~].*/, "", out)
            return out
        }
        $2 == key {
            print
            exit
        }
        {
            n = split($5, provides, / /)
            for (i = 1; i <= n; i++) {
                if (normalize(provides[i]) == key) {
                    print
                    exit
                }
            }
        }
    ' "$WORK_DIR/apk_catalog.tsv"
}

download_apk_file() {
    local repo="$1" pkg="$2" ver="$3" dest_dir="$4"
    local apk_file="${pkg}-${ver}.apk"
    local dest="$dest_dir/$apk_file"
    local repo_url=""

    case "$repo" in
        main) repo_url="$ALPINE_REPO_MAIN" ;;
        community) repo_url="$ALPINE_REPO_COMM" ;;
        *) warn "Unknown Alpine repo for $pkg: $repo"; return 1 ;;
    esac

    if [ -s "$dest" ]; then
        log "Cached apk: $apk_file"
        return 0
    fi

    log "Downloading apk: $apk_file"
    wget -q -O "$dest" "${repo_url}/${apk_file}" 2>/dev/null || \
        { rm -f "$dest"; warn "Cannot download: $apk_file"; return 1; }
}

download_apk() {
    local pkg="$1" dest_dir="$2"
    local record repo resolved_pkg ver deps provides

    record=$(resolve_apk_record "$pkg")
    if [ -z "$record" ]; then
        warn "Package not found in APKINDEX: $pkg"
        return 1
    fi

    IFS=$'\t' read -r repo resolved_pkg ver deps provides <<< "$record"
    [ "$deps" = "-" ] && deps=""
    [ "$provides" = "-" ] && provides=""
    download_apk_file "$repo" "$resolved_pkg" "$ver" "$dest_dir"
}

download_apk_recursive() {
    local pkg="$1" dest_dir="$2" state_dir="$3"
    local dep normalized record repo resolved_pkg ver deps provides
    local visited="$state_dir/visited.txt"

    normalized=$(normalize_apk_dep "$pkg")
    [ -n "$normalized" ] || return 0

    if [ -f "$visited" ] && grep -qxF "$normalized" "$visited" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$normalized" >> "$visited"

    record=$(resolve_apk_record "$normalized")
    if [ -z "$record" ]; then
        warn "Dependency not found in APKINDEX: $normalized"
        return 1
    fi

    IFS=$'\t' read -r repo resolved_pkg ver deps provides <<< "$record"
    [ "$deps" = "-" ] && deps=""
    [ "$provides" = "-" ] && provides=""
    download_apk_file "$repo" "$resolved_pkg" "$ver" "$dest_dir" || return 1

    for dep in $deps; do
        case "$dep" in
            \!*) continue ;;
        esac
        download_apk_recursive "$dep" "$dest_dir" "$state_dir" || return 1
    done
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

# ---- Step 3: Build apks/ directory for diskless boot ----
# Alpine diskless init installs packages from a local repository on the boot media.
# We need:  1) base packages from the standard ISO
#           2) additional tools required by PCInfo scripts
build_apks_dir() {
    log "=== Building apks/ directory ==="
    local apks_dir="$WORK_DIR/apks/x86_64"
    mkdir -p "$apks_dir"

    local iso="$WORK_DIR/alpine-standard.iso"
    [ -s "$iso" ] || error "Alpine ISO not found: $iso"

    # Extract base packages from ISO (APKINDEX + all .apk files)
    if [ ! -s "$apks_dir/APKINDEX.tar.gz" ]; then
        log "  Extracting base packages from ISO..."
        7z e "$iso" -o"$apks_dir" "apks/x86_64/*" -y > /dev/null 2>&1
        log "  Base packages extracted: $(ls "$apks_dir"/*.apk 2>/dev/null | wc -l) packages"
    else
        log "  Base packages cached: $(ls "$apks_dir"/*.apk 2>/dev/null | wc -l) packages"
    fi

    # Download additional packages needed by PCInfo
    log "  Downloading additional packages..."
    local pkgs="bash dialog smartmontools nvme-cli pciutils wireless-tools wpa_supplicant iw \
                hdparm util-linux blkid dmidecode eudev"
    local ok=0 fail=0
    for pkg in $pkgs; do
        if download_apk "$pkg" "$apks_dir"; then
            ok=$((ok + 1))
        else
            warn "Could not fetch: $pkg (may need internet on first boot)"
            fail=$((fail + 1))
        fi
    done
    log "  Additional packages: $ok ok, $fail failed"

    # Rebuild APKINDEX to include our downloaded packages
    # (Alpine's apk tool will use the existing APKINDEX.tar.gz,
    #  new packages are found by apk add --allow-untrusted)
    log "  apks/ ready: $(ls "$apks_dir"/*.apk 2>/dev/null | wc -l) total packages"
}

# ---- Step 4: Fetch offline GPU driver APKs without Docker ----
fetch_gpu_driver_apks() {
    log "=== Fetching offline GPU driver APKs ==="
    local vendor
    local state_dir="$WORK_DIR/gpu_fetch_state"

    rm -rf "$state_dir"
    mkdir -p "$GPU_DRIVERS_DIR/nvidia" "$GPU_DRIVERS_DIR/amd" "$GPU_DRIVERS_DIR/intel"
    mkdir -p "$state_dir/amd" "$state_dir/nvidia" "$state_dir/intel"
    rm -f "$GPU_DRIVERS_DIR"/nvidia/*.apk "$GPU_DRIVERS_DIR"/amd/*.apk "$GPU_DRIVERS_DIR"/intel/*.apk

    log "  AMD packages: linux-firmware-amdgpu linux-firmware-radeon xf86-video-amdgpu mesa-dri-gallium"
    for pkg in linux-firmware-amdgpu linux-firmware-radeon xf86-video-amdgpu mesa-dri-gallium; do
        download_apk_recursive "$pkg" "$GPU_DRIVERS_DIR/amd" "$state_dir/amd" || \
            error "Failed to fetch AMD GPU driver APKs"
    done

    log "  NVIDIA packages: linux-firmware-nvidia xf86-video-nouveau mesa-dri-gallium"
    for pkg in linux-firmware-nvidia xf86-video-nouveau mesa-dri-gallium; do
        download_apk_recursive "$pkg" "$GPU_DRIVERS_DIR/nvidia" "$state_dir/nvidia" || \
            error "Failed to fetch NVIDIA GPU driver APKs"
    done

    log "  Intel packages: linux-firmware-intel xf86-video-intel mesa-dri-gallium"
    for pkg in linux-firmware-intel xf86-video-intel mesa-dri-gallium; do
        download_apk_recursive "$pkg" "$GPU_DRIVERS_DIR/intel" "$state_dir/intel" || \
            error "Failed to fetch Intel GPU driver APKs"
    done

    for vendor in nvidia amd intel; do
        log "  drivers/$vendor: $(find "$GPU_DRIVERS_DIR/$vendor" -maxdepth 1 -name '*.apk' | wc -l) package(s)"
    done
}

build_gpu_pci_db() {
    log "=== Building GPU PCI ID database ==="
    local pci_ids_raw="$WORK_DIR/pci.ids"

    if [ ! -s "$pci_ids_raw" ]; then
        log "Downloading official pci.ids..."
        wget -q -O "$pci_ids_raw" "https://pci-ids.ucw.cz/v2.2/pci.ids" || \
            error "Failed to download pci.ids"
    else
        log "Cached: pci.ids"
    fi

    awk '
        BEGIN {
            OFS="|"
            vendor=""
            keep["1002"]="AMD"
            keep["10de"]="NVIDIA"
            keep["8086"]="Intel"
            print "# vendor_id|device_id|manufacturer|model|vram_hint"
        }
        /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            vendor=tolower(substr($0, 1, 4))
            next
        }
        /^\t[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            if (!(vendor in keep)) {
                next
            }
            device=tolower(substr($0, 2, 4))
            model=substr($0, 8)
            gsub(/\r/, "", model)
            sub(/^[[:space:]]+/, "", model)
            sub(/[[:space:]]+$/, "", model)
            if (model == "") {
                next
            }
            print "0x" vendor, "0x" device, keep[vendor], model, ""
        }
    ' "$pci_ids_raw" > "$GPU_PCI_IDS_BUILD_FILE"

    awk '
        BEGIN {
            OFS="|"
            vendor=""
            device=""
            keep["1002"]="AMD"
            keep["10de"]="NVIDIA"
            keep["8086"]="Intel"
            print "# vendor_id|device_id|subvendor_id|subdevice_id|manufacturer|model|vram_hint"
        }
        /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            vendor=tolower(substr($0, 1, 4))
            device=""
            next
        }
        /^\t[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            if (!(vendor in keep)) {
                next
            }
            device=tolower(substr($0, 2, 4))
            next
        }
        /^\t\t[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f] [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]  / {
            if (!(vendor in keep) || device == "") {
                next
            }
            subvendor=tolower(substr($0, 3, 4))
            subdevice=tolower(substr($0, 8, 4))
            model=substr($0, 14)
            gsub(/\r/, "", model)
            sub(/^[[:space:]]+/, "", model)
            sub(/[[:space:]]+$/, "", model)
            if (model == "") {
                next
            }
            print "0x" vendor, "0x" device, "0x" subvendor, "0x" subdevice, keep[vendor], model, ""
        }
    ' "$pci_ids_raw" > "$GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE"

    [ -s "$GPU_PCI_IDS_BUILD_FILE" ] || error "Failed to build GPU PCI ID database"
    local gpu_id_count
    gpu_id_count=$(grep -vc '^#' "$GPU_PCI_IDS_BUILD_FILE")
    [ "$gpu_id_count" -gt 0 ] || error "GPU PCI ID database is empty"
    log "  GPU IDs: ${gpu_id_count} entries"
    [ -s "$GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE" ] || error "Failed to build GPU PCI subsystem database"
}

# ---- Step 5: Create apkovl overlay ----
build_apkovl() {
    log "=== Building apkovl overlay ==="
    local ovl_dir="$WORK_DIR/apkovl"
    local dmidecode_apk=""
    rm -rf "$ovl_dir"

    # Directory structure
    mkdir -p "$ovl_dir/etc/local.d"
    mkdir -p "$ovl_dir/etc/runlevels/default"
    mkdir -p "$ovl_dir/etc/runlevels/sysinit"
    mkdir -p "$ovl_dir/etc/apk"
    mkdir -p "$ovl_dir/opt/pcinfo"
    mkdir -p "$ovl_dir/root"
    mkdir -p "$ovl_dir/usr/sbin"

    # Hostname
    echo "pcinfo" > "$ovl_dir/etc/hostname"

    # Auto-login on tty1 via inittab
    cat > "$ovl_dir/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

tty1::respawn:/sbin/getty -n -l /usr/sbin/autologin 38400 tty1 linux
tty2::askfirst:/sbin/getty 38400 tty2 linux
tty3::askfirst:/sbin/getty 38400 tty3 linux

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

    cat > "$ovl_dir/usr/sbin/autologin" << 'EOF'
#!/bin/sh
exec /bin/login -f root
EOF
    chmod +x "$ovl_dir/usr/sbin/autologin"

    # APK world file: ONLY packages available in the standard ISO's apks/ directory.
    # 'alpine-base' is already hardcoded in Alpine's init, so only add ISO-included extras.
    # Additional tools (dialog, smartmontools, etc.) are installed by 00-pcinfo-setup.start
    # AFTER boot using the pre-downloaded .apk files in USB:/apks/x86_64/.
    cat > "$ovl_dir/etc/apk/world" << 'EOF'
alpine-base
wpa_supplicant
EOF

    ln -sf /etc/init.d/local "$ovl_dir/etc/runlevels/default/local"
    ln -sf /etc/init.d/modloop "$ovl_dir/etc/runlevels/sysinit/modloop"

    # Startup script: install additional tools from USB then keep USB accessible
    cat > "$ovl_dir/etc/local.d/00-pcinfo-setup.start" << 'SETUP_EOF'
#!/bin/sh
# Install PCInfo tools from pre-downloaded APKs on USB, then mount USB for GPU driver access.
USB_MNT="/mnt/usb"
DEV=""

is_mounted() {
    grep -Fqs " $1 " /proc/mounts 2>/dev/null
}

mkdir -p "$USB_MNT"

# Find where Alpine has already mounted the USB
for mp in /media/usb /media/sd* /media/vd* /media/mmcblk* /media/nvme* /media/LABEL=PCINFO; do
    [ -d "$mp" ] || continue
    if is_mounted "$mp" && { [ -d "$mp/apks" ] || [ -d "$mp/drivers" ]; }; then
        mount --bind "$mp" "$USB_MNT" 2>/dev/null && break
    fi
done

# Fallback: resolve by label, then mount by device
if ! is_mounted "$USB_MNT"; then
    if [ -e /dev/disk/by-label/PCINFO ]; then
        DEV=$(readlink -f /dev/disk/by-label/PCINFO 2>/dev/null)
    elif command -v findfs >/dev/null 2>&1; then
        DEV=$(findfs LABEL=PCINFO 2>/dev/null)
    elif command -v blkid >/dev/null 2>&1; then
        DEV=$(blkid -L PCINFO 2>/dev/null)
        [ -n "$DEV" ] || DEV=$(blkid -t LABEL=PCINFO -o device 2>/dev/null | head -n 1)
    fi
    [ -n "$DEV" ] && mount -t vfat "$DEV" "$USB_MNT" 2>/dev/null || true
fi

if ! is_mounted "$USB_MNT"; then
    for DEV in /dev/sd[a-z][0-9] /dev/vd[a-z][0-9] /dev/mmcblk[0-9]p[0-9] /dev/nvme[0-9]n[0-9]p[0-9]; do
        [ -b "$DEV" ] || continue
        mount -t vfat "$DEV" "$USB_MNT" 2>/dev/null && break
    done
fi

# Install pre-downloaded .apk files directly (bypass APKINDEX lookup)
APK_DIR="$USB_MNT/apks/x86_64"
if is_mounted "$USB_MNT" && [ -d "$APK_DIR" ]; then
    pkgs=""
    for f in bash dialog smartmontools nvme-cli pciutils wireless-tools iw hdparm util-linux blkid dmidecode eudev; do
        found=$(find "$APK_DIR" -name "${f}-[0-9]*.apk" 2>/dev/null | head -1)
        [ -n "$found" ] && pkgs="$pkgs $found"
    done
    if [ -n "$pkgs" ]; then
        # shellcheck disable=SC2086
        apk add --allow-untrusted --force-non-repository --no-network $pkgs 2>/dev/null || true
    fi
fi

exit 0
SETUP_EOF
    chmod +x "$ovl_dir/etc/local.d/00-pcinfo-setup.start"

    dmidecode_apk=$(find "$WORK_DIR/apks/x86_64" -maxdepth 1 -name 'dmidecode-*.apk' | head -n 1)
    if [ -n "$dmidecode_apk" ]; then
        tar -xzf "$dmidecode_apk" -C "$ovl_dir" \
            --exclude='.SIGN.*' \
            --exclude='.PKGINFO' 2>/dev/null || \
            error "Failed to extract dmidecode into overlay"
        log "  Installed: dmidecode runtime"
    else
        error "Missing dmidecode APK in $WORK_DIR/apks/x86_64"
    fi

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

    if [ -f "$GPU_PCI_IDS_BUILD_FILE" ]; then
        cp "$GPU_PCI_IDS_BUILD_FILE" "$ovl_dir/opt/pcinfo/gpu_pci_ids.txt"
        log "  Installed: gpu_pci_ids.txt"
    else
        error "Missing generated GPU PCI ID database: $GPU_PCI_IDS_BUILD_FILE"
    fi

    if [ -f "$GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE" ]; then
        cp "$GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE" "$ovl_dir/opt/pcinfo/gpu_pci_subsystem_ids.txt"
        log "  Installed: gpu_pci_subsystem_ids.txt"
    else
        error "Missing generated GPU PCI subsystem database: $GPU_PCI_SUBSYSTEM_IDS_BUILD_FILE"
    fi

    if [ -f "$GPU_VRAM_HINTS_SOURCE_FILE" ]; then
        cp "$GPU_VRAM_HINTS_SOURCE_FILE" "$ovl_dir/opt/pcinfo/gpu_vram_hints.txt"
        log "  Installed: gpu_vram_hints.txt"
    fi

    # Symlink: /opt/pcinfo/menu.sh as entrypoint
    ln -sf /opt/pcinfo/menu.sh "$ovl_dir/opt/pcinfo/start"

    # Pack as apkovl tarball
    local ovl_tar="$WORK_DIR/pcinfo.apkovl.tar.gz"
    tar -czf "$ovl_tar" -C "$ovl_dir" . 2>/dev/null
    log "  apkovl created: $ovl_tar ($(du -sh "$ovl_tar" | cut -f1))"
    echo "$ovl_tar"
}

# ---- Step 6: Create EFI bootloader (grub-mkstandalone) ----
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

# ---- Step 7: Create FAT32 image with mtools ----
build_fat32_image() {
    local nb="$1"       # netboot dir
    local ovl_tar="$2"  # apkovl.tar.gz
    local efi_bin="$3"  # BOOTX64.EFI
    local image_mb

    log "=== Building FAT32 image ==="
    rm -f "$OUTPUT_IMG"

    image_mb=$(calc_image_size_mb "$ovl_tar" "$efi_bin")

    # Create blank image
    dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count=$image_mb status=progress 2>/dev/null
    log "  Created ${image_mb}MB blank image"

    # Format as FAT32 with volume label
    mformat -i "$OUTPUT_IMG" -F -v "$USB_LABEL" -T 65536 :: 2>/dev/null || \
    mformat -i "$OUTPUT_IMG" -F -v "$USB_LABEL" ::
    log "  Formatted as FAT32 (label: ${USB_LABEL})"

    # Create directory structure
    mmd -i "$OUTPUT_IMG" ::/EFI          2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/EFI/BOOT     2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/boot         2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/apks         2>/dev/null || true
    mmd -i "$OUTPUT_IMG" ::/apks/x86_64  2>/dev/null || true
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

    # Copy apks/ directory (base system + tools for diskless boot)
    local apk_count=0
    for apk in "$WORK_DIR/apks/x86_64/"*.apk; do
        [ -s "$apk" ] || continue
        mcopy -i "$OUTPUT_IMG" "$apk" ::/apks/x86_64/"$(basename "$apk")"
        apk_count=$((apk_count + 1))
    done
    if [ -s "$WORK_DIR/apks/x86_64/APKINDEX.tar.gz" ]; then
        mcopy -i "$OUTPUT_IMG" "$WORK_DIR/apks/x86_64/APKINDEX.tar.gz" ::/apks/x86_64/APKINDEX.tar.gz
    fi
    log "  apks/: $apk_count package(s) copied"

    # Copy offline GPU driver directories recursively with mtools only
    if [ -d "$GPU_DRIVERS_DIR" ]; then
        mcopy -s -n -i "$OUTPUT_IMG" \
            "$GPU_DRIVERS_DIR/nvidia" \
            "$GPU_DRIVERS_DIR/amd" \
            "$GPU_DRIVERS_DIR/intel" \
            ::/drivers/
        log "  drivers/: $(find "$GPU_DRIVERS_DIR" -name '*.apk' | wc -l) package(s) copied recursively"
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
    linuxefi  /boot/vmlinuz-lts modloop=/boot/modloop-lts modules=${BOOT_MODULES} quiet alpine_repo=/media/usb/apks,/media/sda/apks,/media/sdb/apks,/media/mmcblk0p1/apks,/media/LABEL=${USB_LABEL}/apks usbdelay=3
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
  APPEND modloop=/boot/modloop-lts modules=${BOOT_MODULES} quiet alpine_repo=/media/usb/apks,/media/sda/apks,/media/sdb/apks,/media/mmcblk0p1/apks,/media/LABEL=${USB_LABEL}/apks usbdelay=3

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

# ---- Step 8: Install syslinux BIOS bootloader ----
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
    build_apks_dir
    fetch_gpu_driver_apks
    build_gpu_pci_db

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
    log " Offline GPU driver APKs embedded from:"
    log "   $GPU_DRIVERS_DIR/nvidia"
    log "   $GPU_DRIVERS_DIR/amd"
    log "   $GPU_DRIVERS_DIR/intel"
    log ""
}

main "$@"
