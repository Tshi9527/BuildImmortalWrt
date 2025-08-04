#!/bin/sh
# 99-custom.sh - ImmortalWrt首次启动运行脚本
# 作用：配置网络、防火墙、Docker防火墙规则，设置主机名映射，SSH与Web终端访问，修改固件描述等

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE

# 1. 设置默认防火墙规则，方便虚拟机首次访问 WebUI
uci set firewall.@zone[1].input='ACCEPT'

# 2. 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

# 3. 读取 pppoe-settings 配置文件（如果存在）
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >> $LOGFILE
else
    . "$SETTINGS_FILE"
fi

# 4. 计算物理网口数量及名称，筛选 eth 或 en 开头的接口
count=0
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        count=$((count + 1))
        ifnames="$ifnames $iface_name"
    fi
done
# 去除多余空格
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

# 5. 以第一个物理接口为 LAN，设置静态 IP 地址
main_iface=$(echo "$ifnames" | awk '{print $1}')
uci set network.lan.device="$main_iface"
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.50.5'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.50.1'
uci set network.lan.dns='192.168.50.1'
uci commit network

# 6. 配置 DHCP 服务
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci commit dhcp

# 7. 如果安装了 Docker，则配置对应的防火墙规则，扩大子网范围方便容器访问
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..." >> $LOGFILE

    # 删除原有名为 docker 的防火墙 zone
    uci delete firewall.docker 2>/dev/null

    # 删除所有涉及 docker zone 的 forwarding 规则
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall

    # 追加 docker zone 及转发配置
    cat <<EOF >> /etc/config/firewall

config zone 'docker'
  option name 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
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

    /etc/init.d/firewall reload
else
    echo "未检测到 Docker，跳过防火墙配置。" >> $LOGFILE
fi

# 8. 设置所有网口可访问网页终端（ttyd）
uci delete ttyd.@ttyd[0].interface
uci commit ttyd
/etc/init.d/ttyd restart

# 9. 设置所有网口可连接 SSH（dropbear）
uci set dropbear.@dropbear[0].Interface=''
uci commit dropbear
/etc/init.d/dropbear restart

# 10. 备份并修改固件描述信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
if [ -f "$FILE_PATH" ]; then
    cp "$FILE_PATH" "${FILE_PATH}.bak"
    sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"
fi

echo "99-custom.sh 脚本执行完成于 $(date)" >> $LOGFILE

exit 0
