#!/bin/bash
# ===================== 配置文件 =====================
# 服务器列表（每行一个 IP 或 hostname）
SERVERS=(
    "192.168.10.150"
    "192.168.10.151"
    "192.168.10.152"
    "192.168.10.155"
    "192.168.10.198"
)

# SSH 默认账号（留空则在运行时交互式输入）
SSH_USER="root"

# SSH 密码（留空则在运行时交互式输入；如有 SSH 密钥则优先使用密钥）
SSH_PASS=""

# ===================== 可修改项 =====================
PUSHGATEWAY_URL="http://121.36.241.152:9091"
PUSH_INTERVAL="3600"
REMOTE_INSTALL_DIR="/opt/monitor/disk_monitor"
SSH_PORT=22
SSH_CONNECT_TIMEOUT=15
