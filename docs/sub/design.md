# 架构与设计决策

> 单一事实源在 [README.md](README.md) §3：端口、路径、`CONVERT_OPTS`。本文只引用，不复写。
>
> 本文回答「为什么是现在这样」。改服务器之后必须回写本文。改文档不会改变任何行为，改服务器
> 也不会自动更新文档。

## 1. 部署前环境

服务器环境：

- Ubuntu 24.04.4 LTS
- x86_64，2 核 CPU
- 物理内存约 1.9 GiB
- 无 Swap
- 根分区 19 GB，部署前剩余约 15 GB
- 域名：`sub.example.com`
- 证书：Let's Encrypt，覆盖 `sub.example.com`；acme.sh 通过 Nginx webroot（`/var/www/acme`）
  以 HTTP-01 签发和续期，证书落到 `/root/cert/sub.example.com/`

原有服务和端口：

| 服务 | 监听地址 | 用途 |
|---|---|---|
| Xray | `*:443` | VLESS Reality 入站 |
| 3x-ui 订阅 | `127.0.0.1:2096` | 原生客户端订阅，仅本机回源 |
| 3x-ui 面板 | `*:<面板端口>` | 管理面板，端口由面板设置（`webPort`）决定 |

由于 443 已由 Xray 占用，新的 HTTPS 订阅入口选择 `8443`，避免改动现有 Reality 入站或做复杂
的 SNI/fallback 分流。

## 2. 为什么是两条独立链路

链路图见 [README.md](README.md) §2。

两条链路完全独立。**只有 Clash 这条经过 subconverter 转换**，因此只有它受 `rename` 等转换
参数影响；原生订阅那条一个字节都没动过。这解释了一个容易被误认为 bug 的现象：Shadowrocket
的节点名带 `|📊<剩余流量>`，Clash 的不带，前者是 3x-ui 3.4.2 的默认备注格式，后者被
`rename` 剥掉了（原因见 [incidents.md](incidents.md) `2026-08-11`）。

### 2.1 一个地址自动识别客户端

同一个 URL 按 `User-Agent` 分流，见 [unified-subscription.md](unified-subscription.md)。

这套设计成立的关键是**失败方向是安全的**：UA 白名单没命中时返回**原生订阅**，也就是
Shadowrocket / V2rayN 本来就该拿到的内容，而不是一份格式不对的配置；再加 `?t=clash` /
`?t=raw` 作为强制覆盖。若识别失败会返回错误格式，这个方案就不该做。

§2 的「两条独立链路」合并在同一个 URL 之下，只是分流后的两个分支。`2096` 原生订阅只监听
`127.0.0.1`，公网只能经 `8443` 进入；本机 `/etc/hosts` 把订阅域名解析到回环地址，供
subconverter 拉取原始订阅。见 [unified-subscription.md](unified-subscription.md) §6。

## 3. 技术选型

### 3.1 不部署 sub-web-modify 页面

`sub-web-modify` 是 Vue 静态前端，不是转换后端。项目默认配置会调用作者维护的公网服务，例如：

- `api.v1.mk`
- `url.v1.mk`
- `v1.mk` 短链
- `subapi.v1.mk` 配置上传

转换请求会把原始订阅 URL 放入 `url` 参数。URL 编码和 Base64 都不是加密，第三方后端或短链
服务能够恢复并访问订阅。因此最终没有部署网页前端。

### 3.2 不部署 sub-web-api

配套 `sub-web-api` 长期未维护，包含匿名文件写入、自定义 JavaScript、数据库和共享配置修改等
能力，文档还建议扩大目录写权限。对于单用户私有订阅场景，它增加了不必要的攻击面和维护成本。

### 3.3 转换后端选型

当前使用：

```text
asdlokj1qpi233/subconverter v0.9.9
```

选用该 fork 的原因：

- 保留传统 Subconverter 的服务端拉取和完整转换行为。
- 支持当前订阅中的 VLESS/Reality 等新字段。
- 测试能输出 Mihomo 所需的 `reality-opts`、`flow`、SNI 和客户端指纹。
- 常驻内存约 2 MB。
- 真实订阅转换测试稳定通过。

