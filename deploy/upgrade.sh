#!/usr/bin/env bash
# ANS-GO v1.6.2：同版本资产先校验，再切换；失败恢复整套备份。
_ansi_self="${BASH_SOURCE[0]:-}"
case "$_ansi_self" in
  ''|/dev/fd/*|/proc/self/fd/*)
    _ansi_dir=$(mktemp -d) || exit 1
    if [ -n "$_ansi_self" ] && [ -e "$_ansi_self" ]; then
      cat "$_ansi_self" > "$_ansi_dir/upgrade.sh"
    else cat > "$_ansi_dir/upgrade.sh"; fi
    export _ANSGO_UPGRADE_BOOTSTRAP_DIR="$_ansi_dir"
    exec bash "$_ansi_dir/upgrade.sh" "$@";;
esac
set -Eeuo pipefail
umask 077
REPO=6667084/ANS-GO
VER="v1.6.2"
MODE='' YES=0 AUTO=0 STAGE='' BACKUP='' MUTATED=0 DONE=0 DOCKER_PAUSED=0 METAL_PAUSED=0
DOCKER_DIR=/etc/ansgo-docker
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"
RESULT=/var/lib/ansgo/upgrade.result
LOG=/var/log/ansgo/upgrade.log
usage(){ cat <<'EOF'
用法: ansgo-upgrade [--metal|--docker] [--ver vX.Y.Z] [--yes] [--auto]
  --auto  查询 GitHub 最新稳定 release，无更新时退出 0
  --ver   从对应 tag 拉取脚本与 release 资产
  --metal 更新全部受管组件、按活跃服务重启并验证；失败自动恢复整套备份
  --docker 拉取明确版本镜像、迁移旧落地配置、备份实际卷并重建验证
日志: /var/log/ansgo/upgrade.log  结果: /var/lib/ansgo/upgrade.result
下载源环境变量（每次执行读取，不写入已安装脚本）：
  ANSGO_RAW_BASE      deploy 目录 URL
  ANSGO_REL_BASE      release 下载根，按 <base>/<ver>/<asset> 取文件
  ANSGO_RELEASE_API   release 元数据根，按 <api>/<ver> 取 JSON；--auto 另需 <api>/latest
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --metal|--docker)
      requested="${1#--}"
      [ -z "$MODE" ] || [ "$MODE" = "$requested" ] || { echo '部署模式互斥' >&2; exit 1; }
      MODE="$requested"; shift;;
    --ver) VER="${2:?--ver 缺少版本}"; shift 2;;
    --yes|-y) YES=1; shift;;
    --auto) AUTO=1; YES=1; shift;;
    --help|-h) usage; exit 0;;
    *) usage >&2; exit 1;;
  esac
done
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '版本须为 vX.Y.Z' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo '升级需要 root' >&2; exit 1; }
case "$(uname -m)" in x86_64) AARCH=amd64;; aarch64|arm64) AARCH=arm64;; *) echo '架构不支持' >&2; exit 1;; esac
command -v python3 >/dev/null
# Compose 兼容性必须在日志、锁文件、备份权限修复等宿主写入之前检查。
docker_compose_v2_hint(){
  echo '需要 Docker Compose v2（docker compose 子命令）' >&2
  echo 'Debian/Ubuntu: apt-get install -y docker-compose-plugin（软件源无此包时先配置 Docker 官方源）' >&2
  echo '也可安装官方静态插件：mkdir -p /usr/local/lib/docker/cli-plugins' >&2
  echo "curl -fL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose" >&2
}
docker_compose_preflight(){
  if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null; then
    COMPOSE=(docker-compose)
    if ! "${COMPOSE[@]}" -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
      docker_compose_v2_hint; return 1
    fi
    # 后续只在内存解析 JSON；旧 v1 即使接受原文件，也不能支持此升级流程。
    "${COMPOSE[@]}" config --help 2>/dev/null | grep -F -- '--format' >/dev/null || {
      docker_compose_v2_hint; return 1;
    }
  else docker_compose_v2_hint; return 1; fi
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1 || {
    echo 'Docker Compose 配置预检失败，请检查 compose 与环境文件' >&2; return 1;
  }
}
if [ -z "$MODE" ]; then
  if [ -f "$COMPOSE_FILE" ] && [ -f /etc/ansgo/panel.json ]; then
    echo '同时检测到裸金属和 Docker，请指定 --metal/--docker' >&2; exit 1
  elif [ -f "$COMPOSE_FILE" ]; then MODE=docker
  elif [ -f /etc/ansgo/panel.json ]; then MODE=metal
  else echo '未检测到已安装的 ANS-GO' >&2; exit 1; fi
fi
COMPOSE=()
if [ "$MODE" = docker ]; then
  [ "$AUTO" = 0 ] || { echo 'Docker 自动升级请在宿主安排，容器内 timer 不支持' >&2; exit 1; }
  docker_compose_preflight || exit 1
fi
mkdir -p /var/log/ansgo /var/lib/ansgo /usr/local/bin
chmod 700 /var/log/ansgo /var/lib/ansgo
# 跨 CLI/timer/API 防止并行升级。锁 fd 不能传给重启后的服务。
exec 9>/var/lib/ansgo/upgrade.lock
flock -n 9 || { echo '已有升级正在执行' >&2; exit 1; }
# 先裁剪再打开 append fd；后续阶段及每次下载前也执行裁剪。
trim_log(){
  python3 - "$LOG" <<'PY'
import os, sys
p=sys.argv[1]
if os.path.exists(p) and os.path.getsize(p)>1048576:
    with open(p,'r+b') as f:
        f.seek(-262144,2); data=f.read(); f.seek(0); f.write(data); f.truncate()
PY
}
trim_log
if [ "$AUTO" = 1 ]; then
  exec >> "$LOG" 2>&1
  renice -n 10 -p $$ >/dev/null
  command -v ionice >/dev/null && ionice -c3 -p $$ || true
else
  exec > >(tee -a "$LOG") 2>&1
fi
say(){ trim_log; printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
TASK_STARTED=$(date +%s)
TASK_ID="${ANSGO_UPGRADE_TASK_ID:-${INVOCATION_ID:-cli-$TASK_STARTED-$$}}"
write_result(){
  python3 - "$RESULT" "$1" "$TASK_ID" "$TASK_STARTED" <<'PYRESULT'
import json, os, sys, time
p, result, task_id, started = sys.argv[1:]
with open(p+'.tmp', 'w') as f:
    json.dump(dict(result=result, task_id=task_id, started_at=int(started), finished_at=int(time.time())), f)
os.chmod(p+'.tmp', 0o600)
os.replace(p+'.tmp', p)
PYRESULT
}
finish(){
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ "$rc" -ne 0 ] && [ "$MUTATED" = 1 ]; then
    say '升级失败，自动恢复备份'
    if [ "$MODE" = metal ]; then
      systemctl stop ansgo-panel caddy sing-box
      ansgo_restore "$BACKUP"
      restore_rc=$?
      systemctl daemon-reload
      for svc in caddy sing-box ansgo-panel; do
        if printf "%s\n" "${OLD_ENABLED[@]:-}" | grep -x "$svc" >/dev/null; then systemctl enable "$svc" || restore_rc=1; else systemctl disable "$svc" || restore_rc=1; fi
        if printf "%s\n" "${OLD_ACTIVE[@]:-}" | grep -x "$svc" >/dev/null; then
          systemctl reset-failed "$svc" 2>/dev/null || true
          systemctl restart "$svc" && systemctl is-active --quiet "$svc" || restore_rc=1
        fi
      done
      [ "$restore_rc" = 0 ] || say "自动回滚未完全成功，请使用备份恢复: $BACKUP"
    else
      docker_rollback || say "Docker 回滚失败，请用备份恢复: $BACKUP"
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$DOCKER_PAUSED" = 1 ] && [ "$MUTATED" = 0 ]; then
    docker exec "$CID" systemctl reset-failed ansgo-panel 2>/dev/null || true
    docker exec "$CID" systemctl start ansgo-panel cron || true
  fi
  if [ "$rc" -ne 0 ] && [ "$METAL_PAUSED" = 1 ] && [ "$MUTATED" = 0 ]; then
    if printf '%s\n' "${OLD_ACTIVE[@]:-}" | grep -x ansgo-panel >/dev/null; then
      systemctl reset-failed ansgo-panel 2>/dev/null || true
      systemctl start ansgo-panel || true
    fi
  fi
  if [ "$rc" -eq 0 ] && [ "$DONE" = 1 ]; then
    trim_log
    write_result success
    say '升级完成；浏览器请硬刷新（Ctrl+Shift+R / Cmd+Shift+R）'
  elif [ "$rc" -ne 0 ]; then
    write_result failed
    say "升级失败（退出码 $rc），日志: $LOG；备份: ${BACKUP:-尚未切换组件}"
  fi
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "${_ANSGO_UPGRADE_BOOTSTRAP_DIR:-}" ] || rm -rf "$_ANSGO_UPGRADE_BOOTSTRAP_DIR"
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
current_version(){
  if [ "$MODE" = docker ]; then
    docker exec "$CID" cat /usr/local/share/ansgo-version
  else
    local port path current invocation conf="${1:-/etc/ansgo/panel.json}"
    read -r port path < <(python3 - "$conf" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]));print(c["panel_port"],c["url_path"])
PY
)
    current=$(curl --noproxy '*' -kfsS --max-time 5 "https://127.0.0.1:$port${path}api/auth" |
      python3 -c 'import json,re,sys;v=json.load(sys.stdin)["version"];assert re.fullmatch(r"v?\d+\.\d+\.\d+",v);print("v"+v.lstrip("v"))') || current=''
    if [ -n "$current" ]; then printf '%s\n' "$current"; return; fi
    # 旧版 Go 的 trimpath 构建可能不保留 -X 的 buildinfo；只读本次 invocation 的启动行。
    invocation=$(systemctl show ansgo-panel -p InvocationID --value)
    if [ -n "$invocation" ]; then
      current=$(journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat |
        sed -n 's/.*ansgo-panel \(v[0-9][0-9.]*\) .*/\1/p' | tail -1)
    fi
    if [[ "$current" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s\n' "$current"
    else echo '无法识别当前运行版本，自动升级停止' >&2; return 1; fi
  fi
}
if [ "$AUTO" = 1 ]; then
  LATEST_API="https://api.github.com/repos/$REPO/releases/latest"
  [ -z "${ANSGO_RELEASE_API:-}" ] || LATEST_API="${ANSGO_RELEASE_API%/}/latest"
  VER=$(curl --noproxy '*' --connect-timeout 5 --max-time 10 -fsSL \
    "$LATEST_API" |
    python3 -c 'import json,re,sys; d=json.load(sys.stdin); v=d["tag_name"]; assert not d.get("prerelease") and not d.get("draft") and re.fullmatch(r"v\d+\.\d+\.\d+",v); print(v)')
  CURRENT=$(current_version)
  if ! python3 - "$CURRENT" "$VER" <<'PY'
import sys
v=lambda x:tuple(map(int,x.lstrip('v').split('.')))
sys.exit(0 if v(sys.argv[2])>v(sys.argv[1]) else 1)
PY
  then
    say "当前 $CURRENT，最新 $VER，无需升级"
    write_result success
    exit 0
  fi
fi
RAW="${ANSGO_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$VER/deploy}"
RAW="${RAW%/}"
REL="${ANSGO_REL_BASE:-https://github.com/$REPO/releases/download}"
REL="${REL%/}/$VER"
RELEASE_API="${ANSGO_RELEASE_API:-https://api.github.com/repos/$REPO/releases/tags}"
RELEASE_API="${RELEASE_API%/}"
if [ "$YES" = 0 ]; then
  printf '将升级到 %s（%s），升级前自动备份。继续？[y/N] ' "$VER" "$MODE"
  read -r answer </dev/tty
  case "$answer" in y|Y) ;; *) say '已取消'; exit 0;; esac
