#!/usr/bin/env bash
# sub-aggregator 首次部署脚本。
#
# 唯一实现，部署只走这份脚本。默认逐步确认；--dry-run 只打印计划，
# 不做任何修改；--yes 跳过逐步确认。所有替换都在临时目录里完成，
# 不会改动仓库工作副本。
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

# 证书默认落点与 ACME 挑战路径。80 端口的 server 块见 server/nginx/conf.d/acme-challenge.conf。
readonly DEFAULT_CERT_ROOT="/root/cert"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_WEBROOT="/var/www/acme"
readonly ACME_NGINX_CONF="$NGINX_CONF_D_DIR/acme-challenge.conf"

DOMAIN=""
DOMAIN_CANDIDATE=""
DOMAIN_SOURCE=""
CERT_DIR=""
PROFILE_NAME=""
RULES_PREFIX=""
RULES_REPO=""
RULES_WORKDIR="$DEFAULT_RULES_WORKDIR"
ACME_EMAIL=""
WITH_RULES=0
DRY_RUN=0
ASSUME_YES=0
INSTALL_DEPS_ONLY=0
ISSUE_CERT=1
CERT_NEEDS_ISSUE=0
ROLLBACK_DIR=""
WORK_DIR=""
BACKUP_DIR=""
INSTALL_TARGETS=()

usage() {
    cat <<'EOF'
用法：
  deploy.sh [选项]

选项：
  --domain <域名>           订阅域名；省略时从 3x-ui 配置或证书自动推导
  --cert-dir <目录>         证书目录；默认自动查找，缺失时签发到 /root/cert/<域名>
  --acme-email <邮箱>       首次安装 acme.sh 时注册账户用，可留空
  --no-issue-cert           缺少证书时不自动签发，直接报错
  --profile-name <名称>     订阅显示名，纯 ASCII（默认 DuskWander87）
  --rules-prefix <hex>      规则端点前缀，默认随机生成 24 位 hex
  --rules-repo <owner/repo> 规则仓库，默认 DuskWander87/shadowrocket-config
  --rules-workdir <目录>    规则仓库本机工作副本，默认 /root/code/shadowrocket-config
  --with-rules              启用规则同步定时器；默认使用作者的规则集
  --dry-run                 只打印计划，不做修改
  --install-deps            只安装缺失的依赖命令，然后退出
  --yes, -y                 跳过逐步确认；依赖缺失时直接安装
  --rollback <备份目录>     从备份目录恢复
  -h, --help                显示这份帮助

不带参数时逐项询问缺少的值。
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
            --acme-email) opt_value "$@"; ACME_EMAIL=$2; shift 2 ;;
            --no-issue-cert) ISSUE_CERT=0; shift ;;
            --profile-name) opt_value "$@"; PROFILE_NAME=$2; shift 2 ;;
            --rules-prefix) opt_value "$@"; RULES_PREFIX=$2; shift 2 ;;
            --rules-repo) opt_value "$@"; RULES_REPO=$2; shift 2 ;;
            --rules-workdir) opt_value "$@"; RULES_WORKDIR=$2; shift 2 ;;
            --with-rules) WITH_RULES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --install-deps) INSTALL_DEPS_ONLY=1; shift ;;
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
        # 把「回车会发生什么」写清楚，而不是只把默认值放在方括号里。
        printf '%s（回车使用默认值 %s）: ' "$label" "$default" >&2
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

is_domain() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ $value == *.* ]] || return 1
    [[ ! $value =~ ^[0-9.]+$ ]] || return 1
    return 0
}

