#!/bin/sh
# menu.sh - Top menu (called from /etc/local.d/pcinfo.start at boot)

. /opt/pcinfo/common.sh

ensure_setup_ready() {
    local reason=""
    while [ "$(cat "$BOOT_STATUS_FILE" 2>/dev/null)" != ready ]; do
        reason=$(cat "$BOOT_STATUS_FILE" 2>/dev/null) || reason='Startup setup did not complete.'
        [ -n "$reason" ] || reason='Startup setup did not complete.'
        {
            printf '\033[2J\033[H\n[Startup setup failed]\n\n'
            printf '%s\n\n' "$reason"
            printf 'r: Retry setup   q: Shutdown\n'
        } > "$TTY"
        read_key || return 1
        case "$key" in
            r|R) /etc/local.d/00-pcinfo-setup.start > "$TTY" 2>&1 ;;
            q|Q) poweroff; return 1 ;;
        esac
    done
}

ensure_setup_ready || exit 1

show_menu() {
    printf '\033[2J\033[H' > "$TTY" 2>/dev/null
    printf ' ____      ___        __          ____ _               _      \n' > "$TTY"
    printf '|  _ \\ ___|_ _|_ __  / _| ___    / ___| | __ _ ___ ___(_) ___ \n' > "$TTY"
    printf '| |_) / __|| || '"'"'_ \\| |_ / _ \\  | |   | |/ _` / __/ __| |/ __|\n' > "$TTY"
    printf '|  __/ (__ | || | | |  _| (_) | | |___| | (_| \\__ \\__ \\ | (__ \n' > "$TTY"
    printf '|_|   \\___|___|_| |_|_|  \\___/   \\____|_|\\__,_|___/___/_|\\___|\n' > "$TTY"
    printf '                                        Powered by Alpine Linux\n' > "$TTY"
    printf '\n' > "$TTY"
    printf '  1.  PC Info\n' > "$TTY"
    printf '\n' > "$TTY"
    printf '  2.  Memory Test\n' > "$TTY"
    printf '\n' > "$TTY"
    printf '  3.  GPU Driver Check\n' > "$TTY"
    printf '\n' > "$TTY"
    printf '  4.  Storage Health\n' > "$TTY"
    printf '\n' > "$TTY"
    printf '  q.  Shutdown\n' > "$TTY"
    printf '\n  Select [1-4/q]: ' > "$TTY"
}

while true; do
    show_menu
    read_key || exit 1

    case "$key" in
        1) /opt/pcinfo/menu_pcinfo.sh ;;
        2) /opt/pcinfo/menu_memtest.sh ;;
        3) /opt/pcinfo/menu_gpu.sh ;;
        4) /opt/pcinfo/menu_storage.sh ;;
        q|Q) break ;;
    esac
done

poweroff
