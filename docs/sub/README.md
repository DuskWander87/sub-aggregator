# sub-aggregator

给 3x-ui 加一层订阅聚合。在一台已经运行 3x-ui 的 Ubuntu 24.04 服务器上，为 Clash/Mihomo 与
原生客户端提供统一的 HTTPS 订阅入口。每条订阅只有一条地址，按 `User-Agent` 分流，见
[unified-subscription.md](unified-subscription.md)。

设计目标：

- 客户端只看到聚合地址，看不到 3x-ui 原始订阅 URL。
- 不使用第三方订阅转换、短链或配置托管服务。
- 不影响现有 3x-ui、Xray 和 443 端口。
- 适配只有 2GB 内存的服务器。

> 本组文档中的订阅路径和原始订阅 URL 都属于访问凭据。随机路径、UUID、`subId`、完整订阅
> URL 一律写作 `<随机路径>` 之类的占位符：**往文档里粘贴真实值等于泄露凭据**。

## 1. 文档索引

| 文档 | 内容 | 什么时候读 | 编辑规律 |
|---|---|---|---|
| [deploy.md](deploy.md) | 从零部署与卸载：前提、脚本、手动步骤、备份与回滚 | 第一次安装、重装或卸载 | 与 `tools/deploy.sh`、`tools/uninstall.sh` 同步 |
| [operations.md](operations.md) | 管理脚本、编号与轮换、检查与验证、备份范围 | 要动手做某件事 | 保持精简，不留历史 |
| [unified-subscription.md](unified-subscription.md) | 订阅入口：UA 分流规则、两个分支的输出、2096 收口 | 给设备配订阅、或要改分流规则 | §2 判定规则是**单一事实源** |
| [design.md](design.md) | 环境、选型、配置、安全模型、策略组 / DNS / 规则分发设计 | 要改系统，需要先知道为什么是现在这样 | 改服务器必须同步改 |
| [incidents.md](incidents.md) | 踩过的坑，按日期倒序 | 「这个症状以前见过吗」 | 只追加，不改旧条目 |

同目录之外还有 [`../3x-ui/troubleshooting.md`](../3x-ui/troubleshooting.md)，记录一次 3x-ui /
VLESS Reality 故障排查全过程，全文使用占位符，可公开分享。

## 2. 架构

每条订阅只有**一条地址**，一个 URL 按 `User-Agent` 同时服务两类客户端：

```text
任意客户端 -> HTTPS 订阅地址（Nginx :8443 /<48 位随机 hex>）
  -> Clash 家族 UA  -> 本机 Subconverter（127.0.0.1:25500）
                       -> 3x-ui 原生订阅（127.0.0.1:2096）
                       -> 返回完整 Clash YAML
  -> 其余一切       -> 原样透传 3x-ui 原生订阅（127.0.0.1:2096），一个字节都没动过
```

路径不带任何前缀，只有 48 位随机 hex，从 URL 结构看不出这是什么服务。分流规则、两个分支
各返回什么，见 [unified-subscription.md](unified-subscription.md)；为什么这样分、它带来的
可观察差异，见 [design.md](design.md) §2。

规则集分发是独立的第二条链路：

```text
git push -> sub-rules-sync.timer（每分钟）-> /var/lib/sub-rules/
  -> Nginx :8443 直接 serve -> Mihomo rule-provider
```

架构见 [design.md](design.md) §9，自维护规则为什么走本机发布见 §9.4；日常更新步骤见
[operations.md](operations.md) §2。

## 3. 速查

以下速查内容是**单一事实源**，其他文档只引用、不复写。改动本系统时先改这里。

### 3.1 端口

| 端口 | 服务 | 备注 |
|---|---|---|
| `80` | Nginx | 仅 ACME HTTP-01 挑战，其他路径 404 |
| `443` | Xray VLESS Reality | 不要碰 |
| `2096` | 3x-ui 原生订阅 | 仅 `127.0.0.1`；订阅入口原生分支的回源目标 |
| `8443` | Nginx | 订阅入口 + 自维护规则端点 |
| `25500` | Subconverter | 仅 `127.0.0.1` |

3x-ui 面板不占固定端口：端口和路径都由面板设置决定（`webPort` / `webBasePath`），用
`ss -lntp | grep x-ui` 或 `x-ui settings` 查当前值；随机路径不写进文档。

`2096` 来自面板的 `subPort` 设置（未设置时默认 2096），同样不是固定契约；改端口后同步更新
本表。

443 已由 Xray Reality 占用，因此订阅入口选择 `8443`，避免改动现有 Reality 入站或做复杂的
SNI/fallback 分流。代价是 Clash 客户端会显示 `sub.example.com:8443`，那是从订阅 URL 解析出
的服务器地址，不是订阅名称。

### 3.2 关键路径

真正生效的配置都不在本仓库：

