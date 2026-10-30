#!/bin/sh
# ==============================================================================
# OpenWrt / iStoreOS 旁路由短剧去广告一键部署脚本 (红果免费短剧 & 抖音短剧)
# 作用：
#   1. 配置 odhcpd 高优先级 RA (RFC 4191 pref high) 接管局域网 IPv6 流量
#   2. 防止单臂/同二层旁路由 eth0 学习自身 br-lan RA 导致 IPv6 环路
#   3. 配置防火墙阻断 IPv6 QUIC (UDP 443) 与私有广告端口 (8658, 8900, 9681)
#   4. 写入 Dnsmasq 与 OpenClash 全局 SNI 嗅探 + 短剧精准去广告规则
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[1/5] 配置旁路由 odhcpd 高优先级 IPv6 路由通告 (RFC 4191 High Preference)..."
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_preference='high'
uci set dhcp.lan.ra_default='2'
uci set dhcp.lan.ra_slaac='0'
uci set dhcp.lan.ra_maxinterval='30'
uci set dhcp.lan.ra_mininterval='10'
uci commit dhcp
/etc/init.d/odhcpd restart

echo "[2/5] 配置防环路 sysctl 参数 (禁止 eth0 接收同交换机 br-lan 广播的 RA)..."
if uci -q get network.wan6 >/dev/null; then
    uci set network.wan6.defaultroute='0'
    uci commit network
fi

for kv in \
    "net.ipv6.conf.eth0.accept_ra=0" \
    "net.ipv6.conf.all.send_redirects=0" \
    "net.ipv6.conf.default.send_redirects=0" \
    "net.ipv6.conf.br-lan.send_redirects=0"
do
    sysctl -w "$kv" >/dev/null 2>&1 || true
    grep -qF "$kv" /etc/sysctl.conf || echo "$kv" >> /etc/sysctl.conf
done

echo "[3/5] 配置防火墙阻断 IPv6 QUIC (UDP 443) 与私有广告端口..."
uci set firewall.block_v6_quic=rule
uci set firewall.block_v6_quic.name='Block-IPv6-QUIC-and-AdUDP'
uci set firewall.block_v6_quic.src='lan'
uci set firewall.block_v6_quic.dest='*'
uci set firewall.block_v6_quic.family='ipv6'
uci set firewall.block_v6_quic.proto='udp'
uci set firewall.block_v6_quic.dest_port='443 8658 8900 9681'
uci set firewall.block_v6_quic.target='REJECT'
uci commit firewall
/etc/init.d/firewall restart

echo "[4/5] 合并 Dnsmasq 短剧去广告配置..."
while IFS= read -r line; do
    case "$line" in
        ""|\#*) continue ;;
    esac
    grep -qF "$line" /etc/dnsmasq.conf || echo "$line" >> /etc/dnsmasq.conf
done < "$SCRIPT_DIR/config/dnsmasq-shortdrama-adblock.conf"
/etc/init.d/dnsmasq restart

echo "[5/5] 部署 OpenClash Sniffer 与自定义规则..."
if [ -d /etc/openclash/custom ]; then
    cp -f "$SCRIPT_DIR/config/openclash_custom_sniffer.yaml" /etc/openclash/custom/openclash_custom_sniffer.yaml
    uci set openclash.config.enable_custom_clash_rules='1'
    uci set openclash.config.ipv6_enable='1'
    uci commit openclash
    echo "请将 $SCRIPT_DIR/rules/openclash_custom_rules.list 中的规则合并至 /etc/openclash/custom/openclash_custom_rules.list 并重载 OpenClash。"
fi

echo "部署完成！请在手机端划掉抖音/红果短剧后台重新打开测试。"
