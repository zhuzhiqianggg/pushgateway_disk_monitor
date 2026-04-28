# pushgateway_disk_monitor

服务器磁盘 S.M.A.R.T. 健康监控，支持 Prometheus + PushGateway 架构

## 功能特性

- 支持 NVMe / SATA SSD / HDD / VMware 虚拟磁盘自动识别
- 监控磁盘温度、通电时间、寿命百分比、重映射扇区等
- 自动上报到 PushGateway，Prometheus 统一采集
- systemd 服务开机自启
- Grafana 仪表盘展示

## 目录结构

```
pushgateway_disk_monitor/
├── scripts/
│   └── disk_health_monitor.sh    # 主监控脚本
├── systemd/
│   └── disk-health-monitor.service  # systemd 服务文件
├── prometheus/
│   ├── scrape-config.yaml        # Prometheus 抓取配置
│   ├── alerts.yaml              # 报警规则
│   └── grafana-disk-table.json  # Grafana 磁盘统计表
├── deploy.sh                    # 一键部署脚本
└── README.md
```

## 快速部署

### 1. 修改部署服务器列表和密码

编辑 `deploy.sh` 顶部的配置：

```bash
SSH_USER="root"
SSH_PASS="your_password"
SERVERS=("192.168.10.150" "192.168.10.151" ...)
PUSHGATEWAY_URL="http://121.36.241.152:9091"
```

### 2. 一键部署到所有服务器

```bash
bash deploy.sh
```

### 3. 手动部署（单台）

```bash
# 安装依赖
apt-get install -y smartmontools

# 复制脚本
cp scripts/disk_health_monitor.sh /root/.openclaw/disk_monitor/
cp systemd/disk-health-monitor.service /etc/systemd/system/

# 启动服务
systemctl daemon-reload
systemctl enable disk-health-monitor
systemctl start disk-health-monitor
```

## 监控指标

| 指标名 | 说明 | 单位 | 备注 |
|--------|------|------|------|
| `smart_health_status` | 健康状态 (1=正常, 0=失败, 2=未知) | - | - |
| `smart_temperature_celsius` | 磁盘温度 | °C | -1表示不可获取 |
| `smart_power_on_hours` | 通电时间 | 小时 | -1表示不可获取 |
| `smart_percentage_used` | **SSD已消耗寿命百分比** | % | 核心寿命指标，0-100 |
| `smart_available_spare` | NVMe SSD 可用备用块 | % | -1表示非NVMe |
| `smart_available_spare_threshold` | NVMe SSD 备用块阈值 | % | -1表示非NVMe |
| `smart_data_written_blocks` | NVMe累计数据写入量 | 512B blocks | -1表示非NVMe |
| `smart_total_lbas_written` | SATA SSD累计LBA写入量 | 512B blocks | 0表示不可获取 |
| `smart_remaining_life_hours` | **预计剩余寿命** | 小时 | 基于使用率推算 |
| `smart_disk_max_life_hours` | **推算设计总寿命** | 小时 | 基于使用率推算 |
| `smart_reallocated_sectors` | 重映射扇区/坏块数量 | - | 0表示正常 |
| `smart_smart_available` | SMART 是否支持 (1=支持) | - | - |
| `smart_filesystem_size_bytes` | 文件系统总大小 | bytes | - |
| `smart_filesystem_used_bytes` | 文件系统已使用大小 | bytes | - |
| `smart_filesystem_avail_bytes` | 文件系统可用大小 | bytes | - |
| `smart_filesystem_use_percent` | 文件系统使用百分比 | % | - |

## 标签说明

每个指标包含以下标签：

| 标签 | 说明 |
|------|------|
| `device` | 设备名 (sda, nvme0n1) |
| `hostname` | 服务器主机名 |
| `model` | 磁盘型号 |
| `serial` | 序列号 |
| `type` | 磁盘类型 (nvme/ssd/hdd/vmware) |
| `mountpoints` | 挂载点 |

## Prometheus 配置

```yaml
scrape_configs:
  - job_name: 'disk-health'
    honor_labels: true
    static_configs:
      - targets: ['121.36.241.152:9091']
```

## 报警规则

参见 `prometheus/alerts.yaml`，主要报警：

- `smart_percentage_used > 80%` → 警告
- `smart_percentage_used > 95%` → 严重
- `smart_temperature_celsius > 50°C` → 警告
- `smart_temperature_celsius > 60°C` → 严重
- `smart_remaining_life_hours < 8760` → 警告（不足1年）
- `smart_remaining_life_hours < 2160` → 严重（不足3个月）
- `smart_data_written_blocks > 2e12` → 提示（NVMe写入超1000TB）

## Grafana 仪表盘

导入 `prometheus/grafana-disk-table.json`，可查看所有磁盘的：

- 健康状态表格
- 温度
- 寿命消耗百分比
- 通电时间
