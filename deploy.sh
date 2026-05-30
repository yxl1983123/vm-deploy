#!/usr/bin/env bash
# vm-deploy — 通过 govc + cloud-init 自动化部署 Ubuntu 24.04 到 VMware
# https://github.com/yxl1983123/vm-deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/tui.sh"
source "$SCRIPT_DIR/lib/govc.sh"
source "$SCRIPT_DIR/lib/cloudinit.sh"

VERSION="1.1.0"
SAVED_CONFIG="${HOME}/.vm-deploy.env"
LOG_FILE="/tmp/vm-deploy-$(date +%Y%m%d-%H%M%S).log"

# ── 运行模式 ──────────────────────────────────────────────────────────────────
DRY_RUN=0
BATCH_MODE=0

# ── 全局参数（TUI 或环境变量填充） ────────────────────────────────────────────
VCENTER_HOST=""  VCENTER_USER=""  VCENTER_PASS=""
VCENTER_DC=""    VCENTER_INSECURE="false"

VM_NAME=""       VM_TEMPLATE=""   VM_FOLDER=""
VM_DATASTORE=""  VM_NETWORK=""    VM_RESOURCE_POOL=""
VM_CPU="2"       VM_MEMORY="4096" VM_DISK_SIZE=""

NET_TYPE="dhcp"  NET_IP=""        NET_PREFIX="24"
NET_GATEWAY=""   NET_DNS1="114.114.114.114" NET_DNS2="8.8.8.8"

OS_HOSTNAME=""   OS_USER="ubuntu"  OS_PASS=""
OS_SSH_KEY=""    OS_TIMEZONE="Asia/Shanghai"
OS_PACKAGES=""   OS_SUDO_NOPASSWD="0"

VM_EXTRA_METADATA="" # 追加到 cloud-init metadata 的自定义 YAML 字段
OS_EXTRA_RUNCMD=""   # 自定义启动命令（每行一条 shell 命令）
OS_WRITE_FILES=""    # write_files YAML 列表条目（每条以 '- path:' 开头）
VM_TAGS=""           # vSphere 标签（格式: category:value，多个用空格分隔）

# ── 参数解析 ──────────────────────────────────────────────────────────────────
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1  ;;
            --batch)   BATCH_MODE=1 ;;
            --help|-h) show_help; exit 0 ;;
            *) echo "未知参数: $arg" >&2; show_help; exit 1 ;;
        esac
    done
}

show_help() {
    cat <<'EOF'
用法: deploy.sh [--dry-run] [--batch] [--help]

  --dry-run   模拟运行：打印将执行的操作，生成 cloud-init YAML，不实际部署
  --batch     非交互批量模式：从环境变量读取参数，跳过 TUI（适合 CI/CD）
  --help      显示帮助

批量模式必填环境变量:
  VCENTER_HOST, VCENTER_USER, VCENTER_PASS
  VM_NAME, VM_TEMPLATE, VM_DATASTORE, VM_NETWORK
  OS_HOSTNAME, OS_USER, OS_PASS

可选环境变量:
  VCENTER_DC, VCENTER_INSECURE (默认 false)
  VM_FOLDER, VM_RESOURCE_POOL, VM_CPU (默认 2), VM_MEMORY (默认 4096)
  VM_DISK_SIZE (GB, 留空保持模板大小)
  NET_TYPE (dhcp|static, 默认 dhcp)
  NET_IP, NET_PREFIX, NET_GATEWAY, NET_DNS1, NET_DNS2 (静态IP时必填)
  OS_SSH_KEY, OS_TIMEZONE (默认 Asia/Shanghai), OS_PACKAGES
  OS_SUDO_NOPASSWD (0=需要密码[默认], 1=免密sudo)
  VM_EXTRA_METADATA  追加到 metadata 的自定义字段 (YAML key: value, 多行用 $'\n' 分隔)
  OS_EXTRA_RUNCMD    额外启动命令 (每行一条, 多行用 $'\n' 分隔)
  OS_WRITE_FILES     write_files 列表条目 (每条从 '- path:' 开始, 多行用 $'\n' 分隔)
  VM_TAGS            vSphere 标签 (格式: "env:prod team:ops", 多个用空格分隔)

示例:
  VCENTER_HOST=vc.example.com VCENTER_USER=admin@vsphere.local VCENTER_PASS=Secret \
  VM_NAME=prod-web-01 VM_TEMPLATE=/DC/vm/ubuntu-2404-template \
  VM_DATASTORE=/DC/datastore/vsan VM_NETWORK="/DC/network/prod" \
  NET_TYPE=static NET_IP=192.168.1.100 NET_PREFIX=24 \
  NET_GATEWAY=192.168.1.1 NET_DNS1=114.114.114.114 \
  OS_HOSTNAME=prod-web-01 OS_USER=ubuntu OS_PASS=MyPass123 \
  ./deploy.sh --batch
EOF
}

