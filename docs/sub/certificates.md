# 证书与续期

这篇文档回答三个问题：这张证书给谁用、acme.sh 到底在做什么、能不能不要它。具体签发步骤
在 [deploy.md](deploy.md) §2.4；端口和路径以 [README.md](README.md) §3 为准。

## 1. 这张证书是做什么的

HTTPS 除了加密，还要向客户端证明「你连的确实是这个域名」。证书就是这个证明：客户端会检查
签发者是否受信任、证书上的域名是否匹配、有没有过期。三者任一不满足，客户端就会报证书错误，
订阅无法拉取。

本系统只有一个订阅域名，但同一对证书文件被三处共用（端口见 README §3.1）：

| 使用方 | 配置在哪 |
|---|---|
| 3x-ui 面板 HTTPS | 面板设置 `webCertFile` / `webKeyFile` |
| 3x-ui 原生订阅 HTTPS | 面板设置 `subCertFile` / `subKeyFile` |
| 聚合入口 HTTPS | `sub-manager` 的 `CERT_FILE` 常量 |

所以它不是一个「只有聚合层用」的附属文件。替换或丢失这对文件，面板和 2096 也会一起出问题。

面板和原生订阅的这四处设置在 3x-ui 面板里配置，`deploy.sh` 不写（脚本对 3x-ui 零写操作）：
把 `webCertFile` / `webKeyFile` 和 `subCertFile` / `subKeyFile` 指到
`/root/cert/<域名>/fullchain.pem` 和 `privkey.pem`。配置后重新运行 `deploy.sh`，原因见 §2.2。

为什么不能用自签名证书：浏览器和客户端默认不信任它。而且不只是外部客户端，服务器内部的
subconverter 和 `sub-manager` 按订阅域名访问 `https://<域名>:2096` 时同样校验证书链，
自签名证书和私有 CA 都会让这条内部链路失败。

## 2. acme.sh 是什么

`acme.sh` 是一个**纯 shell 写的 ACME 客户端**，用来自动向 Let's Encrypt 申请和续期证书。
它有几个容易误解的特点：

- 不是常驻服务。没有端口、没有 systemd 单元，平时不运行；
- 不参与订阅分发。订阅请求不会经过它，删掉它订阅照常工作，直到证书过期；
- 只在两个时机被调用：`deploy.sh` 第一次签发时，以及 cron 每天检查是否该续期时。

### 2.1 它做一次签发要经过什么

```text
acme.sh --issue
  -> 在 Nginx 的 80 端口挑战路径写入一个随机文件（webroot = /var/www/acme）
  -> Let's Encrypt 从公网访问 http://<域名>/.well-known/acme-challenge/<随机值> 校验
  -> 校验通过，签发证书
  -> acme.sh --install-cert 把文件落到 /root/cert/<域名>/
  -> 首次安装只 reload Nginx；续期时执行完整 hook（§2.2）
```

挑战文件由 Nginx 的 `acme-challenge.conf` 提供，所以这件事要求：**域名的 A/AAAA 记录指向
本机，且公网 80 端口可达**。

- **签发源**：固定为 Let's Encrypt（`tools/deploy.sh` 里的 `--server letsencrypt`），不受
  本机 acme.sh 默认 CA 的影响。上游默认 CA 是 ZeroSSL，注册账户需要邮箱；Let's Encrypt 不
  需要，`--acme-email` 只作为 ACME 账户的联系方式，可以不填。
- **复用已有证书**：acme.sh 里已有一张有效证书时直接复用。判断它是否来自 Let's Encrypt
  正式环境，看 acme.sh 存储的证书本身的签发者，不看 conf 里的 `Le_API`；不是时强制重签
  一次，让证书和后续续期都落到这个 CA 上。staging 证书也会被重签。
- **重签失败**：脚本把 acme.sh 的续期配置还原为部署前的版本并中止，现有证书不变。确认域名
  解析和 80 端口后重新运行；不想换 CA 时按 §4 把现有证书装到证书目录，加 `--no-issue-cert` 重新运行。
- **sudo**：通过 `sudo tools/deploy.sh` 直接运行时，acme.sh 会拒绝签发；需要签发时脚本在
  preflight 就拒绝，不备份、不安装任何聚合层文件（缺依赖时依赖已在这之前安装），并提示先
  `sudo -i` 进入 root shell。

acme.sh 的 conf 不能当作证书来源的证据：跳过签发时它不写 conf，签发失败时却已在下单前写了
`Le_API` / `Le_Webroot`。原因见 [incidents.md](incidents.md)
`2026-11-07 复用 acme.sh 已有证书时，续期配置与实际证书不一致`。

