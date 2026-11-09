# 订阅入口：一条链接服务所有客户端

> 单一事实源在 [README.md](README.md) §3：端口、路径、`CONVERT_OPTS`、订阅名称。本文只引用，
> 不复写。但**分流规则（UA 白名单、`?t=` 覆盖、判定优先级）以本文 §2 为准**，其余文档一律
> 引用本节，不复写。

每条订阅只有**一个 URL**，按 `User-Agent` 返回对应格式：Clash 系客户端拿转换后的 YAML，
Shadowrocket / V2rayN 拿 3x-ui 原生订阅。

## 1. 它解决什么、不解决什么

解决的是「同一个人换设备就要换链接」。**不是**把多个 3x-ui 订阅合并成一个节点列表。那是
另一回事，subconverter 的 `url=A|B` 语法可以做，但当前没有这个需求。

## 2. 判定规则（本节是单一事实源）

地址形态见 [README.md](README.md) §3.4，那里是单一事实源。判定只需要知道三点：**路径不带
任何前缀**；每条订阅只有这一条地址，它本身就是访问凭据；末尾的 fragment 由客户端本地截断、
不发给服务器，因此不参与下面的判定。

承接分流的两个 internal location 保留可读的 `/internal/clash/` 与 `/internal/raw/` 前缀。
它们带 `internal` 指令，外部访问一律 404，不对外可见，没有去特征的必要。

判定规则：`t` 参数优先，缺省时才看 UA。

| 条件 | 结果 |
|---|---|
| `?t=clash` | Clash 配置（转换） |
| `?t=raw` | 原生订阅（透传） |
| `?t=` 其他任何值 | 原生订阅（透传，与 `raw` 同路） |
| 无 `t`（或 `?t=` 留空）+ UA 命中白名单 | Clash 配置（转换） |
| 无 `t`（或 `?t=` 留空）+ 其余一切（含无 UA、浏览器、未知客户端） | 原生订阅（透传） |

两个容易出错的细节，都实测过：`t` 的值**大小写不敏感**（`?t=Clash`、`?t=CLASH` 一样走转换，
这是 Nginx `map` 对字符串键的默认行为）；但**拼错的值不会退回 UA 判定**，`?t=yaml` 配 Clash
UA 拿到的是原生订阅，因为 map 直接落到 `default "raw"`。需要 Clash 配置时写对 `clash`，不确定时
不要带 `t`。

UA 白名单（脚本常量 `UA_CLASH_PATTERN`，大小写不敏感）：

```text
(clash|mihomo|meta|stash|verge|flclash|nekobox)
```

它只回答「是不是 Clash 家族」，不区分具体客户端。实测命中的有 `clash-verge/*`、
`ClashMi/*`、`mihomo/*`、`ClashMetaForAndroid/*`；`Shadowrocket/*` 与 `v2rayN/*` 不命中，
按设计落到原生分支。

**失败方向是安全的**：白名单没命中时拿到的是原生订阅，也就是 Shadowrocket 和 V2rayN 本来
就该拿到的内容，而不是一份格式不对的配置。这是整套分流能成立的前提，见
[design.md](design.md) §2.1。

遇到 UA 不含上述关键词的 Clash 客户端，在客户端里把订阅地址加上 `?t=clash` 即可，
**不必改服务器**。反过来，想让 Clash 客户端拿到原始节点链接用 `?t=raw`。

## 3. 两个分支各返回什么

| 分支 | 内容 | 与源头的关系 |
|---|---|---|
| Clash | 完整 Mihomo YAML，含 `rule-providers`、fake-ip DNS、单策略组 | 与本机 subconverter 直出一致，外加 Nginx `sub_filter` 注入的 `format: text` |
| 原生 | 3x-ui 的 Base64 节点列表原文，只有节点 | 正文与回环直连 `2096` 原始订阅**逐字节相同**（两处每次请求都变的值除外，见下） |

规则集、DNS 和策略组只在 Clash 分支里。Shadowrocket、V2rayN 从本订阅只拿到节点，分流由客户端
自己的配置决定。

原生分支保留上游全部响应头，包括 `Profile-Update-Interval`、`Profile-Web-Page-Url`、
`Subscription-Userinfo`；唯一被覆盖的是 `Profile-Title`，由 Nginx 用 `sub-manager` 的
`PROFILE_NAME` 重写（`base64:` 前缀），因此两个分支的名字同源。不加 `Content-Disposition`
（那是 Clash 分支的取名方式）。命名细节见 [README.md](README.md) §3.4。

