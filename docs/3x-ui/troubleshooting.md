# 3x-ui 面板与 VLESS Reality 故障排查手册

本文整理一次真实的 3x-ui 部署故障。表面上出现了很多症状：面板打不开、根路径 `404`、
Windows 浏览器报 `ERR_CONNECTION_CLOSED`、v2rayN 延迟显示 `-1`、Shadowrocket 无法连接。
但根因只有两个，彼此完全独立：

1. **故障一：面板无法访问**，由「URL 缺少随机 Web Base Path」和「本地代理没能转发 HTTPS」
   两层原因叠加造成（§3）。
2. **故障二：节点不可用**，由 Reality 目标站 `www.microsoft.com` 与当前 Xray Core 不兼容
   造成（§4）。

文中的域名、IP、面板路径、UUID、订阅 ID、Reality 密钥和 Short ID 均使用占位符。排查时不要
把真实凭据贴到聊天、工单或公开日志中。

## 1. 环境概览

本次环境的主要组件：

- Ubuntu Server
- 3x-ui `3.4.2`
- Xray Core `26.6.27`
- 3x-ui 面板使用 HTTPS、自定义端口和随机 Web Base Path
- 节点使用 `VLESS + TCP + Reality + xtls-rprx-vision`
- 客户端包括 v2rayN 和 Shadowrocket

示例占位符：

```text
面板域名：panel.example.com
服务器 IP：203.0.113.10
面板端口：35006
面板路径：/RANDOM_PANEL_PATH/
节点端口：443
```

面板和节点使用同一台主机，因此 `panel.example.com` 既是面板域名，也是客户端节点地址。

## 2. 快速判断表

先用现象定位「问题在哪一层」，再跳到对应章节。

| 现象 | 判断层 | 常见原因 | 详见 |
|---|---|---|---|
| `systemctl status x-ui` 显示失败 | 服务层 | 配置错误、端口冲突、证书文件错误 | §6.1 |
| 面板根路径返回 `404` | URL 路径层 | 忘记自定义 Web Base Path | §3.2 |
| `Test-NetConnection` 为 `False` | TCP 网络层 | 云安全组、主机防火墙、错误端口 | §6.1 |
| `Test-NetConnection` 为 `True`，浏览器报 `ERR_CONNECTION_CLOSED` | TLS/代理层 | 本地代理、HTTPS 检查、错误协议 | §3.3 |
| `curl --noproxy "*"` 成功，普通 `curl` 失败 | 本地代理层 | `HTTPS_PROXY` 或代理客户端转发 TLS 失败 | §3.3 |
| 重启后面板地址不变 | 正常行为，不是故障 | 重启不会重新生成 Web Base Path | §3.4 |
| v2rayN 延迟为 `-1`，Shadowrocket 也不可用 | 节点握手层 | 目标站不兼容、Reality 参数不一致、客户端缓存 | §4 |
| TCP 443 可达，ClientHello 后服务器立即 `FIN` | Reality 认证/回落层 | Reality 认证失败，或目标站 TLS 不适合 Reality | §4.3 至 §4.5 |

## 3. 故障一：面板无法访问

### 3.1 现象

观察到两种不同的现象：

- 访问 `https://panel.example.com:35006/`（不带随机路径）返回 `404`
- 用完整 URL 访问时，浏览器直接报 `ERR_CONNECTION_CLOSED`

这两种现象来自**不同的层**，需要分开处理：

- `404` 说明 TLS 握手已经成功、请求打到了面板，只是路径不对，见 §3.2。
- `ERR_CONNECTION_CLOSED` 说明 TLS 根本没建立起来，见 §3.3。

同一个面板同时出现这两种现象并不矛盾：它们通常来自不同的访问链路，例如服务器本机 `curl`
直连，而浏览器要经过本地代理。

### 3.2 第一层原因：URL 缺少随机 Web Base Path

先确认服务、监听端口和实际面板地址：

```bash
systemctl status x-ui --no-pager -l
ss -lntp
x-ui settings
journalctl -u x-ui -n 100 --no-pager
```

本次服务实际是正常的：

```text
Active: active (running)
Web server running HTTPS on [::]:35006
```

`x-ui settings` 显示面板启用了 HTTPS，并设置了随机路径：

```text
Panel is secure with SSL
port: 35006
webBasePath: /RANDOM_PANEL_PATH/
Access URL: https://panel.example.com:35006/RANDOM_PANEL_PATH/
```

**原因**：访问时遗漏了以下一个或多个部分。

- 使用了 `http://`，但面板只接受 `https://`
- 使用了错误端口
- 只访问 `/`，遗漏随机 Web Base Path

