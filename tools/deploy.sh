#!/usr/bin/env bash
# sub-aggregator 首次部署脚本。
#
# 唯一实现，部署只走这份脚本。默认逐步确认；--dry-run 只打印计划，
# 不做任何修改；--yes 跳过逐步确认。所有替换都在临时目录里完成，
# 不会改动仓库工作副本。
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROGRAM="${0##*/}"

# 下列安装路径与 docs/sub/README.md §3.2 是同一份清单，改一处必须同步另一处。
readonly XUI_DB="/etc/x-ui/x-ui.db"
readonly SBIN_DIR="/usr/local/sbin"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
readonly NGINX_CONF_D_DIR="/etc/nginx/conf.d"
readonly OPT_DIR="/opt/subconverter-classic"
readonly PUBLISH_DIR="/var/lib/sub-rules"
readonly DEFAULT_RULES_WORKDIR="/root/code/shadowrocket-config"
readonly DEFAULT_RULES_REPO="DuskWander87/shadowrocket-config"
readonly SUBCONVERTER_VERSION="v0.9.9"
readonly SUBCONVERTER_URL="https://github.com/asdlokj1qpi233/subconverter/releases/download/${SUBCONVERTER_VERSION}/subconverter_linux64.tar.gz"

DOMAIN=""
CERT_DIR=""
PROFILE_NAME=""
RULES_PREFIX=""
RULES_REPO=""
RULES_WORKDIR="$DEFAULT_RULES_WORKDIR"
WITH_RULES=0
DRY_RUN=0
ASSUME_YES=0
ROLLBACK_DIR=""
WORK_DIR=""
BACKUP_DIR=""
INSTALL_TARGETS=()

usage() {
    cat <<'EOF'
用法：
  deploy.sh [选项]

选项：
  --domain <域名>           订阅域名
  --cert-dir <目录>         证书目录，含 fullchain.pem 和 privkey.pem
  --profile-name <名称>     订阅显示名，纯 ASCII
  --rules-prefix <hex>      规则端点前缀，默认随机生成 24 位 hex
  --rules-repo <owner/repo> 规则仓库，默认 DuskWander87/shadowrocket-config
  --rules-workdir <目录>    规则仓库本机工作副本，默认 /root/code/shadowrocket-config
  --with-rules              启用规则同步定时器；默认使用作者的规则集
  --dry-run                 只打印计划，不做修改
  --yes, -y                 跳过逐步确认
  --rollback <备份目录>     从备份目录恢复
  -h, --help                显示这份帮助

不带参数时逐项询问缺少的值。
EOF
}

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
warn() { printf '警告：%s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ $EUID -eq 0 ]] || fail "必须以 root 运行。"
}

confirm() {
    local prompt=$1 answer
    [[ $ASSUME_YES -eq 1 ]] && return 0
    [[ -t 0 ]] || fail "需要交互确认，但当前不是终端。加 --yes 或手工执行。"
    printf '%s [y/n] ' "$prompt" >&2
    IFS= read -r answer
    answer=${answer,,}
    [[ $answer == y || $answer == yes ]]
}

opt_value() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "$1 需要一个值。"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) opt_value "$@"; DOMAIN=$2; shift 2 ;;
            --cert-dir) opt_value "$@"; CERT_DIR=$2; shift 2 ;;
            --profile-name) opt_value "$@"; PROFILE_NAME=$2; shift 2 ;;
            --rules-prefix) opt_value "$@"; RULES_PREFIX=$2; shift 2 ;;
            --rules-repo) opt_value "$@"; RULES_REPO=$2; shift 2 ;;
            --rules-workdir) opt_value "$@"; RULES_WORKDIR=$2; shift 2 ;;
            --with-rules) WITH_RULES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --rollback) opt_value "$@"; ROLLBACK_DIR=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) fail "未知参数：$1（用 --help 查看用法）" ;;
        esac
    done
}

prompt_value() {
    local var=$1 label=$2 default=${3:-} value
    [[ -n ${!var} ]] && return 0
    if [[ ! -t 0 ]]; then
        [[ -n $default ]] || fail "缺少 $label，且当前不是交互式终端。请用参数传入。"
        printf -v "$var" '%s' "$default"
        return 0
    fi
    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r value
    [[ -n $value ]] || value=$default
    [[ -n $value ]] || fail "$label 不能为空。"
    printf -v "$var" '%s' "$value"
}

