#!/bin/sh
# common.sh - 共通変数・関数（全メニューから . で読み込む）

FBPRINT=/usr/local/bin/fbprint
FONT=/usr/share/consolefonts/unifont_ja.psf.gz
FB=/dev/fb0
TTY=/dev/tty1
LINES_PER_PAGE=43

# 1文字即時入力: raw モードで1バイト読み、割り込み時も必ず stty を復元する
read_key() {
    _old=$(stty -g < "$TTY")
    trap 'stty "$_old" < "$TTY"' INT TERM
    stty -icanon -echo min 1 time 0 < "$TTY"
    key=$(dd bs=1 count=1 < "$TTY" 2>/dev/null)
    stty "$_old" < "$TTY"
    trap - INT TERM
}

# stdin の内容を LINES_PER_PAGE 行ずつページ表示する
# 途中ページ: Enter で次へ / 最終ページ: q でトップに戻る
show_paged() {
    _content=$(cat)
    _total=$(printf '%s\n' "$_content" | wc -l)
    _start=1
    while true; do
        _end=$((_start + LINES_PER_PAGE - 1))
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        _chunk=$(printf '%s\n' "$_content" | sed -n "${_start},${_end}p")
        if [ "$_end" -lt "$_total" ]; then
            { printf '%s\n' "$_chunk"; printf '\n----------------------------------------\nEnterで続きを表示\n'; } | "$FBPRINT" "$FONT" "$FB"
            read -r _dummy < "$TTY"
            _start=$((_end + 1))
        else
            { printf '%s\n' "$_chunk"; printf '\n----------------------------------------\nq でトップに戻る\n'; } | "$FBPRINT" "$FONT" "$FB"
            while true; do
                read_key
                case "$key" in q|Q|'') return ;; esac
            done
        fi
    done
}
