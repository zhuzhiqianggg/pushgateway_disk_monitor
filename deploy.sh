#!/bin/bash
# 磁盘健康监控一键部署脚本
# 支持 SSH 密钥认证优先，无密钥时交互式输入账号密码
# 服务器列表和账号密码来自 config.sh（需自行 cp config.sh.example config.sh）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================== 加载外部配置 ====================
CONFIG_FILE="$SCRIPT_DIR/config.sh"
CONFIG_EXAMPLE="$SCRIPT_DIR/config.sh.example"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
elif [[ -f "$CONFIG_EXAMPLE" ]]; then
    source "$CONFIG_EXAMPLE"
    echo -e "\033[1;33m[WARN]\033[0m 未找到 config.sh，使用 config.sh.example 默认配置"
    echo -e "\033[1;33m[WARN]\033[0m 建议: cp config.sh.example config.sh 并修改"
else
    echo -e "\033[0;31m[ERROR]\033[0m 未找到配置文件 config.sh 或 config.sh.example"
    exit 1
fi

# ==================== 超时控制 ====================
SSH_CMD_TIMEOUT="${SSH_CMD_TIMEOUT:-20}"
SCP_CMD_TIMEOUT="${SCP_CMD_TIMEOUT:-30}"
SERVER_DEPLOY_TIMEOUT="${SERVER_DEPLOY_TIMEOUT:-120}"

# ==================== 路径 ====================
MONITOR_SCRIPT="$SCRIPT_DIR/scripts/disk_health_monitor.sh"
SERVICE_FILE="$SCRIPT_DIR/systemd/disk-health-monitor.service"
REMOTE_SCRIPT_FILE="$SCRIPT_DIR/.remote_setup.sh"

# ==================== 认证 ====================
AUTH_MODE=""

