#!/bin/sh
# Terminal layout, formatting, key input and pagination.

TTY=/dev/tty1
DEFAULT_LINES_PER_PAGE=20
LINES_PER_PAGE=$DEFAULT_LINES_PER_PAGE
DEFAULT_TTY_COLS=80
TTY_COLS=$DEFAULT_TTY_COLS
ITEM_LABEL_WIDTH=22
DISPLAY_LAYOUT_READY=0
ESC=$(printf '\033')

# ANSI colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

SEP='----------------------------------------'

# Read a single key from TTY (raw mode)
read_key() {
    local _old="" _input="" _status=0 _read_failed=0
    key=""
    if ! [ -c "$TTY" ] || ! stty -g < "$TTY" > /dev/null 2>&1; then
        return 1
    fi
    _old=$(stty -g < "$TTY" 2>/dev/null) || return 1
    trap 'stty "$_old" < "$TTY" 2>/dev/null; _read_failed=1' INT TERM
    if stty -icanon -echo min 1 time 0 < "$TTY" 2>/dev/null; then
        # The sentinel preserves an Enter byte during command substitution;
        # a successful zero-byte read is distinguishable from Enter.
        if _input=$(dd bs=1 count=1 < "$TTY" 2>/dev/null && printf '.'); then
            case "$_input" in
                .) _status=1 ;;
                *) key=${_input%?} ;;
            esac
        else
            _status=1
        fi
    else
        _status=1
    fi
    stty "$_old" < "$TTY" 2>/dev/null || _status=1
    trap - INT TERM
    [ "$_read_failed" -eq 0 ] || _status=1
    if [ "$_status" -ne 0 ]; then
        key=""
        return 1
    fi
    # Newline is retained above; map CR/LF to the historical Enter value.
    if [ "$key" = "$(printf '\r')" ] || [ "$key" = "
" ]; then
        key=""
    fi
    return 0
}

wait_any_key() {
    read_key || true
}

trim_value() {
    printf '%s\n' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

get_tty_rows() {
    _size=$(stty size < "$TTY" 2>/dev/null) || return 1
    _rows=$(printf '%s\n' "$_size" | awk '{print $1}')
    _cols=$(printf '%s\n' "$_size" | awk '{print $2}')
    [ -n "$_rows" ] || return 1
    [ -n "$_cols" ] || return 1
    case "$_rows" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_rows" -gt 0 ] || return 1
    printf '%s\n' "$_rows"
}

get_tty_cols() {
    _size=$(stty size < "$TTY" 2>/dev/null) || return 1
    _rows=$(printf '%s\n' "$_size" | awk '{print $1}')
    _cols=$(printf '%s\n' "$_size" | awk '{print $2}')
    [ -n "$_rows" ] || return 1
    [ -n "$_cols" ] || return 1
    case "$_cols" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_cols" -gt 0 ] || return 1
    printf '%s\n' "$_cols"
}

update_pagination_layout() {
    _rows=$(get_tty_rows 2>/dev/null)
    _cols=$(get_tty_cols 2>/dev/null)
    if [ -n "$_rows" ]; then
        if [ "$_rows" -gt 6 ]; then
            LINES_PER_PAGE=$((_rows - 4))
        else
            LINES_PER_PAGE=$_rows
        fi
    else
        LINES_PER_PAGE=$DEFAULT_LINES_PER_PAGE
    fi

    if [ -n "$_cols" ]; then
        TTY_COLS=$_cols
    else
        TTY_COLS=$DEFAULT_TTY_COLS
    fi

    case "$TTY_COLS" in
        ''|*[!0-9]*) TTY_COLS=$DEFAULT_TTY_COLS ;;
    esac

    if [ "$TTY_COLS" -ge 72 ]; then
        ITEM_LABEL_WIDTH=22
    elif [ "$TTY_COLS" -ge 56 ]; then
        ITEM_LABEL_WIDTH=18
    elif [ "$TTY_COLS" -ge 44 ]; then
        ITEM_LABEL_WIDTH=14
    elif [ "$TTY_COLS" -ge 32 ]; then
        ITEM_LABEL_WIDTH=10
    elif [ "$TTY_COLS" -ge 24 ]; then
        ITEM_LABEL_WIDTH=8
    else
        ITEM_LABEL_WIDTH=6
    fi

    _sep_width=$TTY_COLS
    [ "$_sep_width" -lt 8 ] && _sep_width=8
    SEP=$(printf '%*s' "$_sep_width" '' | tr ' ' '-')
    DISPLAY_LAYOUT_READY=1
}

