# 运维手册

> 单一事实源在 [README.md](README.md) §3：端口、路径、`CONVERT_OPTS`。本文只引用，不复写。

## 1. 管理脚本 sub-manager

服务器安装了仅 root 可运行的管理脚本：

```text
/usr/local/sbin/sub-manager
```

脚本支持多个 3x-ui 订阅，每个订阅生成一条独立的随机路径。原始订阅通过隐藏输入读取，不会
出现在 shell 历史或进程参数中。

| 命令 | 作用 | 详见 |
|---|---|---|
| `sub-manager add --from-xui` | 从 3x-ui 客户端列表新增订阅 | §1.2 |
| `sub-manager add` | 手工粘贴原始订阅新增 | §1.2 |
| `sub-manager list` | 查看订阅、客户端归属与双向漂移 | §1.3 |
| `sub-manager update <编号>` | 源订阅 `subId` 变更后同步，地址不变 | §1.4 |
| `sub-manager rotate <编号>` / `--all` | 换随机路径 | §1.5 |
| `sub-manager remove <编号>` | 撤销订阅 | §1.5 |
| `sub-manager renumber <起始编号>` | 重排订阅编号，地址不变 | §1.9 |
| `sub-manager test [编号]` | 端到端验证全部或单条订阅 | §1.6 |
| `sub-manager resync` | 按现有状态重建 Nginx 配置 | §1.7 |

**不要手工编辑由脚本生成的 `/etc/nginx/conf.d/private-sub.conf`**；后续脚本运行会覆盖手工
更改。

### 1.1 状态文件与事务

订阅状态保存在：

```text
/etc/sub-manager/clients.json
```

该目录权限为 `0700`，状态文件权限为 `0600`，只允许 root 读取。当前 schema 为 `version: 2`，
每条订阅只有一个 `path` 字段。

编号（`sub-N`）只增不复用：状态文件用 `next_id` 记录下一个可用编号，删除不会回退它，所以
删掉当前最大号后，下一次新增也不会重新占用同一个编号。旧状态没有 `next_id` 时，按现有最大
编号加一初始化。需要重新编排时用 `sub-manager renumber <起始编号>`（§1.9）。

每次 `add`、`update`、`rotate`、`remove` 或 `resync` 都会：

1. 使用 `flock` 防止两个管理操作并发执行。
2. 在权限受限的临时目录生成候选状态和 Nginx 配置。
3. 使用独立 Nginx 测试配置预先检查语法。
4. 备份当前状态和 Nginx 配置。
5. 原子安装新文件，再执行系统级 `nginx -t`。
6. reload 失败时自动恢复原状态和原配置。

### 1.2 添加订阅

有两种来源，校验与落地流程完全相同，只是原始订阅地址从哪来不同。

**从 3x-ui 客户端中选择（推荐）：**

```bash
sub-manager add --from-xui
```

脚本只读查询 `/etc/x-ui/x-ui.db`，列出**还没有聚合地址的启用中客户端**，按面板备注显示：

```text
还没有聚合地址的 x-ui 客户端：

   1) 编号一
   2) 编号二
   3) 编号三

选择编号（直接回车取消）：
```

选中后原始订阅地址由 `subId` 推导为 `https://<域名>:<subPort><subPath><subId>`
（`subPort` / `subPath` 从 `settings` 表读，查不到即 3x-ui 默认值 `2096` / `/sub/`），
不必再从面板复制粘贴同一个值。

**手工粘贴（原始订阅不来自本机 3x-ui 时用）：**

```bash
sub-manager add
```

脚本提示输入时，粘贴对应的 3x-ui 原始订阅 URL。终端不会显示输入内容。

两种方式之后都一样：脚本会先验证原始订阅可访问且非空、本地 Subconverter 能生成 Clash
YAML、输出不含原始订阅 URL、新 Nginx 配置语法正确，再逐项检查模板未退化。完整校验清单见
§3.2.1。全部通过后自动分配类似 `sub-2` 的订阅编号，应用配置并打印订阅地址（已带订阅名
fragment，整条粘进客户端即可）。地址形态见 [README.md](README.md) §3.4，判定规则见
[unified-subscription.md](unified-subscription.md) §2。