fi
rm -f "$RESULT"
STAGE=$(mktemp -d /usr/local/bin/.ansgo-upgrade.XXXXXX)
dl(){ trim_log; curl --connect-timeout 10 --max-time 180 --retry 2 -fsSL "$1" -o "$2" && test -s "$2"; }
# 从指定 tag 加载公共实现；下载失败不改任何已安装组件。
dl "$RAW/ansgo-limits" "$STAGE/ansgo-limits"
bash -n "$STAGE/ansgo-limits"
source "$STAGE/ansgo-limits"
ansgo_secure_backups
ansgo_logs_init
verify_elf(){
  python3 - "$1" "$AARCH" "${2:-}" <<'PY'
import re,struct,sys
p,arch,version=sys.argv[1:]
with open(p,'rb') as f:
    h=f.read(20)
    assert len(h)==20 and h[:5]==b'\x7fELF\x02' and h[5]==1, '不是 ELF64 小端二进制'
    assert struct.unpack('<H',h[18:20])[0]=={'amd64':62,'arm64':183}[arch], 'ELF 架构错误'
    if version:
        f.seek(0); data=f.read()
        versions=re.findall(rb'main\.version=(\d+\.\d+\.\d+)',data)
        expected=version.lstrip('v').encode()
        # trimpath 构建会省略 ldflags；-X 的值仍以 NUL 结尾存放，避免匹配前端历史注释。
        assert expected in versions or expected+b'\0' in data, 'panel 内嵌版本不匹配'
PY
}
active_services(){
  python3 - /etc/ansgo/panel.json <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); on=lambda k,default='false':str(c.get(k,default)).lower()=='true'
