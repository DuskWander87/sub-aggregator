# 从零部署

本文件是第一次安装或重装的操作路径。日常管理见 [operations.md](operations.md)，端口、路径和
转换参数以 [README.md](README.md) §3 为准。

## 1. 前提

- Ubuntu 24.04，具有 root 权限。
- 3x-ui 已运行，443 上有一个可用的 VLESS Reality 入站。2.x 与 v3 都支持：前者把客户端
  存在入站的 `settings` JSON 里，后者拆成 `clients` / `client_inbounds` 两张表，脚本按表
  结构自动选择查询。
- 域名已经指向这台服务器（签发证书需要公网 80 端口可达）。
- 依赖命令：`curl`、`jq`、`sqlite3`、`openssl`、`flock`、Nginx、systemd 等（`--with-rules` 时
  还有 `git`）。脚本一次性检查，缺失时列出命令和对应 apt 包，确认后执行 `apt-get update`
  和 `apt-get install -y`；正式部署时非交互且没加 `--yes`，打印可以直接复制的命令。
  `--dry-run` 只报告缺失项，不安装。
- 至少 2 GB 内存。

域名也不需要手工提供：脚本按已安装的 `sub-manager`、3x-ui 的 `subDomain` / `webDomain`、
3x-ui 记录的面板/订阅证书、`/root/cert` 下唯一的证书依次推导，都找不到时才询问。3x-ui 入站的
Reality SNI 是目标站域名，不会被采用；推导结果不对时用 `--domain` 覆盖。

证书不需要预先准备：脚本按 `/root/cert/<域名>/`、`/etc/letsencrypt/live/<域名>/`、
acme.sh 的安装记录依次查找；都没有时用 acme.sh 通过 Nginx webroot 自动签发到
`/root/cert/<域名>/`。想用自己的证书时把 `fullchain.pem` 和 `privkey.pem` 放进该目录；文件
不全且希望直接报错、而不是自动签发时加 `--no-issue-cert`。签发源、证书给谁用、续期怎么跑，
见 [certificates.md](certificates.md)。

