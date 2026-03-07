#!/bin/sh
# pcinfo.sh - PC情報収集ツール for Tiny Core Linux
# BusyBox compatible shell script

# autologin 経由で直接起動された場合に PATH が未設定の可能性があるため明示
export PATH="/usr/local/sbin:/usr/local/bin:/apps/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
SEP='--------------------------------------------------------------------------------'

FBPRINT=/usr/local/bin/fbprint
FONT=/usr/share/consolefonts/unifont_ja.psf.gz
FB=/dev/fb0

# フレームバッファ描画が使えるか
use_fb() { [ -x "$FBPRINT" ] && [ -e "$FB" ]; }

# 画面クリア
cls() {
    printf '\033[2J\033[H'
}

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

kb_to_human() {
    kb="$1"
    if [ "$kb" -ge 1048576 ] 2>/dev/null; then
        printf "%.2f GB" "$(echo "$kb 1048576" | awk '{printf "%.2f", $1/$2}')"
    elif [ "$kb" -ge 1024 ] 2>/dev/null; then
        printf "%.2f MB" "$(echo "$kb 1024" | awk '{printf "%.2f", $1/$2}')"
    else
        echo "${kb} kB"
    fi
}

# ============================================================
# バナー
# ============================================================
show_banner() {
    cls
    printf "${BOLD}${CYAN}"
    echo " ____      ___        __          ____ _               _      "
    echo "|  _ \ ___|_ _|_ __  / _| ___    / ___| | __ _ ___ ___(_) ___ "
    echo "| |_) / __|| || '_ \| |_ / _ \  | |   | |/ _\` / __/ __| |/ __|"
    echo "|  __/ (__ | || | | |  _| (_) | | |___| | (_| \__ \__ \ | (__ "
    echo "|_|   \___|___|_| |_|_|  \___/   \____|_|\__,_|___/___/_|\___|"
    printf "${RESET}"
    echo "                                      Powered by Tiny Core Linux"
    echo ""
}

