# 故障档案

按日期倒序。每条保留完整链路：现象 → 排查 → 被排除的方向 → 根因 → 解决方案 → 验证。
「排除了什么」和「根因是什么」同样有价值。

**本文只追加，不修改旧条目。** 条目描述的是当时的状态；系统当前长什么样以
[design.md](design.md) 为准。

---

## 2026-10-25 首次部署在创建第一条订阅处中止

### 现象

`tools/deploy.sh` 安装完成后询问「现在创建第一条订阅？」，回答 `y` 后立即退出：

```text
现在创建第一条订阅？ [y/n] y
错误：读取 3x-ui 客户端列表失败（Error: in prepare, no such table: clients），未做修改。

错误：部署中断（退出码 1）。
```

此时 subconverter、Nginx、证书都已经装好；脚本以 `set -e` 运行，后面的 `setup_rules`
也没机会执行。

### 排查

- `sub-manager add --from-xui` 的查询是
  `from clients c join client_inbounds ci on ci.client_id = c.id`，这是 3x-ui v3 的
  规范化表结构。
- 查本机数据库：`sqlite3 /etc/x-ui/x-ui.db '.tables'` 只有 `inbounds`、`settings`、
  `users`、`client_traffics` 等表，没有 `clients`。本机 3x-ui 是 2.8.11，客户端以 JSON
  数组存在 `inbounds.settings` 的 `clients` 字段里，`subId` 用驼峰命名。
- 3x-ui v3 的 `internal/database/model/model.go` 才把客户端拆成 `clients` 与
  `client_inbounds` 两张表。脚本读的是 v3 的表，装的是 2.x 的库。

### 被排除的方向

- 不是数据库被写事务锁住。错误是 `no such table`，不是 `database is locked`；
  `.timeout 3000` 的重试窗口没有参与。
- 不是 x-ui 没运行或 DB 不可读。`x-ui.service` active，`sqlite3 -readonly` 能正常查询
  `inbounds` 与 `settings`。
- 不是客户端不存在。`inbounds.settings` 的 `clients` 数组里有一个启用中的客户端，带
  `subId`；缺的是查询接口，不是数据。

### 根因

`sub-manager` 把 3x-ui v3 的表结构当成唯一形态；部署脚本又把「创建第一条订阅」当成
安装的必经步骤，失败时用 `set -e` 中止整个部署。订阅是可选的后置操作，不应拖垮已经
成功的安装。

### 解决方案

- `xui_clients_into` 先查 `sqlite_master` 判断有没有 `clients` 表：有则走 v3 查询，没有
  则用 `json_each` 从 `inbounds.settings` 的 `clients` 数组里取 `subId` / `comment` /
  `email` / `enable`。两种查询输出同一种 TSV，`list` 与 `add --from-xui` 不用改。
- `deploy.sh` 不再询问、不再调用 `sub-manager add`。安装完成后打印面板地址（端口与路径
  取自 `webPort` / `webBasePath`，协议看 `webCertFile` / `webKeyFile`），并列出「登录面板
  建入站 → 加客户端 → `sub-manager add --from-xui` → `sub-manager test`」。
- subconverter 健康检查的重试日志不再逐行打到终端：curl 的 stderr 先写进临时文件，只在
  最终失败时回放。

### 验证

- 在本机 2.8.11 的库上执行新查询，返回唯一的启用客户端，`subId` 与备注列对齐。
- `bash -n` 校验 `sub-manager` 与 `deploy.sh`；`deploy.sh --dry-run` 正常打印计划并退出 0。
- 重跑 `deploy.sh --yes` 完整通过，收尾打印面板地址和后续命令，不再访问 3x-ui 客户端表。
- `sub-manager add --from-xui` 在 2.8.11 的库上列出候选客户端；直接回车取消，状态未改。

---

## 2026-10-25 首次部署在 subconverter 健康检查处中止

### 现象

`tools/deploy.sh` 首次部署，安装完 subconverter 后立即退出：

```text
Created symlink /etc/systemd/system/multi-user.target.wants/subconverter.service → /etc/systemd/system/subconverter.service.
curl: (7) Failed to connect to 127.0.0.1 port 25500 after 0 ms: Couldn't connect to server
✗ 错误：subconverter 未在 127.0.0.1:25500 响应。
```

随后 `systemctl status subconverter` 显示 active，25500 正常监听，服务本身没有故障。

### 排查

- `systemctl restart` 只保证进程已拉起，不保证端口已监听。日志显示 subconverter 启动时
  先读 `base/` 与 `snippets/*.txt`，约 2 秒后才开始监听。
- 健康检查写的是 `curl --retry 3 --retry-delay 1`。curl 的 `--retry` 只重试超时、5xx 等
  瞬时错误，**不包含「连接被拒」**（error 7）；需要显式加 `--retry-connrefused`。所以三次
  重试一次都没发生，第一次失败即退出。