还没有 3x-ui 底座，可以先看 [自建节点教程 3XUI 面板（无限芝士）](https://www.youtube.com/watch?v=TRVE7sVTgWw)。

## 2. 用部署脚本

部署只有一个入口：`tools/deploy.sh`，不需要其他工具或中间层。

### 2.1 一条命令

```bash
tools/deploy.sh
```

不带参数即可完成部署。脚本按下面的顺序执行，正常情况下只在打印摘要后停一次：

1. 检查 root 权限，读取已安装的 `sub-manager`、`sub-rules.conf` 和 `sub-rules-sync` 里的
   域名、证书目录、显示名、规则前缀和规则仓库，作为重装时的默认值。
2. 检查依赖命令。缺失时列出对应 apt 包，确认后安装；依赖先装好，后面的域名推导才用得上
   `sqlite3` 和 `openssl`。依赖齐全时不停顿。
3. 推导域名：已安装配置 → 3x-ui 的 `subDomain` / `webDomain` → 3x-ui 记录的面板/订阅证书 →
   `/root/cert` 下唯一的证书，都找不到时才询问。证书目录由域名推导。订阅显示名首次安装用
   默认 `DuskWander87`，重装沿用已安装的值；需要改时用 `--profile-name`。
4. 检查 x-ui 服务与数据库、443 入站、2096 监听、8443 端口和域名解析，并打印部署摘要。
   3x-ui 只读不写；443 入站或 2096 收口不符合预期时给出警告。
5. 确认后备份到 `/root/sub-aggregator-backup-<时间戳>-<pid>/`，把 `server/` 复制到临时目录
   并替换域名、证书目录、显示名、规则前缀和规则仓库。
6. 安装 subconverter、管理脚本、systemd 单元、Nginx 片段、兜底缓存目录和 ACME 挑战路径；
   重启 subconverter，校验并启动/重载 Nginx。
7. 签发或复用证书：缺少证书时安装 acme.sh、用 webroot 签发并安装到 `/root/cert/<域名>/`；
   然后按 [certificates.md](certificates.md) §2.2 对齐续期方式和 hook。部署过程中只 reload
   Nginx、不重启 x-ui；面板或原生订阅也用这张证书时，结束时提示手工重启 x-ui。
8. 如果加了 `--with-rules`，启用本机规则发布：规则仓库默认是作者的，工作副本不存在时
   自动克隆，然后启用同步定时器并跑一次 `sub-rules-check`。不加时 Clash 分支仍含规则表，
   两个自维护列表由服务端反代 GitHub 兜底。
9. 验证 x-ui / subconverter / nginx 状态、转换后端响应和 `nginx -t`，打印 3x-ui 面板地址
   和建订阅的后续步骤。验证不通过时给出警告、以非 0 退出，并明确说明哪一项没过；已安装的
   文件保留。

部署不创建订阅。订阅的前提是面板里已经有节点和客户端，这一步只能在面板里完成；脚本只
把入口和命令打印出来，不打断安装，也不向 3x-ui 写入任何东西。

脚本不会修改 3x-ui、Xray 或 443 入站，也不会改动你的仓库工作副本。2096 收口需要手工执行，
见 §3.5。

### 2.2 预演与无人值守

只检查、不改任何文件：

```bash
tools/deploy.sh --dry-run
```

`--dry-run` 打印推导到的域名、证书状态、规则配置和缺失依赖，然后退出；它不安装依赖，
也不签发证书。证书会显示为「复用已有」或「acme.sh 签发」。

`--yes` 跳过确认，适合无人值守执行。依赖缺失时会直接安装；域名推导失败时必须同时给出
`--domain`，否则非交互环境下无法继续：

```bash
tools/deploy.sh --domain sub.example.com --with-rules --yes
```

### 2.3 参数

| 参数 | 含义 |
|---|---|
| `--domain <域名>` | 订阅域名；省略时从 3x-ui 配置或证书推导 |
| `--cert-dir <目录>` | 证书目录；默认自动查找，缺失时签发到 `/root/cert/<域名>` |
| `--acme-email <邮箱>` | 可选：安装 acme.sh 时写入 ACME 账户联系邮箱 |
| `--no-issue-cert` | 缺少证书时不自动签发，直接报错 |
| `--profile-name <名称>` | 订阅显示名，纯 ASCII，默认 `DuskWander87` |
| `--rules-prefix <hex>` | 规则端点前缀，默认随机生成 24 位 hex |
| `--rules-repo <owner/repo>` | 规则仓库，默认 `DuskWander87/shadowrocket-config`；自定义时传 fork 的 owner/repo |
| `--rules-workdir <目录>` | 规则仓库的本机 git 工作副本，默认 `/root/code/shadowrocket-config` |
| `--with-rules` | 启用本机规则发布（克隆规则仓库并启动 `sub-rules-sync.timer`）；仓库默认是作者的 |
| `--dry-run` | 只打印计划，不做修改；不安装依赖、不签发证书 |
| `--yes` / `-y` | 跳过确认；依赖缺失时直接安装 |
| `--rollback <备份目录>` | 从备份目录恢复 |

重装时，脚本会从已安装的 `sub-manager`、`sub-rules.conf` 和 `sub-rules-sync` 里读取域名、
证书目录、显示名、规则前缀、规则仓库和工作副本，作为默认值；命令行参数优先。这样不会因为
重跑一次脚本就静默换掉规则端点。

### 2.4 证书与续期

证书目录默认是 `/root/cert/<域名>/`，里面只放两个文件：

```text
fullchain.pem    # 证书链（0644）
privkey.pem      # 私钥（0600）
```

脚本按以下顺序找证书，第一个可用的胜出：

1. `--cert-dir` 指定的目录。
2. `/root/cert/<域名>/`。
3. `/etc/letsencrypt/live/<域名>/`（certbot）。
4. acme.sh 的 `install-cert` 记录。
5. 都没有时自动签发到 `/root/cert/<域名>/`。

自动签发走 ACME HTTP-01：脚本安装 `/etc/nginx/conf.d/acme-challenge.conf`（监听 80，
`server_name` 是订阅域名），acme.sh 以 `--webroot /var/www/acme` 写入挑战文件，签发 EC-256
证书后用 `--install-cert` 落到证书目录。要求域名的 A/AAAA 记录指向本机、公网 80 端口可达。
acme.sh 未安装时脚本从 `https://get.acme.sh` 安装。

签发源、已有证书的复用与重签见 [certificates.md](certificates.md) §2.1；续期 hook 的组成、
续期方式对齐规则和 certbot 的处理见 §2.2。`--no-issue-cert` 只关掉自动签发：缺文件直接报错，
已有证书照常使用，续期方式照样对齐。

## 3. 手动部署

不用脚本时按下面做。脚本执行的是同一套步骤。

### 3.1 替换占位符

```bash
git clone https://github.com/DuskWander87/sub-aggregator.git
cd sub-aggregator
grep -rn 'sub.example.com\|<RULES_PREFIX>\|DuskWander\|shadowrocket-config' server/
```

| 值 | 含义 | 出现位置 |
|---|---|---|
| `sub.example.com` | 订阅域名 | `sub-manager`、`sub-rules-check`、`rulesets.txt`、`nginx/conf.d/acme-challenge.conf` |
| `<RULES_PREFIX>` | 规则端点前缀，可用 `openssl rand -hex 12` 生成 | `sub-rules.conf`、`rulesets.txt`、`sub-rules-check` |
| `/root/cert/sub.example.com/` | 证书目录 | `sub-manager` |
| `DuskWander` | 订阅显示名 | `sub-manager` 的 `PROFILE_NAME`（两个分支同源，不必改面板） |
| `DuskWander87/shadowrocket-config` | GitHub 兜底规则仓库 | `sub-rules.conf` |
| `/root/code/shadowrocket-config` | 规则仓库的本机工作副本 | `sub-rules-check`、`sub-rules-sync`、`sub-rules-sync.service` |

前 3 行必须换成你自己的值。后 3 行按你的显示名和规则仓库调整。订阅名保持纯 ASCII，两个
服务器侧分支由同一个常量派生，细节见 [README.md](README.md) §3.4。改完 `sub-manager` 里的常量后，把脚本重新装到
`/usr/local/sbin/`，再跑 `sub-manager resync`。

### 3.2 放置文件

```bash
# 转换后端。本仓库按 v0.9.9 验证，升级前先看上游变更。
curl -fL -o /tmp/subconverter.tar.gz \
  https://github.com/asdlokj1qpi233/subconverter/releases/download/v0.9.9/subconverter_linux64.tar.gz
install -d -m 0755 /opt/subconverter-classic
tar -xzf /tmp/subconverter.tar.gz --strip-components=1 -C /opt/subconverter-classic
install -d -m 0755 /opt/subconverter-classic/base /opt/subconverter-classic/snippets
cp -a server/subconverter/base/. /opt/subconverter-classic/base/
cp -a server/subconverter/snippets/. /opt/subconverter-classic/snippets/
install -m 0644 server/subconverter/pref.ini /opt/subconverter-classic/pref.ini

# 管理脚本与 systemd 单元
install -m 0700 server/sbin/sub-manager server/sbin/sub-rules-sync /usr/local/sbin/
install -m 0750 server/sbin/sub-rules-check /usr/local/sbin/
install -m 0644 server/systemd/subconverter.service \
  server/systemd/sub-rules-sync.service server/systemd/sub-rules-sync.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now subconverter

# Nginx 片段、兜底缓存目录与 ACME 挑战路径
install -m 0644 server/nginx/snippets/sub-rules*.conf /etc/nginx/snippets/
install -m 0644 server/nginx/conf.d/sub-rules-cache.conf /etc/nginx/conf.d/
install -m 0644 server/nginx/conf.d/acme-challenge.conf /etc/nginx/conf.d/
install -d -m 0755 /var/www/acme
install -d -m 0755 /var/cache/nginx
install -d -o www-data -g www-data -m 0700 /var/cache/nginx/sub-rules
nginx -t && systemctl reload nginx
```

没有现成证书时用 acme.sh 签发（`acme.sh` 未安装先执行 `curl https://get.acme.sh | sh`）：

```bash
/root/.acme.sh/acme.sh --issue -d sub.example.com --server letsencrypt \
  --webroot /var/www/acme --keylength ec-256
/root/.acme.sh/acme.sh --install-cert --ecc -d sub.example.com \
  --key-file /root/cert/sub.example.com/privkey.pem \
  --fullchain-file /root/cert/sub.example.com/fullchain.pem \
  --reloadcmd "systemctl reload nginx"
chmod 600 /root/cert/sub.example.com/privkey.pem
```

`acme-challenge.conf` 里的 `server_name` 要换成自己的域名；证书目录中的两个文件在 §3.1 的
替换表里也已经列出。

### 3.3 建第一条订阅

部署脚本最后会打印面板地址，形如 `https://sub.example.com:<面板端口>/<面板路径>/`。先在
面板里准备节点：

1. 登录面板，确认 443 上有一个可用的 VLESS Reality 入站（没有则新建）。
2. 在入站的客户端列表里添加客户端。客户端备注会显示在订阅里；可以加多个，一个客户端
   对应一条聚合订阅。

回到服务器创建聚合订阅：

```bash
curl -fsS http://127.0.0.1:25500/version
sub-manager add --from-xui
sub-manager test
```

`add --from-xui` 会列出还没有聚合地址的 3x-ui 客户端，选中后自动分配随机路径、生成 Nginx
配置并完成端到端验证。如果 3x-ui 的订阅服务不在同一个域名下，改用 `sub-manager add` 手工
粘贴原始订阅。

### 3.4 可选：本机发布规则

Clash 分支的订阅始终包含规则表。作者维护的
[DuskWander87/shadowrocket-config](https://github.com/DuskWander87/shadowrocket-config)
提供 `ChinaDirect.list` 和 `Reject.list` 两个自维护列表，规则内容可以直接在仓库里看到。
这两条 URL 指向本站 `8443`；没有本地发布目录时，服务端反代 GitHub 兜底提供，客户端仍然
只连本站。本节启用的是本地副本，不是「是否使用规则表」：本地发布能让更新延迟确定
（≤1 分钟），并在 GitHub 不可达时继续提供端点。为什么需要这一层，见
[design.md](design.md) §9.4。

手动部署时，把仓库克隆到默认工作副本路径，然后启用定时器：

```bash
git clone https://github.com/DuskWander87/shadowrocket-config.git /root/code/shadowrocket-config
install -d -m 0755 /var/lib/sub-rules
systemctl enable --now sub-rules-sync.timer
sub-rules-sync -v
sub-rules-check
```

用部署脚本时，加 `--with-rules` 启用本机发布。规则仓库默认就是作者的，工作副本不存在时
会自动克隆：

```bash
tools/deploy.sh --with-rules
```

要自己维护规则，fork [DuskWander87/shadowrocket-config](https://github.com/DuskWander87/shadowrocket-config)，
改 `rules/` 下的两个列表，然后在部署时指向你的 fork：

```bash
tools/deploy.sh --with-rules --rules-repo <你的账号>/shadowrocket-config
```

工作副本不在 `/root/code/shadowrocket-config` 时，再加 `--rules-workdir <目录>`。手动部署则
要改 `sub-rules-sync`、`sub-rules-check` 和 `sub-rules-sync.service` 里的 `REPO_DIR` /
`ReadWritePaths`，以及 `sub-rules.conf` 兜底里的仓库名。

工作副本的路径、发布目录和兜底缓存的设计见 [design.md](design.md) §9，日常更新见
[operations.md](operations.md) §2。

### 3.5 收口 2096

把 3x-ui 订阅服务限制到本机，同时让 subconverter 仍能按域名拉取原始订阅。部署脚本不会
修改 3x-ui，这一步手工执行：

1. 备份 `/etc/x-ui/x-ui.db`。
2. 在面板「设置 → 订阅 → Listen IP」填 `127.0.0.1`，或直接设置
   `settings.key = 'subListen'`，值为 `127.0.0.1`。修改后重启 x-ui；443 上的 Xray 会随之
   中断数秒。
3. 在 `/etc/hosts` 增加一行，把订阅域名解析到回环地址：

   ```text
   127.0.0.1 sub.example.com
   ```

4. 重启 subconverter，然后验证：

   ```bash
   ss -lntp | grep 2096     # 只应出现 127.0.0.1:2096
   getent hosts sub.example.com
   sub-manager test
   ```

没有第 3 步，Clash 分支会因 subconverter 连不上 2096 而报「本地转换失败」。回滚时把
`subListen` 清空并重启 x-ui，`/etc/hosts` 的映射可以保留。细节见
[unified-subscription.md](unified-subscription.md) §6。

## 4. 备份与回滚

脚本在覆盖前把目标文件备份到 `/root/sub-aggregator-backup-<时间戳>-<pid>/`，并生成
`restore.sh`。回滚：

```bash
tools/deploy.sh --rollback /root/sub-aggregator-backup-<时间戳>-<pid>
```

或者直接运行备份目录里的 `restore.sh`。回滚会恢复被覆盖的配置，删除本次新建的配置；不会
删除 `/etc/sub-manager/clients.json`。如果启用了规则定时器，回滚后手工执行：

```bash
systemctl disable --now sub-rules-sync.timer
```

## 5. 验证

```bash
systemctl is-active x-ui subconverter nginx
curl -fsS http://127.0.0.1:25500/version
sub-manager list
sub-manager test
nginx -t
/root/.acme.sh/acme.sh --list                     # 用 acme.sh 签发时：证书与下次续期时间
openssl x509 -in /root/cert/sub.example.com/fullchain.pem -noout -enddate
```

启用本机规则发布后再跑：

```bash
sub-rules-check
```

## 6. 卸载

只删除部署脚本写入的聚合层产物，一条命令、没有参数：

```bash
tools/uninstall.sh
```

脚本先打印计划（删什么、留什么、备份落点），再要求确认；需要在交互式终端里运行。确认后先
备份到 `/root/sub-aggregator-uninstall-backup-<时间戳>-<pid>/`，然后停止并禁用
`subconverter.service`、`sub-rules-sync.timer`，删除管理脚本、systemd 单元、本服务的 Nginx
配置、`/etc/sub-manager`、`/opt/subconverter-classic`、规则发布目录和缓存。

以下内容保持原样：

- 3x-ui、Xray、`/etc/x-ui/x-ui.db`、443 与 2096：卸载脚本对 x-ui 零读写。
- Nginx 包与运行中的进程：`deploy.sh` 只启动/重载 Nginx，是否由它安装无法可靠判断，删包
  会连 `/etc/nginx` 的其它配置一起清掉。卸载只移除本服务的配置文件，
  `nginx -t` 通过后 reload。确认 Nginx 只为本项目安装时再手工 `apt purge nginx`。
- 证书与 acme.sh，以及 `acme-challenge.conf` + `/var/www/acme`：后者是证书续期的 webroot
  链路，删掉会让续期静默失败。确定不再使用该证书时手工删除这两处，并执行
  `/root/.acme.sh/acme.sh --remove -d <域名>`。
- 规则仓库工作副本（默认 `/root/code/shadowrocket-config`）：git 仓库不属于安装产物。
- `/etc/hosts` 的 `127.0.0.1 <订阅域名>` 映射：属于 §3.5 的手工步骤，脚本只报告、不修改。

恢复：

```bash
/root/sub-aggregator-uninstall-backup-<时间戳>-<pid>/restore.sh
```

`restore.sh` 按原路径解包并重新启用服务。历史部署备份 `/root/sub-aggregator-backup-*` 不受
影响。

卸载不会收回节点访问：已拉取的 profile 里 UUID 仍然有效，真正踢人要去 3x-ui 删除或更换该
客户端的 UUID，见 [unified-subscription.md](unified-subscription.md) §6。

## 7. 常见问题

- **8443 被别的进程占用**：脚本会直接失败。先确认占用者，`ss -lntp | grep 8443`。
- **证书签发失败**：确认域名的 A/AAAA 记录指向本机、公网 80 端口可达（安全组 / 防火墙），
  且 `nginx -t` 通过。Let's Encrypt 对同一域名有频率限制，失败后不要连续重试。已有证书想
  手动放置时用 `--cert-dir` 指定目录，或加 `--no-issue-cert` 让脚本只检查。
- **通过 sudo 运行**：`sudo tools/deploy.sh` 需要签发证书时，脚本在做任何改动之前就拒绝，
  因为 acme.sh 在这种方式下拒绝签发。先 `sudo -i` 进入 root shell，再运行脚本。
- **续期失败**：`/root/.acme.sh/acme.sh --list` 看下次续期时间；确认
  `/etc/nginx/conf.d/acme-challenge.conf` 生效（`nginx -T | grep -A5 acme-challenge`），且
  Nginx worker 能读 `/var/www/acme`。续期方式不是 webroot 时重跑部署脚本，按
  [certificates.md](certificates.md) §2.2 对齐。
- **域名推导不对**：3x-ui 里配了多个证书或面板/订阅用了不同域名时，推导会停在第一个匹配项
  或退回询问。直接加 `--domain` 明确指定，不要依赖推导。
- **`add --from-xui` 读不到数据库**：确认 `x-ui.service` 在运行、`sqlite3` 已安装、
  `/etc/x-ui/x-ui.db` 可读。
- **`sub-manager test` 失败**：先看是原始订阅拉取失败还是 Clash 转换失败。域名、证书、
  2096 回源和 8443 入口都会影响结果，按 [operations.md](operations.md) §3.2 的验证基线逐层查。
- **规则端点 404**：先确认已经至少创建一条订阅，`sub-manager` 生成的 server 块才会包含
  `sub-rules.conf`。再确认发布目录和定时器状态，跑 `sub-rules-check`。
