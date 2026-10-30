# OpenWrt / iStoreOS 旁路由短剧去广告终极方案 (红果短剧 & 抖音短剧)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: OpenWrt / iStoreOS](https://img.shields.io/badge/Platform-OpenWrt%20%7C%20iStoreOS-00B5E2)](https://github.com/nethao/openwrt-shortdrama-adblock)
[![Core: Mihomo (Clash.Meta)](https://img.shields.io/badge/Core-Mihomo%20(Clash.Meta)-success)](https://github.com/MetaCubeX/mihomo)

针对家庭局域网 **主路由（爱快 iKuai / ROS 等） + 旁路由（OpenWrt / iStoreOS + OpenClash）** 架构下，在 **红果免费短剧**、**抖音短剧**、**番茄免费小说** 中彻底拦截剧集解锁激励广告、插屏弹窗广告、小游戏试玩广告（Ohayoo / `dailygn.com`）及第三方买量落地页的网关级解决方案。

> **核心痛点解决**：为什么你在旁路由上加了去广告规则，手机刷红果/抖音短剧还是有广告？甚至在 OpenClash 面板里根本看不到手机刷抖音的连接？本仓库给出了完整的抓包复盘与四层防御配置。

---

## 目录

- [一、为什么常规去广告规则对红果/抖音短剧失效？](#一为什么常规去广告规则对红果抖音短剧失效)
- [二、四层拦截架构设计](#二四层拦截架构设计)
- [三、核心配置详解](#三核心配置详解)
  - [1. 旁路由 IPv6 高优先级 RA 接管（RFC 4191）](#1-旁路由-ipv6-高优先级-ra-接管rfc-4191)
  - [2. 防火墙阻断 IPv6 QUIC 与私有广告长连接端口](#2-防火墙阻断-ipv6-quic-与私有广告长连接端口)
  - [3. OpenClash 全局 TLS SNI 强制嗅探（破解共享 CDN IP 偷渡）](#3-openclash-全局-tls-sni-强制嗅探破解共享-cdn-ip-偷渡)
  - [4. 精准去广告规则集 + Dnsmasq 联合封锁](#4-精准去广告规则集--dnsmasq-联合封锁)
- [四、快速食用指南（支持 Clash Rule-Provider 订阅与一键脚本）](#四快速食用指南支持-clash-rule-provider-订阅与一键脚本)
- [五、拦截清单与放行边界说明](#五拦截清单与放行边界说明)
- [六、常见问题与边界说明](#六常见问题与边界说明)

---

## 一、为什么常规去广告规则对红果/抖音短剧失效？

在真实抓包排查（iPhone / Android 实测）中，字节系 App（抖音、红果免费短剧）以及第三方买量广告 SDK 具备极强的**防拦截与旁路穿透机制**，常规 DNS 广告屏蔽（AdGuard Home / MosDNS / 普通 Clash 规则）会因以下 **4 个原因** 被轻易绕过：

### 1. 旁路由架构下的 IPv6 二层直连逃逸（最隐蔽）
- 在 `主路由 + 旁路由` 拓扑中，DHCPv4 虽然把默认网关指向了旁路由，但 **IPv6 网关是由 ICMPv6 RA（路由通告）决定的**。
- 当主路由（或同二层交换机上的光猫）广播 IPv6 RA（默认优先级 `medium`）而旁路由未开启高优先级 RA 时，iPhone / Android 会直接把主路由当作 IPv6 默认网关。
- **后果**：手机刷抖音/红果时优先走 IPv6 协议栈，流量在交换机二层直接发给主路由出网，**100% 绕过旁路由**（在旁路由 OpenClash 里甚至看不到这台手机的抖音连接）。

### 2. 内置 HTTPDNS、无 SNI 加密私有通道与非标端口
- App 启动瞬间会并发请求字节自研 HTTPDNS（`tnc*-*.zijieapi.com`、`dig.bdurl.net`）以及写死在客户端内的 IP（如 `101.36.166.0/24`、`113.142.25.50/32`、IPv6 `240e:978:d04:2002::/64`）和阿里云无 SNI 私有加密通道（`8.134.241.67:443`）。
- 同时使用 **QUIC (`UDP 443`)** 以及私有长连接端口（**`TCP/UDP 8658`、`8900`、`9681`**）直接以純 IP 下发穿山甲广告配置，完全绕过本地 DNS（`53` 端口）和 DoH。

### 3. 共享 CDN 边缘 IP 导致 `redir-host` 域名缓存“张冠李戴”
- 字节跳动的边缘 CDN 节点（如 `113.142.204.x`、`203.2.166.x`）由正常业务域名（如 `lf26-dy-cdn-tos.bytegecko.com`、`*.bytedns1.com`）与广告域名（如小游戏试玩广告 `lf26-mgsdk-sign.dailygn.com`、线索广告 `lf-leads-fe-scm.bytecdn.com`、广告接口 `ads5-normal-hl.amemv.com`）**高度复用**。
- 在 OpenClash 的 `redir-host` 模式下，一旦某个共享 IP 先被正常域名解析过，缓存表就会将该 IP 绑定为 `host=lf26-dy-cdn-tos.bytegecko.com`。
- 如果 `sniffer.force-domain` 没有覆盖全局（`"+.*"`），后续发往该 IP 的广告连接即使 TLS 握手里的真实 `sniffHost` 是 `lf26-mgsdk-sign.dailygn.com`，内核也会拿着旧缓存的 `bytegecko.com` 去匹配规则，导致广告连接被当成正常 CDN 放行！

### 4. 短剧买量小游戏与第三方落地页热更新包
- 刷短剧时除了穿山甲（`pglstatp-toutiao.com` / `pangolin`）和北极星激励变现（`polaris*-normal-*.zijieapi.com`），还会高频加载字节小游戏试玩广告 SDK（`*-mgsdk-sign.dailygn.com`）及第三方买量热更新包（如 `down-updatekh06.hbttl.cn`、`quminglemei.com`、`daztoutiao.cn`、`yingt.fun` 等），单次预加载体积高达 3MB~5MB。

---

## 二、四层拦截架构设计

```mermaid
flowchart TD
    Phone["📱 局域网终端 (iPhone / Android)"]

    subgraph L1["第一层：二层/三层双栈流量强制接管 (odhcpd)"]
        RA["旁路由广播 RFC 4191 高优先级 RA (pref high)<br/>接管局域网全部 IPv6 默认网关与 RDNSS"]
    end

    subgraph L2["第二层：协议降级与防逃逸防火墙 (nftables / fw4)"]
        QUIC["阻断 IPv4/IPv6 UDP 443 (强制 QUIC 降级为 TCP TLS)"]
        Ports["阻断私有广告通道端口 TCP/UDP 8658, 8900, 9681"]
    end

    subgraph L3["第三层：DNS 净化层 (Dnsmasq)"]
        FilterRR["过滤 HTTPS (Type 65) / SVCB (Type 64) 记录防 ECH/H3"]
        Sinkhole["核心广告/HTTPDNS/买量域名直接解析为 0.0.0.0"]
    end

    subgraph L4["第四层：深度包检测与规则引擎 (OpenClash / Mihomo)"]
        Sniffer["TLS SNI 全局强制嗅探覆盖 (force-domain: +.*)<br/>破解共享 CDN IP 缓存污染"]
        Rules["精准正则 + 关键词 + 纯 IP/IPv6 CIDR 规则拦截 (REJECT)"]
        Direct["正常短剧视频流 (*.douyinvod.com / *.qznovelvod.com)<br/>与核心接口高速直连"]
    end

    Phone --> L1 --> L2
    L2 -->|DNS 请求| L3
    L2 -->|TCP/UDP 流量 (IPv4 & IPv6 TProxy)| L4
    L4 --> Direct
```

---

## 三、核心配置详解

### 1. 旁路由 IPv6 高优先级 RA 接管（RFC 4191）

无需篡改主路由或光猫，利用 **RFC 4191 (Default Router Preferences)** 标准，在旁路由的 `odhcpd` 上开启 `ra_preference='high'`（高优先级，高于主路由默认的 `medium`），局域网内所有手机会在 10 秒内自动将 IPv6 默认网关切换至旁路由：

```sh
# 在旁路由 (/etc/config/dhcp) 中配置高优先级 RA
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_preference='high'
uci set dhcp.lan.ra_default='2'
uci set dhcp.lan.ra_slaac='0'
uci set dhcp.lan.ra_maxinterval='30'
uci set dhcp.lan.ra_mininterval='10'
uci commit dhcp
/etc/init.d/odhcpd restart
```

> **⚠️ 防环路关键设置**：单臂旁路由或 `eth0` 与 `br-lan` 接在同一台二层交换机时，必须禁止 `eth0`（`wan6`）学习旁路由自己广播的 RA，防止产生 IPv6 路由环路（`reject loopback connection`）：
> ```sh
> uci set network.wan6.defaultroute='0'
> uci commit network
> sysctl -w net.ipv6.conf.eth0.accept_ra=0
> sysctl -w net.ipv6.conf.all.send_redirects=0
> sysctl -w net.ipv6.conf.br-lan.send_redirects=0
> ```

### 2. 防火墙阻断 IPv6 QUIC 与私有广告长连接端口

开启 OpenClash 的 IPv6 流量代理（`ipv6_enable='1'`）后，OpenClash 的 `openclash_mangle_v6` 默认使用 TProxy 接管 IPv6 TCP 流量。因此必须在防火墙 `forward` 链中拒绝 IPv6 `UDP 443`（QUIC）及私有端口，逼迫所有 IPv6 流量降级为 TCP 进入 OpenClash SNI 嗅探器：

```sh
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
```

### 3. OpenClash 全局 TLS SNI 强制嗅探（破解共享 CDN IP 偷渡）

在 `/etc/openclash/custom/openclash_custom_sniffer.yaml` 中，将 ` "+.*" ` 加入 `force-domain`（同时保留推送通知等 `skip-domain`）。这样无论连接是走 IPv4 还是 IPv6、无论客户端是否通过 DoH 绕过本地 DNS、无论目标 IP 是否被其他正常域名缓存污染，Mihomo 都会**强制使用 TLS ClientHello 中的真实 SNI (`sniffHost`)** 匹配分流规则：

```yaml
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    QUIC:
      ports: [443]
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080-8880]
      override-destination: false
  force-domain:
    - "+.*"
  skip-domain:
    - "Mijia Cloud"
    - "dlg.io.mi.com"
    - "+.oray.com"
    - "+.sunlogin.net"
    - "+.push.apple.com"
```

### 4. 精准去广告规则集 + Dnsmasq 联合封锁

完整规则详见本仓库：
- Clash Rule-Provider 格式：[`rules/shortdrama-adblock.yaml`](rules/shortdrama-adblock.yaml)
- OpenClash 自定义规则格式：[`rules/openclash_custom_rules.list`](rules/openclash_custom_rules.list)
- Dnsmasq 配置文件：[`config/dnsmasq-shortdrama-adblock.conf`](config/dnsmasq-shortdrama-adblock.conf)

---

## 四、快速食用指南（支持 Clash Rule-Provider 订阅与一键脚本）

### 方式 A：在任何 Mihomo / OpenClash / Stash / Surge 中作为 Rule-Provider 引用（推荐）

在你的 Clash / Mihomo 配置文件中添加 `rule-providers` 与 `rules`：

```yaml
rule-providers:
  shortdrama_adblock:
    type: http
    behavior: classical
    format: yaml
    interval: 86400
    url: "https://raw.githubusercontent.com/nethao/openwrt-shortdrama-adblock/main/rules/shortdrama-adblock.yaml"
    path: ./ruleset/shortdrama_adblock.yaml

rules:
  - RULE-SET,shortdrama_adblock,REJECT
```

> **提示**：请务必同时确保你的 Mihomo 配置开启了 `sniffer` 且 `force-domain` 包含 `"+.*"`（参考 [`config/openclash_custom_sniffer.yaml`](config/openclash_custom_sniffer.yaml)）。

### 方式 B：OpenWrt / iStoreOS 旁路由一键部署脚本

SSH 登录旁路由后执行：

```sh
git clone https://github.com/nethao/openwrt-shortdrama-adblock.git
cd openwrt-shortdrama-adblock
sh scripts/setup-side-router-ipv6-and-adblock.sh
```

---

## 五、拦截清单与放行边界说明

本方案经过真实流量逐条比对，严格区分**广告/商业化/归因组件**与**正常短剧播放/推荐流接口**：

| 模块类别 | 匹配规则 / 域名特征 | 动作 | 说明 |
| :--- | :--- | :---: | :--- |
| **红果/抖音核心广告下发** | `^ads[0-9]*-normal.*\.(zijieapi\|snssdk\|fqnovel\|amemv)\.com(\..*)?$` | `REJECT` | 拦截激励视频广告、剧集解锁广告、插屏广告请求（兼容 CNAME 后缀） |
| **北极星激励变现组件** | `^polaris[0-9]*-.*\.(zijieapi\|snssdk\|fqnovel\|amemv)\.com(\..*)?$` | `REJECT` | 拦截 `polaris5-normal-zb.zijieapi.com` 等短剧宝箱/看广告领金币组件 |
| **穿山甲 / 字节商业化** | `pglstatp-toutiao`、`pangolin*`、`pangle*`、`ctobsnssdk`、`bytead*` | `REJECT` | 拦截穿山甲广告 SDK 物料与配置拉取 |
| **抖音短剧小游戏试玩广告** | `dailygn.com`、`KEYWORD: mgsdk`、`hbttl.cn`、`KEYWORD: down-update` | `REJECT` | 拦截短剧剧集间插播的 2.7MB~4.8MB 字节小游戏试玩广告与买量热更新包 |
| **商业化线索与电商画像** | `KEYWORD: leads-fe`、`ecomuser.snssdk.com`、`^klink[0-9]*-.*`、`byteurl.cn` | `REJECT` | 拦截 `lf-leads-fe-scm.bytecdn.com` 线索广告前端、广告画像与点击归因跳转 |
| **第三方短剧买量落地页** | `quminglemei.com`、`daztoutiao.cn`、`zttapk.bscgslb.com`、`yingt.fun`、`qiezibenpao.com`、`tianwenca.com` | `REJECT` | 拦截短剧内嵌第三方微短剧/小游戏买量推广 SDK 与 APK 下载源 |
| **内置 HTTPDNS 与私有通道** | `^tnc[0-9]*-.*`、`dig.bdurl.net`、`httpdns.volcengineapi.com`、`101.36.166.0/24`、`113.142.25.50/32`、`8.134.241.67/32`、`240e:978:d04:2002::/64` | `REJECT` | 彻底封死内置 HTTPDNS、无 SNI 阿里云私有通道及 IPv6 HTTPDNS |
| **私有长连接与 QUIC 端口** | `UDP 443`、`TCP/UDP 8658, 8900, 9681` | `REJECT` | 阻断 QUIC 及 Frontier 私有二进制广告推送长连接 |
| **广告计费回传与监控上报** | `^(rt)?log[0-9]*-.*`、`^logbk\..*`、`^.*mon.*`、`toutiaocloud.com/.net`、`aweme-saveu` | `REJECT` | 拦截广告曝光计费回传、应用日志与性能遥测 |
| **红果短剧正常视频与接口** | `*.qznovelvod.com`、`api*-normal-*.fqnovel.com`、`reading*-normal-*.fqnovel.com` | `DIRECT` | **完全放行**：红果短剧剧集播放、选集、书架与搜索正常可用 |
| **抖音正常视频与短剧剧集** | `*.douyinvod.com` (`*-dyseries.douyinvod.com`)、`*.idouyinvod.com`、`api*-normal-*.amemv.com`、`api-play*.amemv.com` | `DIRECT` | **完全放行**：抖音原生短剧播放器、普通短视频流、评论与直播正常可用 |

---

## 六、常见问题与边界说明

1. **配置完成后需要重启手机 App 吗？**
   - 需要。请在手机上**划掉红果短剧 / 抖音后台重新打开**（或开关一次飞行模式以刷新本地 DNS 缓存与已建立的复用长连接）。
2. **关于抖音首页“推荐”信息流里的原生带货/投流视频**：
   - **可以100%拦截的广告**：红果短剧全部广告、抖音短剧剧集内的看广告解锁、弹窗插屏广告、小游戏试玩加载包（`dailygn.com` / `hbttl.cn`）、线索表单卡片（`leads-fe`）及第三方买量落地页。
   - **网关层的物理边界**：如果你在抖音首页“推荐”流上下滑动时，刷到带有“广告”角标的原生投流短视频，由于该视频的 JSON 元数据直接内嵌在加密的 `/aweme/v1/feed/` 核心接口响应体内，且视频流同样存放在 `*.douyinvod.com` 上，在不破除手机 HTTPS 证书（MitM 中间人解密）的前提下，任何路由器网关都无法单独剥离单条原生信息流视频（若强行拦截会导致正常抖音视频也无法刷出），但该视频附带的**小游戏试玩包、线索表单组件与追踪上报**均已被本方案拦截。

---

## License

[MIT License](LICENSE)