- 中止还挡住了下一条命令：`nginx -t` 报
  `mkdir() "/var/cache/nginx/sub-rules" failed (2: No such file or directory)`。
  `sub-rules-cache.conf` 声明了 `proxy_cache_path`，但全新机器上 `/var/cache/nginx` 都不存在，
  部署脚本只装配置没建目录。

### 被排除的方向

- 不是 subconverter 二进制或架构问题：`file` 显示 x86-64 静态链接可执行文件，手动启动正常。
- 不是 `pref.ini` 损坏：日志里的 TOML 解析报错是 subconverter 先按 TOML 试读、失败后回退
  INI 的正常路径；回退后配置生效（监听 `127.0.0.1:25500`）。
- 不是端口冲突：`ss -lntp` 只有 subconverter 自己监听 25500。

### 根因

部署脚本的两处前置条件缺口：健康检查没有覆盖「连接被拒」，缓存目录只写配置、没建目录。

### 解决方案

- 健康检查改为 `--retry 15 --retry-delay 1 --retry-connrefused`，失败信息带上
  `journalctl -u subconverter -n 50` 的排查入口。
- 在 `nginx -t` 前补建目录：父目录 `/var/cache/nginx` 缺失时以 0755 创建，
  `/var/cache/nginx/sub-rules` 属主 `www-data`、权限 0700，与 `nginx.conf` 的 `user` 一致。
- 手工部署步骤同步补上建目录。

### 验证

重启 subconverter 后立即执行新的健康检查：前两次 connection refused，第三次成功，耗时约
2.2 秒；建目录后 `nginx -t` 通过，Nginx reload 正常。

> 后续：重试成功时那几行 connection refused 仍会出现在终端里，看起来像部署出错。现在
> 只在最终失败时回放，见上方 `2026-10-25 首次部署在创建第一条订阅处中止`。

---

## 2026-10-18 2096 收口后 Clash 分支报「本地转换失败」

### 现象

把 3x-ui 订阅的 `subListen` 改为 `127.0.0.1` 并重启 x-ui 后，`ss` 已显示
`127.0.0.1:2096`，但 `sub-manager test` 在第一条订阅上失败：

```text
测试 sub-10                   curl: (22) The requested URL returned error: 400
错误：本地转换失败。
```

失败只出现在经过 subconverter 的链路；原生分支不经过 subconverter，不受影响。

### 排查

- `sub-manager` 自己拉取原始订阅时带 `--resolve sub.example.com:2096:127.0.0.1`，直连
  回环正常。
- Nginx 原生分支显式回源 `https://127.0.0.1:2096`，也正常。
- 失败发生在 `validate_source_and_conversion()` 的第二步：它把**公网域名**放进
  `CONVERT_OPTS` 的 `url=` 交给 subconverter，由 subconverter 自己拉取。此时 2096 只监听
  回环，subconverter 按系统解析去连公网地址，连接失败，转换后端返回 400。

### 被排除的方向

- 不是 x-ui 没起来：服务 active，2096 在回环上正常响应。
- 不是证书或 SNI：`--resolve` 拉取与原生分支都成功。
- 不是订阅内容坏了：收口前同一条订阅通过；失败只出现在经过 subconverter 的链路。

### 根因

收口只改了 3x-ui 的监听地址，没有同步改变 subconverter 的出站解析。文档原先验证了 Nginx
原生分支和 `sub-manager` 自己的拉取，漏掉了 subconverter 的源订阅拉取。

### 解决方案

在 `/etc/hosts` 增加订阅域名到回环的映射，然后重启 subconverter：

```text
127.0.0.1 sub.example.com
```

映射只改解析结果，SNI、Host 和证书校验都不变。原生分支和 `sub-manager` 的 `--resolve`
不依赖它，保留即可。

### 验证

- `sub-manager test` 全部订阅通过。
- `ss -lntp | grep 2096` 只剩 `127.0.0.1:2096`。
- 从本机连接服务器公网地址的 `2096` 被拒绝。
- `getent hosts sub.example.com` 返回 `127.0.0.1`。

---

## 2026-08-22 读 x-ui.db 偶发返回空，被当成「无需新增」

### 现象

给 `clash-sub-manager` 加完 3x-ui 只读联动后做连测，同一条 `add --from-xui` 在连续三次
调用中，第三次打印了：

```text
全部启用中的 x-ui 客户端都已有聚合地址，无需新增。
```

而同一时刻 `clash-sub-manager list` 明确报告有 3 个 x-ui 客户端还没有聚合地址。重跑同一条
命令又恢复正常，稳定复现不出来。

### 排查

先排掉几个看着像的：

- **不是候选过滤逻辑写错。** 重跑立刻正常，且 `list` 用同一份数据算出了正确结果。
- **不是 `flock` 竞争。** 抢锁失败会报「另一个管理操作正在运行」，是另一条消息。
- **不是 x-ui 停了。** 那会走 `xui_available` 的失败分支，消息也不同。

