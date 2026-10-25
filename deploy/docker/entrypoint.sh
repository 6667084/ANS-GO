#!/bin/bash
# =============================================================================
# ansgo-entrypoint —— all-in-one 容器初始化 + 启动 systemd（PID 1）
#
# 首次启动（/etc/ansgo/panel.json 不存在）：
#   1. 生成 panel.json（端口/伪装/svc_*_enabled=false/随机 url_path）
#   2. 生成 secrets.env（SS / ANYTLS / SOCKS / NAIVE 密钥）
#   3. 设置管理员密码（PANEL_PASS 环境变量 → bcrypt）
# 每次启动：
#   4. 确保证书存在（acme 首次无有效证书则签发，manual 则校验同步副本）
#   5. ansgo-genconf 生成 sing-box / caddy 配置
#   6. 首次 acme 必须取得有效 Let's Encrypt 证书，否则容器初始化失败
#   7. exec /sbin/init（systemd 拉起 caddy(:443) + ansgo-panel）
#
# 所有配置/密钥/证书持久化在挂载卷，容器重建不丢失。
# =============================================================================
set -Eeuo pipefail
umask 077

CONF=/etc/ansgo/panel.json
SECRETS=/etc/ansgo/secrets.env
CERTDIR=/etc/ssl/ansgo
DOMAIN="${DOMAIN:-example.com}"
EMAIL="${EMAIL:-admin@${DOMAIN}}"
# 证书来源：acme（默认，需 Dynu 凭证）/ manual（手动指定已有证书+私钥路径）
# env 只在首次初始化使用；已有 panel.json 时下方统一以持久配置覆盖。
CERT_MODE="${CERT_MODE:-acme}"
CERT_FULLCHAIN="${CERT_FULLCHAIN:-}"
CERT_PRIVKEY="${CERT_PRIVKEY:-}"
DYNU_API_KEY="${DYNU_API_KEY:-}"
DYNU_CLIENT_ID="${DYNU_CLIENT_ID:-}"
DYNU_SECRET="${DYNU_SECRET:-}"

source /usr/local/bin/ansgo-limits || exit 1
ansgo_logs_init || exit 1
ansgo_limits || exit 1
log(){ ansgo_log_trim /var/log/ansgo/entrypoint.log; echo "[entrypoint] $*" | tee -a /var/log/ansgo/entrypoint.log; }
# 编码仅用于穿过 compose dotenv；secrets.env 内始终保存字面值。
for field in SS_KEY_IN ANYTLS_PASS_IN ANYTLS_UUID_IN SOCKS_USER_IN SOCKS_PASS_IN NAIVE_USER_IN NAIVE_PASS_IN; do
  encoded="${field}_ENCODED"
  if [ -n "${!encoded:-}" ]; then
    value=$(python3 - "${!encoded}" <<'PYSECRET'
import sys, urllib.parse
value = urllib.parse.unquote(sys.argv[1])
if any(c in value for c in '\n\r\0'): sys.exit('凭证不能包含换行或 NUL')
print(value, end='')
PYSECRET
) || exit 1
    printf -v "$field" '%s' "$value"
  fi
  value="${!field:-}"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    log "FATAL: $field 不能包含换行"; exit 1
  fi
done

mkdir -p /etc/ansgo "$CERTDIR" /etc/sing-box /etc/caddy /var/www/html /var/log
# v1.5.32: 标记容器环境，面板 isDockerMode() 据此识别 Docker 形态（显示 manual 证书宿主路径 UI）。
# 注意：本 shell export 不会传给 systemd 拉起的 ansgo-panel.service，所以 isDockerMode()
#       主要依赖下方写入的 /.dockerenv 文件（每启动都确保存在）。env 仅作容器内其它脚本参考。
[ -f /.dockerenv ] || { : > /.dockerenv; }
export ANSGO_DOCKER=1

