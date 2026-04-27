#!/bin/bash
# disk_health_monitor.sh
# 磁盘健康监控脚本，支持Prometheus格式输出

set -e

# 配置文件
CONFIG_FILE="/etc/disk_monitor.conf"
EXPORTER_PORT="9101"
SCRAPE_INTERVAL="3600"
PUSHGATEWAY_URL="http://121.36.241.152:9091"
PUSH_JOB_NAME="disk_health"
PUSH_INSTANCE_NAME=""

# 默认指标
METRICS=(
    "health_status"
    "temperature_celsius"
    "power_on_hours"
    "reallocated_sectors"
    "reported_uncorrectable_errors"
    "command_timeout"
    "current_pending_sector"
    "offline_uncorrectable"
    "wear_leveling_count"
    "media_wearout_indicator"
    "percentage_used"
    "available_spare"
    "available_spare_threshold"
)

# 颜色定义（用于控制台输出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查smartctl是否安装
check_dependencies() {
    if ! command -v smartctl &> /dev/null; then
        echo "错误: smartctl 未安装"
        echo "请安装 smartmontools:"
        echo "  Ubuntu/Debian: apt-get install smartmontools"
        echo "  RHEL/CentOS: yum install smartmontools"
        echo "  Fedora: dnf install smartmontools"
        exit 1
    fi
}

