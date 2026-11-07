#!/usr/bin/env bash
# sub-aggregator 沙箱自测。
#
# 不碰真机：被测脚本先复制一份，把所有以 / 开头的 readonly 常量挪进
# /tmp/sub-aggregator-selftest-XXXXXX/sysroot，再在子 shell 里 source 副本，
# 只调用下面 case 用到的函数；acme.sh、systemctl、nginx、ss 等一律是桩。
# 副本生成后先做安全断言，任何一条不满足就以 99 退出，一个用例也不运行。
#
# 新增用例前先确认被测函数只使用文件顶部的常量路径，函数体里没有硬编码的
# 系统绝对路径；否则沙箱挡不住它。不要调用 main、install_files、setup_rules、
# stage、do_rollback。
#
# 用法：bash tools/selftest.sh（需要 root）。全部通过退出 0，有失败退出 1。
set -uo pipefail

[[ $EUID -eq 0 ]] || { printf '需要 root 运行。\n' >&2; exit 2; }

readonly REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=$(mktemp -d /tmp/sub-aggregator-selftest-XXXXXX)
readonly SANDBOX
trap 'rm -rf -- "$SANDBOX"' EXIT
readonly ROOT="$SANDBOX/sysroot"
readonly COPY_DIR="$SANDBOX/repo/tools"
readonly DEPLOY_COPY="$COPY_DIR/deploy.sh"
readonly UNINSTALL_COPY="$COPY_DIR/uninstall.sh"
readonly SUB_MANAGER_COPY="$SANDBOX/repo/server/sbin/sub-manager"
readonly CA_DIR="$SANDBOX/ca"
readonly STUB_BIN="$SANDBOX/bin"
readonly XUI_DIR="$SANDBOX/xui"
readonly D="sub.test"
readonly ACME="$ROOT/root/.acme.sh"
readonly CERT="$ROOT/root/cert/$D"
readonly WEBROOT="$ROOT/var/www/acme"
readonly LE_API="https://acme-v02.api.letsencrypt.org/directory"
readonly ZEROSSL_API="https://acme.zerossl.com/v2/DV90"
readonly STAGING_API="https://acme-staging-v02.api.letsencrypt.org/directory"

PASSED=0
FAILED=0
OUT=""
RC=0

# ---------- 输出 ----------

st_pass() { printf 'PASS %s %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
st_fail() {
    printf 'FAIL %s %s：期望 %s / 实际 %s\n' "$1" "$2" "$3" "$4"
    FAILED=$((FAILED + 1))
}
# st_check <id> <名称> <期望描述> <实际描述> <条件命令...>
st_check() {
    local id=$1 name=$2 want=$3 got=$4
    shift 4
    if "$@"; then st_pass "$id" "$name"; else st_fail "$id" "$name" "$want" "$got"; fi
}
has() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }

# ---------- 沙箱副本 ----------

st_make_copy() {
    local src=$1 dst=$2 strip=$3
    sed -E "s#^(readonly [A-Z_]+=\")/#\\1$ROOT/#" "$src" >"$dst.tmp"
    if [[ $strip == strip ]]; then
        # 删掉入口守卫块，才能 source 而不执行 main。
        awk '
            skip == 0 && /^if \[\[ \$\{BASH_SOURCE\[0\]\} == "\$0" \]\]; then/ { skip = 1; next }
            skip == 1 { if ($0 ~ /^fi$/) skip = 0; next }
            { print }
        ' "$dst.tmp" >"$dst"
        rm -f -- "$dst.tmp"
    else
        mv -f -- "$dst.tmp" "$dst"
    fi
}