> **面板增删客户端不会自动改动聚合地址。** 触发权在人手上：新增客户端后执行
> `add --from-xui`，删除客户端后 `list` 会把失去对应客户端的订阅标出来，由你决定是否
> `remove`。选择手工触发而不是定时器的理由见 §1.8。

### 1.3 查看订阅与漂移

```bash
sub-manager list
```

列表不显示完整原始订阅，而是显示订阅编号、所属客户端、脱敏后的原始订阅标识和该订阅的
地址：

```text
sub-N      客户端           <面板备注>
           原始订阅（脱敏） sub.example.com:2096 / …<末尾一段>
           订阅地址         https://...:8443/<随机路径>#<订阅名>
```

「客户端」一行取自 3x-ui 的客户端备注，为空时回落到 `email`。

末尾报告与 3x-ui 之间的**双向漂移**：

```text
⚠ 3 个 x-ui 客户端还没有聚合地址：编号一、编号二、编号三
  用 sub-manager add --from-xui 逐个补齐。

⚠ 1 条聚合地址在 x-ui 中已无对应客户端：sub-4
  确认后用 sub-manager remove <订阅编号> 撤销。
```

两边一一对应时打印「x-ui 客户端与聚合地址一一对应，无漂移」。

x-ui 没运行、没装 `sqlite3`、或 DB 读不到时，`list` **静默降级**为不带客户端名的旧输出，
并明确打印「本次未核对客户端」。它绝不会在读不到数据时谎报无漂移。原因见
[incidents.md](incidents.md) `2026-08-22 读 x-ui.db 偶发返回空`。

### 1.4 更新原始订阅

当某个 3x-ui 订阅的 `subId` 被重置时，按订阅编号更新：

```bash
sub-manager update sub-1
```

隐藏输入新的原始订阅后，脚本会重新验证并更新服务器配置。订阅地址保持不变，因此客户端
不需要重新添加订阅。

处置 `subId` 泄露：

1. 在 3x-ui 中重置对应客户端的 `subId` 或重新创建客户端。
2. 执行 `sub-manager update <订阅编号>`，例如 `sub-manager update sub-1`。
3. 隐藏输入新的原始订阅 URL。
4. 旧的原始订阅地址随 `subId` 重置失效；仍在直连它的客户端要改用聚合地址。

`subId` 重置后若忘了做第 2 步，`list` 会同时报两条漂移：新 `subId`「还没有聚合地址」，
旧地址「已无对应客户端」。两条同时出现且数量相等，通常就是漏做 `update` 而不是真的增删了
客户端。这种情况**不要**用 `remove` + `add --from-xui` 处理，那会换掉随机路径导致所有
设备重配；用 `update` 保持地址不变。

### 1.5 轮换与撤销

订阅地址泄露时换随机路径：

```bash
sub-manager rotate sub-1      # 换一条
sub-manager rotate --all      # 全换
```

只换随机路径，订阅编号与原始订阅保持不变，不需要重新输入订阅 URL。脚本会询问 `[y/n]`，
输入 `y` 才执行（大小写均可，直接回车即取消）。
执行后旧地址立即返回 404，**所有设备都要重新配置**。新地址会连同订阅名 fragment 一起打印
出来，整条粘贴即可（见 [README.md](README.md) §3.4）。

撤销一条订阅：

```bash
sub-manager remove sub-1
```

脚本会先打印该订阅的地址，再询问 `[y/n]`，输入 `y` 才删除（大小写均可，直接回车即取消）。
删除成功后，该订阅的地址立即返回 404，其他订阅不受影响。

> `rotate` / `remove` 作废的只是配置分发通道。客户端已经拉取的配置不会消失，里面的 VLESS
> UUID 仍然有效。要真正收回节点访问，去 3x-ui 面板删掉该客户端或更换 UUID。2096 未收口时，
> 拿到过聚合地址的人还能从原生分支的响应头读到 `subId`、直连原始订阅，所以
> 聚合地址泄露也要按 §1.4 一并重置 `subId`。细节见
> [unified-subscription.md](unified-subscription.md) §6。

### 1.6 测试

```bash
sub-manager test          # 全部订阅
sub-manager test sub-1    # 单条
```