# 获取所有磁盘设备
get_disk_devices() {
    # 获取所有磁盘设备
    local devices=()
    
    # 查找所有磁盘设备
    for device in $(ls /dev/sd? 2>/dev/null) $(ls /dev/nvme?n? 2>/dev/null) $(ls /dev/mmcblk? 2>/dev/null); do
        if [[ -e "$device" ]]; then
            devices+=("$device")
        fi
    done
    
    # 如果没有找到磁盘，尝试通过smartctl扫描
    if [ ${#devices[@]} -eq 0 ]; then
        echo "正在扫描磁盘设备..."
        devices=($(smartctl --scan | awk '{print $1}'))
    fi
    
    echo "${devices[@]}"
}

check_smart_supported() {
    local device=$1
    local smart_output
    smart_output=$(smartctl -i "$device" 2>/dev/null || true)

    if echo "$smart_output" | grep -qi "SMART support is.*Available"; then
        echo 1
    elif echo "$smart_output" | grep -qi "NVMe Version"; then
        echo 1
    else
        echo 0
    fi
}

check_device_accessible() {
    local device=$1
    if [[ -b "$device" ]] && blockdev --getsize64 "$device" &>/dev/null; then
        echo 1
    else
        echo 0
    fi
}

parse_nvme_line() {
    local line="$1"
    echo "$line" | sed 's/,//g' | awk '{print $2}' | tr -d '%'
}

generate_filesystem_metrics() {
    local hostname
    hostname=$(get_hostname)

    echo "# HELP smart_filesystem_size_bytes 文件系统总大小(字节)"
    echo "# TYPE smart_filesystem_size_bytes gauge"
    echo "# HELP smart_filesystem_used_bytes 文件系统已使用大小(字节)"
    echo "# TYPE smart_filesystem_used_bytes gauge"
    echo "# HELP smart_filesystem_avail_bytes 文件系统可用大小(字节)"
    echo "# TYPE smart_filesystem_avail_bytes gauge"
    echo "# HELP smart_filesystem_use_percent 文件系统使用百分比"
    echo "# TYPE smart_filesystem_use_percent gauge"

    (
        flock -n 200 || exit 1
        timeout 3 df -P 2>/dev/null | grep -E '^/dev/' | awk '{
            gsub(/%/, "", $5);
            gsub(/"/, "", $6);
            gsub(/[^a-zA-Z0-9\/_.-]/, "_", $6);
            printf "smart_filesystem_size_bytes{mountpoint=\"%s\",device=\"%s\",hostname=\"%s\"} %s\n", $6, $1, HOST, $2;
            printf "smart_filesystem_used_bytes{mountpoint=\"%s\",device=\"%s\",hostname=\"%s\"} %s\n", $6, $1, HOST, $3;
            printf "smart_filesystem_avail_bytes{mountpoint=\"%s\",device=\"%s\",hostname=\"%s\"} %s\n", $6, $1, HOST, $4;
            printf "smart_filesystem_use_percent{mountpoint=\"%s\",device=\"%s\",hostname=\"%s\"} %s\n", $6, $1, HOST, $5;
        }'
    ) 200>/tmp/disk_monitor_fs.lock
}

# 获取磁盘基本信息
detect_disk_type() {
    local device=$1
    local dev_name=$(basename "$device")

    if [[ $device == /dev/nvme* ]]; then
        echo "nvme"
        return
    fi

    local smart_output=$(smartctl -i "$device" 2>/dev/null || true)
    local vendor=$(echo "$smart_output" | grep -i "Vendor" | head -1 | cut -d: -f2 | xargs)
    local product=$(echo "$smart_output" | grep -i "Product" | head -1 | cut -d: -f2 | xargs)
    local model=$(echo "$smart_output" | grep -iE "Device Model|Model Number" | head -1 | cut -d: -f2 | xargs)
    local rotation=$(echo "$smart_output" | grep -i "Rotation Rate" | head -1 | cut -d: -f2 | xargs)
    local transport=$(echo "$smart_output" | grep -i "Transport protocol" | head -1 | cut -d: -f2 | xargs)

    if echo "$vendor" | grep -qi "VMware"; then
        echo "vmware"
        return
    fi
    if echo "$vendor" | grep -qi "QEMU\|KVM\|virtio"; then
        echo "kvm"
        return
    fi
    if echo "$vendor" | grep -qi "Virtual"; then
        echo "virtual"
        return
    fi

    local rota_file="/sys/block/${dev_name}/queue/rotational"
    if [ -f "$rota_file" ]; then
        local rota=$(cat "$rota_file" 2>/dev/null || echo "1")
        if [ "$rota" = "0" ]; then
            if echo "$rotation" | grep -qi "Solid State\|SSD"; then
                echo "ssd"
            else
                echo "ssd"
            fi
            return
        else
            echo "hdd"
            return
        fi
    fi

    if echo "$rotation" | grep -qi "Solid State\|SSD\|Not Rotating"; then
        echo "ssd"
        return
    fi

    if echo "$transport" | grep -qi "sas\|fc"; then
        echo "sas"
        return
    fi

    echo "sata"
}

format_disk_size() {
    local size_str=$1
    if [ -z "$size_str" ] || [ "$size_str" = "Unknown" ]; then
        echo "Unknown"
        return
    fi

    local size_bytes=$(echo "$size_str" | grep -oP '\d[\d,]+' | tr -d ',')
    if [ -z "$size_bytes" ]; then
        echo "$size_str"
        return
    fi

    local size_gb=$((size_bytes / 1073741824))
    if [ $size_gb -ge 1024 ]; then
        echo "${size_gb}GB"
    else
        echo "${size_gb}GB"
    fi
}

get_disk_info() {
    local device=$1
    local model=""
    local serial=""
    local size=""
    local disk_type=""

    local smart_output=$(smartctl -i "$device" 2>/dev/null || true)

    disk_type=$(detect_disk_type "$device")

    model=$(echo "$smart_output" | grep -E "Model Number|Device Model|Product" | head -1 | cut -d: -f2 | xargs)
    serial=$(echo "$smart_output" | grep "Serial Number" | cut -d: -f2 | xargs)

    local size_line=$(echo "$smart_output" | grep "User Capacity" | head -1)
    if [[ -n "$size_line" ]]; then
        local size_bytes=$(echo "$size_line" | grep -oP '\d[\d,]+ bytes' | head -1 | grep -oP '\d[\d,]+' | tr -d ',')
        if [[ -n "$size_bytes" ]] && [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            size="$((size_bytes / 1073741824))GB"
        else
            size=$(echo "$size_line" | cut -d[ -f2 | cut -d] -f1 | xargs)
        fi
    fi

    if [[ -z "$size" ]]; then
        local dev_name=$(basename "$device")
        local size_bytes=$(blockdev --getsize64 "/dev/${dev_name}" 2>/dev/null || echo "0")
        if [ "$size_bytes" -gt 0 ] 2>/dev/null; then
            size="$((size_bytes / 1073741824))GB"
        else
            size="Unknown"
        fi
    fi

    if [[ -z "$model" ]]; then
        model="Unknown"
    fi
    if [[ -z "$serial" ]]; then
        serial="Unknown"
    fi

    echo "${disk_type}|${model}|${serial}|${size}"
}

# 获取磁盘健康状态
get_disk_health() {
    local device=$1
    local health_status=0
    local output
    
    # 检查磁盘健康状态
    output=$(smartctl -H "$device" 2>/dev/null || true)
    
    if echo "$output" | grep -q "PASSED"; then
        health_status=1
    elif echo "$output" | grep -q "FAILED"; then
        health_status=0
    elif echo "$output" | grep -q "OK"; then
        health_status=1
    else
        # 无法获取健康状态
        health_status=2
    fi
    
    echo $health_status
}

# 获取磁盘温度
get_disk_temperature() {
    local device=$1
    local temperature=0

    if [[ $device == /dev/nvme* ]]; then
        local temp_line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Temperature:')
        if [[ -n "$temp_line" ]]; then
            temperature=$(echo "$temp_line" | sed 's/.*Temperature: *//' | awk '{print $1}')
        fi
    else
        local temp_output=$(smartctl -A "$device" 2>/dev/null | grep "Temperature_Celsius" | awk '{print $10}')
        if [[ -z "$temp_output" || ! "$temp_output" =~ ^[0-9]+$ ]]; then
            temp_output=$(smartctl -A "$device" 2>/dev/null | grep -E "Airflow_Temperature" | awk '{print $10}')
        fi
        if [[ -n "$temp_output" && "$temp_output" =~ ^[0-9]+$ ]]; then
            temperature=$temp_output
        fi
    fi

    if [[ -z "$temperature" || ! "$temperature" =~ ^[0-9]+$ ]]; then
        temperature=0
    fi

    echo $temperature
}

# 获取磁盘使用时间（小时）
get_power_on_hours() {
    local device=$1
    local hours=0

    if [[ $device == /dev/nvme* ]]; then
        local line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Power On Hours:')
        if [[ -n "$line" ]]; then
            hours=$(echo "$line" | sed 's/.*Power On Hours: *//' | awk '{print $1}' | tr -d ',')
        fi
    else
        hours=$(smartctl -A "$device" 2>/dev/null | grep "Power_On_Hours" | awk '{print $10}')
    fi

    if [[ -z "$hours" || ! "$hours" =~ ^[0-9]+$ ]]; then
        hours=0
    fi

    echo $hours
}

# 获取重映射扇区数
get_reallocated_sectors() {
    local device=$1
    local sectors=0

    if [[ $device == /dev/nvme* ]]; then
        local line=$(smartctl -A "$device" 2>/dev/null | grep -E '^Unsafe Shutdowns:')
        if [[ -n "$line" ]]; then
            sectors=$(echo "$line" | sed 's/.*Unsafe Shutdowns: *//' | awk '{print $1}' | tr -d ',')
        fi
    else
        sectors=$(smartctl -A "$device" 2>/dev/null | grep "Reallocated_Sector_Ct" | awk '{print $10}')
    fi

    if [[ -z "$sectors" || ! "$sectors" =~ ^[0-9]+$ ]]; then
        sectors=0
    fi

    echo $sectors
}

# 获取SSD寿命信息
get_ssd_life_info() {
    local device=$1
    local info_type=$2
    local value=0

    if [[ $device == /dev/nvme* ]]; then
        case $info_type in
            "percentage_used")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Percentage Used:' | sed 's/.*Percentage Used: *//' | awk '{print $1}' | tr -d '%,' )
                ;;
            "available_spare")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Available Spare:' | sed 's/.*Available Spare: *//' | awk '{print $1}' | tr -d '%,' )
                ;;
            "available_spare_threshold")
                value=$(smartctl -A "$device" 2>/dev/null | grep 'Available Spare Threshold:' | sed 's/.*Available Spare Threshold: *//' | awk '{print $1}' | tr -d '%,' )
                ;;
            *)
                value=0
                ;;
        esac
    else
        local smart_output=$(smartctl -A "$device" 2>/dev/null)

        case $info_type in
            "wear_leveling_count")
                local wl_raw=$(echo "$smart_output" | grep -i "Wear_Leveling_Count" | awk '{print $10}')
                local wl_value=$(echo "$smart_output" | grep -i "Wear_Leveling_Count" | awk '{print $4}' | sed 's/^0*//')
                if [[ -n "$wl_value" && "$wl_value" =~ ^[0-9]+$ ]]; then
                    value=$wl_value
                elif [[ -n "$wl_raw" && "$wl_raw" =~ ^[0-9]+$ ]]; then
                    value=$wl_raw
                fi
                ;;
            "media_wearout_indicator")
                value=$(echo "$smart_output" | grep -i "Media_Wearout_Indicator" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                ;;
            "percentage_used")
                local pl_used=$(echo "$smart_output" | grep -i "Percent_Lifetime_Used" | awk '{print $4}' | sed 's/^0*//' | tr -d '%')
                if [[ -z "$pl_used" ]]; then
                    pl_used=$(echo "$smart_output" | grep -i "Percentage Used" | awk '{print $3}' | sed 's/^0*//' | tr -d '%')
                fi
                if [[ -z "$pl_used" ]]; then
                    local wl_value=$(echo "$smart_output" | grep -i "Wear_Leveling_Count" | awk '{print $4}' | sed 's/^0*//')
                    if [[ -n "$wl_value" && "$wl_value" =~ ^[0-9]+$ && "$wl_value" -lt 100 ]]; then
                        pl_used=$((100 - wl_value))
                    fi
                fi
                value=$pl_used
                ;;
            *)
                value=0
                ;;
        esac
    fi

    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
        value=0
    fi

    echo $value
}

