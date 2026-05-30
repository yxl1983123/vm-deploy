#!/usr/bin/env bash
# cloud-init 配置生成

set -euo pipefail

# SHA-512 密码哈希 — 通过 stdin 传入，不做字符串插值，避免注入
_hash_pass() {
    local p="$1"

    if command -v openssl &>/dev/null; then
        # openssl passwd -6 在 macOS 和 Linux 上均可用
        local h
        h=$(printf '%s' "$p" | openssl passwd -6 -stdin 2>/dev/null) \
            || { echo "错误: openssl 密码哈希失败" >&2; return 1; }
        echo "$h"
        return 0
    fi

    if command -v python3 &>/dev/null; then
        local h
        h=$(printf '%s' "$p" | python3 -c "
import sys, hashlib, crypt, os
try:
    p = sys.stdin.read()
    print(crypt.crypt(p, crypt.mksalt(crypt.METHOD_SHA512)))
except Exception as e:
    sys.stderr.write('python crypt failed: ' + str(e) + '\n')
    sys.exit(1)
" 2>/dev/null) || { echo "错误: python3 密码哈希失败" >&2; return 1; }
        echo "$h"
        return 0
    fi

    echo "错误: 未找到可用的密码哈希工具 (openssl 或 python3)" >&2
    return 1
}

# 验证用户输入中不含 YAML 危险字符（防止注入）
_yaml_safe() {
    local val="$1" name="$2"
    if [[ "$val" =~ [\'\"\\$\`] || "$val" =~ $'\n' ]]; then
        echo "错误: $name 包含不允许的字符" >&2
        return 1
    fi
}

generate_metadata() {
    local net_config="${1:-}"
    local iid="iid-$(date +%s)-${VM_NAME//[^a-zA-Z0-9]/-}"

    cat <<EOF
instance-id: '${iid}'
local-hostname: '${OS_HOSTNAME}'
EOF

    # 用户自定义 metadata 字段（YAML key: value 格式，直接追加）
    if [[ -n "${VM_EXTRA_METADATA:-}" ]]; then
        printf '%s\n' "${VM_EXTRA_METADATA}"
    fi

    # 将 network config 嵌入 metadata 的 network: 字段（官方支持的唯一传递方式）
    if [[ -n "$net_config" ]]; then
        echo "network:"
        while IFS= read -r line; do
            printf '  %s\n' "$line"
        done <<< "$net_config"
    fi
}

generate_userdata() {
    # 验证关键字段格式
    _yaml_safe "$OS_USER"     "用户名"  || return 1
    _yaml_safe "$OS_HOSTNAME" "主机名"  || return 1
    _yaml_safe "$OS_TIMEZONE" "时区"    || return 1

    local hashed_pass
    hashed_pass=$(_hash_pass "$OS_PASS") || return 1

    # sudo 策略：生产默认要求密码；可通过 OS_SUDO_NOPASSWD=1 覆盖
    local sudo_policy="ALL=(ALL) ALL"
    [[ "${OS_SUDO_NOPASSWD:-0}" == "1" ]] && sudo_policy="ALL=(ALL) NOPASSWD:ALL"

    cat <<YAML
#cloud-config
hostname: '${OS_HOSTNAME}'
timezone: '${OS_TIMEZONE:-Asia/Shanghai}'

users:
  - name: '${OS_USER}'
    gecos: '${OS_USER}'
    sudo: '${sudo_policy}'
    shell: /bin/bash
    groups: [sudo, adm, dialout, cdrom, audio, video, netdev]
    lock_passwd: false
    passwd: '${hashed_pass}'
YAML

    if [[ -n "${OS_SSH_KEY:-}" ]]; then
        _yaml_safe "$OS_SSH_KEY" "SSH 公钥" || return 1
        cat <<YAML
    ssh_authorized_keys:
      - '${OS_SSH_KEY}'
YAML
    fi

    cat <<YAML

package_update: true
package_upgrade: true

packages:
  - open-vm-tools
  - unattended-upgrades
  - curl
  - wget
  - vim
  - net-tools
YAML

    if [[ -n "${OS_PACKAGES:-}" ]]; then
        for pkg in $OS_PACKAGES; do
            echo "  - '${pkg}'"
        done
    fi

    cat <<YAML

runcmd:
  - systemctl enable --now open-vm-tools
  - systemctl enable --now unattended-upgrades
YAML

    # 数据磁盘自动格式化并挂载
    # VMware 追加磁盘按 SCSI 顺序排列：系统盘 sda，额外磁盘依次 sdb sdc ...
    if [[ -n "${VM_DATA_DISKS:-}" ]]; then
        local letters=( b c d e f g h i j )
        local idx=0
        for dsize in $VM_DATA_DISKS; do
            local dev="/dev/sd${letters[$idx]}"
            local mp; [[ $idx -eq 0 ]] && mp="/data" || mp="/data${idx}"
            # 仅在设备存在且未格式化时操作，防止重复运行覆盖数据
            printf '  - [ bash, -c, "if [ -b %s ] && ! blkid %s >/dev/null 2>&1; then mkfs.ext4 -F %s && mkdir -p %s && echo \"%s %s ext4 defaults,nofail 0 2\" >> /etc/fstab && mount %s && chmod 755 %s; fi" ]\n' \
                "$dev" "$dev" "$dev" "$mp" "$dev" "$mp" "$mp" "$mp"
            ((idx++))
        done
    fi

    # 用户自定义启动命令（每行一条，追加到 runcmd 末尾）
    if [[ -n "${OS_EXTRA_RUNCMD:-}" ]]; then
        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            # 若已是 YAML 列表格式（以可选空格 + '- ' 开头），直接输出；否则补充 '  - '
            if [[ "$cmd" =~ ^[[:space:]]*- ]]; then
                printf '%s\n' "$cmd"
            else
                printf '  - %s\n' "$cmd"
            fi
        done <<< "${OS_EXTRA_RUNCMD}"
    fi

    # 用户自定义写入文件（write_files 列表条目，用户提供 '- path:' 开头的 YAML）
    if [[ -n "${OS_WRITE_FILES:-}" ]]; then
        echo ""
        echo "write_files:"
        while IFS= read -r line; do
            printf '%s\n' "$line"
        done <<< "${OS_WRITE_FILES}"
    fi

    cat <<YAML

final_message: "cloud-init 完成，VM ${VM_NAME} 已就绪。"
YAML
}

generate_network_config() {
    if [[ "${NET_TYPE:-dhcp}" == "dhcp" ]]; then
        cat <<EOF
version: 2
ethernets:
  mainif:
    match:
      name: "en*"
    dhcp4: true
    dhcp6: false
EOF
    else
        cat <<EOF
version: 2
ethernets:
  mainif:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - '${NET_IP}/${NET_PREFIX}'
    routes:
      - to: default
        via: '${NET_GATEWAY}'
    nameservers:
      addresses:
        - '${NET_DNS1}'
EOF
        [[ -n "${NET_DNS2:-}" ]] && echo "        - '${NET_DNS2}'"
    fi
}
