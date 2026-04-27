#!/bin/bash
# 磁盘健康监控一键部署脚本
# 部署到多台服务器并配置开机自启

PUSHGATEWAY_URL="http://121.36.241.152:9091"
PUSH_INTERVAL="3600"
SSH_USER="root"
SSH_PASS="beosin@123"
REMOTE_INSTALL_DIR="/root/.openclaw/disk_monitor"

SERVERS=(
    "192.168.10.150"
    "192.168.10.151"
    "192.168.10.152"
    "192.168.10.153"
    "192.168.10.154"
    "192.168.10.155"
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_SCRIPT="$SCRIPT_DIR/scripts/disk_health_monitor.sh"
SERVICE_FILE="$SCRIPT_DIR/systemd/disk-health-monitor.service"
REMOTE_SCRIPT_FILE="$SCRIPT_DIR/.remote_setup.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

cat > "$REMOTE_SCRIPT_FILE" <<'REMOTE_EOF'
#!/bin/bash
set -e
INSTALL_DIR="/root/.openclaw/disk_monitor"

if ! command -v smartctl &>/dev/null; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq smartmontools >/dev/null 2>&1
fi

sed -i "s|PUSHGATEWAY_URL=\".*\"|PUSHGATEWAY_URL=\"http://121.36.241.152:9091\"|" "$INSTALL_DIR/disk_health_monitor.sh"
sed -i "s|SCRAPE_INTERVAL=\"[0-9]*\"|SCRAPE_INTERVAL=\"3600\"|" "$INSTALL_DIR/disk_health_monitor.sh"

cp "$INSTALL_DIR/disk-health-monitor.service" /etc/systemd/system/disk-health-monitor.service
systemctl daemon-reload
systemctl stop disk-health-monitor 2>/dev/null || true
systemctl enable disk-health-monitor
systemctl start disk-health-monitor

sleep 3
if systemctl is-active --quiet disk-health-monitor; then
    echo "SERVICE_OK"
else
    echo "SERVICE_FAILED"
    journalctl -u disk-health-monitor -n 10 --no-pager 2>/dev/null || true
fi
REMOTE_EOF
chmod +x "$REMOTE_SCRIPT_FILE"

deploy_to_server() {
    local server="$1"
    log_info "开始部署到 $server ..."

    local test_out
    test_out=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${SSH_USER}@${server}" "echo CONNECTED" 2>&1)
    local test_rc=$?

    if [ $test_rc -ne 0 ] || ! echo "$test_out" | grep -q "CONNECTED"; then
        log_error "$server SSH连接失败 (rc=$test_rc): $test_out"
        return 1
    fi

    local remote_hostname
    remote_hostname=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${SSH_USER}@${server}" "hostname 2>/dev/null" || echo "$server")
    log_info "连接到 $server (hostname: $remote_hostname)"

    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${SSH_USER}@${server}" "mkdir -p $REMOTE_INSTALL_DIR" || true

    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$MONITOR_SCRIPT" "${SSH_USER}@${server}:${REMOTE_INSTALL_DIR}/disk_health_monitor.sh"
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${SSH_USER}@${server}" "chmod +x ${REMOTE_INSTALL_DIR}/disk_health_monitor.sh"

    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$SERVICE_FILE" "${SSH_USER}@${server}:${REMOTE_INSTALL_DIR}/disk-health-monitor.service"

    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$REMOTE_SCRIPT_FILE" "${SSH_USER}@${server}:/tmp/disk_monitor_setup.sh"

    local setup_output
    setup_output=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${SSH_USER}@${server}" "bash /tmp/disk_monitor_setup.sh" 2>&1) || true

    if echo "$setup_output" | grep -q "SERVICE_OK"; then
        return 0
    else
        log_error "$server 服务启动失败: $setup_output"
        return 1
    fi
}

echo ""
echo "============================================"
echo "  磁盘健康监控批量部署"
echo "============================================"
log_info "PushGateway地址: $PUSHGATEWAY_URL"
log_info "推送间隔: ${PUSH_INTERVAL}秒 (1小时)"
log_info "服务器数量: ${#SERVERS[@]}"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_SERVERS=()

for server in "${SERVERS[@]}"; do
    echo "--------------------------------------------"
    if deploy_to_server "$server"; then
        log_success "$server 部署成功"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "$server 部署失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_SERVERS+=("$server")
    fi
    echo ""
done

echo "============================================"
echo "  部署结果汇总"
echo "============================================"
log_info "成功: $SUCCESS_COUNT / ${#SERVERS[@]}"
if [ $FAIL_COUNT -gt 0 ]; then
    log_error "失败: $FAIL_COUNT 台 - ${FAILED_SERVERS[*]}"
fi
echo "============================================"

rm -f "$REMOTE_SCRIPT_FILE"