第一次探针用 60 次快速查询，失败 0 次、空结果 0 次，一度以为不可复现。**问题出在采样窗口
太短**：60 次查询约 2 秒跑完，根本没跨过一次写事务。

把探针拉长到 90 秒，并改用与脚本**完全相同**的那条 SQL：

```text
26672 次查询：失败 316 次，空结果 316 次
Error: in prepare, database is locked (5)
Error: stepping, database is locked (5)
```

失败率 1.2%，且失败次数与空结果次数完全相等。空结果就是失败本身。

### 被排除的方向

- SQL 语句本身（重跑同一条正常）
- `flock` 并发（消息不符）
- x-ui 未运行（消息不符）
- 「不可复现」这个结论本身：短探针测不出来只是因为没跨过写周期，不是没有问题

### 根因

两层叠加。

**第一层**：`/etc/x-ui/x-ui.db` 是 `journal_mode=delete`，不是 WAL。写事务持有排他锁期间
读者一律被拒。x-ui 每十几秒写一次流量统计，只读查询有约 1.2% 的概率正好撞上。`sqlite3`
CLI 的 `busy_timeout` 默认是 0，撞上就立即返回错误、标准输出为空。

**第二层，也是真正的缺陷**：脚本当时把「查询返回空」等同于「没有候选客户端」。于是一次
读取失败被呈现成「一切正常，无需新增」。合并这两种状态的默认方向，恰好是让人安心的
那个。

### 解决方案

1. 所有只读查询加 `-cmd '.timeout 3000'`，撞锁时在 3 秒内重试而不是立刻失败。
2. `xui_clients_into` 同时检查 `sqlite3` 退出码**和结果是否为空**，任一异常都返回非零。
   「x-ui 里一个客户端都没有」不是正常状态，一律按读取失败处理。
3. 调用方分两种态度：`list` 静默降级为不带客户端名的旧输出，并明确打印「本次未核对
   客户端」；`add --from-xui` 直接 `fail`，不允许降级。
4. `xui_sub_base` 区分「`settings` 里没有该键」（用 3x-ui 默认值 `2096` / `/sub/`）与
   「查询失败」（返回非零）。

### 验证

同一个 90 秒探针，加 `.timeout 3000` 后：

```text
26673 次查询：失败 0 次，空结果 0 次
```

`list` 的降级分支单独验过：把脚本副本的 `XUI_DB` 指向不存在的路径，输出退回旧格式并打印
「（x-ui 未运行或读不到 …，本次未核对客户端。）」，不会谎报无漂移。

### 教训

**「读到空」和「读失败」必须分开。** 任何以外部可变数据源为输入的一致性检查都要显式区分
这两种状态，否则坏读会伪装成「一切正常」。同理，**探针的采样窗口必须跨过被观测系统的写
周期**，否则「测不出来」是采样问题而不是结论。

---

## 2026-08-22 聚合订阅在两个客户端里显示两个难看的名字

### 现象

聚合入口上线并正常工作后，同一条 `/sub/<随机路径>` 在两个客户端上的订阅卡片名称都不对：

- Shadowrocket 显示一串随机字符；
- Clash Verge 显示 `Remote File`。

### 排查

两个症状看着像一个问题，实际是两条独立成因，必须分开查。

**Shadowrocket 那半边**，抓响应头即定位。原生分支（`location = /internal/raw/...`）按设计
原样透传 3x-ui，而实测 `2096` 与聚合入口原生分支的响应头里只有 `Profile-Update-Interval`、
`Profile-Web-Page-Url`、`Subscription-Userinfo`。**没有 `Profile-Title`，也没有
`Content-Disposition`**。一个名称 header 都没有，客户端只能退回用 URL 末段命名，那正好是
随机路径。

读 3x-ui 源码确认了触发条件（`internal/sub/controller.go`，`ApplyCommonHeaders`）：

```go
if profileTitle != "" {
    c.Writer.Header().Set("Profile-Title", "base64:"+base64.StdEncoding.EncodeToString([]byte(profileTitle)))
}
```

`profileTitle` 来自 setting key `subTitle`，默认空串（`internal/web/service/setting.go:93`），
空则整条 header 不发。查库佐证：`settings` 表里压根没有 `subTitle` 这一行，从未设过。

**Clash Verge 那半边三个假设全被证伪**，最终没有在服务器上找到根因：