# 从证书的 SAN 取域名；只有一个可用的 DNS 名时才返回，通配符和 IP 跳过。
cert_domain() {
    local cert=$1 names name count=0 result=""
    [[ -r $cert ]] || return 1
    names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS:[[:space:]]*\(.*\)$/\1/p')
    if [[ -z $names ]]; then
        names=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null \
            | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p')
    fi
    while IFS= read -r name; do
        name=${name//[[:space:]]/}
        is_domain "$name" || continue
        count=$((count + 1))
        result=$name
    done <<<"$names"
    (( count == 1 )) || return 1
    printf '%s\n' "$result"
}

# 3x-ui 自己记录的域名。不能用入站的 Reality SNI：那是目标站域名，不是订阅域名。
detect_domain_from_xui() {
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -r $XUI_DB ]] || return 1
    systemctl is-active --quiet x-ui.service 2>/dev/null || return 1

    local key value cert
    for key in subDomain webDomain; do
        value=$(xui_query "select value from settings where key = '$key';" 2>/dev/null) || continue
        value=${value#http://}
        value=${value#https://}
        value=${value%%/*}
        if [[ $value =~ ^([^:]+):[0-9]+$ ]]; then
            value=${BASH_REMATCH[1]}
        fi
        is_domain "$value" || continue
        DOMAIN_CANDIDATE=$value
        DOMAIN_SOURCE="3x-ui $key"
        return 0
    done
    for key in subCertFile webCertFile; do
        cert=$(xui_query "select value from settings where key = '$key';" 2>/dev/null) || continue
        [[ -r $cert ]] || continue
        value=$(cert_domain "$cert") || continue
        DOMAIN_CANDIDATE=$value
        DOMAIN_SOURCE="3x-ui $key 的证书"
        return 0
    done
    return 1
}

# 兜底：/root/cert 下只有一个域名证书时直接用它。
detect_domain_from_certs() {
    local file dir value found=""
    for file in "$DEFAULT_CERT_ROOT"/*/fullchain.pem; do
        [[ -r $file ]] || continue
        dir=$(basename -- "$(dirname -- "$file")")
        if is_domain "$dir"; then
            value=$dir
        else
            value=$(cert_domain "$file") || continue
        fi
        [[ -z $found ]] || return 1
        found=$value
    done
    [[ -n $found ]] || return 1
    DOMAIN_CANDIDATE=$found
    DOMAIN_SOURCE="$DEFAULT_CERT_ROOT 下唯一的证书"
    return 0
}

detect_domain() {
    [[ -n $DOMAIN ]] && return 0
    DOMAIN_CANDIDATE=""
    DOMAIN_SOURCE=""
    if detect_domain_from_xui || detect_domain_from_certs; then
        DOMAIN=$DOMAIN_CANDIDATE
        log "域名：从 $DOMAIN_SOURCE 推导为 $DOMAIN"
    fi
}

cert_files_ok() {
    [[ -s "$1/fullchain.pem" && -s "$1/privkey.pem" ]]
}

acme_conf_file() {
    local domain=$1 file
    for file in "$ACME_HOME/${domain}_ecc/${domain}.conf" "$ACME_HOME/${domain}/${domain}.conf"; do
        if [[ -r $file ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

acme_installed_paths() {
    # 输出来自 acme.sh install-cert 的证书目录。两个路径不在同一目录时返回非零，
    # sub-manager 只接受一个目录。
    local conf=$1 full key
    full=$(sed -n "s/^Le_RealFullChainPath='\(.*\)'$/\1/p" "$conf" | head -n 1)
    key=$(sed -n "s/^Le_RealKeyPath='\(.*\)'$/\1/p" "$conf" | head -n 1)
    [[ -n $full && -n $key ]] || return 1
    [[ $(dirname -- "$full") == "$(dirname -- "$key")" ]] || return 1
    dirname -- "$full"
}

# 证书目录从域名推导，不再向用户提问。查找顺序：默认目录 → certbot → acme.sh 安装记录，
# 都没有时签发到默认目录。--cert-dir 仍然可以覆盖。
resolve_cert_dir() {
    local candidate conf

    if [[ -z $CERT_DIR ]]; then
        for candidate in "$DEFAULT_CERT_ROOT/$DOMAIN" "/etc/letsencrypt/live/$DOMAIN"; do
            if cert_files_ok "$candidate"; then
                CERT_DIR=$candidate
                log "证书：复用 $CERT_DIR"
                return 0
            fi
        done
        if conf=$(acme_conf_file "$DOMAIN") && candidate=$(acme_installed_paths "$conf") \
            && cert_files_ok "$candidate"; then
            CERT_DIR=$candidate
            log "证书：复用 $CERT_DIR（来自 acme.sh 安装记录）"
            return 0
        fi
        CERT_DIR="$DEFAULT_CERT_ROOT/$DOMAIN"
    fi

    if cert_files_ok "$CERT_DIR"; then
        log "证书：复用 $CERT_DIR"
        return 0
    fi
    if [[ $ISSUE_CERT -eq 0 ]]; then
        fail "证书不完整：$CERT_DIR（需要 fullchain.pem 和 privkey.pem）。用 --cert-dir 指定位置，或去掉 --no-issue-cert。"
    fi
    CERT_NEEDS_ISSUE=1
    log "证书：未找到，将用 acme.sh 签发到 $CERT_DIR"
}

prompt_acme_email() {
    # 邮箱只在首次安装 acme.sh 时用到；已经装好的账户可以留空。
    [[ $CERT_NEEDS_ISSUE -eq 1 ]] || return 0
    if [[ -n $ACME_EMAIL || -x "$ACME_HOME/acme.sh" || ! -t 0 ]]; then
        return 0
    fi
    local value
    printf '用于注册 ACME 账户的邮箱（可留空）: ' >&2
    IFS= read -r value
    ACME_EMAIL=$value
}

prompt_values() {
    prompt_value DOMAIN "订阅域名" ""
    prompt_value PROFILE_NAME "订阅显示名，纯 ASCII" "DuskWander87"
}

fill_defaults() {
    # openssl 可能刚由 ensure_dependencies 装上，所以放在依赖处理之后。
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

xui_query() {
    # 与 sub-manager 相同的读法：x-ui.db 是 journal_mode=delete，写事务会阻塞读，
    # .timeout 给 3 秒重试窗口。空结果和读失败由调用方分开判断。
    sqlite3 -readonly -noheader -cmd '.timeout 3000' \
        "file:${XUI_DB}?mode=ro" "$1"
}

# 命令 → apt 包。只安装缺失命令对应的包；未列出的命令视为基础系统自带，缺失时直接报错，
# 不盲目装包。
command_package() {
    case $1 in
        curl) printf '%s\n' curl ;;
        jq) printf '%s\n' jq ;;
        sqlite3) printf '%s\n' sqlite3 ;;
        openssl) printf '%s\n' openssl ;;
        flock) printf '%s\n' util-linux ;;
        nginx) printf '%s\n' nginx ;;
        systemctl) printf '%s\n' systemd ;;
        tar) printf '%s\n' tar ;;
        install|mktemp) printf '%s\n' coreutils ;;
        sed) printf '%s\n' sed ;;
        grep) printf '%s\n' grep ;;
        getent) printf '%s\n' libc-bin ;;
        ss) printf '%s\n' iproute2 ;;
        awk) printf '%s\n' gawk ;;
        git) printf '%s\n' git ;;
        *) return 1 ;;
    esac
}