测试覆盖源订阅可访问、本地转换成功，以及订阅入口的四项 UA 断言（见
[unified-subscription.md](unified-subscription.md) §7）。输出只报告订阅编号和通过/失败，
不打印原始 URL 或响应正文。

### 1.7 重建配置 resync

改动了转换参数（`CONVERT_OPTS`）、`base/all_base.tpl` 或 `snippets/*.txt` 之后，用它按现有
状态重新生成 Nginx 配置：

```bash
sub-manager resync
```

不需要重新输入任何原始订阅，订阅编号和地址均保持不变。走与 `add`/`update` 完全相同的事务
路径，见 §1.1。

没有订阅时，只要 `private-sub.conf` 存在，resync 照常按当前常量重建它；但状态文件缺失而
`private-sub.conf` 还在时拒绝执行，因为按空状态重建会让所有订阅地址失效。resync 不重新拉取
订阅，也不做 §3.2.1 的转换校验；改了模板或 snippets，resync 之后再执行 `sub-manager test`。

若改的是 subconverter 侧的模板或 snippets，**先重启再 resync**，`pref.ini` 的
`cache_config=300` 会缓存模板：

```bash
systemctl restart subconverter && sub-manager resync
```

### 1.8 与 3x-ui 的联动边界

`list` 和 `add --from-xui` 会**只读**查询 `/etc/x-ui/x-ui.db`（`sqlite3 -readonly` 加 URI
`mode=ro` 双保险）。本脚本对 x-ui、xray 与任何 `*.db` 保持**零写操作**。全脚本的
`systemctl` 只有 `reload nginx` 和三处 `is-active`（`x-ui` / `subconverter` / `nginx`）。

**不做自动同步的定时器**，触发权留在人手上，理由有三：

- **省不掉步骤，反而多一次等待。** 新增一个用户的流程是「面板加客户端 → `add --from-xui` → 当场拿到
  地址 → 发给对方」。改用定时器后变成「面板加客户端 → 等最多 1 分钟 → `list` → 查找 →
  复制 → 发给对方」，步数没少，还把「立即拿到地址」换成「稍后自己去查」。
- **触发源不对。** 新增客户端时操作者就在终端前，该驱动同步的事件是「敲了命令」，不是「过了
  60 秒」。客户端增删约每数天一次，为此每天空转 1440 次不成比例。
- **自动删除危险且误导。** 删聚合地址不等于收回节点访问。语义见 §1.5：`rotate` / `remove`
  只作废 Nginx 里的分发 location，UUID 仍在 443 上生效，真正收回访问要在面板删除 UUID。自动删只完成
  不生效的那一半，却制造
  「已经处理干净」的错觉；随机路径一旦因误判被销毁，重建必然是新路径，该用户的所有设备
  都要重新配置。

没有替代品的是**看见漂移**，而那是一个只读报告，不需要定时器。

### 1.9 重排编号

```bash
sub-manager renumber 101
```

按现有数字顺序把订阅重排为 `sub-101`、`sub-102`…，并把 `next_id` 设为重排后的下一个编号。
只改状态文件里的键，`path`、`source_url` 与节点都不变，**订阅地址不变，设备无需重配**。脚本
会先打印旧号 → 新号的对照，再询问 `[y/n]`，输入 `y` 才执行（直接回车取消）。

编号平时只增不复用，删除会留下空号。空号不影响任何功能，只是不再分配给新订阅；重排是一次
显式的重新编号，不应作为日常清理手段。

## 2. 更新自维护规则

**不需要在服务器执行任何命令。** push 之后多久能拉取到，取决于部署时是否加了 `--with-rules`
（判断方法见 [README.md](README.md) §2）：

```text
默认部署
  git push → GitHub（边缘缓存）→ Nginx 反代（本机缓存）→ Clash 客户端点「更新规则集」

--with-rules
  git push → sub-rules-sync.timer（每分钟）→ /var/lib/sub-rules/ → Clash 客户端点「更新规则集」
```

默认部署要等 GitHub 边缘缓存和本机缓存都过期才能拉取到新版本，延迟上限见 [design.md](design.md)
§9.1，期间单次拉取可能拿到旧版。服务器侧没有办法加速：GitHub 边缘缓存绕不过去，见
[incidents.md](incidents.md) `2026-08-19 「更新规则集」拿到的永远是上一版`。需要更快就启用
`--with-rules`。