根路径返回 `404` 在这种配置下是正常的，不代表 x-ui 没有运行。

**解决方案**：使用 `x-ui settings` 输出的完整 URL。

```text
https://panel.example.com:35006/RANDOM_PANEL_PATH/
```

在服务器本机验证：

```bash
curl -k -i 'https://127.0.0.1:35006/RANDOM_PANEL_PATH/'
```

预期结果：

```text
HTTP/1.1 200 OK
<title>Sign in</title>
```

本机验证通过，但**浏览器用同一个完整 URL 仍然打不开**，说明还有第二层问题。此时先区分是
TCP 不通还是 TLS 不通：

- 外部 TCP 都连不上（`Test-NetConnection` 为 `False`）：检查防火墙与安全组。

  ```bash
  ufw status verbose
  nft list ruleset
  iptables -S
  ```

  同时检查云服务商安全组是否放行对应 TCP 端口。

- 外部 TCP 通、但 TLS 不通：**不是**防火墙问题，见 §3.3。本次属于这一类。

### 3.3 第二层原因：本地代理没能转发 HTTPS

**现象**：Windows 测试端口成功。

```powershell
Test-NetConnection panel.example.com -Port 35006
```

输出：

```text
TcpTestSucceeded : True
```

但浏览器显示：

```text
ERR_CONNECTION_CLOSED
```

**关键诊断**：在 Windows PowerShell 使用原生 curl。

```powershell
curl.exe -vk --http1.1 "https://panel.example.com:35006/RANDOM_PANEL_PATH/"
```

失败输出中出现：

```text
Uses proxy env variable https_proxy == 'http://127.0.0.1:7897'
HTTP/1.1 200 Connection established
schannel: failed to receive handshake
```

这里的 `200 Connection established` 只表示 HTTP 代理接受了 `CONNECT` 隧道请求，不表示里面的
TLS 握手成功。

强制绕过代理后测试：

```powershell
curl.exe --noproxy "*" -vk --http1.1 "https://panel.example.com:35006/RANDOM_PANEL_PATH/"
```

绕过代理后得到：

```text
HTTP/1.1 200 OK
<title>Sign in</title>
```

**原因**：本机代理监听在 `127.0.0.1:7897`。TCP 隧道建立成功，但代理软件、代理节点或 HTTPS
检查功能没有正确转发后续 TLS 握手。非标准 HTTPS 端口更容易触发这类兼容问题。

**解决方案**：在 Clash、Mihomo、v2rayN、sing-box 等客户端中添加直连规则。

```text
DOMAIN,panel.example.com,DIRECT
IP-CIDR,203.0.113.10/32,DIRECT
```

由于面板和节点同域名（§1），这条直连规则同时也避免了代理客户端把自己的节点流量再绕回代理。

或临时清空当前 PowerShell 会话中的代理环境变量：

```powershell
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""
$env:ALL_PROXY = ""
$env:http_proxy = ""
$env:https_proxy = ""
$env:NO_PROXY = "localhost,127.0.0.1,panel.example.com,203.0.113.10"
$env:no_proxy = $env:NO_PROXY
```

注意：浏览器通常使用系统代理或代理软件配置，不一定读取当前 PowerShell 会话的环境变量。
浏览器侧仍需配置直连规则。

### 3.4 相关澄清：重启不会更换面板路径或凭据

这一节记录的**不是故障**，而是排查过程中的一个误解，放在这里避免下次重复走弯路。

**现象**：执行下面的命令后，`x-ui settings` 中的面板路径保持不变。

```bash
x-ui restart
```

**原因**：重启只重新加载现有配置，不会自动生成新的 Web Base Path，也不会重置用户名或密码。

**要真正更换**，运行管理菜单：

```bash
x-ui
```

本版本对应菜单项：

```text
7. Reset Username & Password
8. Reset Web Base Path
```

修改后检查：

```bash
x-ui settings
```

## 4. 故障二：节点不可用（v2rayN 延迟 `-1`，Shadowrocket 也不通）

这个故障与 §3 完全独立：面板恢复访问之后，节点依然不可用。

### 4.1 现象

- v2rayN 更新订阅成功，但真连接延迟显示 `-1`
- Shadowrocket 导入相同订阅后也不可用
- 节点端口是 `443`

### 4.2 服务端与参数核对

```bash
systemctl status x-ui --no-pager -l
ss -lntup
journalctl -u x-ui -n 150 --no-pager
```

本次确认：

- x-ui 和 Xray 都在运行
- Xray 正在公网 `443/TCP` 监听
- UFW 未启用
- nftables/iptables 没有拦截 443
- 服务器出站 HTTPS 正常

订阅和入站参数也一致：

