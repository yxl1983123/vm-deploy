# vm-deploy

通过 **govc + cloud-init** 自动化在 VMware 环境中部署 Ubuntu 24.04 虚拟机。

- 从 vCenter 模板克隆 VM（无需 ISO）
- 通过 `guestinfo` ExtraConfig 注入 cloud-init 配置
- TUI 向导界面，全程交互式配置
- 支持 DHCP / 静态 IP
- 自动完成用户、SSH Key、软件包初始化

---

## 依赖

| 工具 | 安装方式 |
|------|---------|
| [govc](https://github.com/vmware/govmomi/releases) | `brew install govc` 或直接下载二进制 |
| [dialog](https://invisible-island.net/dialog/) | `brew install dialog` / `apt install dialog` |
| openssl | 系统自带（密码哈希用） |

---

## 安装

```bash
git clone https://github.com/yxl1983123/vm-deploy.git
cd vm-deploy
chmod +x deploy.sh
```

---

## 准备 Ubuntu 24.04 模板

> 脚本依赖 VM 模板内已安装 cloud-init 和 open-vm-tools，并启用 VMware 数据源。

### 1. 安装 Ubuntu 24.04 最小化系统

建议使用 Ubuntu Server 24.04 minimal ISO，安装完成后执行：

```bash
sudo apt update
sudo apt install -y open-vm-tools cloud-init cloud-initramfs-growroot
```

### 2. 配置 cloud-init 使用 VMware 数据源

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

# 清除 machine-id（避免 IP 冲突）
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id

# 清除 SSH host keys
sudo rm -f /etc/ssh/ssh_host_*

# 关机
sudo poweroff
```

在 vCenter 中右键 VM → **转换为模板**。

---

## 使用

```bash
./deploy.sh
```

### 配置向导步骤

| 步骤 | 内容 |
|------|------|
| 1/5 | vCenter 地址、用户名、密码、数据中心 |
| 2/5 | 选择模板、数据存储、网络、文件夹 |
| 3/5 | VM 名称、CPU、内存、磁盘大小 |
| 4/5 | DHCP 或静态 IP 配置 |
| 5/5 | 主机名、用户名、密码、SSH Key、时区、额外软件包 |

配置完成后显示摘要确认，确认后自动执行：
1. 从模板克隆 VM
2. 调整 CPU / 内存 / 磁盘
3. 生成并注入 cloud-init（`guestinfo.userdata` / `guestinfo.metadata` / `guestinfo.network`）
4. 开机
5. 等待并显示 IP 地址

### 保存配置

首次部署后，非敏感配置（vCenter 地址、默认规格等）自动保存到 `~/.vm-deploy.env`，下次启动时自动加载，无需重复填写。密码不会保存。

也可以手动创建配置文件：

```bash
cp config.example.env ~/.vm-deploy.env
# 编辑填写你的环境参数
```

---

## cloud-init 注入原理

脚本使用 VMware `guestinfo` ExtraConfig 注入 cloud-init 数据，无需挂载任何 ISO 或 ConfigDrive：

```
guestinfo.userdata         → cloud-init user-data（gzip+base64）
guestinfo.userdata.encoding → gzip+base64
guestinfo.metadata         → cloud-init meta-data（gzip+base64）
guestinfo.metadata.encoding → gzip+base64
guestinfo.network          → cloud-init network-config（gzip+base64）
guestinfo.network.encoding  → gzip+base64
```

cloud-init 的 VMware 数据源（`DataSourceVMware`）在 VM 启动时自动读取这些字段并完成初始化。

---

## 目录结构

```
vm-deploy/
├── deploy.sh             # 主入口脚本（TUI 向导）
├── lib/
│   ├── tui.sh            # dialog TUI 函数
│   ├── govc.sh           # govc 封装函数
│   └── cloudinit.sh      # cloud-init YAML 生成
├── config.example.env    # 配置示例
└── README.md
```

---

## 常见问题

**Q: `govc_list_templates` 返回空**
确认模板已在 vCenter 中标记为"模板"（右键 → 转换为模板），而不是普通 VM。

**Q: cloud-init 没有执行**
确认模板内 cloud-init 已配置 VMware 数据源（见模板准备步骤 2），且 `/etc/machine-id` 已清空。

**Q: 静态 IP 没有生效**
确认模板内网络接口名称。Ubuntu 24.04 在 VMware 上通常为 `ens192`。若网络配置未生效，可查看 VM 内 `/run/cloud-init/ds-identify.result` 排查数据源识别问题。

**Q: SSH 无法连接**
cloud-init 首次初始化约需 1~2 分钟，请等待后重试。可在 vCenter 控制台查看启动日志。
