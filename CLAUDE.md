# CLAUDE.md

## 这是什么

这个仓库是一套运行中服务的运维文档和脱敏配置副本。服务装在这台 Ubuntu 24.04 服务器上：
3x-ui（VLESS Reality 节点 + 面板）和订阅聚合服务 sub-aggregator。仓库里的 `server/` 和
`docs/` 不参与运行，真正生效的是本机对应路径（见下文）。

因此它的用法和普通代码仓库相反：

> **改文档不会改变任何行为；改服务器不会自动更新文档。**
> 两边只能手工同步：服务器上做了什么变更，就回写到对应文档。

## 文档索引

sub-aggregator 的文档按**阅读时机**而非章节顺序组织：

| 文档 | 内容 | 什么时候读 | 编辑规律 |
|---|---|---|---|
| `docs/sub/README.md` | 索引、架构、端口/路径/`CONVERT_OPTS` 速查 | 找入口、查常量 | §3 是**单一事实源** |
| `docs/sub/deploy.md` | 从零部署：前提、脚本、手动步骤、备份与回滚 | 第一次安装或重装 | 与 `tools/deploy.sh` 和 skill 保持同步 |
| `docs/sub/operations.md` | 管理脚本、编号与轮换、检查与验证、备份范围 | 要动手做某件事 | 保持精简 |
| `docs/sub/unified-subscription.md` | 订阅入口：UA 分流规则、两个分支的输出、2096 收口 | 给设备配订阅、要改分流规则 | §2 判定规则是**单一事实源** |
| `docs/sub/design.md` | 环境、选型、配置、安全模型、策略组 / DNS / 规则分发设计 | 要改系统，需先知道为什么是现在这样 | 改服务器必须同步改 |
| `docs/sub/incidents.md` | 踩过的坑，按日期倒序 | 「这个症状以前见过吗」 | 只追加，不改旧条目 |
| `docs/3x-ui/troubleshooting.md` | 一次真实的 3x-ui / VLESS Reality 故障排查全过程 | 节点不通时 | 归档案例，一般不再改动 |

**不要把同一个事实写进两份文档。** 端口、路径、转换参数只在 `sub/README.md` §3 定义，
其余位置一律引用。这条规则是有来历的：`rename` 参数曾同时存在于四处，2026-08-19 改动规则
分发时只更新了其中一处，另外三处静默过期。

**只写现状，不写沿革。** 两份归档文档（`incidents.md`、`3x-ui/troubleshooting.md`）之外，
所有文档只描述系统**现在**是什么样：不写「在此之前」「原本」「已于 X 退役」「旧结论 /
现结论」，标题不带日期戳，不保留已删除命令和已弃用组件的安装细节。要解释「为什么是现在
这样」，用现在时直接给理由，不要叙述改动过程。规则本身的来历可以写——它是规则的证据；
系统的旧状态不写。

历史只有一个去处：`docs/sub/incidents.md`，按日期倒序追加。其余文档需要「为什么」时引用
它的条目标题，如「原因见 incidents.md `2026-08-22 读 x-ui.db 偶发返回空`」。这样文档不会
随时间变长，而排查要的完整链路一条都不少。

删不删的判断：**这句话去掉之后，读者还能不能正确操作现在这套系统？** 能，就删。

两类文档的脱敏约定不同，不要混淆：

- **troubleshooting** 全文使用占位符（`panel.example.com`、`203.0.113.10`、
  `/RANDOM_PANEL_PATH/`），可以公开分享。
