#!/bin/bash
# ui.sh — TUI components with gum (preferred) and bash fallback

_C_RESET="\033[0m"
_C_BOLD="\033[1m"             # headers, menu prompts, input prompts, labels
_C_DIM="\033[2m"             # secondary text: hints, descriptions, caveats
_C_GREEN="\033[32m"
_C_YELLOW="\033[33m"
_C_RED="\033[31m"
_C_ACCENT="\033[38;5;117m"   # brand light-blue (logo + section headers)
_C_GRAY="\033[90m"           # inline menu tags ("  · recommended")
_C_CURSOR="\033[38;5;212m"   # selection cursor (matches gum choose)
UI_TIPS_LINES=3              # blank + blank + tips line
UI_GUTTER=2                  # left indent for body text (COPY-GUIDE §D)
UI_CONTENT_WIDTH=64          # max content chars per line (~66 cols total)

# Shared keyboard hints for arrow-key menus.
ui_tips() {
    echo "" >&2
    echo "" >&2
    tput el >&2
    echo -e "  ↑↓${_C_DIM} navigate  •  ${_C_RESET}return${_C_DIM} submit  •  ${_C_RESET}ctrl+c${_C_DIM} exit${_C_RESET}" >&2
}

# Word-wrap plain text to the shared content column, indenting every line.
# Right edge is UI_GUTTER + UI_CONTENT_WIDTH (clamped to the terminal width),
# so body text and deeper-indented descriptions share one reading column.
# Prints to stdout; sets _UI_WRAP_COUNT to the number of lines written.
# Menu redraws should call this with >&2 so output stays off command substitutions.
_ui_print_wrapped() {
    local indent="$1"
    local color="$2"
    local text="$3"
    local cols right width
    cols=$(tput cols 2>/dev/null) || cols=80
    right=$(( UI_GUTTER + UI_CONTENT_WIDTH ))
    if (( right > cols )); then
        right=$cols
    fi
    width=$(( right - ${#indent} ))
    if (( width < 20 )); then
        width=20
    fi

    local line="" word
    _UI_WRAP_COUNT=0
    for word in $text; do
        if [[ -z "$line" ]]; then
            line="$word"
        elif (( ${#line} + 1 + ${#word} <= width )); then
            line+=" $word"
        else
            tput el 2>/dev/null || true
            echo -e "${indent}${color}${line}${_C_RESET}"
            _UI_WRAP_COUNT=$((_UI_WRAP_COUNT + 1))
            line="$word"
        fi
    done
    tput el 2>/dev/null || true
    echo -e "${indent}${color}${line}${_C_RESET}"
    _UI_WRAP_COUNT=$((_UI_WRAP_COUNT + 1))
}

# Returns 0 on arrow/select keys; sets _UI_KEY and _UI_SELECTED.
_ui_read_menu_key() {
    local count="$1"
    _UI_KEY=""
    local key=""
    if ! IFS= read -rsn1 key < /dev/tty 2>/dev/null; then
        return 1
    fi

    case "$key" in
        $'\x1b')
            if IFS= read -rsn2 key < /dev/tty 2>/dev/null; then
                case "$key" in
                    '[A') _UI_KEY=up ;;
                    '[B') _UI_KEY=down ;;
                esac
            fi
            ;;
        ''|$'\n'|$'\r') _UI_KEY=select ;;
        $'\x03')         _UI_KEY=escape ;;
        k|K)             _UI_KEY=up ;;
        j|J)             _UI_KEY=down ;;
    esac

    case "$_UI_KEY" in
        up)    (( _UI_SELECTED > 0 )) && (( _UI_SELECTED-- )) || true ;;
        down)  (( _UI_SELECTED < count - 1 )) && (( _UI_SELECTED++ )) || true ;;
        select|escape) return 0 ;;
    esac
    return 0
}

