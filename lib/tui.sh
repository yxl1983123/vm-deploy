#!/usr/bin/env bash
# TUI helper functions — dialog-based

set -euo pipefail

DIALOG_H=20
DIALOG_W=72
_TUI_TMP=$(mktemp)
chmod 600 "$_TUI_TMP"

trap 'rm -f "$_TUI_TMP"' EXIT

check_dialog() {
    command -v dialog &>/dev/null && return 0
    echo "dialog 未安装，正在安装..."
    if   command -v brew    &>/dev/null; then brew install dialog
    elif command -v apt-get &>/dev/null; then sudo apt-get install -y dialog
    elif command -v yum     &>/dev/null; then sudo yum install -y dialog
    else echo "错误: 请手动安装 dialog" >&2; exit 1
    fi
}

# 这些函数都在命令替换 $(...) 中被调用，其 stdout 会被捕获。
# dialog 的界面（curses 屏幕更新）默认写到 stdout，结果写到 stderr。
# 若不处理，界面会被 $() 吞进管道而无法显示——只有第一个直接调用的
# 对话框（如欢迎框）能出现，后续 $() 包裹的对话框全部不显示。
# 因此：界面 stdout 重定向到 /dev/tty（始终画在终端），结果经 stderr
# 落入临时文件后再 cat 出来，作为函数 stdout 供 $() 捕获。

# tui_input <title> <label> [default] → stdout; 1 = Cancel
tui_input() {
    dialog --title "$1" --inputbox "$2" $DIALOG_H $DIALOG_W "${3:-}" 2>"$_TUI_TMP" 1>/dev/tty
    local rc=$?; cat "$_TUI_TMP"; return $rc
}

# tui_password <title> <label> → stdout; 1 = Cancel
tui_password() {
    dialog --title "$1" --passwordbox "$2" 10 $DIALOG_W 2>"$_TUI_TMP" 1>/dev/tty
    local rc=$?; cat "$_TUI_TMP"; return $rc
}

# tui_menu <title> <label> <tag1> <item1> [...] → stdout; 1 = Cancel
tui_menu() {
    local title="$1" label="$2"; shift 2
    dialog --title "$title" --menu "$label" $DIALOG_H $DIALOG_W 12 "$@" 2>"$_TUI_TMP" 1>/dev/tty
    local rc=$?; cat "$_TUI_TMP"; return $rc
}

# tui_yesno <title> <label> → 0 = Yes, 1 = No
tui_yesno() { dialog --title "$1" --yesno "$2" $DIALOG_H $DIALOG_W; }

# tui_msgbox <title> <message>
tui_msgbox() { dialog --title "$1" --msgbox "$2" $DIALOG_H $DIALOG_W; }

# tui_infobox <title> <message>
tui_infobox() { dialog --title "$1" --infobox "$2" 5 $DIALOG_W; }

# ── 输入验证辅助 ──────────────────────────────────────────────────────────────

# RFC 1123 主机名：字母/数字/连字符，不以连字符开头/结尾，每段 ≤63 字符
validate_hostname() {
    local h="$1"
    [[ "$h" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.?)+$ ]] && \
    [[ ${#h} -le 253 ]]
}

# 简单 IPv4 格式校验
validate_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do [[ $p -le 255 ]] || return 1; done
    return 0
}

# 正整数
validate_posint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# Linux 用户名：字母开头，字母/数字/下划线/连字符，≤32 字符
validate_username() { [[ "$1" =~ ^[a-z][a-z0-9_\-]{0,31}$ ]]; }
