#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh for AP Mode at $(date)" >>$LOGFILE

# -------------------------------------------------------------------
# AP 模式 (交换机/旁路由) 配置核心修改
# -------------------------------------------------------------------

# 1. 禁用 DHCP 服务
# AP 模式下，子路由不应分配 IP 地址，由主路由统一管理。
# 因此，禁用 dnsmasq (DHCP 服务)。
# -------------------------------------------------------------------
echo "Disabling DHCP server (dnsmasq)..." >>$LOGFILE
uci set dhcp.lan.ignore=1

# 2. 配置静态 LAN 口
# 设置子路由自身的静态 IP 地址、子网掩码、网关和 DNS。
# -------------------------------------------------------------------
echo "Configuring static LAN interface..." >>$LOGFILE
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.100.5' # <-- 子路由静态 IP 地址
uci set network.lan.netmask='255.255.255.0' # <-- 子网掩码
uci set network.lan.gateway='192.168.100.1' # <-- 主路由 IP 地址 (网关)
uci set network.lan.dns='192.168.100.1'     # <-- 主路由 IP 地址 (DNS)

# 3. 禁用 WAN 和 WAN6 接口
# AP 模式下，所有端口都作为 LAN 口使用，不需要独立的 WAN 口配置。
# -------------------------------------------------------------------
echo "Deleting WAN and WAN6 interfaces..." >>$LOGFILE
uci -q delete network.wan
uci -q delete network.wan6

# 4. 将所有物理网口桥接到 br-lan
# 确保所有物理网口都成为 LAN 的一部分，实现交换机功能。
# -------------------------------------------------------------------
echo "Bridging all physical interfaces to LAN..." >>$LOGFILE
# 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')
echo "Detected physical interfaces: $ifnames" >>$LOGFILE

# 查找 br-lan 设备 section
section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
if [ -z "$section" ]; then
    echo "error：cannot find device 'br-lan'." >>$LOGFILE
else
    # 删除原有 ports
    uci -q delete "network.$section.ports"
    # 添加所有物理网口到 br-lan
    for port in $ifnames; do
        uci add_list "network.$section.ports"="$port"
    done
    echo "Updated br-lan ports with all physical interfaces: $ifnames" >>$LOGFILE
fi

# 提交所有网络相关的更改
uci commit network

# -------------------------------------------------------------------
# 以下为原始脚本中与 AP 模式无关或需要注释掉的部分
# -------------------------------------------------------------------

# 注释掉: 防火墙 WAN 口设置。AP 模式下 WAN 口已禁用，此规则无效。
# uci set firewall.@zone[1].input='ACCEPT'

# 注释掉: DHCP 相关的主机名映射。AP 模式下 DHCP 服务已禁用。
# uci add dhcp domain
# uci set "dhcp.@domain[-1].name=time.android.com"
# uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 注释掉: PPPoE 相关设置。AP 模式下不使用 PPPoE 拨号。
# SETTINGS_FILE="/etc/config/pppoe-settings"
# if [ ! -f "$SETTINGS_FILE" ]; then
#     echo "PPPoE settings file not found. Skipping." >>$LOGFILE
# else
#     . "$SETTINGS_FILE"
# fi
# ... (以及后续所有与 PPPoE 相关的 if 判断和 uci set 命令)

# -------------------------------------------------------------------
# 以下为原始脚本中可以保留的通用设置
# -------------------------------------------------------------------

# 若安装了 dockerd 则设置 docker 的防火墙规则
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..." >>$LOGFILE
    FW_FILE="/etc/config/firewall"
    uci delete firewall.docker
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall
    cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF
fi

# 提交防火墙更改
uci commit firewall

# 设置所有网口可访问网页终端
uci -q delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''

# 提交 ttyd 和 dropbear 的更改
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION=\'[^\']*\'/DISTRIB_DESCRIPTION=\'$NEW_DESCRIPTION\'/' "$FILE_PATH"

# 若 luci-app-advancedplus (进阶设置)已安装 则去除 zsh 的调用
if opkg list-installed | grep -q '^luci-app-advancedplus ' >/dev/null 2>&1; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

echo "Finished 99-custom.sh for AP Mode at $(date)" >>$LOGFILE

exit 0
