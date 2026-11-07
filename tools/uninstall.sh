#!/usr/bin/env bash
# sub-aggregator 卸载脚本。
#
# 只删除部署脚本写入的聚合层产物；3x-ui、Xray、x-ui.db、证书、acme.sh、Nginx 本身
# 都不动。先在交互式终端里打印计划并确认，再备份、卸载。
set -Eeuo pipefail
umask 077

# 警告与错误着色。只在 stderr 是终端时启用，重定向到文件或管道时保持纯文本；
# NO_COLOR 可显式关闭。
if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
    readonly COLOR_WARN=$'\033[33m'
    readonly COLOR_ERROR=$'\033[31m'
    readonly COLOR_RESET=$'\033[0m'
else
    readonly COLOR_WARN=""
    readonly COLOR_ERROR=""
    readonly COLOR_RESET=""
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROGRAM="${0##*/}"

# 下列路径与 tools/deploy.sh 的安装清单、docs/sub/README.md §3.2 是同一份清单，
# 改一处必须同步另外两处。
readonly SBIN_DIR="/usr/local/sbin"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
readonly NGINX_CONF_D_DIR="/etc/nginx/conf.d"
readonly OPT_DIR="/opt/subconverter-classic"
readonly PUBLISH_DIR="/var/lib/sub-rules"
readonly STATE_DIR="/etc/sub-manager"
readonly NGINX_CACHE_DIR="/var/cache/nginx/sub-rules"
readonly HOSTS_FILE="/etc/hosts"
# deploy.sh 复用 certbot 证书时安装的续期 hook，属于证书续期链路，卸载时保留。
readonly CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sub-aggregator.sh"

readonly MANAGER_SCRIPTS=(sub-manager sub-rules-sync sub-rules-check)
readonly SERVICE_UNITS=(subconverter.service sub-rules-sync.service sub-rules-sync.timer)
readonly NGINX_SNIPPETS=(sub-rules.conf sub-rules-common.conf sub-rules-upstream.conf)
readonly NGINX_CONFS=(sub-rules-cache.conf private-sub.conf)
readonly ACME_KEPT=(
    "$NGINX_CONF_D_DIR/acme-challenge.conf"
    "/var/www/acme"
    "$CERTBOT_HOOK"
)

HOST=""
RULES_WORKDIR=""
BACKUP_DIR=""
REMOVE_PATHS=()
HOSTS_LINES=()

usage() {
    cat <<'EOF'
用法：
  uninstall.sh

删除部署脚本写入的聚合层：sub-manager、subconverter、本服务的 Nginx 配置、
systemd 单元、订阅状态、规则发布目录与缓存。运行后会先打印计划并要求确认。

3x-ui、x-ui.db、Xray、证书、acme.sh、Nginx 本身不会被修改。
EOF
}

fail() { printf '%s✗ 错误：%s%s\n' "$COLOR_ERROR" "$*" "$COLOR_RESET" >&2; exit 1; }
warn() { printf '%s⚠ 警告：%s%s\n' "$COLOR_WARN" "$*" "$COLOR_RESET" >&2; }
log() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ $EUID -eq 0 ]] || fail "必须以 root 运行。"
}

