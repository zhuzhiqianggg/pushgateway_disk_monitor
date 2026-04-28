#!/bin/bash
# apt 源 DNS 解析失败修复脚本

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  apt 源修复脚本"
echo "============================================"

# 1. 检查 DNS 配置
echo ""
echo "=== 检查 DNS ==="
cat /etc/resolv.conf 2>/dev/null || echo "无 resolv.conf"

# 2. 尝试 ping 测试 DNS
echo ""
echo "=== DNS 连通性测试 ==="
if ping -c1 -W2 223.5.5.5 &>/dev/null; then
    echo -e "${GREEN}Google DNS (223.5.5.5) 连通${NC}"
elif ping -c1 -W2 114.114.114.114 &>/dev/null; then
    echo -e "${GREEN}114 DNS (114.114.114.114) 连通${NC}"
else
    echo -e "${RED}DNS 服务器不可达，请检查网络配置${NC}"
    exit 1
fi

# 3. 备份并修复 DNS
echo ""
echo "=== 修复 DNS 配置 ==="
cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
cat > /etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 223.6.6.6
nameserver 114.114.114.114
EOF
echo -e "${GREEN}DNS 已更新为阿里+114 DNS${NC}"

# 4. 修复 apt 源（替换为阿里云镜像）
echo ""
echo "=== 修复 apt 源 ==="
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
sed -i 's|http://cn.archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list
sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list

# Ubuntu 24.04+ 可能使用 sources.list.d 目录
if ls /etc/apt/sources.list.d/*.sources &>/dev/null; then
    for f in /etc/apt/sources.list.d/*.sources; do
        sed -i 's|http://cn.archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' "$f"
        sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' "$f"
    done
    echo -e "${GREEN}已修复 sources.list.d 中的源${NC}"
fi
echo -e "${GREEN}apt 源已替换为阿里云镜像${NC}"

# 5. 更新并测试
echo ""
echo "=== 更新 apt 缓存 ==="
apt-get update -qq 2>&1 | tail -5

# 6. 尝试安装 smartmontools
echo ""
echo "=== 安装 smartmontools ==="
if command -v smartctl &>/dev/null; then
    echo -e "${GREEN}smartmontools 已安装${NC}"
else
    apt-get install -y -qq smartmontools
    if command -v smartctl &>/dev/null; then
        echo -e "${GREEN}smartmontools 安装成功${NC}"
    else
        echo -e "${RED}安装失败，请手动排查${NC}"
    fi
fi

echo ""
echo "============================================"
echo -e "${GREEN}修复完成${NC}"
echo "============================================"