# v1.5.12: 端口默认随机生成（10000-65535）。容器内无 ss 命令查占用，
# host 网络模式下 install.sh 已在宿主选好随机端口并通过 ansgo.env 透传
# （SS_PORT/ANYTLS_PORT/SOCKS_PORT/NAIVE_PORT/PANEL_PORT），此处仅作容器首次启动兜底。
_rand_port(){ python3 -c "import random;print(random.randint(10000,65535))"; }
RPANEL_PORT="${PANEL_PORT:-$(_rand_port)}"
RSS_PORT="${SS_PORT:-$(_rand_port)}"
RANYTLS_PORT="${ANYTLS_PORT:-$(_rand_port)}"
RSOCKS_PORT="${SOCKS_PORT:-$(_rand_port)}"
RNAIVE_PORT="${NAIVE_PORT:-$(_rand_port)}"

# ---- v1.5.37: panel.json 首次生成抽出为函数（可离线测试 + JSON 转义防御）----
# 函数体约定：fnname(){ 顶格起、结束 } 顶格独立一行，供 scripts/test-*.sh 提取执行。
# JSON 字符串体转义（" \ 全部控制字符 -> \t \n \r \uXXXX；非 ASCII 原样）——
# env 来源可能绕过上游校验（如 percent 解码出的 TAB），写入前防御性标准转义，
# 保证任何值都不会破坏 JSON 结构（分层防御，与 install.sh 同语义）
ansgo_json_escape(){
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1])'
  else
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
  fi
}

# percent 解码（与 install.sh ansgo_pct_encode 配对；python3 缺失时原样返回）
ansgo_pct_decode(){
  python3 -c 'import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))' "$1" 2>/dev/null || printf '%s' "$1"
}