`Aethersailor/SubConverter-Extended v1.3.0` 在这台 Ubuntu 服务器上有稳定性问题，不要再选它，
排查过程见 [incidents.md](incidents.md) `2026-08-08 部署期问题合集`。

### 3.4 反向代理选择

使用 Ubuntu 仓库中的 Nginx 1.24：

- 对外终止 TLS。
- 只开放一个不可猜测的精确路径。
- 将原始订阅 URL 固定在服务器配置中。
- 关闭该虚拟主机的访问日志。
- 隐藏转换后端，不公开 `25500`。

### 3.5 不用 Docker

服务器没有 Docker。考虑到只有 2GB 内存，且目标服务有官方/第三方 Linux 二进制，最终采用原生
二进制加 systemd：

- 避免安装 Docker daemon。
- 减少磁盘和内存占用。
- 不在服务器上进行 Node/Vue 或 C++ 镜像构建。

## 4. 安装和配置

### 4.1 转换后端目录

有效部署位于：

```text
/opt/subconverter-classic
```

主要文件：

```text
/opt/subconverter-classic/subconverter
/opt/subconverter-classic/pref.ini
/opt/subconverter-classic/base/
/opt/subconverter-classic/snippets/
```

当前关键配置：

```ini
api_mode=true
api_access_token=
listen=127.0.0.1
port=25500
log_level=warn
```

说明：

- `api_mode=true` 禁止传统 API 直接加载本地订阅或提供本地文件。
- 后端只监听回环地址，外部无法绕过 Nginx 访问。
- `api_access_token` 没有采用默认弱口令 `password`。
- 生产日志级别降低为 `warn`。

### 4.2 systemd 服务

服务文件：

```text
/etc/systemd/system/subconverter.service
```

服务使用以下加固项：

- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=true`
- 仅允许 `AF_UNIX`、`AF_INET` 和 `AF_INET6`
- 失败后自动重启
- 开机自动启动

常用命令：

```bash
systemctl status subconverter
systemctl restart subconverter
journalctl -u subconverter -n 100 --no-pager
curl http://127.0.0.1:25500/version
```

### 4.3 Nginx HTTPS 入口

配置文件：

```text
/etc/nginx/conf.d/private-sub.conf
```

关键设计：

- 监听 `8443`，不碰 Xray 的 `443`。
- 使用已有的 `sub.example.com` 证书。
- 仅启用 TLS 1.2 和 TLS 1.3。
- 使用 `location =` 精确匹配私有路径。
- 只允许 GET。
- 其他路径统一返回 404。
- `access_log off`，避免把私有路径写入 Nginx access log。
- `Cache-Control: no-store`，避免中间缓存保存订阅。
- `Referrer-Policy: no-referrer`。
- 返回 `Content-Disposition`，为 Clash 客户端提供订阅显示名称，见 [README.md](README.md) §3.4。

Nginx 内部固定调用本机 subconverter，参数见 [README.md](README.md) §3.3。同时对 subconverter
响应进行 `sub_filter` 后处理，为所有 `rule-providers` 注入 `format: text` 字段，确保 Mihomo
能正确解析纯文本格式的远程规则集（原因见 [incidents.md](incidents.md)
`2026-08-08 rule-providers 缺 format: text`）。

外部订阅地址格式为：

```text
https://sub.example.com:8443/<48 位随机 hex>
```

其中不包含原始订阅 URL，也不暴露 `target` 参数，且不带任何前缀：从 URL 结构看不出这是什么
服务。

Clash 客户端中显示的订阅名称由 Nginx 的 `Content-Disposition` 响应头提供；Subconverter 原始
响应头会被 `proxy_hide_header` 隐藏，避免默认的 `clash.yaml` 覆盖自定义名称。原生分支的
`Profile-Title` 同样由脚本生成并覆盖上游值，两个分支的名字因此只有一个来源。名称细节见
[README.md](README.md) §3.4，那里是单一事实源。

检查和加载配置：

```bash
nginx -t
systemctl reload nginx
```

### 4.4 生成的 location 长什么样

订阅一律由 `sub-manager` 管理（见 [operations.md](operations.md) §1），下面是脚本
`render_nginx()` 为单个订阅生成的 location 的等效逻辑，仅供理解参考：

```nginx
location = /<高熵随机值> {
    limit_except GET { deny all; }
    proxy_pass http://127.0.0.1:25500/sub?<CONVERT_OPTS>;
    proxy_set_header Host 127.0.0.1;

    # sub_filter 注入 format: text
    sub_filter_types *;
    sub_filter_once off;
    sub_filter "behavior: classical
    url:" "behavior: classical
    format: text
    url:";

    # 安全响应头
    add_header Cache-Control "no-store" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Content-Disposition '...' always;
    proxy_hide_header Content-Disposition;
}
```

`render_nginx()` 还会在 server 块中写入 `include /etc/nginx/snippets/sub-rules.conf;`，因此
`add` / `update` / `remove` / `resync` 重新生成配置时不会丢掉规则端点。

实际上 `render_nginx()` 为每个订阅生成的是三个 location（一个判定入口加两个 `internal`
承接），并在 server 块之外写入两个 `map`。上面那段是简化后的等效逻辑。真实结构与实现约束见
[unified-subscription.md](unified-subscription.md) §5，此处不复写。

随机路径生成：

```bash
openssl rand -hex 24
```

每个订阅一条随机路径，生成时全局查重。

## 5. 安全模型

当前方案通过以下措施降低订阅泄露风险：

1. 原始 3x-ui 订阅 URL 只保存在服务器 Nginx 配置中。
2. Clash 只得到随机私有路径。
3. 转换后端只监听 `127.0.0.1`，3x-ui 订阅服务也只监听 `127.0.0.1`。
4. 不使用第三方转换后端、短链或配置托管服务。自维护规则由本机发布目录
   `/var/lib/sub-rules/` 直接 serve，客户端不接触第三方（GitHub 反代仅在发布目录缺文件时
   作为兜底触发）；ACL4SSR 规则集仍通过 jsdelivr 公共 CDN 分发给客户端。
5. Nginx 对该虚拟主机关闭 access log。
6. 非精确路径统一返回 404。
7. 订阅响应禁止缓存。
8. 后端 API 模式开启。
9. 服务采用 systemd 沙箱限制。

仍需注意：

- Clash 私有 URL 本身就是凭据，获得它的人可以下载配置和节点。
- 原始 3x-ui 订阅 URL 仍保存在明文 Nginx 配置中，只有 root 应能读取该文件。
- `/etc/nginx/conf.d/private-sub.conf` 不得提交到公共 Git 仓库。
- 更换 3x-ui `subId` 后，必须执行 `sub-manager update <订阅编号>` 同步更新。
- 订阅 URL 泄露时，用 `sub-manager rotate <订阅编号>` 轮换随机路径，见
  [operations.md](operations.md) §1.5。

## 6. 单一策略组设计

### 6.1 为什么只有一个策略组

只保留一个 `🚀节点选择` 手动 select 组。默认模板会生成 10 个策略组（节点选择、自动选择、
国外媒体、国内媒体、微软、Telegram、Apple、全球直连、全球拦截、漏网之鱼），对仅有少量自建
节点的场景过于复杂。

### 6.2 当前策略组和规则映射

策略组（`snippets/groups.txt`）：

```text
🚀节点选择`select`.*`[]DIRECT
```

节点排在 `[]DIRECT` 之前是刻意的：万一将来节点名再次变化导致选择无法还原，兜底会落到节点而
不是直连。原因见 [incidents.md](incidents.md) `2026-08-11`。

规则映射见 §8 的 `snippets/rulesets.txt`。当前使用 `clash-classic:` 远程 URL 格式 +
`expand=false`，输出为 Mihomo 原生 RULE-SET 引用。所有非国内/非直连流量由最后的
`MATCH,🚀节点选择` 兜底走代理。

DIRECT 和 REJECT 是 Mihomo 内置出口，不会出现在策略组界面中。

