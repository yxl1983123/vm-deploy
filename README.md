# vm-deploy

通过 **govc + cloud-init** 自动化在 VMware 环境中部署 Ubuntu 24.04 虚拟机。

- 从 vCenter 模板克隆 VM（无需 ISO）
- 通过 `guestinfo` ExtraConfig 注入 cloud-init 配置
- TUI 向导界面（dialog），全程交互式配置
- 支持 DHCP / 静态 IP
- 部署失败自动回滚（销毁已创建的 VM）
- 支持批量非交互模式（`--batch`）和模拟运行（`--dry-run`）

---

## 依赖

| 工具 | 安装方式 |
|------|---------|
| [govc](https://github.com/vmware/govmomi/releases) | `brew install govc` 或直接下载二进制 |
| [dialog](https://invisible-island.net/dialog/) | `brew install dialog` / `apt install dialog` |
| openssl | 系统自带（用于密码 SHA-512 哈希） |

---

## 安装

```bash
git clone https://github.com/yxl1983123/vm-deploy.git
cd vm-deploy
chmod +x deploy.sh
```

---

## 准备 Ubuntu 24.04 模板

> 脚本依赖模板内已安装 cloud-init 和 open-vm-tools，并启用 VMware 数据源。

### 1. 安装 Ubuntu 24.04 最小化系统后执行

```bash
sudo apt update
sudo apt install -y open-vm-tools cloud-init cloud-initramfs-growroot unattended-upgrades
```

### 2. 启用 VMware 数据源

```bash
sudo tee /etc/cloud/cloud.cfg.d/99-vmware-datasource.cfg <<EOF
datasource_list: ['VMware', 'OVF', 'None']
datasource:
  VMware:
    allow_raw_data: true
EOF
```

### 3. 清理并转换为模板

```bash
# 清除 cloud-init 状态
sudo cloud-init clean --logs

# 清除 machine-id（防止 IP/主机名冲突）
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

# 清除 SSH host keys（首次启动重新生成）
sudo rm -f /etc/ssh/ssh_host_*

sudo poweroff
```

在 vCenter 中右键 VM → **转换为模板**。

---

## 使用

### 交互式（TUI 向导）

```bash
./deploy.sh
```

### 模拟运行（不实际执行，检查配置）

```bash
./deploy.sh --dry-run
```

dry-run 时会生成 cloud-init 配置并写入日志，但不会克隆或启动 VM。

### 批量/非交互模式（CI/CD 集成）

```bash
export VCENTER_HOST=vc.example.com
export VCENTER_USER=administrator@vsphere.local
export VCENTER_PASS=YourPassword
export VM_NAME=prod-web-01
export VM_TEMPLATE="/Datacenter/vm/Templates/ubuntu-2404"
export VM_DATASTORE="/Datacenter/datastore/vsanDatastore"
export VM_NETWORK="/Datacenter/network/VM Network"
export NET_TYPE=static
export NET_IP=192.168.1.100
export NET_PREFIX=24
export NET_GATEWAY=192.168.1.1
export NET_DNS1=114.114.114.114
export OS_HOSTNAME=prod-web-01
export OS_USER=ubuntu
export OS_PASS=SecurePassword123
export OS_SSH_KEY="ssh-rsa AAAA..."

./deploy.sh --batch
```

#### 批量模式环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `VCENTER_HOST` | ✓ | vCenter/ESXi 地址 |
| `VCENTER_USER` | ✓ | 登录用户名 |
| `VCENTER_PASS` | ✓ | 登录密码 |
| `VCENTER_DC` | - | 数据中心名称（留空使用默认） |
| `VCENTER_INSECURE` | - | `false`（默认，验证证书）/ `true`（跳过，仅测试用）|
| `VM_NAME` | ✓ | 虚拟机名称 |
| `VM_TEMPLATE` | ✓ | 模板完整路径 |
| `VM_DATASTORE` | ✓ | 数据存储路径 |
| `VM_NETWORK` | ✓ | 网络/端口组路径 |
| `VM_FOLDER` | - | VM 文件夹（相对路径） |
| `VM_RESOURCE_POOL` | - | 资源池路径 |
| `VM_CPU` | - | CPU 核心数（默认 2） |
| `VM_MEMORY` | - | 内存 MB（默认 4096） |
| `VM_DISK_SIZE` | - | 系统盘扩容至 GB（留空保持模板大小） |
| `NET_TYPE` | - | `dhcp`（默认）/ `static` |
| `NET_IP` | 静态时 ✓ | IP 地址 |
| `NET_PREFIX` | 静态时 ✓ | 子网前缀长度（如 24） |
| `NET_GATEWAY` | 静态时 ✓ | 默认网关 |
| `NET_DNS1` | 静态时 ✓ | 首选 DNS |
| `NET_DNS2` | - | 备用 DNS |
| `OS_HOSTNAME` | ✓ | 主机名 |
| `OS_USER` | ✓ | 管理员用户名 |
| `OS_PASS` | ✓ | 管理员密码（最少 8 位） |
| `OS_SSH_KEY` | - | SSH 公钥（推荐配置，否则只能密码登录） |
| `OS_TIMEZONE` | - | 时区（默认 Asia/Shanghai） |
| `OS_PACKAGES` | - | 额外安装包，空格分隔 |
| `OS_SUDO_NOPASSWD` | - | `0`=需要密码（默认）/ `1`=免密 sudo |

---

## cloud-init 注入原理

脚本使用 VMware `guestinfo` ExtraConfig 注入 cloud-init，无需挂载 ISO：

```
guestinfo.userdata          → cloud-init user-data（gzip+base64）
guestinfo.userdata.encoding → gzip+base64
guestinfo.metadata          → cloud-init meta-data（gzip+base64）
guestinfo.metadata.encoding → gzip+base64
guestinfo.network           → cloud-init network-config（gzip+base64）
guestinfo.network.encoding  → gzip+base64
```

VMware 数据源（`DataSourceVMware`）在 VM 启动时自动读取这些字段。

---

## 目录结构

```
vm-deploy/
├── deploy.sh              # 主入口（TUI 向导 + 批量模式 + dry-run）
├── lib/
│   ├── tui.sh             # dialog TUI 函数 + 输入验证
│   ├── govc.sh            # govc 封装（含回滚、SSH 探测）
│   └── cloudinit.sh       # cloud-init YAML 生成
├── config.example.env     # 配置示例
└── README.md
```

---

## 安全说明

- **密码传输**：vCenter 密码通过 `GOVC_PASSWORD` 独立环境变量传递，不嵌入 URL（防止 `ps aux` 泄露）
- **密码哈希**：通过 stdin 传入 openssl，不做字符串插值（防命令注入）
- **YAML 安全**：对用户输入的 hostname/username 进行格式校验，防止 YAML 注入
- **日志权限**：日志文件创建时即设置 600（仅所有者可读）
- **配置文件**：`~/.vm-deploy.env` 密码不保存，文件权限设为 600
- **TLS 证书**：默认启用证书验证（`VCENTER_INSECURE=false`），跳过验证须显式选择
- **sudo 策略**：默认 `ALL=(ALL) ALL`（需要密码），生产环境不建议改为 NOPASSWD

---

## 常见问题

**Q: 克隆失败，报存储空间不足**
检查目标数据存储剩余容量，确保足够存放模板大小（通常 20GB+）。

**Q: cloud-init 没有执行**
确认模板内 cloud-init 已配置 VMware 数据源，且 `/etc/machine-id` 已清空（见模板准备步骤）。

**Q: 静态 IP 没有生效**
Ubuntu 24.04 在 VMware 上通常接口名为 `ens192`。脚本使用 `match: {name: "en*"}` 匹配，
若实际接口名不匹配，查看 VM 内 `/run/cloud-init/ds-identify.result` 排查数据源问题。

**Q: SSH 无法连接**
cloud-init 首次初始化约需 1~2 分钟。若配置了 SSH Key，脚本会自动等待验证；否则请手动等待后重试。

**Q: 如何批量部署多台 VM**
在 shell 循环中多次调用批量模式：
```bash
for i in 01 02 03; do
  VM_NAME="prod-web-${i}" NET_IP="192.168.1.1${i}" OS_HOSTNAME="prod-web-${i}" \
  ./deploy.sh --batch
done
```