两个分支都加 `Vary: User-Agent`。**这条不能少**：同一个 URL 按 UA 返回两种格式，缺了它
客户端本地缓存或任何中间缓存都可能把 Clash 配置返回给 Shadowrocket。

### 3.1 两个每次请求都变的值

对比原生分支和原始订阅时要知道，以下两处**本来就不固定**，与代理无关：

- 节点名尾部的 `|📊<剩余流量>`，流量一直在走；
- Reality 的 `spx`（spiderX），3x-ui **每次请求随机生成**（连续三次抓取得到三个不同值）。

`sub-manager test` 的逐字节比较会先把这两处归一化，其余部分严格比较。

## 4. 为什么不用 subconverter 的 `target=auto`

subconverter 原生支持 `target=auto`，按 UA 自动选格式。实测可用：Clash 家族 UA 返回
YAML，`Shadowrocket/*` 返回 Base64，未知 UA 返回 **HTTP 400 `Invalid target!`**。

没有采用，因为它会让**非 Clash 客户端也经过 subconverter 重新拼装节点链接**，实测有四处
差异：

1. 丢掉 Reality 的 `spx` 参数（subconverter 不认这个字段）；
2. 凭空加上 `host=` / `path=` / `headerType=`，而节点是 `type=tcp`，这三个参数没有意义；
3. 丢掉 `Profile-Update-Interval` 和 `Profile-Web-Page-Url` 两个响应头，Shadowrocket 的
   自动更新周期靠前者；
4. 未知 UA 直接 400，浏览器打开也是 400。

原生分支必须与 3x-ui 的原始输出完全一致，这一点不能妥协。第 1、2 条动的是 Reality 握手参数，
正是 [`../3x-ui/troubleshooting.md`](../3x-ui/troubleshooting.md) 整篇在讲的那类问题。

`target=auto` 的失败方向也更差：Nginx 分流在识别失败时退回原生订阅，`target=auto` 直接
400。

## 5. 实现结构

配置由 `sub-manager` 生成，**不要手改** `/etc/nginx/conf.d/private-sub.conf`。

server 块之外（http 上下文）两个 map：

```nginx
map $http_user_agent $ua_clash {
    default 0;
    "~*(clash|mihomo|meta|stash|verge|flclash|nekobox)" 1;
}

map "$arg_t:$ua_clash" $sub_backend {
    default   "raw";
    "clash:0" "clash";
    "clash:1" "clash";
    ":1"      "clash";
    "raw:1"   "raw";
}
```

每个订阅生成三个 location：入口 `= /<随机路径>`（无前缀），以及两个 `internal` 的承接
location `= /internal/clash/<随机路径>` 和 `= /internal/raw/<随机路径>`。入口只做判定：

```nginx
error_page 418 = /internal/clash/<随机路径>;
error_page 419 = /internal/raw/<随机路径>;
if ($sub_backend = "clash") { return 418; }
return 419;
```

三个实现约束，改这段前必读：

- **承接 location 必须是精确匹配 + `internal`，不能用命名 location（`@name`）。** 命名
  location 里的 `proxy_pass` 不允许带 URI 部分，而两个后端地址都必须带 URI（转换后端要带
  一长串查询参数，原生后端要带 `subId` 路径）。最初的实现就因此未通过 `nginx -t`。
- **`if` 里只允许 `return`。** 这是 nginx 官方认可的安全用法；把 `proxy_pass` 写进 `if`
  才是常见的错误用法。
- **`internal` 保证这两个路径不能从公网直接访问**，外部请求返回 404。

原生分支的回源地址：源订阅的域名如果就是本机域名，一律改走 `https://127.0.0.1:<端口>`，
并显式设置 `proxy_ssl_name` 和 `Host` 头。这既省掉一次公网回环，也是 §6 收口后原生分支
仍能工作的原因。

## 6. 收口 2096（可选）

3x-ui 订阅服务默认监听所有地址，`https://<域名>:2096/sub/<subId>` 这样的原始订阅地址在公网
可用（除非防火墙或云安全组挡住 2096）。收口是把它限制到 `127.0.0.1:2096`，公网订阅入口只剩
`8443`。部署脚本不改 3x-ui，收口要手工做，步骤见 [deploy.md](deploy.md) §3.5。