组名 `🚀节点选择` 的 emoji 与中文之间**不留空格**。它是 `groups.txt` 里的字面量，改它要同步
三处：`groups.txt`、`rulesets.txt` 末行的 `[]FINAL` 目标、以及脚本断言 `  - name: 🚀节点选择`：
前两者的组名必须逐字节一致，否则 `MATCH` 指向一个不存在的策略组（断言清单见
[operations.md](operations.md) §3.2.1）。改组名会让 Mihomo 的 `store-selected` 失配一次，回落
到成员列表第一项；因为节点排在 `[]DIRECT` 之前，落点正是节点，客户端侧无感。

节点名 `🇺🇸 美国-<节点后缀>` 的空格则去不掉：它由 `emoji=true` 贴国旗时硬编码插入，细节见
[README.md](README.md) §3.3。两处风格不一致是权衡的结果：抹掉节点名那个空格要关掉
`emoji=true`，改用 `rename` 手工拼（`美国@🇺🇸美国` 这样一条一条写，多条用反引号分隔）。那
就丢掉 `snippets/emoji.txt` 那张正则表的自动覆盖：此后每加一个地区的节点都要补一条
rename 规则，漏了就没旗子。当前只有一个 inbound（备注「美国」），代价是一条规则；但风险落
在将来那个容易忘的动作上，所以保留 `emoji=true`，接受这个空格。

### 6.3 客户端效果

更新订阅后，Clash/Mihomo 客户端只显示一个 `🚀节点选择` 策略组，其中包含 DIRECT 和全部自建
节点。规则分流逻辑：

- 广告/追踪 → REJECT
- 局域网、Apple、中国域名/媒体/IP → DIRECT
- `GEOIP,CN`（仅对已有 IP 的连接生效）→ DIRECT
- 其余所有流量（国外网站、Telegram、流媒体、未匹配域名）→ MATCH 兜底走 `🚀节点选择`

没有为 Telegram、流媒体等设置独立规则集或策略组，统一由 MATCH 兜底走代理。

## 7. DNS 防泄漏设计

### 7.1 设计目标

参考用户 iOS Shadowrocket 配置的 DNS 设计原则，在 Mihomo 订阅中实现等效防泄漏：

- 禁用 IPv6 DNS 解析，避免绕行。
- 使用 Fake-IP 模式，减少实际 DNS 暴露。
- 国内域名由国内加密 DNS 解析（腾讯 DoH、阿里 DoH）。
- 国外域名由 Cloudflare/Google DoH 解析。
- 代理节点域名使用专用解析器，避免 DNS 循环依赖。
- TUN 模式劫持 UDP/TCP 53 端口，阻止应用绕过配置的 DNS。
- 启用 strict-route 阻止多网卡 DNS 泄漏（Windows/Linux）。

### 7.2 模板输出的 DNS 配置

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  respect-rules: true                  # 关键：nameserver 的 DoH 连接也走 rules 分流
  default-nameserver:                  # Bootstrap（明文 UDP，仅用于解析 DoH 域名）
    - 119.29.29.29
    - 223.5.5.5
    - 114.114.114.114
  nameserver-policy:                   # 国内/私有/Apple 域名用国内 DoH
    "geosite:cn,private,apple":
      - https://doh.pub/dns-query
      - https://dns.alidns.com/dns-query
  nameserver:                          # 其余域名用 1.1.1.1/8.8.8.8 DoH
    - https://1.1.1.1/dns-query        # 因 respect-rules，这些查询走代理节点发出
    - https://8.8.8.8/dns-query        # ISP 完全看不到境外 DNS 查询
  proxy-server-nameserver:             # 代理节点域名用国内 DoH（防 ISP 嗅探）
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  direct-nameserver:                   # 直连域名也用 DoH（不走系统 DNS）
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  direct-nameserver-follow-policy: true
  fake-ip-filter: [...]                # 31 条过滤规则