ui_choose() {
    local header="$1"
    shift
    local items=("$@")
    local count=${#items[@]}
    (( count == 0 )) && return 1

    local header_lines=0
    [[ -n "$header" ]] && header_lines=2

    local menu_lines=$(( header_lines + count + UI_TIPS_LINES ))
    _UI_SELECTED=0
    local drawn=false

    tput civis >&2 2>/dev/null || true

    while true; do
        if [[ "$drawn" == true ]]; then
            tput cuu "$menu_lines" >&2 2>/dev/null || true
        fi

        if [[ -n "$header" ]]; then
            tput el >&2
            echo -e "  ${_C_BOLD}${header}${_C_RESET}" >&2
            tput el >&2
            echo "" >&2
        fi

        local i title_prefix label_color item label tag
        for (( i=0; i<count; i++ )); do
            if (( i == _UI_SELECTED )); then
                title_prefix="${_C_CURSOR}❯   ${_C_RESET}"
                label_color="${_C_CURSOR}${_C_BOLD}"
            else
                title_prefix="    "
                label_color="${_C_DIM}${_C_BOLD}"
            fi

            item="${items[$i]}"
            label="$item"
            tag=""
            if [[ "$item" == *"|"* ]]; then
                label="${item%%|*}"
                tag="${item#*|}"
            fi

            tput el >&2
            if [[ -n "$tag" ]]; then
                echo -e "  ${title_prefix}${label_color}${label}${_C_RESET}${_C_GRAY}  · ${tag}${_C_RESET}" >&2
            else
                echo -e "  ${title_prefix}${label_color}${label}${_C_RESET}" >&2
            fi
        done

        ui_tips
        drawn=true

        _ui_read_menu_key "$count" || {
            tput cnorm >&2 2>/dev/null || true
            return 1
        }

        if [[ "$_UI_KEY" == escape ]]; then
            tput cnorm >&2 2>/dev/null || true
            echo "" >&2
            return 1
        fi
        if [[ "$_UI_KEY" == select ]]; then
            tput cnorm >&2 2>/dev/null || true
            echo "" >&2
            local selected="${items[$_UI_SELECTED]}"
            [[ "$selected" == *"|"* ]] && selected="${selected%%|*}"
            echo "$selected"
            return 0
        fi
    done
}

# Append one screen line to the current choose-desc frame.
# Uses CSI K (erase to EOL) so redraws don't leave stale glyphs, without
# tput ed which blanks the whole lower screen and makes the tips flicker.
_ui_frame_line() {
    _UI_FRAME+="\033[K$1\n"
    _UI_FRAME_LINES=$((_UI_FRAME_LINES + 1))
}

# Word-wrap into the frame buffer (same column rules as _ui_print_wrapped).
_ui_frame_wrapped() {
    local indent="$1"
    local color="$2"
    local text="$3"
    local cols right width
    cols=$(tput cols 2>/dev/null) || cols=80
    right=$(( UI_GUTTER + UI_CONTENT_WIDTH ))
    if (( right > cols )); then
        right=$cols
    fi
    width=$(( right - ${#indent} ))
    if (( width < 20 )); then
        width=20
    fi

    local line="" word
    for word in $text; do
        if [[ -z "$line" ]]; then
            line="$word"
        elif (( ${#line} + 1 + ${#word} <= width )); then
            line+=" $word"
        else
            _ui_frame_line "${indent}${color}${line}${_C_RESET}"
            line="$word"
        fi
    done
    _ui_frame_line "${indent}${color}${line}${_C_RESET}"
}

# Arrow-key menu where each option shows a label and description together.
# Args: prompt, then pairs of (label, description). Returns the chosen label.
ui_choose_desc() {
    local prompt="$1"
    shift
    if [[ $(( $# % 2 )) -ne 0 ]]; then
        return 1
    fi

    local labels=() descs=()
    while [[ $# -ge 2 ]]; do
        labels+=("$1")
        descs+=("$2")
        shift 2
    done

    local count=${#labels[@]}
    (( count == 0 )) && return 1

    # Track lines actually drawn so redraw can move up past wrapped descriptions.
    local menu_lines=0
    _UI_SELECTED=0
    local drawn=false

    tput civis >&2 2>/dev/null || true

    while true; do
        _UI_FRAME=""
        _UI_FRAME_LINES=0

        _ui_frame_line "  ${_C_BOLD}${prompt}${_C_RESET}"
        _ui_frame_line ""

        local i title_prefix desc_indent label_color desc_color
        for (( i=0; i<count; i++ )); do
            if (( i == _UI_SELECTED )); then
                title_prefix="${_C_CURSOR}❯   ${_C_RESET}"
                label_color="${_C_CURSOR}${_C_BOLD}"
                desc_color="${_C_RESET}"
            else
                title_prefix="    "
                label_color="${_C_DIM}${_C_BOLD}"
                desc_color="${_C_DIM}"
            fi
            # Align description under the label (2-space gutter + 4-char cursor column).
            desc_indent="      "

            _ui_frame_line "  ${title_prefix}${label_color}${labels[$i]}${_C_RESET}"
            _ui_frame_wrapped "$desc_indent" "$desc_color" "${descs[$i]}"

            if (( i < count - 1 )); then
                _ui_frame_line ""
            fi
        done

        _ui_frame_line ""
        _ui_frame_line ""
        _ui_frame_line "  ↑↓${_C_DIM} navigate  •  ${_C_RESET}return${_C_DIM} submit  •  ${_C_RESET}ctrl+c${_C_DIM} exit${_C_RESET}"

        if [[ "$drawn" == true ]]; then
            tput cuu "$menu_lines" >&2 2>/dev/null || true
        fi
        # One write per redraw — avoids the tips vanishing while upper lines paint.
        # %b interprets the same \033 / \n escapes echo -e used elsewhere in this file.
        printf '%b' "$_UI_FRAME" >&2
        menu_lines=$_UI_FRAME_LINES
        drawn=true

        _ui_read_menu_key "$count" || {
            tput cnorm >&2 2>/dev/null || true
            return 1
        }

        if [[ "$_UI_KEY" == escape ]]; then
            tput cnorm >&2 2>/dev/null || true
            echo "" >&2
            return 1
        fi
        if [[ "$_UI_KEY" == select ]]; then
            tput cnorm >&2 2>/dev/null || true
            echo "" >&2
            echo "${labels[$_UI_SELECTED]}"
            return 0
        fi
    done
}

ui_input() {
    local prompt="$1"
    shift
    local is_password=false
    local hints=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --password) is_password=true; shift ;;
            --hint)
                shift
                hints+=("$1")
                shift
                ;;
            *) shift ;;
        esac
    done

    # Text/password input uses plain `read`, not gum. gum input renders inline
    # via bubbletea, which double-renders (leaves a ghost frame) on some terminal
    # emulators. `read` never has that problem, and for a secret unlock key,
    # masked `read -s` is cleaner than handing the value to a TUI buffer.
    # gum is still used for menus (ui_choose), fuzzy search (ui_filter), and
    # confirmation (ui_confirm), where its UX actually matters.
    echo -e "  ${_C_BOLD}${prompt}${_C_RESET}" >&2
    if ((${#hints[@]} > 0)); then
        local hint
        for hint in "${hints[@]}"; do
            echo -e "  ${_C_DIM}${hint}${_C_RESET}" >&2
        done
    fi
    local value=""
    if [[ "$is_password" == "true" ]]; then
        printf "  > " >&2
        local char=""
        while IFS= read -rsn1 char < /dev/tty 2>/dev/null; do
            # Enter
            if [[ -z "$char" ]] || [[ "$char" == $'\n' ]]; then
                break
            fi
            # Backspace / Delete
            if [[ "$char" == $'\x7f' ]] || [[ "$char" == $'\b' ]]; then
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    printf "\b \b" >&2
                fi
                continue
            fi
            value+="$char"
            printf "*" >&2
        done
        echo "" >&2
    else
        if ! read -rp "  > " value < /dev/tty 2>/dev/null; then
            return 1
        fi
    fi
    echo "$value"
}

ui_confirm() {
    local question="$1"
    local choice
    choice=$(ui_choose "$question" "Yes" "No") || return 1
    [[ "$choice" == "Yes" ]]
}

ui_filter() {
    local show_tips=true
    local header="$1"
    shift
    if [[ "$1" == "--no-tips" ]]; then
        show_tips=false
        shift
    fi
    local items=("$@")

    if [[ "$HAS_GUM" == "true" ]]; then
        # gum filter treats --header as plain text; ANSI sequences render literally.
        # Use gum's native header styling instead. Match the 2-space column used elsewhere.
        local filter_header
        if [[ "$show_tips" == true ]]; then
            filter_header="${header}

↑↓ navigate • return submit • ctrl+c exit

"
        else
            filter_header="$header"
        fi
        printf '%s\n' "${items[@]}" | "$GUM_BIN" filter \
            --header "$filter_header" \
            --header.bold \
            --padding "0 2" \
            --no-show-help
        return
    fi

    echo -e "  ${_C_BOLD}${header}${_C_RESET}" >&2
    if [[ "$show_tips" == true ]]; then
        ui_tips
    fi
    echo "" >&2

    echo -e "  ${_C_DIM}Enter a number or type to search.${_C_RESET}\n" >&2

    local i=1
    local display_limit=20
    for item in "${items[@]}"; do
        if (( i > display_limit )); then
            echo -e "  ${_C_DIM}... and $((${#items[@]} - display_limit)) more (type to search)${_C_RESET}" >&2
            break
        fi
        echo -e "  ${_C_DIM}${i})${_C_RESET} ${item}" >&2
        ((i++))
    done
    echo "" >&2

    local input=""
    while true; do
        if ! read -rp "  > " input < /dev/tty 2>/dev/null; then
            return 1
        fi
        # If numeric, select by index
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#items[@]} )); then
            echo "${items[$((input-1))]}"
            return
        fi
        # Otherwise search
        local matches=()
        for item in "${items[@]}"; do
            if [[ "$item" == *"$input"* ]]; then
                matches+=("$item")
            fi
        done
        if [[ ${#matches[@]} -eq 1 ]]; then
            echo "${matches[0]}"
            return
        elif [[ ${#matches[@]} -gt 1 ]]; then
            echo -e "  ${_C_DIM}Multiple matches:${_C_RESET}" >&2
            local j=1
            for m in "${matches[@]}"; do
                echo -e "  ${_C_DIM}${j})${_C_RESET} ${m}" >&2
                ((j++))
            done
        else
            echo -e "  ${_C_RED}No matches.${_C_RESET}" >&2
        fi
    done
}

# Blockdown ASCII wordmark — the single logo used everywhere (splash + headers).
# Shadowed half-block font: on-brand "block" feel, compact 2 rows, lowercase.
ui_logo_compact() {
    local suffix="${1:-}"
    echo -e "${_C_ACCENT}  █▄▄ █   █▀█ █▀▀ █ █ █▀▄ █▀█ █ █ █ █▄ █${_C_RESET}"
    echo -e "${_C_ACCENT}  █▄█ █▄▄ █▄█ █▄▄ █▀▄ █▄▀ █▄█ ▀▄▀▄▀ █ ▀█${_C_RESET}"
    if [[ -n "$suffix" ]]; then
        echo -e "  ${_C_DIM}${suffix}${_C_RESET}"
    fi
    echo ""
}

# Inline bold label for drill-down screens (no box, no uppercase).
ui_heading() {
    local text="$1"
    echo -e "  ${_C_BOLD}${text}${_C_RESET}"
}

# Section header: uppercase label in accent color, boxed.
# Always drawn at the top of a screen; the blank line above comes from clear().
ui_section() {
    local text
    text="$(echo "$1" | tr '[:lower:]' '[:upper:]')"

    if [[ "$HAS_GUM" == "true" ]]; then
        # --margin matches the 2-space gutter the bash fallback and body text use.
        "$GUM_BIN" style --border double --margin "0 2" --padding "0 2" --border-foreground 117 --foreground 117 --bold "$text"
        return
    fi

    local line=""
    local len=${#text}
    local pad=$(( len + 6 ))
    for (( i=0; i<pad; i++ )); do line+="═"; done
    echo -e "  ${_C_ACCENT}╔${line}╗${_C_RESET}"
    echo -e "  ${_C_ACCENT}║${_C_RESET}   ${_C_ACCENT}${_C_BOLD}${text}${_C_RESET}   ${_C_ACCENT}║${_C_RESET}"
    echo -e "  ${_C_ACCENT}╚${line}╝${_C_RESET}"
}

# Tight green "✓" line with no leading blank — for status *lists* where several
# lines stack together (pairs with the dim "○ …" lines). For a standalone action
# result, use ui_success instead, which adds the separating blank line.
ui_status_ok() {
    if [[ "$HAS_GUM" == "true" ]]; then
        "$GUM_BIN" style --foreground 2 "  ✓ $1"
    else
        echo -e "  ${_C_GREEN}✓ $1${_C_RESET}"
    fi
}

# Result messages (success/error/warn) always render one leading blank line so
# they are consistently separated from the output above them. Keep this the
# single source of that spacing — callers should not add their own `echo ""`.
ui_success() {
    echo ""
    ui_status_ok "$1"
}

ui_error() {
    if [[ "$HAS_GUM" == "true" ]]; then
        echo ""
        "$GUM_BIN" style --foreground 1 "  ✗ $1"
    else
        echo "" >&2
        echo -e "  ${_C_RED}✗ $1${_C_RESET}" >&2
    fi
}

ui_warn() {
    echo ""
    if [[ "$HAS_GUM" == "true" ]]; then
        "$GUM_BIN" style --foreground 3 "  ⚠ $1"
    else
        echo -e "  ${_C_YELLOW}⚠ $1${_C_RESET}"
    fi
}

ui_info() {
    _ui_print_wrapped "  " "${_C_DIM}" "$1"
}

ui_pause() {
    local prompt="${1:-Press return to continue. ↵}"
    echo ""
    echo "  ${prompt}"
    read -rs < /dev/tty 2>/dev/null || true
}