| 假设 | 验证方式 | 结果 |
|---|---|---|
| Verge 不解析 `filename*` | 拉 `prfitem.rs` 的 main、v2.0.3、v1.7.7 三个版本对比 | 证伪。三版都是 `parse_str(filename, "filename*")` 优先，percent-decode 后 `split("''").last()`，算出来就是当时的中文名 |
| header 没发出去或格式有问题 | 以 `clash-verge/v2.4.2` 的 UA 实测 GET，`cat -A` 逐字节看 | 证伪。单条、无重复、无异常字节 |
| Verge 走了原生分支 | 推演 | 排除。原生分支返回 base64 节点列表，Verge 会在 `serde_yaml` 那步直接报错拒绝导入，而不是导入成功后名字难看 |

按 Verge 的代码路径，`Remote File` 只可能出现在 header 存在但取名为空、或**名字在首次导入时
就被固化**这两种情况。Verge 的 profile `name` 只在首次导入时写入，之后更新订阅不重算。旧
profile 是在服务器加上 `Content-Disposition` 之前建的，名字就一直留着。

### 被排除的方向

- 不是聚合入口的 UA 分流出错。两个 UA 都命中了预期分支，响应体格式正确。
- 不是 `Vary: User-Agent` 缺失导致的缓存串味。两个分支都带着。
- 不是 3x-ui 版本太老。本机 3.53.2，二进制里 `strings` 能抓到 `subTitle`，功能存在。

### 根因

Shadowrocket 那半边：3x-ui 的订阅标题从未设置，`Profile-Title` 因空值被跳过，原生分支
透传时自然也没有，客户端退回用 URL 末段命名。

Clash Verge 那半边：服务器侧的 `Content-Disposition` 本身没问题，是客户端里的旧 profile
名字已固化。

### 解决方案

1. 3x-ui 面板 → 设置 → 订阅 → 通用 → 订阅标题，设为 `DuskWander`（本次直接写库后重启
   `x-ui`）。这一处同时覆盖 `2096` 直连和聚合入口原生分支，且不破坏原生分支「原样透传、
   不动上游 `Profile-*`」的设计约束。
2. `clash-sub-manager` 里原本硬编码在两处的 percent-encoded 中文名，提成常量
   `PROFILE_NAME`，并把 `Content-Disposition` 改为 `filename` / `filename*` 双写：

   ```text
   attachment; filename="DuskWander"; filename*=UTF-8''DuskWander
   ```

   双写是给只认 `filename=` 的老解析器兜底；名字因此必须保持纯 ASCII，`filename=` 那一份
   不做编码。
3. 名称登记进 [README.md](README.md) §3.4 作为单一事实源，并写明两处必须人工对齐。

Clash Verge 侧无需服务器改动，删除订阅重新导入即可拿到新名字。已实测有效，确认就是固化。

> 后续（同日）：Shadowrocket 侧上面这个解决方案**不够**。设置订阅标题后真机仍显示随机串，
> 补查见下节。

### 验证

```text
Clash 分支  Content-Disposition: attachment; filename="DuskWander"; filename*=UTF-8''DuskWander
原生分支    Profile-Title: base64:RHVza1dhbmRlcg==     # 解出即 DuskWander
独立 /clash 地址同上
```

`nginx -t` 通过，`clash-sub-manager test` 五条订阅全部通过，`x-ui` / `subconverter` /
`nginx` 均 active。

### 补充：Shadowrocket 拿到了 Profile-Title 却不用

设置订阅标题后 Clash Verge 恢复正常，但 Shadowrocket 真机**依然显示随机串**。「删了重加」和
「刷新订阅」都试过，排除了 Verge 那半边的固化解释。

不再推演，上探针。临时在 `private-clash.conf` 的 server 块把 `access_log off` 换成一个自定义
log_format，**只记 UA、命中的分支和两个名称 header，刻意不记 `$request` / `$uri` / `$args`**。
那里含订阅随机路径，等同凭据。真机操作一次后拿到：

```text
backend=raw title=[base64:RHVza1dhbmRlcg==] disp=[-] status=200
ua="Shadowrocket/3378 CFNetwork/3860.700.1 Darwin/25.6.0 iPhone15,4"
```

分支对、状态码对、`Profile-Title` 完整送达。**它拿到了，就是不用。**

上游文档其实早有暗示（3x-ui `docs/content/docs/en/config/subscription.mdx`）：

> `Profile-Title`, `Support-Url`, `Profile-Web-Page-Url`, `Announce` — optional branding shown
> by **some** clients.

根因：Shadowrocket 的订阅名是**本地备注字段**，默认取 URL 末段，服务器 header 管不着。唯一
能给初值的是 URL fragment：

```text
https://sub.example.com:8443/<随机路径>#DuskWander
```

fragment 由客户端本地截断，**不发给服务器**，因此既不影响 UA 分流也不进日志。实测有效。

`clash-sub-manager list` / `add` / `rotate` 现在直接输出带 fragment 的完整地址，整条粘贴即可。

探针用完即拆：`resync` 恢复 `access_log off`，删掉临时 log_format 文件和日志。

### 留下的坑

