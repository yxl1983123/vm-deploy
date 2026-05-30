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
# 支持的键：guestinfo.userdata / guestinfo.metadata / guestinfo.vendordata
# 网络配置嵌入在 metadata 的 network: 字段内，无单独的 guestinfo.network 键
govc_inject_cloudinit() {
    local vm="$1" userdata="$2" metadata="$3"

    _b64gz() { printf '%s' "$1" | gzip -9 | base64 | tr -d '\n'; }

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "[DRY-RUN] govc vm.change -vm '$vm' -e guestinfo.userdata=<gzip+b64> ..."
        return 0
    fi

    timeout "$GOVC_TIMEOUT" govc vm.change \
        -vm "$vm" \
        -e "guestinfo.userdata=$(_b64gz "$userdata")" \
        -e "guestinfo.userdata.encoding=gzip+base64" \
        -e "guestinfo.metadata=$(_b64gz "$metadata")" \
        -e "guestinfo.metadata.encoding=gzip+base64"
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

# 获取数据存储可用空间（返回 GB 整数；解析失败返回 -1）
govc_datastore_free_gb() {
    local ds="$1"
    timeout "$GOVC_TIMEOUT" govc datastore.info -json "$ds" 2>/dev/null | \
        python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    free = d['Datastores'][0]['Summary']['FreeSpace']
    print(int(free) // (1024 ** 3))
except Exception:
    sys.exit(1)
" 2>/dev/null || echo "-1"
}

# 部署前资源与环境预检查（失败返回 1，错误写入 stderr）
govc_preflight_check() {
    local errors=()

    # 1. 模板存在性验证
    if ! timeout "$GOVC_TIMEOUT" govc vm.info "$VM_TEMPLATE" &>/dev/null; then
        errors+=("模板不存在或无访问权限: $VM_TEMPLATE")
    fi

    # 2. Datastore 可用空间（仅在指定 VM_DISK_SIZE 时检查）
    if [[ -n "${VM_DISK_SIZE:-}" ]]; then
        local free_gb
        free_gb=$(govc_datastore_free_gb "$VM_DATASTORE")
        if [[ "$free_gb" -ge 0 && "$free_gb" -lt "$VM_DISK_SIZE" ]]; then
            errors+=("Datastore 可用空间不足: 可用 ${free_gb} GB，需要 ${VM_DISK_SIZE} GB（$VM_DATASTORE）")
        fi
    fi

    # 3. 静态 IP 冲突检测（仅静态网络模式）
    if [[ "${NET_TYPE:-dhcp}" == "static" && -n "${NET_IP:-}" ]]; then
        # 兼容 Linux(-W) 和 macOS(-t) 的 ping 超时参数
        if ping -c 1 -W 2 "$NET_IP" &>/dev/null 2>&1 || \
           ping -c 1 -t 2 "$NET_IP" &>/dev/null 2>&1; then
            errors+=("IP 地址已被占用: $NET_IP（请确认后再部署）")
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        printf "预检查失败:\n" >&2
        printf "  ✗ %s\n" "${errors[@]}" >&2
        return 1
    fi
    return 0
}

# 为已部署的 VM 应用 vSphere 标签
# 标签格式：category:value（多个用空格分隔）
# 若 Category / Tag 不存在则自动创建
govc_apply_tags() {
    local vm_name="$1"
    [[ -z "${VM_TAGS:-}" ]] && return 0

    # 查找 VM 在 vCenter 中的完整路径
    local vm_path
    vm_path=$(timeout "$GOVC_TIMEOUT" govc find . -type m -name "$vm_name" 2>/dev/null | head -1)
    if [[ -z "$vm_path" ]]; then
        echo "警告: 找不到 VM 路径，跳过标签应用: $vm_name" >&2
        return 0
    fi

    local pair category tag_val
    for pair in $VM_TAGS; do
        if [[ "$pair" != *:* ]]; then
            echo "警告: 忽略格式错误的标签（须为 category:value）: $pair" >&2
            continue
        fi
        category="${pair%%:*}"
        tag_val="${pair#*:}"
        [[ -z "$category" || -z "$tag_val" ]] && continue

        # 确保 Category 存在（类型限定为 VirtualMachine）
        if ! timeout "$GOVC_TIMEOUT" govc tags.category.ls 2>/dev/null | grep -qxF "$category"; then
            timeout "$GOVC_TIMEOUT" govc tags.category.create \
                -d "created by vm-deploy" -t VirtualMachine "$category" &>/dev/null \
                || { echo "警告: 无法创建 Tag Category: $category" >&2; continue; }
        fi

        # 确保 Tag 存在
        if ! timeout "$GOVC_TIMEOUT" govc tags.ls -c "$category" 2>/dev/null | grep -qxF "$tag_val"; then
            timeout "$GOVC_TIMEOUT" govc tags.create \
                -d "created by vm-deploy" -c "$category" "$tag_val" &>/dev/null \
                || { echo "警告: 无法创建 Tag: ${category}:${tag_val}" >&2; continue; }
        fi

        # 挂载标签到 VM
        timeout "$GOVC_TIMEOUT" govc tags.attach \
            -c "$category" "$tag_val" "$vm_path" 2>/dev/null \
            || echo "警告: 标签挂载失败: ${category}:${tag_val}" >&2
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
