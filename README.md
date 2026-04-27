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

| 指标名 | 说明 | 单位 |
|--------|------|------|
| `smart_health_status` | 健康状态 (1=正常, 0=失败) | - |
| `smart_temperature_celsius` | 磁盘温度 | °C |
| `smart_power_on_hours` | 通电时间 | 小时 |
| `smart_percentage_used` | SSD 已消耗寿命百分比 | % |
| `smart_available_spare` | NVMe SSD 可用备用块 | % |
| `smart_reallocated_sectors` | 重映射扇区数量 | - |
| `smart_smart_available` | SMART 是否支持 (1=支持) | - |

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

## Grafana 仪表盘

导入 `prometheus/grafana-disk-table.json`，可查看所有磁盘的：

- 健康状态表格
- 温度
- 寿命消耗百分比
- 通电时间