get_disk_mount_points() {
    local device=$1
    local device_basename=$(basename "$device")
    local mount_points=""

    local lsblk_output
    lsblk_output=$(timeout 3 lsblk -no MOUNTPOINT "$device" 2>/dev/null || echo "")
    if [[ -n "$lsblk_output" ]]; then
        mount_points=$(echo "$lsblk_output" | grep -v "^$" | grep -v "^SWAP" | tr '\n' ',' | sed 's/,$//')
    fi

    if [[ -z "$mount_points" ]]; then
        mount_points="unmounted"
    fi

    echo "$mount_points"
}

get_hostname() {
    hostname
}

# 生成Prometheus指标HELP和TYPE头（只输出一次）
generate_prometheus_headers() {
    cat <<'EOF'
# HELP smart_smart_available SMART是否可用 (0=不支持, 1=支持)
# TYPE smart_smart_available gauge
# HELP smart_health_status 磁盘健康状态 (0=失败, 1=正常, 2=未知, -1=SMART不支持)
# TYPE smart_health_status gauge
# HELP smart_temperature_celsius 磁盘温度(摄氏度, -1表示不可获取)
# TYPE smart_temperature_celsius gauge
# HELP smart_power_on_hours 磁盘通电时间(小时, -1表示不可获取)
# TYPE smart_power_on_hours gauge
# HELP smart_reallocated_sectors 重映射扇区数量(-1表示不可获取)
# TYPE smart_reallocated_sectors gauge
# HELP smart_percentage_used SSD已使用百分比(-1表示不可获取)
# TYPE smart_percentage_used gauge
# HELP smart_available_spare SSD可用备用块百分比(-1表示不可获取)
# TYPE smart_available_spare gauge
# HELP smart_available_spare_threshold SSD备用块阈值百分比(-1表示不可获取)
# TYPE smart_available_spare_threshold gauge
EOF
}