# 首次生成 panel.json（$1=输出路径）。返回：0=成功；1=已存在（不动文件，卷数据优先，
# 已有配置不覆盖：容器重建/升级时保留用户在面板改过的标题/IP/端口等）；2=失败（stderr 有原因）。
# Sentinel 修复：原子写（同目录 tmp + python3 JSON 校验 + chmod 0600 + mv），失败绝不被吞成 0。
# v1.5.37: 消费 ansgo.env 的 PANEL_TITLE_ENCODED（install.sh --panel-title 经 percent-encoding
#   transport；ENCODED 键名自明编码语义），解码 + trim 后写 panel.json 可读值；空走旧语义
#   "ANS-GO 管理面板"。SERVER_IP_IN 明文（install 侧已严格校验值域）。本脚本不做公网查询。
entrypoint_ensure_panel_json(){
  local out="$1"
  [ -f "$out" ] && return 1
  local title_raw='' URLPATH title_json ip_json tmp
  local pport ssport atport skport nvport
  if [ -n "${PANEL_TITLE_ENCODED:-}" ]; then
    title_raw="$(ansgo_pct_decode "${PANEL_TITLE_ENCODED}")"
    title_raw="$(printf '%s' "$title_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  [ -n "$title_raw" ] || title_raw="ANS-GO 管理面板"
  URLPATH="${URL_PATH:-/$(openssl rand -hex 4)/}"
  title_json="$(ansgo_json_escape "$title_raw")"
  ip_json="$(ansgo_json_escape "$(printf '%s' "${SERVER_IP_IN:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")"
  # 端口优先级：顶部已算好的 RPANEL_PORT（日志与实际一致）> ansgo.env 原值 > 随机兜底
  pport="${RPANEL_PORT:-${PANEL_PORT:-$(_rand_port)}}"
  ssport="${RSS_PORT:-${SS_PORT:-$(_rand_port)}}"
  atport="${RANYTLS_PORT:-${ANYTLS_PORT:-$(_rand_port)}}"
  skport="${RSOCKS_PORT:-${SOCKS_PORT:-$(_rand_port)}}"
  nvport="${RNAIVE_PORT:-${NAIVE_PORT:-$(_rand_port)}}"
  tmp="${out}.tmp.$$"
  if ! cat > "$tmp" <<EOF
{
  "domain": "$(ansgo_json_escape "${DOMAIN}")",
  "panel_port": ${pport},
  "panel_title": "${title_json}",
  "url_path": "$(ansgo_json_escape "${URLPATH}")",
  "admin_user": "$(ansgo_json_escape "${PANEL_USER:-admin}")",
  "admin_pass_hash": "PLACEHOLDER",
  "session_hours": 8,
  "login_lock_threshold": 5,
  "login_lock_minutes": 10,
  "ss_port": ${ssport},
  "ss_method": "2022-blake3-aes-128-gcm",
  "anytls_port": ${atport},
  "socks_port": ${skport},
  "naive_port": ${nvport},
  "disguise_panel": "$(ansgo_json_escape "${DISGUISE_PANEL:-proxy:https://example.com}")",
  "disguise_naive": "$(ansgo_json_escape "${DISGUISE_NAIVE:-proxy:https://example.com}")",
  "svc_ss_enabled": "false",
  "svc_anytls_enabled": "false",
  "svc_socks_enabled": "false",
  "svc_naive_enabled": "false",
  "caddy_enable": "$([ "${NO_CADDY:-0}" = 1 ] && echo false || echo true)",
  "cert_mode": "$(ansgo_json_escape "${CERT_MODE}")",
  "cert_dir": "/etc/ssl/ansgo",
  "cert_fullchain": "$(ansgo_json_escape "${CERT_FULLCHAIN}")",
  "cert_privkey": "$(ansgo_json_escape "${CERT_PRIVKEY}")",
  "dynu_api_key": "$(ansgo_json_escape "${DYNU_API_KEY:-}")",
  "dynu_client_id": "$(ansgo_json_escape "${DYNU_CLIENT_ID:-}")",
  "dynu_secret": "$(ansgo_json_escape "${DYNU_SECRET:-}")",
  "acme_email": "$(ansgo_json_escape "${EMAIL:-}")",
  "db_path": "/etc/ansgo/sessions.db",
  "server_ip": "${ip_json}",
  "landings": [],
  "auto_upgrade": "false",
  "backup_keep": 5
  }
EOF
  then
    rm -f "$tmp" 2>/dev/null
    log "ERROR: panel.json 写入临时文件失败（磁盘/权限）: $tmp"
    return 2
  fi
  if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log "ERROR: panel.json JSON 校验失败（env 变量含非法值），中止"
    return 2
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; log "ERROR: chmod 失败: $tmp"; return 2; }
  if ! mv -f "$tmp" "$out"; then
    rm -f "$tmp" 2>/dev/null
    log "ERROR: panel.json 原子替换失败: $out"
    return 2
  fi
  log "已生成 $out (url_path=${URLPATH})"
}

# ---- 1/3 首次：panel.json + secrets.env ----
if [ ! -f "$CONF" ]; then
  log "首次初始化：生成 panel.json + secrets.env（端口随机：panel=$RPANEL_PORT ss=$RSS_PORT anytls=$RANYTLS_PORT socks=$RSOCKS_PORT naive=$RNAIVE_PORT）"
  # Sentinel 修复：生成失败必须中止容器初始化，不允许带病拉起 systemd
  if ! entrypoint_ensure_panel_json "$CONF"; then
    log "FATAL: panel.json 首次生成失败，容器初始化中止（docker logs ansgo 查看原因）"
    exit 1
  fi
  log "⚠️ 随机端口：panel=$RPANEL_PORT ss=$RSS_PORT anytls=$RANYTLS_PORT socks=$RSOCKS_PORT naive=$RNAIVE_PORT（请记下！）"

  if [ ! -f "$SECRETS" ]; then
    # v1.5.5: 支持宿主通过 ansgo.env 透传 SS_KEY_IN/ANYTLS_PASS_IN 等预指定密钥
    #         （install.sh 已校验格式），未指定的留空 → 容器内随机生成
    cat > "$SECRETS" <<EOF
SS_METHOD=2022-blake3-aes-128-gcm
SS_KEY=${SS_KEY_IN:-$(openssl rand -base64 16)}
ANYTLS_PASS=${ANYTLS_PASS_IN:-$(openssl rand -hex 16)}
ANYTLS_UUID=${ANYTLS_UUID_IN:-$(cat /proc/sys/kernel/random/uuid)}
SOCKS_USER=${SOCKS_USER_IN:-$(openssl rand -hex 6)}
SOCKS_PASS=${SOCKS_PASS_IN:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}
NAIVE_USER=${NAIVE_USER_IN:-$(openssl rand -hex 6)}
NAIVE_PASS=${NAIVE_PASS_IN:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}
EOF
    chmod 600 "$SECRETS"
    log "已生成 $SECRETS"
  fi
fi

# 先保留旧 group2 数据，再补默认字段；新 schema 的落盘交给 Go 面板。
ansgo_migrate "$CONF" "$SECRETS" || { log "FATAL: 配置迁移失败"; exit 1; }
# 持久配置优先：旧 env 不能把面板里切换后的 manual/acme 模式或凭证覆盖回去。
eval "$(python3 - "$CONF" <<'PYCERT'
import json,shlex,sys
c=json.load(open(sys.argv[1]))
values=(('DOMAIN','domain','your-domain.com'),('CERT_MODE','cert_mode','acme'),
        ('CERT_FULLCHAIN','cert_fullchain',''),('CERT_PRIVKEY','cert_privkey',''),
        ('DYNU_API_KEY','dynu_api_key',''),('DYNU_CLIENT_ID','dynu_client_id',''),
        ('DYNU_SECRET','dynu_secret',''),('EMAIL','acme_email',''))
for env,key,default in values:
    print(env+'='+shlex.quote(str(c.get(key) or default)))
PYCERT
)" || exit 1