服务器侧那两处名字是无法消除的双写点：Clash 分支的响应由 subconverter 生成，根本不经过
3x-ui，拿不到 `Profile-Title`。改名必须同时动脚本常量和面板设置，只改一处就会让同一条链接
在两类客户端上显示两个名字。加上 Shadowrocket 的 fragment，一共三处要对齐，清单见
[README.md](README.md) §3.4，检查命令见 [operations.md](operations.md) §3.1。

`clash-sub-manager test` 现在对 `Profile-Title` 与 `Content-Disposition` 各有一条断言，漏改
服务器侧任一处都会报错；但 fragment 在客户端里，测不到。

---

## 2026-08-19 「更新规则集」拿到的永远是上一版

### 现象

新增 `DOMAIN-SUFFIX,liepin.com` 直连规则并 push 后，客户端仍走代理。在 Clash Verge
点「更新规则集」无效，只有「更新订阅」才能拿到新规则。而同一个仓库的
`shadowrocket.conf` 在 Shadowrocket 里点更新却总是最新的。

### 排查

链路自上而下逐层验证，前四层全部正常：

| 层 | 检查 | 结果 |
|---|---|---|
| 规则内容 | GitHub 上 `ChinaDirect.list` 是否含 liepin | 有，第 123 行 |
| 规则顺序 | `RULE-SET,ChinaDirect,DIRECT` 是否被前面的规则抢匹配 | 排第 2，前面只有 Reject |
| `format: text` | `2026-08-08` 那个坑是否复发 | 11 个 provider 全部带 |
| 订阅生成 | rule-providers 的 URL / behavior 是否正确 | 正确 |

问题出在分发层。决定性观测：仓库在 `15:04:05` 提交了 `lietou-static.com`，
26 分钟后连续拉取本站端点两次：

```text
15:30:48  第 1 次 → X-Rule-Cache: STALE   133 行  无 lietou-static   ← 旧内容
15:30:48  第 2 次 → X-Rule-Cache: HIT     137 行  有 lietou-static   ← 新内容
```

**单次拉取必定拿到旧的，连拉两次才拿到新的。**

### 被排除的方向

- **不是 `interval: 1800` 卡住。** 手动「更新规则集」/ `PUT /providers/rules/<name>`
  本来就绕过 interval，它只管自动刷新。（此前一度误判为主因，需要记一笔。）
- **不是 jsdelivr 那类 CDN 问题。** 自维护规则早已不走 jsdelivr（见 `2026-08-10`）。
- **不是客户端配置错误。** 同一份配置里 ACL4SSR 的 9 个 provider 行为一致。
- **不能靠绕过 GitHub 边缘缓存解决。** 实测 `raw.githubusercontent.com` 在 Fastly 后面
  （`via: 1.1 varnish`），三条绕过路径全部失败：查询串被归一化仍 `HIT`；请求头
  `Cache-Control: no-cache` 不被理会仍 `HIT`；`api.github.com/contents` 端点虽然内容
  一致、无 Fastly 层、TTL 只有 60s，但**条件请求返回 304 照样扣配额**（实测 remaining
  53→52→51→50→49→48），未认证 60 次/小时不够两个文件按分钟级轮询，除非引入 PAT。

### 根因

`/etc/nginx/snippets/clash-rules-upstream.conf` 的
`proxy_cache_background_update on` + `proxy_cache_use_stale ... updating`，
使缓存过期后的**第一个**请求同步返回陈旧副本、仅在后台回源；而客户端
「更新规则集」正是单次一次性拉取，因此必定拿到上一版规则，随后被 Mihomo 落盘
锁定一个 `interval` 周期。

放大它的是第二个缺陷：`proxy_cache_valid 200 60s` 从未生效。全站没有
`proxy_ignore_headers`，上游 `Cache-Control: max-age=300` 覆盖了它。实证，解码
nginx 缓存文件头：

```text
/var/cache/nginx/clash-rules/a/87/48e7…
  valid_sec 15:07:11 − date 15:02:11 = 300 秒
```

于是那个「必定陈旧」的窗口不是 60 秒，而是 300 秒。

这一条解释了全部现象，包括那两个看似矛盾的：

- **「更新订阅」为什么有效**：订阅更新触发 core 重载，provider 被拉取不止一次，
  第二次起就是新的。（客户端行为，推断）
- **Shadowrocket 为什么总是最新**：那条链路上既没有本站反代、也没有 provider
  的 interval，只剩 Fastly 一层；且 `shadowrocket.conf` 是冷门对象，在边缘缓存里
  存不住，几乎每次都回源（实测连拉 5 次 `source-age` 全为 0）。反观
  `ChinaDirect.list` 被持续轮询而常驻缓存，`source-age` 稳定在 245~247。
  **拉得越勤的文件，拿到的副本越旧**。这是 Fastly 缓存的反直觉副作用。
