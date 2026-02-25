#!/bin/bash
set -e

# 清空当前可视区域并将光标移至左上角
printf '\033[2J\033[H'
echo "======== nftables 简单转发 ========"

# 1. Root 权限检查与自动提权
if [ "$EUID" -ne 0 ]; then
  # 重新使用 sudo 执行脚本，并传递所有参数
  exec sudo "$0" "$@"
  exit $?
fi

# 2. 系统及版本检测
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  VERSION_INFO=$VERSION_ID
else
  echo "未知操作系统，尝试通用方案"
  OS="unknown"
  VERSION_INFO=""
fi

echo "检测到系统: $OS $VERSION_INFO"

# 3. 自动安装 nftables
if ! command -v nft &> /dev/null; then
  echo "未检测到 nftables，开始安装..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update && apt-get install -y nftables
  elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum install -y nftables || dnf install -y nftables
  elif [[ "$OS" == "arch" ]]; then
    pacman -Sy --noconfirm nftables
  elif [[ "$OS" == "alpine" ]]; then
    apk add nftables
  else
    echo "当前系统不支持自动安装 nftables，请手动安装 "
    exit 1
  fi
  echo "nftables 安装成功"
else
  echo "检测到 nftables"
fi

# 4. 开启内核 IP 转发
echo "正在开启 IPv4/IPv6 转发..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-nft-forward.conf
if [ -d /proc/sys/net/ipv6 ]; then
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-nft-forward.conf
fi
sysctl -p /etc/sysctl.d/99-nft-forward.conf > /dev/null

# 5. 防火墙冲突检测处理
echo "检查防火墙..."
FW_HANDLED=0

# 处理 UFW (Ubuntu/Debian 常见)
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    echo "检测到 UFW 正在运行"
    # UFW 使用的也是 iptables/nftables，这里的 nft 独立表不一定被完全拦截，但为了保险，尝试放行本机端口
    echo "尝试放行入站端口..."
    # UFW 放行端口段语法是 port:port/protocol，和 iptables 不一样。真正的放行会在获取到输入后做，这里只记录环境
    FW_TYPE="ufw"
    FW_HANDLED=1
fi

# 处理 firewalld (CentOS/RHEL 常见)
if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    echo "检测到 firewalld 正在运行"
    FW_TYPE="firewalld"
    FW_HANDLED=1
fi

if [ "$FW_HANDLED" -eq 0 ]; then
    echo "未检测到防火墙 (UFW/firewalld) "
    FW_TYPE="none"
fi

# 检测本机 IPv6 支持情况以设定默认监听 IP
if [ -d /proc/sys/net/ipv6 ] && ip -6 addr | grep -q 'inet6'; then
    DEFAULT_LISTEN="::"
else
    DEFAULT_LISTEN="0.0.0.0"
fi

# 6. 用户交互
echo ""
MAX_RETRIES=3