# ---- 2/3 设置管理员密码（仅当仍是 PLACEHOLDER 且提供了 PANEL_PASS）----
if grep -q '"admin_pass_hash": "PLACEHOLDER"' "$CONF" 2>/dev/null && [ -n "${PANEL_PASS:-}" ]; then
  log "设置管理员密码（来自 PANEL_PASS 环境变量，已写入 bcrypt）"
  /usr/local/bin/ansgo-panel -setpass "${PANEL_PASS}" \
    || log "WARN: setpass 失败，稍后可用 docker exec ansgo ansgo-admin panel-pass 重置"
fi

# ---- 3/3 证书：manual 模式同步宿主证书到 /etc/ssl/ansgo/ 卷；acme 模式无则自签占位 ----
# v1.5.32: Docker 手动证书改为「固定同步目录」模型：
#   宿主计划任务把证书写入 /etc/ansgo-docker/manual-certs/（compose 只读挂载到 /host/manual-certs）
#   -> ansgo-sync-manual-cert 校验并原子替换 /etc/ssl/ansgo/{fullchain,privkey}.pem
#   -> caddy/sing-box/ansgo-panel 始终使用 /etc/ssl/ansgo/ 副本（权限友好，避免宿主目录 600 读不了）
#   面板不再要求容器读取任意宿主路径，也不再动态改 compose 挂载。
#   续期：用户在面板「证书管理」复制系统定时任务/宝塔计划任务脚本到宿主执行即可。
# 兼容：若旧 env 仍带 CERT_FULLCHAIN/CERT_PRIVKEY 且文件可读（旧部署已 bind mount），
#       则把它们当作初始同步源，cp 进 /host/manual-certs 的对应挂载宿主目录（若可写），
#       或直接 cp 到 /etc/ssl/ansgo/；同时记录到 cert_host_fullchain/cert_host_privkey。
HOST_SYNC_DIR_HOST="/etc/ansgo-docker/manual-certs"
HOST_SYNC_FULL="/host/manual-certs/fullchain.pem"
HOST_SYNC_KEY="/host/manual-certs/privkey.pem"
mkdir -p "$CERTDIR"