- **`clash-rules-check` 一直在报「缓存 STALE」**：它也是单次拉取，工具早就在如实
  报告，只是这个字段此前没被当回事。

### 解决方案

两层同时改（当前形态见 [design.md](design.md) §9）：

1. **改变分发方式**：服务器 clone 规则仓库到 `/root/code/shadowrocket-config`，
   `clash-rules-sync.timer` 每分钟 `fetch` + `ff-only` 合并并发布到
   `/var/lib/clash-rules/`，nginx 直接 serve 该目录的文件。**无任何缓存层**。
   GitHub 反代降级为兜底路径，仅在发布目录缺文件时触发。
2. **修好兜底路径的缓存**：加 `proxy_ignore_headers Cache-Control Expires`；
   TTL 收到 30s；加 `proxy_cache_revalidate on`（带 ETag 条件请求）；
   删掉 `proxy_cache_background_update` 与 `use_stale` 里的 `updating`。
   故障兜底分支（error/timeout/5xx/403/429 + `inactive=30d`）原样保留。

`interval: 1800` 未改动，手动刷新本就绕过它。

### 验证

```text
主路径      单次拉取 ×5，全部 X-Rule-Source: local，137 行，含 lietou-static
无缓存      直接改发布目录，连拉 3 次立即全部反映，无任何延迟
自愈        改动被下一次同步还原，发布目录与仓库逐字节一致
兜底路径    移走本地文件 → X-Rule-Source: github，X-Rule-Cache: REVALIDATED，137 行
            （修复前此处必为 STALE + 旧内容，这是 Layer 1 的红绿证据）
诊断脚本    三个异常分支逐一制造，均正确报红并返回 1；恢复后返回 0
回归        clash-sub-manager test 四个订阅全部通过；11 个 provider 仍全部带 format: text
            nginx -t 前后 /var/cache/nginx/clash-rules 属主仍为 www-data（未触发 08-10 那个坑）
```

### 遗留

延迟上限由同步定时器周期决定，当前 1 分钟。若要压到秒级，可改用 GitHub webhook
触发同步（能保住「服务器侧无需人工命令」的性质），代价是多一个入站端点和一份
HMAC 密钥。当前未实施。

---

## 2026-08-11 更新订阅后策略组回落直连

### 现象

Clash Verge 中手动选定 `🇺🇸 美国` 节点后，只要更新一次订阅，策略组就自动跳回 `DIRECT`，
全部流量走直连。

### 三个叠加原因

**（1）节点名内嵌累计流量，每次更新都在变：决定性原因**

3x-ui 的订阅服务在备注后追加 `|📊<剩余流量>`（inbound remark 本身只是 `美国`）。转换后的
节点名形如：

```text
🇺🇸 美国-<节点后缀>|📊191.97GB
```

Mihomo 和 Clash Verge 还原选择时都以**节点名**为键。流量一变名字就变，上次选中的名字不复
存在，只能回落到策略组第一项。

该后缀是 x-ui 3.4.2 订阅服务拼备注时的默认格式，不是面板设置项（`settings` 表里只有四条
证书/端口配置），也不是本方案引入的。`x-ui.service` 装于 2026-08-07，因此这个问题从建站起
就潜伏着，只是要「手动选节点 + 更新订阅」同时发生才会暴露。

**（2）策略组第一项恰好是 DIRECT**

原 `groups.txt` 为 `🚀 节点选择\`select\`[]DIRECT\`.*`，`[]DIRECT` 排在 `.*` 之前，于是
「回落到第一项」等于「回落到直连」。

**（3）模板缺 `profile.store-selected`**

`base/all_base.tpl` 没有 `profile:` 段，Mihomo 该项默认 `false`，即**每次 reload 都重置所有
select 组**。即使名字稳定，重启内核后同样会掉回第一项。

### 解决方案

三处都改，缺一不可：

| 位置 | 改动 |
|---|---|
| Nginx `proxy_pass` + `clash-sub-manager` 的 `CONVERT_OPTS` | 加 `&rename=%5C%7C%F0%9F%93%8A.%2A%40`（即 `\|📊.*@`），剥掉流量后缀 |
| `base/all_base.tpl` | 加 `profile:` / `store-selected: true` |
| `snippets/groups.txt` | 改为 `🚀 节点选择\`select\`.*\`[]DIRECT`，节点在前、DIRECT 兜底 |

转换参数抽成脚本常量 `CONVERT_OPTS`，`validate_source_and_conversion()` 和 `render_nginx()`
共用，避免两处漂移。同时新增 `resync` 子命令（见 [operations.md](operations.md) §1.7）用于
套用模板改动。

修复后输出：

```yaml
profile:
  store-selected: true

proxies:
  - name: 🇺🇸 美国-<节点后缀>     # 名称恒定，不再含流量

proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - 🇺🇸 美国-<节点后缀>
      - DIRECT
```

### 流量显示去哪了

