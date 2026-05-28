#!/usr/bin/env bash
# vm-deploy — 通过 govc + cloud-init 自动化部署 Ubuntu 24.04 到 VMware
# https://github.com/yxl1983123/vm-deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/tui.sh"
source "$SCRIPT_DIR/lib/govc.sh"
source "$SCRIPT_DIR/lib/cloudinit.sh"

VERSION="1.0.0"
SAVED_CONFIG="${HOME}/.vm-deploy.env"
LOG_FILE="/tmp/vm-deploy-$(date +%Y%m%d-%H%M%S).log"

# ── 全局参数 ──────────────────────────────────────────────────────────────────
VCENTER_HOST="" VCENTER_USER="" VCENTER_PASS="" VCENTER_DC="" VCENTER_INSECURE="true"
VM_NAME="" VM_TEMPLATE="" VM_FOLDER="" VM_DATASTORE="" VM_NETWORK="" VM_RESOURCE_POOL=""
VM_CPU="2" VM_MEMORY="4096" VM_DISK_SIZE=""
NET_TYPE="dhcp" NET_IP="" NET_PREFIX="24" NET_GATEWAY="" NET_DNS1="114.114.114.114" NET_DNS2="8.8.8.8"
OS_HOSTNAME="" OS_USER="ubuntu" OS_PASS="" OS_SSH_KEY="" OS_TIMEZONE="Asia/Shanghai" OS_PACKAGES=""

# ── 配置持久化 ─────────────────────────────────────────────────────────────────
load_config() {
    [[ -f "$SAVED_CONFIG" ]] && source "$SAVED_CONFIG" 2>/dev/null || true
}

save_config() {
    cat > "$SAVED_CONFIG" <<EOF
# vm-deploy 已保存配置（密码不保存）
VCENTER_HOST="${VCENTER_HOST}"
VCENTER_USER="${VCENTER_USER}"
VCENTER_DC="${VCENTER_DC}"
VCENTER_INSECURE="${VCENTER_INSECURE}"
VM_FOLDER="${VM_FOLDER}"
VM_DATASTORE="${VM_DATASTORE}"
VM_NETWORK="${VM_NETWORK}"
VM_RESOURCE_POOL="${VM_RESOURCE_POOL}"
VM_TEMPLATE="${VM_TEMPLATE}"
VM_CPU="${VM_CPU}"
VM_MEMORY="${VM_MEMORY}"
OS_USER="${OS_USER}"
OS_TIMEZONE="${OS_TIMEZONE}"
NET_DNS1="${NET_DNS1}"
NET_DNS2="${NET_DNS2}"
EOF
    chmod 600 "$SAVED_CONFIG"
}

# ── 步骤 1：vCenter 连接 ───────────────────────────────────────────────────────
step_vcenter() {
    VCENTER_HOST=$(tui_input "vCenter 连接  [1/5]" "vCenter / ESXi 主机地址:" "$VCENTER_HOST") \
        || { clear; exit 0; }
    [[ -z "$VCENTER_HOST" ]] && { tui_msgbox "错误" "主机地址不能为空。"; step_vcenter; return; }

    VCENTER_USER=$(tui_input "vCenter 连接  [1/5]" "登录用户名:" "${VCENTER_USER:-administrator@vsphere.local}") \
        || { clear; exit 0; }

    VCENTER_PASS=$(tui_password "vCenter 连接  [1/5]" "登录密码:") \
        || { clear; exit 0; }

    VCENTER_DC=$(tui_input "vCenter 连接  [1/5]" "数据中心名称 (留空使用默认):" "$VCENTER_DC") \
        || { clear; exit 0; }

    tui_infobox "连接中" "正在连接 $VCENTER_HOST ..."
    if ! govc_connect; then
        tui_msgbox "连接失败" \
"无法连接到 vCenter: $VCENTER_HOST

请检查:
  • 主机地址是否正确
  • 用户名 / 密码是否正确
  • 网络是否可达
  • SSL 证书问题 (INSECURE=true 默认已忽略)"
        step_vcenter
    fi
}