# 旧部署迁移：若 env 提供 CERT_FULLCHAIN/CERT_PRIVKEY 且 /host/manual-certs 为空，
# 尝试把宿主源路径记录到 cert_host_*（供面板显示并生成同步脚本）。
migrate_legacy_manual_meta(){
  [ -z "$CERT_FULLCHAIN" ] && [ -z "$CERT_PRIVKEY" ] && return
  [ -f "$CONF" ] || return
  command -v python3 >/dev/null 2>&1 || return
  python3 - "$CONF" "$CERT_FULLCHAIN" "$CERT_PRIVKEY" <<'PY' 2>/dev/null || true
import json, sys
p, full, key = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(p))
chg = False
if full and not full.startswith('/etc/ssl/ansgo/') and not c.get('cert_host_fullchain'):
    c['cert_host_fullchain'] = full; chg = True
if key and not key.startswith('/etc/ssl/ansgo/') and not c.get('cert_host_privkey'):
    c['cert_host_privkey'] = key; chg = True
if chg:
    import os,tempfile
    fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p),prefix='.ansgo-cert-')
    with os.fdopen(fd,'w') as f: json.dump(c,f,indent=2,ensure_ascii=False)
    os.chmod(tmp,0o600); os.replace(tmp,p)
    print('[entrypoint] 已从 env 迁移 manual 证书宿主源路径到 cert_host_*')
PY
}

cert_is_valid(){
  [ -s "$1" ] && [ -s "$2" ] &&
    openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1 &&
    [ "$(openssl x509 -in "$1" -pubkey -noout | openssl sha256)" = \
      "$(openssl pkey -in "$2" -pubout | openssl sha256)" ]
}

if [ "$CERT_MODE" = "manual" ]; then
  log "证书来源：手动模式（Docker 同步目录 /host/manual-certs -> $CERTDIR/）"
  # 优先用固定同步目录；若为空但旧 env 源可读，回退用旧源做一次性同步
  if [ -s "$HOST_SYNC_FULL" ] && [ -s "$HOST_SYNC_KEY" ]; then
    log "检测到 /host/manual-certs 证书，调用 ansgo-sync-manual-cert 同步"
    sync_rc=0
    /usr/local/bin/ansgo-sync-manual-cert || sync_rc=$?
    case "$sync_rc" in 0|10) ;; *) log "FATAL: manual 证书同步失败"; exit 1;; esac
  elif [ -f "$CERT_FULLCHAIN" ] && [ -f "$CERT_PRIVKEY" ]; then
    log "使用持久配置中的已有证书副本"
  else
    log "FATAL: 未发现 manual 证书，请先在宿主写入固定同步目录"
    exit 1
  fi
  openssl x509 -in "$CERTDIR/fullchain.pem" -noout -checkend 0 >/dev/null || exit 1
  cmod=$(openssl x509 -in "$CERTDIR/fullchain.pem" -pubkey -noout | openssl sha256) || exit 1
  kmod=$(openssl pkey -in "$CERTDIR/privkey.pem" -pubout | openssl sha256) || exit 1
  [ "$cmod" = "$kmod" ] || { log "FATAL: 证书与私钥不匹配"; exit 1; }
  printf 'SUCCESS manual-mode\n' > /etc/ansgo-cert.status
  # 无论哪种来源，运行路径始终指向卷内副本
  if [ -f "$CONF" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$CONF" "$CERTDIR" <<'PY' 2>/dev/null || true
import json, sys
p, certdir = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c['cert_mode'] = 'manual'
c['cert_fullchain'] = certdir + '/fullchain.pem'
c['cert_privkey'] = certdir + '/privkey.pem'
import os,tempfile
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p),prefix='.ansgo-cert-')
with os.fdopen(fd,'w') as f: json.dump(c,f,indent=2,ensure_ascii=False)
os.chmod(tmp,0o600); os.replace(tmp,p)
print('[entrypoint] panel.json 已设为 manual 模式（运行路径指向卷内 ' + certdir + '/）')
PY
  fi
  migrate_legacy_manual_meta