```text
/usr/local/sbin/sub-manager             # 订阅管理脚本（0700，仅 root）
/usr/local/sbin/sub-rules-sync          # 规则同步：git → 发布目录（0700，仅 root）
/usr/local/sbin/sub-rules-check         # 规则集一致性诊断（0750，只读）
/etc/sub-manager/clients.json           # 订阅状态（0600，目录 0700）
/etc/nginx/conf.d/private-sub.conf      # 【脚本生成，勿手改】
/etc/nginx/conf.d/sub-rules-cache.conf  # proxy_cache_path 缓存区（仅兜底路径用）
/etc/nginx/conf.d/acme-challenge.conf   # 80 端口 ACME 挑战（server_name = 订阅域名）
/etc/nginx/snippets/sub-rules.conf      # 规则端点：本地文件优先 + GitHub 反代兜底
/etc/nginx/snippets/sub-rules-common.conf
/etc/nginx/snippets/sub-rules-upstream.conf
/etc/systemd/system/sub-rules-sync.{service,timer}
/etc/systemd/system/subconverter.service
/root/code/shadowrocket-config/         # 规则仓库 git 工作副本（0755，root）
/var/lib/sub-rules/                     # 发布目录，nginx 直接 serve（0755，文件 0644）
/opt/subconverter-classic/              # 转换后端（pref.ini / base/ / snippets/）
/root/cert/sub.example.com/             # Let's Encrypt 证书（acme.sh webroot 续期）
/var/www/acme/                          # ACME webroot（acme.sh 写入，Nginx 读取）
/etc/hosts                              # 订阅域名 → 127.0.0.1，供 subconverter 拉取原始订阅
/etc/x-ui/x-ui.db                       # 3x-ui 数据库
```

备份范围见 [operations.md](operations.md) §4。

### 3.3 转换参数 CONVERT_OPTS

Nginx 的 `proxy_pass` 和 `sub-manager` 的校验 URL 共用同一个脚本常量 `CONVERT_OPTS`，
避免两处各写一份造成漂移：

```text
http://127.0.0.1:25500/sub
  ?target=clash
  &url=<URL 编码后的 3x-ui 原始订阅>
  &emoji=true
  &list=false
  &udp=true
  &expand=false
  &rename=%5C%7C%F0%9F%93%8A.%2A%40
```

三个不显然的参数：

- `expand=false`：输出 Mihomo 原生 `RULE-SET` 引用而不是逐条内联规则，配置从 10000+ 行
  缩到 200 行以内。见 [design.md](design.md) §8。
- `rename=%5C%7C%F0%9F%93%8A.%2A%40`：解码后是 `\|📊.*@`，剥掉 3x-ui 追加在节点名末尾的
  `|📊<剩余流量>`。**节点名必须恒定**，否则 Mihomo 无法还原手动选择。见
  [incidents.md](incidents.md) `2026-08-11`。3x-ui 若改变备注格式（例如不再使用 `|📊`
  前缀），这条正则要同步调整；正则失效时 `sub-manager test` 会因节点名残留流量后缀而报错。
- `emoji=true`：拿节点备注去匹配 `snippets/emoji.txt` 的正则表（国家/城市
  关键词），命中就在名字前贴国旗。3x-ui 那边备注只写「美国」，输出成
  `🇺🇸 美国-<节点后缀>`，旗子是这张表自动加的。

`emoji=true` 有一条改不掉的行为：**贴国旗时固定插一个空格**（`旗子 + " " + 原名`）。这个
分隔符是 subconverter 二进制里的字面量，`[emojis]` 段只暴露 `add_emoji`、`remove_old_emoji`
和规则表三项，没有它的开关；表里写什么都落在空格左边，写空字符串只会让空格跑到最前。
`rename` 同样删不掉，它跑在贴国旗**之前**，那时空格还不存在（实测：`rename` 里写
`🇺🇸 @🇺🇸` 对输出没有任何影响）。因此节点名带这个空格，而策略组名不带；这个不一致是已知
的，权衡见 [design.md](design.md) §6.2。

改这些参数中的任何一个之后，都要跑 `sub-manager resync`。

### 3.4 订阅地址与显示名称

地址形态（每条订阅只有这一条）：

```text
https://sub.example.com:8443/<48 位随机 hex>#DuskWander
```

`sub-manager list` 直接输出带 fragment 的完整地址，整条粘进客户端即可。

客户端订阅卡片上显示的名称当前是 `DuskWander`。服务器侧只有一个命名来源，客户端侧另有一处：

| 取名方 | 名称来源 | 改哪里 |
|---|---|---|
| Clash 家族 | Nginx 的 `Content-Disposition` 响应头 | `sub-manager` 的常量 `PROFILE_NAME`，改完 `resync` |
| 3x-ui 原生分支 | Nginx 覆盖过的 `Profile-Title` 响应头（值带 `base64:` 前缀） | 同上，`resync` 后两个分支一起变 |
| Shadowrocket | **URL fragment `#DuskWander`**，服务器完全管不着 | 客户端里手工填，或粘贴 `list` 输出的完整地址 |

前两处都由 `PROFILE_NAME` 生成：Clash 分支的响应由 subconverter 拼装，原生分支则在 Nginx 层
把上游的 `Profile-Title` 覆盖掉，因此改一个常量跑一次 `resync` 即可。3x-ui 面板的「订阅标题」
不参与聚合入口的命名，留空也不影响：原生分支在 Nginx 层覆盖上游值，`2096` 又只监听回环，
面板值没有其他消费者，命名只有一个需要人维护的入口。`sub-manager test` 对两个响应头各有一条
断言，值不一致会报错。

Shadowrocket 那行是客户端行为，不是服务器缺陷。实测（`incidents.md` `2026-08-22`）
Shadowrocket 收到了 `Profile-Title` 却不采信，它的订阅名是本地备注字段，只有 URL fragment
能给初值。fragment 由客户端本地截断，**不会发给服务器**，因此既不影响分流也不进日志。

两个约束：

- `Content-Disposition` 同时写 `filename="..."` 与 `filename*=UTF-8''...`。RFC 6266 允许并存，
  新解析器优先取后者，只认前者的老解析器也不会落空。
- 名字**保持纯 ASCII**。`filename=` 那一份不做编码，非 ASCII 会失真；原生分支的
  `Profile-Title` 有 base64 保护，但两处要一致，所以按最严的那边来。

改名后跑 `sub-manager resync`，验证见 [operations.md](operations.md) §3.1。