```

**防泄漏核心机制**：`respect-rules: true` 使 nameserver 中的 DoH 查询本身也按 Clash rules
分流。`1.1.1.1` 和 `8.8.8.8` 不匹配任何国内规则，因此这些 DNS 查询通过代理节点发出，本地
ISP 完全看不到任何境外域名的 DNS 请求。

### 7.3 TUN 配置

```yaml
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - "any:53"
    - "tcp://any:53"
```

### 7.4 客户端前提

- 客户端必须启用 TUN/增强代理模式，DNS 劫持和 strict-route 才能生效。
- Android 需关闭 Private DNS（设置 > 网络 > 私人 DNS > 关闭），否则系统 DNS over TLS 会绕过
  TUN 劫持。
- iOS 由 VPN Profile 自动处理 DNS 代理，通常不需额外配置。
- Windows 开启 strict-route 可能与 VirtualBox/Hyper-V 冲突。

### 7.5 Fake-IP 兼容性例外

`fake-ip-filter` 已排除的域名会使用真实 IP 解析：

- 局域网和本地主机名
- 连通性检测（captive portal、NCSI）
- NTP 时间同步
- STUN/WebRTC 服务
- 部分 Bilibili CDN

如遇到特定应用因 Fake-IP 异常，将其域名加入 `fake-ip-filter` 即可。

### 7.6 与 Shadowrocket 配置的对比

| Shadowrocket 能力 | Mihomo 等效 | 说明 |
|---|---|---|
| `dns-fallback-system = false` | TUN dns-hijack + strict-route | 系统 DNS 被拦截 |
| `dns-direct-system = false` | proxy-server-nameserver | 直连/代理都不走系统 DNS |
| `private-ip-answer = false` | 无直接等效 | Fake-IP 模式下不依赖真实 DNS 应答；geosite 分流降低风险 |
| `force-remote-dns` | enhanced-mode: fake-ip | 外部域名不在本地解析 |
| `udp-policy-not-supported-behaviour = REJECT` | 无直接字段 | Mihomo 原生支持 UDP 代理 |
| IPv6 关闭 | `ipv6: false`（全局和 DNS） | 一致 |

## 8. RULE-SET 规则集模式

通过 `expand=false` 参数 + `clash-classic:` 远程 URL 格式，输出为 Mihomo 原生 `RULE-SET` +
`rule-providers`，配置在 200 行以内。若不加 `expand=false`，subconverter 会把远程规则集展开
为逐条内联规则（DOMAIN-SUFFIX、IP-CIDR 等），配置会膨胀到 10000 行以上。

规则集配置（`snippets/rulesets.txt`）：

```text
REJECT,clash-classic:https://sub.example.com:8443/r/<随机前缀>/Reject.list,1800
DIRECT,clash-classic:https://sub.example.com:8443/r/<随机前缀>/ChinaDirect.list,1800
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/LocalAreaNetwork.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/UnBan.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/Apple.list,86400
REJECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/BanAD.list,86400
REJECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/BanProgramAD.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaDomain.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaMedia.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaCompanyIp.list,86400
DIRECT,clash-classic:https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaIp.list,86400
DIRECT,[]GEOIP,CN,no-resolve
🚀节点选择,[]FINAL
```

规则集来源：

| 来源 | 用途 |
|---|---|
| `DuskWander87/shadowrocket-config/rules/Reject.list` | 自维护广告/追踪拦截（本机发布目录，见 §9） |
| `DuskWander87/shadowrocket-config/rules/ChinaDirect.list` | ACL4SSR 未覆盖的国内域名补充（本机发布目录，见 §9） |
| `ACL4SSR/Clash/` 系列 | 局域网、解封、Apple、广告、中国域名/媒体/企业 IP/全量 IP（jsdelivr `@master`） |

与 Shadowrocket 配置共享同一套规则文件（`.list` 格式兼容），更新一处即可同步两端。

输出的 rules 段：

```yaml
rules:
  - RULE-SET,Reject,REJECT
  - RULE-SET,ChinaDirect,DIRECT
  - RULE-SET,LocalAreaNetwork,DIRECT
  - RULE-SET,UnBan,DIRECT
  - RULE-SET,Apple,DIRECT
  - RULE-SET,BanAD,REJECT
  - RULE-SET,BanProgramAD,REJECT
  - RULE-SET,ChinaDomain,DIRECT
  - RULE-SET,ChinaMedia,DIRECT
  - RULE-SET,ChinaCompanyIp,DIRECT
  - RULE-SET,ChinaIp,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,🚀节点选择