# 收集缺失命令及对应包。有缺失时返回 0，全部就绪时返回 1。
# 结果放在全局变量里，避免在命令替换的子 shell 中 fail 只退出子 shell。
MISSING_COMMANDS=()
MISSING_PACKAGES=()

collect_missing_dependencies() {
    local cmd pkg existing
    local -a commands=(
        curl jq sqlite3 openssl flock nginx systemctl tar
        install sed grep mktemp getent ss awk
    )
    [[ $WITH_RULES -eq 1 ]] && commands+=(git)

    MISSING_COMMANDS=()
    MISSING_PACKAGES=()
    for cmd in "${commands[@]}"; do
        if have "$cmd"; then
            continue
        fi
        MISSING_COMMANDS+=("$cmd")
        pkg=$(command_package "$cmd") \
            || fail "缺少命令 $cmd，且不知道它属于哪个 apt 包；请手工安装后重跑。"
        for existing in "${MISSING_PACKAGES[@]}"; do
            [[ $existing == "$pkg" ]] && continue 2
        done
        MISSING_PACKAGES+=("$pkg")
    done
    ((${#MISSING_COMMANDS[@]} > 0))
}

ensure_dependencies() {
    collect_missing_dependencies || return 0

    local cmd still=()
    local cmd_list="${MISSING_COMMANDS[*]}"
    local pkg_list="${MISSING_PACKAGES[*]}"

    warn "缺少依赖命令：$cmd_list（对应包：$pkg_list）"

    # dry-run 只读：只报告，不安装。安装走独立的 --install-deps。
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    安装：%s --install-deps\n' "${BASH_SOURCE[0]}" >&2
        return 0
    fi

    if [[ $ASSUME_YES -eq 0 && ! -t 0 ]]; then
        fail "当前不是交互式终端，无法确认安装。手工执行：apt-get update && apt-get install -y $pkg_list（或加 --yes 自动安装）"
    fi
    if ! confirm "现在安装依赖？"; then
        fail "未安装依赖。手工执行：apt-get update && apt-get install -y $pkg_list"
    fi

    log "运行 apt-get update"
    apt-get update
    log "安装：$pkg_list"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"

    for cmd in "${MISSING_COMMANDS[@]}"; do
        have "$cmd" || still+=("$cmd")
    done
    ((${#still[@]} == 0)) || fail "安装后仍缺少命令：${still[*]}"
    log "依赖已就绪。"
}

preflight() {
    require_root

    [[ -r $XUI_DB ]] || fail "读不到 3x-ui 数据库：$XUI_DB。先确认 3x-ui 已安装。"
    systemctl is-active --quiet x-ui.service || fail "x-ui.service 未运行。"

    # 3x-ui 只做检查，不改面板。443 入站缺失时订阅里的节点不可用，但聚合服务本身仍能装。
    # sqlite3 缺失时上面已经报过依赖，这里不再重复一条误导性的「读取失败」。
    local inbound443
    if have sqlite3; then
        if inbound443=$(xui_query "select count(*) from inbounds where port = 443;" 2>/dev/null) \
            && [[ -n $inbound443 ]]; then
            if [[ ! $inbound443 =~ ^[0-9]+$ ]] || ((inbound443 == 0)); then
                warn "3x-ui 没有监听 443 的入站，订阅里的节点可能不可用。"
            fi
        else
            warn "读取 3x-ui 入站列表失败（可能写事务阻塞），跳过 443 入站检查。"
        fi
    fi

    local sub_listen="" entry bad=0
    local -a entries=()
    # dry-run 允许在缺依赖的机器上跑，ss 缺失时跳过端口检查而不是中断。
    if have ss; then
        sub_listen=$(ss -lnt 2>/dev/null | awk '$4 ~ /:2096$/ {print $4}' | paste -sd, -)
    fi
    if [[ -z $sub_listen ]]; then
        warn "2096 未监听：3x-ui 订阅服务可能未启用，原生分支不可用。"
    else
        IFS=, read -r -a entries <<<"$sub_listen"
        for entry in "${entries[@]}"; do
            [[ $entry == "127.0.0.1:2096" || $entry == "[::1]:2096" ]] || bad=1
        done
        if [[ $bad -eq 0 ]]; then
            log "2096：仅回环监听"
        else
            warn "2096 未收口到回环地址（当前 $sub_listen），见 deploy.md §3.5。"
        fi
    fi

    if [[ $CERT_NEEDS_ISSUE -eq 1 ]]; then
        if [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]]; then
            fail "现有 $NGINX_CONF_D_DIR/private-sub.conf 引用的证书缺失，Nginx 无法重载。先恢复证书，或删掉该文件后重跑。"
        fi
        if have ss \
            && ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$' \
            && ! ss -lntp 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q 'nginx'; then
            fail "端口 80 已被其他进程占用，ACME HTTP-01 无法通过。先释放 80 端口。"
        fi
        log "证书：将用 acme.sh 通过 webroot $ACME_WEBROOT 签发"
        [[ -x "$ACME_HOME/acme.sh" ]] \
            || warn "acme.sh 未安装；部署时自动安装，也可先执行 curl https://get.acme.sh | sh"
    else
        [[ -f "$CERT_DIR/fullchain.pem" ]] || fail "证书不存在：$CERT_DIR/fullchain.pem"
        [[ -f "$CERT_DIR/privkey.pem" ]] || fail "私钥不存在：$CERT_DIR/privkey.pem"
    fi

    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    (( mem_mb >= 1800 )) || warn "内存只有 ${mem_mb} MB，建议至少 2 GB。"

    local resolved
    # getent 解析失败时返回 2，pipefail 会让赋值失败；这里要的是「空」而不是中断。
    resolved=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n 1) || true
    if [[ -z $resolved ]]; then
        warn "域名 $DOMAIN 当前解析不到，确认 DNS 已生效。"
    elif [[ $resolved == 127.0.0.1 || $resolved == ::1 ]]; then
        log "域名解析：$resolved（本地回源）"
    else
        log "域名解析：$resolved"
        warn "域名未指向 127.0.0.1；Clash 分支依赖 /etc/hosts 回源，见 deploy.md §3.5。"
    fi

    if have ss && ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE '[:.]8443$'; then
        if ss -lntp 2>/dev/null | grep -E '[:.]8443[[:space:]]' | grep -q 'nginx'; then
            warn "端口 8443 已有 nginx 监听，将复用现有 Nginx。"
        else
            fail "端口 8443 已被其他进程占用。"
        fi
    fi
    # nginx 没装时依赖警告已经覆盖，这里只在已安装但未运行时提示。
    if have nginx && ! systemctl is-active --quiet nginx.service; then
        warn "nginx.service 未运行，部署时会启动。"
    fi
}

init_targets() {
    local acme_conf
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
        "$ACME_NGINX_CONF"
    )
    if [[ $WITH_RULES -eq 1 ]]; then
        INSTALL_TARGETS+=("$PUBLISH_DIR")
    fi
    # 续期方式可能被本脚本改写，回滚时一并恢复。
    if acme_conf=$(acme_conf_file "$DOMAIN"); then
        INSTALL_TARGETS+=("$acme_conf")
    fi
}

print_plan() {
    local repo_display=$RULES_REPO cert_state
    if [[ $CERT_NEEDS_ISSUE -eq 1 ]]; then
        cert_state="acme.sh 签发（webroot $ACME_WEBROOT）"
        [[ -x "$ACME_HOME/acme.sh" ]] || cert_state+="，需先安装 acme.sh"
    else
        cert_state="复用已有证书"
    fi
    cat <<EOF
部署计划

  域名:           $DOMAIN
  证书目录:       $CERT_DIR
  证书:           $cert_state
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
    $ACME_NGINX_CONF
    $ACME_WEBROOT/

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

ensure_acme() {
    [[ -x "$ACME_HOME/acme.sh" ]] && return 0
    log "安装 acme.sh"
    # 固定 HOME，保证安装到 ACME_HOME；安装器会根据 HOME 决定落点。
    if [[ -n $ACME_EMAIL ]]; then
        ( export HOME=/root; curl -fsSL https://get.acme.sh | sh -s "email=$ACME_EMAIL" ) \
            || fail "acme.sh 安装失败。"
    else
        ( export HOME=/root; curl -fsSL https://get.acme.sh | sh ) \
            || fail "acme.sh 安装失败。"
    fi
    [[ -x "$ACME_HOME/acme.sh" ]] || fail "acme.sh 安装后未找到 $ACME_HOME/acme.sh。"
}

# acme.sh 把带空格或分号的 hook 存成 base64，读写时都要处理。
decode_acme_value() {
    local value=$1
    if [[ $value == *__ACME_BASE64__START_* ]]; then
        value=${value#*__ACME_BASE64__START_}
        value=${value%%__ACME_BASE64__END_*}
        printf '%s' "$value" | openssl base64 -d -A
    else
        printf '%s' "$value"
    fi
}

set_acme_reloadcmd() {
    local conf=$1 cmd=$2 encoded
    encoded="__ACME_BASE64__START_$(printf '%s' "$cmd" | openssl base64 -A)__ACME_BASE64__END_"
    if grep -q '^Le_ReloadCmd=' "$conf"; then
        sed -i "s|^Le_ReloadCmd=.*$|Le_ReloadCmd='$encoded'|" "$conf"
    else
        printf "Le_ReloadCmd='%s'\n" "$encoded" >>"$conf"
    fi
}

# 续期 hook 必须包含 reload nginx，同时保留原有的 hook（3x-ui 自签的配置里
# 是 systemctl restart x-ui）。
acme_reload_cmd() {
    local conf cmd=""
    if conf=$(acme_conf_file "$DOMAIN"); then
        cmd=$(sed -n "s/^Le_ReloadCmd='\(.*\)'$/\1/p" "$conf" | head -n 1)
        cmd=$(decode_acme_value "$cmd")
    fi
    [[ $cmd == *"reload nginx"* ]] || cmd="${cmd:+$cmd; }systemctl reload nginx"
    printf '%s\n' "$cmd"
}

# acme.sh 的 standalone 续期要独占 80 端口；nginx 接管 80 之后续期会失败。
# 已有配置是 standalone 时改成 webroot，并确保续期后 reload nginx——否则签发
# 成功但 Nginx 一直拿着旧证书，等旧证书到期就开始报错。
#
# 只改配置文件，不调用 --install-cert：install-cert 会立即执行 reload hook，
# 每次部署都重启一次 x-ui 等于碰 443。
# 只处理 acme.sh 安装到 CERT_DIR 的证书；--cert-dir 指向别处时不碰它的配置。
normalize_acme_renewal() {
    local conf installed reloadcmd
    conf=$(acme_conf_file "$DOMAIN") || return 0
    installed=$(acme_installed_paths "$conf" 2>/dev/null || true)

    if [[ -z $installed || $installed != "$CERT_DIR" ]]; then
        if grep -qx "Le_Webroot='no'" "$conf"; then
            warn "acme.sh 仍是 standalone 续期；nginx 占用 80 端口后续期会失败，见 deploy.md §2.4。"
        fi
        return 0
    fi

    if grep -qx "Le_Webroot='no'" "$conf"; then
        [[ -f "$conf.orig" ]] || cp -a "$conf" "$conf.orig"
        sed -i "s|^Le_Webroot='no'$|Le_Webroot='$ACME_WEBROOT'|" "$conf"
        log "acme.sh 续期方式：standalone → webroot（$ACME_WEBROOT）"
    fi

    reloadcmd=$(acme_reload_cmd)
    set_acme_reloadcmd "$conf" "$reloadcmd"
}

issue_cert() {
    [[ $CERT_NEEDS_ISSUE -eq 1 ]] || return 0

    ensure_acme
    install -d -m 0755 "$ACME_WEBROOT" "$CERT_DIR"

    # deploy.sh 的 umask 是 077。acme.sh 写挑战文件时会继承它，nginx worker
    # 就读不到；签发阶段单独放回 022。
    if ! ( umask 022; "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" \
            --webroot "$ACME_WEBROOT" --keylength ec-256 ); then
        fail "acme.sh 签发失败。确认 $DOMAIN 已解析到本机、公网 80 端口可达。"
    fi
    "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "$(acme_reload_cmd)" \
        || fail "acme.sh install-cert 失败。"
    chmod 0600 "$CERT_DIR/privkey.pem"
    cert_files_ok "$CERT_DIR" || fail "签发后仍找不到证书文件：$CERT_DIR"
    log "证书：已签发到 $CERT_DIR"
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
    install -m 0644 "$stage/nginx/conf.d/sub-rules-cache.conf" \
        "$stage/nginx/conf.d/acme-challenge.conf" "$NGINX_CONF_D_DIR/"
    install -d -m 0755 "$ACME_WEBROOT"

    systemctl daemon-reload
    systemctl enable subconverter
    systemctl restart subconverter
    curl -fsS --max-time 10 --retry 3 --retry-delay 1 \
        http://127.0.0.1:25500/version >/dev/null \
        || fail "subconverter 未在 127.0.0.1:25500 响应。"

    nginx -t
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx
    else
        systemctl enable --now nginx
    fi

    # Nginx 已经接管 80 端口，先把续期方式修好，再签发。
    normalize_acme_renewal
    issue_cert

    # 重装时按新常量重建已有的 Nginx 配置；首次安装还没有这个文件。
    if [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]]; then
        "$SBIN_DIR/sub-manager" resync
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

    if [[ $INSTALL_DEPS_ONLY -eq 1 && $DRY_RUN -eq 1 ]]; then
        fail "--install-deps 会安装软件包，不能与 --dry-run 同用。"
    fi

    if [[ -n $ROLLBACK_DIR ]]; then
        require_root
        do_rollback
        return 0
    fi

    require_root

    if [[ $INSTALL_DEPS_ONLY -eq 1 ]]; then
        if collect_missing_dependencies; then
            ensure_dependencies
        else
            log "依赖已就绪。"
        fi
        return 0
    fi

    # 交互式下先问订阅相关的值，再处理依赖，避免安装提示打断提问流程；无人值守时
    # 依赖必须先装好，否则域名可能无法从 x-ui.db 推导。
    local defer_deps=0
    if [[ -t 0 ]]; then
        defer_deps=1
    else
        ensure_dependencies
    fi

    detect_existing_values
    detect_domain
    prompt_values

    if [[ $defer_deps -eq 1 ]]; then
        ensure_dependencies
    fi
    fill_defaults

    resolve_cert_dir
    prompt_acme_email
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