收不收口，决定了收回一个人的访问要做几步。原生分支透传上游的 `Profile-Web-Page-Url`，值形如
`https://<域名>/sub/<subId>`，带着该客户端的 `subId`；用过聚合地址的人都能据此拼出原始订阅
地址：

- 未收口：原始订阅地址在公网可用。`rotate` 换掉聚合路径收不回它；只换 UUID 也不够，对方从
  原始订阅能直接拉取到新 UUID。收回访问要在 3x-ui 删掉该客户端，或同时更换 UUID 与 `subId`。
- 收口后：原始订阅地址只在本机可达，在 3x-ui 删掉该客户端或更换 UUID 即可。

两种情况下 `rotate` / `remove` 都只作废聚合地址，已拉取配置里的 UUID 仍然有效。

收口的设置项是 `subListen`（面板：设置 → 订阅 → Listen IP），数据库里对应
`settings.key = 'subListen'`，值为 `127.0.0.1`。修改需要重启 x-ui，443 上的 Xray 会随之中断
数秒。

收口后，subconverter 仍按公网域名拉取原始订阅，因此要把该域名解析到回环地址：

```text
/etc/hosts:
127.0.0.1 sub.example.com
```

映射只改解析结果，SNI、Host 和证书校验都不变。没有这条映射，Clash 分支会因 subconverter
连不上 2096 而报「本地转换失败」。映射可以在收口前加上，监听所有地址时回环同样可达，所以
先加映射、再改 `subListen`，中间不会断。原生分支和 `sub-manager` 自己拉取原始订阅时本来就走
`127.0.0.1`，不依赖这条映射。

收口后验证：

```bash
ss -lntp | grep 2096     # 只应出现 127.0.0.1:2096
sub-manager test         # 全部订阅通过
```

回滚：把 `subListen` 清空（或删除该键）并重启 x-ui；`/etc/hosts` 的映射可以保留。

## 7. 验证

`sub-manager test`（全部订阅）或 `sub-manager test sub-N`（单个）对每个订阅
地址执行四项断言：

| 请求 | 期望 |
|---|---|
| `-A "ClashMetaForAndroid/2.11"` | 含 `proxies:`、代理节点、`store-selected: true`、**`format: text`**；无 `\|📊` 残留；不含原始订阅 URL |
| `-A "Shadowrocket/2.2.65"` | 与直连原始订阅逐字节相同（§3.1 两处归一化后），且响应含 `Profile-Update-Interval` 与 `Vary: User-Agent` |
| `-A "curl/8.5.0"`，不带 `t` | 与直连原始订阅逐字节相同（同样归一化后），确认未知 UA 落到原生分支；这个请求不重复头断言 |
| `-A "curl/8.5.0"` + `?t=clash` | 与第一个请求**逐字节相同**，且响应头含 `Content-Disposition` 订阅名 |

原生分支那两发用「逐字节相同」，比逐条 grep 强：`spx` 被改写、参数被注入这类问题会直接
暴露，不需要为每个字段单独写断言。Clash 分支没有可以逐字节比对的参照物，因此用内容断言，
再用 `?t=clash` 与 UA 命中互为参照，守住两条进入该分支的路径不漂移。

其中 `format: text` 由 Nginx `sub_filter` 注入，本机 subconverter 直出里没有，所以只能在这
一层断言：它防止的是 [incidents.md](incidents.md) `2026-08-08` 那个问题再次出现。两个名称 header
（`Profile-Title` 与 `Content-Disposition`）的值都来自 `PROFILE_NAME`，Nginx 覆盖失效或常量
与预期不一致都会在这里报错。

手工核对时的探针（`<订阅地址>` 换成 `sub-manager list` 里的地址，去掉 fragment）：

```bash
for ua in "clash-verge/v2.0.3" "ClashMi/1.2.0" "Shadowrocket/2.2.65" "v2rayN/7.5" "curl/8.5.0"; do
    printf '%-24s %s\n' "$ua" "$(curl -sS -A "$ua" "<订阅地址>" | head -c 10)"
done
```

前 10 个字符是 `port: 7890` 的走了 Clash 分支，是 `dmxlc3M6Ly`（Base64 编码的 `vless://`
开头）的走了原生分支。截到 10 个字符为止，再往后就带上 UUID 了，不要贴进文档。

这四项断言做过红灯验证：把 UA 白名单改成不可能命中、删掉 raw 分支的 `Vary` 头、把 raw
分支错接到转换后端，三次都被对应断言拦下；恢复后复测全部通过。