detect_existing_values() {
    # 重装时复用已安装的值，避免静默换掉规则前缀或域名。
    if [[ -z $DOMAIN && -r "$SBIN_DIR/sub-manager" ]]; then
        DOMAIN=$(sed -n 's/^readonly HOST="\(.*\)"$/\1/p' "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    if [[ -z $CERT_DIR && -r "$SBIN_DIR/sub-manager" ]]; then
        CERT_DIR=$(sed -n 's|^readonly CERT_FILE="\(.*\)/fullchain.pem"$|\1|p' \
            "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    if [[ -z $PROFILE_NAME && -r "$SBIN_DIR/sub-manager" ]]; then
        PROFILE_NAME=$(sed -n 's/^readonly PROFILE_NAME="\(.*\)"$/\1/p' \
            "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    if [[ -z $RULES_PREFIX && -r "$NGINX_SNIPPETS_DIR/sub-rules.conf" ]]; then
        RULES_PREFIX=$(sed -n 's|.*location = /r/\([0-9a-f]\{16,64\}\)/.*|\1|p' \
            "$NGINX_SNIPPETS_DIR/sub-rules.conf" | head -n 1)
    fi
    if [[ -z $RULES_REPO && -r "$NGINX_SNIPPETS_DIR/sub-rules.conf" ]]; then
        RULES_REPO=$(sed -n 's|.*proxy_pass https://$sub_rules_upstream/\([^/]*/[^/]*\)/main/.*|\1|p' \
            "$NGINX_SNIPPETS_DIR/sub-rules.conf" | head -n 1)
    fi
    if [[ -r "$SBIN_DIR/sub-rules-sync" && $RULES_WORKDIR == "$DEFAULT_RULES_WORKDIR" ]]; then
        RULES_WORKDIR=$(sed -n 's/^REPO_DIR=\(.*\)$/\1/p' \
            "$SBIN_DIR/sub-rules-sync" | head -n 1)
    fi
}

prompt_values() {
    prompt_value DOMAIN "订阅域名" ""
    prompt_value CERT_DIR "证书目录（含 fullchain.pem 和 privkey.pem）" "/root/cert/$DOMAIN"
    prompt_value PROFILE_NAME "订阅显示名（纯 ASCII）" "sub-aggregator"
    [[ -n $RULES_PREFIX ]] || RULES_PREFIX=$(openssl rand -hex 12)
    [[ -n $RULES_REPO ]] || RULES_REPO=$DEFAULT_RULES_REPO
}

validate_values() {
    [[ -n $DOMAIN ]] || fail "域名不能为空。"
    [[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || fail "域名格式无效：$DOMAIN"
    [[ $DOMAIN == *.* ]] || fail "域名必须包含点号：$DOMAIN"
    [[ -n $CERT_DIR && $CERT_DIR == /* ]] || fail "证书目录必须是绝对路径。"
    CERT_DIR=${CERT_DIR%/}
    [[ -n $CERT_DIR ]] || fail "证书目录不能是 /。"
    [[ -n $PROFILE_NAME ]] || fail "显示名不能为空。"
    [[ $PROFILE_NAME =~ ^[A-Za-z0-9._-]+$ ]] \
        || fail "显示名只允许 ASCII 字母、数字、点、下划线、连字符。"
    [[ $RULES_PREFIX =~ ^[0-9a-f]{16,64}$ ]] \
        || fail "规则前缀必须是 16 到 64 位小写十六进制。"
    [[ -n $RULES_REPO && $RULES_REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
        || fail "规则仓库格式应为 owner/repo。"
    [[ $RULES_WORKDIR == /* ]] || fail "规则工作副本必须是绝对路径。"
    local value
    for value in "$DOMAIN" "$CERT_DIR" "$PROFILE_NAME" "$RULES_REPO" "$RULES_WORKDIR"; do
        [[ $value != *'|'* && $value != *$'\n'* ]] \
            || fail "值不能包含 | 或换行：$value"
    done
}

preflight() {
    require_root
    local cmd
    for cmd in curl jq sqlite3 openssl flock nginx systemctl tar install sed grep mktemp getent ss awk; do
        have "$cmd" || fail "缺少命令：$cmd"
    done
    if [[ $WITH_RULES -eq 1 ]]; then
        have git || fail "缺少命令：git（--with-rules 需要）"
    fi
    [[ -r $XUI_DB ]] || fail "读不到 3x-ui 数据库：$XUI_DB。先确认 3x-ui 已安装。"
    systemctl is-active --quiet x-ui.service || fail "x-ui.service 未运行。"
    [[ -f "$CERT_DIR/fullchain.pem" ]] || fail "证书不存在：$CERT_DIR/fullchain.pem"
    [[ -f "$CERT_DIR/privkey.pem" ]] || fail "私钥不存在：$CERT_DIR/privkey.pem"

    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    (( mem_mb >= 1800 )) || warn "内存只有 ${mem_mb} MB，建议至少 2 GB。"

    if getent hosts "$DOMAIN" >/dev/null 2>&1; then
        log "域名解析：$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n 1)"
    else
        warn "域名 $DOMAIN 当前解析不到，确认 DNS 已生效。"
    fi

    if ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE '[:.]8443$'; then
        if ss -lntp 2>/dev/null | grep -E '[:.]8443[[:space:]]' | grep -q 'nginx'; then
            warn "端口 8443 已有 nginx 监听，将复用现有 Nginx。"
        else
            fail "端口 8443 已被其他进程占用。"
        fi
    fi
    systemctl is-active --quiet nginx.service || warn "nginx.service 未运行，稍后会启动。"
}

init_targets() {
    INSTALL_TARGETS=(
        "$SBIN_DIR/sub-manager"
        "$SBIN_DIR/sub-rules-sync"
        "$SBIN_DIR/sub-rules-check"
        "$SYSTEMD_DIR/subconverter.service"
        "$SYSTEMD_DIR/sub-rules-sync.service"
        "$SYSTEMD_DIR/sub-rules-sync.timer"
        "$OPT_DIR/subconverter"
        "$OPT_DIR/pref.ini"
        "$OPT_DIR/base"
        "$OPT_DIR/snippets"
        "$OPT_DIR/rules"
        "$OPT_DIR/config"
        "$NGINX_SNIPPETS_DIR/sub-rules.conf"
        "$NGINX_SNIPPETS_DIR/sub-rules-common.conf"
        "$NGINX_SNIPPETS_DIR/sub-rules-upstream.conf"
        "$NGINX_CONF_D_DIR/sub-rules-cache.conf"
        "$NGINX_CONF_D_DIR/private-sub.conf"
    )
    if [[ $WITH_RULES -eq 1 ]]; then
        INSTALL_TARGETS+=("$PUBLISH_DIR")
    fi
}

print_plan() {
    local repo_display=$RULES_REPO
    cat <<EOF
部署计划

  域名:           $DOMAIN
  证书目录:       $CERT_DIR
  订阅显示名:     $PROFILE_NAME
  规则端点前缀:   $RULES_PREFIX
  规则仓库:       $repo_display
  规则工作副本:   $RULES_WORKDIR

  将安装:
    $SBIN_DIR/sub-manager
    $SBIN_DIR/sub-rules-sync
    $SBIN_DIR/sub-rules-check
    $SYSTEMD_DIR/subconverter.service
    $SYSTEMD_DIR/sub-rules-sync.service
    $SYSTEMD_DIR/sub-rules-sync.timer
    $OPT_DIR/{pref.ini,base/,snippets/}
    $NGINX_SNIPPETS_DIR/sub-rules.conf
    $NGINX_SNIPPETS_DIR/sub-rules-common.conf
    $NGINX_SNIPPETS_DIR/sub-rules-upstream.conf
    $NGINX_CONF_D_DIR/sub-rules-cache.conf

  将重启/重载:
    subconverter
    nginx

  备份目录:
    $BACKUP_DIR

  规则链:
    $(if [[ $WITH_RULES -eq 1 ]]; then echo "启用 sub-rules-sync.timer（工作副本不存在时自动克隆 $RULES_REPO）"; else echo "不启用（需要时加 --with-rules）"; fi)
EOF
}

sed_pattern() { printf '%s' "$1" | sed 's/[\\.]/\\&/g'; }
sed_replacement() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }

replace_literal() {
    local file=$1 old=$2 new=$3 pattern replacement
    [[ -f $file ]] || fail "替换目标不存在：$file"
    pattern=$(sed_pattern "$old")
    replacement=$(sed_replacement "$new")
    sed -i "s|$pattern|$replacement|g" "$file"
}

replace_in_files() {
    local old=$1 new=$2 file
    while IFS= read -r file; do
        replace_literal "$file" "$old" "$new"
    done < <(grep -rlF -- "$old" "$WORK_DIR/server" 2>/dev/null || true)
}

apply_placeholders() {
    local stage="$WORK_DIR/server"

    # 证书目录含域名占位符，先替换它，再替换域名。
    replace_literal "$stage/sbin/sub-manager" "/root/cert/sub.example.com" "$CERT_DIR"
    # sub-rules-check 的 grep -E 模式里转义了点号。
    replace_literal "$stage/sbin/sub-rules-check" 'sub\.example\.com' "${DOMAIN//./\\.}"

    replace_in_files 'sub.example.com' "$DOMAIN"
    replace_in_files '<RULES_PREFIX>' "$RULES_PREFIX"

    # 只改 PROFILE_NAME 常量和用法示例，避免误伤 DuskWander87。
    replace_literal "$stage/sbin/sub-manager" 'PROFILE_NAME="DuskWander"' \
        "PROFILE_NAME=\"$PROFILE_NAME\""
    replace_literal "$stage/sbin/sub-manager" '#DuskWander' "#$PROFILE_NAME"

    if [[ -n $RULES_REPO && $RULES_REPO != "$DEFAULT_RULES_REPO" ]]; then
        replace_in_files "$DEFAULT_RULES_REPO" "$RULES_REPO"
    fi
    if [[ $RULES_WORKDIR != "$DEFAULT_RULES_WORKDIR" ]]; then
        replace_in_files "$DEFAULT_RULES_WORKDIR" "$RULES_WORKDIR"
    fi
}

stage() {
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    cp -a "$REPO_ROOT/server/." "$WORK_DIR/server/"
    apply_placeholders
}

backup_path() {
    local p=$1
    if [[ -e $p ]]; then
        mkdir -p "$BACKUP_DIR$(dirname -- "$p")"
        cp -a -- "$p" "$BACKUP_DIR$p"
        printf '%s\n' "$p" >>"$BACKUP_DIR/restore.list"
    else
        printf '%s\n' "$p" >>"$BACKUP_DIR/remove.list"
    fi
}

write_restore_script() {
    cat >"$BACKUP_DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
backup_dir=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ -s $backup_dir/restore.list ]]; then
    while IFS= read -r p; do
        [[ -e "$backup_dir$p" ]] || continue
        mkdir -p "$(dirname -- "$p")"
        rm -rf -- "$p"
        cp -a "$backup_dir$p" "$p"
    done <"$backup_dir/restore.list"
fi
if [[ -s $backup_dir/remove.list ]]; then
    while IFS= read -r p; do
        rm -rf -- "$p"
    done <"$backup_dir/remove.list"
fi
systemctl daemon-reload || true
if nginx -t; then systemctl reload nginx || true; fi
systemctl restart subconverter 2>/dev/null || true
printf '已从 %s 恢复。\n' "$backup_dir"
EOF
    chmod 0700 "$BACKUP_DIR/restore.sh"
}

do_backup() {
    install -d -m 0700 "$BACKUP_DIR"
    : >"$BACKUP_DIR/restore.list"
    : >"$BACKUP_DIR/remove.list"
    local p
    for p in "${INSTALL_TARGETS[@]}"; do
        backup_path "$p"
    done
    write_restore_script
}

install_files() {
    local stage="$WORK_DIR/server"

    install -d -m 0755 "$OPT_DIR"
    if [[ ! -x "$OPT_DIR/subconverter" ]]; then
        log "下载 subconverter $SUBCONVERTER_VERSION"
        curl -fL --retry 3 --max-time 120 \
            -o "$WORK_DIR/subconverter.tar.gz" "$SUBCONVERTER_URL"
        tar -xzf "$WORK_DIR/subconverter.tar.gz" --strip-components=1 -C "$OPT_DIR"
    else
        log "已存在 $OPT_DIR/subconverter，跳过下载。"
    fi

    install -d -m 0755 "$OPT_DIR/base" "$OPT_DIR/snippets"
    install -m 0644 "$stage/subconverter/pref.ini" "$OPT_DIR/pref.ini"
    cp -a "$stage/subconverter/base/." "$OPT_DIR/base/"
    cp -a "$stage/subconverter/snippets/." "$OPT_DIR/snippets/"

    install -m 0700 "$stage/sbin/sub-manager" "$stage/sbin/sub-rules-sync" "$SBIN_DIR/"
    install -m 0750 "$stage/sbin/sub-rules-check" "$SBIN_DIR/"
    install -m 0644 "$stage/systemd/subconverter.service" \
        "$stage/systemd/sub-rules-sync.service" \
        "$stage/systemd/sub-rules-sync.timer" "$SYSTEMD_DIR/"
    install -m 0644 "$stage/nginx/snippets/sub-rules.conf" \
        "$stage/nginx/snippets/sub-rules-common.conf" \
        "$stage/nginx/snippets/sub-rules-upstream.conf" "$NGINX_SNIPPETS_DIR/"
    install -m 0644 "$stage/nginx/conf.d/sub-rules-cache.conf" "$NGINX_CONF_D_DIR/"

    systemctl daemon-reload
    systemctl enable subconverter
    systemctl restart subconverter
    curl -fsS --max-time 10 --retry 3 --retry-delay 1 \
        http://127.0.0.1:25500/version >/dev/null \
        || fail "subconverter 未在 127.0.0.1:25500 响应。"

    # 重装时按新常量重建已有的 Nginx 配置；首次安装还没有这个文件。
    if [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]]; then
        "$SBIN_DIR/sub-manager" resync
    fi

    nginx -t
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx
    else
        systemctl enable --now nginx
    fi
}

add_subscription() {
    if [[ ! -t 0 ]]; then
        warn "当前不是交互式终端，跳过创建订阅。"
        printf '请手工运行：%s add --from-xui\n' "$SBIN_DIR/sub-manager" >&2
        return 0
    fi
    confirm "现在创建第一条订阅？" || { log "已跳过。"; return 0; }
    "$SBIN_DIR/sub-manager" add --from-xui
    "$SBIN_DIR/sub-manager" test
}

setup_rules() {
    [[ $WITH_RULES -eq 1 ]] || return 0

    if [[ ! -d "$RULES_WORKDIR/.git" ]]; then
        if [[ -e "$RULES_WORKDIR" ]]; then
            fail "$RULES_WORKDIR 已存在但不是 git 仓库，拒绝覆盖。"
        fi
        log "克隆规则仓库 $RULES_REPO 到 $RULES_WORKDIR"
        install -d -m 0755 "$(dirname -- "$RULES_WORKDIR")"
        git clone "https://github.com/${RULES_REPO}.git" "$RULES_WORKDIR"
    fi

    [[ -s "$RULES_WORKDIR/rules/ChinaDirect.list" ]] \
        || fail "规则仓库缺少 $RULES_WORKDIR/rules/ChinaDirect.list"
    [[ -s "$RULES_WORKDIR/rules/Reject.list" ]] \
        || fail "规则仓库缺少 $RULES_WORKDIR/rules/Reject.list"

    install -d -m 0755 "$PUBLISH_DIR"
    systemctl enable --now sub-rules-sync.timer
    "$SBIN_DIR/sub-rules-sync" -v \
        || warn "首次规则同步失败，检查 $RULES_WORKDIR 和网络。"
    "$SBIN_DIR/sub-rules-check" \
        || warn "规则链路检查未通过；确认已经至少创建一条订阅。"
}

do_rollback() {
    [[ -d $ROLLBACK_DIR ]] || fail "备份目录不存在：$ROLLBACK_DIR"
    [[ -x "$ROLLBACK_DIR/restore.sh" ]] \
        || fail "备份目录里没有 restore.sh：$ROLLBACK_DIR"
    confirm "从 $ROLLBACK_DIR 恢复？" || { log "已取消。"; exit 0; }
    "$ROLLBACK_DIR/restore.sh"
}

on_error() {
    local rc=$?
    printf '\n错误：部署中断（退出码 %s）。\n' "$rc" >&2
    if [[ -n $BACKUP_DIR && -d $BACKUP_DIR ]]; then
        printf '备份目录：%s\n' "$BACKUP_DIR" >&2
        printf '回滚命令：%s --rollback %s\n' \
            "$REPO_ROOT/tools/deploy.sh" "$BACKUP_DIR" >&2
    fi
    exit "$rc"
}

main() {
    parse_args "$@"

    [[ -d "$REPO_ROOT/server" ]] || fail "找不到仓库根目录：$REPO_ROOT"

    if [[ -n $ROLLBACK_DIR ]]; then
        require_root
        do_rollback
        return 0
    fi

    detect_existing_values
    prompt_values
    validate_values
    preflight

    BACKUP_DIR="/root/sub-aggregator-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    init_targets
    print_plan

    if [[ $DRY_RUN -eq 1 ]]; then
        log "dry-run：未做任何修改。"
        return 0
    fi

    confirm "按上面的计划继续？" || { log "已取消。"; return 0; }

    do_backup
    stage
    install_files
    add_subscription
    setup_rules

    log ""
    log "完成。备份在 $BACKUP_DIR。"
    log "回滚：$REPO_ROOT/tools/deploy.sh --rollback $BACKUP_DIR"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap on_error ERR
    main "$@"
fi
