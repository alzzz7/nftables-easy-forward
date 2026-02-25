#!/bin/bash
set -e

# 清空当前可视区域并将光标移至左上角
printf '\033[2J\033[H'
echo "======== nftables 简单转发卸载 ========"

# 1. Root 权限检查与自动提权
if [ "$EUID" -ne 0 ]; then
  # 重新使用 sudo 执行脚本，并传递所有参数
  exec sudo "$0" "$@"
  exit $?
fi

TABLE_NAME="e2e_forwarding"

echo "开始卸载 $TABLE_NAME 端口转发规则..."

# 2. 清除并删除自建的 nftables 表
REMOVED_TABLE=0
for F in inet ip; do
    if nft list table $F $TABLE_NAME &>/dev/null; then
        echo "找到转发表 $F $TABLE_NAME，正在清除..."
        nft flush table $F $TABLE_NAME
        nft delete table $F $TABLE_NAME
        echo "已清除表 $F $TABLE_NAME "
        REMOVED_TABLE=1
    fi
done

if [ "$REMOVED_TABLE" -eq 0 ]; then
    echo "当前内存中未找到 $TABLE_NAME 表，无需清除 "
fi

# 3. 清理防火墙放行规则 (UFW / firewalld)
FW_RECORD_FILE="/var/run/nft_forward_fw_record.txt"
if [ -f "$FW_RECORD_FILE" ]; then
    echo "发现防火墙放行记录文件，清理遗留的放行规则..."
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        # 格式: fw_type:port/protocol
        FW_TYPE="${line%%:*}"
        PORT_PROTO="${line#*:}"
        
        if [ "$FW_TYPE" == "ufw" ]; then
            echo "  - 从 UFW 移除放行规则: $PORT_PROTO"
            ufw delete allow "$PORT_PROTO" >/dev/null 2>&1 || true
        elif [ "$FW_TYPE" == "firewalld" ]; then
            echo "  - 从 firewalld 移除放行规则: $PORT_PROTO"
            firewall-cmd --remove-port="$PORT_PROTO" --permanent >/dev/null 2>&1 || true
            firewall-cmd --remove-port="$PORT_PROTO" >/dev/null 2>&1 || true
        fi
    done < "$FW_RECORD_FILE"
    rm -f "$FW_RECORD_FILE"
    echo "防火墙遗留规则清理完毕"
else
    echo "未找到防火墙放行记录文件，跳过防火墙规则清理 "
fi

# 4. 持久化清理后的规则（覆盖原有配置，防止开机恢复）
echo "正在持久化 nftables 规则..."

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  OS="unknown"
fi

SAVE_PATH=""
if [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS" == "arch" || "$OS" == "alpine" ]]; then
    SAVE_PATH="/etc/nftables.conf"
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    SAVE_PATH="/etc/sysconfig/nftables.conf"
    if [ ! -d /etc/sysconfig ] && [ -d /etc/nftables.conf ]; then
        SAVE_PATH="/etc/nftables.conf"
    fi
else
    SAVE_PATH="/etc/nftables.conf"
fi

# 如果找不到常规的配置文件路径，就不执行覆盖，避免误删
if [ -n "$SAVE_PATH" ] && [ -f "$SAVE_PATH" ]; then
    nft list ruleset > "$SAVE_PATH"
    echo "规则已重新保存至 $SAVE_PATH，开机不会再恢复之前的转发规则 "
else
    echo "未找到系统默认的 nftables 配置文件 ($SAVE_PATH)，跳过持久化步骤 "
fi

# 5. 可选：关闭内核 IP 转发 (如果不需要了的话)
echo ""
read -p "是否需要同时关闭系统的 IP 内核转发功能 (net.ipv4/ipv6.ip_forward)？[y/N]: " DISABLE_FORWARD
if [[ "$DISABLE_FORWARD" =~ ^[Yy]$ ]]; then
    echo "正在关闭 IP 转发..."
    echo "net.ipv4.ip_forward = 0" > /etc/sysctl.d/99-nft-forward.conf
    if [ -d /proc/sys/net/ipv6 ]; then
        echo "net.ipv6.conf.all.forwarding = 0" >> /etc/sysctl.d/99-nft-forward.conf
    fi
    sysctl -p /etc/sysctl.d/99-nft-forward.conf > /dev/null
    echo "IP 转发已关闭 "
else
    echo "保持当前的 IP 转发状态不变 "
fi

echo "==============================="
echo ""
echo "已删除端口转发规则"
echo "你可以通过 'nft list ruleset' 确认当前剩余规则 "
echo ""
echo "==============================="
