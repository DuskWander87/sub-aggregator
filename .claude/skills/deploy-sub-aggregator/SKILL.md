---
name: deploy-sub-aggregator
description: 在本机从零部署 sub-aggregator：检查 3x-ui、域名和证书，替换占位符，安装 Nginx 与 systemd，创建第一条订阅并验证，可选把 3x-ui 订阅收口到本机。用户要安装、重装或排查首次部署时使用。
---

# 部署 sub-aggregator

## 先确认

- 目标是 Ubuntu 24.04，443 上已经有 3x-ui 的 VLESS Reality 入站。
- 需要 root。脚本会改 `/usr/local/sbin`、`/etc/nginx`、`/etc/systemd/system` 和 `/opt/subconverter-classic`。
- 2096 收口是可选的独立步骤，默认不做。做了还会改 `/etc/x-ui/x-ui.db` 和 `/etc/hosts`，并重启 x-ui；443 上的节点会中断数秒。
- 订阅地址是凭据。不要把完整 URL、UUID 或 `subId` 写进文件、日志或提交。

## 步骤

1. 先看 `tools/deploy.sh --help`，确认参数。
2. 问清三个值：域名、证书目录、订阅显示名，以及是否启用规则链。规则链默认使用作者的规则集，不需要问仓库地址；只有用户想用自己的规则时才问 fork 的 owner/repo。
3. 先跑 dry-run：
   ```bash
   tools/deploy.sh --dry-run --domain <域名> --cert-dir <目录> --profile-name <名称>
   ```
4. 把计划原样给用户看，重点是要覆盖的路径、备份目录和会重启的服务。
5. 用户明确同意后，再去掉 `--dry-run` 执行。脚本默认逐步确认。
6. 不要主动加 `--yes`。只有用户明确要求连续执行时才加。
7. 最后跑 `sub-manager test`，把结果告诉用户。失败时不要反复重试破坏性步骤，先看备份目录和 `docs/sub/deploy.md` 的回滚段。
8. 询问用户是否执行可选的 2096 收口。默认不做；用户明确同意后，按
   `docs/sub/deploy.md` §3.5 执行：
   1. 备份 `/etc/x-ui/x-ui.db`。
   2. 把 3x-ui 订阅的 Listen IP 设为 `127.0.0.1`（面板「设置 → 订阅 → Listen IP」，
      或 `settings.key = 'subListen'`），重启 x-ui。443 上的 Xray 会随之中断数秒。
   3. 在 `/etc/hosts` 增加 `<域名> → 127.0.0.1` 的映射，重启 subconverter。
   4. 验证 `ss -lntp | grep 2096` 只有 `127.0.0.1`、`getent hosts <域名>` 返回
      `127.0.0.1`、`sub-manager test` 全绿。
   5. 如果 `sub-manager test` 报「本地转换失败」，先检查 `/etc/hosts` 映射；subconverter
      需要按域名回源。

## 边界

- 不手写 Nginx location，订阅一律走 `sub-manager`。
- 部署脚本本身不修改 3x-ui、Xray 或 443 入站。可选的 2096 收口是单独步骤，只有用户明确
  同意后才执行；它会重启 x-ui（节点短暂中断），但不改 443 入站或 Reality 配置。
- 2096 收口后必须保留 `/etc/hosts` 映射，否则 Clash 分支会报「本地转换失败」。
- 不把订阅 URL、UUID、`subId` 写进任何文件或日志。
- 规则链是可选步骤。用户没要求就不要启用 `sub-rules-sync.timer`。
