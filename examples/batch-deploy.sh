#!/usr/bin/env bash
# batch-deploy.sh — 从 CSV 批量部署多台 VM，支持并行
#
# 用法:
#   ./examples/batch-deploy.sh [hosts.csv]
#
# 常用选项（环境变量）:
#   MAX_PARALLEL=3     最大并行部署数（默认 3）
#   DRY_RUN=1          模拟运行，不实际部署
#
# 示例:
#   VCENTER_HOST=vc.example.com VCENTER_USER=admin@vsphere.local VCENTER_PASS=secret \
#   VM_TEMPLATE=/DC/vm/ubuntu-2404 VM_DATASTORE=/DC/datastore/vsan \
#   VM_NETWORK="/DC/network/prod" NET_PREFIX=24 NET_DNS1=114.114.114.114 \
#   OS_USER=ubuntu OS_PASS=MyPass123 OS_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)" \
#   ./examples/batch-deploy.sh examples/hosts.csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${SCRIPT_DIR}/../deploy.sh"
HOSTS="${1:-${SCRIPT_DIR}/hosts.csv}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
DRY_RUN="${DRY_RUN:-0}"
RESULTS_DIR="/tmp/vm-batch-$(date +%Y%m%d-%H%M%S)"
SUMMARY_FILE="${RESULTS_DIR}/summary.csv"

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

log_ok()   { echo -e "${GREEN}✓${NC}  $*"; }
log_fail() { echo -e "${RED}✗${NC}  $*"; }
log_info() { echo -e "${CYAN}→${NC}  $*"; }
log_warn() { echo -e "${YELLOW}!${NC}  $*"; }

# ── 前置检查 ──────────────────────────────────────────────────────────────────
preflight_check() {
    if [[ ! -f "$HOSTS" ]]; then
        echo "错误: CSV 文件不存在: $HOSTS" >&2
        echo "用法: $0 [hosts.csv]" >&2
        exit 1
    fi

    if [[ ! -x "$DEPLOY" ]]; then
        echo "错误: 找不到可执行的 deploy.sh: $DEPLOY" >&2
        exit 1
    fi

    # 必填公共环境变量
    local missing=()
    for var in VCENTER_HOST VCENTER_USER VCENTER_PASS VM_TEMPLATE VM_DATASTORE VM_NETWORK OS_PASS; do
        [[ -z "${!var:-}" ]] && missing+=("$var")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "错误: 缺少必填环境变量:" >&2
        printf "  - %s\n" "${missing[@]}" >&2
        exit 1
    fi
}

# ── 导出公共参数（所有 VM 共享） ──────────────────────────────────────────────
export_common_vars() {
    export VCENTER_HOST VCENTER_USER VCENTER_PASS
    export VCENTER_DC="${VCENTER_DC:-}"
    export VCENTER_INSECURE="${VCENTER_INSECURE:-false}"
    export VM_TEMPLATE VM_DATASTORE VM_NETWORK
    export VM_FOLDER="${VM_FOLDER:-}"
    export VM_RESOURCE_POOL="${VM_RESOURCE_POOL:-}"
    export NET_TYPE="${NET_TYPE:-static}"
    export NET_PREFIX="${NET_PREFIX:-24}"
    export NET_DNS1="${NET_DNS1:-114.114.114.114}"
    export NET_DNS2="${NET_DNS2:-8.8.8.8}"
    export OS_USER="${OS_USER:-ubuntu}"
    export OS_PASS
    export OS_SSH_KEY="${OS_SSH_KEY:-}"
    export OS_TIMEZONE="${OS_TIMEZONE:-Asia/Shanghai}"
    export OS_SUDO_NOPASSWD="${OS_SUDO_NOPASSWD:-0}"
    export BATCH_MODE=1
}

# ── 部署单台 VM ───────────────────────────────────────────────────────────────
# 参数: vm_name cpu memory disk net_ip net_gateway hostname packages
#       [data_disks] [tags] [source_type]   ← 列9-11为可选，留空使用默认值
deploy_one() {
    local vm_name="$1" cpu="$2" memory="$3" disk="$4" \
          net_ip="$5" net_gateway="$6" hostname="$7" packages="$8" \
          data_disks="${9:-}" tags="${10:-}" source_type="${11:-template}"

    local log="${RESULTS_DIR}/${vm_name}.log"
    local start elapsed rc=0

    log_info "[${vm_name}] 开始部署..."
    start=$(date +%s)

    local extra_args=()
    [[ $DRY_RUN -eq 1 ]] && extra_args+=(--dry-run)

    # 每台 VM 的独立参数通过环境变量覆盖
    VM_NAME="$vm_name" \
    VM_CPU="$cpu" \
    VM_MEMORY="$memory" \
    VM_DISK_SIZE="$( [[ "$disk" == "0" ]] && echo "" || echo "$disk" )" \
    VM_DATA_DISKS="$data_disks" \
    VM_TAGS="$tags" \
    VM_SOURCE_TYPE="$source_type" \
    NET_IP="$( [[ "$net_ip"      == "-" ]] && echo "" || echo "$net_ip" )" \
    NET_GATEWAY="$( [[ "$net_gateway" == "-" ]] && echo "" || echo "$net_gateway" )" \
    OS_HOSTNAME="$hostname" \
    OS_PACKAGES="$packages" \
    LOG_FILE="${log}" \
    bash "$DEPLOY" --batch "${extra_args[@]}" >"${log}.stdout" 2>&1 || rc=$?

    elapsed=$(( $(date +%s) - start ))

    if [[ $rc -eq 0 ]]; then
        log_ok "[${vm_name}] 完成 (${elapsed}s)  →  查看日志: ${log}.stdout"
        echo "SUCCESS,${vm_name},${elapsed}s,${net_ip}" >> "$SUMMARY_FILE"
    else
        log_fail "[${vm_name}] 失败 (${elapsed}s)  →  查看日志: ${log}.stdout"
        echo "FAILED,${vm_name},${elapsed}s,${net_ip}" >> "$SUMMARY_FILE"
    fi

    return $rc
}