for ((i=1; i<=MAX_RETRIES; i++)); do
    VALID_INPUT=1

    read -p "请输入本机监听 IP 地址 (回车默认监听 [$DEFAULT_LISTEN] ) " LOCAL_IP_RAW
    # 去除可能包含的空格、全角冒号等杂乱字符
    LOCAL_IP=$(echo "$LOCAL_IP_RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/：/:/g')
    
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="$DEFAULT_LISTEN"
    fi

    if [ "$LOCAL_IP" != "0.0.0.0" ] && [ "$LOCAL_IP" != "::" ]; then
        if [[ "$LOCAL_IP" == *":"* ]] && [ "$TARGET_FAMILY" == "ip" ]; then
            echo "目标是 IPv4，但监听却指定了 IPv6。无法跨协议转发。"
            VALID_INPUT=0
        elif [[ "$LOCAL_IP" == *"."* ]] && [ "$TARGET_FAMILY" == "ip6" ]; then
            echo "目标是 IPv6，但监听却指定了 IPv4。无法跨协议转发。"
            VALID_INPUT=0
        fi
        if [ "$TARGET_FAMILY" == "ip6" ]; then
            MATCH_DST="ip6 daddr $LOCAL_IP"
        else
            MATCH_DST="ip daddr $LOCAL_IP"
        fi
    else
        # 针对输入的是 0.0.0.0（隐式或显式）或是 :: 的情况
        if [ "$LOCAL_IP" == "::" ] && [ "$TARGET_FAMILY" == "ip" ]; then
            echo "目标是 IPv4，监听 :: 是 IPv6 通配符，无法跨协议转发。若要两端都是通配，请直接回车。"
            VALID_INPUT=0
        elif [ "$LOCAL_IP" == "0.0.0.0" ] && [ "$TARGET_FAMILY" == "ip6" ]; then
            echo "目标是 IPv6，监听 0.0.0.0 是 IPv4 通配符，无法跨协议转发。若要两端都是通配，请直接回车。"
            VALID_INPUT=0
        fi
        MATCH_DST=""
    fi

    read -p "请输入本机监听端口，用逗号分隔 (如: 100,200-300,114): " LOCAL_PORTS

    read -p "请输入转发目标的 IP 地址 (支持 IPv4 / IPv6): " TARGET_IP_RAW
    # 去除可能包含的回车符、制表符、各种全半角空格
    TARGET_IP=$(echo "$TARGET_IP_RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/　//g')
    
    if [[ "$TARGET_IP" == *":"* ]]; then
        TARGET_FAMILY="ip6"
        TARGET_PROTO="ipv6"
    else
        TARGET_FAMILY="ip"
        TARGET_PROTO="ipv4"
    fi

    read -p "请输入转发目标的端口 (回车默认与本机监听端口相同): " TARGET_PORTS_RAW
    TARGET_PORTS=$(echo "$TARGET_PORTS_RAW" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$TARGET_PORTS" ]; then
        TARGET_PORTS=$LOCAL_PORTS
    fi

    echo "请选择需要转发的协议 (回车默认 1):_"
    echo "1: tcp和udp"
    echo "2: tcp"
    echo "3: udp"
    # 这里用 awk 或 tput 把光标移回到第一行结尾，或者使用下面这种更跨平台的单行控制转义
    # \033[4A 是光标上移4行，\033[38C 往右移38列（紧跟在_后面）
    echo -ne "\033[4A\033[36C"
    read -p "" PROTO_CHOICE
    
    # 读完后由于输入内容跟选项块重叠，为了美观，输入完成后强制把光标丢回底部供下一次循环打印
    echo -ne "\033[4B"
    if [ -z "$PROTO_CHOICE" ] || [ "$PROTO_CHOICE" == "1" ]; then
        PROTO_LIST="tcp udp"
    elif [ "$PROTO_CHOICE" == "2" ]; then
        PROTO_LIST="tcp"
    elif [ "$PROTO_CHOICE" == "3" ]; then
        PROTO_LIST="udp"
    else
        echo "不支持的协议类型"
        VALID_INPUT=0
    fi

    # 处理逗号分隔的端口 -> nftables 集合格式 { 100-200, 444 }
    LOCAL_PORTS_CLEAN=$(echo "$LOCAL_PORTS" | sed 's/ //g')
    TARGET_PORTS_CLEAN=$(echo "$TARGET_PORTS" | sed 's/ //g')

    if [[ "$LOCAL_PORTS_CLEAN" == *","* ]]; then
        LOCAL_PORTS_NFT="{ $(echo "$LOCAL_PORTS_CLEAN" | sed 's/,/, /g') }"
    else
        LOCAL_PORTS_NFT="$LOCAL_PORTS_CLEAN"
    fi

    if [[ "$TARGET_PORTS_CLEAN" == *","* ]]; then
        TARGET_PORTS_NFT="{ $(echo "$TARGET_PORTS_CLEAN" | sed 's/,/, /g') }"
    else
        TARGET_PORTS_NFT="$TARGET_PORTS_CLEAN"
    fi

    if [ "$LOCAL_PORTS_CLEAN" == "$TARGET_PORTS_CLEAN" ]; then
        # 源和目标端口一致时，dnat 后不跟目标端口部分
        PORT_DNAT=""
    else
        if [[ "$TARGET_PORTS_CLEAN" == *","* ]] || [[ "$LOCAL_PORTS_CLEAN" == *","* ]]; then
            echo "将多段端口映射到另一组多段端口时可能因为顺序问题导致异常，建议多端口转发时，直接回车使端口一致"
        else
            PORT_DNAT=":$TARGET_PORTS_CLEAN"
        fi
    fi

    if [ "$VALID_INPUT" -eq 1 ]; then
        #如果标记为全部合法，则跳出循环继续执行
        break
    else
        if [ "$i" -lt "$MAX_RETRIES" ]; then
            echo "输入配置有误，请重新输入"
            echo "--------------------------------------------------------"
        else
            echo " $MAX_RETRIES 次输入不合法，退出脚本"
            exit 1
        fi
    fi
done

# 组装DNAT目标地址格式
if [ -n "$PORT_DNAT" ]; then
    if [ "$TARGET_FAMILY" == "ip6" ]; then
        DNAT_TARGET="[${TARGET_IP}]${PORT_DNAT}"
    else
        DNAT_TARGET="${TARGET_IP}${PORT_DNAT}"
    fi
else
    DNAT_TARGET="${TARGET_IP}"
fi

# 记录防火墙放行状态，供卸载脚本使用
FW_RECORD_FILE="/var/run/nft_forward_fw_record.txt"
> "$FW_RECORD_FILE"

# 根据防火墙类型放行入站端口
if [ "$FW_TYPE" == "ufw" ]; then
    echo "尝试放行本机监听端口: $LOCAL_PORTS ($PROTO_LIST)"
    IFS=',' read -ra PORT_ARRAY <<< "$LOCAL_PORTS_CLEAN"
    for p_item in "${PORT_ARRAY[@]}"; do
        for p in $PROTO_LIST; do
            UFW_PORT=$(echo "$p_item" | tr '-' ':')
            if ufw allow "$UFW_PORT/$p" >/dev/null; then
                 echo "ufw:$UFW_PORT/$p" >> "$FW_RECORD_FILE"
            else
                 echo "放行规则添加失败: $UFW_PORT/$p"
            fi
        done
    done
elif [ "$FW_TYPE" == "firewalld" ]; then
    echo "尝试放行本机监听端口: $LOCAL_PORTS ($PROTO_LIST)"
    IFS=',' read -ra PORT_ARRAY <<< "$LOCAL_PORTS_CLEAN"
    for p_item in "${PORT_ARRAY[@]}"; do
        for p in $PROTO_LIST; do
            firewall-cmd --add-port="$p_item/$p" --permanent >/dev/null 2>&1 || true
            firewall-cmd --add-port="$p_item/$p" >/dev/null 2>&1 || true
            echo "firewalld:$p_item/$p" >> "$FW_RECORD_FILE"
        done
    done
    echo "如果目标机器不可达，请确保 firewalld 开启了 masquerade"
fi

# 7. 配置nftables规则
TABLE_NAME="e2e_forwarding"

# 确保持续运行并自启
systemctl start nftables 2>/dev/null || true
systemctl enable nftables 2>/dev/null || true

# 如果不存在该表，则创建它（独立一个 inet 表用于同时满足 IPv4 和 IPv6，不干扰系统原有的表）
nft list table inet $TABLE_NAME &>/dev/null || {
    nft add table inet $TABLE_NAME
    # PREROUTING 用于目的地址转换 (DNAT)
    nft add chain inet $TABLE_NAME prerouting { type nat hook prerouting priority dstnat \; policy accept \; }
    # POSTROUTING 用于源地址转换 (SNAT/MASQUERADE)
    nft add chain inet $TABLE_NAME postrouting { type nat hook postrouting priority srcnat \; policy accept \; }
}

echo "正在应用 nftables 规则..."
for p in $PROTO_LIST; do
  # DNAT
  nft add rule inet $TABLE_NAME prerouting meta nfproto $TARGET_PROTO $MATCH_DST $p dport $LOCAL_PORTS_NFT dnat $TARGET_FAMILY to $DNAT_TARGET
  # MASQUERADE
  nft add rule inet $TABLE_NAME postrouting meta nfproto $TARGET_PROTO $TARGET_FAMILY daddr $TARGET_IP $p dport $TARGET_PORTS_NFT masquerade
done

# 8. 规则持久化
echo "保存规则中..."

SAVE_PATH=""
if [[ "$OS" == "ubuntu" || "$OS" == "debian" || "$OS" == "arch" || "$OS" == "alpine" ]]; then
    SAVE_PATH="/etc/nftables.conf"
elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    SAVE_PATH="/etc/sysconfig/nftables.conf"
    # 个别特定版本有可能是 /etc/nftables.conf
    if [ ! -d /etc/sysconfig ] && [ -d /etc/nftables.conf ]; then
        SAVE_PATH="/etc/nftables.conf"
    fi
else
    SAVE_PATH="/etc/nftables.conf"
fi

# 导出当前内存中的所有规则到对应的配置文件
nft list ruleset > "$SAVE_PATH"

echo ""
echo ""
echo "======================================================================="
echo "                            规则配置并持久化完成                          "
echo ""
if [ "$LOCAL_IP" == "0.0.0.0" ]; then
    DISPLAY_IP="所有 IPv4"
elif [ "$LOCAL_IP" == "::" ]; then
    DISPLAY_IP="所有 IPv6"
else
    DISPLAY_IP="$LOCAL_IP"
fi

DISPLAY_PROTO="$PROTO_LIST"
if [ "$PROTO_LIST" == "tcp udp" ]; then
    DISPLAY_PROTO="tcp和udp"
fi

echo "监听地址:           $DISPLAY_IP"
echo "监听端口:           $LOCAL_PORTS"
echo "目标地址及端口:      $TARGET_IP:$TARGET_PORTS"
echo "协议类型:           $DISPLAY_PROTO"
echo "规则已保存至:        $SAVE_PATH"
echo ""
echo "运行 'nft -a list table inet $TABLE_NAME'   查看添加的转发规则"
echo "运行 'nft flush table inet e2e_forwarding'  撤销添加的转发规则"
echo ""
echo "查看nftables运行状态     systemctl status nftables "
echo "查看完整规则集           nft list ruleset "
echo "查看系统日志             dmesg | tail 或 journalctl -u nftables.service "
echo "======================================================================="