```text
协议：VLESS
地址：panel.example.com
端口：443
传输：TCP
安全：Reality
Flow：xtls-rprx-vision
Fingerprint：chrome
```

同时验证了：

- UUID 一致
- Reality 公钥可由服务端私钥正确推导
- Short ID 在服务端允许列表中
- SNI 在 `serverNames` 中
- 客户端已启用
- 服务器时间已通过 NTP 同步

也就是说，能在服务端静态核对的项目全部正确。

### 4.3 抓包定位

在服务器短暂监听客户端公网 IP：

```bash
timeout 35 tcpdump -ni eth0 -nn -tttt \
  'host CLIENT_PUBLIC_IP and tcp port 443'
```

本次抓包模式：

```text
客户端 -> 服务端：SYN
服务端 -> 客户端：SYN, ACK
客户端 -> 服务端：约 1.7 KB ClientHello
服务端 -> 客户端：FIN
```

这说明：

- DNS、路由、云安全组和 TCP 443 都正常
- 客户端确实发起了 Reality 握手
- 连接是在 Reality/TLS 阶段被服务端关闭

它不是普通的「端口不通」。

### 4.4 被排除的方向

以下处理均未解决本次问题：

- 更新 v2rayN/Xray 客户端 Core
- 改用 Shadowrocket
- 删除旧节点并重新订阅
- 重启 x-ui/Xray
- 重新生成 UUID
- 重新生成订阅 ID
- 重新生成 Reality X25519 密钥
- 将 Short ID 收敛为单个标准 16 位十六进制值
- 移除可疑的 `testseed`
- 在 `network: tcp` 和 `network: raw` 之间切换

这些步骤证明问题不在单个客户端、不在旧订阅缓存，也不在凭据不同步。注意 §2 表格里对这类现象
列出的「Reality 参数不一致、客户端缓存」在本次都被排除了：它们只是同类现象的常见原因，不是
本次的根因。

### 4.5 根因：Reality 目标站不兼容

**原配置**：

```text
target: www.microsoft.com:443
serverName/SNI: www.microsoft.com
```

普通 TLS 测试可以成功：

```bash
xray tls ping www.microsoft.com
```

但普通 TLS 成功不等于该域名适合作为 Reality 目标站。

开启隔离调试后，服务端能够正确解密 Reality 元数据：

```text
ClientVer: [26 6 27]
ClientTime: 正确
ClientShortId: 正确
```

这证明公钥、Short ID 和时间校验已经通过，与 §4.2 的静态核对结论一致。随后服务端连接
`www.microsoft.com`，但在读取和改写目标证书期间无法完成 TLS 握手：

```text
isHandshakeComplete.Load(): false
processed invalid connection: handshake did not complete successfully
```

**根因说明**：`www.microsoft.com` 当时的 TLS 1.3、证书链或握手行为与 Xray Core `26.6.27` 的
Reality 证书伪装流程不兼容。它可以通过普通 TLS 探测，但 Reality 无法基于该目标完成握手，
最终所有客户端都被回落并关闭。

这是本次最关键的经验：

> Reality 目标站必须经过真实的 Reality 端到端验证。`curl` 或 `xray tls ping` 成功只能证明
> 普通 TLS 可用，不能证明它适合作为 Reality 目标。

### 4.6 解决方案与验证

**候选目标验证**：在独立网络命名空间中，使用全新的临时 UUID、X25519 密钥和 Short ID，测试
多个目标。

```text
www.cloudflare.com  Reality 握手成功
www.apple.com       Reality 握手成功
www.google.com      Reality 握手成功
```

Cloudflare 的完整测试结果：

```text
Reality handshake complete
VLESS request accepted
Outbound connection opened
HTTP 200
```

**最终配置**：将线上入站改为下面的目标。

```text
target: www.cloudflare.com:443
serverNames:
  - www.cloudflare.com
客户端 SNI: www.cloudflare.com
```

保留：

```text
VLESS + TCP + Reality
flow: xtls-rprx-vision
fingerprint: chrome
port: 443
```

修改后必须：

1. 重启 Xray 或 x-ui。
2. 确认 `443` 重新监听。
3. 在客户端更新订阅。
4. 确认客户端节点 SNI 已变为 `www.cloudflare.com`。
5. 再运行真连接延迟测试。

最终 v2rayN 和 Shadowrocket 均恢复可用。

## 5. Reality 目标站选择与验证流程

不要只凭域名知名度选择目标站。建议流程：

1. 目标站必须支持 TLS 1.3。
2. 服务器必须能稳定访问目标站的 443 端口。
3. SNI 必须包含在目标证书的域名列表中。
4. 不要选择重定向逻辑复杂或区域行为不稳定的站点。
5. 用与线上相同 Xray 版本进行真实 Reality 端到端测试。
6. 更换目标后同时修改服务端 `target/serverNames` 和客户端 `sni`。

