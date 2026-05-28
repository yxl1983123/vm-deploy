#!/usr/bin/env bash
# TUI helper functions using dialog

DIALOG_H=20
DIALOG_W=72
_TUI_TMP=$(mktemp)

trap 'rm -f "$_TUI_TMP"' EXIT

check_dialog() {
    if ! command -v dialog &>/dev/null; then
        echo "dialog 未安装，正在安装..."
        if command -v brew &>/dev/null; then
            brew install dialog
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y dialog
        elif command -v yum &>/dev/null; then
            sudo yum install -y dialog
        else
            echo "错误: 请手动安装 dialog" >&2
            exit 1
        fi
    fi
}

# tui_input <title> <label> [default] → stdout; returns 1 on Cancel
tui_input() {
    dialog --title "$1" --inputbox "$2" $DIALOG_H $DIALOG_W "${3:-}" 2>"$_TUI_TMP"
    local rc=$?
    cat "$_TUI_TMP"
    return $rc
}

# tui_password <title> <label> → stdout; returns 1 on Cancel
tui_password() {
    dialog --title "$1" --passwordbox "$2" 10 $DIALOG_W 2>"$_TUI_TMP"
    local rc=$?
    cat "$_TUI_TMP"
    return $rc
}

# tui_menu <title> <label> <tag1> <item1> [tag2 item2 ...] → stdout; returns 1 on Cancel
tui_menu() {
    local title="$1" label="$2"; shift 2
    dialog --title "$title" --menu "$label" $DIALOG_H $DIALOG_W 12 "$@" 2>"$_TUI_TMP"
    local rc=$?
    cat "$_TUI_TMP"
    return $rc
}

# tui_yesno <title> <label> → returns 0 for Yes, 1 for No
tui_yesno() {
    dialog --title "$1" --yesno "$2" $DIALOG_H $DIALOG_W
}

# tui_msgbox <title> <message>
tui_msgbox() {
    dialog --title "$1" --msgbox "$2" $DIALOG_H $DIALOG_W
}

# tui_infobox <title> <message>  (no button, auto-dismiss)
tui_infobox() {
    dialog --title "$1" --infobox "$2" 5 $DIALOG_W
}