# 生成单个磁盘的Prometheus指标值（不含HELP/TYPE）
generate_prometheus_metric_values() {
    local device=$1
    local device_basename=$(basename "$device")
    local disk_info=$(get_disk_info "$device")
    IFS='|' read -r disk_type model serial size <<< "$disk_info"

    local hostname_val=$(get_hostname)
    local mount_points=$(get_disk_mount_points "$device")
    local smart_supported=$(check_smart_supported "$device")

    model=$(echo "$model" | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    serial=$(echo "$serial" | tr -cd '[:alnum:]')
    mount_points=$(echo "$mount_points" | tr -cd '[:alnum:]_/,-')

    local labels="device=\"$device_basename\",hostname=\"$hostname_val\",mountpoints=\"$mount_points\",model=\"$model\",serial=\"$serial\",type=\"$disk_type\",smart_supported=\"$smart_supported\""
    local smart_labels="device=\"$device_basename\",hostname=\"$hostname_val\",mountpoints=\"$mount_points\",model=\"$model\",serial=\"$serial\",type=\"$disk_type\""

    echo "smart_smart_available{$labels} $smart_supported"

    if [[ $smart_supported -eq 1 ]]; then
        local health_status=$(get_disk_health "$device")
        local temperature=$(get_disk_temperature "$device")
        local power_on_hours=$(get_power_on_hours "$device")
        local reallocated_sectors=$(get_reallocated_sectors "$device")
        local percentage_used=$(get_ssd_life_info "$device" "percentage_used")
        local available_spare=$(get_ssd_life_info "$device" "available_spare")
        local available_spare_threshold=$(get_ssd_life_info "$device" "available_spare_threshold")
    else
        local health_status=1
        local temperature=-1
        local power_on_hours=-1
        local reallocated_sectors=-1
        local percentage_used=-1
        local available_spare=-1
        local available_spare_threshold=-1
    fi

    echo "smart_health_status{$smart_labels} $health_status"
    echo "smart_temperature_celsius{$smart_labels} $temperature"
    echo "smart_power_on_hours{$smart_labels} $power_on_hours"
    echo "smart_reallocated_sectors{$smart_labels} $reallocated_sectors"
    echo "smart_percentage_used{$smart_labels} $percentage_used"
    echo "smart_available_spare{$smart_labels} $available_spare"
    echo "smart_available_spare_threshold{$smart_labels} $available_spare_threshold"
}

# 控制台彩色输出
print_colored_output() {
    local device=$1
    local device_basename=$(basename "$device")
    local disk_info=$(get_disk_info "$device")
    IFS='|' read -r disk_type model serial size <<< "$disk_info"

    local smart_supported=$(check_smart_supported "$device")

    if [[ $smart_supported -eq 1 ]]; then
        health_status=$(get_disk_health "$device")
        temperature=$(get_disk_temperature "$device")
        power_on_hours=$(get_power_on_hours "$device")
        reallocated_sectors=$(get_reallocated_sectors "$device")
    else
        health_status=1
        temperature=-1
        power_on_hours=-1
        reallocated_sectors=-1
    fi

    if [ $health_status -eq 1 ]; then
        health_color=$GREEN
        health_text="正常"
    elif [ $health_status -eq 0 ]; then
        health_color=$RED
        health_text="失败"
    else
        health_color=$YELLOW
        health_text="未知"
    fi

    if [ $temperature -gt 50 ]; then
        temp_color=$RED
    elif [ $temperature -gt 40 ]; then
        temp_color=$YELLOW
    else
        temp_color=$GREEN
    fi

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}设备: $device_basename${NC}"
    echo -e "${BLUE}型号: $model${NC}"
    echo -e "${BLUE}类型: $disk_type${NC}"
    echo -e "${BLUE}容量: $size${NC}"
    echo -e "${BLUE}序列号: $serial${NC}"
    if [[ $smart_supported -eq 1 ]]; then
        echo -e "${BLUE}SMART: ${GREEN}已启用${NC}"
        echo -e "${BLUE}健康状态: ${health_color}$health_text${NC}"
        echo -e "${BLUE}温度: ${temp_color}${temperature}°C${NC}"
        echo -e "${BLUE}通电时间: ${power_on_hours}小时${NC}"
        echo -e "${BLUE}重映射扇区: ${reallocated_sectors}${NC}"
    else
        echo -e "${BLUE}SMART: ${YELLOW}不支持 (虚拟化磁盘)${NC}"
        echo -e "${BLUE}健康状态: ${health_color}$health_text${NC}"
        echo -e "${BLUE}SMART指标: ${YELLOW}N/A (设备不支持S.M.A.R.T)${NC}"
    fi
}

