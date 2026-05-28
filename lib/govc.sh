#!/usr/bin/env bash
# govc wrapper functions

check_govc() {
    if ! command -v govc &>/dev/null; then
        echo "错误: govc 未安装。" >&2
        echo "下载地址: https://github.com/vmware/govmomi/releases" >&2
        exit 1
    fi
}

# 设置 govc 环境变量并验证连接
govc_connect() {
    export GOVC_URL="https://${VCENTER_USER}:${VCENTER_PASS}@${VCENTER_HOST}/sdk"
    export GOVC_INSECURE="${VCENTER_INSECURE:-true}"
    [[ -n "${VCENTER_DC:-}" ]] && export GOVC_DATACENTER="$VCENTER_DC"

    govc about &>/dev/null
}

# 列出所有 VM 模板
govc_list_templates() {
    govc find . -type m -config.template true 2>/dev/null | sort
}

# 列出数据存储
govc_list_datastores() {
    govc ls -t Datastore . 2>/dev/null | sort
}

# 列出网络
govc_list_networks() {
    govc ls -t Network . 2>/dev/null | sort
}

# 从模板克隆 VM（关机状态）
govc_clone_vm() {
    local template="$1" vm_name="$2"

    local args=(-vm "$template" -on=false -ds="$VM_DATASTORE")

    [[ -n "${VM_FOLDER:-}"        ]] && args+=(-folder="$VM_FOLDER")
    [[ -n "${VM_RESOURCE_POOL:-}" ]] && args+=(-pool="$VM_RESOURCE_POOL")
    [[ -n "${VM_NETWORK:-}"       ]] && args+=(-net="$VM_NETWORK")

    govc vm.clone "${args[@]}" "$vm_name"
}

# 调整 CPU / 内存
govc_configure_vm() {
    local vm="$1"
    govc vm.change -vm "$vm" -c "$VM_CPU" -m "$VM_MEMORY"

    if [[ -n "${VM_DISK_SIZE:-}" ]]; then
        govc vm.disk.change -vm "$vm" -size "${VM_DISK_SIZE}GB" 2>/dev/null || true
    fi
}

# 通过 guestinfo ExtraConfig 注入 cloud-init（gzip+base64）
govc_inject_cloudinit() {
    local vm="$1" userdata="$2" metadata="$3" network_config="${4:-}"

    _b64gz() { printf '%s' "$1" | gzip -9 | base64 | tr -d '\n'; }

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

    govc vm.change "${args[@]}"
}

# 开机
govc_power_on() {
    govc vm.power -on "$1"
}

# 等待 VM 获取 IP，超时返回 1
govc_get_ip() {
    local vm="$1" timeout="${2:-180}"
    local start elapsed ip
    start=$(date +%s)

    while true; do
        elapsed=$(( $(date +%s) - start ))
        [[ $elapsed -gt $timeout ]] && return 1

        ip=$(govc vm.ip "$vm" 2>/dev/null || true)
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }

        sleep 5
    done
}