# ============================================================
# CPU
# ============================================================
show_cpu() {
    section "CPU"

    model=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ //')
    cores=$(grep 'cpu cores' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')
    threads=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    stepping=$(grep '^stepping' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')
    model_num=$(grep '^model' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')

    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]; then
        max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        max_mhz=$((max_khz / 1000))
    else
        max_mhz=$(grep 'cpu MHz' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' | cut -d'.' -f1)
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
# GPU デバイスIDルックアップ (pci.ids ベース)
# AMD: HD 3800 / RV670 以降, NVIDIA: GT200 / GTX280 以降, Intel Arc
# ============================================================
gpu_lookup() {
    case "${1}:${2}" in
        # ---------- AMD ----------
        0x1002:0x6640) echo "FirePro M6100" ;;
        0x1002:0x6641) echo "Radeon HD 8930M" ;;
        0x1002:0x6646) echo "Radeon R9 M280X / FirePro W6150M" ;;
        0x1002:0x6647) echo "Radeon R9 M270X/M280X" ;;
        0x1002:0x6649) echo "FirePro W5100" ;;
        0x1002:0x664d) echo "FirePro W5100 / Barco MXRT-5600" ;;
        0x1002:0x6650) echo "Bonaire" ;;
        0x1002:0x6651) echo "Bonaire" ;;
        0x1002:0x6658) echo "Radeon R7 260X/360" ;;
        0x1002:0x665c) echo "Radeon HD 7790/8770 / R7 360 / R9 260/360 OEM" ;;
        0x1002:0x665d) echo "Radeon R7 200 Series" ;;
        0x1002:0x665f) echo "Radeon R7 360 / R9 360 OEM" ;;
        0x1002:0x6660) echo "Radeon HD 8670A/8670M/8690M / R5 M330 / M430 / Radeon 520 Mobile" ;;
        0x1002:0x6663) echo "Radeon HD 8570A/8570M" ;;
        0x1002:0x6664) echo "Radeon R5 M240" ;;
        0x1002:0x6665) echo "Radeon R5 M230 / R7 M260DX / Radeon 520/610 Mobile" ;;
        0x1002:0x6667) echo "Radeon R5 M230" ;;
        0x1002:0x666f) echo "Radeon HD 8550M / R5 M230" ;;
        0x1002:0x6704) echo "FirePro V7900" ;;
        0x1002:0x6707) echo "FirePro V5900" ;;
        0x1002:0x6718) echo "Radeon HD 6970" ;;
        0x1002:0x6719) echo "Radeon HD 6950" ;;
        0x1002:0x671c) echo "Radeon HD 6990" ;;
        0x1002:0x671d) echo "Radeon HD 6990" ;;
        0x1002:0x671f) echo "Radeon HD 6930" ;;
        0x1002:0x6720) echo "Radeon HD 6970M/6990M" ;;
        0x1002:0x6738) echo "Radeon HD 6870" ;;
        0x1002:0x6739) echo "Radeon HD 6850" ;;
        0x1002:0x673e) echo "Radeon HD 6790" ;;
        0x1002:0x6740) echo "Radeon HD 6730M/6770M/7690M XT" ;;
        0x1002:0x6741) echo "Radeon HD 6630M/6650M/6750M/7670M/7690M" ;;
        0x1002:0x6742) echo "Radeon HD 6610M/7610M" ;;
        0x1002:0x6743) echo "Radeon E6760" ;;
        0x1002:0x6749) echo "FirePro V4900" ;;
        0x1002:0x674a) echo "FirePro V3900" ;;
        0x1002:0x6750) echo "Radeon HD 6650A/7650A" ;;
        0x1002:0x6751) echo "Radeon HD 7650A/7670A" ;;
        0x1002:0x6758) echo "Radeon HD 6670/7670" ;;
        0x1002:0x6759) echo "Radeon HD 6570/7570/8550 / R5 230" ;;
        0x1002:0x675b) echo "Radeon HD 7600 Series" ;;
        0x1002:0x675d) echo "Radeon HD 7570" ;;
        0x1002:0x675f) echo "Radeon HD 5570/6510/7510/8510" ;;
        0x1002:0x6760) echo "Radeon HD 6400M/7400M Series" ;;
        0x1002:0x6761) echo "Radeon HD 6430M" ;;
        0x1002:0x6763) echo "Radeon E6460" ;;
        0x1002:0x6764) echo "Radeon HD 6400M Series" ;;
        0x1002:0x6765) echo "Radeon HD 6400M Series" ;;
        0x1002:0x6766) echo "Caicos" ;;
        0x1002:0x6767) echo "Caicos" ;;
        0x1002:0x6768) echo "Caicos" ;;
        0x1002:0x6770) echo "Radeon HD 6450A/7450A" ;;
        0x1002:0x6771) echo "Radeon HD 8490 / R5 235X OEM" ;;
        0x1002:0x6772) echo "Radeon HD 7450A" ;;
        0x1002:0x6778) echo "Radeon HD 7470/8470 / R5 235/310 OEM" ;;
        0x1002:0x6779) echo "Radeon HD 6450/7450/8450 / R5 230 OEM" ;;
        0x1002:0x677b) echo "Radeon HD 7450" ;;
        0x1002:0x6780) echo "FirePro W9000" ;;
        0x1002:0x6784) echo "FirePro Series Graphics Adapter" ;;
        0x1002:0x6788) echo "FirePro Series Graphics Adapter" ;;
        0x1002:0x678a) echo "FirePro Series" ;;
        0x1002:0x6798) echo "Radeon HD 7970/8970 OEM / R9 280X" ;;
        0x1002:0x679a) echo "Radeon HD 7950/8950 OEM / R9 280" ;;
        0x1002:0x679b) echo "Radeon HD 7990/8990 OEM" ;;
        0x1002:0x679e) echo "Radeon HD 7870 XT" ;;
        0x1002:0x679f) echo "Tahiti" ;;
        0x1002:0x67a0) echo "FirePro W9100" ;;
        0x1002:0x67a1) echo "FirePro W8100" ;;
        0x1002:0x67a2) echo "Hawaii GL" ;;
        0x1002:0x67a8) echo "Hawaii" ;;
        0x1002:0x67a9) echo "Hawaii" ;;
        0x1002:0x67aa) echo "Hawaii" ;;
        0x1002:0x67b0) echo "Radeon R9 290X/390X" ;;
        0x1002:0x67b1) echo "Radeon R9 290/390" ;;
        0x1002:0x67b8) echo "Radeon R9 290X Engineering Sample" ;;
        0x1002:0x67b9) echo "Radeon R9 295X2" ;;
        0x1002:0x67be) echo "Hawaii LE" ;;
        0x1002:0x67c0) echo "Radeon Pro WX 7100 Mobile" ;;
        0x1002:0x67c2) echo "Radeon Pro V7300X / V7350x2" ;;
        0x1002:0x67c4) echo "Radeon Pro WX 7100" ;;
        0x1002:0x67c7) echo "Radeon Pro WX 5100" ;;
        0x1002:0x67ca) echo "Ellesmere [Polaris10]" ;;
        0x1002:0x67cc) echo "Ellesmere [Polaris10]" ;;
        0x1002:0x67cf) echo "Ellesmere [Polaris10]" ;;
        0x1002:0x67d0) echo "Radeon Pro V7300X / V7350x2" ;;
        0x1002:0x67d4) echo "Radeon Pro WX 7100 / Barco MXRT-8700" ;;
        0x1002:0x67d7) echo "Radeon Pro WX 5100 / Barco MXRT-6700" ;;
        0x1002:0x67df) echo "Radeon RX 470/480/570/570X/580/580X/590" ;;
        0x1002:0x67e0) echo "Radeon Pro WX 4170" ;;
        0x1002:0x67e1) echo "Baffin [Polaris11]" ;;
        0x1002:0x67e3) echo "Radeon Pro WX 4100" ;;
        0x1002:0x67e8) echo "Radeon Pro WX 4130/4150" ;;
        0x1002:0x67e9) echo "Baffin [Polaris11]" ;;
        0x1002:0x67eb) echo "Radeon Pro V5300X" ;;
        0x1002:0x67ef) echo "Radeon RX 460/560D / Pro 450/455/460/555/555X/560/560X" ;;
        0x1002:0x67ff) echo "Radeon RX 550 640SP / RX 560/560X" ;;
        0x1002:0x6800) echo "Radeon HD 7970M" ;;
        0x1002:0x6801) echo "Radeon HD 8970M" ;;
        0x1002:0x6802) echo "Wimbledon" ;;
        0x1002:0x6806) echo "Neptune" ;;
        0x1002:0x6808) echo "FirePro W7000" ;;
        0x1002:0x6809) echo "FirePro W5000" ;;
        0x1002:0x6810) echo "Radeon R7 370 / R9 270X/370X" ;;
        0x1002:0x6811) echo "Radeon R7 370 / R9 270/370 OEM" ;;
        0x1002:0x6816) echo "Pitcairn" ;;
        0x1002:0x6817) echo "Pitcairn" ;;
        0x1002:0x6818) echo "Radeon HD 7870 GHz Edition" ;;
        0x1002:0x6819) echo "Radeon HD 7850 / R7 265 / R9 270 1024SP" ;;
        0x1002:0x6820) echo "Radeon HD 8890M / R9 M275X/M375X" ;;
        0x1002:0x6821) echo "Radeon HD 8870M / R9 M270X/M370X" ;;
        0x1002:0x6822) echo "Radeon E8860" ;;
        0x1002:0x6823) echo "Radeon HD 8850M / R9 M265X" ;;
        0x1002:0x6825) echo "Radeon HD 7870M" ;;
        0x1002:0x6826) echo "Radeon HD 7700M Series" ;;
        0x1002:0x6827) echo "Radeon HD 7850M/8850M" ;;
        0x1002:0x6828) echo "FirePro W600" ;;
        0x1002:0x6829) echo "Cape Verde" ;;
        0x1002:0x682a) echo "Venus PRO" ;;
        0x1002:0x682b) echo "Radeon HD 8830M / R7 250 / R7 M465X" ;;
        0x1002:0x682c) echo "FirePro W4100" ;;
        0x1002:0x682d) echo "FirePro M4000" ;;
        0x1002:0x682f) echo "Radeon HD 7730M" ;;
        0x1002:0x6835) echo "Radeon R9 255 OEM" ;;
        0x1002:0x6837) echo "Radeon HD 7730/8730" ;;
        0x1002:0x683d) echo "Radeon HD 7770/8760 / R7 250X" ;;
        0x1002:0x683f) echo "Radeon HD 7750/8740 / R7 250E" ;;
        0x1002:0x6860) echo "Vega 10 [Instinct MI25/MI25x2/V340/V320]" ;;
        0x1002:0x6861) echo "Radeon PRO WX 9100" ;;
        0x1002:0x6862) echo "Radeon PRO SSG" ;;
        0x1002:0x6863) echo "Radeon Vega Frontier Edition" ;;
        0x1002:0x6864) echo "Radeon Pro V340/Instinct MI25x2" ;;
        0x1002:0x6867) echo "Radeon Pro Vega 56" ;;
        0x1002:0x6868) echo "Radeon PRO WX 8100/8200" ;;
        0x1002:0x6869) echo "Radeon Pro Vega 48" ;;
        0x1002:0x686a) echo "Vega 10 LEA" ;;
        0x1002:0x686b) echo "Radeon Pro Vega 64X" ;;
        0x1002:0x686c) echo "Vega 10 [Instinct MI25 MxGPU/MI25x2 MxGPU/V340 MxGPU/V340L MxGPU]" ;;
        0x1002:0x686d) echo "Vega 10 GLXTA" ;;
        0x1002:0x686e) echo "Vega 10 GLXLA" ;;
        0x1002:0x687f) echo "Radeon RX Vega 56/64" ;;
        0x1002:0x6880) echo "Radeon HD 6550M" ;;
        0x1002:0x6888) echo "FirePro V8800" ;;
        0x1002:0x6889) echo "FirePro V7800" ;;
        0x1002:0x688a) echo "FirePro V9800" ;;
        0x1002:0x688c) echo "Cypress XT GL [FireStream 9370]" ;;
        0x1002:0x688d) echo "Cypress PRO GL [FireStream 9350]" ;;
        0x1002:0x6898) echo "Radeon HD 5870" ;;
        0x1002:0x6899) echo "Radeon HD 5850" ;;
        0x1002:0x689b) echo "Radeon HD 6800 Series" ;;
        0x1002:0x689c) echo "Radeon HD 5970" ;;
        0x1002:0x689d) echo "Radeon HD 5970" ;;
        0x1002:0x689e) echo "Radeon HD 5830" ;;
        0x1002:0x68a0) echo "Mobility Radeon HD 5870" ;;
        0x1002:0x68a1) echo "Mobility Radeon HD 5850" ;;
        0x1002:0x68a8) echo "Radeon HD 6850M/6870M" ;;
        0x1002:0x68a9) echo "FirePro V5800" ;;
        0x1002:0x68b8) echo "Radeon HD 5770" ;;
        0x1002:0x68b9) echo "Radeon HD 5670 640SP Edition" ;;
        0x1002:0x68ba) echo "Radeon HD 6770" ;;
        0x1002:0x68be) echo "Radeon HD 5750" ;;
        0x1002:0x68bf) echo "Radeon HD 6750" ;;
        0x1002:0x68c0) echo "Mobility Radeon HD 5730 / 6570M" ;;
        0x1002:0x68c1) echo "Mobility Radeon HD 5650/5750 / 6530M/6550M" ;;
        0x1002:0x68c7) echo "Mobility Radeon HD 5570/6550A" ;;
        0x1002:0x68c8) echo "FirePro V4800" ;;
        0x1002:0x68c9) echo "FirePro V3800" ;;
        0x1002:0x68d8) echo "Radeon HD 5670/5690/5730" ;;
        0x1002:0x68d9) echo "Radeon HD 5550/5570/5630/6510/6610/7570" ;;
        0x1002:0x68da) echo "Radeon HD 5550/5570/5630/6390/6490/7570" ;;
        0x1002:0x68de) echo "Redwood" ;;
        0x1002:0x68e0) echo "Mobility Radeon HD 5430/5450/5470" ;;
        0x1002:0x68e1) echo "Mobility Radeon HD 5430" ;;
        0x1002:0x68e4) echo "Radeon HD 6370M/7370M" ;;
        0x1002:0x68e5) echo "Radeon HD 6330M" ;;
        0x1002:0x68e8) echo "Cedar" ;;
        0x1002:0x68e9) echo "ATI FirePro (FireGL) Graphics Adapter" ;;
        0x1002:0x68f1) echo "FirePro 2460" ;;
        0x1002:0x68f2) echo "FirePro 2270" ;;
        0x1002:0x68f8) echo "Radeon HD 7300 Series" ;;
        0x1002:0x68f9) echo "Radeon HD 5000/6000/7350/8350 Series" ;;
        0x1002:0x68fa) echo "Radeon HD 7350/8350 / R5 220" ;;
        0x1002:0x68fe) echo "Cedar LE" ;;
        0x1002:0x6900) echo "Radeon R7 M260/M265 / M340/M360 / M440/M445 / 530/535 / 620/625 Mobile" ;;
        0x1002:0x6901) echo "Radeon R5 M255" ;;
        0x1002:0x6907) echo "Radeon R5 M315" ;;
        0x1002:0x6920) echo "Radeon R9 M395/ M395X Mac Edition" ;;
        0x1002:0x6921) echo "Radeon R9 M295X / M390X" ;;
        0x1002:0x6929) echo "FirePro S7150" ;;
        0x1002:0x692b) echo "FirePro W7100" ;;
        0x1002:0x692f) echo "FirePro S7150V" ;;
        0x1002:0x6930) echo "Radeon R9 380 4GB" ;;
        0x1002:0x6938) echo "Radeon R9 380X / R9 M295X" ;;
        0x1002:0x6939) echo "Radeon R9 285/380" ;;
        0x1002:0x693b) echo "FirePro W7100 / Barco MXRT-7600" ;;
        0x1002:0x694c) echo "Radeon RX Vega M GH" ;;
        0x1002:0x694e) echo "Radeon RX Vega M GL" ;;
        0x1002:0x694f) echo "Radeon Pro WX Vega M GL" ;;
        0x1002:0x699f) echo "Radeon 540/540X/550/550X / RX 540X/550/550X" ;;
        0x1002:0x6fdf) echo "Radeon RX 580 2048SP" ;;
        0x1002:0x7310) echo "Radeon Pro W5700X" ;;
        0x1002:0x7312) echo "Radeon Pro W5700" ;;
        0x1002:0x7314) echo "Navi 10 USB" ;;
        0x1002:0x7319) echo "Radeon Pro 5700 XT" ;;
        0x1002:0x731b) echo "Radeon Pro 5700" ;;
        0x1002:0x731e) echo "TDC-150" ;;
        0x1002:0x731f) echo "Radeon RX 5600 OEM/5600 XT / 5700/5700 XT" ;;
        0x1002:0x7340) echo "Radeon RX 5500/5500M / Pro 5300/5500M" ;;
        0x1002:0x7341) echo "Radeon Pro W5500" ;;
        0x1002:0x7347) echo "Radeon Pro W5500M" ;;
        0x1002:0x734f) echo "Radeon Pro W5300M" ;;
        0x1002:0x73a1) echo "Radeon Pro V620" ;;
        0x1002:0x73a2) echo "Radeon Pro W6900X" ;;
        0x1002:0x73a3) echo "Radeon PRO W6800" ;;
        0x1002:0x73a4) echo "Navi 21 USB" ;;
        0x1002:0x73a5) echo "Radeon RX 6950 XT" ;;
        0x1002:0x73ab) echo "Radeon Pro W6800X/Radeon Pro W6800X Duo" ;;
        0x1002:0x73ae) echo "Radeon Pro V620 MxGPU" ;;
        0x1002:0x73af) echo "Radeon RX 6900 XT" ;;
        0x1002:0x73bf) echo "Radeon RX 6800/6800 XT / 6900 XT" ;;
        0x1002:0x73c3) echo "Navi 22" ;;
        0x1002:0x73c4) echo "Navi 22 USB" ;;
        0x1002:0x73ce) echo "Navi 22-XL SRIOV MxGPU" ;;
        0x1002:0x73df) echo "Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT" ;;
        0x1002:0x73e0) echo "Navi 23" ;;
        0x1002:0x73e1) echo "Radeon PRO W6600M" ;;
        0x1002:0x73e3) echo "Radeon PRO W6600" ;;
        0x1002:0x73e4) echo "Navi 23 USB" ;;
        0x1002:0x73ef) echo "Radeon RX 6650 XT / 6700S / 6800S" ;;
        0x1002:0x73f0) echo "Radeon RX 7600M XT" ;;
        0x1002:0x73ff) echo "Radeon RX 6600/6600 XT/6600M" ;;
        0x1002:0x7446) echo "Navi 31 USB" ;;
        0x1002:0x7448) echo "Radeon Pro W7900" ;;
        0x1002:0x744a) echo "Radeon Pro W7900 Dual Slot" ;;
        0x1002:0x744b) echo "Radeon Pro W7900D" ;;
        0x1002:0x744c) echo "Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M" ;;
        0x1002:0x745e) echo "Radeon Pro W7800" ;;
        0x1002:0x7460) echo "AMD Radeon PRO V710" ;;
        0x1002:0x7461) echo "AMD Radeon PRO V710" ;;
        0x1002:0x7470) echo "Radeon PRO W7700" ;;
        0x1002:0x747e) echo "Radeon RX 7700 XT / 7800 XT" ;;
        0x1002:0x7480) echo "Radeon RX 7600/7600 XT/7600M XT/7600S/7700S / PRO W7600" ;;
        0x1002:0x7481) echo "Radeon Graphics" ;;
        0x1002:0x7483) echo "Radeon RX 7600M/7600M XT" ;;
        0x1002:0x7487) echo "Radeon Graphics" ;;
        0x1002:0x7489) echo "Radeon Pro W7500" ;;
        0x1002:0x748b) echo "Radeon Graphics" ;;
        0x1002:0x9440) echo "Radeon HD 4870" ;;
        0x1002:0x9441) echo "Radeon HD 4870 X2" ;;
        0x1002:0x9442) echo "Radeon HD 4850" ;;
        0x1002:0x9443) echo "Radeon HD 4850 X2" ;;
        0x1002:0x9444) echo "FirePro V8750" ;;
        0x1002:0x9446) echo "FirePro V7760" ;;
        0x1002:0x944a) echo "Mobility Radeon HD 4850" ;;
        0x1002:0x944b) echo "Mobility Radeon HD 4850 X2" ;;
        0x1002:0x944c) echo "Radeon HD 4830" ;;
        0x1002:0x944e) echo "Radeon HD 4710" ;;
        0x1002:0x9450) echo "RV770 GL [FireStream 9270]" ;;
        0x1002:0x9452) echo "RV770 GL [FireStream 9250]" ;;
        0x1002:0x9456) echo "FirePro V8700" ;;
        0x1002:0x945a) echo "Mobility Radeon HD 4870" ;;
        0x1002:0x9460) echo "Radeon HD 4890" ;;
        0x1002:0x9462) echo "Radeon HD 4860" ;;
        0x1002:0x946a) echo "FirePro M7750" ;;
        0x1002:0x9480) echo "Mobility Radeon HD 4650/5165" ;;
        0x1002:0x9488) echo "Mobility Radeon HD 4670" ;;
        0x1002:0x9489) echo "RV730/M96 GL [Mobility FireGL V5725]" ;;
        0x1002:0x9490) echo "Radeon HD 4670" ;;
        0x1002:0x9491) echo "Radeon E4690" ;;
        0x1002:0x9495) echo "Radeon HD 4600 AGP Series" ;;
        0x1002:0x9498) echo "Radeon HD 4650" ;;
        0x1002:0x949c) echo "FirePro V7750" ;;
        0x1002:0x949e) echo "FirePro V5700" ;;
        0x1002:0x949f) echo "FirePro V3750" ;;
        0x1002:0x94a0) echo "Mobility Radeon HD 4830" ;;
        0x1002:0x94a1) echo "Mobility Radeon HD 4860" ;;
        0x1002:0x94a3) echo "FirePro M7740" ;;
        0x1002:0x94b3) echo "Radeon HD 4770" ;;
        0x1002:0x94b4) echo "Radeon HD 4750" ;;
        0x1002:0x94c1) echo "Radeon HD 2400 PRO/XT" ;;
        0x1002:0x94c3) echo "Radeon HD 2400 PRO" ;;
        0x1002:0x94c4) echo "Radeon HD 2400 PRO AGP" ;;
        0x1002:0x94c5) echo "Radeon HD 2400 LE" ;;
        0x1002:0x94c7) echo "Radeon HD 2350" ;;
        0x1002:0x94c8) echo "Mobility Radeon HD 2400 XT" ;;
        0x1002:0x94c9) echo "Mobility Radeon HD 2400" ;;
        0x1002:0x94cb) echo "Radeon E2400" ;;
        0x1002:0x94cc) echo "Radeon HD 2400 PRO PCI" ;;
        0x1002:0x9500) echo "Radeon HD 3850 X2" ;;
        0x1002:0x9501) echo "Radeon HD 3870" ;;
        0x1002:0x9504) echo "Mobility Radeon HD 3850" ;;
        0x1002:0x9505) echo "Radeon HD 3690/3850" ;;
        0x1002:0x9506) echo "Mobility Radeon HD 3850 X2" ;;
        0x1002:0x9507) echo "Radeon HD 3830" ;;
        0x1002:0x9508) echo "Mobility Radeon HD 3870" ;;
        0x1002:0x9509) echo "Mobility Radeon HD 3870 X2" ;;
        0x1002:0x950f) echo "Radeon HD 3870 X2" ;;
        0x1002:0x9511) echo "RV670 GL [FireGL V7700]" ;;
        0x1002:0x9513) echo "Radeon HD 3850 X2" ;;
        0x1002:0x9515) echo "Radeon HD 3850 AGP" ;;
        0x1002:0x9519) echo "RV670 GL [FireStream 9170]" ;;
        0x1002:0x9540) echo "Radeon HD 4550" ;;
        0x1002:0x954f) echo "Radeon HD 4350/4550" ;;
        0x1002:0x9552) echo "Mobility Radeon HD 4330/4350/4550" ;;
        0x1002:0x9553) echo "Mobility Radeon HD 4530/4570/5145/530v/540v/545v" ;;
        0x1002:0x9555) echo "Mobility Radeon HD 4350/4550/530v/540v/545v / FirePro RG220" ;;
        0x1002:0x9557) echo "FirePro RG220" ;;
        0x1002:0x955f) echo "Mobility Radeon HD 4330" ;;
        0x1002:0x9580) echo "Radeon HD 2600 PRO" ;;
        0x1002:0x9581) echo "Mobility Radeon HD 2600" ;;
        0x1002:0x9583) echo "Mobility Radeon HD 2600 XT/2700" ;;
        0x1002:0x9586) echo "Radeon HD 2600 XT AGP" ;;
        0x1002:0x9587) echo "Radeon HD 2600 PRO AGP" ;;
        0x1002:0x9588) echo "Radeon HD 2600 XT" ;;
        0x1002:0x9589) echo "Radeon HD 2600 PRO" ;;
        0x1002:0x958a) echo "Radeon HD 2600 X2" ;;
        0x1002:0x958b) echo "Mobility Radeon HD 2600 XT" ;;
        0x1002:0x958c) echo "RV630 GL [FireGL V5600]" ;;
        0x1002:0x958d) echo "RV630 GL [FireGL V3600]" ;;
        0x1002:0x9591) echo "Mobility Radeon HD 3650" ;;
        0x1002:0x9593) echo "Mobility Radeon HD 3670" ;;
        0x1002:0x9595) echo "RV635/M86 GL [Mobility FireGL V5700]" ;;
        0x1002:0x9596) echo "Radeon HD 3650 AGP" ;;
        0x1002:0x9597) echo "Radeon HD 3650 AGP" ;;
        0x1002:0x9598) echo "Radeon HD 3650/3750/4570/4580" ;;
        0x1002:0x9599) echo "Radeon HD 3650 AGP" ;;
        0x1002:0x95c0) echo "Radeon HD 3470" ;;
        0x1002:0x95c2) echo "Mobility Radeon HD 3410/3430" ;;
        0x1002:0x95c4) echo "Mobility Radeon HD 3450/3470" ;;
        0x1002:0x95c5) echo "Radeon HD 3450" ;;
        0x1002:0x95c6) echo "Radeon HD 3450 AGP" ;;
        0x1002:0x95c9) echo "Radeon HD 3450 PCI" ;;
        0x1002:0x95cc) echo "FirePro V3700" ;;
        0x1002:0x95cd) echo "FirePro 2450" ;;
        0x1002:0x95cf) echo "FirePro 2260" ;;
        # ---------- NVIDIA ----------
        0x10de:0x05b8) echo "NF200 PCIe 2.0 switch for GTX 295" ;;
        0x10de:0x05be) echo "NF200 PCIe 2.0 switch for Quadro Plex S4 / Tesla S870 / Tesla S1070 / Tesla S2050" ;;
        0x10de:0x05e0) echo "GeForce GTX 295" ;;
        0x10de:0x05e1) echo "GeForce GTX 280" ;;
        0x10de:0x05e2) echo "GeForce GTX 260" ;;
        0x10de:0x05e3) echo "GeForce GTX 285" ;;
        0x10de:0x05e6) echo "GeForce GTX 275" ;;
        0x10de:0x05e7) echo "Tesla C1060 / M1060" ;;
        0x10de:0x05ea) echo "GeForce GTX 260" ;;
        0x10de:0x05eb) echo "GeForce GTX 295" ;;
        0x10de:0x05ed) echo "Quadro Plex 2200 D2" ;;
        0x10de:0x05f1) echo "GeForce GTX 280" ;;
        0x10de:0x05f2) echo "GeForce GTX 260" ;;
        0x10de:0x05f8) echo "Quadro Plex 2200 S4" ;;
        0x10de:0x05f9) echo "Quadro CX" ;;
        0x10de:0x05fd) echo "Quadro FX 5800" ;;
        0x10de:0x05fe) echo "Quadro FX 4800" ;;
        0x10de:0x05ff) echo "Quadro FX 3800" ;;
        0x10de:0x0600) echo "GeForce 8800 GTS 512" ;;
        0x10de:0x0601) echo "GeForce 9800 GT" ;;
        0x10de:0x0602) echo "GeForce 8800 GT" ;;
        0x10de:0x0603) echo "GeForce GT 230 OEM" ;;
        0x10de:0x0604) echo "GeForce 9800 GX2" ;;
        0x10de:0x0605) echo "GeForce 9800 GT" ;;
        0x10de:0x0606) echo "GeForce 8800 GS" ;;
        0x10de:0x0607) echo "GeForce GTS 240" ;;
        0x10de:0x0608) echo "GeForce 9800M GTX" ;;
        0x10de:0x0609) echo "GeForce 8800M GTS" ;;
        0x10de:0x060a) echo "GeForce GTX 280M" ;;
        0x10de:0x060b) echo "GeForce 9800M GT" ;;
        0x10de:0x060c) echo "GeForce 8800M GTX" ;;
        0x10de:0x060d) echo "GeForce 8800 GS" ;;
        0x10de:0x060f) echo "GeForce GTX 285M" ;;
        0x10de:0x0610) echo "GeForce 9600 GSO" ;;
        0x10de:0x0611) echo "GeForce 8800 GT" ;;
        0x10de:0x0612) echo "GeForce 9800 GTX / 9800 GTX+" ;;
        0x10de:0x0613) echo "GeForce 9800 GTX+" ;;
        0x10de:0x0614) echo "GeForce 9800 GT" ;;
        0x10de:0x0615) echo "GeForce GTS 250" ;;
        0x10de:0x0617) echo "GeForce 9800M GTX" ;;
        0x10de:0x0618) echo "GeForce GTX 260M" ;;
        0x10de:0x0619) echo "Quadro FX 4700 X2" ;;
        0x10de:0x061a) echo "Quadro FX 3700" ;;
        0x10de:0x061b) echo "Quadro VX 200" ;;
        0x10de:0x061c) echo "Quadro FX 3600M" ;;
        0x10de:0x061d) echo "Quadro FX 2800M" ;;
        0x10de:0x061e) echo "Quadro FX 3700M" ;;
        0x10de:0x061f) echo "Quadro FX 3800M" ;;
        0x10de:0x0620) echo "GeForce 9800 GT" ;;
        0x10de:0x0621) echo "GeForce GT 230" ;;
        0x10de:0x0622) echo "GeForce 9600 GT" ;;
        0x10de:0x0623) echo "GeForce 9600 GS" ;;
        0x10de:0x0624) echo "GeForce 9600 GT Green Edition" ;;
        0x10de:0x0625) echo "GeForce 9600 GSO 512" ;;
        0x10de:0x0626) echo "GeForce GT 130" ;;
        0x10de:0x0627) echo "GeForce GT 140" ;;
        0x10de:0x0628) echo "GeForce 9800M GTS" ;;
        0x10de:0x062a) echo "GeForce 9700M GTS" ;;
        0x10de:0x062b) echo "GeForce 9800M GS" ;;
        0x10de:0x062c) echo "GeForce 9800M GTS" ;;
        0x10de:0x062d) echo "GeForce 9600 GT" ;;
        0x10de:0x062e) echo "GeForce 9600 GT" ;;
        0x10de:0x062f) echo "GeForce 9800 S" ;;
        0x10de:0x0630) echo "GeForce 9600 GT" ;;
        0x10de:0x0631) echo "GeForce GTS 160M" ;;
        0x10de:0x0632) echo "GeForce GTS 150M" ;;
        0x10de:0x0633) echo "GeForce GT 220" ;;
        0x10de:0x0635) echo "GeForce 9600 GSO" ;;
        0x10de:0x0637) echo "GeForce 9600 GT" ;;
        0x10de:0x0638) echo "Quadro FX 1800" ;;
        0x10de:0x063a) echo "Quadro FX 2700M" ;;
        0x10de:0x063f) echo "GeForce 9600 GE" ;;
        0x10de:0x0640) echo "GeForce 9500 GT" ;;
        0x10de:0x0641) echo "GeForce 9400 GT" ;;
        0x10de:0x0643) echo "GeForce 9500 GT" ;;
        0x10de:0x0644) echo "GeForce 9500 GS" ;;
        0x10de:0x0645) echo "GeForce 9500 GS" ;;
        0x10de:0x0646) echo "GeForce GT 120" ;;
        0x10de:0x0647) echo "GeForce 9600M GT" ;;
        0x10de:0x0648) echo "GeForce 9600M GS" ;;
        0x10de:0x0649) echo "GeForce 9600M GT" ;;
        0x10de:0x064a) echo "GeForce 9700M GT" ;;
        0x10de:0x064b) echo "GeForce 9500M G" ;;
        0x10de:0x064c) echo "GeForce 9650M GT" ;;
        0x10de:0x064e) echo "GeForce 9600 GSO / 9800 GT" ;;
        0x10de:0x0651) echo "GeForce G 110M" ;;
        0x10de:0x0652) echo "GeForce GT 130M" ;;
        0x10de:0x0653) echo "GeForce GT 120M" ;;
        0x10de:0x0654) echo "GeForce GT 220M" ;;
        0x10de:0x0655) echo "GeForce GT 120 Mac Edition" ;;
        0x10de:0x0656) echo "GeForce GT 120 Mac Edition" ;;
        0x10de:0x0658) echo "Quadro FX 380" ;;
        0x10de:0x0659) echo "Quadro FX 580" ;;
        0x10de:0x065a) echo "Quadro FX 1700M" ;;
        0x10de:0x065b) echo "GeForce 9400 GT" ;;
        0x10de:0x065c) echo "Quadro FX 770M" ;;
        0x10de:0x065d) echo "GeForce 9500 GA / 9600 GT / GTS 250" ;;
        0x10de:0x065f) echo "GeForce G210" ;;
        0x10de:0x06c0) echo "GeForce GTX 480" ;;
        0x10de:0x06c4) echo "GeForce GTX 465" ;;
        0x10de:0x06ca) echo "GeForce GTX 480M" ;;
        0x10de:0x06cb) echo "GeForce GTX 480" ;;
        0x10de:0x06cd) echo "GeForce GTX 470" ;;
        0x10de:0x06d1) echo "Tesla C2050 / C2070" ;;
        0x10de:0x06d2) echo "Tesla M2070" ;;
        0x10de:0x06d8) echo "Quadro 6000" ;;
        0x10de:0x06d9) echo "Quadro 5000" ;;
        0x10de:0x06da) echo "Quadro 5000M" ;;
        0x10de:0x06dc) echo "Quadro 6000" ;;
        0x10de:0x06dd) echo "Quadro 4000" ;;
        0x10de:0x06de) echo "Tesla T20 Processor" ;;
        0x10de:0x06df) echo "Tesla M2070-Q" ;;
        0x10de:0x06e0) echo "GeForce 9300 GE" ;;
        0x10de:0x06e1) echo "GeForce 9300 GS" ;;
        0x10de:0x06e2) echo "GeForce 8400" ;;
        0x10de:0x06e3) echo "GeForce 8300 GS" ;;
        0x10de:0x06e4) echo "GeForce 8400 GS Rev. 2" ;;
        0x10de:0x06e5) echo "GeForce 9300M GS" ;;
        0x10de:0x06e6) echo "GeForce G 100" ;;
        0x10de:0x06e7) echo "GeForce 9300 SE" ;;
        0x10de:0x06e8) echo "GeForce 9200M GS" ;;
        0x10de:0x06e9) echo "GeForce 9300M GS" ;;
        0x10de:0x06ea) echo "Quadro NVS 150M" ;;
        0x10de:0x06eb) echo "Quadro NVS 160M" ;;
        0x10de:0x06ec) echo "GeForce G 105M" ;;
        0x10de:0x06ed) echo "GeForce 9600 GT / 9800 GT" ;;
        0x10de:0x06ee) echo "GeForce 9600 GT / 9800 GT / GT 240" ;;
        0x10de:0x06ef) echo "GeForce G 103M" ;;
        0x10de:0x06f1) echo "GeForce G 105M" ;;
        0x10de:0x06f8) echo "Quadro NVS 420" ;;
        0x10de:0x06f9) echo "Quadro FX 370 LP" ;;
        0x10de:0x06fa) echo "Quadro NVS 450" ;;
        0x10de:0x06fb) echo "Quadro FX 370M" ;;
        0x10de:0x06fd) echo "Quadro NVS 295" ;;
        0x10de:0x0dc0) echo "GeForce GT 440" ;;
        0x10de:0x0dc4) echo "GeForce GTS 450" ;;
        0x10de:0x0dc5) echo "GeForce GTS 450 OEM" ;;
        0x10de:0x0dc6) echo "GeForce GTS 450 OEM" ;;
        0x10de:0x0dcd) echo "GeForce GT 555M" ;;
        0x10de:0x0dce) echo "GeForce GT 555M" ;;
        0x10de:0x0dd1) echo "GeForce GTX 460M" ;;
        0x10de:0x0dd2) echo "GeForce GT 445M" ;;
        0x10de:0x0dd3) echo "GeForce GT 435M" ;;
        0x10de:0x0dd6) echo "GeForce GT 550M" ;;
        0x10de:0x0dd8) echo "Quadro 2000" ;;
        0x10de:0x0dda) echo "Quadro 2000M" ;;
        0x10de:0x0de0) echo "GeForce GT 440" ;;
        0x10de:0x0de1) echo "GeForce GT 430" ;;
        0x10de:0x0de2) echo "GeForce GT 420" ;;
        0x10de:0x0de3) echo "GeForce GT 635M" ;;
        0x10de:0x0de4) echo "GeForce GT 520" ;;
        0x10de:0x0de5) echo "GeForce GT 530" ;;
        0x10de:0x0de7) echo "GeForce GT 610" ;;
        0x10de:0x0de8) echo "GeForce GT 620M" ;;
        0x10de:0x0de9) echo "GeForce GT 620M/630M/635M/640M LE" ;;
        0x10de:0x0dea) echo "GeForce 610M" ;;
        0x10de:0x0deb) echo "GeForce GT 555M" ;;
        0x10de:0x0dec) echo "GeForce GT 525M" ;;
        0x10de:0x0ded) echo "GeForce GT 520M" ;;
        0x10de:0x0dee) echo "GeForce GT 415M" ;;
        0x10de:0x0df0) echo "GeForce GT 425M" ;;
        0x10de:0x0df1) echo "GeForce GT 420M" ;;
        0x10de:0x0df2) echo "GeForce GT 435M" ;;
        0x10de:0x0df3) echo "GeForce GT 420M" ;;
        0x10de:0x0df4) echo "GeForce GT 540M" ;;
        0x10de:0x0df5) echo "GeForce GT 525M" ;;
        0x10de:0x0df6) echo "GeForce GT 550M" ;;
        0x10de:0x0df7) echo "GeForce GT 520M" ;;
        0x10de:0x0df8) echo "Quadro 600" ;;
        0x10de:0x0df9) echo "Quadro 500M" ;;
        0x10de:0x0dfa) echo "Quadro 1000M" ;;
        0x10de:0x0fc0) echo "GeForce GT 640 OEM" ;;
        0x10de:0x0fc1) echo "GeForce GT 640" ;;
        0x10de:0x0fc2) echo "GeForce GT 630 OEM" ;;
        0x10de:0x0fc5) echo "GeForce GT 1030" ;;
        0x10de:0x0fc6) echo "GeForce GTX 650" ;;
        0x10de:0x0fc8) echo "GeForce GT 740" ;;
        0x10de:0x0fc9) echo "GeForce GT 730" ;;
        0x10de:0x0fcc) echo "GeForce GT 720" ;;
        0x10de:0x0fcd) echo "GeForce GT 755M" ;;
        0x10de:0x0fce) echo "GeForce GT 640M LE" ;;
        0x10de:0x0fd1) echo "GeForce GT 650M" ;;
        0x10de:0x0fd2) echo "GeForce GT 640M" ;;
        0x10de:0x0fd3) echo "GeForce GT 640M LE" ;;
        0x10de:0x0fd4) echo "GeForce GTX 660M" ;;
        0x10de:0x0fd5) echo "GeForce GT 650M Mac Edition" ;;
        0x10de:0x0fd7) echo "GK107-GTX" ;;
        0x10de:0x0fd8) echo "GeForce GT 640M Mac Edition" ;;
        0x10de:0x0fd9) echo "GeForce GT 645M" ;;
        0x10de:0x0fdf) echo "GeForce GT 740M" ;;
        0x10de:0x0fe0) echo "GeForce GTX 660M Mac Edition" ;;
        0x10de:0x0fe1) echo "GeForce GT 730M" ;;
        0x10de:0x0fe2) echo "GeForce GT 745M" ;;
        0x10de:0x0fe3) echo "GeForce GT 745M" ;;
        0x10de:0x0fe4) echo "GeForce GT 750M" ;;
        0x10de:0x0fe5) echo "GeForce K340 USM" ;;
        0x10de:0x0fe9) echo "GeForce GT 750M Mac Edition" ;;
        0x10de:0x0fea) echo "GeForce GT 755M Mac Edition" ;;
        0x10de:0x0fec) echo "GeForce 710A" ;;
        0x10de:0x0fed) echo "GeForce 820M" ;;
        0x10de:0x0fee) echo "GeForce 810M" ;;
        0x10de:0x0ff3) echo "Quadro K420" ;;
        0x10de:0x0ff5) echo "GRID K1 Tesla USM" ;;
        0x10de:0x0ff6) echo "Quadro K1100M" ;;
        0x10de:0x0ff8) echo "Quadro K500M" ;;
        0x10de:0x0ff9) echo "Quadro K2000D" ;;
        0x10de:0x0ffa) echo "Quadro K600" ;;
        0x10de:0x0ffb) echo "Quadro K2000M" ;;
        0x10de:0x0ffc) echo "Quadro K1000M" ;;
        0x10de:0x0ffe) echo "Quadro K2000" ;;
        0x10de:0x0fff) echo "Quadro 410" ;;
        0x10de:0x1001) echo "GeForce GTX TITAN Z" ;;
        0x10de:0x1003) echo "GeForce GTX Titan LE" ;;
        0x10de:0x1004) echo "GeForce GTX 780" ;;
        0x10de:0x1005) echo "GeForce GTX TITAN" ;;
        0x10de:0x1007) echo "GeForce GTX 780 Rev. 2" ;;
        0x10de:0x1008) echo "GeForce GTX 780 Ti 6GB" ;;
        0x10de:0x100a) echo "GeForce GTX 780 Ti" ;;
        0x10de:0x100c) echo "GeForce GTX TITAN Black" ;;
        0x10de:0x101e) echo "Tesla K20X" ;;
        0x10de:0x101f) echo "Tesla K20" ;;
        0x10de:0x1020) echo "Tesla K20X" ;;
        0x10de:0x1021) echo "Tesla K20Xm" ;;
        0x10de:0x1022) echo "Tesla K20c" ;;
        0x10de:0x1023) echo "Tesla K40m" ;;
        0x10de:0x1024) echo "Tesla K40c" ;;
        0x10de:0x1026) echo "Tesla K20s" ;;
        0x10de:0x1027) echo "Tesla K40st" ;;
        0x10de:0x1028) echo "Tesla K20m" ;;
        0x10de:0x1029) echo "Tesla K40s" ;;
        0x10de:0x102a) echo "Tesla K40t" ;;
        0x10de:0x102d) echo "Tesla K80" ;;
        0x10de:0x102e) echo "Tesla K40d" ;;
        0x10de:0x102f) echo "Tesla Stella Solo" ;;
        0x10de:0x103a) echo "Quadro K6000" ;;
        0x10de:0x103c) echo "Quadro K5200" ;;
        0x10de:0x103f) echo "Tesla Stella SXM" ;;
        0x10de:0x1040) echo "GeForce GT 520" ;;
        0x10de:0x1042) echo "GeForce 510" ;;
        0x10de:0x1048) echo "GeForce 605" ;;
        0x10de:0x1049) echo "GeForce GT 620 OEM" ;;
        0x10de:0x104a) echo "GeForce GT 610" ;;
        0x10de:0x104b) echo "GeForce GT 625 OEM" ;;
        0x10de:0x104c) echo "GeForce GT 705" ;;
        0x10de:0x104d) echo "GeForce GT 710" ;;
        0x10de:0x1050) echo "GeForce GT 520M" ;;
        0x10de:0x1051) echo "GeForce GT 520MX" ;;
        0x10de:0x1052) echo "GeForce GT 520M" ;;
        0x10de:0x1054) echo "GeForce 410M" ;;
        0x10de:0x1055) echo "GeForce 410M" ;;
        0x10de:0x1057) echo "Quadro NVS 4200M" ;;
        0x10de:0x1058) echo "GeForce 610M" ;;
        0x10de:0x1059) echo "GeForce 610M" ;;
        0x10de:0x105a) echo "GeForce 610M" ;;
        0x10de:0x105b) echo "GeForce 705M" ;;
        0x10de:0x1080) echo "GeForce GTX 580" ;;
        0x10de:0x1081) echo "GeForce GTX 570" ;;
        0x10de:0x1082) echo "GeForce GTX 560 Ti OEM" ;;
        0x10de:0x1084) echo "GeForce GTX 560 OEM" ;;
        0x10de:0x1086) echo "GeForce GTX 570 Rev. 2" ;;
        0x10de:0x1087) echo "GeForce GTX 560 Ti 448 Cores" ;;
        0x10de:0x1088) echo "GeForce GTX 590" ;;
        0x10de:0x1089) echo "GeForce GTX 580 Rev. 2" ;;
        0x10de:0x108b) echo "GeForce GTX 580" ;;
        0x10de:0x108e) echo "Tesla C2090" ;;
        0x10de:0x1091) echo "Tesla M2090" ;;
        0x10de:0x1094) echo "Tesla M2075" ;;
        0x10de:0x1096) echo "Tesla C2050 / C2075" ;;
        0x10de:0x109a) echo "Quadro 5010M" ;;
        0x10de:0x109b) echo "Quadro 7000" ;;
        0x10de:0x1180) echo "GeForce GTX 680" ;;
        0x10de:0x1182) echo "GeForce GTX 760 Ti" ;;
        0x10de:0x1183) echo "GeForce GTX 660 Ti" ;;
        0x10de:0x1184) echo "GeForce GTX 770" ;;
        0x10de:0x1185) echo "GeForce GTX 660 OEM" ;;
        0x10de:0x1186) echo "GeForce GTX 660 Ti" ;;
        0x10de:0x1187) echo "GeForce GTX 760" ;;
        0x10de:0x1188) echo "GeForce GTX 690" ;;
        0x10de:0x1189) echo "GeForce GTX 670" ;;
        0x10de:0x118b) echo "GRID K2 GeForce USM" ;;
        0x10de:0x118e) echo "GeForce GTX 760 OEM" ;;
        0x10de:0x118f) echo "Tesla K10" ;;
        0x10de:0x1191) echo "GeForce GTX 760 Rev. 2" ;;
        0x10de:0x1193) echo "GeForce GTX 760 Ti OEM" ;;
        0x10de:0x1194) echo "Tesla K8" ;;
        0x10de:0x1195) echo "GeForce GTX 660 Rev. 2" ;;
        0x10de:0x1198) echo "GeForce GTX 880M" ;;
        0x10de:0x1199) echo "GeForce GTX 870M" ;;
        0x10de:0x119a) echo "GeForce GTX 860M" ;;
        0x10de:0x119d) echo "GeForce GTX 775M Mac Edition" ;;
        0x10de:0x119e) echo "GeForce GTX 780M Mac Edition" ;;
        0x10de:0x119f) echo "GeForce GTX 780M" ;;
        0x10de:0x11a0) echo "GeForce GTX 680M" ;;
        0x10de:0x11a1) echo "GeForce GTX 670MX" ;;
        0x10de:0x11a2) echo "GeForce GTX 675MX Mac Edition" ;;
        0x10de:0x11a3) echo "GeForce GTX 680MX" ;;
        0x10de:0x11a7) echo "GeForce GTX 675MX" ;;
        0x10de:0x11a8) echo "Quadro K5100M" ;;
        0x10de:0x11a9) echo "GeForce GTX 870M" ;;
        0x10de:0x11b1) echo "GRID K2 Tesla USM" ;;
        0x10de:0x11b4) echo "Quadro K4200" ;;
        0x10de:0x11b6) echo "Quadro K3100M" ;;
        0x10de:0x11b7) echo "Quadro K4100M" ;;
        0x10de:0x11b8) echo "Quadro K5100M" ;;
        0x10de:0x11ba) echo "Quadro K5000" ;;
        0x10de:0x11bb) echo "Quadro 4100" ;;
        0x10de:0x11bc) echo "Quadro K5000M" ;;
        0x10de:0x11bd) echo "Quadro K4000M" ;;
        0x10de:0x11be) echo "Quadro K3000M" ;;
        0x10de:0x11c0) echo "GeForce GTX 660" ;;
        0x10de:0x11c2) echo "GeForce GTX 650 Ti Boost" ;;
        0x10de:0x11c3) echo "GeForce GTX 650 Ti OEM" ;;
        0x10de:0x11c4) echo "GeForce GTX 645 OEM" ;;
        0x10de:0x11c5) echo "GeForce GT 740" ;;
        0x10de:0x11c6) echo "GeForce GTX 650 Ti" ;;
        0x10de:0x11c7) echo "GeForce GTX 750 Ti" ;;
        0x10de:0x11c8) echo "GeForce GTX 650 OEM" ;;
        0x10de:0x11cb) echo "GeForce GT 740" ;;
        0x10de:0x11e0) echo "GeForce GTX 770M" ;;
        0x10de:0x11e1) echo "GeForce GTX 765M" ;;
        0x10de:0x11e2) echo "GeForce GTX 765M" ;;
        0x10de:0x11e3) echo "GeForce GTX 760M" ;;
        0x10de:0x11fa) echo "Quadro K4000" ;;
        0x10de:0x11fc) echo "Quadro K2100M" ;;
        0x10de:0x1200) echo "GeForce GTX 560 Ti" ;;
        0x10de:0x1201) echo "GeForce GTX 560" ;;
        0x10de:0x1202) echo "GeForce GTX 560 Ti OEM" ;;
        0x10de:0x1203) echo "GeForce GTX 460 SE v2" ;;
        0x10de:0x1205) echo "GeForce GTX 460 v2" ;;
        0x10de:0x1206) echo "GeForce GTX 555" ;;
        0x10de:0x1207) echo "GeForce GT 645 OEM" ;;
        0x10de:0x1208) echo "GeForce GTX 560 SE" ;;
        0x10de:0x1210) echo "GeForce GTX 570M" ;;
        0x10de:0x1211) echo "GeForce GTX 580M" ;;
        0x10de:0x1212) echo "GeForce GTX 675M" ;;
        0x10de:0x1213) echo "GeForce GTX 670M" ;;
        0x10de:0x1380) echo "GeForce GTX 750 Ti" ;;
        0x10de:0x1381) echo "GeForce GTX 750" ;;
        0x10de:0x1382) echo "GeForce GTX 745" ;;
        0x10de:0x1390) echo "GeForce 845M" ;;
        0x10de:0x1391) echo "GeForce GTX 850M" ;;
        0x10de:0x1392) echo "GeForce GTX 860M" ;;
        0x10de:0x1393) echo "GeForce 840M" ;;
        0x10de:0x1398) echo "GeForce 845M" ;;
        0x10de:0x1399) echo "GeForce 945M" ;;
        0x10de:0x139a) echo "GeForce GTX 950M" ;;
        0x10de:0x139b) echo "GeForce GTX 960M" ;;
        0x10de:0x139c) echo "GeForce 940M" ;;
        0x10de:0x139d) echo "GeForce GTX 750 Ti" ;;
        0x10de:0x13b0) echo "Quadro M2000M" ;;
        0x10de:0x13b1) echo "Quadro M1000M" ;;
        0x10de:0x13b2) echo "Quadro M600M" ;;
        0x10de:0x13b3) echo "Quadro K2200M" ;;
        0x10de:0x13b4) echo "Quadro M620 Mobile" ;;
        0x10de:0x13b6) echo "Quadro M1200 Mobile" ;;
        0x10de:0x13ba) echo "Quadro K2200" ;;
        0x10de:0x13bb) echo "Quadro K620" ;;
        0x10de:0x13bc) echo "Quadro K1200" ;;
        0x10de:0x13bd) echo "Tesla M10" ;;
        0x10de:0x13c0) echo "GeForce GTX 980" ;;
        0x10de:0x13c2) echo "GeForce GTX 970" ;;
        0x10de:0x13d7) echo "GeForce GTX 980M" ;;
        0x10de:0x13d8) echo "GeForce GTX 960 OEM / 970M" ;;
        0x10de:0x13d9) echo "GeForce GTX 965M" ;;
        0x10de:0x13da) echo "GeForce GTX 980 Mobile" ;;
        0x10de:0x13e7) echo "GeForce GTX 980 Engineering Sample" ;;
        0x10de:0x13f0) echo "Quadro M5000" ;;
        0x10de:0x13f1) echo "Quadro M4000" ;;
        0x10de:0x13f2) echo "Tesla M60" ;;
        0x10de:0x13f3) echo "Tesla M6" ;;
        0x10de:0x13f8) echo "Quadro M5000M / M5000 SE" ;;
        0x10de:0x13f9) echo "Quadro M4000M" ;;
        0x10de:0x13fa) echo "Quadro M3000M" ;;
        0x10de:0x13fb) echo "Quadro M5500" ;;
        0x10de:0x17c2) echo "GeForce GTX TITAN X" ;;
        0x10de:0x17c8) echo "GeForce GTX 980 Ti" ;;
        0x10de:0x17f0) echo "Quadro M6000" ;;
        0x10de:0x17f1) echo "Quadro M6000 24GB" ;;
        0x10de:0x17fd) echo "Tesla M40" ;;
        0x10de:0x1b00) echo "GP102 [TITAN X Pascal]" ;;
        0x10de:0x1b01) echo "GeForce GTX 1080 Ti 10GB" ;;
        0x10de:0x1b02) echo "GP102 [TITAN Xp]" ;;
        0x10de:0x1b06) echo "GeForce GTX 1080 Ti" ;;
        0x10de:0x1b30) echo "Quadro P6000" ;;
        0x10de:0x1b38) echo "Tesla P40" ;;
        0x10de:0x1b39) echo "Tesla P10" ;;
        0x10de:0x1b80) echo "GeForce GTX 1080" ;;
        0x10de:0x1b81) echo "GeForce GTX 1070" ;;
        0x10de:0x1b82) echo "GeForce GTX 1070 Ti" ;;
        0x10de:0x1b83) echo "GeForce GTX 1060 6GB" ;;
        0x10de:0x1b84) echo "GeForce GTX 1060 3GB" ;;
        0x10de:0x1ba0) echo "GeForce GTX 1080 Mobile" ;;
        0x10de:0x1ba1) echo "GeForce GTX 1070 Mobile" ;;
        0x10de:0x1ba2) echo "GeForce GTX 1070 Mobile" ;;
        0x10de:0x1bad) echo "GeForce GTX 1070 Engineering Sample" ;;
        0x10de:0x1bb0) echo "Quadro P5000" ;;
        0x10de:0x1bb1) echo "Quadro P4000" ;;
        0x10de:0x1bb3) echo "Tesla P4" ;;
        0x10de:0x1bb4) echo "Tesla P6" ;;
        0x10de:0x1bb5) echo "Quadro P5200 Mobile" ;;
        0x10de:0x1bb6) echo "Quadro P5000 Mobile" ;;
        0x10de:0x1bb7) echo "Quadro P4000 Mobile" ;;
        0x10de:0x1bb8) echo "Quadro P3000 Mobile" ;;
        0x10de:0x1bb9) echo "Quadro P4200 Mobile" ;;
        0x10de:0x1bbb) echo "Quadro P3200 Mobile" ;;
        0x10de:0x1be0) echo "GeForce GTX 1080 Mobile" ;;
        0x10de:0x1be1) echo "GeForce GTX 1070 Mobile" ;;
        0x10de:0x1c02) echo "GeForce GTX 1060 3GB" ;;
        0x10de:0x1c03) echo "GeForce GTX 1060 6GB" ;;
        0x10de:0x1c04) echo "GeForce GTX 1060 5GB" ;;
        0x10de:0x1c06) echo "GeForce GTX 1060 6GB Rev. 2" ;;
        0x10de:0x1c20) echo "GeForce GTX 1060 Mobile" ;;
        0x10de:0x1c21) echo "GeForce GTX 1050 Ti Mobile" ;;
        0x10de:0x1c22) echo "GeForce GTX 1050 Mobile" ;;
        0x10de:0x1c23) echo "GeForce GTX 1060 Mobile Rev. 2" ;;
        0x10de:0x1c30) echo "Quadro P2000" ;;
        0x10de:0x1c31) echo "Quadro P2200" ;;
        0x10de:0x1c35) echo "Quadro P2000 Mobile / DRIVE PX 2 AutoChauffeur" ;;
        0x10de:0x1c60) echo "GeForce GTX 1060 Mobile 6GB" ;;
        0x10de:0x1c61) echo "GeForce GTX 1050 Ti Mobile" ;;
        0x10de:0x1c62) echo "GeForce GTX 1050 Mobile" ;;
        0x10de:0x1c81) echo "GeForce GTX 1050" ;;
        0x10de:0x1c82) echo "GeForce GTX 1050 Ti" ;;
        0x10de:0x1c83) echo "GeForce GTX 1050 3GB" ;;
        0x10de:0x1c8c) echo "GeForce GTX 1050 Ti Mobile" ;;
        0x10de:0x1c8d) echo "GeForce GTX 1050 Mobile" ;;
        0x10de:0x1c8f) echo "GeForce GTX 1050 Ti Max-Q" ;;
        0x10de:0x1c90) echo "GeForce MX150" ;;
        0x10de:0x1c91) echo "GeForce GTX 1050 3 GB Max-Q" ;;
        0x10de:0x1c92) echo "GeForce GTX 1050 Mobile" ;;
        0x10de:0x1c94) echo "GeForce MX350" ;;
        0x10de:0x1c96) echo "GeForce MX350" ;;
        0x10de:0x1cb1) echo "Quadro P1000" ;;
        0x10de:0x1cb2) echo "Quadro P600" ;;
        0x10de:0x1cb3) echo "Quadro P400" ;;
        0x10de:0x1cb6) echo "Quadro P620" ;;
        0x10de:0x1cba) echo "Quadro P2000 Mobile" ;;
        0x10de:0x1cbb) echo "Quadro P1000 Mobile" ;;
        0x10de:0x1cbc) echo "Quadro P600 Mobile" ;;
        0x10de:0x1cbd) echo "Quadro P620" ;;
        0x10de:0x1ccc) echo "GeForce GTX 1050 Ti Mobile" ;;
        0x10de:0x1ccd) echo "GeForce GTX 1050 Mobile" ;;
        0x10de:0x1cfa) echo "Quadro P2000" ;;
        0x10de:0x1cfb) echo "Quadro P1000" ;;
        0x10de:0x1d01) echo "GeForce GT 1030" ;;
        0x10de:0x1d02) echo "GeForce GT 1010" ;;
        0x10de:0x1d10) echo "GeForce MX150" ;;
        0x10de:0x1d11) echo "GeForce MX230" ;;
        0x10de:0x1d12) echo "GeForce MX150" ;;
        0x10de:0x1d13) echo "GeForce MX250" ;;
        0x10de:0x1d16) echo "GeForce MX330" ;;
        0x10de:0x1d33) echo "Quadro P500 Mobile" ;;
        0x10de:0x1d34) echo "Quadro P520" ;;
        0x10de:0x1d52) echo "GeForce MX250" ;;
        0x10de:0x1d56) echo "GeForce MX330" ;;
        0x10de:0x1e02) echo "TITAN RTX" ;;
        0x10de:0x1e03) echo "GeForce RTX 2080 Ti 12GB" ;;
        0x10de:0x1e04) echo "GeForce RTX 2080 Ti" ;;
        0x10de:0x1e07) echo "GeForce RTX 2080 Ti Rev. A" ;;
        0x10de:0x1e2d) echo "GeForce RTX 2080 Ti Engineering Sample" ;;
        0x10de:0x1e2e) echo "GeForce RTX 2080 Ti 12GB Engineering Sample" ;;
        0x10de:0x1e30) echo "Quadro RTX 6000/8000" ;;
        0x10de:0x1e35) echo "Tesla T10" ;;
        0x10de:0x1e36) echo "Quadro RTX 6000" ;;
        0x10de:0x1e37) echo "Tesla T10 16GB / GRID RTX T10-2/T10-4/T10-8" ;;
        0x10de:0x1e38) echo "Tesla T40 24GB" ;;
        0x10de:0x1e78) echo "Quadro RTX 6000/8000" ;;
        0x10de:0x1e81) echo "GeForce RTX 2080 SUPER" ;;
        0x10de:0x1e82) echo "GeForce RTX 2080" ;;
        0x10de:0x1e84) echo "GeForce RTX 2070 SUPER" ;;
        0x10de:0x1e87) echo "GeForce RTX 2080 Rev. A" ;;
        0x10de:0x1e89) echo "GeForce RTX 2060" ;;
        0x10de:0x1e90) echo "GeForce RTX 2080 Mobile" ;;
        0x10de:0x1e91) echo "GeForce RTX 2070 SUPER Mobile / Max-Q" ;;
        0x10de:0x1e93) echo "GeForce RTX 2080 SUPER Mobile / Max-Q" ;;
        0x10de:0x1eae) echo "GeForce GTX 2080 Engineering Sample" ;;
        0x10de:0x1eb0) echo "Quadro RTX 5000" ;;
        0x10de:0x1eb1) echo "Quadro RTX 4000" ;;
        0x10de:0x1eb5) echo "Quadro RTX 5000 Mobile / Max-Q" ;;
        0x10de:0x1eb6) echo "Quadro RTX 4000 Mobile / Max-Q" ;;
        0x10de:0x1eb8) echo "Tesla T4" ;;
        0x10de:0x1ec2) echo "GeForce RTX 2070 SUPER" ;;
        0x10de:0x1ec7) echo "GeForce RTX 2070 SUPER" ;;
        0x10de:0x1ed0) echo "GeForce RTX 2080 Mobile" ;;
        0x10de:0x1ed1) echo "GeForce RTX 2070 SUPER Mobile / Max-Q" ;;
        0x10de:0x1ed3) echo "GeForce RTX 2080 SUPER Mobile / Max-Q" ;;
        0x10de:0x1ef5) echo "Quadro RTX 5000 Mobile Refresh" ;;
        0x10de:0x1f02) echo "GeForce RTX 2070" ;;
        0x10de:0x1f03) echo "GeForce RTX 2060 12GB" ;;
        0x10de:0x1f06) echo "GeForce RTX 2060 SUPER" ;;
        0x10de:0x1f07) echo "GeForce RTX 2070 Rev. A" ;;
        0x10de:0x1f08) echo "GeForce RTX 2060 Rev. A" ;;
        0x10de:0x1f09) echo "GeForce GTX 1660 SUPER" ;;
        0x10de:0x1f0a) echo "GeForce GTX 1650" ;;
        0x10de:0x1f10) echo "GeForce RTX 2070 Mobile" ;;
        0x10de:0x1f11) echo "GeForce RTX 2060 Mobile" ;;
        0x10de:0x1f12) echo "GeForce RTX 2060 Max-Q" ;;
        0x10de:0x1f14) echo "GeForce RTX 2070 Mobile / Max-Q Refresh" ;;
        0x10de:0x1f15) echo "GeForce RTX 2060 Mobile" ;;
        0x10de:0x1f36) echo "Quadro RTX 3000 Mobile / Max-Q" ;;
        0x10de:0x1f42) echo "GeForce RTX 2060 SUPER" ;;
        0x10de:0x1f47) echo "GeForce RTX 2060 SUPER" ;;
        0x10de:0x1f50) echo "GeForce RTX 2070 Mobile / Max-Q" ;;
        0x10de:0x1f51) echo "GeForce RTX 2060 Mobile" ;;
        0x10de:0x1f54) echo "GeForce RTX 2070 Mobile" ;;
        0x10de:0x1f55) echo "GeForce RTX 2060 Mobile" ;;
        0x10de:0x1f76) echo "Quadro RTX 3000 Mobile Refresh" ;;
        0x10de:0x1f82) echo "GeForce GTX 1650" ;;
        0x10de:0x1f83) echo "GeForce GTX 1630" ;;
        0x10de:0x1f91) echo "GeForce GTX 1650 Mobile / Max-Q" ;;
        0x10de:0x1f92) echo "GeForce GTX 1650 Mobile" ;;
        0x10de:0x1f94) echo "GeForce GTX 1650 Mobile" ;;
        0x10de:0x1f95) echo "GeForce GTX 1650 Ti Mobile" ;;
        0x10de:0x1f96) echo "GeForce GTX 1650 Mobile / Max-Q" ;;
        0x10de:0x1f97) echo "GeForce MX450" ;;
        0x10de:0x1f98) echo "GeForce MX450" ;;
        0x10de:0x1f99) echo "GeForce GTX 1650 Mobile / Max-Q" ;;
        0x10de:0x1f9c) echo "GeForce MX450" ;;
        0x10de:0x1f9d) echo "GeForce GTX 1650 Mobile / Max-Q" ;;
        0x10de:0x1f9f) echo "GeForce MX550" ;;
        0x10de:0x1fa0) echo "GeForce MX550" ;;
        0x10de:0x1fb0) echo "Quadro T1000 Mobile" ;;
        0x10de:0x1fb2) echo "Quadro T400 Mobile" ;;
        0x10de:0x1fb8) echo "Quadro T2000 Mobile / Max-Q" ;;
        0x10de:0x1fb9) echo "Quadro T1000 Mobile" ;;
        0x10de:0x1fbb) echo "Quadro T500 Mobile" ;;
        0x10de:0x1fd9) echo "GeForce GTX 1650 Mobile Refresh" ;;
        0x10de:0x1fdd) echo "GeForce GTX 1650 Mobile Refresh" ;;
        0x10de:0x1ff9) echo "Quadro T1000 Mobile" ;;
        0x10de:0x2182) echo "GeForce GTX 1660 Ti" ;;
        0x10de:0x2184) echo "GeForce GTX 1660" ;;
        0x10de:0x2187) echo "GeForce GTX 1650 SUPER" ;;
        0x10de:0x2188) echo "GeForce GTX 1650" ;;
        0x10de:0x2191) echo "GeForce GTX 1660 Ti Mobile" ;;
        0x10de:0x2192) echo "GeForce GTX 1650 Ti Mobile" ;;
        0x10de:0x21c4) echo "GeForce GTX 1660 SUPER" ;;
        0x10de:0x21d1) echo "GeForce GTX 1660 Ti Mobile" ;;
        0x10de:0x2203) echo "GeForce RTX 3090 Ti" ;;
        0x10de:0x2204) echo "GeForce RTX 3090" ;;
        0x10de:0x2205) echo "GeForce RTX 3080 Ti 20GB" ;;
        0x10de:0x2206) echo "GeForce RTX 3080" ;;
        0x10de:0x2207) echo "GeForce RTX 3070 Ti" ;;
        0x10de:0x2208) echo "GeForce RTX 3080 Ti" ;;
        0x10de:0x220a) echo "GeForce RTX 3080 12GB" ;;
        0x10de:0x2216) echo "GeForce RTX 3080 Lite Hash Rate" ;;
        0x10de:0x222b) echo "GeForce RTX 3090 Engineering Sample" ;;
        0x10de:0x222f) echo "GeForce RTX 3080 11GB / 12GB Engineering Sample" ;;
        0x10de:0x2230) echo "RTX A6000" ;;
        0x10de:0x2231) echo "RTX A5000" ;;
        0x10de:0x2232) echo "RTX A4500" ;;
        0x10de:0x2233) echo "RTX A5500" ;;
        0x10de:0x2414) echo "GeForce RTX 3060 Ti" ;;
        0x10de:0x2420) echo "GeForce RTX 3080 Ti Mobile" ;;
        0x10de:0x2438) echo "RTX A5500 Laptop GPU" ;;
        0x10de:0x2460) echo "GeForce RTX 3080 Ti Laptop GPU" ;;
        0x10de:0x2482) echo "GeForce RTX 3070 Ti" ;;
        0x10de:0x2484) echo "GeForce RTX 3070" ;;
        0x10de:0x2486) echo "GeForce RTX 3060 Ti" ;;
        0x10de:0x2487) echo "GeForce RTX 3060" ;;
        0x10de:0x2488) echo "GeForce RTX 3070 Lite Hash Rate" ;;
        0x10de:0x2489) echo "GeForce RTX 3060 Ti Lite Hash Rate" ;;
        0x10de:0x248c) echo "GeForce RTX 3070 Ti" ;;
        0x10de:0x248d) echo "GeForce RTX 3070" ;;
        0x10de:0x248e) echo "GeForce RTX 3060 Ti" ;;
        0x10de:0x249c) echo "GeForce RTX 3080 Mobile / Max-Q 8GB/16GB" ;;
        0x10de:0x249d) echo "GeForce RTX 3070 Mobile / Max-Q" ;;
        0x10de:0x24a0) echo "Geforce RTX 3070 Ti Laptop GPU" ;;
        0x10de:0x24ac) echo "GeForce RTX 30x0 Engineering Sample" ;;
        0x10de:0x24ad) echo "GeForce RTX 3060 Engineering Sample" ;;
        0x10de:0x24af) echo "GeForce RTX 3070 Engineering Sample" ;;
        0x10de:0x24b0) echo "RTX A4000" ;;
        0x10de:0x24b1) echo "RTX A4000H" ;;
        0x10de:0x24b6) echo "RTX A5000 Mobile" ;;
        0x10de:0x24b7) echo "RTX A4000 Mobile" ;;
        0x10de:0x24b8) echo "RTX A3000 Mobile" ;;
        0x10de:0x24b9) echo "RTX A3000 12GB Laptop GPU" ;;
        0x10de:0x24ba) echo "RTX A4500 Laptop GPU" ;;
        0x10de:0x24bb) echo "RTX A3000 Laptop GPU" ;;
        0x10de:0x24bf) echo "GeForce RTX 3070 Engineering Sample" ;;
        0x10de:0x24c7) echo "GeForce RTX 3060 8GB" ;;
        0x10de:0x24c8) echo "GeForce RTX 3070 GDDR6X" ;;
        0x10de:0x24c9) echo "GeForce RTX 3060 Ti GDDR6X" ;;
        0x10de:0x24dc) echo "GeForce RTX 3080 Mobile / Max-Q 8GB/16GB" ;;
        0x10de:0x24dd) echo "GeForce RTX 3070 Mobile / Max-Q" ;;
        0x10de:0x24e0) echo "Geforce RTX 3070 Ti Laptop GPU" ;;
        0x10de:0x24fa) echo "RTX A4500 Embedded GPU " ;;
        0x10de:0x2501) echo "GeForce RTX 3060" ;;
        0x10de:0x2503) echo "GeForce RTX 3060" ;;
        0x10de:0x2504) echo "GeForce RTX 3060 Lite Hash Rate" ;;
        0x10de:0x2507) echo "Geforce RTX 3050" ;;
        0x10de:0x2508) echo "GeForce RTX 3050 OEM" ;;
        0x10de:0x2509) echo "GeForce RTX 3060 12GB Rev. 2" ;;
        0x10de:0x2520) echo "GeForce RTX 3060 Mobile / Max-Q" ;;
        0x10de:0x2521) echo "GeForce RTX 3060 Laptop GPU" ;;
        0x10de:0x2523) echo "GeForce RTX 3050 Ti Mobile / Max-Q" ;;
        0x10de:0x252f) echo "GeForce RTX 3060 Engineering Sample" ;;
        0x10de:0x2531) echo "RTX A2000" ;;
        0x10de:0x2544) echo "GeForce RTX 3060" ;;
        0x10de:0x2560) echo "GeForce RTX 3060 Mobile / Max-Q" ;;
        0x10de:0x2561) echo "GeForce RTX 3060 Laptop GPU" ;;
        0x10de:0x2563) echo "GeForce RTX 3050 Ti Mobile / Max-Q" ;;
        0x10de:0x2571) echo "RTX A2000 12GB" ;;
        0x10de:0x2582) echo "GeForce RTX 3050 8GB" ;;
        0x10de:0x2583) echo "GeForce RTX 3050 4GB" ;;
        0x10de:0x2584) echo "GeForce RTX 3050 6GB" ;;
        0x10de:0x25a0) echo "GeForce RTX 3050 Ti Mobile" ;;
        0x10de:0x25a2) echo "GeForce RTX 3050 Mobile" ;;
        0x10de:0x25a5) echo "GeForce RTX 3050 Mobile" ;;
        0x10de:0x25a6) echo "GeForce MX570" ;;
        0x10de:0x25a7) echo "GeForce MX570" ;;
        0x10de:0x25a9) echo "GeForce RTX 2050" ;;
        0x10de:0x25aa) echo "GeForce MX570 A" ;;
        0x10de:0x25ab) echo "GeForce RTX 3050 4GB Laptop GPU" ;;
        0x10de:0x25ac) echo "GeForce RTX 3050 6GB Laptop GPU" ;;
        0x10de:0x25ad) echo "GeForce RTX 2050" ;;
        0x10de:0x25af) echo "GeForce RTX 3050 Engineering Sample" ;;
        0x10de:0x25b0) echo "RTX A1000" ;;
        0x10de:0x25b2) echo "RTX A400" ;;
        0x10de:0x25b5) echo "RTX A4 Mobile" ;;
        0x10de:0x25b8) echo "RTX A2000 Mobile" ;;
        0x10de:0x25b9) echo "RTX A1000 Laptop GPU" ;;
        0x10de:0x25ba) echo "RTX A2000 8GB Laptop GPU" ;;
        0x10de:0x25bb) echo "RTX A500 Laptop GPU" ;;
        0x10de:0x25bc) echo "RTX A1000 6GB Laptop GPU" ;;
        0x10de:0x25bd) echo "RTX A500 Laptop GPU" ;;
        0x10de:0x25e0) echo "GeForce RTX 3050 Ti Mobile" ;;
        0x10de:0x25e2) echo "GeForce RTX 3050 Mobile" ;;
        0x10de:0x25e5) echo "GeForce RTX 3050 Mobile" ;;
        0x10de:0x25ec) echo "GeForce RTX 3050 6GB Laptop GPU" ;;
        0x10de:0x25ed) echo "GeForce RTX 2050" ;;
        0x10de:0x25f9) echo "RTX A1000 Embedded GPU " ;;
        0x10de:0x25fa) echo "RTX A2000 Embedded GPU" ;;
        0x10de:0x25fb) echo "RTX A500 Embedded GPU" ;;
        0x10de:0x2681) echo "RTX TITAN Ada" ;;
        0x10de:0x2684) echo "GeForce RTX 4090" ;;
        0x10de:0x2685) echo "GeForce RTX 4090 D" ;;
        0x10de:0x2689) echo "GeForce RTX 4070 Ti SUPER" ;;
        0x10de:0x26b1) echo "RTX 6000 Ada Generation" ;;
        0x10de:0x26b2) echo "RTX 5000 Ada Generation" ;;
        0x10de:0x26b3) echo "RTX 5880 Ada Generation" ;;
        0x10de:0x2702) echo "GeForce RTX 4080 SUPER" ;;
        0x10de:0x2703) echo "GeForce RTX 4080 SUPER" ;;
        0x10de:0x2704) echo "GeForce RTX 4080" ;;
        0x10de:0x2705) echo "GeForce RTX 4070 Ti SUPER" ;;
        0x10de:0x2709) echo "GeForce RTX 4070" ;;
        0x10de:0x2717) echo "GeForce RTX 4090 Laptop GPU" ;;
        0x10de:0x2730) echo "RTX 5000 Ada Generation Laptop GPU" ;;
        0x10de:0x2757) echo "GeForce RTX 4090 Laptop GPU" ;;
        0x10de:0x2770) echo "RTX 5000 Ada Generation Embedded GPU" ;;
        0x10de:0x2782) echo "GeForce RTX 4070 Ti" ;;
        0x10de:0x2783) echo "GeForce RTX 4070 SUPER" ;;
        0x10de:0x2786) echo "GeForce RTX 4070" ;;
        0x10de:0x2788) echo "GeForce RTX 4060 Ti" ;;
        0x10de:0x27a0) echo "GeForce RTX 4080 Max-Q / Mobile" ;;
        0x10de:0x27b0) echo "RTX 4000 SFF Ada Generation" ;;
        0x10de:0x27b1) echo "RTX 4500 Ada Generation" ;;
        0x10de:0x27b2) echo "RTX 4000 Ada Generation" ;;
        0x10de:0x27ba) echo "RTX 4000 Ada Generation Laptop GPU" ;;
        0x10de:0x27bb) echo "RTX 3500 Ada Generation Laptop GPU" ;;
        0x10de:0x27e0) echo "GeForce RTX 4080 Max-Q / Mobile" ;;
        0x10de:0x27fa) echo "RTX 4000 Ada Generation Embedded GPU" ;;
        0x10de:0x27fb) echo "RTX 3500 Ada Generation Embedded GPU" ;;
        0x10de:0x2803) echo "GeForce RTX 4060 Ti" ;;
        0x10de:0x2805) echo "GeForce RTX 4060 Ti 16GB" ;;
        0x10de:0x2808) echo "GeForce RTX 4060" ;;
        0x10de:0x2820) echo "GeForce RTX 4070 Max-Q / Mobile" ;;
        0x10de:0x2822) echo "GeForce RTX 3050 A Laptop GPU" ;;
        0x10de:0x2838) echo "RTX 3000 Ada Generation Laptop GPU" ;;
        0x10de:0x2860) echo "GeForce RTX 4070 Max-Q / Mobile" ;;
        0x10de:0x2878) echo "RTX 3000 Ada Generation Embedded GPU" ;;
        0x10de:0x2882) echo "GeForce RTX 4060" ;;
        0x10de:0x28a0) echo "GeForce RTX 4060 Max-Q / Mobile" ;;
        0x10de:0x28a1) echo "GeForce RTX 4050 Max-Q / Mobile" ;;
        0x10de:0x28a3) echo "GeForce RTX 3050 A Laptop GPU" ;;
        0x10de:0x28b0) echo "RTX 2000 / 2000E Ada Generation" ;;
        0x10de:0x28b8) echo "RTX 2000 Ada Generation Laptop GPU" ;;
        0x10de:0x28b9) echo "RTX 1000 Ada Generation Laptop GPU" ;;
        0x10de:0x28ba) echo "RTX 500 Ada Generation Laptop GPU" ;;
        0x10de:0x28bb) echo "RTX 500 Ada Generation Laptop GPU" ;;
        0x10de:0x28e0) echo "GeForce RTX 4060 Max-Q / Mobile" ;;
        0x10de:0x28e1) echo "GeForce RTX 4050 Max-Q / Mobile" ;;
        0x10de:0x28e3) echo "GeForce RTX 3050 A Laptop GPU" ;;
        0x10de:0x28f8) echo "RTX 2000 Ada Generation Embedded GPU" ;;
        # ---------- Intel Arc ----------
        0x8086:0x0201) echo "Arctic Sound" ;;
        0x8086:0x5690) echo "Arc A770M" ;;
        0x8086:0x5691) echo "Arc A730M" ;;
        0x8086:0x5692) echo "Arc A550M" ;;
        0x8086:0x5693) echo "Arc A370M" ;;
        0x8086:0x5694) echo "Arc A350M" ;;
        0x8086:0x5696) echo "Arc A570M" ;;
        0x8086:0x5697) echo "Arc A530M" ;;
        0x8086:0x5698) echo "Arc Xe Graphics" ;;
        0x8086:0x56a0) echo "Arc A770" ;;
        0x8086:0x56a1) echo "Arc A750" ;;
        0x8086:0x56a2) echo "Arc A580" ;;
        0x8086:0x56a3) echo "Arc Xe Graphics" ;;
        0x8086:0x56a4) echo "Arc Xe Graphics" ;;
        0x8086:0x56a5) echo "Arc A380" ;;
        0x8086:0x56a6) echo "Arc A310" ;;
        0x8086:0x56a7) echo "Arc Xe Graphics" ;;
        0x8086:0x56a8) echo "Arc Xe Graphics" ;;
        0x8086:0x56a9) echo "Arc Xe Graphics" ;;
        0x8086:0x56b0) echo "Arc Pro A30M" ;;
        0x8086:0x56b1) echo "Arc Pro A40/A50" ;;
        0x8086:0x56b2) echo "Arc Pro A60M" ;;
        0x8086:0x56b3) echo "Arc Pro A60" ;;
        0x8086:0x56ba) echo "Arc A380E" ;;
        0x8086:0x56bb) echo "Arc A310E" ;;
        0x8086:0x56bc) echo "Arc A370E" ;;
        0x8086:0x56bd) echo "Arc A350E" ;;
        0x8086:0x56be) echo "Arc A750E" ;;
        0x8086:0x56bf) echo "Arc A580E" ;;
        0x8086:0x64a0) echo "Intel Arc Graphics 130V / 140V" ;;
        0x8086:0x7d51) echo "Arc Pro 130T/140T" ;;
        0x8086:0x7d55) echo "Intel Arc Graphics" ;;
        0x8086:0xb080) echo "Arc B390" ;;
        0x8086:0xb081) echo "Arc B370" ;;
        0x8086:0xb082) echo "Arc B390" ;;
        0x8086:0xb083) echo "Arc B370" ;;
        0x8086:0xb084) echo "Arc Pro B390" ;;
        0x8086:0xb085) echo "Arc Pro B370" ;;
        0x8086:0xb086) echo "Arc Pro B390" ;;
        0x8086:0xb087) echo "Arc Pro B370" ;;
        0x8086:0xe20b) echo "Arc B580" ;;
        0x8086:0xe20c) echo "Arc B570" ;;
        0x8086:0xe211) echo "Arc Pro B60" ;;
        0x8086:0xe212) echo "Arc Pro B50" ;;
        *) echo "" ;;
    esac
}

