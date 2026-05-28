#!/usr/bin/env bash
# demo-sim.sh — 模拟批量部署输出（演示用，无需真实 vCenter）

S="${DEMO_SPEED:-0.06}"  # 控制演示节奏

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC}  $*"; }
fail() { echo -e "${RED}✗${NC}  $*"; }
info() { echo -e "${CYAN}→${NC}  $*"; }
ts()   { printf "[%s] (%3d%%) %s\n" "$(date '+%H:%M:%S')" "$1" "$2"; }

echo ""
echo -e "${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  VM Deploy — 批量部署${NC}"
echo    "  主机文件:  examples/hosts.csv"
echo    "  VM 总数:   4  |  最大并行: 3"
echo    "  vCenter:   vc.corp.example.com"
echo    "  模板:      /DC/vm/ubuntu-2404-template"
echo -e "${BOLD}══════════════════════════════════════════════${NC}"
echo ""
sleep "$S"

# ── 三台并行启动 ─────────────────────────────────────────────────────────────
info "[prod-web-01] 开始部署..."
sleep 0.05
info "[prod-web-02] 开始部署..."
sleep 0.05
info "[prod-web-03] 开始部署..."
echo ""
sleep "$S"

# ── prod-web-01 进度 ──────────────────────────────────────────────────────────
ts   3 "[ 0/5 ]  检查 VM 名称: prod-web-01 ..."
sleep "$S"
ts   8 "[ 1/5 ]  正在克隆虚拟机: prod-web-01 ..."
sleep "$(echo "$S * 5" | bc)"
ts  28 "[ 2/5 ]  配置硬件规格 (CPU: 2, 内存: 4096MB)..."
sleep "$S"
ts  45 "[ 3/5 ]  生成 cloud-init 配置..."
sleep "$S"
ts  62 "[ 4/5 ]  注入 cloud-init 数据 (guestinfo ExtraConfig)..."
sleep "$S"
ts  80 "[ 5/5 ]  启动虚拟机..."
sleep "$S"
ts 100 "✓ 部署完成！VM 正在初始化..."
sleep "$S"

# ── prod-web-02 交错进度 ──────────────────────────────────────────────────────
ts   8 "[ 1/5 ]  正在克隆虚拟机: prod-web-02 ..."
sleep "$(echo "$S * 4" | bc)"
ts  28 "[ 2/5 ]  配置硬件规格 (CPU: 2, 内存: 4096MB)..."
sleep "$S"
ts  62 "[ 4/5 ]  注入 cloud-init 数据 (guestinfo ExtraConfig)..."
sleep "$S"
ts 100 "✓ 部署完成！VM 正在初始化..."
sleep "$S"

# ── web-01 拿到 IP，cloud-init 验证 ──────────────────────────────────────────
ts   0 "等待 VM 获取 IP（最长 3 分钟）..."
sleep "$(echo "$S * 2" | bc)"
ts   0 "等待 cloud-init 完成..."
sleep "$(echo "$S * 3" | bc)"

echo ""
echo "┌──────────────────────────────────────┐"
echo "│  ✓ 部署成功: prod-web-01              │"
echo "│  IP:  192.168.1.101                   │"
echo "│  SSH: ssh ubuntu@192.168.1.101        │"
echo "│  cloud-init: 已完成 ✓                 │"
echo "└──────────────────────────────────────┘"
ok "[prod-web-01] 完成 (38s)"
echo ""
sleep "$S"

# ── 第四台补位 ────────────────────────────────────────────────────────────────
info "[prod-db-01] 开始部署..."
sleep "$S"

# ── web-02/03 完成 ────────────────────────────────────────────────────────────
ts   8 "[ 1/5 ]  正在克隆虚拟机: prod-web-03 ..."
sleep "$(echo "$S * 4" | bc)"
ts  80 "[ 5/5 ]  启动虚拟机..."
sleep "$S"
ts 100 "✓ 部署完成！VM 正在初始化..."
sleep "$S"
ok "[prod-web-02] 完成 (41s)"
ok "[prod-web-03] 完成 (43s)"

# ── db-01 完成 ────────────────────────────────────────────────────────────────
ts   8 "[ 1/5 ]  正在克隆虚拟机: prod-db-01 ..."
sleep "$(echo "$S * 5" | bc)"
ts  28 "[ 2/5 ]  配置硬件规格 (CPU: 4, 内存: 8192MB)..."
sleep "$S"
ts  62 "[ 4/5 ]  注入 cloud-init 数据 (guestinfo ExtraConfig)..."
sleep "$S"
ts 100 "✓ 部署完成！VM 正在初始化..."
sleep "$(echo "$S * 2" | bc)"
ok "[prod-db-01] 完成 (47s)"

echo ""
echo -e "总耗时: ${BOLD}51s${NC}"

# ── 汇总报告 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${BOLD}            批量部署汇总${NC}"
echo -e "${BOLD}══════════════════════════════════════════════${NC}"
ok "  $(printf '%-20s' 'prod-web-01')  IP: 192.168.1.101    耗时: 38s"
sleep 0.05
ok "  $(printf '%-20s' 'prod-web-02')  IP: 192.168.1.102    耗时: 41s"
sleep 0.05
ok "  $(printf '%-20s' 'prod-web-03')  IP: 192.168.1.103    耗时: 43s"
sleep 0.05
ok "  $(printf '%-20s' 'prod-db-01')   IP: 192.168.1.111    耗时: 47s"
echo "──────────────────────────────────────────────"
echo -e "  总计: ${BOLD}4${NC}  成功: ${GREEN}4${NC}  失败: ${RED}0${NC}"
echo    "  日志目录: /tmp/vm-batch-20260528-102256"
echo -e "${BOLD}══════════════════════════════════════════════${NC}"
echo ""
