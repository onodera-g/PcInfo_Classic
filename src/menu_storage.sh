#!/bin/sh
# menu_storage.sh - ストレージ情報画面

. /opt/common.sh

printf '\033[2J\033[H' > "$TTY" 2>/dev/null
printf "[ストレージ情報]\n\nnot implemented\n\nq でトップに戻る\n" | "$FBPRINT" "$FONT" "$FB"
while true; do read_key; case "$key" in q|Q) break ;; esac; done
