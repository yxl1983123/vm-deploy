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
    local iid="iid-$(date +%s)-${VM_NAME//[^a-zA-Z0-9]/-}"
    cat <<EOF
instance-id: '${iid}'
local-hostname: '${OS_HOSTNAME}'
EOF
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