# ── 解析 CSV 并并行控制 ───────────────────────────────────────────────────────
deploy_all() {
    local pids=()
    local vm_list=()

    # 读取 8 个必填列 + 3 个可选列（列9-11：data_disks tags source_type）
    # 旧格式 CSV（8列）完全兼容，新列缺失时变量为空
    while IFS=',' read -r vm_name cpu memory disk net_ip net_gateway hostname packages \
                          data_disks tags source_type; do
        # 跳过注释行和空行
        [[ "$vm_name" =~ ^[[:space:]]*# || -z "${vm_name// /}" ]] && continue

        # 去除首尾空格
        _trim() { local v="$1"; v="${v#"${v%%[! ]*}"}"; v="${v%"${v##*[! ]}"}"; echo "$v"; }
        vm_name="$(_trim "$vm_name")"; cpu="$(_trim "$cpu")"
        memory="$(_trim "$memory")";   disk="$(_trim "$disk")"
        net_ip="$(_trim "$net_ip")";   net_gateway="$(_trim "$net_gateway")"
        hostname="$(_trim "$hostname")"; packages="$(_trim "$packages")"
        data_disks="$(_trim "$data_disks")"; tags="$(_trim "$tags")"
        source_type="$(_trim "${source_type:-template}")"

        vm_list+=("$vm_name")

        # 并行控制：当活跃任务达上限时等待
        while true; do
            local alive=()
            for pid in "${pids[@]:-}"; do
                kill -0 "$pid" 2>/dev/null && alive+=("$pid") || true
            done
            pids=("${alive[@]:-}")
            [[ ${#pids[@]} -lt $MAX_PARALLEL ]] && break
            sleep 2
        done

        deploy_one "$vm_name" "$cpu" "$memory" "$disk" \
                   "$net_ip" "$net_gateway" "$hostname" "$packages" \
                   "$data_disks" "$tags" "$source_type" &
        pids+=($!)

    done < "$HOSTS"

    # 等待所有后台任务完成
    local overall_rc=0
    for pid in "${pids[@]:-}"; do
        wait "$pid" || overall_rc=1
    done

    return $overall_rc
}

# ── 汇总报告 ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}            批量部署汇总${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"

    local total=0 success=0 failed=0

    if [[ -f "$SUMMARY_FILE" ]]; then
        while IFS=',' read -r status vm_name elapsed ip; do
            ((total++))
            if [[ "$status" == "SUCCESS" ]]; then
                ((success++))
                log_ok "  $(printf '%-20s' "$vm_name")  IP: $(printf '%-16s' "$ip")  耗时: $elapsed"
            else
                ((failed++))
                log_fail "  $(printf '%-20s' "$vm_name")  IP: $(printf '%-16s' "$ip")  耗时: $elapsed"
            fi
        done < "$SUMMARY_FILE"
    fi

    echo "──────────────────────────────────────────────"
    echo -e "  总计: ${BOLD}${total}${NC}  成功: ${GREEN}${success}${NC}  失败: ${RED}${failed}${NC}"
    echo    "  日志目录: ${RESULTS_DIR}"
    [[ $DRY_RUN -eq 1 ]] && echo -e "  ${YELLOW}（Dry-run 模式，未实际执行部署）${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"

    [[ $failed -gt 0 ]] && return 1 || return 0
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    preflight_check
    export_common_vars

    mkdir -p "$RESULTS_DIR"
    : > "$SUMMARY_FILE"   # 清空汇总文件

    # 统计有效行数
    local total_vms
    total_vms=$(grep -v '^\s*#\|^\s*$' "$HOSTS" | wc -l | tr -d ' ')

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  VM Deploy — 批量部署${NC}"
    echo    "  主机文件:    $HOSTS"
    echo    "  VM 总数:     $total_vms"
    echo    "  最大并行:    $MAX_PARALLEL"
    echo    "  vCenter:     $VCENTER_HOST"
    echo    "  模板:        $VM_TEMPLATE"
    [[ $DRY_RUN -eq 1 ]] && \
        echo -e "  ${YELLOW}模式: DRY-RUN（不实际部署）${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════${NC}"
    echo ""

    local start_total
    start_total=$(date +%s)

    deploy_all || true   # 并行失败不中止，汇总后统一报告

    local elapsed_total=$(( $(date +%s) - start_total ))
    echo ""
    echo "总耗时: ${elapsed_total}s"

    print_summary
}

main "$@"