# GPU VRAM ルックアップ (pci.ids にVRAM情報なし → 手動データ)
# 同一デバイスIDで複数容量がある場合は代表値を記載
# R9 290X(4GB)/390X(8GB) のように共有IDは区別不可
gpu_vram_lookup() {
    case "${1}:${2}" in
        # ----- AMD HD 3000/4000/5000/6000 -----
        0x1002:0x9501) echo "512 MB" ;;   # HD 3870
        0x1002:0x950f) echo "1024 MB" ;;  # HD 3870 X2
        0x1002:0x9440) echo "512 MB" ;;   # HD 4870
        0x1002:0x9441) echo "1024 MB" ;;  # HD 4870 X2
        0x1002:0x9442) echo "512 MB" ;;   # HD 4850
        0x1002:0x9443) echo "1024 MB" ;;  # HD 4850 X2
        0x1002:0x9460) echo "1024 MB" ;;  # HD 4890
        0x1002:0x6898) echo "1024 MB" ;;  # HD 5870
        0x1002:0x6899) echo "512 MB" ;;   # HD 5850
        0x1002:0x6738) echo "1024 MB" ;;  # HD 6870
        0x1002:0x6739) echo "512 MB" ;;   # HD 6850
        0x1002:0x6718) echo "3072 MB" ;;  # HD 6970
        0x1002:0x6719) echo "2048 MB" ;;  # HD 6950
        # ----- AMD HD 7000 / R9 200 -----
        0x1002:0x6798) echo "3072 MB" ;;  # HD 7970 / R9 280X
        0x1002:0x679a) echo "3072 MB" ;;  # HD 7950 / R9 280
        0x1002:0x679e) echo "2048 MB" ;;  # HD 7870
        0x1002:0x6810) echo "2048 MB" ;;  # HD 7870 XT
        0x1002:0x6818) echo "2048 MB" ;;  # HD 7870
        0x1002:0x6819) echo "2048 MB" ;;  # HD 7850
        0x1002:0x682b) echo "2048 MB" ;;  # HD 7870 / R9 270X
        # ----- AMD R9 290/390 (Hawaii) -----
        0x1002:0x67b0) echo "4 GB (R9 290X) / 8 GB (R9 390X)" ;;
        0x1002:0x67b1) echo "4 GB (R9 290) / 8 GB (R9 390)" ;;
        # ----- AMD R9 380/Fury -----
        0x1002:0x6939) echo "4096 MB" ;;  # R9 380X / 285
        0x1002:0x692b) echo "4096 MB" ;;  # R9 Fury
        0x1002:0x7300) echo "4096 MB" ;;  # R9 Fury X (HBM)
        # ----- AMD Polaris (RX 400/500) -----
        0x1002:0x67df) echo "4/8 GB" ;;   # RX 480
        0x1002:0x67ef) echo "4/8 GB" ;;   # RX 470 / RX 580
        0x1002:0x67ff) echo "4/8 GB" ;;   # RX 570
        0x1002:0x699f) echo "2/4 GB" ;;   # RX 550
        # ----- AMD Vega -----
        0x1002:0x687f) echo "8192 MB" ;;  # RX Vega 64 (HBM2)
        0x1002:0x687e) echo "8192 MB" ;;  # RX Vega 56 (HBM2)
        0x1002:0x6860) echo "16384 MB" ;; # Radeon Pro Vega 56
        # ----- AMD Navi 10/12/14 (RX 5000) -----
        0x1002:0x731f) echo "8192 MB" ;;  # RX 5700 XT
        0x1002:0x7312) echo "8192 MB" ;;  # RX 5700
        0x1002:0x7340) echo "4/8 GB" ;;   # RX 5500 XT
        0x1002:0x7341) echo "4/8 GB" ;;   # RX 5500 XT
        0x1002:0x7360) echo "6144 MB" ;;  # RX 5600 XT
        # ----- AMD RDNA2 (RX 6000) -----
        0x1002:0x73a5) echo "16384 MB" ;; # RX 6900 XT
        0x1002:0x73bf) echo "16384 MB" ;; # RX 6800 XT
        0x1002:0x73c0) echo "16384 MB" ;; # RX 6800
        0x1002:0x73df) echo "12288 MB" ;; # RX 6700 XT
        0x1002:0x73e3) echo "12288 MB" ;; # RX 6700
        0x1002:0x73ff) echo "8192 MB" ;;  # RX 6600 XT
        0x1002:0x73e0) echo "8192 MB" ;;  # RX 6600
        0x1002:0x743f) echo "4096 MB" ;;  # RX 6500 XT
        # ----- AMD RDNA3 (RX 7000) -----
        0x1002:0x7480) echo "24576 MB" ;; # RX 7900 XTX
        0x1002:0x744c) echo "20480 MB" ;; # RX 7900 XT
        0x1002:0x7448) echo "16384 MB" ;; # RX 7900 GRE
        0x1002:0x747e) echo "12288 MB" ;; # RX 7700 XT
        0x1002:0x7470) echo "16384 MB" ;; # RX 7800 XT
        0x1002:0x7461) echo "8192 MB" ;;  # RX 7600
        # ----- NVIDIA GT200 (GTX 260/280/285) -----
        0x10de:0x05e0) echo "1792 MB" ;;  # GTX 295
        0x10de:0x05e1) echo "1024 MB" ;;  # GTX 280
        0x10de:0x05e2) echo "896 MB" ;;   # GTX 260
        0x10de:0x05e3) echo "1024 MB" ;;  # GTX 285
        0x10de:0x05e6) echo "896 MB" ;;   # GTX 275
        # ----- NVIDIA Fermi (GTX 400/500) -----
        0x10de:0x06c0) echo "1536 MB" ;;  # GTX 480
        0x10de:0x06d1) echo "3072 MB" ;;  # Tesla C2050
        0x10de:0x1086) echo "1536 MB" ;;  # GTX 580
        0x10de:0x1084) echo "1024 MB" ;;  # GTX 560 Ti
        0x10de:0x1045) echo "1024 MB" ;;  # GTX 550 Ti
        # ----- NVIDIA Kepler (GTX 600/700) -----
        0x10de:0x1180) echo "2048 MB" ;;  # GTX 680
        0x10de:0x1183) echo "2048 MB" ;;  # GTX 660 Ti
        0x10de:0x1185) echo "2048 MB" ;;  # GTX 660
        0x10de:0x1187) echo "4096 MB" ;;  # GTX 760
        0x10de:0x100a) echo "3072 MB" ;;  # GTX 780 Ti
        0x10de:0x1004) echo "3072 MB" ;;  # GTX 780
        0x10de:0x1005) echo "6144 MB" ;;  # GTX Titan
        0x10de:0x1189) echo "2048 MB" ;;  # GTX 670
        # ----- NVIDIA Maxwell (GTX 900) -----
        0x10de:0x17c8) echo "4096 MB" ;;  # GTX 980 Ti (6GB actually)
        0x10de:0x17c2) echo "12288 MB" ;; # GTX Titan X
        0x10de:0x13c0) echo "4096 MB" ;;  # GTX 980
        0x10de:0x13c2) echo "4096 MB" ;;  # GTX 970
        0x10de:0x1380) echo "4096 MB" ;;  # GTX 750 Ti (2GB)
        0x10de:0x1381) echo "1024 MB" ;;  # GTX 750
        # ----- NVIDIA Pascal (GTX 1000) -----
        0x10de:0x1b00) echo "12288 MB" ;; # Titan X Pascal
        0x10de:0x1b02) echo "12288 MB" ;; # Titan Xp
        0x10de:0x1b06) echo "11264 MB" ;; # GTX 1080 Ti
        0x10de:0x1b80) echo "8192 MB" ;;  # GTX 1080
        0x10de:0x1b81) echo "8192 MB" ;;  # GTX 1070
        0x10de:0x1b82) echo "8192 MB" ;;  # GTX 1070 Ti
        0x10de:0x1c02) echo "3072 MB" ;;  # GTX 1060 3GB
        0x10de:0x1c03) echo "6144 MB" ;;  # GTX 1060 6GB
        0x10de:0x1c81) echo "2048 MB" ;;  # GTX 1050 2GB
        0x10de:0x1c82) echo "4096 MB" ;;  # GTX 1050 Ti
        # ----- NVIDIA Turing (RTX 2000) -----
        0x10de:0x1e02) echo "24576 MB" ;; # Titan RTX
        0x10de:0x1e04) echo "8192 MB" ;;  # RTX 2080
        0x10de:0x1e82) echo "11264 MB" ;; # RTX 2080 Ti
        0x10de:0x1e87) echo "8192 MB" ;;  # RTX 2080 Super
        0x10de:0x1f02) echo "8192 MB" ;;  # RTX 2070 Super
        0x10de:0x1f06) echo "6144 MB" ;;  # RTX 2060 Super
        0x10de:0x1f08) echo "6144 MB" ;;  # RTX 2060
        0x10de:0x1e81) echo "8192 MB" ;;  # RTX 2070
        # ----- NVIDIA Ampere (RTX 3000) -----
        0x10de:0x2204) echo "24576 MB" ;; # RTX 3090
        0x10de:0x2203) echo "24576 MB" ;; # RTX 3090 Ti
        0x10de:0x2206) echo "10240 MB" ;; # RTX 3080 10GB
        0x10de:0x2208) echo "12288 MB" ;; # RTX 3080 12GB
        0x10de:0x220a) echo "24576 MB" ;; # RTX 3080 Ti
        0x10de:0x2484) echo "8192 MB" ;;  # RTX 3070
        0x10de:0x2488) echo "8192 MB" ;;  # RTX 3070 Ti
        0x10de:0x2503) echo "12288 MB" ;; # RTX 3060
        0x10de:0x2504) echo "8192 MB" ;;  # RTX 3060 Ti
        0x10de:0x2571) echo "8192 MB" ;;  # RTX 3050
        # ----- NVIDIA Ada (RTX 4000) -----
        0x10de:0x2684) echo "24576 MB" ;; # RTX 4090
        0x10de:0x2702) echo "16384 MB" ;; # RTX 4080
        0x10de:0x2705) echo "12288 MB" ;; # RTX 4080 Super
        0x10de:0x2782) echo "12288 MB" ;; # RTX 4070 Ti
        0x10de:0x2786) echo "12288 MB" ;; # RTX 4070 Ti Super
        0x10de:0x2783) echo "12288 MB" ;; # RTX 4070 Super
        0x10de:0x2730) echo "12288 MB" ;; # RTX 4070
        0x10de:0x2860) echo "8192 MB" ;;  # RTX 4060 Ti 8GB
        0x10de:0x2803) echo "16384 MB" ;; # RTX 4060 Ti 16GB
        0x10de:0x2882) echo "8192 MB" ;;  # RTX 4060
        # ----- Intel Arc -----
        0x8086:0x56a0) echo "16384 MB" ;; # Arc A770 16GB
        0x8086:0x56a1) echo "8192 MB" ;;  # Arc A750
        0x8086:0x56a2) echo "8192 MB" ;;  # Arc A580
        0x8086:0x56a5) echo "6144 MB" ;;  # Arc A380
        0x8086:0xe20b) echo "12288 MB" ;; # Arc B580
        0x8086:0xe20c) echo "10240 MB" ;; # Arc B570
        *) echo "" ;;
    esac
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
        sep
    done
}

# profile.d のメニューから呼ばれる: 情報を stdout に出力するだけ
show_cpu
show_memory
show_motherboard
show_gpu
show_storage
printf "\n"