没有丢。Clash 的原生机制是 `Subscription-UserInfo` 响应头，3x-ui 发出、subconverter 转发
（`pref.ini` 的 `append_sub_userinfo=true`）、Nginx 未 hide，端到端已通：

```text
Subscription-UserInfo: upload=<字节>; download=<字节>; total=<字节>; expire=0
```

Clash Verge 的订阅卡片直接读这个头渲染流量条。它不参与节点名匹配，随便变都不影响
`store-selected`。这才是流量信息该待的地方。

`expire=0` 表示 3x-ui 该客户端未设到期时间，因此卡片不显示到期日；需要显示就在 3x-ui 里给
客户端设一个。

**未采用机场式「假节点显示流量」**：机场那么做主要是兼容不渲染该响应头的客户端。自建假节点
需要从响应头的字节数算出剩余量，而 Nginx 原生没有算术能力、`sub_filter` 也只支持字面量匹配
拿不到正则捕获组，只能引入 `libnginx-mod-http-js`（njs）。为一个 Clash Verge 本就会显示的
信息增加模块，在这台 2GB 服务器上不划算。真要做的话，那必须是一个**额外的**假节点，真实
节点的名字仍须保持稳定，否则本条的问题会原样复发。

Shadowrocket 侧不受影响：它走 3x-ui 原生订阅，不经 subconverter，节点名里仍带
`|📊<剩余流量>`。Shadowrocket 按节点顺序而非名称记忆选择，名字变化对它无害，所以 3x-ui 这个
默认格式在小火箭上是特性、在 Clash 上才是 bug。

节点名中的 🇺🇸 国旗由 `emoji=true` 按「美国」匹配生成，与本次改动无关，保留。

### 客户端操作

更新订阅后**手动选一次美国节点**。旧的持久化记录里存的仍是带流量后缀的旧名字，必须重新选定
一次；此后更新订阅不会再回落。

### 验证

```text
YAML 解析: OK
profile: {'store-selected': True}
proxies: ['🇺🇸 美国-<节点后缀>']
groups: [('🚀 节点选择', 'select', ['🇺🇸 美国-<节点后缀>', 'DIRECT'])]
rule-providers: 11 条; 均有 format: True
rules 末两条: ['GEOIP,CN,DIRECT,no-resolve', 'MATCH,🚀 节点选择']
ipv6: False | fake-ip: fake-ip | strict-route: True
配置文件: 185 行

$ clash-sub-manager test
测试 sub-2   通过
测试 sub-3   通过
测试 sub-4   通过

$ ls -ld /var/cache/nginx/clash-rules
drwx------ 6 www-data www-data          # 08-10 那个坑未复发
$ clash-rules-check
ChinaDirect.list   一致（128 行，缓存 HIT）
Reject.list        一致（22 行，缓存 HIT）
```

三个订阅的节点名均已去除流量后缀。

---

## 2026-08-10 jsdelivr 缓存不收敛，改为自托管

### 现象

排查「新增规则不生效」时确认，jsdelivr 对**文件内容**和**分支 → commit 的解析结果**是两层
独立缓存，且各 provider 之间不同步。

### 实测

实测同一个 `@main` URL：

| provider | 返回 |
|---|---|
| `gcore.jsdelivr.net` | 128 行（新） |
| `cdn.jsdelivr.net` | 123 行（旧） |
| `fastly.jsdelivr.net` | 123 行（旧） |

purge 三次、轮询 5 分钟均未收敛，`s-maxage=43200` 意味着最坏等 12 小时。**重复 purge 反而
有害**：每次 purge 清掉已刷新好的副本，再从尚未同步的元数据层回源，内容在新旧之间来回跳
（实测撞到过）。

### 被排除的方向

中途曾改为 commit SHA 固定（`@<sha>`，不可变引用，jsdelivr 永久缓存）。可行，但有两个代价：
每次改规则必须在服务器跑一次同步命令，且 URL 变化会让客户端 `providers/` 每次残留一组孤儿
文件（约 6.3 KB/次）。

### 解决方案

改为自托管反代，同时消除了这两个代价和最后一个第三方依赖。SHA 时期的两个过渡脚本
`clash-rules-sync`（改写 `rulesets.txt` 里的 SHA）和 `clash-rules-purge`（purge jsdelivr）
随之废弃并删除。

> **同名不同物**：2026-08-19 新建了一个同样叫 `/usr/local/sbin/clash-rules-sync` 的脚本，
> 职责完全不同：从 git 工作副本发布规则到 `/var/lib/clash-rules/`。它是**当前生效**的，
> 见 [design.md](design.md) §9.2。本条里被删除的是 SHA 时期那个旧同名脚本。

> 后续：2026-08-19 发现反代路径的缓存本身有更严重的问题，分发方式再次调整为本地发布目录，
> 见 `2026-08-19`。

---