# 主监控循环
monitor_loop() {
    echo "开始磁盘健康监控..."
    echo "指标将在 http://localhost:$EXPORTER_PORT/metrics 提供"
    echo "按 Ctrl+C 停止监控"
    
    while true; do
        # 生成HTML页面
        cat > /tmp/disk_metrics.html <<EOF
<html>
<head>
    <title>磁盘健康监控</title>
    <meta http-equiv="refresh" content="10">
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .device { border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 5px; }
        .healthy { color: green; }
        .warning { color: orange; }
        .error { color: red; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>磁盘健康监控</h1>
    <p>更新时间: $(date)</p>
EOF
        
        # 为每个磁盘生成指标
        METRICS_CONTENT=""
        METRICS_CONTENT+=$(generate_prometheus_headers)
        METRICS_CONTENT+=$'\n'
        for device in $(get_disk_devices); do
            if [ -e "$device" ]; then
                METRICS_CONTENT+=$(generate_prometheus_metric_values "$device")
                METRICS_CONTENT+=$'\n'
            fi
        done
        
        echo "$METRICS_CONTENT" > /tmp/disk_metrics.prom
        ln -sf /tmp/disk_metrics.prom /tmp/metrics

        # 生成简化的HTML页面
        cat >> /tmp/disk_metrics.html <<EOF
    <h2>磁盘状态概览</h2>
    <table>
        <tr>
            <th>设备</th>
            <th>型号</th>
            <th>健康状态</th>
            <th>温度(°C)</th>
            <th>通电时间(小时)</th>
            <th>重映射扇区</th>
        </tr>
EOF
        
        for device in $(get_disk_devices); do
            if [ -e "$device" ]; then
                device_basename=$(basename "$device")
                disk_info=$(get_disk_info "$device")
                IFS='|' read -r disk_type model serial size <<< "$disk_info"
                health_status=$(get_disk_health "$device")
                temperature=$(get_disk_temperature "$device")
                power_on_hours=$(get_power_on_hours "$device")
                reallocated_sectors=$(get_reallocated_sectors "$device")
                
                if [ $health_status -eq 1 ]; then
                    health_class="healthy"
                    health_text="正常"
                elif [ $health_status -eq 0 ]; then
                    health_class="error"
                    health_text="失败"
                else
                    health_class="warning"
                    health_text="未知"
                fi
                
                cat >> /tmp/disk_metrics.html <<EOF
        <tr>
            <td>$device_basename</td>
            <td>$model</td>
            <td class="$health_class">$health_text</td>
            <td>$temperature</td>
            <td>$power_on_hours</td>
            <td>$reallocated_sectors</td>
        </tr>
EOF
            fi
        done
        
        cat >> /tmp/disk_metrics.html <<EOF
    </table>
    <p><a href="/metrics">查看原始Prometheus指标</a></p>
</body>
</html>
EOF
        
        sleep $SCRAPE_INTERVAL
    done
}

# 启动HTTP服务器
start_http_server() {
    touch /tmp/disk_metrics.prom
    ln -sf /tmp/disk_metrics.prom /tmp/metrics
    python3 -m http.server $EXPORTER_PORT --directory /tmp/ &> /tmp/disk_exporter.log &
    SERVER_PID=$!
    echo "HTTP服务器已启动 (PID: $SERVER_PID)"
}

push_to_gateway() {
    local metrics_file="$1"
    local instance="${PUSH_INSTANCE_NAME:-$(hostname)}"

    if [ ! -s "$metrics_file" ]; then
        echo "警告: 指标文件为空，跳过推送"
        return 1
    fi

    local url="${PUSHGATEWAY_URL}/metrics/job/${PUSH_JOB_NAME}/instance/${instance}"

    local response
    response=$(curl -s -w "\n%{http_code}" --data-binary "@${metrics_file}" "$url" 2>&1)
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
        return 0
    else
        echo "推送失败: HTTP $http_code - $body" >&2
        return 1
    fi
}

push_loop() {
    echo "开始推送磁盘健康指标到 PushGateway..."
    echo "PushGateway地址: ${PUSHGATEWAY_URL}"
    echo "Job名称: ${PUSH_JOB_NAME}"
    echo "实例名称: ${PUSH_INSTANCE_NAME:-$(hostname)}"
    echo "推送间隔: ${SCRAPE_INTERVAL}秒"
    echo "按 Ctrl+C 停止"

    while true; do
        METRICS_FILE="/tmp/disk_metrics_$$.prom"
        {
            generate_prometheus_headers
            for device in $(get_disk_devices); do
                if [ -e "$device" ]; then
                    generate_prometheus_metric_values "$device"
                fi
            done
        } > "$METRICS_FILE"

        if push_to_gateway "$METRICS_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 推送成功"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 推送失败"
        fi

        rm -f "$METRICS_FILE"
        sleep $SCRAPE_INTERVAL
    done
}

# 清理函数
cleanup() {
    echo -e "\n正在清理..."
    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi
    exit 0
}

# 主函数
main() {
    # 设置信号处理
    trap cleanup SIGINT SIGTERM
    
    # 检查依赖
    check_dependencies
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --console|-c)
                MODE="console"
                shift
                ;;
            --prometheus|-p)
                MODE="prometheus"
                shift
                ;;
            --pushgateway|--push|-g)
                MODE="pushgateway"
                shift
                ;;
            --once|-o)
                MODE="once"
                shift
                ;;
            --port)
                EXPORTER_PORT="$2"
                shift 2
                ;;
            --interval)
                SCRAPE_INTERVAL="$2"
                shift 2
                ;;
            --pushgateway-url)
                PUSHGATEWAY_URL="$2"
                shift 2
                ;;
            --job)
                PUSH_JOB_NAME="$2"
                shift 2
                ;;
            --instance)
                PUSH_INSTANCE_NAME="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 默认模式
    if [ -z "$MODE" ]; then
        MODE="prometheus"
    fi
    
    case $MODE in
        "console")
            echo "=== 磁盘健康检查 ==="
            for device in $(get_disk_devices); do
                if [ -e "$device" ]; then
                    print_colored_output "$device"
                fi
            done
            ;;
        "once")
            generate_prometheus_headers
            for device in $(get_disk_devices); do
                if [ -e "$device" ]; then
                    generate_prometheus_metric_values "$device"
                fi
            done
            ;;
        "prometheus")
            start_http_server
            monitor_loop
            ;;
        "pushgateway")
            push_loop
            ;;
    esac
}