# ── 步骤 2：VM 位置与资源 ─────────────────────────────────────────────────────
step_placement() {
    tui_infobox "加载资源" "正在从 vCenter 获取模板、数据存储和网络列表..."

    # 模板选择
    local templates=()
    mapfile -t templates < <(govc_list_templates)
    if [[ ${#templates[@]} -eq 0 ]]; then
        tui_msgbox "未找到模板" \
"在 vCenter 中未找到 VM 模板。

请先按照 README.md 中的说明创建 Ubuntu 24.04 模板，
确保已安装 open-vm-tools 和 cloud-init。"
        exit 1
    fi
    local tmpl_menu=()
    for t in "${templates[@]}"; do tmpl_menu+=("$t" " "); done
    VM_TEMPLATE=$(tui_menu "选择模板  [2/5]" "选择 Ubuntu 24.04 VM 模板:" "${tmpl_menu[@]}") \
        || { clear; exit 0; }

    # 数据存储
    local datastores=()
    mapfile -t datastores < <(govc_list_datastores)
    local ds_menu=()
    for d in "${datastores[@]}"; do ds_menu+=("$d" " "); done
    VM_DATASTORE=$(tui_menu "数据存储  [2/5]" "选择目标数据存储:" "${ds_menu[@]}") \
        || { clear; exit 0; }

    # 网络
    local networks=()
    mapfile -t networks < <(govc_list_networks)
    local net_menu=()
    for n in "${networks[@]}"; do net_menu+=("$n" " "); done
    VM_NETWORK=$(tui_menu "网络  [2/5]" "选择 VM 连接的端口组/网络:" "${net_menu[@]}") \
        || { clear; exit 0; }

    VM_FOLDER=$(tui_input "VM 位置  [2/5]" \
        "VM 文件夹路径 (相对数据中心 vm 目录, 留空放根目录):" "$VM_FOLDER") \
        || { clear; exit 0; }

    VM_RESOURCE_POOL=$(tui_input "VM 位置  [2/5]" \
        "资源池路径 (留空使用默认资源池):" "$VM_RESOURCE_POOL") \
        || { clear; exit 0; }
}

# ── 步骤 3：VM 规格 ───────────────────────────────────────────────────────────
step_vmspecs() {
    VM_NAME=$(tui_input "VM 规格  [3/5]" "VM 名称:" "") \
        || { clear; exit 0; }
    [[ -z "$VM_NAME" ]] && { tui_msgbox "错误" "VM 名称不能为空。"; step_vmspecs; return; }

    VM_CPU=$(tui_input "VM 规格  [3/5]" "CPU 核心数:" "${VM_CPU:-2}") \
        || { clear; exit 0; }

    VM_MEMORY=$(tui_input "VM 规格  [3/5]" "内存大小 (MB, 如 4096 = 4GB):" "${VM_MEMORY:-4096}") \
        || { clear; exit 0; }

    VM_DISK_SIZE=$(tui_input "VM 规格  [3/5]" \
        "系统盘扩容至 (GB), 留空保持模板大小:" "${VM_DISK_SIZE:-}") \
        || { clear; exit 0; }
}

# ── 步骤 4：网络配置 ──────────────────────────────────────────────────────────
step_network() {
    NET_TYPE=$(tui_menu "网络配置  [4/5]" "IP 分配方式:" \
        "dhcp"   "DHCP — 自动获取 IP 地址" \
        "static" "静态 IP — 手动指定地址") \
        || { clear; exit 0; }

    if [[ "$NET_TYPE" == "static" ]]; then
        NET_IP=$(tui_input "静态 IP  [4/5]" "IP 地址 (如 192.168.1.100):" "${NET_IP:-}") \
            || { clear; exit 0; }
        [[ -z "$NET_IP" ]] && { tui_msgbox "错误" "IP 地址不能为空。"; step_network; return; }

        NET_PREFIX=$(tui_input "静态 IP  [4/5]" "子网前缀长度 (如 24 表示 /24):" "${NET_PREFIX:-24}") \
            || { clear; exit 0; }

        NET_GATEWAY=$(tui_input "静态 IP  [4/5]" "默认网关:" "${NET_GATEWAY:-}") \
            || { clear; exit 0; }
        [[ -z "$NET_GATEWAY" ]] && { tui_msgbox "错误" "网关不能为空。"; step_network; return; }

        NET_DNS1=$(tui_input "静态 IP  [4/5]" "首选 DNS:" "${NET_DNS1:-114.114.114.114}") \
            || { clear; exit 0; }

        NET_DNS2=$(tui_input "静态 IP  [4/5]" "备用 DNS (留空跳过):" "${NET_DNS2:-8.8.8.8}") \
            || { clear; exit 0; }
    fi
}

# ── 步骤 5：操作系统配置 ──────────────────────────────────────────────────────
step_os() {
    OS_HOSTNAME=$(tui_input "系统配置  [5/5]" "主机名 (hostname):" "${VM_NAME}") \
        || { clear; exit 0; }
    [[ -z "$OS_HOSTNAME" ]] && OS_HOSTNAME="$VM_NAME"

    OS_USER=$(tui_input "系统配置  [5/5]" "管理员用户名:" "${OS_USER:-ubuntu}") \
        || { clear; exit 0; }

    local p1 p2
    p1=$(tui_password "系统配置  [5/5]" "管理员密码:") || { clear; exit 0; }
    p2=$(tui_password "系统配置  [5/5]" "确认密码:")   || { clear; exit 0; }
    if [[ "$p1" != "$p2" ]]; then
        tui_msgbox "密码不匹配" "两次输入的密码不一致，请重新设置。"
        step_os; return
    fi
    OS_PASS="$p1"

    OS_SSH_KEY=$(tui_input "系统配置  [5/5]" \
        "SSH 公钥 (粘贴 public key, 留空仅允许密码登录):" "${OS_SSH_KEY:-}") \
        || { clear; exit 0; }

    OS_TIMEZONE=$(tui_input "系统配置  [5/5]" "时区:" "${OS_TIMEZONE:-Asia/Shanghai}") \
        || { clear; exit 0; }

    OS_PACKAGES=$(tui_input "系统配置  [5/5]" \
        "额外安装包 (空格分隔, 如: git htop nmap, 留空跳过):" "${OS_PACKAGES:-}") \
        || { clear; exit 0; }
}

# ── 确认摘要 ──────────────────────────────────────────────────────────────────
step_confirm() {
    local net_info="DHCP 自动分配"
    [[ "$NET_TYPE" == "static" ]] && \
        net_info="${NET_IP}/${NET_PREFIX}  GW: ${NET_GATEWAY}  DNS: ${NET_DNS1}"

    tui_yesno "确认部署配置" \
"───────────── vCenter ──────────────
  主机:      $VCENTER_HOST
  用户:      $VCENTER_USER
  数据中心:  ${VCENTER_DC:-默认}

─────────────── VM ─────────────────
  名称:      $VM_NAME
  模板:      $VM_TEMPLATE
  CPU/内存:  ${VM_CPU} 核 / ${VM_MEMORY} MB
  磁盘:      ${VM_DISK_SIZE:-模板默认} GB
  数据存储:  $VM_DATASTORE
  网络:      $VM_NETWORK
  文件夹:    ${VM_FOLDER:-根目录}

──────────────── 网络 ───────────────
  $net_info

──────────────── 系统 ───────────────
  主机名:    $OS_HOSTNAME
  用户:      $OS_USER
  SSH Key:   ${OS_SSH_KEY:+已配置}${OS_SSH_KEY:-未配置}
  时区:      $OS_TIMEZONE

确认开始部署？"
}

# ── 执行部署 ──────────────────────────────────────────────────────────────────
do_deploy() {
    local deploy_ok=0

    (
        pct() { printf "%d\nXXX\n%s\nXXX\n" "$1" "$2"; }

        pct 5 "[ 1/5 ]  正在克隆虚拟机: $VM_NAME ..."
        if ! govc_clone_vm "$VM_TEMPLATE" "$VM_NAME" >>"$LOG_FILE" 2>&1; then
            pct 100 "✗ 克隆失败！日志: $LOG_FILE"
            sleep 2; exit 1
        fi

        pct 28 "[ 2/5 ]  配置硬件规格 — CPU: $VM_CPU  内存: ${VM_MEMORY}MB ..."
        govc_configure_vm "$VM_NAME" >>"$LOG_FILE" 2>&1 || true

        pct 48 "[ 3/5 ]  生成 cloud-init 配置..."
        USERDATA=$(generate_userdata)
        METADATA=$(generate_metadata)
        NETWORK_CONFIG=$(generate_network_config)

        pct 65 "[ 4/5 ]  注入 cloud-init 数据 (guestinfo ExtraConfig)..."
        if ! govc_inject_cloudinit "$VM_NAME" "$USERDATA" "$METADATA" "$NETWORK_CONFIG" >>"$LOG_FILE" 2>&1; then
            pct 100 "✗ cloud-init 注入失败！日志: $LOG_FILE"
            sleep 2; exit 1
        fi

        pct 82 "[ 5/5 ]  启动虚拟机..."
        if ! govc_power_on "$VM_NAME" >>"$LOG_FILE" 2>&1; then
            pct 100 "✗ 启动失败！日志: $LOG_FILE"
            sleep 2; exit 1
        fi

        pct 100 "✓ 部署完成！VM 正在启动并执行 cloud-init 初始化..."
        sleep 1

    ) | dialog --title "VM 部署进度" --gauge "初始化中..." 10 72 0 || deploy_ok=$?

    if [[ $deploy_ok -ne 0 ]]; then
        tui_msgbox "部署失败" "部署过程中发生错误。\n\n详细日志: $LOG_FILE"
        return 1
    fi

    dialog --title "等待 IP" --infobox \
        "正在等待 VM 获取 IP 地址（最长等待 3 分钟）..." 5 55

    local vm_ip
    vm_ip=$(govc_get_ip "$VM_NAME" 180) \
        || vm_ip="(暂未获取，请稍后在 vCenter 中查看)"

    save_config

    tui_msgbox "部署成功" \
"✓  虚拟机已成功部署！

  VM 名称:   $VM_NAME
  IP 地址:   $vm_ip
  用户名:    $OS_USER
  主机名:    $OS_HOSTNAME

  SSH 登录:  ssh ${OS_USER}@${vm_ip}

提示: cloud-init 首次配置约需 1~2 分钟，
      如 SSH 无法立即连接请稍等后重试。

日志文件:   $LOG_FILE"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    check_dialog
    check_govc
    load_config

    dialog --title "VM Deploy  v${VERSION}" --msgbox \
"欢迎使用 VM Deploy v${VERSION}

  通过 govc + cloud-init 自动化部署 Ubuntu 24.04

功能特性:
  • 从 vCenter 模板克隆虚拟机
  • 通过 guestinfo ExtraConfig 注入 cloud-init（无需 ISO）
  • 支持 DHCP / 静态 IP 配置
  • 自动完成系统初始化（用户、SSH Key、软件包）
  • 保存上次配置供下次复用

按 Enter 开始配置向导..." 16 62

    step_vcenter
    step_placement
    step_vmspecs
    step_network
    step_os

    if step_confirm; then
        do_deploy
    else
        tui_msgbox "已取消" "部署已取消，未对 vCenter 做任何修改。"
    fi

    clear
    echo "VM Deploy 完成。日志: $LOG_FILE"
}

main "$@"
