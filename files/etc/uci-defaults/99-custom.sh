#!/bin/sh
# 99-custom.sh - ImmortalWrt 首次启动运行脚本
# 功能：配置网络、防火墙、Docker规则、主机名映射、终端访问、固件描述等

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE

# 1. 设置默认防火墙规则，便于首次访问 WebUI
uci set firewall.@zone[1].input='ACCEPT'

# 2. 设置主机名映射，解决 Android TV 无法联网
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"
uci commit dhcp

# 3. 加载 PPPoE 配置（如存在）
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >> $LOGFILE
else
    . "$SETTINGS_FILE"
fi

# 4. 查找物理网口 (eth 或 en 开头)
count=0
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        count=$((count + 1))
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')  # 去除多余空格

# 5. 设置 LAN 网口和静态 IP
main_iface=$(echo "$ifnames" | awk '{print $1}')
uci set network.lan.device="$main_iface"
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.50.5'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.50.1'
uci set network.lan.dns='192.168.50.1'

# 6. 配置 DHCP 服务
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'

# 执行 commit
uci commit network
uci commit dhcp

# 7. Docker 防火墙配置
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，配置防火墙规则..." >> $LOGFILE

    # 删除名为 docker 的 zone
    for idx in $(uci show firewall | grep "=zone" | sed -n 's/.*@\([0-9]*\).*/\1/p' | sort -rn); do
        name=$(uci get firewall.@zone[$idx].name 2>/dev/null)
        if [ "$name" = "docker" ]; then
            uci delete firewall.@zone[$idx]
        fi
    done

    # 删除所有指向 docker 的 forwarding 规则
    for idx in $(uci show firewall | grep "=forwarding" | sed -n 's/.*@\([0-9]*\).*/\1/p' | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done

    uci commit firewall

    # 添加 docker zone 配置
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
    echo "未检测到 Docker，跳过 Docker 防火墙配置。" >> $LOGFILE
fi

# 8. 开启所有接口访问网页终端 ttyd
if uci get ttyd.@ttyd[0] >/dev/null 2>&1; then
    uci delete ttyd.@ttyd[0].interface
    uci commit ttyd
    /etc/init.d/ttyd restart
fi

# 9. 开启所有接口访问 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit dropbear
/etc/init.d/dropbear restart

# 10. 修改固件描述
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by Rodger"
if [ -f "$FILE_PATH" ]; then
    cp "$FILE_PATH" "${FILE_PATH}.bak"
    if grep -q "DISTRIB_DESCRIPTION=" "$FILE_PATH"; then
        sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"
    else
        echo "DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'" >> "$FILE_PATH"
    fi
fi

echo "99-custom.sh 脚本执行完成于 $(date)" >> $LOGFILE
exit 0
