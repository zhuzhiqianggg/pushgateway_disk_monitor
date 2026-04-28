#!/bin/bash
# 磁盘健康监控一键部署脚本
# 支持 SSH 密钥认证优先，无密钥时交互式输入账号密码
# 服务器列表和账号密码来自 config.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================== 加载外部配置 ====================
CONFIG_FILE="$SCRIPT_DIR/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "警告: 未找到配置文件 $CONFIG_FILE，使用默认配置"
    SERVERS=("192.168.10.150" "192.168.10.151" "192.168.10.152" "192.168.10.155" "192.168.10.198")
    PUSHGATEWAY_URL="http://121.36.241.152:9091"
    PUSH_INTERVAL="3600"
    REMOTE_INSTALL_DIR="/opt/monitor/disk_monitor"
    SSH_PORT=22
    SSH_CONNECT_TIMEOUT=15
fi

# ==================== 路径 ====================
MONITOR_SCRIPT="$SCRIPT_DIR/scripts/disk_health_monitor.sh"
SERVICE_FILE="$SCRIPT_DIR/systemd/disk-health-monitor.service"
REMOTE_SCRIPT_FILE="$SCRIPT_DIR/.remote_setup.sh"

# ==================== 认证 ====================
AUTH_MODE=""

has_ssh_key() {
    [[ -f "$HOME/.ssh/id_rsa" ]] || [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_ecdsa" ]]
}

get_ssh_opts() {
    local extra=""
    if [[ "$AUTH_MODE" == "password" ]]; then
        extra="-o PreferredAuthentications=password -o PasswordAuthentication=yes"
    fi
    echo "-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -p ${SSH_PORT} $extra"
}

get_scp_opts() {
    local extra=""
    if [[ "$AUTH_MODE" == "password" ]]; then
        extra="-o PreferredAuthentications=password -o PasswordAuthentication=yes"
    fi
    echo "-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -P ${SSH_PORT} $extra"
}

remote_exec() {
    local server="$1"; shift
    if [[ "$AUTH_MODE" == "password" ]]; then
        sshpass -p "$SSH_PASS" ssh $(get_ssh_opts) "${SSH_USER}@${server}" "$*"
    else
        ssh $(get_ssh_opts) "${SSH_USER}@${server}" "$*"
    fi
}

remote_scp() {
    local server="$1" src="$2" dst="$3"
    if [[ "$AUTH_MODE" == "password" ]]; then
        sshpass -p "$SSH_PASS" scp $(get_scp_opts) "$src" "${SSH_USER}@${server}:${dst}"
    else
        scp $(get_scp_opts) "$src" "${SSH_USER}@${server}:${dst}"
    fi
}

init_auth() {
    echo ""
    echo "============================================"
    echo "  SSH 认证配置"
    echo "============================================"

    # 如果 config.sh 中未配置 SSH_USER，交互式输入
    if [[ -z "${SSH_USER:-}" ]]; then
        read -p "请输入远程服务器登录用户 [root]: " SSH_USER
        SSH_USER="${SSH_USER:-root}"
    fi

    if has_ssh_key; then
        AUTH_MODE="key"
        local test_out
        test_out=$(remote_exec "${SERVERS[0]}" "echo CONNECTED" 2>&1) || true
        if echo "$test_out" | grep -q "CONNECTED"; then
            echo -e "\033[0;32m[SUCCESS]\033[0m SSH 密钥认证成功"
            return
        else
            echo -e "\033[1;33m[WARN]\033[0m SSH 密钥连接失败，切换为密码认证"
        fi
    fi

    # 如果 config.sh 中配置了 SSH_PASS 则直接使用，否则交互式输入
    if [[ -z "${SSH_PASS:-}" ]]; then
        read -s -p "请输入远程服务器密码: " SSH_PASS
        echo ""
    fi
    [[ -z "$SSH_PASS" ]] && { echo -e "\033[0;31m[ERROR]\033[0m 密码不能为空"; exit 1; }

    command -v sshpass &>/dev/null || { echo -e "\033[0;31m[ERROR]\033[0m 请安装 sshpass: apt-get install -y sshpass"; exit 1; }
    AUTH_MODE="password"
    echo -e "\033[0;34m[INFO]\033[0m 使用密码认证模式"
}

# ==================== 远程安装脚本 ====================
generate_remote_script() {
    cat > "$REMOTE_SCRIPT_FILE" <<REMOTE_EOF
#!/bin/bash
set -e
INSTALL_DIR="${REMOTE_INSTALL_DIR}"

if ! command -v smartctl &>/dev/null; then
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq smartmontools
    elif command -v yum &>/dev/null; then
        yum install -y -q smartmontools
    elif command -v dnf &>/dev/null; then
        dnf install -y -q smartmontools
    fi
fi

sed -i "s|PUSHGATEWAY_URL=.*|PUSHGATEWAY_URL=\"${PUSHGATEWAY_URL}\"|" "\${INSTALL_DIR}/scripts/disk_health_monitor.sh"
sed -i "s|SCRAPE_INTERVAL=.*|SCRAPE_INTERVAL=\"${PUSH_INTERVAL}\"|" "\${INSTALL_DIR}/scripts/disk_health_monitor.sh"

cp "\${INSTALL_DIR}/systemd/disk-health-monitor.service" /etc/systemd/system/disk-health-monitor.service
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
REMOTE_EOF
    chmod +x "$REMOTE_SCRIPT_FILE"
}

# ==================== 部署 ====================
deploy_to_server() {
    local server="$1"
    echo -e "\033[0;34m[INFO]\033[0m 开始部署到 $server ..."

    local test_out
    test_out=$(remote_exec "$server" "echo CONNECTED" 2>&1) || true
    if ! echo "$test_out" | grep -q "CONNECTED"; then
        echo -e "\033[0;31m[ERROR]\033[0m $server SSH连接失败: $test_out"
        return 1
    fi

    local remote_hostname
    remote_hostname=$(remote_exec "$server" "hostname 2>/dev/null" || echo "$server")
    echo -e "\033[0;34m[INFO]\033[0m 连接到 $server (hostname: $remote_hostname)"

    # 检测物理盘
    local has_physical
    has_physical=$(remote_exec "$server" "ls /dev/nvme?n? /dev/sd? 2>/dev/null | head -1" || true)
    if [[ -z "$has_physical" ]]; then
        echo -e "\033[1;33m[WARN]\033[0m $server 未检测到物理磁盘，跳过部署"
        return 0
    fi
    echo -e "\033[0;34m[INFO]\033[0m $server 检测到物理磁盘: $has_physical"

    # 创建远程目录结构
    remote_exec "$server" "mkdir -p ${REMOTE_INSTALL_DIR}/scripts ${REMOTE_INSTALL_DIR}/systemd ${REMOTE_INSTALL_DIR}/prometheus" || true

    # 上传文件
    remote_scp "$server" "$MONITOR_SCRIPT" "${REMOTE_INSTALL_DIR}/scripts/disk_health_monitor.sh"
    remote_exec "$server" "chmod +x ${REMOTE_INSTALL_DIR}/scripts/disk_health_monitor.sh"
    remote_scp "$server" "$SERVICE_FILE" "${REMOTE_INSTALL_DIR}/systemd/disk-health-monitor.service"
    remote_scp "$server" "$REMOTE_SCRIPT_FILE" "/tmp/disk_monitor_setup.sh"

    local setup_output
    setup_output=$(remote_exec "$server" "bash /tmp/disk_monitor_setup.sh" 2>&1) || true
    remote_exec "$server" "rm -f /tmp/disk_monitor_setup.sh" 2>/dev/null || true

    if echo "$setup_output" | grep -q "SERVICE_OK"; then
        return 0
    else
        echo -e "\033[0;31m[ERROR]\033[0m $server 服务启动失败: $setup_output"
        return 1
    fi
}

# ==================== 主流程 ====================
main() {
    [[ ! -f "$MONITOR_SCRIPT" ]] && { echo -e "\033[0;31m[ERROR]\033[0m 找不到监控脚本: $MONITOR_SCRIPT"; exit 1; }
    [[ ! -f "$SERVICE_FILE" ]] && { echo -e "\033[0;31m[ERROR]\033[0m 找不到 service 文件: $SERVICE_FILE"; exit 1; }

    echo ""
    echo "============================================"
    echo "  磁盘健康监控批量部署"
    echo "============================================"
    echo -e "\033[0;34m[INFO]\033[0m PushGateway: $PUSHGATEWAY_URL"
    echo -e "\033[0;34m[INFO]\033[0m 推送间隔: ${PUSH_INTERVAL}秒"
    echo -e "\033[0;34m[INFO]\033[0m 部署目录: $REMOTE_INSTALL_DIR"
    echo -e "\033[0;34m[INFO]\033[0m 服务器数: ${#SERVERS[@]}"
    echo ""

    init_auth
    generate_remote_script

    echo ""
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    SKIP_COUNT=0
    FAILED_SERVERS=()

    for server in "${SERVERS[@]}"; do
        echo "--------------------------------------------"
        if deploy_to_server "$server"; then
            local has_disk
            has_disk=$(remote_exec "$server" "ls /dev/nvme?n? /dev/sd? 2>/dev/null | head -1" 2>/dev/null || true)
            if [[ -n "$has_disk" ]]; then
                echo -e "\033[0;32m[SUCCESS]\033[0m $server 部署成功"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                SKIP_COUNT=$((SKIP_COUNT + 1))
            fi
        else
            echo -e "\033[0;31m[ERROR]\033[0m $server 部署失败"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_SERVERS+=("$server")
        fi
        echo ""
    done

    echo "============================================"
    echo "  部署结果汇总"
    echo "============================================"
    echo -e "\033[0;34m[INFO]\033[0m 成功: $SUCCESS_COUNT"
    [[ $SKIP_COUNT -gt 0 ]] && echo -e "\033[1;33m[WARN]\033[0m 跳过(无物理盘): $SKIP_COUNT"
    [[ $FAIL_COUNT -gt 0 ]] && echo -e "\033[0;31m[ERROR]\033[0m 失败: $FAIL_COUNT 台 - ${FAILED_SERVERS[*]}"
    echo "============================================"

    rm -f "$REMOTE_SCRIPT_FILE"
}

main "$@"