else
  if ! cert_is_valid "$CERTDIR/fullchain.pem" "$CERTDIR/privkey.pem"; then
    log "生成自签占位证书"
    openssl ecparam -genkey -name prime256v1 -out "$CERTDIR/privkey.pem" 2>/dev/null \
      || openssl genrsa -out "$CERTDIR/privkey.pem" 2048
    openssl req -new -x509 -days 365 -key "$CERTDIR/privkey.pem" \
      -out "$CERTDIR/fullchain.pem" -subj "/CN=${DOMAIN}" 2>/dev/null || true
  fi
fi

# 生成 sing-box / caddy 配置（幂等；失败时写兜底 Caddyfile，避免 caddy 起不来）
ansgo_log_trim /var/log/ansgo/genconf.log
if /usr/local/bin/ansgo-genconf all >>/var/log/ansgo/genconf.log 2>&1; then
  log "已生成 sing-box + caddy 配置"
else
  log "FATAL: ansgo-genconf 失败（见 /var/log/ansgo/genconf.log）"
  exit 1
fi

# v1.5.10: --no-caddy 模式 caddy 启停逻辑（修复 v1.5.10 的 bug）
#   v1.5.10 bug：容器重启时即使 naive 已装（svc_naive_enabled=true）也 stop caddy → naive 失效
#   正确逻辑：caddy_enable=false 且 naive 未装时才不启 caddy；
#             naive 已装时 caddy 必须启动（naive 依赖 caddy 的 forwardproxy）
NO_CADDY_MODE=0
if grep -q '"caddy_enable": "false"' "$CONF" 2>/dev/null; then
  NO_CADDY_MODE=1