```

规则集中，`ChinaDirect` 和 `Reject` 两个自维护规则由本站 `8443` 从本机发布目录直接 serve
（GitHub 反代兜底），其余 9 个 ACL4SSR 规则集由客户端经 jsdelivr CDN 获取（分工见 §9.1）。
`interval` 为建议刷新周期，实际刷新时机取决于客户端实现，部分客户端需手动触发。

### 8.1 GEOIP 规则与 no-resolve

`GEOIP,CN,DIRECT,no-resolve` 的 `no-resolve` 参数确保：当流量只有域名（没有真实 IP）时，
不触发 DNS 解析来获取 IP 做 GEOIP 匹配，而是直接跳过该规则让 `MATCH` 兜底走代理。

这避免了以下潜在泄漏场景：某个国外域名不在前面任何 RULE-SET 中 → 走到 GEOIP 时若触发 DNS
解析 → 即使 `respect-rules` 生效由代理发出查询，也会增加不必要的延迟和复杂度。加
`no-resolve` 后，只有连接本身已携带 IP 地址（如应用直连 IP）时才检查是否为国内 IP。

未被 ChinaDomain 规则集覆盖的国内域名会走代理（极少数），代价是多绕一跳，但比 DNS 泄漏安全。

## 9. 规则分发架构

### 9.1 两类规则集的分工

| 规则集 | 来源 | 引用方式 | interval |
|---|---|---|---|
| 自维护 2 个（`ChinaDirect` / `Reject`） | 本机发布目录 `/var/lib/sub-rules/`（GitHub 反代兜底） | `https://sub.example.com:8443/r/<随机前缀>/*.list` | 1800 |
| ACL4SSR 9 个 | jsdelivr CDN | `cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/...` | 86400 |

客户端始终只连本站 `8443` 或 jsdelivr，**从不直连 `raw.githubusercontent.com`**（国内被墙）。

ACL4SSR 保持 jsdelivr：上游按天更新，不存在「改完想立刻生效」的诉求，无需自托管。

为什么自维护的两个必须由本机发布、不能直接写 GitHub 或 jsdelivr，见 §9.4。

### 9.2 实现结构

```text
/root/code/shadowrocket-config/            # git 工作副本（0755，root）
/var/lib/sub-rules/                      # 发布目录，nginx 直接 serve（0755，文件 0644）
  ├─ ChinaDirect.list
  ├─ Reject.list
  └─ .last-sync                            # 最后一次成功 fetch 的 unix 时间戳
/usr/local/sbin/sub-rules-sync           # 同步脚本（0700，仅 root）
/etc/systemd/system/sub-rules-sync.{service,timer}
/etc/nginx/snippets/sub-rules.conf          # 两个 location + 两个 @兜底命名 location
/etc/nginx/snippets/sub-rules-common.conf   # 两条路径共用的响应头
/etc/nginx/snippets/sub-rules-upstream.conf # 仅兜底路径使用的反代参数
/etc/nginx/conf.d/sub-rules-cache.conf      # http 上下文，proxy_cache_path 缓存区
```

`/root` 是 0700，www-data 穿不进去，所以 clone 目录不能直接给 nginx serve，必须由同步脚本
发布到 `/var/lib/sub-rules/`。

同步脚本的三条保守设计：

- 拉取用 `fetch` + `merge --ff-only`：工作副本有本地提交或未提交改动时**拒绝合并**而不是
  `reset --hard` 销毁。`/root/code/shadowrocket-config` 是可能被直接编辑的工作副本，不是只读
  镜像。此时 `sub-rules-check` 会报「同步已停滞」。
- 网络失败不致命：仍按工作副本内容发布，端点不会因 GitHub 抽风而降级。
- 先全部校验（非空 + 至少一条规则行）再全部发布，且经由临时文件 `mv`，避免发布出半套规则或
  被 nginx 读到写了一半的文件。