### 2.2 续期是怎么自动发生的

acme.sh 安装时会在 root 的 crontab 里加一条任务，每天运行一次：

```text
58 22 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh
```

`--cron` 每次都只做检查，只有剩余有效期进入续期窗口（约 30 天）才真正签发。续期成功后执行
acme.sh conf 里保存的 reload hook。`deploy.sh` 按下面的规则组成它：

1. 保留原有命令（3x-ui 自己签发过的配置里通常已有 `x-ui restart`）；
2. 补上 `systemctl reload nginx`；
3. 面板或原生订阅的证书指向本证书目录、或读不到面板设置时，原有命令里没有 x-ui 重启
   （`x-ui restart` 或 `systemctl restart x-ui` 都算）才补上
   `systemctl restart x-ui || rc-service x-ui restart`；
4. 原有命令以第 3 条的那条重启开头、后面另有 x-ui 重启时，去掉开头那条，x-ui 只重启一次。

典型结果：

```text
# 证书由 deploy.sh 新签发，面板或原生订阅也用这张证书
systemctl restart x-ui || rc-service x-ui restart; systemctl reload nginx
# 证书由 3x-ui 签发过（原有命令是 x-ui restart）
x-ui restart; systemctl reload nginx
```

两部分都必要：面板/原生订阅由 x-ui 进程持有证书，聚合入口由 Nginx 持有。缺了 reload，文件换新
了但进程还在发旧证书，到期后仍会报错。hook 按部署当时的面板设置生成，所以面板证书路径改过
之后要重新运行 `deploy.sh`。

`--install-cert` 会立即执行传入的 hook。部署过程中脚本只传 `systemctl reload nginx`，不重启
x-ui、不影响 443；完整 hook 在安装之后写回 acme.sh 的 conf，续期时才执行。面板或原生订阅用的
正是这张证书时，部署结束会提示手工 `systemctl restart x-ui`。

**续期方式对齐。**证书安装之后，脚本按 acme.sh conf 的 `Le_Webroot` 对齐续期方式：Nginx 已经
占用 80 端口，standalone / alpn 这类独占端口的方式续期必然失败。

| `Le_Webroot` | 处理 |
|---|---|
| `/var/www/acme` | 不改写 |
| `dns` / `dns_*` | 不改写（DNS 验证不经过 80 端口） |
| 含逗号（多个方式组合） | 警告，不改写 |
| `no`（standalone）、`alpn`、`apache`、`stateless`、`nginx`、`nginx:*`、其他目录 | 原文件保留为 `.conf.orig`，改为 `/var/www/acme` |
| 其他 | 警告「未识别」，不改写 |

证书还包含其他域名（`Le_Alt` 不是 `no`）时不改写，只警告：80 端口的挑战路径只服务订阅域名，
改成 webroot 会让其余域名的验证失败。证书本身已由 Let's Encrypt 签发、而 conf 的 `Le_API` 仍
指向别的 CA 时，脚本把 `Le_API` 对齐为 Let's Encrypt，否则 cron 会向旧 CA 续期。

只有 acme.sh 的安装记录（`Le_RealFullChainPath` / `Le_RealKeyPath`）指向本证书目录时才对齐
并写 hook。证书安装到别的目录时，脚本只警告：那份证书续期后不会更新 Nginx 用的文件。同一域名
在 acme.sh 里同时有 RSA 与 ECC 两份配置时，脚本只管理 ECC 那份，并提示清理 RSA 那份。之后在
3x-ui 面板里重新申请证书导致配置退回 standalone，重新运行一次 `deploy.sh` 即可。

**certbot。**证书目录在 `/etc/letsencrypt/live/<域名>/` 时，续期由 certbot 负责。脚本安装
deploy hook `/etc/letsencrypt/renewal-hooks/deploy/sub-aggregator.sh`，内容按上面同样的规则
包含 reload Nginx 和（需要时的）x-ui 重启。certbot 每续期一张证书都会执行这个目录下的全部
脚本，hook 先比较 `$RENEWED_LINEAGE`，只在本证书续期时动作。续期方式只检查、不改：
`/etc/letsencrypt/renewal/<名称>.conf` 是 `authenticator = standalone`，或 webroot 不是
`/var/www/acme` 时，脚本警告并给出命令：

```bash
certbot reconfigure --cert-name <名称> --webroot -w /var/www/acme
```

## 3. 为什么不能直接删掉