st_assert_copy() {
    local copy=$1 strip=$2
    if grep -qE '^readonly [A-Z_]+="/(etc|usr|opt|var|root|srv|home)/' "$copy"; then
        printf '安全断言失败：%s 仍有指向真机的常量。\n' "$copy" >&2; exit 99
    fi
    if [[ $strip == strip ]] && grep -qE '^[[:space:]]*main "\$@"' "$copy"; then
        printf '安全断言失败：%s 仍会执行 main。\n' "$copy" >&2; exit 99
    fi
    if grep -qF '/root/sub-aggregator' "$copy"; then
        printf '安全断言失败：%s 含有硬编码的备份目录。\n' "$copy" >&2; exit 99
    fi
    # source 后逐个检查常量的实际值：以 / 开头的必须落在沙箱里。sub-manager 副本
    # 保留了 main，不能 source，只靠上面的文本断言。
    [[ $strip == strip ]] || return 0
    local name bad
    bad=$( (
        source "$copy" >/dev/null 2>&1 || true
        for name in $(sed -nE 's/^readonly ([A-Z_]+)=.*/\1/p' "$copy"); do
            [[ ${!name-} == /* && ${!name} != "$SANDBOX"* ]] && printf '%s=%s\n' "$name" "${!name}"
        done
    ) ) || true
    if [[ -n $bad ]]; then
        printf '安全断言失败：%s 的常量不在沙箱里：\n%s\n' "$copy" "$bad" >&2; exit 99
    fi
}

# ---------- 桩 ----------

# 函数桩：source 被测脚本前定义，被测函数调用的是它们而不是真命令。
systemctl() { "$STUB_BIN/systemctl" "$@"; }
nginx() { "$STUB_BIN/nginx" "$@"; }
ss() { "$STUB_BIN/ss" "$@"; }
curl() { printf 'curl %s\n' "$*" >>"$SANDBOX/calls.log"; return 0; }
apt-get() { printf 'apt-get %s\n' "$*" >>"$SANDBOX/calls.log"; return 0; }
sqlite3() { printf 'sqlite3 %s\n' "$*" >>"$SANDBOX/calls.log"; return 0; }

st_write_path_stubs() {
    install -d -m 0755 "$STUB_BIN"
    # systemctl：记录调用与单元文件当时是否存在；$SANDBOX/systemctl/<动作>/<单元>
    # 存在时输出其内容（用于 is-enabled / is-active）。
    cat >"$STUB_BIN/systemctl" <<EOF
#!/usr/bin/env bash
root='$ROOT'
sandbox='$SANDBOX'
EOF
    cat >>"$STUB_BIN/systemctl" <<'EOF'
verb="" unit=""
for a in "$@"; do
    [[ $a == -* ]] && continue
    if [[ -z $verb ]]; then verb=$a; else unit=$a; fi
done
state=""
if [[ -n $unit ]]; then
    [[ $unit == *.service || $unit == *.timer ]] || unit="$unit.service"
    if [[ -e $root/etc/systemd/system/$unit ]]; then state=present; else state=absent; fi
fi
printf 'systemctl %s%s\n' "$*" "${state:+ [$state]}" >>"$sandbox/calls.log"
canned="$sandbox/systemctl/$verb/$unit"
if [[ -n $unit && -f $canned ]]; then
    out=$(cat -- "$canned")
    [[ " $* " == *" --quiet "* ]] || printf '%s\n' "$out"
    [[ $out == enabled || $out == active ]] && exit 0
    exit 3
fi
exit 0
EOF
    cat >"$STUB_BIN/nginx" <<EOF
#!/usr/bin/env bash
printf 'nginx %s\n' "\$*" >>'$SANDBOX/calls.log'
if [[ \${1:-} == -t ]]; then
    if [[ \${STUB_NGINX_T_RC:-0} -eq 0 ]]; then
        printf 'nginx: configuration file test is successful\n' >&2
    else
        printf 'nginx: [emerg] stub failure\nnginx: configuration file test failed\n' >&2
    fi
    exit "\${STUB_NGINX_T_RC:-0}"
fi
exit 0
EOF
    cat >"$STUB_BIN/ss" <<EOF
#!/usr/bin/env bash
printf 'ss %s\n' "\$*" >>'$SANDBOX/calls.log'
if [[ \${STUB_SS_PORT80:-0} -eq 1 ]]; then
    printf 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:*\n'
fi
if [[ \${STUB_SS_PORT8443:-0} -eq 1 ]]; then
    printf 'LISTEN 0 511 0.0.0.0:8443 0.0.0.0:*\n'
fi
# 任意监听行，原样输出（含 users:(("进程名",...)) 时可模拟占用者）。
if [[ -n \${STUB_SS_EXTRA:-} ]]; then
    printf '%s\n' "\$STUB_SS_EXTRA"
fi
exit 0
EOF
    chmod 0755 "$STUB_BIN/systemctl" "$STUB_BIN/nginx" "$STUB_BIN/ss"
}

# 假 CA：真实 openssl 生成，签发者 DN 与三家 CA 的结构一致。
st_gen_ca() {
    local name=$1 subj=$2
    openssl ecparam -name prime256v1 -genkey -noout -out "$CA_DIR/$name.key" 2>/dev/null
    openssl req -x509 -new -key "$CA_DIR/$name.key" -subj "$subj" -days 3650 \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -out "$CA_DIR/$name.crt" 2>/dev/null
}

# st_sign_leaf <ca> <输出目录> ：写 <域名>.key、<域名>.cer、fullchain.cer
st_sign_leaf() {
    local ca=$1 dir=$2
    install -d -m 0700 "$dir"
    openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$D.key" 2>/dev/null
    openssl req -new -key "$dir/$D.key" -subj "/CN=$D" -out "$dir/$D.csr" 2>/dev/null
    openssl x509 -req -in "$dir/$D.csr" -CA "$CA_DIR/$ca.crt" -CAkey "$CA_DIR/$ca.key" \
        -set_serial "0x$(openssl rand -hex 8)" -days 90 \
        -extfile <(printf 'subjectAltName=DNS:%s\n' "$D") -out "$dir/$D.cer" 2>/dev/null
    cat "$dir/$D.cer" "$CA_DIR/$ca.crt" >"$dir/fullchain.cer"
    rm -f -- "$dir/$D.csr"
}

# 桩 acme.sh：按 v3.1.3 的顺序模拟。--issue 先做跳过检查（不写 conf），
# 再写 Le_Webroot / Le_API，然后才「下单」；--install-cert 只拷文件、写安装记录，
# 绝不执行 reloadcmd。
st_write_acme_stub() {
    install -d -m 0700 "$ACME"
    cat >"$ACME/acme.sh" <<EOF
#!/usr/bin/env bash
home='$ACME'
sandbox='$SANDBOX'
ca_dir='$CA_DIR'
EOF
    cat >>"$ACME/acme.sh" <<'EOF'
set -uo pipefail
printf '%q ' "$@" >>"$sandbox/acme-calls.log"
printf '\n' >>"$sandbox/acme-calls.log"
mode="" domain="" server="" webroot="" force=0 ecc=0 keyfile="" fullfile="" reloadcmd=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --issue|--install-cert) mode=$1; shift ;;
        -d) domain=$2; shift 2 ;;
        --server) server=$2; shift 2 ;;
        --webroot|-w) webroot=$2; shift 2 ;;
        --force) force=1; shift ;;
        --ecc) ecc=1; shift ;;
        --keylength) shift 2 ;;
        --key-file) keyfile=$2; shift 2 ;;
        --fullchain-file) fullfile=$2; shift 2 ;;
        --reloadcmd) reloadcmd=$2; shift 2 ;;
        *) shift ;;
    esac
done
setconf() {
    local conf=$1 key=$2 value=$3
    if grep -q "^$key=" "$conf"; then
        sed -i "s|^$key=.*\$|$key='$value'|" "$conf"
    else
        printf "%s='%s'\n" "$key" "$value" >>"$conf"
    fi
}
getconf() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1" | head -n 1; }
case $mode in
    --issue)
        dir="$home/${domain}_ecc"
        conf="$dir/$domain.conf"
        next=$( [[ -f $conf ]] && getconf "$conf" Le_NextRenewTime )
        if [[ $force -eq 0 && -f $conf && -n $next ]] && (( next > $(date +%s) )); then
            echo "Skipping. Next renewal time is: $next"
            exit 2
        fi
        install -d -m 0700 "$dir"
        [[ -f $conf ]] || printf "Le_Domain='%s'\nLe_Alt='no'\n" "$domain" >"$conf"
        case $server in
            letsencrypt) server="https://acme-v02.api.letsencrypt.org/directory" ;;
        esac
        setconf "$conf" Le_Webroot "$webroot"
        setconf "$conf" Le_API "$server"
        if [[ ${STUB_ORDER:-ok} == fail ]]; then
            echo "Create new order error."
            exit 1
        fi
        openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$domain.key" 2>/dev/null
        openssl req -new -key "$dir/$domain.key" -subj "/CN=$domain" -out "$dir/$domain.csr" 2>/dev/null
        openssl x509 -req -in "$dir/$domain.csr" -CA "$ca_dir/le.crt" -CAkey "$ca_dir/le.key" \
            -set_serial "0x$(openssl rand -hex 8)" -days 90 \
            -extfile <(printf 'subjectAltName=DNS:%s\n' "$domain") -out "$dir/$domain.cer" 2>/dev/null
        cat "$dir/$domain.cer" "$ca_dir/le.crt" >"$dir/fullchain.cer"
        rm -f -- "$dir/$domain.csr"
        setconf "$conf" Le_NextRenewTime "$(( $(date +%s) + 60 * 86400 ))"
        exit 0
        ;;
    --install-cert)
        # 与 acme.sh _initpath 一致：--ecc 用 _ecc；否则 RSA 目录存在就用它。
        if [[ $ecc -eq 1 ]]; then
            dir="$home/${domain}_ecc"
        elif [[ -d $home/$domain ]]; then
            dir="$home/$domain"
        else
            dir="$home/${domain}_ecc"
        fi
        conf="$dir/$domain.conf"
        [[ -f $conf ]] || { echo "not issued"; exit 1; }
        cp -- "$dir/fullchain.cer" "$fullfile"
        cp -- "$dir/$domain.key" "$keyfile"
        setconf "$conf" Le_RealFullChainPath "$fullfile"
        setconf "$conf" Le_RealKeyPath "$keyfile"
        setconf "$conf" Le_ReloadCmd "__ACME_BASE64__START_$(printf '%s' "$reloadcmd" | openssl base64 -A)__ACME_BASE64__END_"
        exit 0
        ;;
esac
exit 0
EOF
    chmod 0755 "$ACME/acme.sh"
}

# seed_acme <le|zerossl|staging> <Le_Webroot 值> [rsa]
seed_acme() {
    local kind=$1 webroot=$2 dir="$ACME/${D}_ecc" api
    [[ ${3:-} == rsa ]] && dir="$ACME/$D"
    case $kind in
        le) api=$LE_API ;;
        zerossl) api=$ZEROSSL_API ;;
        staging) api=$STAGING_API ;;
    esac
    st_sign_leaf "$kind" "$dir"
    cat >"$dir/$D.conf" <<EOF
Le_Domain='$D'
Le_Alt='no'
Le_Webroot='$webroot'
Le_NextRenewTime='$(( $(date +%s) + 30 * 86400 ))'
Le_API='$api'
EOF
}

acme_conf() { printf '%s\n' "$ACME/${D}_ecc/$D.conf"; }
conf_get() { sed -n "s/^$2='\(.*\)'\$/\1/p" "$1" | head -n 1; }
conf_set() {
    if grep -q "^$2=" "$1"; then
        sed -i "s|^$2=.*\$|$2='$3'|" "$1"
    else
        printf "%s='%s'\n" "$2" "$3" >>"$1"
    fi
}
b64_hook() { printf '__ACME_BASE64__START_%s__ACME_BASE64__END_' "$(printf '%s' "$1" | openssl base64 -A)"; }
decoded_hook() {
    local v
    v=$(conf_get "$1" Le_ReloadCmd)
    v=${v#*__ACME_BASE64__START_}
    v=${v%%__ACME_BASE64__END_*}
    printf '%s' "$v" | openssl base64 -d -A
}
issuer_o() {
    openssl x509 -in "$1" -noout -issuer -nameopt RFC2253 2>/dev/null \
        | sed 's/^issuer=//' | tr ',' '\n' | sed -n 's/^O=//p'
}

# 每个独立用例前清空沙箱系统根和调用记录。
st_reset() {
    rm -rf -- "$ROOT" "$XUI_DIR" "$SANDBOX/systemctl" "$SANDBOX/backup"
    : >"$SANDBOX/calls.log"
    : >"$SANDBOX/acme-calls.log"
    install -d -m 0755 "$ROOT/etc" "$ROOT/root/cert" "$XUI_DIR"
    printf '/bin/sh\n/bin/bash\n/usr/bin/bash\n' >"$ROOT/etc/shells"
    st_write_acme_stub
}

# run_deploy <函数> ：在子 shell 里 source deploy 副本，设好公共变量后调用 <函数>。
# 结果放在 OUT（stdout+stderr）和 RC。
run_deploy() {
    OUT=$( (
        # shellcheck disable=SC1090
        source "$DEPLOY_COPY"
        xui_setting() {
            [[ -e $XUI_DIR/FAIL ]] && return 1
            if [[ -f $XUI_DIR/$1 ]]; then cat -- "$XUI_DIR/$1"; else printf '\n'; fi
        }
        DOMAIN=$D
        CERT_DIR=$CERT
        SUB_PORT=$DEFAULT_SUB_PORT
        "$@"
    ) 2>&1 )
    RC=$?
}

# run_uninstall <函数> ：同上，source uninstall 副本。
run_uninstall() {
    OUT=$( (
        # shellcheck disable=SC1090
        source "$UNINSTALL_COPY"
        "$@"
    ) 2>&1 )
    RC=$?
}

# run_restore <备份目录> [环境变量...] ：作为子进程运行生成的 restore.sh，PATH 指向桩目录。
# stdout 放 OUT，stderr 放 ERR，退出码放 RC。
ERR=""
run_restore() {
    local dir=$1
    shift
    OUT=$(env "$@" PATH="$STUB_BIN:$PATH" "$dir/restore.sh" 2>"$SANDBOX/restore.err")
    RC=$?
    ERR=$(cat -- "$SANDBOX/restore.err")
}

# ---------- Phase 1：证书与续期 ----------

b_issue_then_normalize() { CERT_NEEDS_ISSUE=1; issue_cert; normalize_acme_renewal; }
b_install_files_order() { declare -f install_files; }

t1() {
    st_reset
    seed_acme le no
    run_deploy b_issue_then_normalize
    cp -- "$SANDBOX/acme-calls.log" "$SANDBOX/t1-acme-calls.log"
    local wr rc=$RC out=$OUT order
    wr=$(conf_get "$(acme_conf)" Le_Webroot)
    run_deploy b_install_files_order
    order=$(printf '%s\n' "$OUT" | grep -oE '\b(issue_cert|normalize_acme_renewal|normalize_certbot_renewal)\b' | paste -sd, -)
    st_check T1 "F1 复用 LE standalone 证书后续期改为 webroot" \
        "rc=0 Le_Webroot=$WEBROOT 顺序 issue_cert,normalize_acme_renewal,normalize_certbot_renewal" \
        "rc=$rc Le_Webroot=$wr 顺序 $order；$(oneline "$out")" \
        test "$rc" -eq 0 -a "$wr" = "$WEBROOT" -a "$order" = issue_cert,normalize_acme_renewal,normalize_certbot_renewal
}

t8() {
    local line
    line=$(grep -- '--install-cert' "$SANDBOX/t1-acme-calls.log" | head -n 1)
    st_check T8 "P2 install-cert 带 --ecc" "--ecc" "$line" has "$line" "--ecc"
}

b_backup_then_issue_fail() {
    CERT_NEEDS_ISSUE=1
    BACKUP_DIR="$SANDBOX/backup"
    init_targets
    do_backup
    export STUB_ORDER=fail
    issue_cert
}
b_issue_fail_again() {
    CERT_NEEDS_ISSUE=1
    BACKUP_DIR="$SANDBOX/backup"
    export STUB_ORDER=fail
    issue_cert
}

t2_t3() {
    st_reset
    seed_acme zerossl dns_cf
    run_deploy b_backup_then_issue_fail
    local api wr forces
    api=$(conf_get "$(acme_conf)" Le_API)
    wr=$(conf_get "$(acme_conf)" Le_Webroot)
    forces=$(grep -c -- '--force' "$SANDBOX/acme-calls.log")
    if (( RC != 0 )) && has "$OUT" "还原为部署前的版本" && [[ $api == "$ZEROSSL_API" && $wr == dns_cf ]] \
        && (( forces >= 1 )); then
        st_pass T2 "F2 强制重签失败后还原 acme.sh 配置"
    else
        st_fail T2 "F2 强制重签失败后还原 acme.sh 配置" \
            "rc≠0、提示还原、Le_API=ZeroSSL、Le_Webroot=dns_cf、出现 --force" \
            "rc=$RC Le_API=$api Le_Webroot=$wr --force×$forces；$(oneline "$OUT")"
    fi

    run_deploy b_issue_fail_again
    forces=$(grep -c -- '--force' "$SANDBOX/acme-calls.log")
    st_check T3 "F2 重跑仍按证书本身判断、再次强制重签" "--force×2" "--force×$forces rc=$RC" \
        test "$forces" -eq 2
}

b_issue_ok() { CERT_NEEDS_ISSUE=1; export STUB_ORDER=ok; issue_cert; }

t4() {
    st_reset
    seed_acme zerossl "$WEBROOT"
    run_deploy b_issue_ok
    local o api
    o=$(issuer_o "$CERT/fullchain.pem")
    api=$(conf_get "$(acme_conf)" Le_API)
    st_check T4 "F2 ZeroSSL 证书重签为 LE" "rc=0 O=Let's Encrypt Le_API=LE" \
        "rc=$RC O=$o Le_API=$api；$(oneline "$OUT")" \
        test "$RC" -eq 0 -a "$o" = "Let's Encrypt" -a "$api" = "$LE_API"
}

t5() {
    st_reset
    seed_acme staging "$WEBROOT"
    run_deploy b_issue_ok
    local o forces
    o=$(issuer_o "$CERT/fullchain.pem")
    forces=$(grep -c -- '--force' "$SANDBOX/acme-calls.log")
    st_check T5 "F2 staging 证书不算 LE，强制重签" "--force≥1 O=Let's Encrypt" \
        "--force×$forces O=$o rc=$RC" \
        test "$forces" -ge 1 -a "$o" = "Let's Encrypt"
}

b_issue_note() { CERT_NEEDS_ISSUE=1; export STUB_ORDER=ok; issue_cert; printf 'NOTE=%s\n' "$XUI_RESTART_NOTE"; }

t6_t7() {
    local id
    for id in T6 T7; do
        st_reset
        seed_acme le "$WEBROOT"
        conf_set "$(acme_conf)" Le_ReloadCmd "$(b64_hook 'echo custom-hook')"
        printf '%s\n' "$CERT/fullchain.pem" >"$XUI_DIR/webCertFile"
        [[ $id == T7 ]] && : >"$XUI_DIR/FAIL"
        run_deploy b_issue_note
        local line hook
        line=$(grep -- '--install-cert' "$SANDBOX/acme-calls.log" | head -n 1)
        hook=$(decoded_hook "$(acme_conf)")
        if [[ $id == T6 ]]; then
            if has "$line" '--reloadcmd systemctl\ reload\ nginx ' && has "$hook" 'echo custom-hook' \
                && has "$hook" 'systemctl restart x-ui' && has "$hook" 'systemctl reload nginx' \
                && has "$OUT" 'NOTE=1'; then
                st_pass T6 "F3 部署时只 reload nginx，完整 hook 写回 conf"
            else
                st_fail T6 "F3 部署时只 reload nginx，完整 hook 写回 conf" \
                    "--reloadcmd 'systemctl reload nginx'；hook 含 custom/restart x-ui/reload nginx；NOTE=1" \
                    "调用 $line；hook=$hook；$(oneline "$OUT")"
            fi
        else
            if has "$hook" 'systemctl restart x-ui' && has "$OUT" '读不到 3x-ui 的证书设置'; then
                st_pass T7 "F3 读不到面板设置时 hook 保守包含 x-ui 重启"
            else
                st_fail T7 "F3 读不到面板设置时 hook 保守包含 x-ui 重启" \
                    "hook 含 restart x-ui；提示读不到设置" "hook=$hook；$(oneline "$OUT")"
            fi
        fi
    done
}

b_normalize() { normalize_acme_renewal; }

t9() {
    st_reset
    seed_acme le "$WEBROOT"
    seed_acme le "$WEBROOT" rsa
    run_deploy b_normalize
    st_check T9 "P2 RSA 与 ECC 并存时警告" "输出含「RSA 与 ECC」" "$(oneline "$OUT")" \
        has "$OUT" "RSA 与 ECC"
}

b_normalize_reuse() { CERT_NEEDS_ISSUE=0; normalize_acme_renewal; }

t10() {
    local value wr ok=1 detail=""
    for value in /var/www/html alpn nginx: dns_cf /a,/b; do
        st_reset
        seed_acme le "$value"
        conf_set "$(acme_conf)" Le_RealFullChainPath "$CERT/fullchain.pem"
        conf_set "$(acme_conf)" Le_RealKeyPath "$CERT/privkey.pem"
        run_deploy b_normalize_reuse
        wr=$(conf_get "$(acme_conf)" Le_Webroot)
        case $value in
            dns_cf)
                [[ $wr == dns_cf && $RC -eq 0 ]] || { ok=0; detail+="[$value→$wr rc=$RC] "; } ;;
            /a,/b)
                [[ $wr == "/a,/b" && $RC -eq 0 ]] && has "$OUT" '警告' \
                    || { ok=0; detail+="[$value→$wr 无警告? $(oneline "$OUT")] "; } ;;
            *)
                [[ $wr == "$WEBROOT" && -f "$(acme_conf).orig" && $RC -eq 0 ]] \
                    || { ok=0; detail+="[$value→$wr orig=$([[ -f "$(acme_conf).orig" ]] && echo y || echo n)] "; } ;;
        esac
    done
    st_check T10 "P4 续期方式对齐表" "前三个改为 webroot 且有 .orig；dns_cf 不动；/a,/b 不动并警告" \
        "${detail:-符合}" test "$ok" -eq 1
}

b_sudo_case() {
    unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
    case $1 in
        a) export SUDO_USER=ubuntu SUDO_UID=1000 SUDO_GID=1000 SUDO_COMMAND=/root/code/x/tools/deploy.sh ;;
        b) export SUDO_USER=ubuntu SUDO_UID=1000 SUDO_GID=1000 SUDO_COMMAND=/bin/bash ;;
        c) ;;
        d) export SUDO_USER=root SUDO_UID=0 SUDO_GID=1000 SUDO_COMMAND=/root/code/x/tools/deploy.sh ;;
    esac
    if sudo_env_blocked; then printf 'R=0\n'; else printf 'R=1\n'; fi
}

t11() {
    local c got=""
    for c in a b c d; do
        run_deploy b_sudo_case "$c"
        got+="$c:$(printf '%s\n' "$OUT" | sed -n 's/^R=//p' | tail -n 1) "
    done
    st_check T11 "P1 sudo 环境判定与 acme.sh 一致" "a:0 b:1 c:1 d:1 " "$got" \
        test "$got" = "a:0 b:1 c:1 d:1 "
}

b_fail_with_backup() { BACKUP_DIR=$1; fail x; }

t12() {
    local with without
    st_reset
    install -d -m 0700 "$SANDBOX/bk1" "$SANDBOX/bk2"
    printf '#!/bin/sh\n' >"$SANDBOX/bk1/restore.sh"
    chmod 0700 "$SANDBOX/bk1/restore.sh"
    run_deploy b_fail_with_backup "$SANDBOX/bk1"
    with=$OUT
    run_deploy b_fail_with_backup "$SANDBOX/bk2"
    without=$OUT
    if has "$with" "--rollback $SANDBOX/bk1" && lacks "$without" "--rollback"; then
        st_pass T12 "P8 fail 在有备份时打印回滚命令"
    else
        st_fail T12 "P8 fail 在有备份时打印回滚命令" "有 restore.sh 时含 --rollback，否则不含" \
            "有：$(oneline "$with")；无：$(oneline "$without")"
    fi
}

b_certbot() { CERT_DIR="$ROOT/etc/letsencrypt/live/$D"; normalize_certbot_renewal; }

t13() {
    st_reset
    local live="$ROOT/etc/letsencrypt/live/$D" hook="$ROOT/etc/letsencrypt/renewal-hooks/deploy/sub-aggregator.sh"
    st_sign_leaf le "$SANDBOX/leaf"
    install -d -m 0755 "$live" "$ROOT/etc/letsencrypt/renewal"
    cp -- "$SANDBOX/leaf/fullchain.cer" "$live/fullchain.pem"
    cp -- "$SANDBOX/leaf/$D.key" "$live/privkey.pem"
    printf 'version = 2.9.0\n\n[renewalparams]\nauthenticator = standalone\n' \
        >"$ROOT/etc/letsencrypt/renewal/$D.conf"
    run_deploy b_certbot
    local mode content=""
    mode=$(stat -c %a -- "$hook" 2>/dev/null || echo missing)
    [[ -f $hook ]] && content=$(cat -- "$hook")
    local other own
    : >"$SANDBOX/calls.log"
    [[ -f $hook ]] && RENEWED_LINEAGE="$ROOT/etc/letsencrypt/live/other.test" PATH="$STUB_BIN:$PATH" sh "$hook"
    other=$(cat -- "$SANDBOX/calls.log")
    [[ -f $hook ]] && RENEWED_LINEAGE="$live" PATH="$STUB_BIN:$PATH" sh "$hook"
    own=$(cat -- "$SANDBOX/calls.log")
    if [[ $mode == 755 ]] && has "$content" 'systemctl reload nginx' \
        && has "$OUT" "certbot reconfigure --cert-name $D --webroot -w" \
        && [[ -z $other ]] && has "$own" "systemctl reload nginx"; then
        st_pass T13 "C1 certbot 证书安装 deploy hook，standalone 只警告"
    else
        st_fail T13 "C1 certbot 证书安装 deploy hook，standalone 只警告" \
            "hook 0755 含 reload nginx；提示 certbot reconfigure；别的证书续期时 hook 不动作" \
            "mode=$mode content=$(oneline "$content")；别的证书：$(oneline "$other")；本证书：$(oneline "$own")；$(oneline "$OUT")"
    fi
}

# ---------- Phase 2：回滚、恢复与中断 ----------

st_canned() {
    install -d -m 0755 "$SANDBOX/systemctl/$1"
    printf '%s\n' "$3" >"$SANDBOX/systemctl/$1/$2"
}

st_seed_uninstall() {
    st_reset
    local sd="$ROOT/etc/systemd/system"
    install -d -m 0755 "$sd" "$ROOT/usr/local/sbin" "$ROOT/etc/nginx/conf.d"
    printf '[Unit]\n' >"$sd/subconverter.service"
    printf '[Unit]\n' >"$sd/sub-rules-sync.timer"
    printf '#!/bin/sh\n' >"$ROOT/usr/local/sbin/sub-manager"
    printf 'server {}\n' >"$ROOT/etc/nginx/conf.d/private-sub.conf"
    st_canned is-enabled subconverter.service enabled
    st_canned is-active subconverter.service active
    st_canned is-enabled sub-rules-sync.timer disabled
    st_canned is-active sub-rules-sync.timer inactive
}

b_un_backup() { build_remove_paths; do_backup; printf 'BK=%s\n' "$BACKUP_DIR"; }

t14_t15() {
    local id bk state calls want
    want=$'subconverter.service enabled active\nsub-rules-sync.timer disabled inactive'
    for id in T14 T15; do
        st_seed_uninstall
        run_uninstall b_un_backup
        bk=$(printf '%s\n' "$OUT" | sed -n 's/^BK=//p' | tail -n 1)
        state=$(cat -- "$bk/units.state" 2>/dev/null)
        : >"$SANDBOX/calls.log"
        if [[ $id == T14 ]]; then
            run_restore "$bk"
        else
            run_restore "$bk" STUB_NGINX_T_RC=1
        fi
        calls=$(cat -- "$SANDBOX/calls.log")
        if [[ $id == T14 ]]; then
            if [[ $state == "$want" && $RC -eq 0 ]] \
                && grep -q '^systemctl enable subconverter\.service' <<<"$calls" \
                && grep -q '^systemctl start subconverter\.service' <<<"$calls" \
                && ! grep -qE '^systemctl .*\b(enable|start)\b.*sub-rules-sync\.timer' <<<"$calls"; then
                st_pass T14 "F4 卸载恢复按记录还原单元状态"
            else
                st_fail T14 "F4 卸载恢复按记录还原单元状态" \
                    "units.state 两行正确；enable/start subconverter；不启用 timer；rc=0" \
                    "state=$(oneline "$state") rc=$RC calls=$(oneline "$calls")"
            fi
        else
            st_check T15 "F4 nginx -t 失败时恢复以非 0 退出" "rc≠0，stderr 含「nginx -t 未通过」" \
                "rc=$RC stderr=$(oneline "$ERR")" \
                eval '(( RC != 0 )) && has "$ERR" "nginx -t 未通过"'
        fi
    done
}

# 部署备份：restore.list / remove.list 先空着，由用例填。
st_deploy_backup() {
    st_reset
    DBK="$SANDBOX/dbk"
    rm -rf -- "$DBK"
    install -d -m 0700 "$DBK"
    : >"$DBK/restore.list"
    : >"$DBK/remove.list"
}
# st_backup_file <路径> <备份内容> ：备份里放一份 <路径>，并登记到 restore.list。
st_backup_file() {
    install -d -m 0755 "$DBK$(dirname -- "$1")"
    printf '%s\n' "$2" >"$DBK$1"
    printf '%s\n' "$1" >>"$DBK/restore.list"
}

b_write_restore() { BACKUP_DIR=$1; write_restore_script; }

t16() {
    st_deploy_backup
    local psc="$ROOT/etc/nginx/conf.d/private-sub.conf" content log=""
    install -d -m 0755 "$(dirname -- "$psc")" "$ROOT/usr/local/sbin"
    printf 'CURRENT\n' >"$psc"
    st_backup_file "$psc" OLD
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%q\n' "$SANDBOX/sub-manager.log" >"$ROOT/usr/local/sbin/sub-manager"
    chmod 0755 "$ROOT/usr/local/sbin/sub-manager"
    rm -f -- "$SANDBOX/sub-manager.log"
    run_deploy b_write_restore "$DBK"
    run_restore "$DBK"
    content=$(cat -- "$psc" 2>/dev/null)
    [[ -f $SANDBOX/sub-manager.log ]] && log=$(cat -- "$SANDBOX/sub-manager.log")
    st_check T16 "P7 回滚不从快照恢复 private-sub.conf，改为 resync" "内容 CURRENT；sub-manager resync" \
        "内容 $content；sub-manager 调用 $(oneline "$log")；rc=$RC $(oneline "$ERR")" \
        eval '[[ $content == CURRENT && $log == *resync* ]]'
}

t17() {
    st_deploy_backup
    local unit="$ROOT/etc/systemd/system/subconverter.service" calls
    install -d -m 0755 "$(dirname -- "$unit")"
    printf '[Unit]\n' >"$unit"
    printf '%s\n' "$unit" >>"$DBK/remove.list"
    run_deploy b_write_restore "$DBK"
    : >"$SANDBOX/calls.log"
    run_restore "$DBK"
    calls=$(cat -- "$SANDBOX/calls.log")
    st_check T17 "O1 回滚删除单元前先停用" "systemctl disable --now subconverter.service [present]" \
        "$(oneline "$calls")" has "$calls" "systemctl disable --now subconverter.service [present]"
}

t18() {
    st_deploy_backup
    local conf
    conf=$(acme_conf)
    install -d -m 0700 "$(dirname -- "$conf")"
    printf "Le_Webroot='%s'\n" "$WEBROOT" >"$conf"
    st_backup_file "$conf" "Le_Webroot='no'"
    run_deploy b_write_restore "$DBK"
    run_restore "$DBK" STUB_SS_PORT80=1
    st_check T18 "P3 恢复出 standalone 而 80 被占时提示" "stderr 含「恢复为 standalone 续期，但 80 端口仍在监听」" \
        "rc=$RC stderr=$(oneline "$ERR")" has "$ERR" "恢复为 standalone 续期，但 80 端口仍在监听"
}

b_on_exit() { WORK_DIR=""; INSTALLED_NGINX=1; ACME_NORMALIZED=$1; on_exit; }

t19() {
    local first second
    st_reset
    run_deploy b_on_exit 0
    first=$OUT
    run_deploy b_on_exit 1
    second=$OUT
    st_check T19 "P3 装了 nginx 却没完成部署时提示" "前者含 systemctl disable --now nginx；后者无输出" \
        "前者 $(oneline "$first")；后者 $(oneline "$second")" \
        eval '[[ $first == *"systemctl disable --now nginx"* && -z $second ]]'
}

b_stop_services() { stop_services; }

t20() {
    st_reset
    run_uninstall b_stop_services
    local calls
    calls=$(cat -- "$SANDBOX/calls.log")
    st_check T20 "O1 没有单元文件时仍停掉残留进程" "calls 含 systemctl stop subconverter.service" \
        "$(oneline "$calls")" has "$calls" "systemctl stop subconverter.service"
}

# ---------- Phase 3：重装时的状态 ----------

readonly SBIN="$ROOT/usr/local/sbin"
readonly STATE_FILE_SB="$ROOT/etc/sub-manager/clients.json"
readonly PRIVATE_SUB="$ROOT/etc/nginx/conf.d/private-sub.conf"

b_detect() {
    DOMAIN=$1
    CERT_DIR=""
    detect_existing_values
    printf 'DOMAIN=%s\nCERT_DIR=%s\nCHANGED=%s\n' "$DOMAIN" "$CERT_DIR" "${DOMAIN_CHANGED_FROM-}"
}
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | tail -n 1; }

t21() {
    st_reset
    install -d -m 0755 "$SBIN"
    printf 'readonly HOST="old.test"\nreadonly CERT_FILE="%s"\n' "$ROOT/root/cert/old.test/fullchain.pem" \
        >"$SBIN/sub-manager"
    local a b
    run_deploy b_detect new.test
    a="DOMAIN=$(field DOMAIN) CERT_DIR=$(field CERT_DIR) CHANGED=$(field CHANGED)"
    run_deploy b_detect ""
    b="DOMAIN=$(field DOMAIN) CERT_DIR=$(field CERT_DIR) CHANGED=$(field CHANGED)"
    st_check T21 "P6 换域名时不沿用旧证书目录" \
        "DOMAIN=new.test CERT_DIR= CHANGED=old.test | DOMAIN=old.test CERT_DIR=$ROOT/root/cert/old.test CHANGED=" \
        "$a | $b" \
        test "$a | $b" = "DOMAIN=new.test CERT_DIR= CHANGED=old.test | DOMAIN=old.test CERT_DIR=$ROOT/root/cert/old.test CHANGED="
}

b_matches() {
    local r1=1 r2=1
    cert_matches_domain "$1" sub.test && r1=0
    cert_matches_domain "$1" other.test && r2=0
    printf 'R=%s,%s\n' "$r1" "$r2"
}

t22() {
    st_reset
    st_sign_leaf le "$SANDBOX/leaf"
    run_deploy b_matches "$SANDBOX/leaf/fullchain.cer"
    st_check T22 "P6 证书域名匹配" "R=0,1" "$(oneline "$OUT")" test "$(field R)" = "0,1"
}

st_sub_manager_stub() {
    install -d -m 0755 "$SBIN"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%q\n' "$SANDBOX/sub-manager.log" >"$SBIN/sub-manager"
    chmod 0755 "$SBIN/sub-manager"
    rm -f -- "$SANDBOX/sub-manager.log"
}
b_sync() { sync_private_conf; printf 'SUB_COUNT=%s\n' "$SUB_COUNT"; }

t23() {
    local c ok=1 detail="" called
    for c in 1 2 3 4; do
        st_reset
        st_sub_manager_stub
        install -d -m 0700 "$(dirname -- "$STATE_FILE_SB")"
        install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
        case $c in
            1) printf '{"version":2,"clients":{"sub-1":{},"sub-2":{}}}\n' >"$STATE_FILE_SB" ;;
            2) printf '{"version":2,"clients":{}}\n' >"$STATE_FILE_SB"; printf 'x\n' >"$PRIVATE_SUB" ;;
            3) printf '{"version":2,"clients":{}}\n' >"$STATE_FILE_SB" ;;
            4) printf '{"version":2,"clients":' >"$STATE_FILE_SB"; printf 'x\n' >"$PRIVATE_SUB" ;;
        esac
        run_deploy b_sync
        called=no
        grep -qx resync "$SANDBOX/sub-manager.log" 2>/dev/null && called=yes
        case $c in
            1|2) [[ $called == yes && $RC -eq 0 ]] || { ok=0; detail+="[($c) resync=$called rc=$RC $(oneline "$OUT")] "; } ;;
            3) [[ $called == no && $RC -eq 0 ]] || { ok=0; detail+="[($c) resync=$called rc=$RC] "; } ;;
            4) [[ $called == no && $RC -ne 0 ]] && has "$OUT" "不是有效的订阅状态" \
                   || { ok=0; detail+="[($c) resync=$called rc=$RC $(oneline "$OUT")] "; } ;;
        esac
    done
    st_check T23 "P5/P9 按订阅状态决定是否 resync" "(1)(2) resync；(3) 不调用；(4) fail" \
        "${detail:-符合}" test "$ok" -eq 1
}

t24() {
    st_reset
    install -d -m 0700 "$(dirname -- "$STATE_FILE_SB")"
    install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
    printf '{"version":2,"clients":{}}\n' >"$STATE_FILE_SB"
    printf 'placeholder\n' >"$PRIVATE_SUB"
    OUT=$(PATH="$STUB_BIN:$PATH" bash "$SUB_MANAGER_COPY" resync 2>&1)
    RC=$?
    local content
    content=$(cat -- "$PRIVATE_SUB" 2>/dev/null)
    st_check T24 "P9 零订阅但有配置时 resync 照常重建" "rc=0；含 Generated by 与 listen 8443 ssl" \
        "rc=$RC $(oneline "$OUT")；文件 $(oneline "$content" | cut -c1-80)" \
        eval '(( RC == 0 )) && has "$content" "Generated by" && has "$content" "listen 8443 ssl"'
}

b_verify() { SUB_COUNT=2; if verify_deploy; then printf 'R=0\n'; else printf 'R=1\n'; fi; }
b_verify_ready() { export STUB_SS_PORT8443=1; b_verify; }

t25() {
    local bad good
    st_reset
    run_deploy b_verify
    bad="R=$(field R) $(oneline "$OUT")"
    install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
    printf 'server {}\n' >"$PRIVATE_SUB"
    run_deploy b_verify_ready
    good="R=$(field R) $(oneline "$OUT")"
    st_check T25 "P5 有订阅时验证 8443 入口" "未就绪 R=1 且提示；就绪 R=0 且「已就绪」" "未就绪：$bad；就绪：$good" \
        eval '[[ $bad == "R=1 "*"8443 订阅入口未就绪"* && $good == "R=0 "*"订阅入口 8443 已就绪"* ]]'
}

# ---------- 审查修正 ----------

b_sync_quiet() { sync_private_conf; }

t26() {
    st_reset
    st_sub_manager_stub
    install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
    printf 'server {}\n' >"$PRIVATE_SUB"
    run_deploy b_sync_quiet
    local called=no
    grep -qx resync "$SANDBOX/sub-manager.log" 2>/dev/null && called=yes
    st_check T26 "状态文件缺失而配置还在时拒绝 resync" "rc≠0，不调用 resync，提示状态文件缺失" \
        "rc=$RC resync=$called $(oneline "$OUT")" \
        eval '(( RC != 0 )) && [[ $called == no ]] && has "$OUT" "缺失"'
}

t27() {
    st_reset
    install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
    printf 'ORIGINAL\n' >"$PRIVATE_SUB"
    OUT=$(PATH="$STUB_BIN:$PATH" bash "$SUB_MANAGER_COPY" resync 2>&1)
    RC=$?
    local content
    content=$(cat -- "$PRIVATE_SUB")
    st_check T27 "sub-manager：状态文件缺失时 resync 不覆盖现有配置" "rc≠0；private-sub.conf 仍是 ORIGINAL" \
        "rc=$RC 文件=$(oneline "$content")；$(oneline "$OUT")" \
        eval '(( RC != 0 )) && [[ $content == ORIGINAL ]]'
}

t28() {
    st_reset
    seed_acme le /var/www/html
    conf_set "$(acme_conf)" Le_Alt "www.$D"
    conf_set "$(acme_conf)" Le_RealFullChainPath "$CERT/fullchain.pem"
    conf_set "$(acme_conf)" Le_RealKeyPath "$CERT/privkey.pem"
    run_deploy b_normalize_reuse
    local wr
    wr=$(conf_get "$(acme_conf)" Le_Webroot)
    st_check T28 "多域名证书不改写 webroot" "Le_Webroot 仍为 /var/www/html 且警告" "Le_Webroot=$wr；$(oneline "$OUT")" \
        eval '[[ $wr == /var/www/html ]] && has "$OUT" "警告"'
}

t29() {
    st_reset
    seed_acme le "$WEBROOT"
    conf_set "$(acme_conf)" Le_API "$ZEROSSL_API"
    conf_set "$(acme_conf)" Le_RealFullChainPath "$CERT/fullchain.pem"
    conf_set "$(acme_conf)" Le_RealKeyPath "$CERT/privkey.pem"
    run_deploy b_normalize_reuse
    local api
    api=$(conf_get "$(acme_conf)" Le_API)
    st_check T29 "证书已是 LE 而 conf 仍指向旧 CA 时对齐 Le_API" "Le_API=LE" "Le_API=$api；$(oneline "$OUT")" \
        test "$api" = "$LE_API"
}

# ---------- 订阅端口 ----------

b_detect_port() {
    SUB_PORT=$1
    detect_existing_values
    printf 'PORT=%s\nCHANGED=%s\n' "$SUB_PORT" "$PORT_CHANGED_FROM"
}

t30() {
    local a b c
    st_reset
    run_deploy b_detect_port ""
    a="PORT=$(field PORT) CHANGED=$(field CHANGED)"
    install -d -m 0755 "$SBIN"
    printf 'readonly HOST="%s"\nreadonly PORT="9443"\n' "$D" >"$SBIN/sub-manager"
    run_deploy b_detect_port ""
    b="PORT=$(field PORT) CHANGED=$(field CHANGED)"
    run_deploy b_detect_port 10443
    c="PORT=$(field PORT) CHANGED=$(field CHANGED)"
    st_check T30 "重装沿用已安装端口，换端口时记下旧值" \
        "PORT= CHANGED= | PORT=9443 CHANGED= | PORT=10443 CHANGED=9443" "$a | $b | $c" \
        test "$a | $b | $c" = "PORT= CHANGED= | PORT=9443 CHANGED= | PORT=10443 CHANGED=9443"
}

b_validate_port() { RULES_PREFIX=0123456789abcdef01234567; RULES_REPO=o/r; PROFILE_NAME=X; SUB_PORT=$1; validate_values && printf 'R=0\n'; }

t31() {
    local p got="" want="9443:0 65535:0 443:1 2096:1 25500:1 80:1 0:1 08443:1 65536:1 abc:1"
    st_reset
    for p in 9443 65535 443 2096 25500 80 0 08443 65536 abc; do
        run_deploy b_validate_port "$p"
        got+="$p:$(( RC == 0 ? 0 : 1 )) "
    done
    got=${got% }
    st_check T31 "端口校验：范围与保留端口" "$want" "$got" test "$got" = "$want"
}

b_check_port() { SUB_PORT=$1; check_sub_port && printf 'R=0\n'; }

t32() {
    local free busy ours other
    st_reset
    run_deploy b_check_port 8443
    free="rc=$RC"
    STUB_SS_EXTRA='LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:* users:(("caddy",pid=1,fd=3))' \
        run_deploy b_check_port 8443
    busy="rc=$RC $(oneline "$OUT")"
    install -d -m 0755 "$(dirname -- "$PRIVATE_SUB")"
    printf 'server {\n    listen 9443 ssl;\n}\n' >"$PRIVATE_SUB"
    STUB_SS_EXTRA='LISTEN 0 511 0.0.0.0:9443 0.0.0.0:* users:(("nginx",pid=1,fd=6))' \
        run_deploy b_check_port 9443
    ours="rc=$RC $(oneline "$OUT")"
    STUB_SS_EXTRA='LISTEN 0 511 0.0.0.0:10443 0.0.0.0:* users:(("nginx",pid=1,fd=7))' \
        run_deploy b_check_port 10443
    other="rc=$RC $(oneline "$OUT")"
    st_check T32 "端口占用：他人占用失败并提示 --port；本服务沿用；其他 nginx 站点警告" \
        "空闲 rc=0；caddy 占用 rc≠0 含 --port；本服务 rc=0 含「沿用」；他站 rc=0 含警告" \
        "$free | $busy | $ours | $other" \
        eval '[[ $free == "rc=0" && $busy == "rc=1 "*"--port"* && $ours == "rc=0 "*"沿用"* && $other == "rc=0 "*"警告"* ]]'
}

b_placeholders() {
    WORK_DIR=$1
    SUB_PORT=9443
    PROFILE_NAME=X
    RULES_PREFIX=ab8443cd8443ef0123456789
    RULES_REPO=$DEFAULT_RULES_REPO
    apply_placeholders
}

t33() {
    st_reset
    local work="$SANDBOX/stage" sm rs rc left
    rm -rf -- "$work"
    install -d -m 0700 "$work"
    cp -a "$REPO/server/." "$work/server/"
    run_deploy b_placeholders "$work"
    sm=$(grep -c '^readonly PORT="9443"$' "$work/server/sbin/sub-manager")
    rs=$(grep -c "https://$D:9443/r/ab8443cd8443ef0123456789/" "$work/server/subconverter/snippets/rulesets.txt")
    rc=$(grep -cF "${D//./\\.}:9443/r/ab8443cd8443ef0123456789/" "$work/server/sbin/sub-rules-check")
    left=$(grep -rlE "(sub\.example\.com|$D|${D//./\\\\.}):8443" "$work/server" | paste -sd, -)
    st_check T33 "--port 9443 替换 sub-manager、rulesets.txt、sub-rules-check，前缀不受影响" \
        "PORT 常量 1 处；rulesets 2 条；check 至少 1 处；无残留 :8443" \
        "rc=$RC PORT=$sm rulesets=$rs check=$rc 残留=$left $(oneline "$OUT")" \
        eval '(( RC == 0 && sm == 1 && rs == 2 && rc >= 1 )) && [[ -z $left ]]'
}

b_main_bad_port() {
    collect_missing_dependencies() { MISSING_COMMANDS=(nginx); MISSING_PACKAGES=(nginx); return 0; }
    install_dependencies() { printf 'INSTALLED=1\n'; }
    main --port 443 --yes
}

t34() {
    st_reset
    run_deploy b_main_bad_port
    st_check T34 "保留端口在安装依赖之前被拒绝" "rc≠0；未安装依赖" "rc=$RC $(oneline "$OUT")" \
        eval '(( RC != 0 )) && ! has "$OUT" "INSTALLED=1" && has "$OUT" "固定端口"'
}

# ---------- 入口 ----------

main() {
    install -d -m 0700 "$CA_DIR" "$COPY_DIR"
    st_make_copy "$REPO/tools/deploy.sh" "$DEPLOY_COPY" strip
    st_assert_copy "$DEPLOY_COPY" strip
    st_make_copy "$REPO/tools/uninstall.sh" "$UNINSTALL_COPY" strip
    st_assert_copy "$UNINSTALL_COPY" strip
    install -d -m 0700 "$(dirname -- "$SUB_MANAGER_COPY")"
    st_make_copy "$REPO/server/sbin/sub-manager" "$SUB_MANAGER_COPY" keep
    st_assert_copy "$SUB_MANAGER_COPY" keep
    st_write_path_stubs
    export PATH="$STUB_BIN:$PATH"

    st_gen_ca le "/C=US/O=Let's Encrypt/CN=Test LE"
    st_gen_ca zerossl "/C=AT/O=ZeroSSL/CN=Test ZeroSSL"
    st_gen_ca staging "/C=US/O=(STAGING) Let's Encrypt/CN=Test Staging"

    t1
    t2_t3
    t4
    t5
    t6_t7
    t8
    t9
    t10
    t11
    t12
    t13
    t14_t15
    t16
    t17
    t18
    t19
    t20
    t21
    t22
    t23
    t24
    t25
    t26
    t27
    t28
    t29
    t30
    t31
    t32
    t33
    t34

    printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
    (( FAILED == 0 ))
}

main "$@"