基础探测：

```bash
xray tls ping www.cloudflare.com
```

该命令适合筛选候选站，但不能作为最终结论。最终仍需客户端真实连接，或者使用隔离环境进行完整
Reality 测试（做法见 §4.6）。

## 6. 标准排查顺序

### 6.1 面板问题

```bash
systemctl status x-ui --no-pager -l
x-ui settings
ss -lntp
curl -k -i 'https://127.0.0.1:PANEL_PORT/WEB_BASE_PATH/'
```

判断：

1. 服务未运行：先看日志和配置。
2. 本机不通：检查监听、证书和路径。
3. 本机通、外部 TCP 不通：检查安全组和防火墙。
4. 外部 TCP 通、TLS 不通：检查协议、本地代理和 HTTPS 检查（§3.3），不要再查防火墙。

### 6.2 节点问题

```bash
systemctl status x-ui --no-pager -l
ss -lntp '( sport = :443 )'
timedatectl status
nft list ruleset
```

客户端侧：

```powershell
Test-NetConnection panel.example.com -Port 443
```

判断：

1. TCP 不通：网络层问题。
2. TCP 通，但无 ClientHello 到达：客户端节点地址或本地代理问题。
3. ClientHello 到达后立即 FIN：Reality 参数或目标站问题。
4. Reality 元数据无法解密：优先检查公钥、Short ID、时间和客户端版本。
5. 元数据可解密，但目标握手不完整：更换 Reality 目标站（§4.5、§5）。
6. 握手完成但网页不通：继续检查 VLESS UUID、flow、路由和服务器出站。

## 7. 敏感信息与重置范围

本节适用于整个排查过程结束后的收尾，包括 §3 和 §4 产生的所有输出。

### 7.1 本次没有直接暴露的内容

- 管理员密码
- 已认证登录会话
- VLESS UUID
- Reality 私钥
- 完整订阅 URL

### 7.2 可能出现在排查输出中的信息

- 面板域名和服务器公网 IP
- 面板端口
- 随机 Web Base Path
- x-ui/Xray 版本
- 未登录页面产生的 Cookie 和 CSRF token

未登录页面的 Cookie 和 CSRF token 通常不能直接登录面板，但仍不应公开保存。

### 7.3 建议

如果排查记录会被第三方看到：

1. 重置 Web Base Path（做法见 §3.4）。
2. 重置管理员用户名和密码。
3. 重新生成客户端 UUID、订阅 ID、Reality 密钥和 Short ID。

   本次排查中 §4.4 已经把这些全部轮换过一遍；如果排查过程与本文相同，这一步可以只做一次
   确认，不必重复轮换。
4. 将面板端口在安全组中限制为可信公网 IP。

日志分享前应遮盖：

```text
用户名、密码、UUID、subId、完整订阅 URL、pbk/publicKey/password、privateKey、sid/shortId、Cookie、CSRF token
```

## 8. 备份与回滚

修改数据库或重建入站前先备份：

```bash
backup="/etc/x-ui/x-ui.db.backup-$(date -u +%Y%m%d-%H%M%S)"
cp --preserve=mode,ownership,timestamps /etc/x-ui/x-ui.db "$backup"
chmod 600 "$backup"
sha256sum "$backup"
```

优先通过 3x-ui 面板修改入站。只有在确认面板无法正确保存或需要事务化修复时，才直接操作
数据库。

回滚前必须停止服务，并先保留当前数据库副本：

```bash
systemctl stop x-ui
cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.failed
cp /etc/x-ui/x-ui.db.backup-YYYYMMDD-HHMMSS /etc/x-ui/x-ui.db
chown root:root /etc/x-ui/x-ui.db
chmod 600 /etc/x-ui/x-ui.db
systemctl start x-ui
```

## 9. 最终结论

本次实际上是两个独立故障：

1. **面板访问失败**（§3）：由遗漏随机 Web Base Path 和本地 HTTPS 代理共同造成。修好其中
   一个都不够，两个现象必须分别处理。
2. **节点不可用**（§4）：由 Reality 目标站 `www.microsoft.com` 与当前 Xray Reality 握手
   流程不兼容造成。

「重启后面板地址不变」（§3.4）不是故障，是设计行为。

最快的定位原则：

```text
先分层：服务 -> TCP -> TLS -> Reality -> VLESS -> 出站
TCP 成功不代表 TLS 成功
普通 TLS 成功不代表 Reality 成功
订阅导入成功不代表节点认证成功
```
