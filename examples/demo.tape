Output docs/demo.gif

Set Shell       bash
Set FontSize    13
Set Width       1100
Set Height      600
Set Theme       "Dracula"
Set TypingSpeed 40ms
Set Padding     18
Set Framerate   30

# ── 静默初始化：进入目录、设置公共环境变量 ──────────────────────────────────
Hide
Type "cd /tmp/vm-deploy"
Enter
Type "export VCENTER_HOST=vc.corp.example.com"
Enter
Type "export VM_TEMPLATE='/Datacenter/vm/ubuntu-2404-template'"
Enter
Type "export VM_DATASTORE='/Datacenter/datastore/vsanDatastore'"
Enter
Type "export VM_NETWORK='/Datacenter/network/VM Network'"
Enter
Type "export NET_PREFIX=24 NET_DNS1=114.114.114.114"
Enter
Type "export OS_USER=ubuntu OS_PASS='P@ssw0rd2026' OS_TIMEZONE=Asia/Shanghai"
Enter
Type "export DEMO_SPEED=0.10"
Enter
Show

Sleep 600ms

# ── 展示主机清单 ──────────────────────────────────────────────────────────────
Type "# 1. 查看主机清单（CSV 格式：VM名称/规格/IP/安装包）"
Sleep 100ms
Enter
Sleep 200ms

Type "grep -v '^#' examples/hosts.csv | head -6"
Sleep 200ms
Enter
Sleep 1800ms

# ── 运行批量部署 ──────────────────────────────────────────────────────────────
Type "# 2. 批量部署（最大并行 3 台）"
Sleep 100ms
Enter
Sleep 200ms

Type "MAX_PARALLEL=3 bash examples/demo-sim.sh"
Sleep 400ms
Enter

# 等待 demo-sim.sh 执行完成（约 7 秒）
Sleep 8000ms

# 停留在汇总界面让读者看清楚
Sleep 3000ms