### 9.3 兜底路径的缓存：两条硬约束

发布目录正常时**根本走不到缓存**：nginx 直接 serve 本地文件，`X-Rule-Source: local`。
只有发布目录缺文件时才落到 `@sub_rules_*` 反代 GitHub，此时 `X-Rule-Source: github`。
兜底的意义是保证端点任何情况下都不 404：rule-provider 加载失败会让 Mihomo 的国内流量全部走
代理。`proxy_cache_use_stale` + `inactive=30d` 让 GitHub 不可达时仍有最后一份可用规则。

兜底路径上有两条**必须**遵守的约束（踩坑记录见 [incidents.md](incidents.md) `2026-08-19`）：

- **必须写 `proxy_ignore_headers Cache-Control Expires`。** 上游回
  `Cache-Control: max-age=300`，nginx 默认尊重上游指令并**完全覆盖** `proxy_cache_valid`。
  不写这行，配置里的 TTL 形同虚设。
- **禁止 `proxy_cache_background_update on`，禁止在 `proxy_cache_use_stale` 里写
  `updating`。** 该组合会让缓存过期后的第一个请求同步拿到陈旧副本、只在后台回源，而客户端
  「更新规则集」正是单次一次性拉取，于是必定拿到上一版规则。

缓存目录 `/var/cache/nginx/sub-rules` 必须属 `www-data`：`nginx -t` 会夺走它，见
[incidents.md](incidents.md) `2026-08-10 nginx -t 夺走缓存目录属主`。

### 9.4 为什么自维护规则由本机发布

订阅 profile 本身由本站 `8443` 生成并返回，不经过 GitHub 或 jsdelivr。但客户端「更新订阅」
不只下载 profile：Mihomo 加载配置时会初始化全部 `rule-providers`，任一规则表拉取失败，
这次配置加载就失败，客户端保留上一份配置。于是规则表的可达性也是订阅可靠性的一部分——
规则表拉不到的表现是「订阅更新失败」，不是「分流不准」。

这排除了两个候选来源：

- **`raw.githubusercontent.com`**：国内网络不可达。写进 `rule-providers` 等于让订阅更新
  依赖一个被墙的地址。
- **jsdelivr**：国内通常可达，但对**自维护**规则不满足「push 后尽快生效」。jsdelivr 对
  文件内容和「分支 → commit」的解析各有一层缓存，不同 POP 会分叉；固定 SHA 能绕开，
  但每次 push 都要改写 URL，还会在客户端 `providers/` 留下旧引用的孤儿文件（incidents
  `2026-08-10 jsdelivr 缓存不收敛，改为自托管`）。即使改用 GitHub 原生地址，Fastly
  边缘缓存也会让「拉得越勤的文件越旧」（incidents `2026-08-19 「更新规则集」拿到的永远
  是上一版`）。

本机发布同时满足三条：

1. 客户端只连本站 `8443`，国内可达，路径上没有境外地址；
2. 主路径无缓存层，nginx 直接读发布目录，读到即当前内容；push 到生效的上限 = 同步周期
   1 分钟；
3. URL 恒定（随机前缀 + 固定文件名），更新规则内容不需要改订阅。

不直接把 git 工作副本交给 nginx，原因有两个，且都与正确性有关：`/root` 是 0700，
www-data 穿不进去；`git fetch` 合并工作副本与 nginx 读文件并发时，可能读到半套规则。
发布目录用独立权限（0755 / 文件 0644）和临时文件 `mv` 解决这两点。

ACL4SSR 的 9 个规则集不跟着自托管，判据是「谁维护、多久更新一次、是否要求改完立刻生效」：
上游按天更新，客户端 `interval: 86400`，自托管换不来时效收益。如果实测 jsdelivr 在客户端
网络里不可用，正确做法是按同一结构把它们也纳入本地发布，而不是退回
`raw.githubusercontent.com`。

GitHub 反代只是兜底：仅当发布目录缺文件时由服务器侧回源，客户端始终只连 `8443`。缓存
约束见 §9.3。
