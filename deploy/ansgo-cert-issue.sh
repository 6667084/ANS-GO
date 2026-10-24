#!/bin/bash
# =============================================================================
# ansgo-cert-issue.sh —— AGENTS §9 步骤 1-3（服务端执行）
#   1. 安装 acme.sh（curl，~200KB）
#   2. 部署 dns_dynukey.sh（路径A 钩子）+ 校验路径B 凭证可达
#   3. 签发 example.com ECDSA 证书：路径A(默认) → 失败降级路径B
#      安装到 /etc/ssl/ansgo/{fullchain,privkey}.pem，reloadcmd=ansgo-cert-reload
#
# 用法（凭证经环境传入，不落盘额外文件）：
#   DYNU_API_KEY=... DYNU_CLIENT_ID=... DYNU_SECRET=... \
#     nohup bash ansgo-cert-issue.sh > /var/log/ansgo/cert-issue.log 2>&1 &
#
# 输出状态文件：/etc/ansgo-cert.status  (SUCCESS_A | SUCCESS_B | FAILED)
# =============================================================================
set -Eeuo pipefail
umask 077
# 自身即 300s 总期限的父进程；避免调用方再包一层导致信号/清理语义不一。
DOMAIN="${DOMAIN:-your-domain.com}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"
CERTDIR="/etc/ssl/ansgo"
STATUS_FILE="/etc/ansgo-cert.status"
ACME="/root/.acme.sh/acme.sh"
CERT_LOG=/var/log/ansgo/cert-issue.log

# 所有入口共享同一把锁；外层限时进程先持锁，内层子进程继承后不再重复加锁。
if [ "${_ANSGO_CERT_LOCK_HELD:-0}" != 1 ]; then
  exec 8>/etc/ansgo-cert.lock
  flock -n 8 || { echo '已有证书签发任务运行'; exit 1; }
  rm -f "$STATUS_FILE"
fi

LIB="${ANSGO_LIB:-/usr/local/bin/ansgo-limits}"
[ -f "$LIB" ] || LIB="$(dirname "${BASH_SOURCE[0]}")/ansgo-limits"
source "$LIB"
ansgo_logs_init
ansgo_log_trim "$CERT_LOG"
# 不依赖 acme 续期部署在宿主还是容器；随证书包一起刷新同类限流与日志函数。
# 日志是单一事实来源，不再重复 tee 到终端。
# 所有入口（安装、面板、cron）都有真实总期限；timeout 会终止整个子进程组。
if [ "${_ANSGO_CERT_TIMED:-0}" != 1 ]; then
  rc=0
  export _ANSGO_CERT_TIMED=1 _ANSGO_CERT_LOCK_HELD=1
  # 先建立独立会话，再让 timeout 管理其子进程组；超时后连同 acme/钩子一起清理。
  if command -v setsid >/dev/null; then
    setsid timeout --kill-after=5s 300s bash "$0" "$@" || rc=$?
  else
    timeout --kill-after=5s 300s bash "$0" "$@" || rc=$?
  fi
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    printf 'FAILED:timeout\n' > "$STATUS_FILE"
    msg="签发超过 300 秒，已终止进程组，请检查 $CERT_LOG"
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$msg" >> "$CERT_LOG" 2>/dev/null || true
    echo "$msg"
  fi
  # 子进程自行写日志；父进程只等待真实退出码。
  exit "$rc"
fi
# 子进程独占日志；父进程仅等待退出码，避免调用方重定向后日志丢失。
exec >> "$CERT_LOG" 2>&1
WORK=$(mktemp -d)
cert_cleanup(){
  local rc=$?
  rm -rf "$WORK"
  if [ "$rc" -ne 0 ]; then printf 'FAILED:exit-%s\n' "$rc" > "$STATUS_FILE"; fi
}
trap cert_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
log(){ ansgo_log_trim "$CERT_LOG"; echo "[$(date '+%H:%M:%S')] $*"; }
acme(){ ansgo_log_trim "$CERT_LOG"; "$ACME" "$@"; }
mkdir -p "$CERTDIR"

# ---- 步骤1: 安装 acme.sh ----
log "=== 步骤1: 安装 acme.sh ==="
if [ -x "$ACME" ]; then
  log "acme.sh 已存在，跳过安装。"
elif [ -n "${ACME_TARBALL:-}" ] && [ -f "$ACME_TARBALL" ]; then
  log "从 vendored 快照安装 acme.sh: $ACME_TARBALL"
  tar xzf "$ACME_TARBALL" -C "$WORK"
  ACME_SRC=$(find "$WORK" -type f -name acme.sh | head -1)
  [ -n "$ACME_SRC" ] && (cd "$(dirname "$ACME_SRC")" && bash ./acme.sh --install --home /root/.acme.sh --accountemail "$EMAIL")
  [ -x "$ACME" ] || { log "FATAL: vendored acme.sh 安装失败"; echo "FAILED:install" > "$STATUS_FILE"; exit 1; }
