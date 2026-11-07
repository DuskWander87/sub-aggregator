#!/usr/bin/env bash
# sub-aggregator 部署脚本。
#
# 唯一实现，部署只走这份脚本。不带参数即可：自动推导配置、安装缺失依赖、
# 打印摘要确认一次后执行。--dry-run 只打印计划，不做任何修改；--yes 跳过确认。
# 所有替换都在临时目录里完成，不会改动仓库工作副本。
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
# 订阅状态。与 README §3.2、sub-manager 的 STATE_FILE 是同一个路径；deploy 只读它。
readonly STATE_FILE="/etc/sub-manager/clients.json"
readonly DEFAULT_RULES_WORKDIR="/root/code/shadowrocket-config"
readonly DEFAULT_RULES_REPO="DuskWander87/shadowrocket-config"
readonly DEFAULT_PROFILE_NAME="DuskWander87"
# 订阅入口（Nginx）端口。443 被 Xray Reality 占用，所以默认 8443；被占用时用 --port 换。
readonly DEFAULT_SUB_PORT="8443"
# 本系统其他组件的固定端口，订阅入口不能用：80 ACME、443 Reality、2096 3x-ui 原生订阅、
# 25500 subconverter。与 docs/sub/README.md §3.1 是同一份清单。
readonly RESERVED_PORTS="80 443 2096 25500"
readonly BACKUP_ROOT="/root"
readonly SUBCONVERTER_VERSION="v0.9.9"
readonly SUBCONVERTER_URL="https://github.com/asdlokj1qpi233/subconverter/releases/download/${SUBCONVERTER_VERSION}/subconverter_linux64.tar.gz"

# 证书默认落点与 ACME 挑战路径。80 端口的 server 块见 server/nginx/conf.d/acme-challenge.conf。
readonly DEFAULT_CERT_ROOT="/root/cert"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_WEBROOT="/var/www/acme"
readonly ACME_NGINX_CONF="$NGINX_CONF_D_DIR/acme-challenge.conf"
# 签发源固定为 Let's Encrypt，不依赖本机 acme.sh 的默认 CA。上游默认是 ZeroSSL，
# 注册账户需要邮箱；固定 CA 后签发不再需要邮箱。
readonly ACME_CA_SERVER="letsencrypt"
# acme.sh 把 --server letsencrypt 解析成这个目录地址，存进 conf 的 Le_API。
readonly ACME_LE_DIRECTORY="https://acme-v02.api.letsencrypt.org/directory"
# certbot：复用 /etc/letsencrypt/live/<域名>/ 的证书时，在这里装 deploy hook。
readonly CERTBOT_DIR="/etc/letsencrypt"
readonly CERTBOT_HOOK="$CERTBOT_DIR/renewal-hooks/deploy/sub-aggregator.sh"
# acme.sh 的 sudo 检查读这份清单，判断 SUDO_COMMAND 是否是登录 shell。
readonly SHELLS_FILE="/etc/shells"

DOMAIN=""
DOMAIN_CANDIDATE=""
DOMAIN_SOURCE=""
CERT_DIR=""
PROFILE_NAME=""
SUB_PORT=""
PORT_CHANGED_FROM=""
RULES_PREFIX=""
RULES_REPO=""
RULES_WORKDIR="$DEFAULT_RULES_WORKDIR"
ACME_EMAIL=""
WITH_RULES=0
DRY_RUN=0
ASSUME_YES=0
ISSUE_CERT=1
CERT_NEEDS_ISSUE=0
ROLLBACK_DIR=""
WORK_DIR=""
BACKUP_DIR=""
INSTALL_TARGETS=()
# 本次由 install_dependencies 装上了 nginx（它会立即监听 80）；续期方式对齐之前
# 退出时提示。
INSTALLED_NGINX=0
ACME_NORMALIZED=0
# xui_uses_cert_dir 的结论：match / none / unknown。
XUI_CERT_USAGE=""
# 本次换了证书文件、而 x-ui 也用这张证书：部署结束时提示手工重启 x-ui。
XUI_RESTART_NOTE=0
# 订阅条数（count_subscriptions）；已安装的域名与本次不同时记下旧域名。
SUB_COUNT=0
DOMAIN_CHANGED_FROM=""

usage() {
    cat <<'EOF'
用法：
  deploy.sh [选项]

不带参数即可部署：自动推导域名与证书、安装缺失的依赖，打印摘要后确认一次。
只询问无法自动推导的域名。

选项：
  --domain <域名>           订阅域名；省略时从 3x-ui 配置或证书自动推导
  --cert-dir <目录>         证书目录；默认自动查找，缺失时签发到 /root/cert/<域名>
  --acme-email <邮箱>       可选：安装 acme.sh 时写入 ACME 账户联系邮箱
  --no-issue-cert           缺少证书时不自动签发，直接报错
  --port <端口>             订阅入口端口（默认 8443，重装时沿用已安装的值）；被占用时换一个
  --profile-name <名称>     订阅显示名，纯 ASCII（默认 DuskWander87）
  --rules-prefix <hex>      规则端点前缀，默认随机生成 24 位 hex
  --rules-repo <owner/repo> 规则仓库，默认 DuskWander87/shadowrocket-config
  --rules-workdir <目录>    规则仓库本机工作副本，默认 /root/code/shadowrocket-config
  --with-rules              启用本机规则发布；规则仓库默认是作者的
  --dry-run                 只打印计划，不做修改
  --yes, -y                 跳过确认；依赖缺失时直接安装
  --rollback <备份目录>     从备份目录恢复
  -h, --help                显示这份帮助
EOF
}

