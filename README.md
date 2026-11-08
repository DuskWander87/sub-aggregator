# sub-aggregator

> 给 3x-ui 加一层订阅聚合。同一条订阅地址，Clash/Mihomo 拿到带规则集的完整配置，Shadowrocket/v2rayN 只拿节点，转换在你自己的服务器上完成。

[![License: MIT](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)](LICENSE)
[![3x-ui](https://img.shields.io/badge/base-3x--ui-2F6FEB?style=flat-square)](https://github.com/MHSanaei/3x-ui)
[![Clash / Mihomo](https://img.shields.io/badge/client-Clash%20%2F%20Mihomo-7B61FF?style=flat-square)](https://github.com/MetaCubeX/mihomo)
[![Docs](https://img.shields.io/badge/docs-zh-555?style=flat-square)](docs/sub/README.md)

3x-ui 的原生订阅是一串 Base64 编码的节点，Shadowrocket、v2rayN 能直接用，Clash 客户端不认。第三方转换服务能把格式对上，代价是原始订阅地址要交给别人。转换和规则集都落在别人的服务器上，服务停不停、规则什么时候更新，你控制不了。同一个人的手机和电脑还常常各配一条订阅，换个客户端就要重新找地址。

sub-aggregator 装在 3x-ui 所在的服务器上，把转换收回本机。一个人的所有设备共用一条 HTTPS 订阅地址，Nginx 按 `User-Agent` 识别客户端，返回不同的内容：

| 客户端 | 拿到什么 |
|---|---|
| Clash/Mihomo 系，如 Clash Verge、ClashMi、ClashMetaForAndroid | 本机转换的完整配置：节点、一个手动选择的策略组、防 DNS 泄漏配置和规则集 |
| Shadowrocket、v2rayN 和其他客户端 | 3x-ui 原生订阅原样转发，只有节点，没有规则集、策略组和 DNS 设置 |

转换时会去掉 3x-ui 追加在节点名末尾的剩余流量（`|📊…`），名字不随流量变化，Clash 更新订阅后还记得你选的是哪个节点。原生订阅不做任何改动，所以 Shadowrocket 里的节点名仍带着剩余流量。

## 快速开始

### 1. 准备

- 一台 Ubuntu 24.04 服务器，装好了 3x-ui，443 上有一个能用的 VLESS Reality 入站。需要 root 权限和至少 2 GB 内存，不需要 Docker。
- 一个解析到这台服务器的域名。没有证书时脚本会用 Let's Encrypt 签发，要求公网能访问 80 端口。
- 一个空闲端口留给订阅入口，默认 `8443`（443 已被 Reality 占用），并在防火墙 / 云安全组放行 TCP 入站。

### 2. 部署

```bash
git clone https://github.com/DuskWander87/sub-aggregator.git
cd sub-aggregator
tools/deploy.sh               # 加 --dry-run 只看计划，不改任何文件
```

脚本会自己推导域名、找证书，没有证书就签发一张，之后由 acme.sh 自动续期。缺依赖时先问你要不要装，打印部署摘要后再确认一次才动手，覆盖文件前都会先备份。

`8443` 被占用时加 `--port <端口>` 换一个。端口会写进每条订阅地址，装好后再改，所有设备都要重新导入。

装好后建议再手工做一步：把 3x-ui 的订阅服务（默认 2096 端口）改成只监听本机，原始订阅地址在公网上就访问不到了。部署脚本不碰 3x-ui，步骤见 [deploy.md](docs/sub/deploy.md) §3.5。全部参数、手动部署和回滚也在这份文档里。

### 3. 建订阅，导入客户端

部署不会替你建订阅。先在 3x-ui 面板的入站里添加客户端，一个客户端对应一条订阅，再回到服务器：

```bash
sub-manager add --from-xui    # 从面板里还没有订阅的客户端中选一个
sub-manager test              # 检查全部订阅是否正常
```

`add` 最后会打印订阅地址：

```text
https://<域名>:8443/<48 位随机 hex>#<订阅名>
```

整条复制到客户端里添加订阅，Clash 和 Shadowrocket 用的是同一条。末尾的 `#<订阅名>` 只给 Shadowrocket 显示名字用，不会发到服务器。

冷门 Clash 客户端的 `User-Agent` 可能识别不出来，会拿到原生订阅。这时在 `#` 前加 `?t=clash` 强制返回 Clash 配置，比如 `https://<域名>:8443/<随机路径>?t=clash#<订阅名>`。反过来，`?t=raw` 强制返回原生订阅。

## 日常操作

```bash
sub-manager list              # 列出订阅地址，以及和面板客户端的对应关系
sub-manager add --from-xui    # 面板里加了客户端，给它建订阅
sub-manager update sub-1      # 面板里重置了 subId，订阅地址不变
sub-manager rotate sub-1      # 地址泄露，换一条新地址，设备要重新导入
sub-manager remove sub-1      # 删除订阅
sub-manager test              # 检查全部订阅
```

面板里增删客户端不会自动同步过来。加了人要再跑一次 `add --from-xui`；删了人，`list` 会标出哪些订阅已经没有对应的客户端。每条命令的细节见 [operations.md](docs/sub/operations.md)。

## 规则集只对 Clash 生效

Shadowrocket、v2rayN 从订阅拿到的只有节点，分流由它们自己的配置决定。Clash 配置则引用 11 个规则集：9 个来自 [ACL4SSR](https://github.com/ACL4SSR/ACL4SSR)，客户端经 jsDelivr 拉取；另外 2 个是作者自维护的 [`ChinaDirect.list` 和 `Reject.list`](https://github.com/DuskWander87/shadowrocket-config/tree/main/rules)，由你的服务器在订阅端口上提供，客户端不用直连国内不可达的 raw.githubusercontent.com。

默认部署时，这两个列表由服务器反代 GitHub 提供，受 GitHub 边缘缓存影响，push 后要等几分钟才拉得到新版本（时效见 [design.md](docs/sub/design.md) §9.1）。部署时（或之后重跑一次）加 `--with-rules`，服务器会克隆规则仓库、每分钟同步一次，push 后一分钟内就能拉到，GitHub 暂时访问不了也不影响：

```bash
tools/deploy.sh --with-rules
```

想维护自己的规则，fork 规则仓库，改 `rules/` 下的两个列表，部署时用 `--rules-repo <你的账号>/shadowrocket-config` 指向你的仓库，加不加 `--with-rules` 都生效。规则端点是否正常，用 `sub-rules-check` 检查，两种方式都适用。

## 安全与边界

- 不修改 3x-ui、Xray 和 443 上的 Reality 入站，面板数据库只读。它只在旁边加一个 Nginx 订阅入口和一个只监听本机的 subconverter。
- **订阅地址就是凭据。** 拿到地址的人就能拉到节点，泄露后用 `sub-manager rotate` 换一条，旧地址立即失效。
- **换地址不等于踢人。** 已经拉到的配置里，节点的 UUID 照样能用。要真正收回访问，去 3x-ui 删掉这个客户端；只换 UUID 的话，没收口 2096 时还要一起重置它的 subId，原因见 [unified-subscription.md](docs/sub/unified-subscription.md) §6。
- 只有命令行，没有网页面板、账号体系和配额，也不做高可用，适合个人或小圈子用。
- 仓库里的域名、路径都是占位符，不含真实凭据。它记录的是一台真实机器的做法，请当参考蓝图，不要当安全承诺。

## 卸载

不想再用了就跑 `tools/uninstall.sh`。它会先打印计划再等确认，只删聚合层，3x-ui、节点、证书和 Nginx 本身不动。

## 文档

| 文档 | 什么时候读 |
|---|---|
| [deploy.md](docs/sub/deploy.md) | 第一次安装、重装、卸载或回滚 |
| [unified-subscription.md](docs/sub/unified-subscription.md) | 给设备配订阅，或想知道按客户端分流的规则 |
| [operations.md](docs/sub/operations.md) | 管理订阅、检查与验证、备份 |
| [certificates.md](docs/sub/certificates.md) | 证书给谁用、怎么续期、能不能不用 acme.sh |
| [design.md](docs/sub/design.md) | 要改系统，先看设计取舍 |
| [incidents.md](docs/sub/incidents.md) | 「这个症状以前见过吗」 |
| [3x-ui/troubleshooting.md](docs/3x-ui/troubleshooting.md) | 节点不通时，一次完整的排查过程 |
| [docs/sub/README.md](docs/sub/README.md) | 查端口、路径和转换参数 |

`server/` 是 `tools/deploy.sh` 装到服务器上的配置，也是作者服务器实际配置的脱敏副本：域名等真实值用占位符代替，部署时替换。`tools/` 是部署、卸载和自测脚本。

## 许可与致谢

[MIT](LICENSE) © 2026 DuskWander。建立在 [3x-ui](https://github.com/MHSanaei/3x-ui)、[subconverter](https://github.com/tindy2013/subconverter) 与 [Mihomo](https://github.com/MetaCubeX/mihomo) 之上。
