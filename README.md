# sub-aggregator

> 给 3x-ui 加一层订阅聚合。同一条订阅地址，Clash/Mihomo 拿到带规则集的完整配置，Shadowrocket/v2rayN 只拿节点，转换在你自己的服务器上完成。

[![License: MIT](https://img.shields.io/badge/license-MIT-3DA639?style=flat-square)](LICENSE)
[![3x-ui](https://img.shields.io/badge/base-3x--ui-2F6FEB?style=flat-square)](https://github.com/MHSanaei/3x-ui)
[![Clash / Mihomo](https://img.shields.io/badge/client-Clash%20%2F%20Mihomo-7B61FF?style=flat-square)](https://github.com/MetaCubeX/mihomo)
[![Docs](https://img.shields.io/badge/docs-zh-555?style=flat-square)](docs/sub/README.md)

3x-ui 的原生订阅是一串 Base64 编码的节点，Shadowrocket、v2rayN 能直接使用，Clash 客户端无法识别。第三方转换服务能把格式对上，代价是原始订阅地址要交给别人。转换和规则集都落在别人的服务器上，服务停不停、规则什么时候更新，你控制不了。同一个人的手机和电脑还常常各配一条订阅，换个客户端就要重新找地址。

sub-aggregator 装在 3x-ui 所在的服务器上，把转换收回本机。一个人的所有设备共用一条 HTTPS 订阅地址，Nginx 按 `User-Agent` 识别客户端，返回不同的内容：

| 客户端 | 拿到什么 |
|---|---|
| Clash/Mihomo 系，如 Clash Verge、ClashMi、ClashMetaForAndroid | 本机转换的完整配置：节点、一个手动选择的策略组、防 DNS 泄漏配置和规则集 |
| Shadowrocket、v2rayN 和其他客户端 | 3x-ui 原生订阅原样转发，只有节点，没有规则集、策略组和 DNS 设置 |

转换时会去掉 3x-ui 追加在节点名末尾的剩余流量（`|📊…`），名字不随流量变化，Clash 更新订阅后还记得你选的是哪个节点。原生订阅不做任何改动，所以 Shadowrocket 里的节点名仍带着剩余流量。

## 快速开始

### 1. 准备

- 一台 Ubuntu 24.04 服务器，已安装 3x-ui，443 端口上有一个可用的 VLESS Reality 入站。需要 root 权限和至少 2 GB 内存，不需要 Docker。尚未安装 3x-ui 时，可以先参考 [自建节点教程 3XUI 面板（无限芝士）](https://www.youtube.com/watch?v=TRVE7sVTgWw)。
- 一个解析到这台服务器的域名。没有证书时脚本会用 Let's Encrypt 签发，要求公网能访问 80 端口。
- 一个空闲端口留给订阅入口，默认 `8443`（443 已被 Reality 占用），并在防火墙 / 云安全组放行 TCP 入站。

### 2. 部署

```bash
git clone https://github.com/DuskWander87/sub-aggregator.git
cd sub-aggregator
tools/deploy.sh               # 加 --dry-run 只看计划，不改任何文件
```

脚本会自动推导域名并查找证书，没有证书时签发一张，之后由 acme.sh 自动续期。缺少依赖时会先询问是否安装，打印部署摘要并再次确认后才开始部署，覆盖文件前都会先备份。

`8443` 被占用时，用 `--port <端口>` 指定其他端口。端口会写进每条订阅地址，部署后再改端口，所有设备都要重新导入订阅。

部署完成后，建议再手动完成一步：把 3x-ui 的订阅服务（默认 2096 端口）改成只监听本机，原始订阅地址在公网上就访问不到了。部署脚本不修改 3x-ui，步骤见 [deploy.md](docs/sub/deploy.md) §3.5。全部参数、手动部署和回滚也在这份文档里。

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

整条复制到客户端里添加订阅，Clash 和 Shadowrocket 用的是同一条。末尾的 `#<订阅名>` 是给客户端看的显示名（Shadowrocket 只使用它），不会发到服务器。

服务器按 `User-Agent` 判断要不要返回 Clash 配置：UA 含 `clash`、`mihomo`、`verge` 等关键词的才返回，其余一律返回原生订阅。如果你的 Clash 客户端 UA 不含这些关键词，拿到的就是原生订阅，这时在 `#` 前加 `?t=clash` 强制返回 Clash 配置，比如 `https://<域名>:8443/<随机路径>?t=clash#<订阅名>`；反过来，`?t=raw` 强制返回原生订阅。`t` 取其他值（比如拼错）时不会退回 UA 判断，一律返回原生订阅。完整规则见 [docs/sub/unified-subscription.md](docs/sub/unified-subscription.md) §2。

## 日常操作

```bash
sub-manager list              # 列出订阅地址，以及和面板客户端的对应关系
sub-manager add --from-xui    # 面板里加了客户端，给它建订阅
sub-manager update sub-1      # 面板里重置了 subId，订阅地址不变
sub-manager rotate sub-1      # 地址泄露，换一条新地址，设备要重新导入
sub-manager remove sub-1      # 删除订阅
sub-manager test              # 检查全部订阅
```

面板里增删客户端不会自动同步过来。新增客户端后，再执行一次 `add --from-xui` 为它建订阅；删除客户端后，`list` 会标出哪些订阅已经没有对应的客户端。每条命令的细节见 [operations.md](docs/sub/operations.md)。

## 规则集只对 Clash 生效

Shadowrocket、v2rayN 从订阅拿到的只有节点，分流由它们自己的配置决定。Clash 配置则引用 11 个规则集：9 个来自 [ACL4SSR](https://github.com/ACL4SSR/ACL4SSR)，客户端经 jsDelivr 拉取；另外 2 个是作者自维护的 [`ChinaDirect.list` 和 `Reject.list`](https://github.com/DuskWander87/shadowrocket-config/tree/main/rules)，由你的服务器在订阅端口上提供，客户端不用直连国内不可达的 raw.githubusercontent.com。

默认部署时，这两个列表由服务器反代 GitHub 提供，受 GitHub 边缘缓存影响，push 后要等几分钟才能拉取到新版本（时效见 [design.md](docs/sub/design.md) §9.1）。部署时（或之后重新部署时）加 `--with-rules`，服务器会克隆规则仓库、每分钟同步一次，push 后一分钟内即可拉取到，GitHub 暂时无法访问时也不受影响：

```bash
tools/deploy.sh --with-rules
```

如需维护自己的规则，先 fork 规则仓库，改 `rules/` 下的两个列表，部署时用 `--rules-repo <你的账号>/shadowrocket-config` 指向你的仓库，无论是否加 `--with-rules` 都生效。规则端点是否正常，用 `sub-rules-check` 检查，两种方式都适用。

## 适用范围

sub-aggregator 面向已经运行 3x-ui 的单台服务器，供个人或少数人自用。使用者需要能登录服务器、执行命令行操作，并按 [operations.md](docs/sub/operations.md) 自行维护订阅。

- **命令行工具。** 部署和日常操作全部在命令行完成。客户端的新增、删除、流量限制和到期时间由 3x-ui 面板管理，本项目只读取客户端信息生成订阅地址。
- **单机承担全部订阅请求。** 订阅入口由同一个 Nginx、同一个 subconverter 和一份本地配置组成，部署在 3x-ui 所在的服务器上，可用性取决于这台服务器本身。
- **一条订阅对应一个客户端。** 每个订阅绑定一个 3x-ui 客户端，能接入多少设备由该客户端的设置决定；账号、配额和计费全部由 3x-ui 承担。
- **旁挂式部署。** 新增的内容只有 Nginx 订阅入口和一个只监听 `127.0.0.1` 的 subconverter；3x-ui、Xray 和 443 上的 Reality 入站保持原样，面板数据库只读。
- **按实际环境调整。** 仓库记录的是作者服务器的做法，硬件、系统版本、域名和端口组合不同时，需要相应修改。

## 安全与边界

- **订阅地址就是凭据。** 访问该地址即可拉取节点，不需要账号或口令；泄露后用 `sub-manager rotate` 换一条，旧地址立即失效。
- **换地址不收回节点访问。** 已经拉取的配置里，节点的 UUID 仍然可用，`rotate` 只让分发地址失效。要真正收回访问，在 3x-ui 面板删除该客户端，机制与步骤见 [unified-subscription.md](docs/sub/unified-subscription.md) §6。
- **仓库不含真实凭据，也不构成安全承诺。** 域名、路径均为占位符；照搬到自己的服务器时，域名、证书和访问控制需要自行核对。

## 卸载

需要卸载时执行 `tools/uninstall.sh`。脚本会先打印卸载计划，确认后才执行；只删除聚合层，不改动 3x-ui、节点、证书和 Nginx 本身。

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

[MIT](LICENSE) © 2026 DuskWander87。建立在 [3x-ui](https://github.com/MHSanaei/3x-ui)、[subconverter](https://github.com/tindy2013/subconverter) 与 [Mihomo](https://github.com/MetaCubeX/mihomo) 之上。