invalidate_display_layout() {
    DISPLAY_LAYOUT_READY=0
}

ensure_display_layout() {
    [ "${DISPLAY_LAYOUT_READY:-0}" -eq 1 ] && return 0
    update_pagination_layout
}

wrap_plain_text_to_width() {
    _width="$1"
    awk -v width="$_width" '
        function emit_word_chunks(word,    part) {
            while (length(word) > width) {
                print substr(word, 1, width)
                word = substr(word, width + 1)
            }
            if (word != "") {
                print word
            }
        }
        {
            if ($0 == "") {
                print ""
                next
            }
            line = ""
            count = split($0, words, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                word = words[i]
                if (word == "") {
                    continue
                }
                if (length(word) > width) {
                    if (line != "") {
                        print line
                        line = ""
                    }
                    emit_word_chunks(word)
                    continue
                }
                if (line == "") {
                    line = word
                } else if (length(line) + 1 + length(word) <= width) {
                    line = line " " word
                } else {
                    print line
                    line = word
                }
            }
            if (line != "") {
                print line
            }
        }
    '
}

print_wrapped_line() {
    _prefix="$1"
    _next_prefix="$2"
    _value="$3"
    _format="$4"
    _width="$5"
    _printed=0

    case "$_value" in
        *"$ESC"*)
            if [ "$_format" = "b" ]; then
                printf '%s%b\n' "$_prefix" "$_value"
            else
                printf '%s%s\n' "$_prefix" "$_value"
            fi
            return
            ;;
    esac

    if [ -z "$_value" ]; then
        printf '%s\n' "$_prefix"
        return
    fi

    printf '%s\n' "$_value" | wrap_plain_text_to_width "$_width" | while IFS= read -r _line || [ -n "$_line" ]; do
        if [ "$_printed" -eq 0 ]; then
            _current_prefix=$_prefix
            _printed=1
        else
            _current_prefix=$_next_prefix
        fi
        if [ "$_format" = "b" ]; then
            printf '%s%b\n' "$_current_prefix" "$_line"
        else
            printf '%s%s\n' "$_current_prefix" "$_line"
        fi
    done
}

render_item_value() {
    ensure_display_layout
    _label="$1"
    _value="$2"
    _format="${3:-s}"

    if [ "$TTY_COLS" -le $((ITEM_LABEL_WIDTH + 12)) ]; then
        printf '  %s:\n' "$_label"
        _value_width=$((TTY_COLS - 4))
        [ "$_value_width" -lt 8 ] && _value_width=8
        print_wrapped_line '    ' '    ' "$_value" "$_format" "$_value_width"
        return
    fi

    _prefix=$(printf '  %-*s: ' "$ITEM_LABEL_WIDTH" "$_label")
    _next_prefix=$(printf '  %-*s  ' "$ITEM_LABEL_WIDTH" '')
    _value_width=$((TTY_COLS - ITEM_LABEL_WIDTH - 4))
    [ "$_value_width" -lt 8 ] && _value_width=8
    print_wrapped_line "$_prefix" "$_next_prefix" "$_value" "$_format" "$_value_width"
}

render_item() {
    render_item_value "$1" "$2" s
}

render_item_escaped() {
    render_item_value "$1" "$2" b
}

