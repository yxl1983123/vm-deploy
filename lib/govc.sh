#!/usr/bin/env bash
# govc wrapper functions

set -euo pipefail

GOVC_TIMEOUT="${GOVC_TIMEOUT:-60}"   # 每条 govc 命令超时秒数

check_govc() {
    if ! command -v govc &>/dev/null; then
        echo "错误: govc 未安装。" >&2
        echo "下载: https://github.com/vmware/govmomi/releases" >&2
        exit 1
    fi
}

# 设置连接环境变量 — 密码通过独立变量传递，不嵌入 URL
govc_connect() {
    export GOVC_URL="https://${VCENTER_HOST}/sdk"
    export GOVC_USERNAME="${VCENTER_USER}"
    export GOVC_PASSWORD="${VCENTER_PASS}"
    export GOVC_INSECURE="${VCENTER_INSECURE:-false}"
    [[ -n "${VCENTER_DC:-}" ]] && export GOVC_DATACENTER="$VCENTER_DC"

    timeout "$GOVC_TIMEOUT" govc about &>/dev/null
}

# 列出 VM 模板
govc_list_templates() {
    timeout "$GOVC_TIMEOUT" govc find . -type m -config.template true 2>/dev/null | sort
}

# 列出数据存储
govc_list_datastores() {
    timeout "$GOVC_TIMEOUT" govc ls -t Datastore . 2>/dev/null | sort
}

# 列出网络/端口组
govc_list_networks() {
    timeout "$GOVC_TIMEOUT" govc ls -t Network . 2>/dev/null | sort
}

# 检查 VM 是否已存在
govc_vm_exists() {
    timeout "$GOVC_TIMEOUT" govc vm.info "$1" &>/dev/null
}

# 从模板克隆 VM（关机态）
govc_clone_vm() {
    local template="$1" vm_name="$2"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "[DRY-RUN] govc vm.clone -vm '$template' -on=false -ds='$VM_DATASTORE'" \
             "${VM_FOLDER:+-folder='$VM_FOLDER'}" \
             "${VM_RESOURCE_POOL:+-pool='$VM_RESOURCE_POOL'}" \
             "${VM_NETWORK:+-net='$VM_NETWORK'}" \
             "'$vm_name'"
        return 0
    fi

    local args=(-vm "$template" -on=false -ds="$VM_DATASTORE")
    [[ -n "${VM_FOLDER:-}"        ]] && args+=(-folder="$VM_FOLDER")
    [[ -n "${VM_RESOURCE_POOL:-}" ]] && args+=(-pool="$VM_RESOURCE_POOL")
    [[ -n "${VM_NETWORK:-}"       ]] && args+=(-net="$VM_NETWORK")

    timeout 300 govc vm.clone "${args[@]}" "$vm_name"
}

# 调整 CPU / 内存 / 首块磁盘大小
govc_configure_vm() {
    local vm="$1"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "[DRY-RUN] govc vm.change -vm '$vm' -c $VM_CPU -m $VM_MEMORY"
        [[ -n "${VM_DISK_SIZE:-}" ]] && \
            echo "[DRY-RUN] govc vm.disk.change -vm '$vm' -disk <first> -size ${VM_DISK_SIZE}GB"
        return 0
    fi

    timeout "$GOVC_TIMEOUT" govc vm.change -vm "$vm" -c "$VM_CPU" -m "$VM_MEMORY"

    if [[ -n "${VM_DISK_SIZE:-}" ]]; then
        # 获取第一块磁盘的设备名，避免多磁盘时误操作
        local first_disk
        first_disk=$(timeout "$GOVC_TIMEOUT" govc device.ls -vm "$vm" 2>/dev/null \
                     | awk '/^disk-/{print $1; exit}')
        if [[ -n "$first_disk" ]]; then
            timeout "$GOVC_TIMEOUT" \
                govc vm.disk.change -vm "$vm" -disk "$first_disk" -size "${VM_DISK_SIZE}GB" \
                || echo "警告: 磁盘扩容失败（可能当前大小已 ≥ 目标值），继续部署" >&2
        fi
    fi
}

# 通过 guestinfo ExtraConfig 注入 cloud-init（gzip+base64）
govc_inject_cloudinit() {
    local vm="$1" userdata="$2" metadata="$3" network_config="${4:-}"

    _b64gz() { printf '%s' "$1" | gzip -9 | base64 | tr -d '\n'; }

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "[DRY-RUN] govc vm.change -vm '$vm' -e guestinfo.userdata=<gzip+b64> ..."
        return 0
    fi

    local args=(
        -vm "$vm"
        -e "guestinfo.userdata=$(_b64gz "$userdata")"
        -e "guestinfo.userdata.encoding=gzip+base64"
        -e "guestinfo.metadata=$(_b64gz "$metadata")"
        -e "guestinfo.metadata.encoding=gzip+base64"
    )

    if [[ -n "$network_config" ]]; then
        args+=(
            -e "guestinfo.network=$(_b64gz "$network_config")"
            -e "guestinfo.network.encoding=gzip+base64"
        )
    fi

    timeout "$GOVC_TIMEOUT" govc vm.change "${args[@]}"
}

# 开机
govc_power_on() {
    [[ "${DRY_RUN:-0}" -eq 1 ]] && { echo "[DRY-RUN] govc vm.power -on '$1'"; return 0; }
    timeout "$GOVC_TIMEOUT" govc vm.power -on "$1"
}

# 销毁 VM（用于回滚）
govc_destroy_vm() {
    local vm="$1"
    [[ "${DRY_RUN:-0}" -eq 1 ]] && { echo "[DRY-RUN] govc vm.destroy '$vm'"; return 0; }
    timeout "$GOVC_TIMEOUT" govc vm.power -off -force "$vm" &>/dev/null || true
    timeout "$GOVC_TIMEOUT" govc vm.destroy "$vm"
}

# 等待 VM 获取 IPv4 地址，超时返回 1
govc_get_ip() {
    local vm="$1" timeout_sec="${2:-180}"
    local start elapsed ip
    start=$(date +%s)

    while true; do
        elapsed=$(( $(date +%s) - start ))
        [[ $elapsed -gt $timeout_sec ]] && return 1

        ip=$(timeout 10 govc vm.ip "$vm" 2>/dev/null \
             | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1 || true)
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }

        sleep 5
    done
}

# SSH 可达性探测（验证 cloud-init 已完成）
wait_ssh_ready() {
    local ip="$1" user="$2" timeout_sec="${3:-180}"
    local start elapsed
    start=$(date +%s)

    while true; do
        elapsed=$(( $(date +%s) - start ))
        [[ $elapsed -gt $timeout_sec ]] && return 1

        if ssh -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 \
               -o BatchMode=yes \
               -o PasswordAuthentication=no \
               "${user}@${ip}" \
               "cloud-init status 2>/dev/null | grep -q done" 2>/dev/null; then
            return 0
        fi

        sleep 10
    done
}
