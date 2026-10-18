#!/usr/bin/env bash
# 公开入口。真实逻辑在 skill 的 scripts/ 目录里，两边共用一份实现。
set -Eeuo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$repo_root/.claude/skills/deploy-sub-aggregator/scripts/deploy.sh" "$@"