has_ssh_key() {
    [[ -f "$HOME/.ssh/id_rsa" ]] || [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_ecdsa" ]]
}

get_ssh_base_opts() {
    echo "-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_CONNECT_TIMEOUT:-15} -p ${SSH_PORT:-22} -o BatchMode=no"
}

get_scp_base_opts() {
    echo "-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_CONNECT_TIMEOUT:-15} -P ${SSH_PORT:-22} -o BatchMode=no"
}

# 带超时的远程执行（防止卡住）
remote_exec() {
    local server="$1"; shift
    local cmd="$*"
    local ssh_opts
    ssh_opts=$(get_ssh_base_opts)

    if [[ "$AUTH_MODE" == "password" ]]; then
        ssh_opts="$ssh_opts -o PreferredAuthentications=password -o PasswordAuthentication=yes"
        timeout ${SSH_CMD_TIMEOUT} sshpass -p "$SSH_PASS" ssh $ssh_opts "${SSH_USER}@${server}" "$cmd" 2>&1
    else
        timeout ${SSH_CMD_TIMEOUT} ssh $ssh_opts "${SSH_USER}@${server}" "$cmd" 2>&1
    fi
    local rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "TIMEOUT" >&2
    fi
    return $rc
}

# 带超时的 SCP（防止卡住）
remote_scp() {
    local server="$1" src="$2" dst="$3"
    local scp_opts
    scp_opts=$(get_scp_base_opts)

    if [[ "$AUTH_MODE" == "password" ]]; then
        scp_opts="$scp_opts -o PreferredAuthentications=password -o PasswordAuthentication=yes"
        timeout ${SCP_CMD_TIMEOUT} sshpass -p "$SSH_PASS" scp $scp_opts "$src" "${SSH_USER}@${server}:${dst}" 2>&1
    else
        timeout ${SCP_CMD_TIMEOUT} scp $scp_opts "$src" "${SSH_USER}@${server}:${dst}" 2>&1
    fi
    local rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "TIMEOUT" >&2
    fi
    return $rc
}

init_auth() {
    echo ""
    echo "============================================"
    echo "  SSH 认证配置"
    echo "============================================"

    if [[ -z "${SSH_USER:-}" ]]; then
        read -p "请输入远程服务器登录用户 [root]: " SSH_USER
        SSH_USER="${SSH_USER:-root}"
    fi

    if has_ssh_key; then
        AUTH_MODE="key"
        echo -e "\033[0;34m[INFO]\033[0m 检测到 SSH 密钥，使用密钥认证"
        return
    fi

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
    cat > "$REMOTE_SCRIPT_FILE" <<'REMOTE_EOF'
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
REMOTE_EOF
    chmod +x "$REMOTE_SCRIPT_FILE"
}

# ==================== 部署单台服务器（带超时保护） ====================
deploy_to_server() {
    local server="$1"
    echo -e "\033[0;34m[INFO]\033[0m 开始部署到 $server ..."

    # 1. 测试连接（超时保护）
    local test_out
    test_out=$(remote_exec "$server" "echo CONNECTED" 2>&1) || true
    if [[ "$test_out" == *"TIMEOUT"* ]] || ! echo "$test_out" | grep -q "CONNECTED"; then
        echo -e "\033[0;31m[ERROR]\033[0m $server SSH连接失败或超时"
        return 1
    fi

    # 2. 获取主机名
    local remote_hostname
    remote_hostname=$(remote_exec "$server" "hostname 2>/dev/null" || echo "$server")
    echo -e "\033[0;34m[INFO]\033[0m 连接到 $server (hostname: $remote_hostname)"

    # 3. 检测物理盘
    local has_physical
    has_physical=$(remote_exec "$server" "ls /dev/nvme?n? /dev/sd? 2>/dev/null | head -1" || true)
    if [[ -z "$has_physical" ]]; then
        echo -e "\033[1;33m[WARN]\033[0m $server 未检测到物理磁盘，跳过"
        return 0
    fi
    echo -e "\033[0;34m[INFO]\033[0m $server 检测到物理磁盘: $has_physical"

    # 4. 创建远程目录
    echo -e "\033[0;34m[INFO]\033[0m 创建远程目录 ..."
    remote_exec "$server" "mkdir -p ${REMOTE_INSTALL_DIR}/scripts ${REMOTE_INSTALL_DIR}/systemd ${REMOTE_INSTALL_DIR}/prometheus" || true

    # 5. 上传脚本文件（超时保护）
    echo -e "\033[0;34m[INFO]\033[0m 上传文件 ..."
    local scp_out
    scp_out=$(remote_scp "$server" "$MONITOR_SCRIPT" "${REMOTE_INSTALL_DIR}/scripts/disk_health_monitor.sh" 2>&1) || true
    if [[ "$scp_out" == *"TIMEOUT"* ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m $server 上传监控脚本超时"
        return 1
    fi

    scp_out=$(remote_scp "$server" "$SERVICE_FILE" "${REMOTE_INSTALL_DIR}/systemd/disk-health-monitor.service" 2>&1) || true
    if [[ "$scp_out" == *"TIMEOUT"* ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m $server 上传 service 文件超时"
        return 1
    fi

    # 6. 权限设置 + 远程安装
    remote_exec "$server" "chmod +x ${REMOTE_INSTALL_DIR}/scripts/disk_health_monitor.sh" || true
    remote_scp "$server" "$REMOTE_SCRIPT_FILE" "/tmp/disk_monitor_setup.sh" 2>&1 || true

    echo -e "\033[0;34m[INFO]\033[0m 安装服务 ..."
    local setup_out
    setup_out=$(timeout ${SERVER_DEPLOY_TIMEOUT} remote_exec "$server" "bash /tmp/disk_monitor_setup.sh ${REMOTE_INSTALL_DIR} ${PUSHGATEWAY_URL} ${PUSH_INTERVAL}" 2>&1) || true

    remote_exec "$server" "rm -f /tmp/disk_monitor_setup.sh" 2>/dev/null || true

    if echo "$setup_out" | grep -q "SERVICE_OK"; then
        return 0
    else
        echo -e "\033[0;31m[ERROR]\033[0m $server 服务启动失败"
        [[ -n "$setup_out" ]] && echo "$setup_out" | tail -5
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
    echo -e "\033[0;34m[INFO]\033[0m SSH超时: ${SSH_CMD_TIMEOUT}s / SCP超时: ${SCP_CMD_TIMEOUT}s"
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
