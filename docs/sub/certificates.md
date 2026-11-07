# 证书与续期

这篇文档回答三个问题：这张证书给谁用、acme.sh 到底在做什么、能不能不要它。具体签发步骤
在 [deploy.md](deploy.md) §2.4；端口和路径以 [README.md](README.md) §3 为准。

## 1. 这张证书是做什么的

HTTPS 除了加密，还要向客户端证明「你连的确实是这个域名」。证书就是这个证明：客户端会检查
签发者是否受信任、证书上的域名是否匹配、有没有过期。三者任一不满足，客户端就会报证书错误，
订阅直接拉不下来。

本系统只有一个订阅域名，但同一对证书文件被三处共用（端口见 README §3.1）：

| 使用方 | 配置在哪 |
|---|---|
| 3x-ui 面板 HTTPS | 面板设置 `webCertFile` / `webKeyFile` |
| 3x-ui 原生订阅 HTTPS | 面板设置 `subCertFile` / `subKeyFile` |
| 聚合入口 HTTPS | `sub-manager` 的 `CERT_FILE` 常量 |

所以它不是一个「只有聚合层用」的附属文件。换掉或弄丢它，面板和 2096 也会一起出问题。

面板和原生订阅的这四处设置不由 `deploy.sh` 写入（脚本对 3x-ui 零写操作）。首次部署时在
3x-ui 面板里把 `webCertFile` / `webKeyFile` 和 `subCertFile` / `subKeyFile` 指到
`/root/cert/<域名>/fullchain.pem` 和 `privkey.pem`；改完再跑一次 `deploy.sh`，续期 hook
才会补上 `systemctl restart x-ui`（hook 按部署当时的面板设置生成，见 §2.2）。

为什么不能用自签名证书：浏览器和客户端默认不信任它。而且不只是外部客户端——服务器内部的
subconverter 和 `sub-manager` 通过回环地址访问 `https://<域名>:2096` 时同样校验证书链，
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
  -> 执行 reload hook，让 Nginx 和 3x-ui 重新加载证书
```

挑战文件由 Nginx 的 `acme-challenge.conf` 提供，所以这件事要求：**域名的 A/AAAA 记录指向
本机，且公网 80 端口可达**。签发源固定为 Let's Encrypt（`tools/deploy.sh` 里的
`--server letsencrypt`），因此不需要邮箱，也不受本机 acme.sh 默认 CA 的影响。acme.sh 里
已有一张有效证书时默认会直接复用；如果那张证书不是 Let's Encrypt 签发，脚本会强制重签
一次，让证书和后续续期都落到这个 CA 上。

### 2.2 续期是怎么自动发生的

acme.sh 安装时会在 root 的 crontab 里加一条任务，每天运行一次：

```text
58 22 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh
```

`--cron` 每次都只做检查，只有剩余有效期进入续期窗口（约 30 天）才真正签发。续期成功后执行
reload hook：

```text
systemctl restart x-ui || rc-service x-ui restart
systemctl reload nginx
```

两行都必要：面板/原生订阅由 x-ui 进程持有证书，聚合入口由 Nginx 持有。缺了 reload，文件换新
了但进程还在发旧证书，到期后照样报错。`deploy.sh` 在面板或原生订阅的证书路径指向本证书目录
时会把 restart 行补进 hook（读不到面板设置时同样补上）；不共用这张证书的部署只有 reload。

## 3. 为什么不能直接删掉

Let's Encrypt 证书有效期 90 天。即使 DNS 交给 Cloudflare，也不能省掉续期：只做 DNS 托管时，
域名直接解析到服务器公网 IP，TLS 在服务器上终结，Cloudflare 既不参与握手，也不会替源站
续期；把记录改成橙云代理后，客户端看到的虽然是 Cloudflare 的边缘证书，但 Cloudflare 回源时
仍要求源站有一张有效证书（Full / Full Strict），而且服务器内部回环访问 2096 的链路只认公网
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
- reload hook 丢失，文件已更新但进程仍在发旧证书。

如果只是 `/root/cert/<域名>/` 下的安装副本被删、而 acme.sh 自己目录里的证书仍在有效期内，
先把文件重新落盘，再重跑 `deploy.sh`，不需要等续期时间：

```bash
/root/.acme.sh/acme.sh --install-cert -d <域名> \
  --key-file /root/cert/<域名>/privkey.pem \
  --fullchain-file /root/cert/<域名>/fullchain.pem \
  --reloadcmd "systemctl restart x-ui || rc-service x-ui restart; systemctl reload nginx"
```

这一步要在重跑 `deploy.sh` 之前做：已有部署的 `/etc/nginx/conf.d/private-sub.conf` 仍引用
缺失的文件，直接重跑会先在 preflight 被拒绝（「现有 private-sub.conf 引用的证书缺失」）。
恢复时 `systemctl reload nginx` 可能因为配置尚未通过校验而报错，文件已经落盘，忽略后重跑
`deploy.sh` 即可。`--install-cert` 会覆盖
acme.sh 里保存的 reload hook，所以这里按 §2.2 把两行完整写回。

`/etc/hosts` 把订阅域名指到 `127.0.0.1` 不会影响签发：Let's Encrypt 从公网解析域名，不看
本机 hosts。它影响的是服务端自己回源原始订阅，见
[unified-subscription.md](unified-subscription.md) §6。

## 5. 几个常见误解

- **「Cloudflare 上已经有证书了」**：DNS-only 时无关；开启代理后也只覆盖客户端到 Cloudflare
  这一段，源站这一段仍需要证书。
- **「acme.sh 是订阅服务的一部分」**：不是。它只负责续期文件，订阅链路运行时完全不经过它。
- **「签发必须填邮箱」**：只有 ZeroSSL 的账户注册需要邮箱。签发源已经固定为 Let's Encrypt，
  邮箱变成可选，只作为 ACME 账户的联系方式。
- **「Nginx 会自己续期」**：不会。Nginx 只负责读取证书文件，续期由 acme.sh 的定时任务完成。
