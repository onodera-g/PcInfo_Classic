#!/bin/sh
# menu.sh - トップメニュー（起動時に profile.d から呼ばれる）

. /opt/common.sh

# fbprint が使えない場合のフォールバック
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
        printf "\n"
        printf "  2. メモリテスト\n"
        printf "\n"
        printf "  3. GPUテスト\n"
        printf "\n"
        printf "  4. ストレージ情報\n"
        printf "\n"
        printf "  q. シャットダウン\n"
        printf "\n  Select [1-4/q]: "
    } | "$FBPRINT" "$FONT" "$FB"

    read_key

    case "$key" in
        1) /opt/menu_pcinfo.sh ;;
        2) /opt/menu_memtest.sh ;;
        3) /opt/menu_gpu.sh ;;
        4) /opt/menu_storage.sh ;;
        q|Q) break ;;
    esac
done

poweroff