confirm() {
    local answer
    [[ -t 0 ]] || fail "卸载需要在交互式终端里确认。请在终端中直接运行 $PROGRAM。"
    printf '%s [y/n] ' "$1" >&2
    IFS= read -r answer
    answer=${answer,,}
    [[ $answer == y || $answer == yes ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            *) fail "未知参数：$1（卸载不需要参数，用 --help 查看说明）" ;;
        esac
    done
}

detect_installed() {
    # 只读已安装的管理脚本，用于输出提示；不查询也不写 3x-ui。
    if [[ -r "$SBIN_DIR/sub-manager" ]]; then
        HOST=$(sed -n 's/^readonly HOST="\(.*\)"$/\1/p' "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    if [[ -r "$SBIN_DIR/sub-rules-sync" ]]; then
        RULES_WORKDIR=$(sed -n 's/^REPO_DIR=\(.*\)$/\1/p' "$SBIN_DIR/sub-rules-sync" | head -n 1)
    fi
}

# 受保护路径永不删除。清单之外的删除都由 build_remove_paths 决定。
path_is_protected() {
    case $1 in
        /|/root|/root/code|/etc|/etc/nginx|/etc/nginx/snippets|/etc/nginx/conf.d|\
        /etc/systemd|/etc/systemd/system|/usr|/usr/local|/usr/local/sbin|/opt|\
        /var|/var/lib|/var/cache|/var/cache/nginx|/var/www|/etc/x-ui|/etc/x-ui/*|\
        /root/cert|/root/cert/*|/root/.acme.sh|/root/.acme.sh/*|\
        /etc/letsencrypt|/etc/letsencrypt/*|"$HOSTS_FILE")
            return 0 ;;
    esac
    return 1
}

build_remove_paths() {
    local p
    REMOVE_PATHS=()
    for p in "${MANAGER_SCRIPTS[@]}"; do REMOVE_PATHS+=("$SBIN_DIR/$p"); done
    for p in "${SERVICE_UNITS[@]}"; do REMOVE_PATHS+=("$SYSTEMD_DIR/$p"); done
    for p in "${NGINX_SNIPPETS[@]}"; do REMOVE_PATHS+=("$NGINX_SNIPPETS_DIR/$p"); done
    for p in "${NGINX_CONFS[@]}"; do REMOVE_PATHS+=("$NGINX_CONF_D_DIR/$p"); done
    REMOVE_PATHS+=("$OPT_DIR" "$PUBLISH_DIR" "$NGINX_CACHE_DIR" "$STATE_DIR")

    for p in "${REMOVE_PATHS[@]}"; do
        if path_is_protected "$p"; then
            fail "拒绝删除受保护路径：$p"
        fi
    done
}

collect_hosts_lines() {
    HOSTS_LINES=()
    [[ -n $HOST && -r $HOSTS_FILE ]] || return 0
    mapfile -t HOSTS_LINES \
        < <(awk -v h="$HOST" '$1=="127.0.0.1" && $2==h {print}' "$HOSTS_FILE")
}

existing_paths() {
    local p
    for p in "${REMOVE_PATHS[@]}"; do
        [[ -e $p || -L $p ]] && printf '%s\n' "$p"
    done
}

write_restore_script() {
    cat >"$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
# 由 uninstall.sh 生成：把聚合层恢复到卸载之前。
set -Eeuo pipefail
backup_dir=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ -s $backup_dir/files.tar.gz ]]; then
    tar -xzPf "$backup_dir/files.tar.gz"
fi
systemctl daemon-reload || true
systemctl enable subconverter 2>/dev/null || true
systemctl start subconverter 2>/dev/null || true
if [[ -f /etc/systemd/system/sub-rules-sync.timer ]]; then
    systemctl enable --now sub-rules-sync.timer 2>/dev/null || true
fi
if nginx -t 2>/dev/null; then systemctl reload nginx || true; fi
printf '已从 %s 恢复。\n' "$backup_dir"
EOF
    chmod 0700 "$BACKUP_DIR/restore.sh"
}

do_backup() {
    local stamp existing=()
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    BACKUP_DIR="/root/sub-aggregator-uninstall-backup-$stamp-$$"
    install -d -m 0700 "$BACKUP_DIR"

    mapfile -t existing < <(existing_paths)
    if (( ${#existing[@]} > 0 )); then
        # -P 允许归档绝对路径；restore.sh 里按原位置解包。
        tar -czPf "$BACKUP_DIR/files.tar.gz" --absolute-names "${existing[@]}"
    fi
    write_restore_script
    log "备份：$BACKUP_DIR"
}

stop_services() {
    if [[ -f "$SYSTEMD_DIR/sub-rules-sync.timer" ]]; then
        systemctl disable --now sub-rules-sync.timer \
            || warn "停用 sub-rules-sync.timer 失败，继续。"
    fi
    if [[ -f "$SYSTEMD_DIR/sub-rules-sync.service" ]]; then
        systemctl stop sub-rules-sync.service 2>/dev/null || true
    fi
    if [[ -f "$SYSTEMD_DIR/subconverter.service" ]]; then
        systemctl disable --now subconverter.service \
            || warn "停用 subconverter.service 失败，继续。"
    fi
}

remove_path() {
    local p=$1
    if path_is_protected "$p"; then
        fail "拒绝删除受保护路径：$p"
    fi
    if [[ ! -e $p && ! -L $p ]]; then
        return 0
    fi
    rm -rf -- "$p"
    log "已删除 $p"
}

remove_nginx_configs() {
    local p
    for p in "${NGINX_SNIPPETS[@]}"; do remove_path "$NGINX_SNIPPETS_DIR/$p"; done
    for p in "${NGINX_CONFS[@]}"; do remove_path "$NGINX_CONF_D_DIR/$p"; done

    if have nginx && ! nginx -t; then
        warn "删除配置后 nginx -t 未通过，正在从备份恢复。"
        "$BACKUP_DIR/restore.sh" || fail "自动恢复失败，请手工运行 $BACKUP_DIR/restore.sh"
        fail "已中止卸载，配置已恢复。"
    fi
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx || warn "nginx reload 失败，检查 nginx -t 的输出。"
    fi
}

remove_units() {
    local p
    for p in "${SERVICE_UNITS[@]}"; do remove_path "$SYSTEMD_DIR/$p"; done
    systemctl daemon-reload || warn "systemctl daemon-reload 失败。"
    systemctl reset-failed subconverter.service sub-rules-sync.service \
        sub-rules-sync.timer 2>/dev/null || true
}

remove_scripts() {
    local p
    for p in "${MANAGER_SCRIPTS[@]}"; do remove_path "$SBIN_DIR/$p"; done
}

remove_state() {
    remove_path "$STATE_DIR"
    remove_path "$OPT_DIR"
    remove_path "$PUBLISH_DIR"
    remove_path "$NGINX_CACHE_DIR"
}

report_kept() {
    local p
    log ""
    log "未修改：x-ui、Xray、443、2096、/etc/x-ui/x-ui.db、证书、acme.sh、Nginx 本身。"
    for p in "${ACME_KEPT[@]}"; do
        [[ -e $p ]] && log "已保留 $p（证书续期链路）"
    done
    if [[ -n $RULES_WORKDIR && -d $RULES_WORKDIR ]]; then
        log "已保留 $RULES_WORKDIR（规则仓库工作副本）"
    fi
    if (( ${#HOSTS_LINES[@]} > 0 )); then
        log ""
        log "注意：$HOSTS_FILE 里仍有部署时手工加的回源映射，未修改："
        for p in "${HOSTS_LINES[@]}"; do log "  $p"; done
        log "确定不再需要时手工删除这些行。"
    fi
}

verify_uninstall() {
    local failed=0 p
    while IFS= read -r p; do
        warn "卸载后仍存在：$p"
        failed=1
    done < <(existing_paths)

    if have nginx && ! nginx -t >/dev/null 2>&1; then
        warn "nginx -t 未通过。"
        failed=1
    fi
    # 端口可能被无关进程占用，只提示，不算卸载失败。
    if ss -lntp 2>/dev/null | grep -qE ':(8443|25500)[[:space:]]'; then
        warn "8443 或 25500 仍在监听；若不是本服务残留，可能是其它进程占用。"
    fi
    return "$failed"
}

show_plan() {
    local p u
    log "卸载计划："
    log ""
    log "将停止并禁用："
    for u in "${SERVICE_UNITS[@]}"; do
        [[ -f "$SYSTEMD_DIR/$u" ]] && log "  $u"
    done
    log ""
    log "将删除："
    while IFS= read -r p; do log "  $p"; done < <(existing_paths)
    log ""
    log "将保留："
    log "  /etc/x-ui/x-ui.db            3x-ui 数据库（节点、客户端、UUID）"
    log "  x-ui / Xray / 443 / 2096     节点本身"
    log "  /root/cert/<域名>/           证书"
    log "  /root/.acme.sh/              acme.sh 与其续期配置"
    for p in "${ACME_KEPT[@]}"; do
        [[ -e $p ]] && log "  $p  证书续期链路"
    done
    if [[ -n $RULES_WORKDIR && -d $RULES_WORKDIR ]]; then
        log "  $RULES_WORKDIR  规则仓库工作副本"
    fi
    log "  nginx 包与运行中的进程"
    log ""
    log "备份会写到 /root/sub-aggregator-uninstall-backup-<时间戳>-<pid>/。"
}

main() {
    parse_args "$@"
    require_root
    detect_installed
    build_remove_paths
    collect_hosts_lines

    local existing=()
    mapfile -t existing < <(existing_paths)
    if (( ${#existing[@]} == 0 )); then
        log "未发现已安装的聚合层组件，无需卸载。"
        exit 0
    fi

    show_plan
    confirm "确认卸载以上 ${#existing[@]} 项？" || { log "已取消。"; exit 0; }

    do_backup
    stop_services
    remove_nginx_configs
    remove_units
    remove_scripts
    remove_state
    report_kept

    local verify_ok=0
    verify_uninstall || verify_ok=1

    log ""
    if (( verify_ok == 0 )); then
        log "卸载完成，验证通过。"
    else
        warn "卸载完成，但有残留或配置错误（见上方警告）。"
    fi
    log "恢复：$BACKUP_DIR/restore.sh"
    log "重新部署：$REPO_ROOT/tools/deploy.sh"
    exit "$verify_ok"
}

main "$@"