else
  if curl --connect-timeout 10 --max-time 60 -fsSL https://get.acme.sh -o "$WORK/install-acme.sh" && sh "$WORK/install-acme.sh" "email=${EMAIL}" --home /root/.acme.sh; then
    log "acme.sh 安装完成（官方源）。"
  else
    log "FATAL: acme.sh 安装失败"; echo "FAILED:install" > "$STATUS_FILE"; exit 1
  fi
fi
acme --set-default-ca --server letsencrypt >/dev/null 2>&1
# 注册账号（幂等，已注册会提示）
acme --register-account -m "${EMAIL}" --server letsencrypt >/dev/null 2>&1 || log "register-account: 已注册或忽略"

# ---- 部署重载助手 + 钩子 ----
install -m 0755 /etc/ansgo-deploy/ansgo-cert-reload /usr/local/bin/ansgo-cert-reload
mkdir -p /root/.acme.sh/dnsapi
install -m 0644 /etc/ansgo-deploy/dns_dynukey.sh /root/.acme.sh/dnsapi/dns_dynukey.sh
log "已部署 ansgo-cert-reload 与 dns_dynukey.sh 钩子。"

# ---- 步骤3: 签发（路径A 默认，失败降级B）----
USED=""
if [ -n "${DYNU_API_KEY:-}" ]; then
  log "=== 步骤3A: 路径A（API Key）签发 ==="
  export DYNU_API_KEY
  if acme --issue --dns dns_dynukey -d "$DOMAIN" --keylength ec-256 --server letsencrypt; then
    USED="A"
    log "路径A 签发成功。"
  else
    log "路径A 签发失败，准备降级路径B。"
  fi
else
  log "未提供 DYNU_API_KEY，跳过路径A。"
fi

if [ -z "$USED" ] && [ -n "${DYNU_CLIENT_ID:-}" ] && [ -n "${DYNU_SECRET:-}" ]; then
  log "=== 步骤3B: 路径B（OAuth2）签发 ==="
  export Dynu_ClientId="$DYNU_CLIENT_ID"
  export Dynu_Secret="$DYNU_SECRET"
  if acme --issue --dns dns_dynu -d "$DOMAIN" --keylength ec-256 --server letsencrypt; then
    USED="B"
    log "路径B 签发成功。"
  else
    log "路径B 签发也失败。"
  fi
fi

if [ -z "$USED" ]; then
  log "FATAL: A/B 双路径均失败；首次安装无有效证书时不能继续部署。"
  echo "FAILED" > "$STATUS_FILE"
  exit 1
fi

# ---- 安装证书到固定路径 + 配置续期 reloadcmd ----
log "=== 安装证书到 ${CERTDIR}（reloadcmd=ansgo-cert-reload）==="
if acme --install-cert -d "$DOMAIN" --ecc \
    --key-file       "${CERTDIR}/privkey.pem" \
    --fullchain-file "${CERTDIR}/fullchain.pem" \
    --reloadcmd      "/usr/local/bin/ansgo-cert-reload"; then
  log "证书安装完成。"
else
  log "FATAL: install-cert 失败"; echo "FAILED:install-cert" > "$STATUS_FILE"; exit 1
fi

chmod 644 "${CERTDIR}/fullchain.pem"
chmod 600 "${CERTDIR}/privkey.pem"

# ---- 校验 ----
log "=== 证书校验 ==="
SUBJECT=$(openssl x509 -in "${CERTDIR}/fullchain.pem" -noout -subject 2>/dev/null)
ISSUER=$(openssl x509 -in "${CERTDIR}/fullchain.pem" -noout -issuer 2>/dev/null)
DATES=$(openssl x509 -in "${CERTDIR}/fullchain.pem" -noout -dates 2>/dev/null)
log "subject: $SUBJECT"
log "issuer:  $ISSUER"
log "dates:   $DATES"

openssl x509 -in "$CERTDIR/fullchain.pem" -noout -checkend 0 >/dev/null || exit 1
cmod=$(openssl x509 -in "$CERTDIR/fullchain.pem" -pubkey -noout | openssl sha256)
kmod=$(openssl pkey -in "$CERTDIR/privkey.pem" -pubout | openssl sha256)
[ "$cmod" = "$kmod" ] || { log "证书与私钥不匹配"; exit 1; }
printf 'SUCCESS_%s\n' "$USED" > "$STATUS_FILE"

log "=== 完成（路径=${USED}）==="