# PAGE_ACTION is local to the pager process. GPU mode returns r/q on stdout;
# all report text and prompts continue to go to TTY.
read_page_action() {
    local more="$1" controls="${2:-normal}"
    PAGE_ACTION=done
    if [ "$controls" = gpu ]; then
        if [ "$more" -eq 1 ]; then
            printf '\n%s\nEnter: Next page   r: Load missing drivers   q: Back\n' "$SEP" > "$TTY"
        else
            printf '\n%s\nr: Load missing drivers   q: Back\n' "$SEP" > "$TTY"
        fi
        while true; do
            read_key || return 1
            case "$key" in
                q|Q) PAGE_ACTION=q; return 0 ;;
                r|R) PAGE_ACTION=r; return 0 ;;
                ''|' ') if [ "$more" -eq 1 ]; then PAGE_ACTION=next; return 0; fi ;;
            esac
        done
    elif [ "$more" -eq 1 ]; then
        printf '\n%s\nPress Enter for more...\n' "$SEP" > "$TTY"
        read -r _dummy < "$TTY" || return 1
        PAGE_ACTION=next
    else
        printf '\n%s\nPress any key to return\n' "$SEP" > "$TTY"
        read_key || return 1
    fi
}

# In-memory fallback when the temporary page directory is unavailable.
show_paged() {
    local controls="${1:-normal}" more=0
    _content=$(cat)
    update_pagination_layout
    _total=$(printf '%s\n' "$_content" | wc -l)
    _start=1
    while true; do
        _end=$((_start + LINES_PER_PAGE - 1))
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        _chunk=$(printf '%s\n' "$_content" | sed -n "${_start},${_end}p")
        printf '%s\n' "$_chunk" > "$TTY"
        more=0
        [ "$_end" -lt "$_total" ] && more=1
        read_page_action "$more" "$controls" || return 1
        case "$PAGE_ACTION" in
            next) _start=$((_end + 1)) ;;
            r|q) printf '%s' "$PAGE_ACTION"; return 0 ;;
            *) return 0 ;;
        esac
    done
}

show_paged_blocks() {
    local controls="${1:-normal}" result=0 more=0 action=""
    _tmpdir=$(mktemp -d /tmp/pcinfo-pages.XXXXXX 2>/dev/null)
    [ -n "$_tmpdir" ] || {
        show_paged "$controls"
        return $?
    }
    _input="$_tmpdir/input.txt"
    cat > "$_input"
    update_pagination_layout

    awk -v max="$LINES_PER_PAGE" -v dir="$_tmpdir" '
        function is_blank(idx) {
            return lines[idx] ~ /^[[:space:]]*$/
        }
        function write_page(s, e,    file, i) {
            if (e < s) {
                return
            }
            page++
            file = sprintf("%s/page_%03d.txt", dir, page)
            for (i = s; i <= e; i++) {
                print lines[i] > file
            }
            close(file)
        }
        {
            lines[++n] = $0
        }
        END {
            start = 1
            while (start <= n && is_blank(start)) {
                start++
            }
            while (start <= n) {
                end = start + max - 1
                if (end >= n) {
                    write_page(start, n)
                    break
                }
                split_at = 0
                for (i = end; i > start; i--) {
                    if (is_blank(i)) {
                        split_at = i - 1
                        break
                    }
                }
                if (split_at < start) {
                    split_at = end
                }
                write_page(start, split_at)
                start = split_at + 1
                while (start <= n && is_blank(start)) {
                    start++
                }
            }
        }
    ' "$_input"

    _pages=$(find "$_tmpdir" -maxdepth 1 -name 'page_*.txt' | wc -l | tr -d ' ')
    if [ "$_pages" -eq 0 ]; then
        rm -rf "$_tmpdir"
        return
    fi

    _current=0
    for _page in "$_tmpdir"/page_*.txt; do
        [ -f "$_page" ] || continue
        _current=$((_current + 1))
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        cat "$_page" > "$TTY"
        more=0
        [ "$_current" -lt "$_pages" ] && more=1
        if ! read_page_action "$more" "$controls"; then
            result=1
            break
        fi
        case "$PAGE_ACTION" in
            r|q) action="$PAGE_ACTION"; break ;;
            done) break ;;
        esac
    done

    rm -rf "$_tmpdir"
    [ -z "$action" ] || printf '%s' "$action"
    return "$result"
}