# exit 不触发 ERR trap，所以备份之后的 fail 要自己打印回滚命令。
fail() {
    printf '%s✗ 错误：%s%s\n' "$COLOR_ERROR" "$*" "$COLOR_RESET" >&2
    if [[ -n $BACKUP_DIR && -x "$BACKUP_DIR/restore.sh" ]]; then
        printf '备份目录：%s\n' "$BACKUP_DIR" >&2
        printf '回滚命令：%s --rollback %s\n' "$REPO_ROOT/tools/deploy.sh" "$BACKUP_DIR" >&2
    fi
    exit 1
}
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
            --port) opt_value "$@"; SUB_PORT=$2; shift 2 ;;
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
    # 重装时复用已安装的值，避免静默换掉规则前缀或域名。--domain 换了域名时不沿用
    # 旧证书目录：那张证书不覆盖新域名。
    local installed_host="" installed_cert=""
    if [[ -r "$SBIN_DIR/sub-manager" ]]; then
        installed_host=$(sed -n 's/^readonly HOST="\(.*\)"$/\1/p' "$SBIN_DIR/sub-manager" | head -n 1)
        installed_cert=$(sed -n 's|^readonly CERT_FILE="\(.*\)/fullchain.pem"$|\1|p' \
            "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    [[ -n $DOMAIN ]] || DOMAIN=$installed_host
    if [[ -n $installed_host && $DOMAIN != "$installed_host" ]]; then
        DOMAIN_CHANGED_FROM=$installed_host
    elif [[ -z $CERT_DIR ]]; then
        CERT_DIR=$installed_cert
    fi
    # 重装时沿用已安装的端口：静默换回默认值会让所有设备的订阅地址失效。
    local installed_port=""
    if [[ -r "$SBIN_DIR/sub-manager" ]]; then
        installed_port=$(sed -n 's/^readonly PORT="\([0-9]\{1,5\}\)"$/\1/p' \
            "$SBIN_DIR/sub-manager" | head -n 1)
    fi
    [[ -n $SUB_PORT ]] || SUB_PORT=$installed_port
    if [[ -n $installed_port && $SUB_PORT != "$installed_port" ]]; then
        PORT_CHANGED_FROM=$installed_port
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

# 证书是否覆盖域名。-checkhost 匹配与否退出码都是 0，只能看输出。
cert_matches_domain() {
    openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null | grep -qF ' does match certificate'
}

# 订阅条数放进 SUB_COUNT。区分「没有订阅」和「读取失败」：状态文件存在却读不出
# 订阅表时直接报错，不能当成 0 条。
count_subscriptions() {
    if [[ ! -e $STATE_FILE ]]; then
        # 配置还在而状态没了：resync 会按空状态重建，所有订阅地址失效。
        if [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]]; then
            fail "订阅状态 $STATE_FILE 缺失，但 $NGINX_CONF_D_DIR/private-sub.conf 仍在：重建会让所有订阅地址失效。先从备份恢复状态文件再重跑。"
        fi
        SUB_COUNT=0
        return 0
    fi
    SUB_COUNT=$(jq -e '.clients | if type == "object" then length else error("clients") end' \
        "$STATE_FILE" 2>/dev/null) \
        || fail "读不到 $STATE_FILE（不是有效的订阅状态），先用 sub-manager list 检查。"
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

# acme.sh 存储的 ECC 证书是否由 Let's Encrypt 正式环境签发。acme.sh 在证书未到期时
# 直接返回 RENEW_SKIP（2），不比较 --server；后续 renew 只认 conf 里的 Le_API。
# 换 CA 必须自己判断并用 --force 重签。
#
# 判断看证书本身的签发者，不看 conf 的 Le_API：acme.sh v3.1.3 的 issue() 在下单
# （4582 行）之前就把 Le_API 写进 conf（4564-4565 行），签发失败也不回退，Le_API
# 可能已经是 LE 而证书仍是旧 CA 的。staging 的 O=(STAGING) Let's Encrypt 不算。
acme_cert_is_letsencrypt() {
    local cert="$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.cer"
    [[ -r $cert ]] || return 1
    openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null \
        | sed 's/^issuer=//' | tr ',' '\n' | grep -qxF "O=Let's Encrypt"
}

# 是否「普通用户用 sudo 直接运行」。照抄 acme.sh v3.1.3 的 _checkSudo：root 经 sudo、
# sudo su、sudo -i / -s（SUDO_COMMAND 是登录 shell）都放行。
sudo_env_blocked() {
    [[ -n ${SUDO_GID:-} && -n ${SUDO_COMMAND:-} && -n ${SUDO_USER:-} && -n ${SUDO_UID:-} ]] \
        || return 1
    if [[ $SUDO_USER == root && $SUDO_UID == 0 ]]; then
        return 1
    fi
    if [[ $SUDO_COMMAND == */bin/su || $SUDO_COMMAND == *"/bin/su "* ]]; then
        return 1
    fi
    if grep -qxF -- "$SUDO_COMMAND" "$SHELLS_FILE" 2>/dev/null; then
        return 1
    fi
    return 0
}

# acme.sh 只在 stdout 是终端时做 sudo 检查（__INTERACTIVE），条件与它保持一致。
acme_sudo_blocked() {
    [[ -t 1 ]] && sudo_env_blocked
}

# 证书目录从域名推导，不再向用户提问。查找顺序：默认目录 → certbot → acme.sh 安装记录，
# 都没有时签发到默认目录。--cert-dir 仍然可以覆盖。
resolve_cert_dir() {
    local candidate conf

    if [[ -z $CERT_DIR ]]; then
        for candidate in "$DEFAULT_CERT_ROOT/$DOMAIN" "$CERTBOT_DIR/live/$DOMAIN"; do
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

prompt_values() {
    # 只问推导不到的域名。显示名、规则前缀和规则仓库都有默认值。
    prompt_value DOMAIN "订阅域名" ""
}

fill_defaults() {
    # openssl 可能刚由 install_dependencies 装上，所以放在依赖处理之后。
    [[ -n $PROFILE_NAME ]] || PROFILE_NAME=$DEFAULT_PROFILE_NAME
    [[ -n $SUB_PORT ]] || SUB_PORT=$DEFAULT_SUB_PORT
    if [[ -z $RULES_PREFIX ]]; then
        if have openssl; then
            RULES_PREFIX=$(openssl rand -hex 12)
        elif [[ $DRY_RUN -eq 1 ]]; then
            # dry-run 不装依赖，用一个合法的占位值把计划打印完。
            RULES_PREFIX="0123456789abcdef01234567"
            warn "缺少 openssl：dry-run 用占位规则前缀；正式部署会随机生成。"
        else
            fail "缺少 openssl，无法生成规则前缀。"
        fi
    fi
    [[ -n $RULES_REPO ]] || RULES_REPO=$DEFAULT_RULES_REPO
}

validate_sub_port() {
    [[ $SUB_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( SUB_PORT <= 65535 )) \
        || fail "端口必须是 1 到 65535 的整数：$SUB_PORT"
    [[ " $RESERVED_PORTS " != *" $SUB_PORT "* ]] \
        || fail "端口 $SUB_PORT 是本系统其他组件的固定端口（$RESERVED_PORTS），用 --port 换一个，例如 --port 9443。"
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
    validate_sub_port
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

# 读 settings 表的单个键。键不存在时 sqlite3 返回空串且退出码为 0，与查询失败
# 区分开：失败返回非零，由调用方决定回落到默认值还是放弃打印。
xui_setting() {
    local value
    value=$(xui_query "select value from settings where key = '$1';" 2>/dev/null) || return 1
    printf '%s\n' "$value"
}

# 3x-ui 面板地址。端口和路径只有被面板改过才落进 settings 表，查不到即面板默认值。
# 主机名优先取面板证书的 SAN；证书不是单域名时回落到订阅域名。
xui_panel_url() {
    local port path cert key host="" scheme=http
    port=$(xui_setting webPort) || return 1
    path=$(xui_setting webBasePath) || return 1
    cert=$(xui_setting webCertFile) || return 1
    key=$(xui_setting webKeyFile) || return 1
    [[ -n $port ]] || port=2053
    [[ -n $path ]] || path=/
    [[ $path == /* ]] || path="/$path"
    [[ $path == */ ]] || path="$path/"
    if [[ -n $cert && -n $key ]]; then
        scheme=https
        host=$(cert_domain "$cert" 2>/dev/null) || host=""
    fi
    [[ -n $host ]] || host=$DOMAIN
    printf '%s://%s:%s%s\n' "$scheme" "$host" "$port" "$path"
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

print_missing_dependencies() {
    log "部署前需要安装依赖："
    log "  命令：${MISSING_COMMANDS[*]}"
    log "  apt 包：${MISSING_PACKAGES[*]}"
}

# 安装 collect_missing_dependencies 收集到的包。确认由调用方负责。
install_dependencies() {
    ((${#MISSING_PACKAGES[@]} > 0)) || return 0

    local cmd still=()
    log "运行 apt-get update"
    apt-get update
    log "安装：${MISSING_PACKAGES[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"
    local pkg
    for pkg in "${MISSING_PACKAGES[@]}"; do
        if [[ $pkg == nginx ]]; then INSTALLED_NGINX=1; fi
    done

    for cmd in "${MISSING_COMMANDS[@]}"; do
        have "$cmd" || still+=("$cmd")
    done
    ((${#still[@]} == 0)) || fail "安装后仍缺少命令：${still[*]}"
    log "依赖已就绪。"
    MISSING_COMMANDS=()
    MISSING_PACKAGES=()
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

    # 现有配置引用的证书缺失时，部署中途的 nginx -t 会失败。换域名时它引用的是旧
    # 域名的证书，按它实际引用的文件判断，而不是本次的 CERT_DIR。
    local psc="$NGINX_CONF_D_DIR/private-sub.conf" ref_cert ref_key
    if [[ -f $psc ]]; then
        ref_cert=$(sed -n 's/^[[:space:]]*ssl_certificate[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$psc" | head -n 1)
        ref_key=$(sed -n 's/^[[:space:]]*ssl_certificate_key[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$psc" | head -n 1)
        if [[ -z $ref_cert || -z $ref_key || ! -s $ref_cert || ! -s $ref_key ]]; then
            fail "现有 $psc 引用的证书缺失：$(dirname -- "${ref_cert:-$CERT_DIR/fullchain.pem}")。按 docs/sub/certificates.md §4 把证书重新落盘后重跑。"
        fi
    fi

    if [[ $CERT_NEEDS_ISSUE -eq 1 ]]; then
        if acme_sudo_blocked; then
            fail "当前通过 sudo 直接运行（SUDO_USER=$SUDO_USER），acme.sh 在这种方式下拒绝签发。先执行 sudo -i 进入 root shell，再运行 $REPO_ROOT/tools/deploy.sh。"
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
        if have openssl; then
            cert_matches_domain "$CERT_DIR/fullchain.pem" "$DOMAIN" \
                || fail "证书 $CERT_DIR/fullchain.pem 不包含域名 $DOMAIN。用 --cert-dir 指定正确的目录，或移走该目录让脚本签发。"
        else
            warn "缺少 openssl，跳过证书域名检查；正式部署会先安装 openssl。"
        fi
    fi

    if [[ -n $DOMAIN_CHANGED_FROM ]]; then
        warn "域名将从 $DOMAIN_CHANGED_FROM 改为 $DOMAIN：所有设备的订阅地址都要换成新域名；acme-challenge.conf 只为新域名提供挑战路径，$DOMAIN_CHANGED_FROM 的证书若仍由 acme.sh webroot 续期（例如面板还在用），续期会失败；已有订阅的原始订阅地址仍指向 $DOMAIN_CHANGED_FROM，见 docs/sub/deploy.md §7「改域名」。"
    fi
    # 状态文件损坏要在改动之前发现，而不是装到一半在 resync 时才失败。
    if have jq; then
        count_subscriptions
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

    check_sub_port
    # nginx 没装时依赖警告已经覆盖，这里只在已安装但未运行时提示。
    if have nginx && ! systemctl is-active --quiet nginx.service; then
        warn "nginx.service 未运行，部署时会启动。"
    fi
}

# 订阅入口端口：其他进程占用时在改动之前失败，并提示 --port。
check_sub_port() {
    if [[ -n $PORT_CHANGED_FROM ]]; then
        warn "订阅端口将从 $PORT_CHANGED_FROM 改为 $SUB_PORT：所有设备的订阅地址都要换成新端口，防火墙 / 云安全组也要放行 TCP $SUB_PORT。"
    fi
    if have ss && ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$SUB_PORT\$"; then
        if ss -lntp 2>/dev/null | grep -E "[:.]$SUB_PORT[[:space:]]" | grep -q 'nginx'; then
            if grep -qE "^[[:space:]]*listen[[:space:]]+$SUB_PORT[[:space:]]+ssl;" \
                "$NGINX_CONF_D_DIR/private-sub.conf" 2>/dev/null; then
                log "端口 $SUB_PORT：本服务的订阅入口已在监听，沿用。"
            else
                warn "端口 $SUB_PORT 已有 nginx 监听（可能是其他站点），将与之共用。若那是非 TLS 站点，订阅入口会让它也变成 TLS：改用 --port 换一个空闲端口。"
            fi
        else
            fail "端口 $SUB_PORT 已被其他进程占用（ss -lntp | grep ':$SUB_PORT ' 查看）。用 --port 换一个空闲端口，例如 --port 9443。"
        fi
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
    if cert_dir_is_certbot; then
        INSTALL_TARGETS+=("$CERTBOT_HOOK")
    fi
}

# 摘要里的端口变更行，与域名变更行同一写法。
port_change_line() {
    [[ -n $PORT_CHANGED_FROM ]] || return 0
    printf '\n  端口变更:       %s → %s（所有设备需要重新配置订阅地址）' "$PORT_CHANGED_FROM" "$SUB_PORT"
}

print_plan() {
    local repo_display=$RULES_REPO cert_state dep_state="已就绪"
    if [[ $CERT_NEEDS_ISSUE -eq 1 ]]; then
        cert_state="acme.sh 签发（webroot $ACME_WEBROOT）"
        [[ -x "$ACME_HOME/acme.sh" ]] || cert_state+="，需先安装 acme.sh"
    else
        cert_state="复用已有证书"
    fi
    if ((${#MISSING_COMMANDS[@]} > 0)); then
        dep_state="缺少 ${MISSING_COMMANDS[*]}（正式部署时安装：${MISSING_PACKAGES[*]}）"
    fi
    cat <<EOF
部署计划

  域名:           $DOMAIN$(if [[ -n $DOMAIN_CHANGED_FROM ]]; then printf '\n  域名变更:       %s → %s（所有设备需要重新配置订阅地址）' "$DOMAIN_CHANGED_FROM" "$DOMAIN"; fi)
  证书目录:       $CERT_DIR
  证书:           $cert_state
  订阅端口:       $SUB_PORT$(port_change_line)
  依赖:           $dep_state
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
    $ACME_WEBROOT/$(if cert_dir_is_certbot; then printf '\n    %s' "$CERTBOT_HOOK"; fi)

  将重启/重载:
    subconverter
    nginx

  备份目录:
    $BACKUP_DIR

  规则发布:
    $(if [[ $WITH_RULES -eq 1 ]]; then echo "启用 sub-rules-sync.timer（工作副本不存在时自动克隆 $RULES_REPO）"; else echo "本次不启用（Clash 分支仍含规则表，自维护列表由服务器侧回源 GitHub 兜底，客户端只连 $SUB_PORT）"; fi)
EOF
}

# 正式部署前的确认摘要。静态的安装清单只在 dry-run 里展开；这里只列本次运行
# 会变化、确认时值得看一眼的值。
print_summary() {
    local cert_state rules_state
    if [[ $CERT_NEEDS_ISSUE -eq 1 ]]; then
        cert_state="acme.sh 签发到 $CERT_DIR"
    else
        cert_state="复用 $CERT_DIR"
    fi
    if [[ $WITH_RULES -eq 1 ]]; then
        rules_state="启用 sub-rules-sync.timer（本机发布）"
    else
        rules_state="本次不启用（Clash 分支仍含规则表，服务器侧回源 GitHub 兜底，客户端只连 $SUB_PORT）"
    fi
    cat <<EOF
部署配置

  域名:           $DOMAIN$(if [[ -n $DOMAIN_CHANGED_FROM ]]; then printf '\n  域名变更:       %s → %s（所有设备需要重新配置订阅地址）' "$DOMAIN_CHANGED_FROM" "$DOMAIN"; fi)
  证书:           $cert_state
  订阅端口:       $SUB_PORT$(port_change_line)
  订阅显示名:     $PROFILE_NAME
  规则端点前缀:   $RULES_PREFIX
  规则仓库:       $RULES_REPO
  规则工作副本:   $RULES_WORKDIR
  规则发布:       $rules_state
  备份目录:       $BACKUP_DIR
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

    # 端口跟在域名占位符后面，先于域名替换；只改带域名的 URL 和 PORT 常量，不做全局
    # 替换（随机规则前缀里也可能出现这四个数字）。
    replace_literal "$stage/sbin/sub-manager" "readonly PORT=\"$DEFAULT_SUB_PORT\"" \
        "readonly PORT=\"$SUB_PORT\""
    replace_literal "$stage/sbin/sub-rules-check" "sub\\.example\\.com:$DEFAULT_SUB_PORT" \
        "sub\\.example\\.com:$SUB_PORT"
    replace_in_files "sub.example.com:$DEFAULT_SUB_PORT" "sub.example.com:$SUB_PORT"

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

# 生成的 restore.sh 按记录恢复部署之前的状态：
# - 先停用本次新建的 systemd 单元，删掉单元文件不会让 systemd 停掉正在运行的服务；
# - private-sub.conf 是派生文件，不从快照恢复（快照会让已撤销、已轮换的订阅路径重新
#   生效），而是用恢复后的 sub-manager 按当前 clients.json 重建；
# - 有检查未通过时以非 0 退出。
write_restore_script() {
    {
        printf '#!/usr/bin/env bash\n'
        printf '# 由 deploy.sh 生成：把本次部署覆盖或新建的文件恢复到部署之前。\n'
        printf '%s=%q\n' \
            SYSTEMD_DIR "$SYSTEMD_DIR" \
            PRIVATE_SUB_CONF "$NGINX_CONF_D_DIR/private-sub.conf" \
            SUB_MANAGER "$SBIN_DIR/sub-manager" \
            ACME_HOME "$ACME_HOME"
        cat <<'EOF'
set -Euo pipefail
rc=0
backup_dir=$(cd -- "$(dirname -- "$0")" && pwd)

if [[ -s $backup_dir/remove.list ]]; then
    while IFS= read -r p; do
        case $p in
            "$SYSTEMD_DIR"/*.service|"$SYSTEMD_DIR"/*.timer)
                systemctl disable --now "${p##*/}" 2>/dev/null || true ;;
        esac
    done <"$backup_dir/remove.list"
fi

if [[ -s $backup_dir/restore.list ]]; then
    while IFS= read -r p; do
        [[ $p == "$PRIVATE_SUB_CONF" ]] && continue
        [[ -e "$backup_dir$p" ]] || continue
        if ! { mkdir -p "$(dirname -- "$p")" && rm -rf -- "$p" && cp -a "$backup_dir$p" "$p"; }; then
            printf '恢复 %s 失败。\n' "$p" >&2
            rc=1
        fi
    done <"$backup_dir/restore.list"
fi
if [[ -s $backup_dir/remove.list ]]; then
    while IFS= read -r p; do
        if ! rm -rf -- "$p"; then
            printf '删除 %s 失败。\n' "$p" >&2
            rc=1
        fi
    done <"$backup_dir/remove.list"
fi
systemctl daemon-reload || true

if [[ -x $SUB_MANAGER && -f $PRIVATE_SUB_CONF ]]; then
    if ! "$SUB_MANAGER" resync; then
        printf 'sub-manager resync 失败，private-sub.conf 仍是回滚前的版本。\n' >&2
        rc=1
    fi
fi

if nginx -t; then
    if ! systemctl reload nginx; then
        printf 'systemctl reload nginx 失败。\n' >&2
        rc=1
    fi
else
    printf 'nginx -t 未通过，未重载 Nginx。\n' >&2
    rc=1
fi

if [[ -f $SYSTEMD_DIR/subconverter.service ]]; then
    if ! systemctl restart subconverter; then
        printf 'systemctl restart subconverter 失败。\n' >&2
        rc=1
    fi
fi

# 恢复出的 acme.sh 配置是 standalone、而 80 端口仍被占用时，续期必然失败。
if [[ -s $backup_dir/restore.list ]]; then
    while IFS= read -r p; do
        [[ $p == "$ACME_HOME"/*.conf && -f $p ]] || continue
        if grep -qx "Le_Webroot='no'" "$p" \
            && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
            printf 'acme.sh 恢复为 standalone 续期，但 80 端口仍在监听：续期会失败。重跑 tools/deploy.sh（会改回 webroot），或停掉占用 80 端口的服务。\n' >&2
        elif grep -qx "Le_Webroot='alpn'" "$p"; then
            printf 'acme.sh 恢复为 alpn 续期，但 443 由 Xray 占用：续期会失败。重跑 tools/deploy.sh（会改回 webroot）。\n' >&2
        fi
    done <"$backup_dir/restore.list"
fi

printf '已从 %s 恢复。\n' "$backup_dir"
exit "$rc"
EOF
    } >"$BACKUP_DIR/restore.sh"
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

# 面板/原生订阅是否把证书指向本脚本安装的目录。是的话续期后必须重启 x-ui，
# 否则它继续用内存里的旧证书。读不到设置时按「在用」处理：多一次重启，
# 好过面板继续发旧证书。结论同时记在 XUI_CERT_USAGE（match / none / unknown），
# 调用方要在当前 shell 里调用它，放进 $(...) 时这个变量带不回来。
xui_uses_cert_dir() {
    local key path
    XUI_CERT_USAGE=none
    for key in webCertFile subCertFile; do
        if path=$(xui_setting "$key"); then
            [[ -n $path ]] || continue
            if [[ $(dirname -- "${path%/}") == "$CERT_DIR" ]]; then
                XUI_CERT_USAGE=match
                return 0
            fi
        else
            XUI_CERT_USAGE=unknown
            return 0
        fi
    done
    return 1
}

# 续期 hook 必须包含 reload nginx；面板/原生订阅也用这张证书时还要重启 x-ui。
# 两者都保留原有的 hook（3x-ui 自签的配置里通常已有 systemctl restart x-ui）。
acme_reload_cmd() {
    local conf cmd=""
    if conf=$(acme_conf_file "$DOMAIN"); then
        cmd=$(sed -n "s/^Le_ReloadCmd='\(.*\)'$/\1/p" "$conf" | head -n 1)
        cmd=$(decode_acme_value "$cmd")
    fi
    if xui_uses_cert_dir; then
        [[ $cmd == *"restart x-ui"* ]] \
            || cmd="systemctl restart x-ui || rc-service x-ui restart${cmd:+; $cmd}"
    fi
    [[ $cmd == *"reload nginx"* ]] || cmd="${cmd:+$cmd; }systemctl reload nginx"
    printf '%s\n' "$cmd"
}

# 在证书安装之后调用：按 acme.sh 的安装记录把续期方式对齐为 webroot，并写回完整
# hook。acme.sh 的 standalone / alpn 续期要独占端口，Nginx 接管 80 之后续期会失败；
# 续期后不 reload，Nginx 会一直拿着旧证书，等旧证书到期就开始报错。
#
# 只改配置文件，不调用 --install-cert：install-cert 会立即执行 reload hook，
# 每次部署都重启一次 x-ui 等于碰 443。
# 只处理 acme.sh 安装到 CERT_DIR 的证书；安装到别处时只警告，不碰它的配置。
normalize_acme_renewal() {
    local conf installed webroot alt api reloadcmd
    if [[ -r "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.conf" && -r "$ACME_HOME/${DOMAIN}/${DOMAIN}.conf" ]]; then
        warn "acme.sh 里同时有 $DOMAIN 的 RSA 与 ECC 两份证书配置，部署只管理 ECC（${DOMAIN}_ecc）。确认 RSA 那份不再使用后执行：$ACME_HOME/acme.sh --remove -d $DOMAIN"
    fi
    conf=$(acme_conf_file "$DOMAIN") || return 0
    installed=$(acme_installed_paths "$conf" 2>/dev/null || true)

    if [[ -z $installed || $installed != "$CERT_DIR" ]]; then
        warn "acme.sh 里 $DOMAIN 的证书安装到 ${installed:-（无安装记录）}，不是 $CERT_DIR：它续期后不会更新 Nginx 用的这份文件，脚本也不改它的续期方式。要交给 acme.sh 续期，按 docs/sub/certificates.md §4 把证书安装到 $CERT_DIR 后重跑。"
        return 0
    fi

    # 对齐规则与 docs/sub/certificates.md §2.2 的表一致。逗号分隔表示多域名各用
    # 不同方式，无法整体改写；DNS 验证不经过 80 端口，保持原样。
    webroot=$(sed -n "s/^Le_Webroot='\(.*\)'$/\1/p" "$conf" | head -n 1)
    alt=$(sed -n "s/^Le_Alt='\(.*\)'$/\1/p" "$conf" | head -n 1)
    # 多域名证书：acme-challenge.conf 只为订阅域名提供挑战路径，改成 webroot 会让
    # 其余域名的验证失败，整张证书续期失败。只警告。
    if [[ -n $alt && $alt != no && $webroot != "$ACME_WEBROOT" && $webroot != dns && $webroot != dns_* ]]; then
        warn "acme.sh 里 $DOMAIN 的证书还包含其他域名（$alt），续期方式是 $webroot。80 端口的挑战路径只服务 $DOMAIN，脚本不改它；确认续期不依赖 80 端口独占，或把这张证书拆开。"
        webroot=$ACME_WEBROOT
    fi
    case $webroot in
        "$ACME_WEBROOT") ;;
        dns|dns_*) ;;
        *,*)
            warn "acme.sh 里 $DOMAIN 的续期方式是多项组合（$webroot），脚本不改它。确认每一项都不依赖 80 端口独占，或手工改为 webroot $ACME_WEBROOT。" ;;
        no|alpn|apache|stateless|nginx|nginx:*|/*)
            [[ -f "$conf.orig" ]] || cp -a "$conf" "$conf.orig"
            sed -i "s|^Le_Webroot=.*$|Le_Webroot='$ACME_WEBROOT'|" "$conf"
            log "acme.sh 续期方式：$webroot → webroot（$ACME_WEBROOT）" ;;
        *)
            warn "acme.sh 里 $DOMAIN 的续期方式未识别（Le_Webroot='$webroot'），脚本不改它。确认续期不依赖 80 端口独占。" ;;
    esac

    # 证书已是 LE、conf 却仍指向别的 CA（例如回滚恢复了重签之前的 conf）：renew 只读
    # Le_API，不对齐就会向旧 CA 续期。
    api=$(sed -n "s/^Le_API='\(.*\)'$/\1/p" "$conf" | head -n 1)
    if [[ $api != "$ACME_LE_DIRECTORY" ]] && acme_cert_is_letsencrypt; then
        if grep -q '^Le_API=' "$conf"; then
            sed -i "s|^Le_API=.*$|Le_API='$ACME_LE_DIRECTORY'|" "$conf"
        else
            printf "Le_API='%s'\n" "$ACME_LE_DIRECTORY" >>"$conf"
        fi
        log "acme.sh 续期 CA：${api:-（未设置）} → Let's Encrypt（证书本身由 Let's Encrypt 签发）"
    fi

    reloadcmd=$(acme_reload_cmd)
    set_acme_reloadcmd "$conf" "$reloadcmd"
}

cert_dir_is_certbot() {
    [[ $CERT_DIR == "$CERTBOT_DIR/live/"* ]]
}

# 复用 certbot 的证书时，certbot 续期后要让 Nginx（以及使用同一证书的 x-ui）加载
# 新证书：装一个 deploy hook。续期方式只检查、不改：renewal/*.conf 的格式归
# certbot 所有，certbot reconfigure 还会联网试运行一次。
normalize_certbot_renewal() {
    cert_dir_is_certbot || return 0

    local name renewal hook="systemctl reload nginx" tmp fix lineage
    name=$(basename -- "$CERT_DIR")
    # certbot 对每张证书的续期都执行 renewal-hooks/deploy/ 下的全部脚本，只对本证书动作。
    lineage=${CERT_DIR//\'/\'\\\'\'}
    if xui_uses_cert_dir; then
        hook="systemctl restart x-ui || rc-service x-ui restart; $hook"
    fi
    install -d -m 0755 "$(dirname -- "$CERTBOT_HOOK")"
    tmp=$(mktemp "$CERTBOT_HOOK.XXXXXX")
    printf '#!/bin/sh\n# 由 sub-aggregator 的 deploy.sh 生成：certbot 续期成功后让 Nginx（以及使用同一证书的 x-ui）加载新证书\n[ "$RENEWED_LINEAGE" = '"'"'%s'"'"' ] || exit 0\n%s\n' \
        "$lineage" "$hook" >"$tmp"
    chmod 0755 "$tmp"
    mv -f -- "$tmp" "$CERTBOT_HOOK"
    log "certbot：续期后执行 $CERTBOT_HOOK（$hook）"

    renewal="$CERTBOT_DIR/renewal/$name.conf"
    fix="certbot reconfigure --cert-name $name --webroot -w $ACME_WEBROOT"
    if [[ ! -r $renewal ]]; then
        warn "找不到 certbot 的续期配置 $renewal，无法确认续期方式。若它用 standalone，Nginx 占用 80 端口后续期会失败：$fix"
    elif grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal"; then
        warn "certbot 用 standalone 续期 $name，Nginx 占用 80 端口后续期会失败。执行：$fix"
    elif grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*webroot[[:space:]]*$' "$renewal" \
        && ! grep -Eq "=[[:space:]]*${ACME_WEBROOT//./\\.},?[[:space:]]*$" "$renewal"; then
        warn "certbot 的 webroot 不是 $ACME_WEBROOT，而 80 端口只为这个目录提供挑战路径，续期会失败。执行：$fix"
    fi
}

issue_cert() {
    [[ $CERT_NEEDS_ISSUE -eq 1 ]] || return 0

    ensure_acme
    install -d -m 0755 "$ACME_WEBROOT" "$CERT_DIR"

    # deploy.sh 的 umask 是 077。acme.sh 写挑战文件时会继承它，nginx worker
    # 就读不到；签发阶段单独放回 022。
    local rc=0 conf="" hook
    ( umask 022; "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" \
        --server "$ACME_CA_SERVER" \
        --webroot "$ACME_WEBROOT" --keylength ec-256 ) || rc=$?

    # acme.sh 在证书仍在有效期内、未到续期时间时返回 2（RENEW_SKIP），不改 conf，
    # 也不比较 CA。已有证书不是 Let's Encrypt 正式环境签发时 --force 重签一次。
    # 重签失败时 acme.sh 已在下单前改写了 conf（Le_Webroot / Le_API），从本次的
    # 部署备份还原，否则续期会对着旧证书用新 CA。
    if (( rc == 2 )) && ! acme_cert_is_letsencrypt; then
        log "现有证书不是 Let's Encrypt 正式环境签发，强制重签。"
        conf=$(acme_conf_file "$DOMAIN") || conf=""
        rc=0
        ( umask 022; "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" \
            --server "$ACME_CA_SERVER" --force \
            --webroot "$ACME_WEBROOT" --keylength ec-256 ) || rc=$?
        if (( rc != 0 )); then
            if [[ -n $conf && -n $BACKUP_DIR && -f "$BACKUP_DIR$conf" ]]; then
                cp -a -- "$BACKUP_DIR$conf" "$conf"
                fail "强制重签失败（退出码 $rc），已把 acme.sh 的续期配置还原为部署前的版本，现有证书未改动。确认 $DOMAIN 解析到本机、公网 80 端口可达后重跑；不想换 CA 时，按 docs/sub/certificates.md §4 把现有证书装到 $CERT_DIR 后加 --no-issue-cert 重跑。"
            fi
            fail "强制重签失败（退出码 $rc），且没有可用的部署备份来还原 acme.sh 的续期配置：检查 ${conf:-acme.sh 的 $DOMAIN 配置} 的 Le_API / Le_Webroot。确认 $DOMAIN 解析到本机、公网 80 端口可达后重跑。"
        fi
    fi

    # 这个分支只在首次部署且 acme.sh 里已有一张有效证书时可达；已有部署的安装副本
    # 缺失会先被 preflight 拦下，按 certificates.md §4 手工恢复。签发成功或跳过都
    # 要继续走 --install-cert 落盘，不能当成失败。
    if (( rc != 0 && rc != 2 )); then
        fail "acme.sh 签发失败（退出码 $rc）。确认 $DOMAIN 已解析到本机、公网 80 端口可达。"
    fi
    if (( rc == 2 )); then
        log "证书仍在 acme.sh 的存储里且未到续期时间，跳过签发，直接重新安装。"
    fi

    # --install-cert 会先用传入的值覆盖 Le_ReloadCmd，再立即执行它。部署过程中只
    # reload Nginx、不重启 x-ui（不碰 443）；完整 hook 在安装前算好，装完写回 conf，
    # 续期时才执行。xui_uses_cert_dir 要在当前 shell 调用，XUI_CERT_USAGE 才带得回来。
    xui_uses_cert_dir || true
    hook=$(acme_reload_cmd)
    "$ACME_HOME/acme.sh" --install-cert --ecc -d "$DOMAIN" \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "systemctl reload nginx" \
        || fail "acme.sh install-cert 失败。"
    if conf=$(acme_conf_file "$DOMAIN"); then
        set_acme_reloadcmd "$conf" "$hook"
    fi
    chmod 0600 "$CERT_DIR/privkey.pem"
    cert_files_ok "$CERT_DIR" || fail "安装后仍找不到证书文件：$CERT_DIR"
    log "证书：已安装到 $CERT_DIR"
    case $XUI_CERT_USAGE in
        match) XUI_RESTART_NOTE=1 ;;
        unknown)
            warn "读不到 3x-ui 的证书设置：续期 hook 保守地包含 x-ui 重启。面板或原生订阅若使用 $CERT_DIR，现在执行 systemctl restart x-ui。" ;;
    esac
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
    # restart 返回时进程可能还没开始监听：subconverter 要先读完 base/ 与 snippets/。
    # 普通 --retry 不重试「连接被拒」，必须加 --retry-connrefused。重试期间 curl
    # 每失败一次就往 stderr 打一行，看起来像部署出错；先存起来，只在最终失败时回放。
    log "等待 subconverter 监听 127.0.0.1:25500"
    if ! curl -fsS --max-time 10 --retry 15 --retry-delay 1 --retry-connrefused \
            http://127.0.0.1:25500/version >/dev/null 2>"$WORK_DIR/subconverter-curl.err"; then
        cat "$WORK_DIR/subconverter-curl.err" >&2
        fail "subconverter 未在 127.0.0.1:25500 响应。查看 journalctl -u subconverter -n 50。"
    fi

    # proxy_cache_path 不会自己建目录，父目录缺失时 nginx -t 的 mkdir() 会失败。
    # 缓存目录属主与 nginx.conf 的 user 一致，规则缓存才能写入。
    [[ -d /var/cache/nginx ]] || install -d -m 0755 /var/cache/nginx
    install -d -o www-data -g www-data -m 0700 /var/cache/nginx/sub-rules

    nginx -t
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx
    else
        systemctl enable --now nginx
    fi

    # 先装证书，再按安装结果对齐续期方式和 hook：acme.sh 跳过签发时不改 conf。
    issue_cert
    normalize_acme_renewal
    ACME_NORMALIZED=1
    normalize_certbot_renewal

    sync_private_conf
}

# 按订阅状态重建订阅入口配置：有订阅（即使 private-sub.conf 被删了），或配置文件还在
# （即使已经没有订阅，常量变了也要更新），都 resync。首次安装两者都没有。
sync_private_conf() {
    count_subscriptions
    if (( SUB_COUNT > 0 )) || [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]]; then
        "$SBIN_DIR/sub-manager" resync
    fi
}

# 部署后的健康检查。与 uninstall 的 verify 对称：只报告，不修改。
verify_deploy() {
    local failed=0 svc
    for svc in x-ui subconverter nginx; do
        if systemctl is-active --quiet "$svc"; then
            log "  ✓ $svc 运行中"
        else
            warn "$svc 未运行。"
            failed=1
        fi
    done
    if curl -fsS --max-time 5 http://127.0.0.1:25500/version >/dev/null 2>&1; then
        log "  ✓ 转换后端 127.0.0.1:25500 响应正常"
    else
        warn "转换后端未响应；查看 journalctl -u subconverter -n 50。"
        failed=1
    fi
    if nginx -t >/dev/null 2>&1; then
        log "  ✓ nginx -t 通过"
    else
        warn "nginx -t 未通过。"
        failed=1
    fi
    if (( SUB_COUNT > 0 )); then
        if [[ -f "$NGINX_CONF_D_DIR/private-sub.conf" ]] \
            && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$SUB_PORT\$"; then
            log "  ✓ 订阅入口 $SUB_PORT 已就绪（$SUB_COUNT 条订阅，端到端验证用 sub-manager test）"
        else
            warn "有 $SUB_COUNT 条订阅，但 $SUB_PORT 订阅入口未就绪：运行 sub-manager resync，再 sub-manager test"
            failed=1
        fi
    fi
    return "$failed"
}

# 部署只安装聚合层，不碰 3x-ui，也不替用户创建订阅：订阅的前提是面板里已经有
# 节点和客户端，而这只能在面板里完成。把面板入口和后续命令一次打印出来。
print_next_steps() {
    local verify_ok=${1:-0} panel_url=""
    panel_url=$(xui_panel_url 2>/dev/null) || panel_url=""

    log ""
    if (( verify_ok == 0 )); then
        log "部署完成，验证通过。备份在 $BACKUP_DIR。"
    else
        warn "部署完成，但有验证项未通过（见上方警告）。备份在 $BACKUP_DIR。"
    fi
    log "回滚：$REPO_ROOT/tools/deploy.sh --rollback $BACKUP_DIR"
    log ""
    if (( XUI_RESTART_NOTE == 1 )); then
        log "面板或原生订阅使用 $CERT_DIR 的证书：执行 systemctl restart x-ui 让它加载新证书（443 会中断几秒）。"
        log ""
    fi
    log "下一步：在 3x-ui 面板里创建节点和客户端"
    log ""
    log "  订阅入口端口：$SUB_PORT（防火墙 / 云安全组需放行 TCP $SUB_PORT，否则设备拉不到订阅）"
    if [[ -n $panel_url ]]; then
        log "  面板地址：$panel_url"
    else
        log "  面板地址：读取面板设置失败，请从面板配置中确认端口和路径。"
    fi
    cat <<EOF

  1. 登录面板，确认 443 上有一个可用的 VLESS Reality 入站（没有则新建）。
  2. 在入站的客户端列表里添加客户端；备注会显示在订阅里。
  3. 回到服务器创建聚合订阅：

       $SBIN_DIR/sub-manager add --from-xui
       $SBIN_DIR/sub-manager test

EOF
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
        || warn "规则发布检查未通过；确认已经至少创建一条订阅。"
}

do_rollback() {
    [[ -d $ROLLBACK_DIR ]] || fail "备份目录不存在：$ROLLBACK_DIR"
    [[ -x "$ROLLBACK_DIR/restore.sh" ]] \
        || fail "备份目录里没有 restore.sh：$ROLLBACK_DIR"
    confirm "从 $ROLLBACK_DIR 恢复？" || { log "已取消。"; exit 0; }
    "$ROLLBACK_DIR/restore.sh" || fail "回滚已执行，但有检查未通过（见上方提示）。"
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

# EXIT trap：清理临时目录；装了 nginx 却没走到续期方式对齐时提示（nginx 已占用 80，
# standalone 续期会失败）。
on_exit() {
    if [[ -n $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    if (( INSTALLED_NGINX == 1 && ACME_NORMALIZED == 0 )); then
        warn "本次安装的 nginx 已启动并监听 80 端口，但部署没有完成。若本机证书用 acme.sh 或 certbot 的 standalone 方式续期，续期会失败：重新运行 deploy.sh 完成部署，或执行 systemctl disable --now nginx。"
    fi
}

main() {
    parse_args "$@"

    [[ -d "$REPO_ROOT/server" ]] || fail "找不到仓库根目录：$REPO_ROOT"

    if [[ -n $ROLLBACK_DIR ]]; then
        require_root
        do_rollback
        return 0
    fi

    require_root

    detect_existing_values
    # 写错的端口不值得先装一轮依赖。占用检查要等依赖就绪，留在 preflight。
    [[ -z $SUB_PORT ]] || validate_sub_port

    local deps_missing=0
    collect_missing_dependencies && deps_missing=1

    # 先装依赖，后面的推导才用得上（缺 sqlite3 时域名推导会失败）。
    # dry-run 只报告，不安装。
    if [[ $DRY_RUN -eq 0 && $deps_missing -eq 1 ]]; then
        if [[ $ASSUME_YES -eq 0 && ! -t 0 ]]; then
            fail "缺少依赖命令：${MISSING_COMMANDS[*]}（对应包：${MISSING_PACKAGES[*]}）。手工执行：apt-get update && apt-get install -y ${MISSING_PACKAGES[*]}，或加 --yes 自动安装。"
        fi
        print_missing_dependencies
        if ! confirm "安装以上依赖？"; then
            log "已取消。手工安装依赖：apt-get update && apt-get install -y ${MISSING_PACKAGES[*]}"
            return 0
        fi
        install_dependencies
    fi

    detect_domain
    prompt_values
    resolve_cert_dir
    fill_defaults
    validate_values
    preflight

    BACKUP_DIR="$BACKUP_ROOT/sub-aggregator-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    init_targets

    if [[ $DRY_RUN -eq 1 ]]; then
        print_plan
        log "dry-run：未做任何修改。"
        return 0
    fi

    print_summary
    confirm "按上面的配置继续？" || { log "已取消。"; return 0; }

    do_backup
    stage
    install_files
    setup_rules

    local verify_ok=0
    log ""
    log "验证："
    verify_deploy || verify_ok=1
    print_next_steps "$verify_ok"
    exit "$verify_ok"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap on_error ERR
    trap on_exit EXIT
    main "$@"
fi