fi
if [ "$NO_CADDY_MODE" = 1 ]; then
  # 检查 naive 是否已启用（从 panel.json 读 svc_naive_enabled）
  NAIVE_ON=$(grep -o '"svc_naive_enabled": *"[^"]*"' "$CONF" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"')
  if [ "$NAIVE_ON" = "true" ]; then
    log "--no-caddy 模式但 naive 已启用：启动 caddy（仅听 naive 端口，不碰 80/443）"
    systemctl enable caddy.service 2>/dev/null || true
    systemctl reset-failed caddy.service 2>/dev/null || true
    systemctl restart caddy.service 2>/dev/null || true
  else
    log "--no-caddy 模式且 naive 未启用：不启动 caddy（80/443 由 nginx 等接管）"
    systemctl disable caddy.service 2>/dev/null || true
    systemctl stop caddy.service 2>/dev/null || true
  fi
else
  # 非 --no-caddy 模式：caddy 始终启用（:443 伪装站是域名基础设施）
  # v1.5.17: 容器重建后 systemd 是全新状态，caddy 之前可能被 disable，需显式 enable
  log "默认模式：启用 caddy（:443 伪装站）"
  systemctl enable caddy.service 2>/dev/null || true
fi

# v1.5.17: sing-box 自动启停逻辑（修复容器重建后代理服务不自动恢复）
#   容器重建（docker compose up -d）后 systemd 是全新状态，sing-box.service 默认 disabled，
#   即使 panel.json 里 svc_*_enabled=true 也不会被拉起 → 用户拉新镜像后代理全断。
#   genconf 已据 svc 开关生成对应 inbound，此处按"是否有启用的 sing-box 服务"决定启停。
#   v1.5.26: 判断条件与 Go 端 needSB 一致：
#     ss/anytls/socks 任一启用 或 landings 数组里有任一 enabled 项 → 需要 sing-box
SB_NEED=0
for K in svc_ss_enabled svc_anytls_enabled svc_socks_enabled; do
  V=$(grep -o "\"$K\": *\"[^\"]*\"" "$CONF" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"')
  [ "$V" = "true" ] && SB_NEED=1
done
# v1.5.26: landings 数组里是否有 enabled=true（用 python 精确解析，避免粗 grep 误判）
LAND_EN=$(python3 -c "
import json
try:
    d=json.load(open('$CONF'))
    print('1' if any(str(L.get('enabled','false')).lower() in ('true','1') for L in d.get('landings',[])) else '0')
except Exception:
    print('0')
" 2>/dev/null || echo 0)
[ "$LAND_EN" = "1" ] && SB_NEED=1
if [ "$SB_NEED" = 1 ]; then
  log "检测到启用的 sing-box 服务：enable + restart sing-box"
  systemctl enable sing-box.service 2>/dev/null || true
  systemctl reset-failed sing-box.service 2>/dev/null || true
  systemctl restart sing-box.service 2>/dev/null || true
else
  log "无启用的 sing-box 服务：sing-box 保持 disabled（面板内按需安装时再起）"
fi

# 首次 acme 安装必须拿到有效证书后才算初始化成功；已有有效证书则跳过签发。
valid_pair(){ cert_is_valid "$CERTDIR/fullchain.pem" "$CERTDIR/privkey.pem"; }
if [ "$CERT_MODE" != "manual" ]; then
  existing_le=0
  if valid_pair; then
    cert_issuer=$(openssl x509 -in "$CERTDIR/fullchain.pem" -noout -issuer 2>/dev/null || true)
    case "$cert_issuer" in *"Let's Encrypt"*|*"let's encrypt"*) existing_le=1;; esac
  fi
  if [ "$existing_le" = 1 ]; then
    printf 'SUCCESS existing-cert\n' > /etc/ansgo-cert.status
  elif [ -n "${DYNU_API_KEY:-}" ] || { [ -n "${DYNU_CLIENT_ID:-}" ] && [ -n "${DYNU_SECRET:-}" ]; }; then
    ansgo_log_trim /var/log/ansgo/cert-issue.log
    log "首次启动签发 Let's Encrypt 证书（最多 300 秒），日志 /var/log/ansgo/cert-issue.log"
    DOMAIN="$DOMAIN" EMAIL="$EMAIL" \
      DYNU_API_KEY="${DYNU_API_KEY:-}" DYNU_CLIENT_ID="${DYNU_CLIENT_ID:-}" DYNU_SECRET="${DYNU_SECRET:-}" \
      bash /usr/local/bin/ansgo-cert-issue.sh >/dev/null 2>&1 || { log "FATAL: 首次证书签发失败"; exit 1; }
    cert_issuer=$(openssl x509 -in "$CERTDIR/fullchain.pem" -noout -issuer 2>/dev/null || true)
    case "$cert_issuer" in *"Let's Encrypt"*|*"let's encrypt"*) issued_le=1;; *) issued_le=0;; esac
    if ! valid_pair || [ "$issued_le" != 1 ]; then
      log "FATAL: 签发后未取得有效 Let's Encrypt 证书"; exit 1
    fi
  else
    log "FATAL: acme 模式缺少 Dynu 凭证，无法取得有效证书"
    exit 1
  fi
fi
# cron 在镜像中显式 enable，保证 acme.sh 续期计划会被调度。
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/cron.service /etc/systemd/system/multi-user.target.wants/cron.service

# 容器内 PATH（含 acme.sh，供面板 exec ansgo-admin/genconf 使用）
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.acme.sh

log "启动 systemd（PID 1）—— 拉起 caddy(:443 伪装) + ansgo-panel"
exec /sbin/init