## 2026-08-10 nginx -t 夺走缓存目录属主

### 现象

规则端点返回 500：

```text
[crit] open() "/var/cache/nginx/clash-rules/..." failed (13: Permission denied)
```

### 根因

`clash-sub-manager` 的 `validate_candidate_nginx()` 用一份最小配置跑 `nginx -t` 做隔离校验。
**该配置中的 `proxy_cache_path` 绝不能 include 生产的 `clash-rules-cache.conf`**：最小配置
没有 `user` 指令，nginx 默认以 `nobody` 运行，`nginx -t` 会按该用户创建并 chown 缓存目录，
夺走 `www-data` 的写权限。

### 解决方案

在测试配置里用临时目录声明同名缓存区：

```nginx
proxy_cache_path $test_dir/cache levels=1:2 keys_zone=clash_rules:1m max_size=1m;
```

已修复并验证：跑完隔离校验后生产缓存目录属主保持 `www-data:www-data 700` 不变。

若日后仍出现 500，先查属主：

```bash
ls -ld /var/cache/nginx/clash-rules
chown -R www-data:www-data /var/cache/nginx/clash-rules
```

---

## 2026-08-08 rule-providers 缺 format: text，国内规则全部失效

### 现象

Bilibili 等国内媒体流量仍走代理，ChinaMedia 规则集未命中。

### 根因

subconverter-classic 生成的 `rule-providers` 只有 `behavior: classical`，没有 `format: text`
字段。ACL4SSR 的 `.list` 文件是纯文本格式（每行 `DOMAIN-SUFFIX,bilibili.com`），不是 YAML
payload 格式。Mihomo 在缺少显式 `format` 时可能无法正确解析纯文本规则文件，导致所有
RULE-SET 规则加载失败，流量 fall through 到最终的 `MATCH,🚀 节点选择` 走代理。

### 解决方案

在 Nginx 的每个订阅 location 中加入 `sub_filter` 后处理，将 subconverter 响应中的
`behavior: classical` 后自动注入 `format: text`：

```nginx
sub_filter_types *;
sub_filter_once off;
sub_filter "behavior: classical
    url:" "behavior: classical
    format: text
    url:";
```

修改位置：

- `/etc/nginx/conf.d/private-clash.conf`（当前运行配置）
- `/usr/local/sbin/clash-sub-manager` 的 `render_nginx()` 函数（确保未来 `add`/`update`
  生成的配置也包含此修复）

修复后 rule-providers 输出示例：

```yaml
  ChinaMedia:
    type: http
    behavior: classical
    format: text
    url: https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaMedia.list
    path: ./providers/<hash>.yaml
    interval: 86400
```

### 客户端操作

更新订阅重新拉取配置即可。规则集的本地缓存由客户端独立管理，部分客户端（如 Clash Verge）
需要手动点击「更新规则集」才会刷新 provider 文件，仅重启 Mihomo 不一定触发重新下载。

---

## 2026-08-08 部署期问题合集

### SubConverter-Extended 便携包依赖问题

直接运行：

```text
/opt/subconverter-extended/subconverter
```

报错：

```text
libyaml-cpp.so.0.8: cannot open shared object file
```

原因是便携包要求通过 `start.sh` 调用包内动态链接器和依赖目录。systemd 的 `ExecStart` 后来
改为 `start.sh`，依赖问题得到解决。

### SubConverter-Extended 配置路径问题

配置文件放在 `/etc/subconverter-extended/` 后，示例中的相对路径：

```text
snippets/emoji.toml
snippets/groups.toml
snippets/rulesets.toml
```

不能按安装目录解析。尝试调整 `WorkingDirectory`、`base_path` 和绝对导入路径后，snippets
可以加载，但进程仍出现段错误。

### SubConverter-Extended SIGSEGV

合成节点测试和真实 `/sub` 请求均可能造成：

```text
status=11/SEGV
```

因为这是转换服务的核心路径，不能接受自动重启掩盖问题。因此：

- 停止并禁用 `subconverter-extended.service`。
- 保留文件用于后续排查，但不参与当前生产链路。
- 切换到经过真实订阅验证的 classic fork（选型见 [design.md](design.md) §3.3）。

### 443 端口冲突

现有 Xray Reality 占用 `443`。强行复用 443 需要重新设计 Reality、TLS 或 SNI 分流，风险和变更
范围过大。因此 Nginx 使用 `8443`。

### 输出体积较大（已解决）

切换 `expand=false` + RULE-SET 模式前，Clash 配置约 526 KB / 10000+ 行，原因是默认模板将远程
规则展开为逐条内联规则。切换后缩减到 200 行以内，见 [design.md](design.md) §8。

### 转换日志中的 TOML 解析告警（已解决）

切换到 `clash-classic:` URL 格式的 RULE-SET 模式后，后端不再加载默认 TOML 规则资源，该告警
已消失。