# 显示帮助
show_help() {
    cat <<EOF
磁盘健康监控脚本

用法: $0 [选项]

选项:
  -c, --console     控制台模式（彩色输出）
  -p, --prometheus  Prometheus导出器模式（默认）
  -o, --once        单次输出Prometheus格式指标
  -g, --pushgateway 推送到PushGateway模式
  --port PORT       设置HTTP服务器端口（默认: 9101）
  --interval SEC    设置采集间隔（默认: 60秒）
  --pushgateway-url URL  设置PushGateway地址（默认: http://localhost:9091）
  --job NAME        设置PushGateway job名称（默认: disk_health）
  --instance NAME   设置PushGateway instance名称（默认: 主机名）
  -h, --help        显示此帮助信息

示例:
  $0 --console                    # 控制台输出
  $0 --once                       # 单次输出Prometheus格式
  $0 --prometheus --port 9101     # 启动Prometheus导出器
  $0 --prometheus --interval 30   # 30秒采集间隔
  $0 --pushgateway --pushgateway-url http://pushgateway:9091  # 推送到PushGateway
  $0 -g --job disk_monitor --instance server01  # 自定义job和instance名称

部署说明:
  1. 在每台服务器上运行脚本，配置相同的PushGateway地址
  2. Prometheus配置从PushGateway拉取指标:
     - job_name: 'disk-health'
       static_configs:
         - targets: ['pushgateway:9091']
  3. 所有服务器的指标通过job/instance标签区分

EOF
}

# 运行主函数
main "$@"