启用 `--with-rules` 后，延迟上限 = 定时器周期 = **1 分钟**。想跳过这 1 分钟，可在服务器手工执行
一次 `sub-rules-sync`（幂等，随时可执行）。

Clash 客户端侧：`interval: 1800` 是**自动**刷新周期；手动点「更新规则集」（或
`PUT /providers/rules/ChinaDirect`）会绕过 interval 立即拉取。启用 `--with-rules` 时端点无缓存
层，**单次拉取一定拿到发布目录的当前内容**。

订阅内容完全不变（URL 恒定），因此**不需要**重启 subconverter，**不需要**重新添加订阅，
客户端 `providers/` 目录里文件名也恒定，不会累积孤儿文件。

诊断：

```bash
sub-rules-check      # 先判断部署方式，再核对对应的整条链
sub-rules-sync -v    # 仅 --with-rules：手工同步一次，打印结果
```

`sub-rules-check` 按部署方式选检查项：发布目录存在或定时器已启用，按 `--with-rules` 检查，
否则按默认部署检查。默认部署核对两个端点返回 `200`、`X-Rule-Source: github`、含规则行，且
内容与 GitHub 当前版本一致；push 后、缓存过期之前报不一致属正常。`--with-rules` 核对端点 =
发布目录 = git 工作副本 = origin/main，并报同步器健康度。

同步脚本用 `fetch` + `merge --ff-only`：`/root/code/shadowrocket-config` 是可能被直接编辑的
工作副本，有本地提交或未提交改动时**拒绝合并**而不是 `reset --hard` 销毁。此时
`sub-rules-check` 会报「同步已停滞」，需要人工处理工作副本。

## 3. 检查与验证

「正常」长什么样。`sub-manager test` 是它的自动化版本，本节是人工核对时的参照。

### 3.1 日常检查

服务状态：

```bash
systemctl is-active x-ui subconverter nginx
systemctl is-enabled x-ui subconverter nginx
```

端口：

```bash
ss -lntp | grep -E ':(80|443|2096|8443|25500)\b'
ss -lntp | grep x-ui                                      # 面板端口随面板设置变化
```

`2096` 默认监听所有地址。收口后（可选，见 [deploy.md](deploy.md) §3.5）应只出现
`127.0.0.1:2096`，订阅域名也要解析到回环地址，供 subconverter 回源：

```bash
getent hosts sub.example.com    # 收口后应返回 127.0.0.1
```

后端：

```bash
curl -fsS http://127.0.0.1:25500/version
```

配置校验：

```bash
nginx -t
```

订阅显示名称（两个分支由同一个常量生成，见 [README.md](README.md) §3.4）：

```bash
# Clash 分支：Content-Disposition 双写 filename / filename*
curl -ksS -o /dev/null -D - -H 'User-Agent: clash-verge/v2' \
  https://sub.example.com:8443/<随机路径> | grep -i disposition

# 原生分支：Profile-Title，base64: 前缀；解码后应与 PROFILE_NAME 一致
curl -ksS -o /dev/null -D - -H 'User-Agent: Shadowrocket/2' \
  https://sub.example.com:8443/<随机路径> | grep -i profile-title
```

错误日志：

```bash
journalctl -u subconverter.service -u nginx.service \
  --since today --no-pager
```

### 3.2 验证基线

**易变的数字不写死**：订阅个数以 `sub-manager list` 为准，配置行数随节点数和模板浮动。

#### 3.2.1 脚本自动校验的 11 项

`validate_source_and_conversion()` 在 `add`（含 `--from-xui`）和 `update` 时逐项检查，任一缺失
即拒绝应用配置；`sub-manager test` 对每条订阅执行同样的检查，用来在改模板之后发现退化：

- 策略组 `🚀节点选择` 存在
- 策略组数量恰好为 1
- `rule-providers:` 存在
- `RULE-SET,` 引用存在
- `enhanced-mode: fake-ip` 存在
- `respect-rules: true` 存在
- 全局 `ipv6: false` 存在
- `strict-route: true` 存在
- `dns-hijack:` 存在
- `profile.store-selected: true` 存在
- 节点名不含 `|📊` 流量后缀（确认 `rename` 生效）