Let's Encrypt 证书有效期 90 天。即使 DNS 交给 Cloudflare，也不能省掉续期：只做 DNS 托管时，
域名直接解析到服务器公网 IP，TLS 在服务器上终结，Cloudflare 既不参与握手，也不会替源站
续期；把记录改成橙云代理后，客户端看到的虽然是 Cloudflare 的边缘证书，但 Cloudflare 回源时
仍要求源站有一张有效证书（Full / Full Strict），而且服务器内部访问 2096 的链路只认公网
CA。Cloudflare 的 Origin CA 证书虽然能签 15 年，但默认不被系统信任库接受，要额外把它的根
证书装进系统，复杂度比定时续期更高。

可行的替代方案只有换一套续期器，而不是不要续期：

| 方案 | 说明 |
|---|---|
| 保留 acme.sh | 部署脚本会安装，cron 和 reload hook 一并配好，日常零维护 |
| 换 certbot | `deploy.sh` 已支持 `/etc/letsencrypt/live/<域名>/`，但 3x-ui 的四个证书设置仍指向 `/root/cert/`，需要额外的拷贝和重启步骤 |
| 用面板申请证书 | 面板负责签发，但续期和 reload 仍要有人管；同时要确认只有一套机制在写同一对证书文件 |

删掉 acme.sh 后的时间线很直接：现有证书继续可用到到期日，然后面板、2096、8443 同时开始报
证书错误，没有任何东西会自动补上。

## 4. 怎么确认它在工作

```bash
/root/.acme.sh/acme.sh --list                      # CA、签发时间、下次续期时间
openssl x509 -in /root/cert/<域名>/fullchain.pem -noout -enddate   # 实际到期时间
crontab -l | grep acme                             # 续期任务是否存在
systemctl is-active x-ui nginx subconverter        # 使用证书的服务
```

续期失败最常见的原因是环境变化，而不是 acme.sh 本身：

- 域名的 A/AAAA 记录不再指向本机，或公网 80 端口不通；
- `/etc/nginx/conf.d/acme-challenge.conf` 被删掉，或 `/var/www/acme` 不可写；
- acme.sh conf 的 `Le_Webroot` 是 `no`（standalone）：Nginx 占着 80 端口，每次续期都报
  `tcp port 80 is already used`；
- reload hook 丢失，文件已更新但进程仍在发旧证书。

cron 任务把输出丢进 `/dev/null`，续期失败不会留下任何痕迹。怀疑续期有问题时手工执行一次，
看它停在哪一步：

```bash
/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
```

续期方式不对时重新运行 `deploy.sh`，它按 §2.2 对齐为 webroot；证书已经过期时它会同时重签。

如果只是 `/root/cert/<域名>/` 下的安装副本被删、而 acme.sh 自己目录里的证书仍在有效期内，
先把文件重新落盘，再重新运行 `deploy.sh`，不需要等续期时间：

```bash
/root/.acme.sh/acme.sh --install-cert --ecc -d <域名> \
  --key-file /root/cert/<域名>/privkey.pem \
  --fullchain-file /root/cert/<域名>/fullchain.pem \
  --reloadcmd "systemctl restart x-ui || rc-service x-ui restart; systemctl reload nginx"
```

这一步要在重新运行 `deploy.sh` 之前做：已有部署的 `/etc/nginx/conf.d/private-sub.conf` 仍引用
缺失的文件，直接重新运行会先在 preflight 被拒绝（「现有 /etc/nginx/conf.d/private-sub.conf 引用的
证书缺失：<证书目录>。按 docs/sub/certificates.md §4 把证书重新落盘后重新运行。」）。
恢复时 `systemctl reload nginx` 可能因为配置尚未通过校验而报错，文件已经落盘，忽略后重新运行
`deploy.sh` 即可。`--install-cert` 会覆盖
acme.sh 里保存的 reload hook，所以这里按 §2.2 把完整 hook 写回。这条命令会立即执行 hook，
x-ui 会重启，443 中断几秒。

`/etc/hosts` 把订阅域名指到 `127.0.0.1` 不会影响签发：Let's Encrypt 从公网解析域名，不看
本机 hosts。它影响的是服务端自己回源原始订阅，见
[unified-subscription.md](unified-subscription.md) §6。

## 5. 几个常见误解

- **「Cloudflare 上已经有证书了」**：DNS-only 时无关；开启代理后也只覆盖客户端到 Cloudflare
  这一段，源站这一段仍需要证书。
- **「acme.sh 是订阅服务的一部分」**：不是。它只负责续期文件，订阅链路运行时完全不经过它。
- **「签发必须填邮箱」**：不需要，签发源固定为 Let's Encrypt，见 §2.1。
- **「Nginx 会自己续期」**：不会。Nginx 只负责读取证书文件，续期由 acme.sh 的定时任务完成。
