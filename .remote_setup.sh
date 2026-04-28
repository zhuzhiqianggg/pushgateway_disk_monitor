#!/bin/bash
set -e
INSTALL_DIR="$1"
PUSHGATEWAY_URL="$2"
PUSH_INTERVAL="$3"

if ! command -v smartctl &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq smartmontools
    elif command -v yum &>/dev/null; then
        yum install -y -q smartmontools
    elif command -v dnf &>/dev/null; then
        dnf install -y -q smartmontools
    fi
fi

sed -i "s|PUSHGATEWAY_URL=.*|PUSHGATEWAY_URL=\"${PUSHGATEWAY_URL}\"|" "${INSTALL_DIR}/scripts/disk_health_monitor.sh" 2>/dev/null || true
sed -i "s|SCRAPE_INTERVAL=.*|SCRAPE_INTERVAL=\"${PUSH_INTERVAL}\"|" "${INSTALL_DIR}/scripts/disk_health_monitor.sh" 2>/dev/null || true

cp "${INSTALL_DIR}/systemd/disk-health-monitor.service" /etc/systemd/system/disk-health-monitor.service
systemctl daemon-reload
systemctl stop disk-health-monitor 2>/dev/null || true
systemctl enable disk-health-monitor
systemctl restart disk-health-monitor

sleep 3
if systemctl is-active --quiet disk-health-monitor; then
    echo "SERVICE_OK"
else
    echo "SERVICE_FAILED"
    journalctl -u disk-health-monitor -n 10 --no-pager 2>/dev/null || true
fi