if on('caddy_enable','true') or on('svc_naive_enabled'): print('caddy')
if any(on('svc_'+x+'_enabled') for x in ('ss','anytls','socks')) or any(str(x.get('enabled','false')).lower()=='true' for x in c.get('landings',[])): print('sing-box')
print('ansgo-panel')
PY
}
wait_active(){
  local svc="$1" i
  for i in {1..15}; do
    systemctl is-active --quiet "$svc" && return 0
    sleep 1
  done
  say "$svc 未进入 active"; return 1
}
verify_panel(){
  local invocation logged i
  invocation=$(systemctl show ansgo-panel -p InvocationID --value)
  [ -n "$invocation" ] || return 1
  for i in {1..10}; do
    logged=$(journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat -n 30 |
      sed -n 's/.*ansgo-panel \(v[0-9][0-9.]*\) .*/\1/p' | tail -1)
    [ "$logged" != "$VER" ] || break
    sleep 1
  done
  [ "$logged" = "$VER" ] || { say "本次启动版本不匹配: $logged / $VER"; return 1; }
  local port path i
  read -r port path < <(python3 -c 'import json;c=json.load(open("/etc/ansgo/panel.json")); print(c["panel_port"],c["url_path"])')
  for i in {1..10}; do
    curl --noproxy '*' -kfsS --max-time 3 "https://127.0.0.1:$port${path}api/auth" >/dev/null && return 0
    sleep 1
  done
  return 1
}
upgrade_metal(){
  local f asset checksums=0
  local scripts=(ansgo-genconf ansgo-admin ansgo-cert-reload ansgo-cert-issue.sh ansgo-sync-manual-cert ansgo-landing.sh dns_dynukey.sh)
  local units=(ansgo-panel.service systemd/caddy.service systemd/sing-box.service systemd/ansgo-autoupgrade.service systemd/ansgo-autoupgrade.timer)
  local -a needed=()
  say "暂存 $VER 全部组件"
  for f in "${scripts[@]}"; do
    dl "$RAW/$f" "$STAGE/$f"
    bash -n "$STAGE/$f"
  done
  dl "$RAW/upgrade.sh" "$STAGE/ansgo-upgrade"
  bash -n "$STAGE/ansgo-upgrade"
  for f in "${units[@]}"; do dl "$RAW/$f" "$STAGE/${f##*/}"; done
  # 发布清单存在时必须校验；API 中有清单但下载失败不能降级跳过。
  dl "$RELEASE_API/$VER" "$STAGE/release.json"
  checksum_name=$(python3 - "$STAGE/release.json" <<'PY'
import json,sys
names={a['name'] for a in json.load(open(sys.argv[1]))['assets']}
print(next((n for n in ('SHA256SUMS','sha256sums.txt','checksums.txt') if n in names),''))
PY
)
  if [ -n "$checksum_name" ]; then dl "$REL/$checksum_name" "$STAGE/SHA256SUMS"; checksums=1; fi
  for asset in "ansgo-panel-linux-$AARCH" "caddy-naive-linux-$AARCH" "sing-box-linux-$AARCH.tar.gz"; do
    dl "$REL/$asset" "$STAGE/$asset"
    if [ "$checksums" = 1 ]; then
      python3 - "$STAGE/SHA256SUMS" "$STAGE/$asset" <<'PY'
import hashlib,os,sys
manifest,path=sys.argv[1:]; expected=None
for line in open(manifest):
    parts=line.split()
    name=parts[1].lstrip('*') if len(parts)==2 else ''
    if name.startswith('./'): name=name[2:]
    if len(parts)==2 and name==os.path.basename(path): expected=parts[0]
h=hashlib.sha256()
with open(path,'rb') as f:
    for chunk in iter(lambda:f.read(65536),b''): h.update(chunk)
assert expected and h.hexdigest()==expected.lower(), 'SHA256 校验失败'
PY
    fi
  done
  mv "$STAGE/ansgo-panel-linux-$AARCH" "$STAGE/ansgo-panel"
  mv "$STAGE/caddy-naive-linux-$AARCH" "$STAGE/caddy"
  mkdir "$STAGE/sb"
  tar xzf "$STAGE/sing-box-linux-$AARCH.tar.gz" -C "$STAGE/sb" --no-same-owner
  mapfile -t sb_bins < <(find "$STAGE/sb" -type f -name sing-box)
  [ "${#sb_bins[@]}" = 1 ]
  mv "${sb_bins[0]}" "$STAGE/sing-box"
  for f in ansgo-panel sing-box caddy; do verify_elf "$STAGE/$f" "$([ "$f" != ansgo-panel ] || printf '%s' "$VER")"; chmod 755 "$STAGE/$f"; done
  "$STAGE/caddy" list-modules | grep -F 'http.handlers.forward_proxy' >/dev/null
  "$STAGE/sing-box" version
  # 全部下载校验完成后才备份和切换。记录运行状态供失败恢复。
  OLD_ACTIVE=()
  for f in caddy sing-box ansgo-panel; do
    if systemctl is-active --quiet "$f"; then OLD_ACTIVE+=("$f"); fi
  done
  OLD_ENABLED=()
  for f in caddy sing-box ansgo-panel; do
    if systemctl is-enabled --quiet "$f"; then OLD_ENABLED+=("$f"); fi
  done
  local paths=(/etc/ansgo /etc/ssl/ansgo /root/.acme.sh /etc/sing-box /etc/caddy
    /etc/ansgo-deploy /etc/systemd/journald.conf.d/60-ansgo.conf
    /etc/sysctl.d/99-ansgo-tune.conf)
  for f in ansgo-panel caddy sing-box ansgo-limits ansgo-upgrade "${scripts[@]}"; do paths+=("/usr/local/bin/$f"); done
  for f in "${units[@]}"; do paths+=("/etc/systemd/system/${f##*/}"); done
  for f in caddy sing-box ansgo-panel; do paths+=("/etc/systemd/system/$f.service.d/10-ansgo-limits.conf"); done
  METAL_PAUSED=1
  systemctl stop ansgo-panel
  BACKUP=$(ansgo_backup upgrade "${paths[@]}")
  say "备份: $BACKUP"
  MUTATED=1
  for f in ansgo-panel caddy sing-box ansgo-limits ansgo-upgrade "${scripts[@]}"; do
    # STAGE 在 /usr/local/bin 同一文件系统，rename 不产生半个正式文件。
    chmod 755 "$STAGE/$f"
    mv -f "$STAGE/$f" "/usr/local/bin/$f"
  done
  mkdir -p /etc/ansgo-deploy /etc/systemd/system
  for f in "${scripts[@]}"; do install -m 755 "/usr/local/bin/$f" "/etc/ansgo-deploy/$f"; done
  for f in "${units[@]}"; do install -m 644 "$STAGE/${f##*/}" "/etc/systemd/system/${f##*/}"; done
  ansgo_migrate /etc/ansgo/panel.json /etc/ansgo/secrets.env
  ansgo_limits
  ansgo_tune
  systemctl daemon-reload
  ansgo_log_trim /var/log/ansgo/genconf.log
  ansgo-genconf all >> /var/log/ansgo/genconf.log 2>&1
  mapfile -t needed < <(active_services)
  [ "${#needed[@]}" -gt 0 ]
  for f in caddy sing-box; do
    if ! printf '%s\n' "${needed[@]}" | grep -x "$f" >/dev/null; then
      systemctl stop "$f"
      systemctl disable "$f"
    fi
  done
  for f in "${needed[@]}"; do
    # 三个二进制本次均刷新；关闭的载体不启动。
    systemctl reset-failed "$f" 2>/dev/null || true
    systemctl restart "$f"
    wait_active "$f"
  done
  verify_panel
  for f in "${needed[@]}"; do systemctl enable "$f"; done
  MUTATED=0
  METAL_PAUSED=0
  ansgo-admin prune --yes || say '服务升级已完成；备份清理失败，请稍后执行 ansgo-admin prune --yes'
}
# Docker 只操作 inspect 查到的真实挂载；不创建猜测名称的空卷。
# 日常备份卷原位保留，不重复打包历史归档，避免低磁盘主机双份占用。
docker_backup(){
  local dest type name source helper_image
  mkdir -p "$STAGE/docker/files"
  docker inspect "$CID" > "$STAGE/docker/inspect.json"
  cp -p "${original_compose:-$COMPOSE_FILE}" "$STAGE/docker/compose.yml"
  helper_image=$(docker inspect -f '{{.Image}}' "$CID")
  OLD_IMAGE="$helper_image"
  while IFS=$'\t' read -r dest type name source; do
    mkdir -p "$STAGE/docker/files$dest"
    local mount
    if [ "$type" = volume ]; then mount="type=volume,src=$name,dst=/source,readonly"
    elif [ "$type" = bind ]; then mount="type=bind,src=$source,dst=/source,readonly"
    else say "不支持的持久化挂载: $type $dest"; return 1; fi
    docker run --rm --network none --entrypoint /bin/tar --mount "$mount" \
      "$helper_image" -C /source -cf - . | tar xf - -C "$STAGE/docker/files$dest"
  done < <(python3 - "$STAGE/docker/inspect.json" <<'PY'
import json,sys
for m in json.load(open(sys.argv[1]))[0]['Mounts']:
    if m['Destination'] in ('/etc/ansgo','/etc/ssl/ansgo','/etc/caddy','/etc/sing-box','/root/.acme.sh'):
        print('\t'.join([m['Destination'],m['Type'],m.get('Name','-'),m['Source']]))
PY
)
  test -s "$STAGE/docker/files/etc/ansgo/panel.json"
  test -s "$STAGE/docker/files/etc/ansgo/secrets.env"
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$STAGE/docker/files/etc/ansgo/panel.json"
  mkdir -p /etc/ansgo-backup
  BACKUP="/etc/ansgo-backup/docker-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  tar czf "$BACKUP" -C "$STAGE/docker" .
  chmod 600 "$BACKUP"
  tar tzf "$BACKUP" | grep -E '^\.?/?files/etc/ansgo/panel.json$' >/dev/null
}
docker_rollback(){
  local dest type name source
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" stop ansgo || return 1
  while IFS=$'\t' read -r dest type name source; do
    local mount
    if [ "$type" = volume ]; then mount="type=volume,src=$name,dst=/target"
    else mount="type=bind,src=$source,dst=/target"; fi
    tar cf - -C "$STAGE/docker/files$dest" . |
      docker run --rm -i --network none --entrypoint /bin/bash --mount "$mount" "$OLD_IMAGE" \
        -c 'set -e
          python3 -c '\''import os,shutil
for name in os.listdir("/target"):
    p=os.path.join("/target",name)
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p)
    else: os.unlink(p)'\''
          tar xf - -C /target' || return 1
  done < <(python3 - "$STAGE/docker/inspect.json" <<'PY'
import json,sys
for m in json.load(open(sys.argv[1]))[0]['Mounts']:
    if m['Destination'] in ('/etc/ansgo','/etc/ssl/ansgo','/etc/caddy','/etc/sing-box','/root/.acme.sh'):
        print('\t'.join([m['Destination'],m['Type'],m.get('Name','-'),m['Source']]))
PY
)
  cp -p "$STAGE/docker/compose.yml" "$COMPOSE_FILE"
  # override 固定旧 image ID，避免原 latest 指向新镜像。
  printf 'services:\n  ansgo:\n    image: %s\n' "$OLD_IMAGE" > "$STAGE/rollback.yml"
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" -f "$STAGE/rollback.yml" up -d --force-recreate --pull never ansgo
}
# 解析结果只驻留内存；正式文件始终从原文编辑，不能持久化 config 的展开输出。
docker_prepare_compose(){
  cp -p "$COMPOSE_FILE" "$STAGE/compose.yml"
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" config --quiet
  python3 - "$STAGE/compose.yml" "$VER" "$DOCKER_DIR" "${COMPOSE[@]}" <<'PY'
import json, pathlib, re, subprocess, sys
p, version, directory, *compose = sys.argv[1:]
result = subprocess.run(compose + ['--project-directory', directory, '-f', p,
                                  'config', '--format', 'json'],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
cfg = json.loads(result.stdout)['services']['ansgo']
original = pathlib.Path(p).read_text()
lines = original.splitlines(keepends=True)
def key(line):
    return re.match(r'^( *)([\w-]+|"[^"\n]+"|\'[^\'\n]+\'):[ \t]*(.*?)(?:\n)?$', line)
def section(rows, name, indent=None):
    for i, line in enumerate(rows):
        m = key(line)
        if m and m[2].strip('"\'') == name and (indent is None or len(m[1]) == indent):
            depth = len(m[1])
            end = next((j for j in range(i+1, len(rows))
                        if rows[j].strip() and not rows[j].lstrip().startswith('#')
                        and (len(rows[j])-len(rows[j].lstrip()) < depth
                             or (key(rows[j]) and len(key(rows[j])[1]) <= depth))), len(rows))
            return i, end, m
    return None
services = section(lines, 'services', 0)
assert services, 'compose 缺少 services'
base, end, _ = services
children = [len(m[1]) for line in lines[base+1:end] if (m := key(line))]
assert children, 'compose 缺少服务定义'
service = section(lines[base+1:end], 'ansgo', min(children))
assert service, 'compose 缺少 services.ansgo'
a, b, header = service
start, stop = base+1+a+1, base+1+b
block = lines[start:stop]
source_block = block[:]
fields = [len(m[1]) for line in block if (m := key(line))]
assert fields, '不支持内联 ansgo 定义'
depth = min(fields)
pad = ' '*depth
assert section(block, 'env_file', depth), 'compose 缺少 env_file，请先恢复外部凭据文件'
def replace_value(rows, index, value):
    m = key(rows[index])
    # 行尾注释与缩进原样保留；image 的旧值允许加引号。
    comment = re.search(r'[ \t]+#.*', m[3])
    rows[index] = m[1]+m[2]+': '+value+(comment[0] if comment else '')+'\n'
image = section(block, 'image', depth)
if image:
    replace_value(block, image[0], 'ghcr.io/6667084/ansgo:'+version)
else:
    block.insert(0, pad+'image: ghcr.io/6667084/ansgo:'+version+'\n')
mem = int(next(x.split()[1] for x in open('/proc/meminfo') if x.startswith('MemTotal:')))//1024
limit = mem*70//100 if mem <= 1024 else 512
add = []
for name, value in [('mem_limit', str(limit)+'m'), ('pids_limit', '512'),
                    ('cpu_shares', '512'), ('cpus', '1.0')]:
    if name not in cfg:
        add.append(pad+name+': '+value+'\n')
if 'memswap_limit' not in cfg:
    size = int(cfg.get('mem_limit', limit*1024**2))
    add.append(pad+'memswap_limit: '+str(size+256*1024**2)+'\n')
logging = section(block, 'logging', depth)
if not logging:
    add.extend([pad+'logging:\n', pad+'  driver: json-file\n', pad+'  options:\n',
                pad+'    max-size: "10m"\n', pad+'    max-file: "3"\n'])
else:
    i, j, m = logging
    assert not m[3].split('#', 1)[0].strip(), '请将 logging 改为分行格式后升级'
    log = block[i+1:j]
    log_fields = [len(m[1]) for line in log if (m := key(line))]
    ld = min(log_fields, default=depth+2)
    lp = ' '*ld
    driver = cfg.get('logging', {}).get('driver', 'json-file')
    if not section(log, 'driver', ld):
        log.insert(0, lp+'driver: '+driver+'\n')
    if driver == 'json-file':
        options = section(log, 'options', ld)
        if options:
            oi, oj, om = options
            value = om[3].split('#', 1)[0].strip()
            assert value in ('', '{}'), '请将 logging.options 改为分行格式后升级'
            if value == '{}': replace_value(log, oi, '')
            option_fields = [len(m[1]) for line in log[oi+1:oj] if (m := key(line))]
            op = ' '*min(option_fields, default=ld+2)
        else:
            oi = len(log)
            log.append(lp+'options:\n')
            op = lp+'  '
        for name, value in [('max-size', '10m'), ('max-file', '3')]:
            if name not in cfg.get('logging', {}).get('options', {}):
                log.insert(oi+1, op+name+': "'+value+'"\n')
    block[i+1:j] = log
missing_mounts = [mount for target, mount in (
    ('/host/manual-certs', '/etc/ansgo-docker/manual-certs:/host/manual-certs:ro'),
    ('/etc/ansgo-backup', 'ansgo_backup:/etc/ansgo-backup'))
    if not any(v.get('target', '').rstrip('/') == target for v in cfg.get('volumes', []))]
if missing_mounts:
    volumes = section(block, 'volumes', depth)
    if volumes:
        i, j, m = volumes
        value = m[3].split('#', 1)[0].strip()
        assert value in ('', '[]'), '请将 volumes 改为分行格式后升级'
        if value == '[]': replace_value(block, i, '')
        vp = next((line[:line.index('-')] for line in block[i+1:j]
                   if line.lstrip().startswith('- ')), pad+'  ')
        block[i+1:i+1] = [vp+'- '+mount+'\n' for mount in missing_mounts]
    else:
        add.extend([pad+'volumes:\n']+[pad+'  - '+mount+'\n' for mount in missing_mounts])
edited = lines[:start]+add+block+lines[stop:]
if 'ansgo_backup:/etc/ansgo-backup' in missing_mounts:
    volumes = section(edited, 'volumes', 0)
    if volumes:
        i, j, m = volumes
        value = m[3].split('#', 1)[0].strip()
        assert value in ('', '{}'), '请将顶层 volumes 改为分行格式后升级'
        if value == '{}': replace_value(edited, i, '')
        fields = [len(m[1]) for line in edited[i+1:j] if (m := key(line))]
        vd = min(fields, default=2)
        if not section(edited[i+1:j], 'ansgo_backup', vd):
            edited.insert(i+1, ' '*vd+'ansgo_backup:\n')
    else:
        if edited and not edited[-1].endswith('\n'): edited[-1] += '\n'
        edited.extend(['volumes:\n', '  ansgo_backup:\n'])
text = ''.join(edited)
assert section(block, 'env_file', depth), 'env_file 不得丢失'
# 外部凭据引用与显式环境块必须逐行保留。
for name in ('env_file', 'environment'):
    before, after = section(source_block, name, depth), section(block, name, depth)
    assert bool(before) == bool(after), '环境配置不得增删'
    if before:
        assert source_block[before[0]:before[1]] == block[after[0]:after[1]], '环境配置不得展开'
# 包括 dotenv 解码后的值；原文已有的短值及固定证书模式枚举不能当成新泄露。
values = [str(v) for v in cfg.get('environment', {}).values() if v is not None]
env = pathlib.Path(directory)/'ansgo.env'
if env.exists():
    for line in env.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            value = line.split('=', 1)[1].strip().strip('"\'')
            values.append(value)
assert not any(v and v not in ('manual', 'acme') and v in text and v not in original
               for v in values), '拒绝写入展开的环境凭据'
pathlib.Path(p).write_text(text)
PY
  "${COMPOSE[@]}" --project-directory "$DOCKER_DIR" -f "$STAGE/compose.yml" config --quiet
}
docker_available_bytes(){
  df -Pk "$DOCKER_ROOT" | awk 'NR==2 {printf "%.0f\n", $4*1024}'
}
# 同 ID 若还带其它仓库标签，也不触碰。
docker_old_images(){
  docker image ls --no-trunc --format '{{.Repository}} {{.ID}}' |
    python3 -c 'import sys
keep=set(sys.argv[1:]); repos={"ghcr.io/6667084/ansgo", "ghcr.io/jiasongji/ansgo"}; images={}
for line in sys.stdin:
    repo, image=line.split(); images.setdefault(image,set()).add(repo)
for image, tags in images.items():
    if image not in keep and tags <= repos: print(image)' "$@"
}
docker_remove_image(){
  local references
  # 再核验标签、摘要引用与全部容器；多项目共用 ID 或仍被引用时不能强制删除。
  docker image inspect --format '{"tags":{{json .RepoTags}},"digests":{{json .RepoDigests}}}' "$1" |
    python3 -c 'import json,sys
d=json.load(sys.stdin); refs=(d.get("tags") or [])+(d.get("digests") or [])
repos={"ghcr.io/6667084/ansgo","ghcr.io/jiasongji/ansgo"}
assert refs and all((r.split("@",1)[0] if "@" in r else r.rsplit(":",1)[0]) in repos for r in refs)' || return 1
  references=$(docker ps -aq --filter "ancestor=$1") || return 1
  [ -z "$references" ] || return 1
  # 同一项目的 latest/版本双标签需要 force；上面的检查保护其它镜像与容器。
  docker image rm --force "$1"
}
docker_check_space(){
  # 本地已有目标镜像时无需为重复拉取预留完整镜像空间。
  if TARGET_ID=$(docker image inspect -f '{{.Id}}' "$TARGET_IMAGE" 2>/dev/null); then return; fi
  TARGET_ID=''
  local size available required image candidates reclaim=0
  size=$(docker image inspect -f '{{.Size}}' "$OLD_IMAGE")
  [[ "$size" =~ ^[0-9]+$ ]]
  required=$((size+200*1024*1024))
  available=$(docker_available_bytes)
  [[ "$available" =~ ^[0-9]+$ ]]
  [ "$available" -lt "$required" ] || return 0
  candidates=$(docker_old_images "$OLD_IMAGE" "$TARGET_ID")
  while read -r image; do
    [ -n "$image" ] || continue
    size=$(docker image inspect -f '{{.Size}}' "$image")
    [[ "$size" =~ ^[0-9]+$ ]]
    reclaim=$((reclaim+size))
  done <<< "$candidates"
  # 连理论回收上限都不足时，不删除镜像，也不暂停容器或修改 compose。
  if [ $((available+reclaim)) -ge "$required" ]; then
    while read -r image; do
      [ -n "$image" ] || continue
      say "拉取前清理本项目旧镜像: $image"
      docker_remove_image "$image" || say "镜像仍被引用或无法删除，保留: $image"
      available=$(docker_available_bytes)
      [ "$available" -lt "$required" ] || return 0
    done <<< "$candidates"
  fi
  say "Docker 磁盘空间不足: $DOCKER_ROOT 可用 $((available/1024/1024))MB，估计需要 $((required/1024/1024))MB（当前镜像 + 200MB 余量）；未切换 compose 或容器"
  say '请手动检查并释放：/etc/ansgo-backup 中过期备份、宿主日志、Docker 构建缓存及确认无用的镜像；不自动清理其它项目镜像或卷'
  return 1
}
docker_cleanup_images(){
  local image current available
  current=$(docker inspect -f '{{.Image}}' "$CID") || return 0
  while read -r image; do
    [ -n "$image" ] || continue
    docker_remove_image "$image" || say "镜像仍被引用或无法删除，保留: $image"
  done < <(docker_old_images "$current" "$OLD_IMAGE")
  available=$(docker_available_bytes) || return 0
  if [[ "$available" =~ ^[0-9]+$ ]] && [ "$available" -lt $((500*1024*1024)) ] && [ "$OLD_IMAGE" != "$current" ]; then
    while read -r image; do
      [ "$image" = "$OLD_IMAGE" ] || continue
      if docker_remove_image "$image"; then
        say "为保证磁盘余量已删除旧镜像，如需回滚将重新拉取 ${OLD_HINT:-$OLD_TAG}"
      fi
    done < <(docker_old_images "$current")
  fi
}
upgrade_docker(){
  CID=$("${COMPOSE[@]}" -f "$COMPOSE_FILE" ps -q ansgo)
  [ -n "$CID" ]
  OLD_IMAGE=$(docker inspect -f '{{.Image}}' "$CID")
  OLD_TAG=$(docker inspect -f '{{.Config.Image}}' "$CID")
  # 浮动 tag（如 :latest）升级后会指向新版本，回滚提示改用旧容器内记录的明确版本号
  local old_ver
  old_ver=$(docker exec "$CID" cat /usr/local/share/ansgo-version 2>/dev/null || true)
  old_ver="v${old_ver#v}"
  OLD_HINT="$OLD_TAG"
  if [[ "$OLD_TAG" != *:v[0-9]* && "$old_ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    OLD_HINT="ghcr.io/6667084/ansgo:$old_ver"
  fi
  TARGET_IMAGE="ghcr.io/6667084/ansgo:$VER"
  DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}')
  [ -n "$DOCKER_ROOT" ]
  dl "$RAW/ansgo-admin" "$STAGE/ansgo-admin"
  bash -n "$STAGE/ansgo-admin"
  docker_prepare_compose
  docker_check_space
  say "拉取明确版本镜像: $VER"
  docker pull "$TARGET_IMAGE"
  # 备份只收录原始 compose，不能包含 config 展开的环境变量。
  original_compose=$(mktemp "$STAGE/compose-original.XXXXXX")
  cp -p "$COMPOSE_FILE" "$original_compose"
  # 先停止写入者再快照所有实际配置/证书/acme 卷，保证 SQLite 一致。
  docker exec "$CID" systemctl stop ansgo-panel cron
  DOCKER_PAUSED=1
  docker_backup
  MUTATED=1
  # Docker 升级与裸金属使用同一旧格式迁移；新 schema 交给新版面板。
  container_lib="/tmp/ansgo-limits.$$"
  docker cp "$STAGE/ansgo-limits" "$CID:$container_lib"
  docker exec "$CID" bash -c 'source "$1"; ansgo_migrate /etc/ansgo/panel.json /etc/ansgo/secrets.env; rc=$?; rm -f "$1"; exit "$rc"' _ "$container_lib"
  mkdir -p "$DOCKER_DIR/manual-certs"
  chmod 700 "$DOCKER_DIR/manual-certs"
  cp -p "$STAGE/compose.yml" "$COMPOSE_FILE"
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" config --quiet
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --force-recreate ansgo
  DOCKER_PAUSED=0
  local i healthy=0
  CID=$("${COMPOSE[@]}" -f "$COMPOSE_FILE" ps -q ansgo)
  for i in {1..30}; do
    if docker exec "$CID" systemctl is-active --quiet ansgo-panel 2>/dev/null &&
       [ "$(docker exec "$CID" cat /usr/local/share/ansgo-version)" = "$VER" ]; then
      healthy=1; break
    fi
    sleep 2
  done
  [ "$healthy" = 1 ]
  # compose config 只证明语法；再核验实际容器的硬内存、swap、pids 与 CPU 竞争权重。
  docker inspect "$CID" --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}} {{.HostConfig.CpuShares}} {{json .HostConfig.LogConfig}}' |
    python3 -c 'import json,sys; p=sys.stdin.read().split(" ",4); assert len(p)==5 and all(int(x)>0 for x in p[:4]); log=json.loads(p[4]); assert log.get("Type"); assert log["Type"]!="json-file" or all(k in log.get("Config",{}) for k in ("max-size","max-file"))'
  docker exec "$CID" bash -c '
    source /usr/local/bin/ansgo-limits
    port=$(python3 -c '\''import json;c=json.load(open("/etc/ansgo/panel.json"));print(c["panel_port"])'\'')
    path=$(python3 -c '\''import json;c=json.load(open("/etc/ansgo/panel.json"));print(c["url_path"])'\'')
    curl --noproxy "*" -kfsS --max-time 5 "https://127.0.0.1:$port${path}api/auth" >/dev/null'
  MUTATED=0
  say 'Docker 日常备份现已持久化到卷 ansgo_backup（已有自定义备份挂载继续沿用）'
  docker exec "$CID" ansgo-admin prune --yes || say '容器升级已完成；容器内备份清理失败'
  # 宿主的 Docker 备份也需保留策略；使用本次同版本 admin，不安装到宿主。
  ANSGO_CONF="$STAGE/docker/files/etc/ansgo/panel.json" ANSGO_LIB="$STAGE/ansgo-limits" \
    bash "$STAGE/ansgo-admin" prune --yes || say '容器升级已完成；宿主备份清理失败'
  docker_cleanup_images
}
case "$MODE" in metal) upgrade_metal;; docker) upgrade_docker;; esac
DONE=1
