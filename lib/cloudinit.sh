#!/usr/bin/env bash
# cloud-init 配置生成

# 哈希密码（SHA-512），跨平台
_hash_pass() {
    local p="$1"
    if command -v openssl &>/dev/null && openssl passwd -6 "$p" &>/dev/null 2>&1; then
        openssl passwd -6 "$p"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import sys
try:
    import crypt
    print(crypt.crypt('$p', crypt.mksalt(crypt.METHOD_SHA512)))
except Exception:
    print('$p')
"
    else
        echo "$p"
    fi
}

generate_metadata() {
    local iid="iid-$(date +%s)-${VM_NAME//[^a-zA-Z0-9]/-}"
    cat <<EOF
instance-id: ${iid}
local-hostname: ${OS_HOSTNAME}
EOF
}

generate_userdata() {
    local hashed_pass
    hashed_pass=$(_hash_pass "$OS_PASS")

    cat <<YAML
#cloud-config
hostname: ${OS_HOSTNAME}
timezone: ${OS_TIMEZONE:-Asia/Shanghai}

users:
  - name: ${OS_USER}
    gecos: ${OS_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [sudo, adm, dialout, cdrom, audio, video, netdev]
    lock_passwd: false
    passwd: '${hashed_pass}'
YAML

    if [[ -n "${OS_SSH_KEY:-}" ]]; then
        cat <<YAML
    ssh_authorized_keys:
      - ${OS_SSH_KEY}
YAML
    fi

    cat <<YAML

package_update: true
package_upgrade: false

packages:
  - open-vm-tools
  - curl
  - wget
  - vim
  - net-tools
YAML

    if [[ -n "${OS_PACKAGES:-}" ]]; then
        for pkg in $OS_PACKAGES; do
            echo "  - $pkg"
        done
    fi

    cat <<YAML

runcmd:
  - systemctl enable --now open-vm-tools

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
      - ${NET_IP}/${NET_PREFIX}
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - ${NET_DNS1}
EOF
        [[ -n "${NET_DNS2:-}" ]] && echo "        - ${NET_DNS2}"
    fi
}
