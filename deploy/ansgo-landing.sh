#!/bin/bash
# =============================================================================
# ansgo-landing.sh —— 落地服务器 Shadowsocks 一键部署（供 install.sh --landing 调用）
#
# 用途：在"落地机"上部署一个独立的 ss-server，供中转机的第二组服务（anytls-2/naive-2）
#       通过 ss outbound 接入。本脚本独立于中转机部署。
#
# 用法：
#   bash install.sh --landing                # 交互式
#   bash install.sh --landing --port 8388 --non-interactive
# =============================================================================
set -Eeuo pipefail
umask 077
WORK=$(mktemp -d)
STAGE=""
trap 'rm -rf "$WORK" "${STAGE:-}"; command -v apt-get >/dev/null && apt-get clean || true' EXIT
if [ -t 1 ]; then C_G='\033[32m';C_Y='\033[33m';C_R='\033[31m';C_0='\033[0m'; else C_G='';C_Y='';C_R='';C_0=''; fi
log(){ printf "${C_G}[*]${C_0} %s\n" "$*"; }
warn(){ printf "${C_Y}[!]${C_0} %s\n" "$*" >&2; }
err(){ printf "${C_R}[X]${C_0} %s\n" "$*" >&2; }

[ "$(id -u)" = 0 ] || { err "需 root"; exit 1; }
LANDING_PORT="${LANDING_PORT:-8388}"
SS_METHOD="2022-blake3-aes-128-gcm"

# 解析参数
while [ $# -gt 0 ]; do
  case "$1" in
    --port) LANDING_PORT="$2"; shift 2;;
    --non-interactive) NONINT=1; shift;;
    *) shift;;
  esac
done

log "=== 落地服务器 Shadowsocks 部署 ==="

[[ "$LANDING_PORT" =~ ^[0-9]+$ ]] && [ "$LANDING_PORT" -ge 1 ] && [ "$LANDING_PORT" -le 65535 ] || { err "端口须为 1-65535"; exit 1; }

# 装依赖
command -v curl >/dev/null || { apt-get update && apt-get install -y --no-install-recommends curl ca-certificates openssl python3; }

# 装 sing-box（若未装）
if ! command -v sing-box >/dev/null; then
  REPO="6667084/ANS-GO"; VER="v1.6.0"
  AARCH=$(uname -m); AARCH="${AARCH/x86_64/amd64}"; AARCH="${AARCH/aarch64/arm64}"
  log "下载 sing-box (from release, arch=$AARCH)"
  curl -fsSL "https://github.com/${REPO}/releases/download/${VER}/sing-box-linux-${AARCH}.tar.gz" -o "$WORK/sb.tgz" || { err "下载失败"; exit 1; }
  tar xzf "$WORK/sb.tgz" -C "$WORK"
  STAGE=$(mktemp -d /usr/local/bin/.ansgo-landing.XXXXXX)
  install -m 755 "$WORK"/sing-box-*/sing-box "$STAGE/sing-box"
  "$STAGE/sing-box" version >/dev/null
  mv "$STAGE/sing-box" /usr/local/bin/sing-box
fi

# 生成密钥
SS_KEY=$(openssl rand -base64 16)

# 生成配置（仅 ss-server，direct 出口）
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks", "tag": "ss-in",
      "listen": "::", "listen_port": ${LANDING_PORT},
      "method": "${SS_METHOD}", "password": "${SS_KEY}"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

# systemd unit
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box (landing ss-server)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF

if [ ! -f /usr/local/bin/ansgo-limits ]; then
  curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/v1.6.0/deploy/ansgo-limits -o "$WORK/ansgo-limits"
  install -m 755 "$WORK/ansgo-limits" /usr/local/bin/ansgo-limits
fi
/usr/local/bin/ansgo-limits
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl reset-failed sing-box 2>/dev/null || true
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box

PUBIP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

cat <<EOF

═══════════════════════════════════════════════════
  ✅ 落地服务器 Shadowsocks 部署完成
═══════════════════════════════════════════════════
  监听端口 : ${LANDING_PORT}
  加密方式 : ${SS_METHOD}
  密钥     : ${SS_KEY}
  服务器   : ${PUBIP}
═══════════════════════════════════════════════════
  请在中转机的「出口落地」页填写以上信息：
    host=${PUBIP}  port=${LANDING_PORT}  password=${SS_KEY}
═══════════════════════════════════════════════════
EOF
log "完成。sing-box 状态: $(systemctl is-active sing-box)"