`cmd_test_one` 对订阅入口另执行四项 UA 断言（见
[unified-subscription.md](unified-subscription.md) §7）。其中三项是本层独有、上面这份清单
覆盖不到的：`format: text`（由 Nginx `sub_filter` 注入，本地直出里没有）、`Profile-Title`
与 `Content-Disposition`（两个分支的订阅名，均由 `PROFILE_NAME` 生成，见
[README.md](README.md) §3.4）。

#### 3.2.2 转换输出应有的形态

```text
策略组          1 个，🚀节点选择 (select)，成员为全部节点 + DIRECT，DIRECT 在最后
proxies         type: vless
rule-providers  11 个（2 条自维护 + 9 条 ACL4SSR），全部带 format: text
rules 末两条    GEOIP,CN,DIRECT,no-resolve  /  MATCH,🚀节点选择
规则目标        只有 {🚀节点选择, DIRECT, REJECT} 三种
profile         store-selected: true
DNS             enhanced-mode: fake-ip，respect-rules: true，fake-ip-range 198.18.0.1/16
TUN             enable: true，strict-route: true，dns-hijack ['any:53', 'tcp://any:53']
全局            ipv6: false
行数            200 行以内（RULE-SET 模式；内联展开时代为 10000+ 行）
```

Reality 节点应包含的字段：

```yaml
type: vless
flow: xtls-rprx-vision
reality-opts:
  public-key: ...
  short-id: ...
servername: www.cloudflare.com
client-fingerprint: chrome
network: tcp
udp: true
```

#### 3.2.3 链路两端

原始 3x-ui 订阅：

- 默认监听所有地址；收口后（可选）只监听 `127.0.0.1`，公网不可达
- HTTP 200，`Content-Type: text/plain`
- 包含 `Subscription-UserInfo`（Clash Verge 的流量条靠它渲染）
- 正文为 Base64/通用节点订阅

公网 HTTPS 入口：

- HTTP 200，输出与本机转换结果一致
- 未知路径返回 404
- **原始 3x-ui 订阅路径未出现在返回内容中**

规则端点：`sub-rules-check` 全部通过。默认部署两个文件都是 `X-Rule-Source: github`，启用
`--with-rules` 时是 `X-Rule-Source: local`。

### 3.3 资源基线

```bash
systemctl show subconverter.service nginx.service \
  -p Id -p MemoryCurrent -p MemoryPeak
free -h
df -h /
```

| 服务 | 当前内存 | 峰值内存 |
|---|---:|---:|
| Subconverter | 约 2 MB | 约 3.5 MB |
| Nginx | 约 3.7 MB | 约 5.6 MB |

在 [design.md](design.md) §1 的验证环境上，部署完成时系统仍有约 965 MB available 内存，
根分区剩余约 15 GB。明显偏离这个量级时需要排查。

## 4. 备份范围

路径含义见 [README.md](README.md) §3.2。建议备份：

```text
/etc/sub-manager/clients.json
/usr/local/sbin/sub-manager
/usr/local/sbin/sub-rules-sync
/usr/local/sbin/sub-rules-check
/etc/nginx/conf.d/private-sub.conf
/etc/nginx/conf.d/sub-rules-cache.conf
/etc/nginx/conf.d/acme-challenge.conf
/etc/nginx/snippets/sub-rules.conf
/etc/nginx/snippets/sub-rules-common.conf
/etc/nginx/snippets/sub-rules-upstream.conf
/etc/systemd/system/sub-rules-sync.service
/etc/systemd/system/sub-rules-sync.timer
/etc/systemd/system/subconverter.service
/opt/subconverter-classic/pref.ini
/opt/subconverter-classic/base/all_base.tpl
/opt/subconverter-classic/snippets/rulesets.txt
/opt/subconverter-classic/snippets/groups.txt
/root/cert/sub.example.com/
/root/.acme.sh/
/etc/x-ui/x-ui.db
```

`/root/.acme.sh/` 含 ACME 账户私钥和续期配置，恢复后可继续自动续期；`/var/www/acme` 只是
挑战文件的临时落点，不需要备份。

`/opt/subconverter-classic` 可以从 Release 重新安装，但保留完整目录有利于快速恢复相同版本和
模板。
