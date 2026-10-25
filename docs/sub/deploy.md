# 从零部署

本文件是第一次安装或重装的操作路径。日常管理见 [operations.md](operations.md)，端口、路径和
转换参数以 [README.md](README.md) §3 为准。

## 1. 前提

- Ubuntu 24.04，具有 root 权限。
- 3x-ui 已运行，443 上有一个可用的 VLESS Reality 入站。
- 域名已经指向这台服务器（签发证书需要公网 80 端口可达）。
- 已安装 `curl`、`jq`、`sqlite3`、`openssl`、`flock`、`git`、Nginx 和 systemd。
  缺少时脚本会打印一条可以直接复制的 `apt-get install` 命令后退出。
- 至少 2 GB 内存。

证书不需要预先准备：脚本按 `/root/cert/<域名>/`、`/etc/letsencrypt/live/<域名>/`、
acme.sh 的安装记录依次查找；都没有时用 acme.sh 通过 Nginx webroot 自动签发到
`/root/cert/<域名>/`。想用自己的证书时把 `fullchain.pem` 和 `privkey.pem` 放进该目录；
文件不全且希望直接报错、而不是自动签发时加 `--no-issue-cert`。

还没有 3x-ui 底座，可以先看 [自建节点教程 3XUI 面板（无限芝士）](https://www.youtube.com/watch?v=TRVE7sVTgWw)。

## 2. 用部署脚本

部署只有一个入口：`tools/deploy.sh`，不需要其他工具或中间层。

### 2.1 先看计划

```bash
tools/deploy.sh --dry-run \
  --domain sub.example.com \
  --profile-name DuskWander
```

不带参数时脚本询问域名和订阅显示名（首次自动签发且没装 acme.sh 时还会问一个可留空的邮箱）；
证书目录由域名推导，规则前缀、规则仓库都有默认值。dry-run 只做检查并打印计划，不改任何
文件。证书会显示为「复用已有」或「acme.sh 签发」。

### 2.2 执行

```bash
tools/deploy.sh --domain sub.example.com --profile-name DuskWander
```

默认每一步都会停下来确认。全参数加 `--yes` 可跳过确认；再配 `< /dev/null` 让脚本跳过创建
订阅，适合无人值守执行：

```bash
tools/deploy.sh --domain sub.example.com --profile-name DuskWander \
  --with-rules --yes < /dev/null
```

确认计划后，脚本会：

1. 检查 root、依赖命令、x-ui 服务与数据库、443 入站、2096 监听、8443 端口和域名解析。
   3x-ui 只读不写；443 入站或 2096 收口不符合预期时给出警告。
2. 把 `server/` 复制到临时目录，替换域名、证书目录、显示名、规则前缀和规则仓库。
3. 把要覆盖的文件备份到 `/root/sub-aggregator-backup-<时间戳>-<pid>/`。
4. 安装 subconverter、管理脚本、systemd 单元、Nginx 片段和 ACME 挑战路径。
5. 重启 subconverter，校验并启动/重载 Nginx。
6. 缺少证书时安装 acme.sh、用 webroot 签发到 `/root/cert/<域名>/`；已有 acme.sh 配置是
   standalone 时改成 webroot，并确保续期后 reload Nginx（见 §2.4）。
7. 询问是否创建第一条订阅。创建后自动跑 `sub-manager test`。
8. 如果加了 `--with-rules`，默认使用作者的规则集，工作副本不存在时自动克隆，然后启用同步
   定时器并跑一次 `sub-rules-check`。

非交互执行（`< /dev/null`）会跳过第 7 步，之后手工运行 `sub-manager add --from-xui` 和
`sub-manager test`。

脚本不会修改 3x-ui、Xray 或 443 入站，也不会改动你的仓库工作副本。2096 收口需要手工执行，
见 §3.5。

### 2.3 参数

| 参数 | 含义 |
|---|---|
| `--domain <域名>` | 订阅域名 |
| `--cert-dir <目录>` | 证书目录；默认自动查找，缺失时签发到 `/root/cert/<域名>` |
| `--acme-email <邮箱>` | 首次安装 acme.sh 时注册账户用，可留空 |
| `--no-issue-cert` | 缺少证书时不自动签发，直接报错 |
| `--profile-name <名称>` | 订阅显示名，纯 ASCII，默认 `sub-aggregator` |
| `--rules-prefix <hex>` | 规则端点前缀，默认随机生成 24 位 hex |
| `--rules-repo <owner/repo>` | 规则仓库，默认 `DuskWander87/shadowrocket-config`；自定义时传 fork 的 owner/repo |
| `--rules-workdir <目录>` | 规则仓库的本机 git 工作副本，默认 `/root/code/shadowrocket-config` |
| `--with-rules` | 启用 `sub-rules-sync.timer`；默认使用作者的规则集 |
| `--dry-run` | 只打印计划，不做修改 |
| `--yes` / `-y` | 跳过逐步确认 |
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
证书后用 `--install-cert` 落到证书目录，并设置续期后 `systemctl reload nginx`。要求域名的
A/AAAA 记录指向本机、公网 80 端口可达。acme.sh 未安装时脚本从 `https://get.acme.sh` 安装，
`--acme-email` 可指定注册邮箱（留空也能签发）。

续期由 acme.sh 自带的 cron 任务执行，`acme.sh --list` 看下次时间。已有配置如果是 standalone
（`Le_Webroot='no'`），脚本会改成 webroot，原文件保留为 `.conf.orig`：standalone 续期要独占
80 端口，而 Nginx 已经占用 80。注意续期后 Nginx 必须 reload，否则它一直发旧证书；脚本会把
`systemctl reload nginx` 追加到 acme.sh 原有的 reload hook 后面（3x-ui 自签的配置里通常已有
`systemctl restart x-ui`）。如果之后在 3x-ui 面板里重新申请证书导致配置退回 standalone，重跑
一次 `tools/deploy.sh` 即可。

不想让脚本碰证书时加 `--no-issue-cert`：缺文件直接报错，已经存在的证书照常使用；脚本仍会
修正 acme.sh 的续期方式，因为 Nginx 接管 80 端口后 standalone 续期必然失败。

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
| `DuskWander` | 订阅显示名 | `sub-manager`，同时要改 3x-ui 面板的「订阅标题」 |
| `DuskWander87/shadowrocket-config` | GitHub 兜底规则仓库 | `sub-rules.conf` |
| `/root/code/shadowrocket-config` | 规则仓库的本机工作副本 | `sub-rules-check`、`sub-rules-sync`、`sub-rules-sync.service` |

前 3 行必须换成你自己的值。后 3 行按你的显示名和规则仓库调整。订阅名保持纯 ASCII，三处要
一致，细节见 [README.md](README.md) §3.4。改完 `sub-manager` 里的常量后，把脚本重新装到
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

# Nginx 片段与 ACME 挑战路径
install -m 0644 server/nginx/snippets/sub-rules*.conf /etc/nginx/snippets/
install -m 0644 server/nginx/conf.d/sub-rules-cache.conf /etc/nginx/conf.d/
install -m 0644 server/nginx/conf.d/acme-challenge.conf /etc/nginx/conf.d/
install -d -m 0755 /var/www/acme
nginx -t && systemctl reload nginx
```

没有现成证书时用 acme.sh 签发（`acme.sh` 未安装先执行 `curl https://get.acme.sh | sh`）：

```bash
acme.sh --issue -d sub.example.com --webroot /var/www/acme --keylength ec-256
acme.sh --install-cert -d sub.example.com \
  --key-file /root/cert/sub.example.com/privkey.pem \
  --fullchain-file /root/cert/sub.example.com/fullchain.pem \
  --reloadcmd "systemctl reload nginx"
chmod 600 /root/cert/sub.example.com/privkey.pem
```

`acme-challenge.conf` 里的 `server_name` 要换成自己的域名；证书目录中的两个文件在 §3.1 的
替换表里也已经列出。

### 3.3 建第一条订阅

```bash
curl -fsS http://127.0.0.1:25500/version
sub-manager add --from-xui
sub-manager test
```

`add --from-xui` 会列出还没有聚合地址的 3x-ui 客户端，选中后自动分配随机路径、生成 Nginx
配置并完成端到端验证。如果 3x-ui 的订阅服务不在同一个域名下，改用 `sub-manager add` 手工
粘贴原始订阅。

### 3.4 可选：规则链

规则集使用作者维护的 [DuskWander87/shadowrocket-config](https://github.com/DuskWander87/shadowrocket-config)，
`rules/` 下有 `ChinaDirect.list` 和 `Reject.list` 两个列表。规则内容可以直接在仓库里看到。

手动部署时，把仓库克隆到默认工作副本路径，然后启用定时器：

```bash
git clone https://github.com/DuskWander87/shadowrocket-config.git /root/code/shadowrocket-config
install -d -m 0755 /var/lib/sub-rules
systemctl enable --now sub-rules-sync.timer
sub-rules-check
```

用部署脚本时，加 `--with-rules` 即可。脚本默认使用作者的规则集，工作副本不存在时会自动克隆：

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
acme.sh --list                                    # 用 acme.sh 签发时：证书与下次续期时间
openssl x509 -in /root/cert/sub.example.com/fullchain.pem -noout -enddate
```

规则链启用后再跑：

```bash
sub-rules-check
```

## 6. 常见问题

- **8443 被别的进程占用**：脚本会直接失败。先确认占用者，`ss -lntp | grep 8443`。
- **证书签发失败**：确认域名的 A/AAAA 记录指向本机、公网 80 端口可达（安全组 / 防火墙），
  且 `nginx -t` 通过。Let's Encrypt 对同一域名有频率限制，失败后不要连续重试。已有证书想
  手动放置时用 `--cert-dir` 指定目录，或加 `--no-issue-cert` 让脚本只检查。
- **续期失败**：`acme.sh --list` 看下次续期时间；确认 `/etc/nginx/conf.d/acme-challenge.conf`
  生效（`nginx -T | grep -A5 acme-challenge`），且 Nginx worker 能读 `/var/www/acme`。原来由
  3x-ui 用 standalone 签发的证书，重跑部署脚本会自动改成 webroot。
- **`add --from-xui` 读不到数据库**：确认 `x-ui.service` 在运行、`sqlite3` 已安装、
  `/etc/x-ui/x-ui.db` 可读。
- **`sub-manager test` 失败**：先看是原始订阅拉取失败还是 Clash 转换失败。域名、证书、
  2096 回源和 8443 入口都会影响结果，按 [operations.md](operations.md) §3.2 的验证基线逐层查。
- **规则端点 404**：先确认已经至少创建一条订阅，`sub-manager` 生成的 server 块才会包含
  `sub-rules.conf`。再确认发布目录和定时器状态，跑 `sub-rules-check`。