# ── 安全解析配置文件（不使用 source，白名单键） ───────────────────────────────
load_config() {
    [[ ! -f "$SAVED_CONFIG" ]] && return 0

    local _WHITELIST=(
        VCENTER_HOST VCENTER_USER VCENTER_DC VCENTER_INSECURE
        VM_FOLDER VM_DATASTORE VM_NETWORK VM_RESOURCE_POOL VM_TEMPLATE
        VM_CPU VM_MEMORY OS_USER OS_TIMEZONE NET_TYPE NET_DNS1 NET_DNS2
    )

    local line key val
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue
        # 匹配 KEY="VALUE" 或 KEY=VALUE
        [[ "$line" =~ ^([A-Z_]+)=\"?([^\"]*)\"?$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        for _k in "${_WHITELIST[@]}"; do
            if [[ "$key" == "$_k" ]]; then
                printf -v "$key" '%s' "$val"
                break
            fi
        done
    done < "$SAVED_CONFIG"
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
NET_TYPE="${NET_TYPE}"
NET_DNS1="${NET_DNS1}"
NET_DNS2="${NET_DNS2}"
EOF
    chmod 600 "$SAVED_CONFIG"
}

# ── 批量模式参数校验 ──────────────────────────────────────────────────────────
batch_validate() {
    local missing=()
    local required=(VCENTER_HOST VCENTER_USER VCENTER_PASS
                    VM_NAME VM_TEMPLATE VM_DATASTORE VM_NETWORK
                    OS_HOSTNAME OS_USER OS_PASS)

    for var in "${required[@]}"; do
        [[ -z "${!var:-}" ]] && missing+=("$var")
    done

    if [[ "${NET_TYPE:-dhcp}" == "static" ]]; then
        for var in NET_IP NET_PREFIX NET_GATEWAY NET_DNS1; do
            [[ -z "${!var:-}" ]] && missing+=("$var")
        done
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "错误: 批量模式缺少以下必填环境变量:" >&2
        printf "  - %s\n" "${missing[@]}" >&2
        echo "运行 './deploy.sh --help' 查看完整说明" >&2
        exit 1
    fi
}

# ── 步骤 1：vCenter 连接 ──────────────────────────────────────────────────────
step_vcenter() {
    VCENTER_HOST=$(tui_input "vCenter 连接  [1/6]" \
        "vCenter / ESXi 主机地址:" "$VCENTER_HOST") || { clear; exit 0; }
    [[ -z "$VCENTER_HOST" ]] && { tui_msgbox "错误" "主机地址不能为空。"; step_vcenter; return; }

    VCENTER_USER=$(tui_input "vCenter 连接  [1/6]" \
        "登录用户名:" "${VCENTER_USER:-administrator@vsphere.local}") || { clear; exit 0; }

    VCENTER_PASS=$(tui_password "vCenter 连接  [1/6]" "登录密码:") || { clear; exit 0; }

    VCENTER_DC=$(tui_input "vCenter 连接  [1/6]" \
        "数据中心名称 (留空使用默认):" "$VCENTER_DC") || { clear; exit 0; }

    local insecure_choice
    insecure_choice=$(tui_menu "SSL 证书  [1/6]" "TLS 证书验证:" \
        "false" "验证证书 (推荐，生产环境)" \
        "true"  "跳过验证 (仅用于测试环境)") || { clear; exit 0; }
    VCENTER_INSECURE="$insecure_choice"

    tui_infobox "连接中" "正在连接 $VCENTER_HOST ..."
    if ! govc_connect; then
        tui_msgbox "连接失败" \
"无法连接到 vCenter: $VCENTER_HOST

请检查:
  • 主机地址是否正确
  • 用户名 / 密码是否正确
  • 网络是否可达
  • 证书验证设置是否与服务器匹配"
        step_vcenter
    fi
}

# ── 步骤 2：VM 位置与资源 ─────────────────────────────────────────────────────
step_placement() {
    tui_infobox "加载资源" "正在从 vCenter 获取模板、数据存储和网络列表..."

    local templates=()
    mapfile -t templates < <(govc_list_templates)
    if [[ ${#templates[@]} -eq 0 ]]; then
        tui_msgbox "未找到模板" \
"在 vCenter 中未找到 VM 模板。

请先按照 README.md 的说明制作 Ubuntu 24.04 模板，
确保已安装 open-vm-tools 和 cloud-init 并启用 VMware 数据源。"
        exit 1
    fi
    local tmpl_menu=()
    for t in "${templates[@]}"; do tmpl_menu+=("$t" " "); done
    VM_TEMPLATE=$(tui_menu "选择模板  [2/6]" \
        "选择 Ubuntu 24.04 VM 模板:" "${tmpl_menu[@]}") || { clear; exit 0; }

    local datastores=()
    mapfile -t datastores < <(govc_list_datastores)
    local ds_menu=()
    for d in "${datastores[@]}"; do ds_menu+=("$d" " "); done
    VM_DATASTORE=$(tui_menu "数据存储  [2/6]" \
        "选择目标数据存储:" "${ds_menu[@]}") || { clear; exit 0; }

    local networks=()
    mapfile -t networks < <(govc_list_networks)
    local net_menu=()
    for n in "${networks[@]}"; do net_menu+=("$n" " "); done
    VM_NETWORK=$(tui_menu "网络  [2/6]" \
        "选择 VM 连接的端口组/网络:" "${net_menu[@]}") || { clear; exit 0; }

    VM_FOLDER=$(tui_input "VM 位置  [2/6]" \
        "VM 文件夹路径 (相对 vm 目录, 留空放根目录):" "$VM_FOLDER") || { clear; exit 0; }

    VM_RESOURCE_POOL=$(tui_input "VM 位置  [2/6]" \
        "资源池路径 (留空使用默认):" "$VM_RESOURCE_POOL") || { clear; exit 0; }
}

# ── 步骤 3：VM 规格 ───────────────────────────────────────────────────────────
step_vmspecs() {
    local name cpu mem disk

    name=$(tui_input "VM 规格  [3/6]" "VM 名称:" "") || { clear; exit 0; }
    [[ -z "$name" ]] && { tui_msgbox "错误" "VM 名称不能为空。"; step_vmspecs; return; }
    VM_NAME="$name"

    cpu=$(tui_input "VM 规格  [3/6]" "CPU 核心数:" "${VM_CPU:-2}") || { clear; exit 0; }
    if ! validate_posint "$cpu"; then
        tui_msgbox "错误" "CPU 核心数必须为正整数。"; step_vmspecs; return
    fi
    VM_CPU="$cpu"

    mem=$(tui_input "VM 规格  [3/6]" "内存 (MB, 如 4096 = 4GB):" "${VM_MEMORY:-4096}") \
        || { clear; exit 0; }
    if ! validate_posint "$mem"; then
        tui_msgbox "错误" "内存大小必须为正整数 (MB)。"; step_vmspecs; return
    fi
    VM_MEMORY="$mem"

    disk=$(tui_input "VM 规格  [3/6]" \
        "系统盘扩容至 (GB), 留空保持模板大小:" "${VM_DISK_SIZE:-}") || { clear; exit 0; }
    if [[ -n "$disk" ]] && ! validate_posint "$disk"; then
        tui_msgbox "错误" "磁盘大小必须为正整数 (GB)。"; step_vmspecs; return
    fi
    VM_DISK_SIZE="$disk"
}

# ── 步骤 4：网络配置 ──────────────────────────────────────────────────────────
step_network() {
    NET_TYPE=$(tui_menu "网络配置  [4/6]" "IP 分配方式:" \
        "dhcp"   "DHCP — 自动获取 IP 地址" \
        "static" "静态 IP — 手动指定地址") || { clear; exit 0; }

    if [[ "$NET_TYPE" == "static" ]]; then
        local ip pfx gw dns1 dns2

        ip=$(tui_input "静态 IP  [4/6]" \
            "IP 地址 (如 192.168.1.100):" "${NET_IP:-}") || { clear; exit 0; }
        if ! validate_ipv4 "$ip"; then
            tui_msgbox "错误" "IP 地址格式无效。"; step_network; return
        fi
        NET_IP="$ip"

        pfx=$(tui_input "静态 IP  [4/6]" \
            "子网前缀长度 (如 24):" "${NET_PREFIX:-24}") || { clear; exit 0; }
        if ! [[ "$pfx" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
            tui_msgbox "错误" "前缀长度须为 0~32 的整数。"; step_network; return
        fi
        NET_PREFIX="$pfx"

        gw=$(tui_input "静态 IP  [4/6]" \
            "默认网关:" "${NET_GATEWAY:-}") || { clear; exit 0; }
        if ! validate_ipv4 "$gw"; then
            tui_msgbox "错误" "网关地址格式无效。"; step_network; return
        fi
        NET_GATEWAY="$gw"

        dns1=$(tui_input "静态 IP  [4/6]" \
            "首选 DNS:" "${NET_DNS1:-114.114.114.114}") || { clear; exit 0; }
        validate_ipv4 "$dns1" || { tui_msgbox "错误" "DNS 地址格式无效。"; step_network; return; }
        NET_DNS1="$dns1"

        dns2=$(tui_input "静态 IP  [4/6]" \
            "备用 DNS (留空跳过):" "${NET_DNS2:-8.8.8.8}") || { clear; exit 0; }
        if [[ -n "$dns2" ]] && ! validate_ipv4 "$dns2"; then
            tui_msgbox "错误" "备用 DNS 地址格式无效。"; step_network; return
        fi
        NET_DNS2="$dns2"
    fi
}

# ── 步骤 5：操作系统配置 ──────────────────────────────────────────────────────
step_os() {
    local hostname user p1 p2 sshkey tz pkgs sudo_choice

    hostname=$(tui_input "系统配置  [5/6]" \
        "主机名 (hostname):" "${VM_NAME}") || { clear; exit 0; }
    if ! validate_hostname "${hostname:-x}"; then
        tui_msgbox "错误" "主机名格式无效。\n只允许字母、数字、连字符，不能以连字符开头或结尾。"
        step_os; return
    fi
    OS_HOSTNAME="${hostname:-$VM_NAME}"

    user=$(tui_input "系统配置  [5/6]" \
        "管理员用户名:" "${OS_USER:-ubuntu}") || { clear; exit 0; }
    if ! validate_username "$user"; then
        tui_msgbox "错误" "用户名格式无效。\n只允许小写字母、数字、下划线、连字符，须以小写字母开头。"
        step_os; return
    fi
    OS_USER="$user"

    p1=$(tui_password "系统配置  [5/6]" "管理员密码:") || { clear; exit 0; }
    [[ ${#p1} -lt 8 ]] && { tui_msgbox "错误" "密码长度不能少于 8 位。"; step_os; return; }
    p2=$(tui_password "系统配置  [5/6]" "确认密码:")   || { clear; exit 0; }
    if [[ "$p1" != "$p2" ]]; then
        tui_msgbox "密码不匹配" "两次输入的密码不一致，请重新设置。"
        step_os; return
    fi
    OS_PASS="$p1"

    sshkey=$(tui_input "系统配置  [5/6]" \
        "SSH 公钥 (粘贴 public key, 留空仅允许密码登录):" \
        "${OS_SSH_KEY:-}") || { clear; exit 0; }
    OS_SSH_KEY="$sshkey"

    tz=$(tui_input "系统配置  [5/6]" "时区:" "${OS_TIMEZONE:-Asia/Shanghai}") \
        || { clear; exit 0; }
    OS_TIMEZONE="$tz"

    pkgs=$(tui_input "系统配置  [5/6]" \
        "额外安装包 (空格分隔, 留空跳过):" "${OS_PACKAGES:-}") || { clear; exit 0; }
    OS_PACKAGES="$pkgs"

    sudo_choice=$(tui_menu "系统配置  [5/6]" "sudo 权限策略:" \
        "0" "执行 sudo 需要输入密码 (推荐，安全)" \
        "1" "免密 sudo (仅用于测试/受控环境)") || { clear; exit 0; }
    OS_SUDO_NOPASSWD="$sudo_choice"
}

# ── 步骤 6：自定义 Metadata / Userdata ───────────────────────────────────────
step_advanced() {
    # 去除注释行和空行的辅助函数
    _strip_comments() { grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' || true; }

    # --- vSphere 标签 ---
    local tags_raw
    tags_raw=$(tui_input "vSphere 标签  [6/6]" \
"VM 标签 (格式: category:value，多个用空格分隔，留空跳过)
示例: env:prod team:ops app:nginx cost-center:IT-001" \
        "${VM_TAGS:-}") || { clear; exit 0; }
    VM_TAGS="$tags_raw"

    # --- Metadata 自定义字段 ---
    local meta_raw
    meta_raw=$(tui_editbox "自定义 Metadata  [6/6]" \
"# 追加到 cloud-init metadata 的自定义字段（YAML key: value 格式）
# 注释行和空行自动忽略。示例:
# environment: production
# owner: platform-team
# cost-center: IT-001
${VM_EXTRA_METADATA:-}") || { clear; exit 0; }
    VM_EXTRA_METADATA=$(printf '%s' "$meta_raw" | _strip_comments)

    # --- 自定义启动命令 (runcmd) ---
    local runcmd_raw
    runcmd_raw=$(tui_editbox "自定义启动命令  [6/6]" \
"# 每行一条 shell 命令，追加到 cloud-init runcmd 列表末尾
# 注释行和空行自动忽略。示例:
# systemctl restart nginx
# echo 'deploy done' > /tmp/ready
# curl -s http://cmdb.internal/register -d name=\$HOSTNAME
${OS_EXTRA_RUNCMD:-}") || { clear; exit 0; }
    OS_EXTRA_RUNCMD=$(printf '%s' "$runcmd_raw" | _strip_comments)

    # --- 自定义写入文件 (write_files) ---
    local wf_raw
    wf_raw=$(tui_editbox "自定义写入文件  [6/6]" \
"# cloud-init write_files 列表条目，每条从 '- path:' 开始
# 注释行和空行自动忽略。示例:
# - path: /etc/myapp/config.yaml
#   content: |
#     server: 0.0.0.0
#     port: 8080
#   permissions: '0644'
#   owner: 'root:root'
${OS_WRITE_FILES:-}") || { clear; exit 0; }
    OS_WRITE_FILES=$(printf '%s' "$wf_raw" | _strip_comments)
}

# ── 确认摘要 ──────────────────────────────────────────────────────────────────
step_confirm() {
    local net_info="DHCP 自动分配"
    [[ "$NET_TYPE" == "static" ]] && \
        net_info="${NET_IP}/${NET_PREFIX}  GW: ${NET_GATEWAY}  DNS: ${NET_DNS1}"

    local dry_note=""
    [[ $DRY_RUN -eq 1 ]] && dry_note="\n\n⚠  DRY-RUN 模式：不会实际执行任何操作"

    # 高级配置摘要
    local adv_parts=()
    [[ -n "${VM_TAGS:-}"           ]] && adv_parts+=("vSphere标签")
    [[ -n "${VM_EXTRA_METADATA:-}" ]] && adv_parts+=("metadata字段")
    [[ -n "${OS_EXTRA_RUNCMD:-}"   ]] && adv_parts+=("自定义命令")
    [[ -n "${OS_WRITE_FILES:-}"    ]] && adv_parts+=("写入文件")
    local adv_info
    adv_info=$( [[ ${#adv_parts[@]} -gt 0 ]] \
        && printf '%s  ' "${adv_parts[@]}" \
        || echo "未配置（使用默认）" )

    tui_yesno "确认部署配置" \
"───────────── vCenter ──────────────
  主机:      $VCENTER_HOST
  用户:      $VCENTER_USER
  数据中心:  ${VCENTER_DC:-默认}
  SSL 验证:  $( [[ "$VCENTER_INSECURE" == "true" ]] && echo "已跳过⚠" || echo "已启用✓" )

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
  密码长度:  ${#OS_PASS} 位
  SSH Key:   ${OS_SSH_KEY:+已配置✓}${OS_SSH_KEY:-未配置}
  sudo:      $( [[ "$OS_SUDO_NOPASSWD" == "1" ]] && echo "免密⚠" || echo "需密码✓" )
  时区:      $OS_TIMEZONE

──────────────── 标签 ───────────────
  ${VM_TAGS:-未配置}

──────────── 自定义配置 ─────────────
  $adv_info${dry_note}

确认开始部署？"
}

# ── 部署步骤核心（模式无关，由 do_deploy 以不同方式驱动） ────────────────────
# 调用前必须设置：_SF（状态文件路径）和 _pct 函数
_deploy_core() {
    _fail() {
        echo "FAILED:$1" >> "$_SF"
        _pct 100 "✗ $1"
        [[ "${BATCH_MODE:-0}" -eq 0 ]] && sleep 2
        exit 1
    }

    _pct 2 "预检查  模板 / 存储空间 / IP 冲突..."
    if [[ $DRY_RUN -eq 0 ]]; then
        govc_preflight_check >> "$LOG_FILE" 2>&1 \
            || _fail "部署前预检查未通过（查看日志: $LOG_FILE）"
    else
        echo "[DRY-RUN] 跳过预检查（模板 / 存储 / IP 检测）" >> "$LOG_FILE"
    fi

    _pct 5 "[ 0/5 ]  检查 VM 名称: $VM_NAME ..."
    if [[ $DRY_RUN -eq 0 ]] && govc_vm_exists "$VM_NAME"; then
        _fail "VM '$VM_NAME' 已存在，请更换名称"
    fi

    _pct 8 "[ 1/5 ]  正在克隆虚拟机: $VM_NAME ..."
    govc_clone_vm "$VM_TEMPLATE" "$VM_NAME" >> "$LOG_FILE" 2>&1 \
        || _fail "VM 克隆失败（检查模板路径和存储空间）"
    echo "CREATED:${VM_NAME}" >> "$_SF"

    _pct 28 "[ 2/5 ]  配置硬件规格 (CPU: $VM_CPU, 内存: ${VM_MEMORY}MB)..."
    govc_configure_vm "$VM_NAME" >> "$LOG_FILE" 2>&1 \
        || echo "警告: 硬件配置部分失败" >> "$LOG_FILE"

    _pct 45 "[ 3/5 ]  生成 cloud-init 配置..."
    local USERDATA NETWORK_CONFIG METADATA
    USERDATA=$(generate_userdata)             || _fail "生成 user-data 失败（密码哈希错误？）"
    NETWORK_CONFIG=$(generate_network_config)
    METADATA=$(generate_metadata "$NETWORK_CONFIG")

    if [[ $DRY_RUN -eq 1 ]]; then
        { echo "=== user-data ==="; echo "$USERDATA"
          echo "=== metadata (含 network config) ==="; echo "$METADATA"; } >> "$LOG_FILE"
    fi

    _pct 62 "[ 4/5 ]  注入 cloud-init 数据 (guestinfo ExtraConfig)..."
    govc_inject_cloudinit "$VM_NAME" "$USERDATA" "$METADATA" \
        >> "$LOG_FILE" 2>&1 || _fail "cloud-init 数据注入失败"

    _pct 80 "[ 5/5 ]  启动虚拟机..."
    govc_power_on "$VM_NAME" >> "$LOG_FILE" 2>&1 || _fail "VM 启动失败"

    if [[ -n "${VM_TAGS:-}" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] govc tags.attach: $VM_TAGS → $VM_NAME" >> "$LOG_FILE"
        else
            _pct 85 "应用 vSphere 标签: $VM_TAGS ..."
            govc_apply_tags "$VM_NAME" >> "$LOG_FILE" 2>&1 \
                || echo "警告: 部分标签未能应用，继续部署" >> "$LOG_FILE"
        fi
    fi

    echo "DONE" >> "$_SF"
    _pct 100 "✓ 部署完成！VM 正在初始化，cloud-init 运行中..."
    [[ "${BATCH_MODE:-0}" -eq 0 ]] && sleep 1
}

# ── 执行部署（含回滚） ────────────────────────────────────────────────────────
do_deploy() {
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

    # 状态文件：跨 subshell/管道边界传递部署结果
    _SF=$(mktemp) && chmod 600 "$_SF"
    local pipe_exit=0

    if [[ $BATCH_MODE -eq 1 ]]; then
        # 批量模式：直接输出带时间戳的文本进度，不调用 dialog
        _pct() { printf "[%s] (%3d%%) %s\n" "$(date '+%H:%M:%S')" "$1" "$2"; }
        _deploy_core || true
    else
        # 交互模式：在 subshell 中运行，输出 dialog gauge 格式
        _pct() { printf "%d\nXXX\n%s\nXXX\n" "$1" "$2"; }
        ( _deploy_core ) \
            | dialog --title "VM 部署进度${DRY_RUN:+ [DRY-RUN]}" \
                     --gauge "初始化中..." 10 72 0 || pipe_exit=$?
    fi

    # ── 检查部署结果 ──────────────────────────────────────────────────────────
    local created_vm=""
    created_vm=$(grep '^CREATED:' "$_SF" 2>/dev/null | cut -d: -f2 || true)

    if ! grep -q '^DONE$' "$_SF" 2>/dev/null || [[ $pipe_exit -ne 0 ]]; then
        local fail_msg
        fail_msg=$(grep '^FAILED:' "$_SF" 2>/dev/null | cut -d: -f2- \
                   || echo "未知错误（进程异常退出或用户取消）")
        rm -f "$_SF"

        # 回滚
        if [[ -n "$created_vm" && $DRY_RUN -eq 0 ]]; then
            if [[ $BATCH_MODE -eq 1 ]]; then
                echo "[$(date '+%H:%M:%S')] 正在回滚，销毁 VM: $created_vm ..."
            else
                dialog --title "回滚中" --infobox \
                    "部署失败，正在清理 VM: $created_vm ..." 5 60
            fi
            govc_destroy_vm "$created_vm" >> "$LOG_FILE" 2>&1 \
                || echo "警告: 回滚失败，请手动删除 VM: $created_vm" >> "$LOG_FILE"
        fi

        if [[ $BATCH_MODE -eq 1 ]]; then
            echo "错误: $fail_msg" >&2
            echo "日志: $LOG_FILE" >&2
        else
            tui_msgbox "部署失败" "${fail_msg}\n\n详细日志: $LOG_FILE"
        fi
        return 1
    fi

    rm -f "$_SF"

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ $BATCH_MODE -eq 1 ]]; then
            echo "Dry-run 完成。cloud-init 配置见日志: $LOG_FILE"
        else
            tui_msgbox "Dry-run 完成" \
"模拟运行完成，未实际执行任何操作。

生成的 cloud-init 配置已写入日志:
$LOG_FILE"
        fi
        return 0
    fi

    # ── 等待 IP ───────────────────────────────────────────────────────────────
    if [[ $BATCH_MODE -eq 1 ]]; then
        echo "[$(date '+%H:%M:%S')] 等待 VM 获取 IP（最长 3 分钟）..."
    else
        dialog --title "等待 IP" --infobox \
            "正在等待 VM 获取 IP 地址（最长 3 分钟）..." 5 55
    fi
    local vm_ip=""
    vm_ip=$(govc_get_ip "$VM_NAME" 180) || vm_ip=""

    # ── 等待 cloud-init 完成（仅配置了 SSH Key 时可验证） ─────────────────────
    local cloudinit_status="跳过（未配置 SSH Key）"
    if [[ -n "$vm_ip" && -n "${OS_SSH_KEY:-}" ]]; then
        if [[ $BATCH_MODE -eq 1 ]]; then
            echo "[$(date '+%H:%M:%S')] 等待 cloud-init 完成（最长 3 分钟）..."
        else
            dialog --title "等待初始化" --infobox \
                "正在验证 cloud-init 是否完成（最长 3 分钟）..." 5 60
        fi
        if wait_ssh_ready "$vm_ip" "$OS_USER" 180; then
            cloudinit_status="已完成 ✓"
        else
            cloudinit_status="超时（VM 仍在初始化，稍后可登录）"
        fi
    fi

    save_config

    if [[ $BATCH_MODE -eq 1 ]]; then
        echo ""
        echo "┌─────────────────────────────────────┐"
        printf "│  ✓ 部署成功: %-23s│\n" "$VM_NAME"
        printf "│  IP:  %-31s│\n" "${vm_ip:-(请稍后查看)}"
        printf "│  SSH: ssh %-28s│\n" "${OS_USER}@${vm_ip:-<IP>}"
        printf "│  cloud-init: %-24s│\n" "$cloudinit_status"
        printf "│  日志: %-31s│\n" "$(basename "$LOG_FILE")"
        echo "└─────────────────────────────────────┘"
    else
        tui_msgbox "部署成功" \
"✓  虚拟机已成功部署！

  VM 名称:      $VM_NAME
  IP 地址:      ${vm_ip:-(请稍后在 vCenter 查看)}
  用户名:       $OS_USER
  主机名:       $OS_HOSTNAME
  cloud-init:   $cloudinit_status

  SSH 登录:  ssh ${OS_USER}@${vm_ip:-<IP>}

日志文件:  $LOG_FILE"
    fi
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_dialog
    check_govc
    load_config

    if [[ $BATCH_MODE -eq 1 ]]; then
        # 批量模式：校验环境变量，连接 vCenter，直接部署
        batch_validate
        govc_connect || { echo "错误: 无法连接到 vCenter $VCENTER_HOST" >&2; exit 1; }
        do_deploy
        return
    fi

    # 交互模式
    local dry_banner=""
    [[ $DRY_RUN -eq 1 ]] && dry_banner="\n\n⚠  当前为 DRY-RUN 模式，不会实际执行部署"

    dialog --title "VM Deploy  v${VERSION}" --msgbox \
"欢迎使用 VM Deploy v${VERSION}

  通过 govc + cloud-init 自动化部署 Ubuntu 24.04

功能特性:
  • 从 vCenter 模板克隆虚拟机
  • 通过 guestinfo ExtraConfig 注入 cloud-init（无需 ISO）
  • 支持 DHCP / 静态 IP 配置
  • 部署失败自动回滚清理
  • 支持批量模式 (--batch) 和模拟模式 (--dry-run)${dry_banner}

按 Enter 开始配置向导..." 18 62

    step_vcenter
    step_placement
    step_vmspecs
    step_network
    step_os
    step_advanced

    if step_confirm; then
        do_deploy
    else
        tui_msgbox "已取消" "部署已取消，未对 vCenter 做任何修改。"
    fi

    clear
    echo "VM Deploy 完成。日志: $LOG_FILE"
}

main "$@"