- **sub/** 用 `sub.example.com` 代表真实订阅域名，端口是真实值；随机订阅路径、UUID、
  `subId`、原始订阅 URL、节点后缀一律写作 `<随机路径>` 之类的占位符。**继续保持这一点**——
  往文档里粘贴真实随机路径等于泄露凭据。

## 系统实际位置

真正生效的配置都不在本仓库，而在以下路径（编辑前务必先读）。此表与
`docs/sub/README.md` §3.2 是同一份清单，改一处必须同步另一处：

```text
/usr/local/sbin/sub-manager             # 订阅管理脚本（0700，仅 root）
/usr/local/sbin/sub-rules-sync          # 规则同步：git → 发布目录（0700，仅 root）
/usr/local/sbin/sub-rules-check         # 规则集一致性诊断（0750，只读）
/etc/sub-manager/clients.json           # 订阅状态（0600，目录 0700）
/etc/nginx/conf.d/private-sub.conf      # 【脚本生成，勿手改】
/etc/nginx/conf.d/sub-rules-cache.conf  # proxy_cache_path 缓存区（仅兜底路径用）
/etc/nginx/snippets/sub-rules.conf      # 规则端点：本地文件优先 + GitHub 反代兜底
/etc/nginx/snippets/sub-rules-common.conf
/etc/nginx/snippets/sub-rules-upstream.conf
/etc/systemd/system/sub-rules-sync.{service,timer}
/etc/systemd/system/subconverter.service
/root/code/shadowrocket-config/         # 规则仓库 git 工作副本（0755，root）
/var/lib/sub-rules/                     # 发布目录，nginx 直接 serve（0755，文件 0644）
/opt/subconverter-classic/              # 转换后端（pref.ini / base/ / snippets/）
/root/cert/sub.example.com/             # Let's Encrypt 证书
/etc/hosts                              # 订阅域名 → 127.0.0.1，供 subconverter 拉取原始订阅
/etc/x-ui/x-ui.db                       # 3x-ui 数据库
```

端口分工（当前实际监听，勿冲突）。此表与 `docs/sub/README.md` §3.1 是同一份清单，改一处
必须同步另一处：

| 端口 | 服务 |
|---|---|
| `443` | Xray VLESS Reality（**不要碰**） |
| `2096` | 3x-ui 原生订阅（仅 `127.0.0.1`；订阅入口原生分支的回源目标） |
| `35006` | 3x-ui 面板（HTTPS + 随机 Web Base Path） |
| `8443` | Nginx（订阅入口 + 自维护规则端点） |
| `25500` | Subconverter（**仅 `127.0.0.1`**） |

## `server/` 公开镜像

`server/` 是把本机四类配置（`sbin/`、`nginx/`、`subconverter/`、`systemd/`）收进仓库的**脱敏
拷贝**，与 `docs/` 一起对外发布。CLAUDE.md 也随仓库版本化，因此本文件同样遵守脱敏规则：
不写真实域名、订阅路径与客户端名。改真机对应文件时同步 `server/` 的同名文件，并把真实值换回
占位符：真实域名 → `sub.example.com`、规则前缀 24 位 hex → `<RULES_PREFIX>`、证书路径 →
`/root/cert/sub.example.com/`。
`PROFILE_NAME=DuskWander` 与 Nginx 兜底的 `DuskWander87/shadowrocket-config` 是作者实际值，
原样保留（与公开 docs 对齐）。`pref.ini` 活跃引用的自维护 snippet（`groups.txt`、`rulesets.txt`、
`emoji.txt`、`rename_node.txt`）必须一起镜像，否则公开副本不自洽。

## 关键操作

首次部署走 `tools/deploy.sh`，先 `--dry-run` 看计划，再执行。它只负责安装，日常订阅管理仍走
`sub-manager`：

```bash
tools/deploy.sh --dry-run       # 预览首次部署（仓库工具，不装到真机）
```

订阅管理一律走脚本，不要手工编辑它生成的 Nginx 配置：

```bash
sub-manager list                # 查看（脱敏显示，带客户端名与漂移报告）
sub-manager add --from-xui      # 从 3x-ui 客户端列表里挑一个建订阅，地址由 subId 推导
sub-manager add                 # 新增，隐藏输入原始订阅（源不在本机 3x-ui 时用）
sub-manager update sub-1        # 原始订阅 subId 变更后同步，地址不变
sub-manager rotate sub-1        # 换随机路径（--all 换全部），编号与原始订阅不变
sub-manager remove sub-1        # 撤销；编号只增不复用，删除留下空号
sub-manager renumber 101        # 重排编号，订阅地址与设备配置不变
sub-manager resync              # 改了模板/转换参数后重建配置
sub-manager test                # 端到端验证全部订阅（四发 UA 断言）
sub-rules-check                     # 端点 = 发布目录 = git 副本 = origin，并查同步器
sub-rules-sync                      # 手工同步一次（push 后想跳过 1 分钟等待时用）
```

`list` 会只读查 `/etc/x-ui/x-ui.db`，显示每条订阅属于哪个面板客户端，并报告双向漂移
（x-ui 有客户端却无地址 / 地址已无对应客户端）。**面板增删客户端不会自动改动聚合地址**，
触发权在人手上；不做定时器同步是刻意的，理由见 `docs/sub/operations.md` §1.8。

每个订阅只有**一条地址**，形如 `https://sub.example.com:8443/<48 位随机 hex>#<订阅名>`：
路径不带前缀，按 UA 分流，Clash 与原生客户端通用，`?t=clash` / `?t=raw` 强制指定。判定规则见
`docs/sub/unified-subscription.md` §2，那里是单一事实源；地址形态与 `<订阅名>` 的当前值见
`docs/sub/README.md` §3.4。示例中的 `sub.example.com` 是占位符，本机真实域名见
`sub-manager` 的 `HOST` 常量。

改了 `base/all_base.tpl` 或 `snippets/*.txt` 之后，**先重启再 resync**（`cache_config=300`
会缓存模板）：

```bash
systemctl restart subconverter && sub-manager resync
```

健康检查：

```bash
systemctl is-active x-ui subconverter nginx
ss -lntp | grep -E ':(443|2096|35006|8443|25500)\b'   # 2096 应只有 127.0.0.1
getent hosts sub.example.com                            # 占位符换成实际订阅域名；应返回 127.0.0.1
curl -fsS http://127.0.0.1:25500/version
nginx -t
```

## 改动前检查

以下约束在改动本系统前逐条确认。机制和完整链路以链接文档为准；两者冲突时以文档为准。

- **节点名恒定**：3x-ui 在备注后追加 `|📊<剩余流量>`，靠 `CONVERT_OPTS` 的
  `rename=\|📊.*@` 剥掉。Mihomo 以节点名为键还原选择，名字变了就回落到策略组第一项；
  3x-ui 改备注格式时，这条正则要同步调整。incidents `2026-08-11`
- **旗子后的空格去不掉**：subconverter 贴旗时硬编码 `旗子 + " " + 原名`，`[emojis]` 没有
  分隔符开关；唯一替代是 `emoji=false` + 手工 `rename`，代价见 design §6.2，机制见
  README §3.3。策略组名 `🚀节点选择` 是另一回事：改它要同步 `groups.txt`、
  `rulesets.txt` 的 `[]FINAL` 和脚本断言，逐字节一致。
- **订阅名三处对齐**：Clash 分支取 `PROFILE_NAME`（`Content-Disposition`），原生分支取面板
  「订阅标题」（`Profile-Title`），Shadowrocket 只认 URL fragment `#<订阅名>`；前两处双写
  消不掉，名字保持纯 ASCII。当前值见 README §3.4。incidents `2026-08-22`
- **改路径 = 所有设备重配**：只有 `rotate` 会换路径，它保留编号与原始订阅，不必重输 URL；
  `resync` 只重建 Nginx 配置，编号和地址都不动。
- **`renumber` 只改编号**：`path`、源订阅和节点都不动，设备无需重配；但记住的旧编号会失效，
  之后的 `update` / `rotate` / `remove` 要用新编号。
- **`rotate` / `remove` ≠ 收回节点访问**：`sub-manager` 对 x-ui / `*.db` 零写操作，它们只
  作废分发通道，已拉取 profile 里的 UUID 仍然有效。真正踢人要去 3x-ui 删掉或更换该客户端的
  UUID。见 unified-subscription §6。
- **2096 收口依赖 `/etc/hosts`**：订阅域名必须解析到 `127.0.0.1`，否则 Clash 分支报「本地
  转换失败」，原生分支正常。incidents `2026-10-18`
- **读 `x-ui.db` 要区分「空」与「失败」**：库是 `journal_mode=delete`，写事务会阻塞读，坏读
  返回空结果；所有查询带 `-cmd '.timeout 3000'`，并同时检查退出码和结果非空。把空当成
  「没有客户端」会得到「无漂移」的错误结论。incidents `2026-08-22 读 x-ui.db 偶发返回空`
- **两个分支都要带 `Vary: User-Agent`**：否则缓存会把 Clash 配置喂给 Shadowrocket。承接
  分流的 location 必须是精确匹配 + `internal`，不能用命名 location。见
  unified-subscription §3、§5
- **`nginx -t` 会 chown 缓存目录**：隔离校验配置里不能 include 生产的
  `sub-rules-cache.conf`，否则 `/var/cache/nginx/sub-rules` 属主被夺，规则端点返回 500。
  incidents `2026-08-10 nginx -t 夺走缓存目录属主`
- **规则集不走 jsdelivr**：自维护 list 由 `sub-rules-sync.timer` 每分钟从规则仓库发布到
  `/var/lib/sub-rules/`，nginx 直接 serve；jsdelivr 的两层缓存不同步，重复 purge 会让内容
  在新旧间跳变。incidents `2026-08-10 jsdelivr 缓存不收敛`
- **兜底反代缓存的两条硬约束**：必须写 `proxy_ignore_headers Cache-Control Expires`；禁止
  `proxy_cache_background_update on` 和 `use_stale ... updating`。incidents `2026-08-19`
- **`interval: 1800` 只管自动刷新**：手动「更新规则集」本来就绕过它，排查规则不生效时不要
  把它当主因。incidents `2026-08-19` 被排除的方向
- **`rule-providers` 必须带 `format: text`**：由 Nginx `sub_filter` 注入，缺了国内规则集
  不生效。incidents `2026-08-08 rule-providers 缺 format: text`
- **Reality 目标站必须端到端实测**：`xray tls ping` / `curl` 只证明普通 TLS 可用，不证明
  适合做 Reality 目标。troubleshooting §4.5、§5
- **分层定位**：服务 → TCP → TLS → Reality → VLESS → 出站；前一层通不代表后一层通。
  troubleshooting §9

## 约定

- 文档语言为中文。除 `incidents` 外，其余文档章节按数字编号；`incidents` 用日期做标题，如
  `## 2026-08-19 「更新规则集」拿到的永远是上一版`——追加时不必重排编号，跨文档引用也不会
  因插入新条目而失效。
- 新故障写进 `docs/sub/incidents.md` 顶部（倒序），保留完整链路：现象 → 排查 → 被排除的
  方向 → 根因 → 解决方案 → 验证。「排除了什么」和「根因是什么」同样有价值。旧条目只读，
  后续演进用「> 后续：」引用新条目，不要就地改写。
- 系统当前状态以运维文档为准，两处说法冲突时以上表标注的**单一事实源**为准；
  `incidents.md` 描述的是当时的状态，不要拿它当现状。
- 破坏性操作前先备份，且写明回滚步骤。备份清单见 `docs/sub/operations.md` §4。
- 涉及订阅、面板、密钥的排查输出，贴进文档前先遮盖：用户名、密码、UUID、`subId`、完整
  订阅 URL、`pbk`/`privateKey`、`sid`/`shortId`、Cookie、CSRF token。
