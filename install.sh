#!/usr/bin/env bash
# =============================================================================
# ANS-GO 一键部署脚本 (install.sh)   v1.6.2
#   交互式：bash install.sh          （主菜单：安装/卸载/彻底卸载/落地）
#   带参数：bash install.sh --domain ... --dynu-key ... --non-interactive
#   Docker：bash install.sh --domain ... --docker --non-interactive
#   卸载  ：bash install.sh --uninstall           # 移除服务/容器，保留配置/卷
#           bash install.sh --uninstall --purge   # 彻底删除配置/卷/镜像
#
# 所有资源取自本仓库 GitHub / 官方上游：
#   脚本/源码    -> raw.githubusercontent.com/6667084/ANS-GO/v1.6.2/deploy/
#   面板二进制    -> github.com/6667084/ANS-GO/releases/download/$VER/ansgo-panel-linux-<arch>
#   sing-box      -> SagerNet 官方 release（多架构）
#   caddy(naive) -> klzgrad/forwardproxy 源码 + xcaddy 编译（Docker 内）或本项目预编译产物
#   面板镜像      -> ghcr.io/6667084/ansgo（all-in-one，--docker 模式）
#
# 适用于 Debian 11/12（含 LXC），需 root。
# =============================================================================
# ---- bootstrap：把脚本完整落地后再执行（解决 curl|bash 的两个问题） ----
# 问题1 SIGPIPE：`curl ... | bash -s -- ...` 形式下 bash 从管道逐块读脚本执行。
#   脚本中途任何 exit（do_uninstall/--landing/--help/错误退出）都会让 bash 提前结束
#   → 管道读端关闭 → curl 还在写剩余字节 → curl 收到 SIGPIPE → 报 (23)。
# 问题2 进程替换卡死：`bash <(curl ...)` 下 BASH_SOURCE=/dev/fd/NN，脚本内容在 fd，
#   fd0 是用户终端。若误用 cat（无参数）从 fd0 读 → 吃掉用户终端输入 → 卡死。
# 修复：检测管道/进程替换运行 → 落地临时文件 → exec 重跑。关键：
#   - 进程替换判断用 [ -e ]（fd 通过 -e 测试，但 [ -f ] 失败因为非常规文件）
#   - 进程替换下 cat "$_ansi_self"（从 /dev/fd/NN 读脚本），绝不 cat 无参数（会吃终端）
#   - 管道下（BASH_SOURCE 空）才 cat 无参数（从 fd0=管道读）
#   - `bash install.sh`（真实文件）→ BASH_SOURCE 常规路径 → 跳过 bootstrap
_ansi_self="${BASH_SOURCE[0]:-}"
case "$_ansi_self" in
  "" | /dev/fd/* | /proc/self/fd/*)
    # 来自管道或进程替换：落地到临时文件后 exec 重跑（保留所有原参数）
    _ansi_dir="$(mktemp -d)" || exit 1
    _ansi_tmp="$_ansi_dir/install.sh"
    # 注意：进程替换下 BASH_SOURCE=/dev/fd/NN，但 [ -f ] 对 fd 返回 false（非常规文件），
    #   必须用 [ -e ] 判断；且脚本内容在 /dev/fd/NN 里，不在 stdin(fd0=用户终端)。
    #   管道模式下 BASH_SOURCE 为空，脚本内容在 stdin，必须 cat 从 stdin 读。
    if [ -n "$_ansi_self" ] && [ -e "$_ansi_self" ]; then
      # 进程替换：脚本内容在 /dev/fd/NN，cat 它（绝不能 cat 无参数从 fd0 读，那会吃用户终端输入）
      cat "$_ansi_self" > "$_ansi_tmp" 2>/dev/null || cp "$_ansi_self" "$_ansi_tmp" 2>/dev/null
    else
      # 管道：BASH_SOURCE 为空，脚本内容在 stdin，cat 从 stdin 读
      cat > "$_ansi_tmp" 2>/dev/null
    fi
    # 落地失败则继续从管道执行（退化为旧行为，不至于卡死）
    if [ -s "$_ansi_tmp" ]; then
      chmod +rx "$_ansi_tmp" 2>/dev/null
      export _ANSGO_BOOTSTRAP_TMP="$_ansi_tmp"
      export _ANSGO_BOOTSTRAP_DIR="$_ansi_dir"
      exec bash "$_ansi_tmp" "$@"
    fi
    rm -rf "$_ansi_dir" 2>/dev/null
    ;;
esac
unset _ansi_self _ansi_tmp
# ---- bootstrap end ----

set -uo pipefail
umask 077

WORK="" BIN_STAGE="" APT_READY=0
install_cleanup(){
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ -z "$BIN_STAGE" ] || rm -rf "$BIN_STAGE"
  [ -z "${_ANSGO_BOOTSTRAP_DIR:-}" ] || rm -rf "$_ANSGO_BOOTSTRAP_DIR"
  [ "$APT_READY" = 0 ] || { command -v apt-get >/dev/null && apt-get clean || true; }
}
trap install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# curl | bash 管道形式下，bash 的 stdin(fd0) 被 curl 输出占用。若用 exec 0</dev/tty
# 全局切走 fd0，bash 会读不到脚本剩余部分（管道还在喂脚本）→ 后续代码全部不执行。
# 故不能在脚本中途对 fd0 做 exec；改为定义 readtty 函数，仅在某次 read 时临时把
# stdin 指到 /dev/tty（局部重定向，不动全局 fd0），读完即恢复。
#   - NONINT 模式不调用 readtty，本机制对 CI/自动化 无影响
#   - 无 /dev/tty（纯 CI 容器）时 readtty 回退到原 stdin（读 EOF → 返回空）
readtty(){ # 从 /dev/tty 读一行（curl|bash 下 stdin 被管道占用时的交互读取）
  local line=""
  if [ -c /dev/tty ]; then
    # 用子 shell + 局部重定向：仅这次 read 的 fd0 是 /dev/tty，不影响主脚本读管道
    line=$(read -r _LINE </dev/tty 2>/dev/null && printf '%s' "$_LINE") || line=""
  fi
  printf '%s' "$line"
}

REPO="6667084/ANS-GO"
RAW="${ANSGO_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/v1.6.2/deploy}"
RAW="${RAW%/}"
REL="${ANSGO_REL_BASE:-https://github.com/${REPO}/releases/download}"
REL="${REL%/}"
RELEASE_API="${ANSGO_RELEASE_API:-https://api.github.com/repos/${REPO}/releases/tags}"
RELEASE_API="${RELEASE_API%/}"
VER="v1.6.2"         # 面板二进制 release tag（install.sh 脚本本体 v1.6.0：--panel-title/--server-ip 安装参数 + ACME 引导精简）
# 架构映射（uname -m -> 下载用后缀）；用 case 避免关联数组在 set -u 下的 unbound variable 陷阱
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        AARCH=amd64 ;;
  aarch64|arm64) AARCH=arm64 ;;
  *)             AARCH=amd64 ;;
esac

# ---- 默认值 ----
# v1.5.12: 所有端口默认空（未指定），在 validate_inputs 后随机生成（10000-65535，
#   避开 80/443/25822/互相冲突/已占用）。用户通过 --ss-port 等参数可显式指定。
DOMAIN="" DYNU_KEY="" DYNU_CID="" DYNU_SECRET="" EMAIL=""
SS_PORT="" ANYTLS_PORT="" SOCKS_PORT="" NAIVE_PORT="" PANEL_PORT=""
PANEL_USER="admin" DISGUISE_PANEL="proxy:https://example.com" DISGUISE_NAIVE="proxy:https://example.com"
# 证书来源：acme（默认，需 Dynu 凭证）/ manual（手动指定已有证书+私钥路径，二选一）
CERT_MODE="acme" CERT_FILE="" KEY_FILE=""
# 各服务密码/密钥（v1.5.5 新增；留空则部署时自动随机生成）
SS_PASSWORD="" ANYTLS_PASSWORD="" ANYTLS_UUID_IN="" SOCKS_USER_IN="" SOCKS_PASSWORD="" NAIVE_USER_IN="" NAIVE_PASSWORD=""
PANEL_PASSWORD_IN="" URL_PATH_IN=""
# v1.6.0: 节点信息基础名（--panel-title）与显式连接 IP（--server-ip）。
#   留空保持旧语义：panel_title="ANS-GO 管理面板"、server_ip=""（空值由面板 Go 端
#   启动时自动探测公网 IP 并保存；shell 层不做任何公网查询）。
PANEL_TITLE_IN="" SERVER_IP_IN=""
# v1.5.36: Docker 容器内存硬限制（MB，整数）。留空则部署时按宿主内存自动计算：
#   宿主 ≤1G → MemTotal*70%；宿主 >1G → 512m。memswap 自动 = mem_limit + 256m。
DOCKER_MEM_IN=""
NONINT=0 DOCKER=0 FORCE_BIN=0 UNINSTALL=0 PURGE=0 LANDING=0 NO_CADDY=0
LANDING_ARGS=()

# ---- 颜色/日志 ----
if [ -t 1 ]; then C_G='\033[32m';C_Y='\033[33m';C_R='\033[31m';C_B='\033[36m';C_0='\033[0m'; else C_G='';C_Y='';C_R='';C_B='';C_0=''; fi
log(){ printf "${C_G}[*]${C_0} %s\n" "$*"; }
inf(){ printf "${C_B}[i]${C_0} %s\n" "$*"; }
warn(){ printf "${C_Y}[!]${C_0} %s\n" "$*" >&2; }
err(){ printf "${C_R}[X]${C_0} %s\n" "$*" >&2; }
hr(){ printf "\n${C_B}═══ %s ═══${C_0}\n" "$*"; }
# 下载辅助（curl 优先，回退 wget）—— v1.5.6 修复：提前定义到 do_docker_deploy 之前
# 之前定义在 line 654（在 do_docker_deploy 的 line 472 调用之后才解析），
# 导致 bash 单遍解析时 do_docker_deploy 内调用 dl_or_exit 报 command not found
dl(){ # URL DEST
  if command -v curl >/dev/null; then curl --connect-timeout 10 --max-time 180 -fsSL "$1" -o "$2"
  else wget --timeout=30 --tries=2 -qO "$2" "$1"; fi
}
dl_or_exit(){ dl "$1" "$2" || { err "下载失败: $1"; exit 3; }; }

# ---- 参数解析 ----
usage(){ cat <<EOF
用法: bash install.sh [选项]
  --domain DOMAIN          你的域名（必填）
  --dynu-key KEY           Dynu API Key（路径A，推荐）
  --dynu-client-id ID      [兼容保留] Dynu OAuth Client ID（路径B，与 --dynu-secret 同用；安装交互已只引导 API Key）
  --dynu-secret SECRET     [兼容保留] Dynu OAuth Secret（路径B）
  --email EMAIL            ACME 注册邮箱
  --ss-port N              Shadowsocks 端口（默认随机 10000-65535）
  --anytls-port N          AnyTLS 端口（默认随机 10000-65535）
  --socks-port N           SOCKS5 端口（默认随机 10000-65535）
  --naive-port N           NaiveProxy 端口（默认随机 10000-65535，勿用 443）
  --panel-port N           面板端口（默认随机 10000-65535）
  --panel-user USER        面板管理员用户名（默认 admin）
  --panel-title TITLE      节点信息基础名（浏览器标题 <TITLE>_ANS、节点 URI 名称 <TITLE>-AT/NV/SS/SK/LD；
                           默认 "ANS-GO 管理面板"→显示 Manage；1-64 字符（首尾空白自动去除，纯空白/控制字符拒绝），
                           其余字符（含 $ # 引号 空格 中文等）均可——Docker 侧经 percent-encoding 透传，裸金属 JSON 转义）
  --server-ip IP           节点「连接地址」显式公网 IP（严格 IPv4/IPv6 校验；VPC/NAT 网络必填）。
                           留空保持旧语义：面板启动时自动探测并保存；已有配置不会被覆盖
  --panel-password PASS    面板管理员密码（默认随机；自定义须 6-64 字符）
  --panel-url-path PATH    面板 URL 路径（默认随机 /xxxxxxxx/；自定义形如 /my-path/）
  --ss-password KEY        Shadowsocks 密钥（默认随机；须 base64(16字节)，用 'openssl rand -base64 16' 生成）
  --anytls-password PASS   AnyTLS 密码（默认随机）
  --anytls-uuid UUID       AnyTLS 用户 UUID（默认随机；标准 UUID 格式如 a1b2c3d4-e5f6-7890-abcd-ef1234567890）
  --socks-user USER        SOCKS5 用户名（默认随机；不含冒号和空白）
  --socks-password PASS    SOCKS5 密码（默认随机；不含冒号和空白）
  --naive-user USER        NaiveProxy 用户名（默认随机；不含冒号和空白）
  --naive-password PASS    NaiveProxy 密码（默认随机；不含冒号和空白）
  --disguise-panel VAL     :443 直访伪装站点（proxy:<URL> 反代 / page 默认页，默认 proxy:https://example.com）
  --disguise-naive VAL     NaiveProxy 端口的伪装站点（同上格式，默认 proxy:https://example.com）
  --cert-mode MODE         证书来源：acme（默认，用 Dynu DNS-01 自动签发）| manual（手动指定已有证书，跳过 Dynu/acme）
  --cert-fullchain PATH    manual 模式：证书文件完整绝对路径（如 /etc/letsencrypt/live/x.com/fullchain.pem）
  --cert-privkey PATH      manual 模式：私钥文件完整绝对路径（如 /etc/letsencrypt/live/x.com/privkey.pem）
  --docker                 用 ghcr.io all-in-one 镜像跑（KVM；否则裸金属）
  --docker-mem MB          Docker 容器内存硬限制，单位 MB（默认按宿主内存自动：≤1G 宿主取 70%，>1G 取 512）
  --no-caddy               不部署 caddy 的 :80/:443 站点（让已装的 nginx/其它 web 服务器接管；naive 仍可装但只听 naive 端口）
  --force-bin              强制从 Releases 重装 sing-box/caddy（已装则跳过）
  --non-interactive        不交互，缺项报错退出
  --landing                在落地机部署独立 ss-server（剩余参数 --port N 等透传给落地脚本）
  --uninstall              卸载 ANS-GO（自动检测 Docker/裸金属；保留配置/卷）
  --purge                  与 --uninstall 同用：彻底删除配置/密钥/证书/卷/镜像
  -h, --help
交互式运行（无参数）会显示主菜单：安装 / 卸载 / 彻底卸载 / 落地
下载源环境变量（仅本次执行生效）：
  ANSGO_RAW_BASE      deploy 目录 URL
  ANSGO_REL_BASE      release 下载根，按 <base>/<ver>/<asset> 取文件
  ANSGO_RELEASE_API   release 元数据根，按 <api>/<ver> 取 JSON
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --dynu-key) DYNU_KEY="$2"; shift 2;;
    --dynu-client-id) DYNU_CID="$2"; shift 2;;
    --dynu-secret) DYNU_SECRET="$2"; shift 2;;
    --email) EMAIL="$2"; shift 2;;
    --ss-port) SS_PORT="$2"; shift 2;;
    --anytls-port) ANYTLS_PORT="$2"; shift 2;;
    --socks-port) SOCKS_PORT="$2"; shift 2;;
    --naive-port) NAIVE_PORT="$2"; shift 2;;
    --panel-port) PANEL_PORT="$2"; shift 2;;
    --panel-user) PANEL_USER="$2"; shift 2;;
    --panel-title) PANEL_TITLE_IN="$2"; shift 2;;
    --server-ip) SERVER_IP_IN="$2"; shift 2;;
    --panel-password) PANEL_PASSWORD_IN="$2"; shift 2;;
    --panel-url-path) URL_PATH_IN="$2"; shift 2;;
    --ss-password) SS_PASSWORD="$2"; shift 2;;
    --anytls-password) ANYTLS_PASSWORD="$2"; shift 2;;
    --anytls-uuid) ANYTLS_UUID_IN="$2"; shift 2;;
    --socks-user) SOCKS_USER_IN="$2"; shift 2;;
    --socks-password) SOCKS_PASSWORD="$2"; shift 2;;
    --naive-user) NAIVE_USER_IN="$2"; shift 2;;
    --naive-password) NAIVE_PASSWORD="$2"; shift 2;;
    --disguise-panel) DISGUISE_PANEL="$2"; shift 2;;
    --disguise-naive) DISGUISE_NAIVE="$2"; shift 2;;
    --cert-mode) CERT_MODE="$2"; shift 2;;
    --cert-fullchain) CERT_FILE="$2"; shift 2;;
    --cert-privkey) KEY_FILE="$2"; shift 2;;
    --docker) DOCKER=1; shift;;
    --docker-mem) DOCKER_MEM_IN="$2"; shift 2;;
    --no-caddy) NO_CADDY=1; shift;;
    --force-bin) FORCE_BIN=1; shift;;
    --non-interactive) NONINT=1; shift;;
    # --landing：剩余参数（--port N 等）透传给 ansgo-landing.sh，不在此解析
    --landing) LANDING=1; shift; LANDING_ARGS=("$@"); break;;
    --uninstall) UNINSTALL=1; shift;;
    --purge) PURGE=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "未知参数: $1"; usage; exit 1;;
  esac
done

# =============================================================================
# 工具函数（v1.6.0）：在 validate_inputs 调用前定义——校验在依赖安装前执行，
# 此时 python3 可能尚未安装，所有工具函数都有无 python 的 shell 兜底路径。
# 函数体约定：fnname(){ 顶格起、结束 } 顶格独立一行，供 scripts/test-*.sh 提取执行。
# =============================================================================
# JSON 字符串字面量转义（" 与 \ 与全部控制字符 -> \t \n \r \uXXXX，非 ASCII 原样）。
# python3 存在时用 json.dumps 保证与标准 JSON 一致；缺失时 sed 兜底（" \ TAB），
# 其余控制字符依赖上游校验拒绝（分层防御）。
ansgo_json_escape(){
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1])'
  else
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
  fi
}

# RFC3986 percent-encode（safe=''）：把任意可读值收敛为 [A-Za-z0-9%_.-] 字符集，
# 专门用于 Docker ansgo.env transport——compose v2 会解析 env_file 中的 $ 插值与
# " #" 行内注释，v1 逐行全字面；percent 值在两代解析器下均字面安全。
# 仅 Docker 路径使用（install.sh 依赖段已确保 python3 存在）；裸金属不走 env 无需编码。
ansgo_pct_encode(){
  python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# 严格校验 IPv4/IPv6 文本（rc 0=合法）。优先 python3 ipaddress（覆盖 IPv4-mapped 等
# 边缘格式）；python3 未装时（校验先于依赖安装执行）用 shell 结构化规则兜底，
# 保证普通安装流程在无 python 环境不会崩溃、也不会放过明显非法值。
# 兜底较 python 略严：不支持 IPv4 映射尾段（::ffff:1.2.3.4）——依赖段确保 python3
# 后安装流程会用 ipaddress 复核一次（见环境校验段），两侧取交集不产生误拒。
# ANSGO_IP_FORCE_SHELL=1 强制走 shell 分支（离线测试用）。
ansgo_ip_check(){
  local ip="$1"
  if [ -z "${ANSGO_IP_FORCE_SHELL:-}" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import ipaddress,sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)' "$ip" 2>/dev/null
    return $?
  fi
  # ---- shell 结构化兜底（无 python3）----
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1        # 字符集
  if [[ "$ip" != *:* ]]; then
    # 无冒号：只可能是纯 IPv4（点分四段，各 0-255）
    [[ "$ip" == *.* ]] || return 1
    local -a o; local IFS='.'; read -r -a o <<<"$ip"; unset IFS
    [ ${#o[@]} -eq 4 ] || return 1
    local x
    for x in "${o[@]}"; do
      [[ "$x" =~ ^[0-9]{1,3}$ ]] && [ "$x" -le 255 ] || return 1
    done
    return 0
  fi
  [[ "$ip" == *.* ]] && return 1                      # 有冒号又含点（IPv4-mapped）→ 兜底不支持（依赖段 python 复核）
  [[ "$ip" == *":::"* ]] && return 1                  # 三连及以上冒号（2001:::1 / :::）
  [[ "$ip" == :* && "$ip" != ::* ]] && return 1       # 前导单冒号（:2001:db8::1）
  [[ "$ip" == *: && "$ip" != *:: ]] && return 1       # 尾部单冒号（2001:db8::1:）
  local pre post part g groups=0
  if [[ "$ip" == *"::"* ]]; then
    [[ "$ip" == *::*::* ]] && return 1                # :: 只能压缩一次（1::2::3）
    pre="${ip%%::*}"; post="${ip##*::}"
    for part in "$pre" "$post"; do
      [ -z "$part" ] && continue
      local -a segs; local IFS=':'; read -r -a segs <<<"$part"; unset IFS
      for g in "${segs[@]}"; do
        [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        groups=$((groups+1))
      done
    done
    [ "$groups" -le 7 ] || return 1
  else
    local -a segs; local IFS=':'; read -r -a segs <<<"$ip"; unset IFS
    [ ${#segs[@]} -eq 8 ] || return 1
    for g in "${segs[@]}"; do
      [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
  fi
  return 0
}

# 下载后的 Linux 可执行文件先验证 ELF 架构与内嵌版本，校验失败不覆盖正式路径。
ansgo_verify_elf(){
  local file="$1" arch="$2" version="$3"
  python3 - "$file" "$arch" "$version" <<'PY'
import re, struct, sys
p, arch, version = sys.argv[1:]
with open(p, 'rb') as f:
    h = f.read(20)
assert len(h) == 20 and h[:5] == b'\x7fELF\x02' and h[5] == 1, '不是 ELF64 小端二进制'
assert struct.unpack('<H', h[18:20])[0] == {'amd64': 62, 'arm64': 183}[arch], 'ELF 架构错误'
version = version.lstrip('v').encode()
with open(p, 'rb') as f:
    data = f.read()
    assert version+b'\0' in data or version in re.findall(rb'main\.version=(\d+\.\d+\.\d+)', data), '二进制内嵌版本不匹配'
PY
}

# 全部预检只访问远端和临时目录，失败前不安装依赖或写入宿主配置。
ansgo_asset_probe(){
  if command -v curl >/dev/null; then
    curl --connect-timeout 5 --max-time 15 -fsSLI "$1" >/dev/null 2>&1 ||
      curl --connect-timeout 5 --max-time 15 -fsSL --range 0-0 --max-filesize 1048576 "$1" -o /dev/null
  elif command -v wget >/dev/null; then
    wget --timeout=15 --tries=1 --spider -q "$1"
  else
    err "预检需要已有 curl 或 wget，请先安装下载工具"; return 1
  fi
}
ansgo_compose_v2_hint(){
  err "需要 Docker Compose v2（docker compose 子命令）"
  err "Debian/Ubuntu: apt-get install -y docker-compose-plugin（软件源无此包时先配置 Docker 官方源）"
  err "也可安装官方静态插件：mkdir -p /usr/local/lib/docker/cli-plugins"
  err "curl -fL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose"
}
ansgo_compose_check(){
  local file="$1"
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null; then
    COMPOSE="docker-compose"
  else
    # 未安装 Docker 时由后续官方安装器安装引擎与插件。
    command -v docker >/dev/null || return 0
    ansgo_compose_v2_hint; return 1
  fi
  if ! $COMPOSE -f "$file" config --quiet >/dev/null 2>&1; then
    if [ "$COMPOSE" = docker-compose ]; then ansgo_compose_v2_hint
    else err "Docker Compose 配置预检失败，请检查模板、环境文件与插件版本"; fi
    return 1
  fi
}
ansgo_preflight_assets(){
  local f meta="$WORK/release.json"
  dl "$RELEASE_API/$VER" "$meta" || { err "发布元数据不可下载"; return 1; }
  # 已有 python 时验证发布清单；缺少时仍逐 URL 检查，不为预检安装软件。
  if command -v python3 >/dev/null; then
    python3 - "$meta" "ansgo-panel-linux-$AARCH" <<'PYPREFLIGHT'
import json, sys
names = {a['name'] for a in json.load(open(sys.argv[1]))['assets']}
assert sys.argv[2] in names, 'release 缺少当前架构的面板资产'
PYPREFLIGHT
    [ "$?" = 0 ] || return 1
  fi
  ansgo_asset_probe "$REL/$VER/ansgo-panel-linux-$AARCH" || return 1
  for f in ansgo-limits ansgo-admin ansgo-genconf ansgo-cert-reload ansgo-cert-issue.sh ansgo-sync-manual-cert ansgo-landing.sh dns_dynukey.sh upgrade.sh ansgo-panel.service systemd/caddy.service systemd/sing-box.service systemd/ansgo-autoupgrade.service systemd/ansgo-autoupgrade.timer; do
    ansgo_asset_probe "$RAW/$f" || { err "必需脚本不可下载: $f"; return 1; }
  done
  if [ "$DOCKER" = 1 ]; then
    ansgo_asset_probe "$RAW/docker-compose.yml" || return 1
    dl "$RAW/docker-compose.yml" "$WORK/docker-compose.yml" || return 1
    # 用空环境文件校验模板兼容性，不落宿主配置或凭据。
    : > "$WORK/ansgo.env"
    ansgo_compose_check "$WORK/docker-compose.yml" || return 1
  else
    if [ "$FORCE_BIN" = 1 ] || ! command -v caddy >/dev/null || ! caddy list-modules 2>/dev/null | grep -F 'http.handlers.forward_proxy' >/dev/null; then
      ansgo_asset_probe "$REL/$VER/caddy-naive-linux-$AARCH" ||
        ansgo_asset_probe "$REL/v1.5.16/caddy-naive-linux-$AARCH" || return 1
    fi
    if [ "$FORCE_BIN" = 1 ] || ! command -v sing-box >/dev/null; then
      ansgo_asset_probe "$REL/$VER/sing-box-linux-$AARCH.tar.gz" ||
        ansgo_asset_probe "https://github.com/SagerNet/sing-box/releases/download/v1.13.13/sing-box-1.13.13-linux-$AARCH.tar.gz" || return 1
    fi
  fi
}

# =============================================================================
# 参数校验（v1.5.5 新增）
#   仅对「带参数安装/部署」场景校验；--uninstall / --landing / --purge 跳过
# =============================================================================
validate_inputs(){
  local errs=0 port p
  local final="${VALIDATE_PORTS_ONLY:-0}"

  # secrets.env 按字面值解析，仅拒绝不能表示为单行的输入。
  local field value
  for field in SS_PASSWORD ANYTLS_PASSWORD ANYTLS_UUID_IN SOCKS_USER_IN SOCKS_PASSWORD NAIVE_USER_IN NAIVE_PASSWORD; do
    value="${!field:-}"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
      err "$field 不能包含换行"; errs=$((errs+1))
    fi
  done
  for field in DOMAIN EMAIL PANEL_USER DISGUISE_PANEL DISGUISE_NAIVE DYNU_KEY DYNU_CID DYNU_SECRET CERT_FILE KEY_FILE PANEL_PASSWORD_IN; do
    value="${!field:-}"
    if [[ "$value" =~ [[:cntrl:]] ]] || [[ "$value" == *'$'* || "$value" == *'`'* || "$value" == *"'"* || "$value" == *'"'* || "$value" == *'\'* || "$value" == *' #'* ]]; then
      err "$field 含不能安全传输到 JSON/env 的字符"; errs=$((errs+1))
    fi
  done
  if [ -n "$DOMAIN" ] && ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
    err "域名格式不合法"; errs=$((errs+1))
  fi
  # 首次调用只检查“已提供”的显式参数；交互收集结束后再检查证书分支完整性。
  if [ "$final" = 1 ]; then
    case "$CERT_MODE" in acme|manual) ;; *) err "证书模式须为 acme/manual"; errs=$((errs+1));; esac
    if [ "$CERT_MODE" = acme ]; then
      if { [ -n "$DYNU_CID" ] && [ -z "$DYNU_SECRET" ]; } || { [ -z "$DYNU_CID" ] && [ -n "$DYNU_SECRET" ]; }; then
        err "Dynu OAuth 凭证必须成对"; errs=$((errs+1))
      fi
      if [ -z "$DYNU_KEY" ] && [ -z "$DYNU_CID" ]; then
        err "acme 模式缺少 Dynu 凭证（API Key 或完整 OAuth）"; errs=$((errs+1))
      fi
    elif [ "$CERT_MODE" = manual ]; then
      if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
        err "manual 模式缺少证书或私钥路径"; errs=$((errs+1))
      elif [ ! -f "$CERT_FILE" ] || [ ! -r "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ] || [ ! -r "$KEY_FILE" ]; then
        err "manual 证书或私钥不存在/不可读"; errs=$((errs+1))
      fi
    fi
  fi
  # 初轮只校验已提供值；随机端口填充后 final=1 再次完整校验。
  if [ "$final" = 0 ] && [ "$errs" -gt 0 ]; then
    err "参数校验失败（$errs 项），已列出详情。修正后重试。"; exit 1
  fi

  # 端口范围校验（1-65535，整数）
  for p in SS_PORT ANYTLS_PORT SOCKS_PORT NAIVE_PORT PANEL_PORT; do
    port="${!p:-}"
    [ -n "$port" ] || continue
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      err "$p=$port 不合法（须 1-65535 整数）"; errs=$((errs+1))
    fi
  done

  # 端口冲突校验：四个可配端口互相不得重复，且不得占用 caddy/SSH 固定端口
  #   80=caddy HTTP 跳转，443=caddy :443 伪装站，25822=SSH 加固后端口（如启用）
  #   v1.5.10: --no-caddy 模式下 caddy 不监听 80/443，故不保留这两个端口（让用户可自由用）
  local sys_ports="25822"
  [ "$NO_CADDY" = 0 ] && sys_ports="80 443 25822"
  local conf_ports=()
  for p in SS_PORT ANYTLS_PORT SOCKS_PORT NAIVE_PORT PANEL_PORT; do
    port="${!p:-}"; [ -n "$port" ] || continue
    # 与系统固定端口冲突
    for s in $sys_ports; do
      if [ "$port" = "$s" ]; then err "$p=$port 与系统固定端口冲突（$s 为 caddy/SSH 保留）"; errs=$((errs+1)); fi
    done
    # 互相冲突
    local prev
    for prev in "${conf_ports[@]:-}"; do
      if [ "$port" = "$prev" ]; then err "$p=$port 与其它服务端口重复"; errs=$((errs+1)); fi
    done
    conf_ports+=("$port")
  done

  # Docker 容器内存限制（v1.5.36）：正整数 MB
  if [ -n "${DOCKER_MEM_IN:-}" ]; then
    if ! [[ "$DOCKER_MEM_IN" =~ ^[0-9]+$ ]] || [ "$DOCKER_MEM_IN" -lt 128 ] || [ "$DOCKER_MEM_IN" -gt 65536 ]; then
      err "--docker-mem=${DOCKER_MEM_IN} 不合法（须 128-65536 的整数，单位 MB）"
      errs=$((errs+1))
    fi
  fi

  # SS2022 密钥：base64 解码后必须恰好 16 字节（aes-128-gcm）
  if [ -n "$SS_PASSWORD" ]; then
    local n
    n=$(printf '%s' "$SS_PASSWORD" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    if [ "$n" != "16" ]; then
      err "--ss-password 不是合法的 2022-blake3-aes-128-gcm 密钥（base64 解码后须 16 字节，当前 $n 字节）"
      err "  生成命令: openssl rand -base64 16"
      errs=$((errs+1))
    fi
  fi

  # AnyTLS UUID：标准 v4 格式（大小写不敏感）
  if [ -n "$ANYTLS_UUID_IN" ]; then
    if ! [[ "$ANYTLS_UUID_IN" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      err "--anytls-uuid 格式错误（须标准 UUID 如 a1b2c3d4-e5f6-7890-abcd-ef1234567890）"
      errs=$((errs+1))
    fi
  fi

  # SOCKS5/NaiveProxy 用户名/密码：不含冒号和空白
  # 注：用平行数组而非 "val:flag" 拼接，避免值本身含冒号被截断
  local naive_vals=("$SOCKS_USER_IN" "$SOCKS_PASSWORD" "$NAIVE_USER_IN" "$NAIVE_PASSWORD")
  local naive_flags=("--socks-user" "--socks-password" "--naive-user" "--naive-password")
  local i
  for i in 0 1 2 3; do
    local val="${naive_vals[$i]}" flag="${naive_flags[$i]}"
    [ -n "$val" ] || continue
    if [[ "$val" == *:* ]] || [[ "$val" =~ [[:space:]] ]]; then
      err "$flag 含有非法字符（冒号或空白，caddy basic_auth 不支持）"; errs=$((errs+1))
    fi
  done

  # AnyTLS 密码：非空即可（与现有 Go 端一致，无格式约束）
  # NaiveProxy 已在上方校验

  # 面板密码：6-64 字符
  if [ -n "$PANEL_PASSWORD_IN" ]; then
    local pn=${#PANEL_PASSWORD_IN}
    if [ "$pn" -lt 6 ] || [ "$pn" -gt 64 ]; then
      err "--panel-password 长度须 6-64 字符（当前 ${pn}）"; errs=$((errs+1))
    fi
  fi

  # v1.6.0: 节点信息基础名（--panel-title）
  #   接受任意可读字符（含 $ ` \ " ' # 空格 中文 % 等）：Docker 侧经 PANEL_TITLE_ENCODED
  #   percent-encoding transport（见 docker_gen_ansgo_env / ansgo_pct_encode），裸金属
  #   仅 JSON 转义（ansgo_json_escape），无需拒绝特殊字符。
  #   仅限制：长度 1-64、拒绝控制字符（换行/制表破坏 env 行协议且无合法输入场景）。
  if [ -n "$PANEL_TITLE_IN" ]; then
    # 统一 trim 首尾空白（与生成函数同语义）；trim 后为空（纯空白标题）拒绝
    PANEL_TITLE_IN="$(printf '%s' "$PANEL_TITLE_IN" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "$PANEL_TITLE_IN" ]; then
      err "--panel-title 不能为纯空白（去除首尾空白后为空）"; errs=$((errs+1))
    fi
    local tn=${#PANEL_TITLE_IN}
    if [ "$tn" -lt 1 ] || [ "$tn" -gt 64 ]; then
      err "--panel-title 长度须 1-64 字符（当前 ${tn}）"; errs=$((errs+1))
    fi
    if [[ "$PANEL_TITLE_IN" =~ [[:cntrl:]] ]]; then
      err "--panel-title 含控制字符（换行/制表等），不允许"; errs=$((errs+1))
    fi
  fi

  # v1.6.0: 显式连接 IP（--server-ip）：严格 IPv4/IPv6 校验。
  #   ansgo_ip_check 优先 python3 ipaddress；python3 未装时（校验先于依赖安装）走
  #   shell 结构化兜底——拒绝 2001:::1 / ::: / 仅冒号 / 双:: 等非法文本，不崩溃。
  #   依赖段确保 python3 后安装流程会用 ipaddress 再复核一次。
  if [ -n "$SERVER_IP_IN" ]; then
    if ! ansgo_ip_check "$SERVER_IP_IN"; then
      err "--server-ip 格式错误（须 IPv4 如 203.0.113.7 或 IPv6 如 2001:db8::1）"; errs=$((errs+1))
    fi
  fi

  # 面板 URL 路径：/xxxx/ 形式
  if [ -n "$URL_PATH_IN" ]; then
    if ! [[ "$URL_PATH_IN" =~ ^/[A-Za-z0-9_-]+/$ ]]; then
      err "--panel-url-path 格式错误（须 /xxxx/ 形式，仅含字母数字 _ -）"; errs=$((errs+1))
    fi
  fi

  if [ "$errs" -gt 0 ]; then
    err "参数校验失败（$errs 项），已列出详情。修正后重试。"
    exit 1
  fi
}
# =============================================================================
# v1.6.0: 初始化生成函数（抽出为独立函数 + 路径参数化，便于离线测试覆盖；
#   与 Go 端 confPath var 测试覆盖同一模式。工具函数 ansgo_json_escape /
#   ansgo_pct_encode / ansgo_ip_check 已前移至参数校验段之前）
# =============================================================================
# 裸金属 panel.json 生成（$1=输出路径）。返回：0=成功生成；1=已存在（不动文件）；
#   2=失败（stderr 有原因，绝不让失败被吞成 0）。
#   Sentinel 修复：原子写——同目录临时文件 + python3 JSON 合法性校验 + chmod 0600 +
#   mv 原子替换；校验失败/写失败立即清理 tmp 并返回 2，不落地半成品/坏文件。
#   依赖环境变量：DOMAIN/PANEL_PORT/SS_*/... 与 --panel-title/--server-ip 的
#   PANEL_TITLE_IN/SERVER_IP_IN（trim 后为空走旧语义默认值）。
#   注意：heredoc JSON 结尾 } 带 2 空格缩进（合法 JSON），避免与函数提取的
#   顶格 } 结束约定冲突。
metal_ensure_panel_json(){
  local out="$1"
  [ -f "$out" ] && return 1
  local title_raw ip_raw URLPATH title_json ip_json tmp
  # 统一 trim 首尾空白（CLI 校验层同语义；纯空白=空=旧语义默认）
  title_raw="$(printf '%s' "${PANEL_TITLE_IN:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  ip_raw="$(printf '%s' "${SERVER_IP_IN:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$title_raw" ] || title_raw="ANS-GO 管理面板"
  URLPATH="${URL_PATH_IN:-/$(openssl rand -hex 4)/}"
  title_json="$(ansgo_json_escape "$title_raw")"
  ip_json="$(ansgo_json_escape "$ip_raw")"
  tmp="${out}.tmp.$$"
  if ! cat > "$tmp" <<EOF
{
  "domain": "$(ansgo_json_escape "$DOMAIN")",
  "panel_port": ${PANEL_PORT},
  "panel_title": "${title_json}",
  "url_path": "$(ansgo_json_escape "$URLPATH")",
  "admin_user": "$(ansgo_json_escape "$PANEL_USER")",
  "admin_pass_hash": "PLACEHOLDER",
  "session_hours": 8,
  "login_lock_threshold": 5,
  "login_lock_minutes": 10,
  "ss_port": ${SS_PORT},
  "ss_method": "2022-blake3-aes-128-gcm",
  "anytls_port": ${ANYTLS_PORT},
  "socks_port": ${SOCKS_PORT},
  "naive_port": ${NAIVE_PORT},
  "disguise_panel": "$(ansgo_json_escape "$DISGUISE_PANEL")",
  "disguise_naive": "$(ansgo_json_escape "$DISGUISE_NAIVE")",
  "svc_ss_enabled": "false",
  "svc_anytls_enabled": "false",
  "svc_socks_enabled": "false",
  "svc_naive_enabled": "false",
  "caddy_enable": "$([ "$NO_CADDY" = 1 ] && echo false || echo true)",
  "cert_mode": "$(ansgo_json_escape "$CERT_MODE")",
  "cert_dir": "/etc/ssl/ansgo",
  "cert_fullchain": "$(ansgo_json_escape "$CERT_FILE")",
  "cert_privkey": "$(ansgo_json_escape "$KEY_FILE")",
  "dynu_api_key": "$(ansgo_json_escape "$DYNU_KEY")",
  "dynu_client_id": "$(ansgo_json_escape "$DYNU_CID")",
  "dynu_secret": "$(ansgo_json_escape "$DYNU_SECRET")",
  "acme_email": "$(ansgo_json_escape "$EMAIL")",
  "db_path": "/etc/ansgo/sessions.db",
  "server_ip": "${ip_json}",
  "landings": [],
  "auto_upgrade": "false",
  "backup_keep": 5
  }
EOF
  then
    rm -f "$tmp" 2>/dev/null
    printf 'metal_ensure_panel_json: 写入临时文件失败（磁盘/权限）: %s\n' "$tmp" >&2
    return 2
  fi
  # JSON 合法性校验（python3 在依赖段已确保；缺失环境跳过校验但保留原子替换）
  if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'metal_ensure_panel_json: 生成的 JSON 校验失败（变量含非法值），中止\n' >&2
    return 2
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; printf 'metal_ensure_panel_json: chmod 失败: %s\n' "$tmp" >&2; return 2; }
  if ! mv -f "$tmp" "$out"; then
    rm -f "$tmp" 2>/dev/null
    printf 'metal_ensure_panel_json: 原子替换失败: %s\n' "$out" >&2
    return 2
  fi
  log "已生成 $out (url_path=${URLPATH})"
}

# Docker ansgo.env 生成（$1=输出路径；宿主侧凭证+端口+预指定密钥透传给容器 entrypoint）。
#   v1.6.0: 标题经 PANEL_TITLE_ENCODED percent-encoding 透传（ansgo_pct_encode）——
#   compose v2 对 env_file 做 $ 插值与 " #" 行内注释截断，明文特殊字符跨版本不安全；
#   ENCODED 键名自明编码语义（与「标题本身含 %」无歧义）。entrypoint 解码后写
#   panel.json 可读值。SERVER_IP_IN 经严格 IP 校验（值域 [0-9a-fA-F:.]）明文透传。
#   卷内已有 panel.json 时 entrypoint 不覆盖，以容器内实际为准。
docker_gen_ansgo_env(){
  local out="$1" _pw _up _title_enc
  # 取值优先级：显式 CLI 输入（PANEL_PASSWORD_IN/URL_PATH_IN）> 调用方已算好的值
  # （do_docker_deploy 的显示输出与 env 文件保持一致）> 随机（测试/独立调用路径）
  _pw="${PANEL_PASSWORD_IN:-${PANEL_PW:-}}"
  [ -n "$_pw" ] || _pw="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)"
  _up="${URL_PATH_IN:-${URL_PATH:-}}"
  [ -n "$_up" ] || _up="/$(openssl rand -hex 4)/"
  # 标题 percent-encode（transport 编码；entrypoint 解码后写可读值）。
  # 此函数仅在 Docker 部署路径调用，python3 已由依赖段确保。
  _title_enc="$(ansgo_pct_encode "$(printf '%s' "${PANEL_TITLE_IN:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")"
  cat > "$out" <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
PANEL_USER=${PANEL_USER}
PANEL_PASS=${_pw}
URL_PATH=${_up}
PANEL_PORT=${PANEL_PORT}
SS_PORT=${SS_PORT}
ANYTLS_PORT=${ANYTLS_PORT}
SOCKS_PORT=${SOCKS_PORT}
NAIVE_PORT=${NAIVE_PORT}
DISGUISE_PANEL=${DISGUISE_PANEL}
DISGUISE_NAIVE=${DISGUISE_NAIVE}
DYNU_API_KEY=${DYNU_KEY}
DYNU_CLIENT_ID=${DYNU_CID}
DYNU_SECRET=${DYNU_SECRET}
CERT_MODE=${CERT_MODE}
CERT_FULLCHAIN=${CERT_FILE}
CERT_PRIVKEY=${KEY_FILE}
SS_KEY_IN_ENCODED=$(ansgo_pct_encode "${SS_PASSWORD}")
ANYTLS_PASS_IN_ENCODED=$(ansgo_pct_encode "${ANYTLS_PASSWORD}")
ANYTLS_UUID_IN_ENCODED=$(ansgo_pct_encode "${ANYTLS_UUID_IN}")
SOCKS_USER_IN_ENCODED=$(ansgo_pct_encode "${SOCKS_USER_IN}")
SOCKS_PASS_IN_ENCODED=$(ansgo_pct_encode "${SOCKS_PASSWORD}")
NAIVE_USER_IN_ENCODED=$(ansgo_pct_encode "${NAIVE_USER_IN}")
NAIVE_PASS_IN_ENCODED=$(ansgo_pct_encode "${NAIVE_PASSWORD}")
PANEL_TITLE_ENCODED=${_title_enc}
SERVER_IP_IN=${SERVER_IP_IN}
NO_CADDY=${NO_CADDY}
EOF
}


# =============================================================================
# 随机端口填补（v1.5.12）
#   未通过 --ss-port/--anytls-port/--naive-port/--panel-port 指定的端口，
#   在 10000-65535 范围随机生成。避免以下端口：
#     - 80/443（caddy 固定端口，--no-caddy 模式下除外）
#     - 25822（SSH 加固后端口）
#     - 已被占用的端口（ss -tln 检测）
#     - 已为本部署其它服务选用的端口（互斥）
# =============================================================================
_rand_port_used=" "   # 本次部署已选端口（空格分隔），避免互相冲突
_sys_busy_ports(){ echo "25822"; [ "$NO_CADDY" = 0 ] && echo "80 443"; }
_listening_ports(){ ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' | sort -u; }
rand_port(){
  # 在 10000-65535 随机生成一个未冲突端口
  local busy sys_used p
  busy="$( { _listening_ports; echo "$_rand_port_used" | tr ' ' '\n'; } | sort -u )"
  sys_used="$(_sys_busy_ports)"
  while :; do
    p=$(( (RANDOM << 15 | RANDOM) % 55536 + 10000 ))  # 10000-65535
    # 跳过系统保留 / 已监听 / 本次已选
    { echo "$sys_used" | grep -x "$p" >/dev/null; } && continue
    { echo "$busy" | grep -x "$p" >/dev/null; } && continue
    echo "$p"; return
  done
}
# 仅在「安装/部署」场景下填补；卸载/落地/帮助场景跳过
fill_ports(){
  _rand_port_used=" $SS_PORT $ANYTLS_PORT $SOCKS_PORT $NAIVE_PORT $PANEL_PORT "
  [ -z "$SS_PORT" ]     && SS_PORT="$(rand_port)"     && _rand_port_used+="$SS_PORT "
  [ -z "$ANYTLS_PORT" ] && ANYTLS_PORT="$(rand_port)" && _rand_port_used+="$ANYTLS_PORT "
  [ -z "$SOCKS_PORT" ]  && SOCKS_PORT="$(rand_port)"  && _rand_port_used+="$SOCKS_PORT "
  [ -z "$NAIVE_PORT" ]  && NAIVE_PORT="$(rand_port)"  && _rand_port_used+="$NAIVE_PORT "
  [ -z "$PANEL_PORT" ]  && PANEL_PORT="$(rand_port)"  && _rand_port_used+="$PANEL_PORT "
}

# =============================================================================
# 卸载（apt purge 风格两级：默认保留配置/卷，--purge 彻底删除一切）
#   自动检测部署模式：Docker（/etc/ansgo-docker/）或裸金属（/etc/ansgo/）
# =============================================================================
ansgo_purge_images(){
  command -v docker >/dev/null || return 0
  local images image refs used
  images=$(docker image ls --no-trunc --format '{{.Repository}} {{.ID}}' |
    awk '$1=="ghcr.io/6667084/ansgo" || $1=="ghcr.io/jiasongji/ansgo" {ids[$2]=1}
         END {for (id in ids) print id}') || { warn "无法列出本项目镜像，请稍后手动检查"; return 0; }
  while read -r image; do
    [ -n "$image" ] || continue
    # 共用 ID 的其它仓库标签/摘要、其它容器的引用都必须保留。
    refs=$(docker image inspect --format '{{range .RepoTags}}{{println .}}{{end}}{{range .RepoDigests}}{{println .}}{{end}}' "$image") || continue
    if ! printf '%s\n' "$refs" | awk '
      {sub(/@.*/, ""); sub(/:[^\/]*$/, "");
       if ($0!="ghcr.io/6667084/ansgo" && $0!="ghcr.io/jiasongji/ansgo") bad=1}
      END {exit (NR==0 || bad)}'; then
      warn "保留其它仓库共用的镜像: $image"; continue
    fi
    used=$(docker ps -aq --filter "ancestor=$image") || continue
    if [ -n "$used" ]; then warn "保留其它容器仍引用的镜像: $image"; continue; fi
    docker image rm --force "$image" || warn "无法删除镜像，请手动检查: $image"
  done <<< "$images"
}
ansgo_tuning_content(){
  awk '!/^[[:space:]]*#/ {
    sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "");
    gsub(/[[:space:]]+/, " "); gsub(/ *= */, "="); if (length) print
  }' "$@" | LC_ALL=C sort
}
ansgo_purge_tuning(){
  local net_old net_current limits journal file content header expected net_changed=0 journal_changed=0
  # v1.5.x install.sh 的原始模板；旧 proxy 文件名也只按这些已知内容认领。
  net_old=$(ansgo_tuning_content <<'SYS'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_local_port_range = 10000 65535
SYS
)
  net_current=$(printf '%s\n' "$net_old" | grep -vE 'tcp_max_tw_buckets|ip_local_port_range')
  limits=$(ansgo_tuning_content <<'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
)
  journal=$(ansgo_tuning_content <<'JOU'
[Journal]
SystemMaxUse=50M
JOU
)
  for file in /etc/sysctl.d/99-ansgo-tune.conf /etc/sysctl.d/99-proxy-tune.conf \
      /etc/security/limits.d/99-ansgo.conf /etc/security/limits.d/99-proxy.conf \
      /etc/systemd/journald.conf.d/60-ansgo.conf /etc/systemd/journald.conf.d/size.conf; do
    [ -f "$file" ] || continue
    if [ -L "$file" ]; then warn "保留调优软链: $file"; continue; fi
    case "$file" in
      */sysctl.d/*) expected="$net_old";;
      */limits.d/*) expected="$limits";;
      *) expected="$journal";;
    esac
    header=$(sed -n '1,8p' "$file")
    content=$(ansgo_tuning_content "$file") || continue
    if printf '%s\n' "$header" | grep -E '^[[:space:]]*#[[:space:]]*(managed-by:[[:space:]]*ansgo|ANS-GO)([[:space:]]|$)' >/dev/null ||
       [ "$content" = "$expected" ] ||
       { [[ "$file" = */sysctl.d/* ]] && [ "$content" = "$net_current" ]; }; then
      rm -f "$file" || continue
      case "$file" in
        */sysctl.d/*) net_changed=1;;
        */journald.conf.d/*) journal_changed=1;;
      esac
    else
      warn "保留无法确认由本项目生成的调优文件: $file"
    fi
  done
  if [ "$net_changed" = 1 ]; then sysctl --system >/dev/null 2>&1 || true; fi
  if [ "$journal_changed" = 1 ]; then systemctl restart systemd-journald >/dev/null 2>&1 || true; fi
}
do_uninstall(){
  [ "$(id -u)" = 0 ] || { err "需 root 运行"; exit 1; }
  local PURGE="${PURGE:-0}"

  hr "ANS-GO 卸载（purge=${PURGE}）"

  # ---- 检测部署模式 ----
  local HAS_DOCKER=0 HAS_METAL=0
  [ -f /etc/ansgo-docker/docker-compose.yml ] && HAS_DOCKER=1
  { [ -f /etc/ansgo/panel.json ] || systemctl list-unit-files 2>/dev/null | grep -E 'ansgo-panel|sing-box|caddy' >/dev/null \
    || [ -x /usr/local/bin/ansgo-panel ]; } && HAS_METAL=1

  if [ "$HAS_DOCKER" = 0 ] && [ "$HAS_METAL" = 0 ]; then
    if [ "$PURGE" = 1 ] && { [ -d /etc/ansgo-backup ] || [ -d /var/lib/ansgo ] \
      || [ -d /var/log/ansgo ] || [ -f /etc/ansgo-cert.status ] \
      || [ -f /etc/sysctl.d/99-ansgo-tune.conf ] || [ -f /etc/sysctl.d/99-proxy-tune.conf ] \
      || [ -f /etc/security/limits.d/99-ansgo.conf ] || [ -f /etc/security/limits.d/99-proxy.conf ] \
      || [ -f /etc/systemd/journald.conf.d/60-ansgo.conf ] || [ -f /etc/systemd/journald.conf.d/size.conf ] \
      || compgen -G '/etc/ansgo-backup-*' >/dev/null; }; then
      warn "仅检测到备份/维护数据，将继续清除残留"
    else
      warn "未检测到 ANS-GO 部署痕迹（无 /etc/ansgo-docker、无 /etc/ansgo/、无 systemd unit）"
      warn "可能从未安装，或已卸载。退出。"
      exit 0
    fi
  fi

  echo "检测到的部署模式：$([ "$HAS_DOCKER" = 1 ] && echo 'Docker ')$([ "$HAS_METAL" = 1 ] && echo '裸金属')"
  if [ "$PURGE" = 1 ]; then
    warn "--purge 模式：将彻底删除全部配置/密钥/证书/数据卷/镜像/系统调优，不可恢复"
  else
    echo "默认模式：移除服务/容器/二进制，保留配置/卷（可重装不丢参数）"
    echo "如需彻底删除一切，用: bash install.sh --uninstall --purge"
  fi
  printf "确认卸载？输入 yes: " >&2
  a="$(readtty)"
  [ "$a" = yes ] || { echo "已取消"; exit 0; }

  # ---- Docker 模式卸载 ----
  if [ "$HAS_DOCKER" = 1 ]; then
    # 兼手清理：不论 compose 文件在不在，都强制删同名容器（避免 compose down 遗漏残留）
    docker rm -f ansgo 2>/dev/null || true
    if command -v docker >/dev/null 2>&1 && [ -f /etc/ansgo-docker/docker-compose.yml ]; then
      log "[Docker] 停止并删除容器..."
      ( cd /etc/ansgo-docker && docker compose down --remove-orphans 2>/dev/null \
        || docker-compose down 2>/dev/null || true )
      # 再次兑底：compose down 可能因 project 名不一致而遗漏
      docker rm -f ansgo 2>/dev/null || true
      if [ "$PURGE" = 1 ]; then
        log "[Docker] 删除数据卷（配置/密钥/证书/acme/日常备份）..."
        ( cd /etc/ansgo-docker && docker compose down -v --remove-orphans 2>/dev/null \
          || docker-compose down -v 2>/dev/null || true )
        # 兑底删除可能残留的卷（compose project 名不同时）；按名称模式匹配，
        # 覆盖 ansgo_* / ansgo-docker_ansgo_* / 自定义 project 名的卷
        docker volume ls --format '{{.Name}}' 2>/dev/null \
          | grep -iE 'ansgo_(etc|ssl|caddy|sb|acme|backup)$|_ansgo_(etc|ssl|caddy|sb|acme|backup)$' \
          | xargs -r docker volume rm 2>/dev/null || true
      fi
    else
      warn "[Docker] docker 命令缺失或 compose 文件不在，已尝试手动清理容器"
      [ "$PURGE" = 1 ] && docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep -iE 'ansgo_(etc|ssl|caddy|sb|acme|backup)$|_ansgo_(etc|ssl|caddy|sb|acme|backup)$' \
        | xargs -r docker volume rm 2>/dev/null || true
    fi
    if [ "$PURGE" = 1 ]; then
      log "[Docker] 按仓库精确清理全部版本镜像..."
      ansgo_purge_images
      rm -rf /etc/ansgo-docker
      log "[Docker] 已删除 /etc/ansgo-docker/（含 ansgo.env + compose）"
    else
      warn "[Docker] 保留 /etc/ansgo-docker/（含凭证，重装可复用）"
    fi
  fi

  # ---- 裸金属模式卸载 ----
  if [ "$HAS_METAL" = 1 ]; then
    log "[裸金属] 停止并禁用服务..."
    systemctl disable --now ansgo-autoupgrade.timer 2>/dev/null || true
    for s in ansgo-panel caddy sing-box; do
      systemctl stop "$s" 2>/dev/null || true
      systemctl disable "$s" 2>/dev/null || true
      rm -f "/etc/systemd/system/$s.service"
      rm -f "/etc/systemd/system/multi-user.target.wants/$s.service"
    done
    systemctl daemon-reload 2>/dev/null || true
    log "[裸金属] 移除管理二进制 + 脚本..."
    rm -f /usr/local/bin/ansgo-panel /usr/local/bin/ansgo-admin \
          /usr/local/bin/ansgo-genconf /usr/local/bin/ansgo-cert-reload \
          /usr/local/bin/ansgo-cert-issue.sh /usr/local/bin/ansgo-sync-manual-cert \
          /usr/local/bin/ansgo-landing.sh /usr/local/bin/dns_dynukey.sh
    if [ "$PURGE" = 1 ]; then
      log "[裸金属] --purge：移除代理二进制 + 配置/密钥/证书/备份/调优..."
      rm -f /usr/local/bin/sing-box /usr/local/bin/caddy
      rm -rf /etc/ansgo /etc/ssl/ansgo /etc/sing-box /etc/caddy /var/www/html
      rm -rf /root/.acme.sh /etc/ansgo-deploy
      rm -rf /etc/systemd/system/ansgo-panel.service.d \
             /etc/systemd/system/caddy.service.d \
             /etc/systemd/system/sing-box.service.d
      rm -f /etc/systemd/system/ansgo-autoupgrade.service \
            /etc/systemd/system/ansgo-autoupgrade.timer \
            /usr/local/bin/ansgo-limits /usr/local/bin/ansgo-upgrade
      log "[裸金属] 配置/密钥/证书/备份/调优已彻底删除"
    else
      log "[裸金属] 配置保留在 /etc/ansgo/ /etc/ssl/ansgo/（--purge 可彻底删）"
    fi
  fi

  if [ "$PURGE" = 1 ]; then
    ansgo_purge_tuning
    rm -rf /etc/ansgo-backup /etc/ansgo-backup-* /etc/ansgo-uninstall-backup-* \
           /var/lib/ansgo /var/log/ansgo
    rm -f /etc/ansgo-cert.status
    # 旧日志路径的兼容软链（ansgo-limits 的 ansgo_logs_init 创建）
    for f in /root/ansgo-cert-issue.log /var/log/ansgo-cert.log /var/log/ansgo-genconf.log; do
      if [ -L "$f" ]; then rm -f "$f"; fi
    done
  fi
  hr "卸载完成（purge=${PURGE}）"
  [ "$PURGE" = 0 ] && echo "提示：彻底删除一切请重跑  bash install.sh --uninstall --purge"
  echo "注：未卸载 docker 本体（可能被其他服务使用）；如需卸载 docker 请手动执行。"
  exit 0
}

# ---- 卸载子命令（在交互收集前拦截，避免无谓的域名/凭证提问）----
if [ "${UNINSTALL:-0}" = 1 ]; then do_uninstall; exit 0; fi

# ---- landing 子命令：在落地机一键部署 ss-server ----
# 注：首次执行时 /etc/ansgo-deploy/ansgo-landing.sh 尚未下载，需先从仓库拉取
do_landing(){
  [ "$(id -u)" = 0 ] || { err "需 root 运行"; exit 1; }
  WORK=$(mktemp -d) || exit 1
  mkdir -p /etc/ansgo-deploy
  local LSCRIPT=/etc/ansgo-deploy/ansgo-landing.sh
  if [ ! -f "$LSCRIPT" ]; then
    log "下载 ansgo-landing.sh ..."
    if command -v curl >/dev/null; then curl -fsSL "$RAW/ansgo-landing.sh" -o "$WORK/landing"
    else wget -qO "$WORK/landing" "$RAW/ansgo-landing.sh"; fi
    install -m 755 "$WORK/landing" "$LSCRIPT" || exit 3
    [ -s "$LSCRIPT" ] || { err "下载 ansgo-landing.sh 失败（$RAW/ansgo-landing.sh）"; exit 3; }
    chmod 0755 "$LSCRIPT"
  fi
  # 透传 --landing 之后剩余的参数（--port / --non-interactive 等）
  bash "$LSCRIPT" "${LANDING_ARGS[@]}"
  exit $?
}
if [ "${LANDING:-0}" = 1 ]; then do_landing; exit 0; fi

# ---- 交互收集 ----
ask(){ # prompt default -> 读入到 ASK_VAL
  local p="$1" d="${2:-}" v
  if [ "${NONINT:-0}" = 1 ]; then ASK_VAL="$d"; return; fi
  if [ -n "$d" ]; then printf "%s [%s]: " "$p" "$d" >&2
  else printf "%s: " "$p" >&2; fi
  v="$(readtty)"
  ASK_VAL="${v:-$d}"
}
ask_req(){ # prompt ; NONINT 下为空则报错
  ask "$1" "${2:-}"; [ -n "$ASK_VAL" ] || { err "$1 必填（非交互模式请用参数传入）"; exit 2; }
}

# =============================================================================
# Docker 一体化部署（all-in-one 容器，KVM / 资源充足主机推荐）
#   一个容器跑全部服务（caddy :443 伪装 + sing-box 按需 + ansgo-panel），
#   容器内 systemd 作 PID 1，复用裸金属全部 unit/脚本/面板代码（0 改动）。
#   配置/密钥/证书在容器内首次生成，持久化到 docker volume。
# =============================================================================
do_docker_deploy(){
  hr "Docker 一体化部署（all-in-one 容器）"
  command -v docker >/dev/null 2>&1 || { log "安装 docker ..."; curl -fsSL https://get.docker.com | sh; }
  ansgo_compose_check "$WORK/docker-compose.yml" || exit 8
  log "使用 compose 命令: $COMPOSE"

  # host 网络端口冲突预警（v1.5.10: --no-caddy 模式下 80/443 不再预警，由 nginx 等接管）
  WARN_PORTS="$PANEL_PORT"
  [ "$NO_CADDY" = 0 ] && WARN_PORTS="80 443 $PANEL_PORT"
  for p in $WARN_PORTS; do
    if command -v ss >/dev/null && ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":$p$" >/dev/null; then
      warn "端口 $p 已被占用，host 网络下容器可能启动失败，请先停掉占用进程"
    fi
  done

  local DIR=/etc/ansgo-docker
  mkdir -p "$DIR" || { err "无法创建 $DIR"; exit 1; }

  # 随机面板密码 + URL 路径（仅首次部署生效；卷已存在时以容器内实际为准）
  # v1.5.5: 支持 --panel-password / --panel-url-path 指定
  local PANEL_PW URL_PATH
  PANEL_PW="${PANEL_PASSWORD_IN:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}"
  URL_PATH="${URL_PATH_IN:-/$(openssl rand -hex 4)/}"

  # ansgo.env：凭证 + 端口 + 用户预指定密钥（600 权限，敏感不入 git）
  # 注：代理服务密钥（SS_KEY_IN 等）用 _IN 后缀避免与容器内同名变量冲突；
  #     entrypoint.sh 用 ${VAR:-随机} 接收，留空则在容器内随机生成。
  #     v1.6.0: 抽出为 docker_gen_ansgo_env 函数 + 新增 PANEL_TITLE_IN/SERVER_IP_IN 透传。
  docker_gen_ansgo_env "$DIR/ansgo.env" || { err "生成 $DIR/ansgo.env 失败（磁盘满或目录不可写），已中止部署"; exit 1; }
  chmod 600 "$DIR/ansgo.env" || { err "无法设置 $DIR/ansgo.env 权限"; exit 1; }
  log "已生成 $DIR/ansgo.env（含凭证，权限 600）"

  cp "$WORK/docker-compose.yml" "$DIR/docker-compose.yml" || exit 1

  # ---- v1.5.36: 按宿主内存收紧容器资源约束 ----
  #   模板默认 mem_limit=512m / memswap_limit=768m（适配 >1G 宿主）。
  #   小内存宿主（≤1G）若无限制，泄漏/失控会拖垮整机（用户实测 464M VPS 长跑卡死
  #   只能强制重启）。规则（与生产实测调优一致：464M 宿主 → 约 320m/576m）：
  #     --docker-mem 显式指定 > 优先；否则 宿主 ≤1G → MemTotal*70%；>1G → 512m
  #   memswap_limit 始终 = mem_limit + 256m（swap 缓冲防过早 OOM）。
  #   常驻仅 50-105MiB，限制值有 3-5 倍余量；顶到限时容器内 OOM，
  #   restart: unless-stopped 自动重启自愈，宿主整机不受影响。
  local COMPOSE_MEM COMPOSE_MEMSWAP _mem_total_mb
  _mem_total_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  if [ -n "$DOCKER_MEM_IN" ]; then
    COMPOSE_MEM="${DOCKER_MEM_IN}m"
    COMPOSE_MEMSWAP="$(( DOCKER_MEM_IN + 256 ))m"
  elif [ -n "$_mem_total_mb" ] && [ "$_mem_total_mb" -le 1024 ] 2>/dev/null; then
    COMPOSE_MEM="$(( _mem_total_mb * 70 / 100 ))m"
    COMPOSE_MEMSWAP="$(( _mem_total_mb * 70 / 100 + 256 ))m"
  else
    COMPOSE_MEM="512m"; COMPOSE_MEMSWAP="768m"
  fi
  sed -i "s/^    mem_limit: .*/    mem_limit: ${COMPOSE_MEM}/; s/^    memswap_limit: .*/    memswap_limit: ${COMPOSE_MEMSWAP}/" \
    "$DIR/docker-compose.yml" \
    && log "容器资源约束: mem_limit=${COMPOSE_MEM} memswap_limit=${COMPOSE_MEMSWAP}$([ -n "$_mem_total_mb" ] && echo "（宿主内存 ${_mem_total_mb}MB）" || echo "")" \
    || warn "docker-compose.yml 资源约束注入失败（模板结构变化？容器将以模板默认值运行）"

  # v1.5.32: Docker 手动证书改为「固定同步目录」模型。
  #   compose 已固定挂载 /etc/ansgo-docker/manual-certs -> /host/manual-certs（只读），
  #   不再为 cert/key 原目录动态注入 bind mount（旧方案对 Let's Encrypt live->archive
  #   symlink、宝塔 600 目录权限都不稳）。首次部署时直接把 CLI 提供的证书复制进同步目录。
  mkdir -p "$DIR/manual-certs"
  chmod 700 "$DIR/manual-certs"
  if [ "$CERT_MODE" = "manual" ] && [ -n "$CERT_FILE" ] && [ -n "$KEY_FILE" ]; then
    if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ]; then
      install -m 0644 "$CERT_FILE" "$DIR/manual-certs/fullchain.pem"
      install -m 0600 "$KEY_FILE"  "$DIR/manual-certs/privkey.pem"
      log "manual 证书模式：已把证书复制到固定同步目录 $DIR/manual-certs/（容器启动自动同步到 /etc/ssl/ansgo）"
      log "  续期后操作：在面板「证书管理」复制「系统自动任务一键安装」或「宝塔计划任务脚本」到宿主执行"
    else
      warn "manual 证书模式：证书/私钥文件不存在或为空，跳过初始复制（容器内将用自签占位，请在面板补填宿主真实路径）"
    fi
  fi

  cd "$DIR" || exit 1

  # 拉镜像：优先 compose pull；失败再用 docker pull 兜底（绕过 compose 自身问题）
  #   使用与脚本一致的固定版本镜像，--ver 不回退到浮动 latest
  IMG="ghcr.io/${REPO%/*}/ansgo:${VER}"
  sed -i "s#image: ghcr.io/6667084/ansgo:.*#image: ${IMG}#" "$DIR/docker-compose.yml"
  ansgo_compose_check "$DIR/docker-compose.yml" || exit 8
  if ! $COMPOSE pull 2>&1 | tail -5; then
    warn "$COMPOSE pull 失败，尝试直接 docker pull $IMG 兜底"
    if ! docker pull "$IMG" 2>&1 | tail -10; then
      err "docker pull $IMG 失败（网络问题？）。可手动："
      err "  1. docker pull $IMG（检查错误）"
      err "  2. 或回退本地构建：git clone https://github.com/${REPO} && docker build -f deploy/Dockerfile.allinone ."
      exit 6
    fi
    log "docker pull 成功（绕过 compose 问题）"
  fi

  $COMPOSE up -d && log "容器已启动" || { err "$COMPOSE up 失败"; exit 7; }
  local ready=0 i
  for i in $(seq 1 180); do
    if docker exec ansgo grep -q '^SUCCESS' /etc/ansgo-cert.status 2>/dev/null &&
       docker exec ansgo systemctl is-active --quiet ansgo-panel 2>/dev/null &&
       docker exec ansgo python3 -c 'import json,ssl,urllib.request;c=json.load(open("/etc/ansgo/panel.json"));urllib.request.urlopen("https://127.0.0.1:%s%sapi/auth"%(c["panel_port"],c["url_path"]),context=ssl._create_unverified_context(),timeout=3)' 2>/dev/null; then
      ready=1; break
    fi
    if docker exec ansgo grep -q '^FAILED' /etc/ansgo-cert.status 2>/dev/null; then break; fi
    sleep 2
  done
  [ "$ready" = 1 ] || { err "证书签发或面板启动失败：docker logs ansgo；docker exec ansgo cat /var/log/ansgo/cert-issue.log"; exit 1; }

  # 读取容器内实际 url_path（卷已存在时可能与此处生成的不一致）
  local ACTUAL_PATH
  ACTUAL_PATH=$(docker exec ansgo python3 -c 'import json;print(json.load(open("/etc/ansgo/panel.json")).get("url_path","/"))' 2>/dev/null || echo "$URL_PATH")

  hr "部署完成"
  cat <<EOF

╔═══════════════════════════════════════════════════════════════╗
║  ✅ ANS-GO 一体化部署完成（Docker / KVM）
╠═══════════════════════════════════════════════════════════════╣
║
║  ⚠️  本次部署端口均为随机生成，请立即记录！
║  ─────────────────────────────────────────────────
║
║  Web 面板:   https://${DOMAIN}:${PANEL_PORT}${ACTUAL_PATH}
║  用户名:     ${PANEL_USER}
║  密码(首次): ${PANEL_PW}
║
║  ──────── 代理服务端口（登录面板后启用） ────────
║   • Shadowsocks : ${SS_PORT}
║   • AnyTLS      : ${ANYTLS_PORT}
║   • SOCKS5      : ${SOCKS_PORT}
║   • NaiveProxy  : ${NAIVE_PORT}
║   • 管理面板    : ${PANEL_PORT}
║
╠═══════════════════════════════════════════════════════════════╣
║  ⚠️ 证书: $([ "$CERT_MODE" = "manual" ] && echo "手动模式（${CERT_FILE}），无需后台签发" || echo "Let's Encrypt 签发成功")
║  管理命令:
║     cd ${DIR} && $COMPOSE logs -f ansgo   # 查日志/签证书进度
║     docker exec -it ansgo ansgo-admin status         # 服务状态
║     docker exec -it ansgo ansgo-admin info           # 节点连接参数
║     docker exec -it ansgo ansgo-admin panel-pass     # 找回面板密码
║     docker exec -it ansgo ansgo-admin restart panel  # 恢复面板
║     以上 Docker 命令在宿主机执行；若改过容器名请替换 ansgo。
║  下一步: 登录面板 →「服务管理」页按需开启代理服务
╚═══════════════════════════════════════════════════════════════╝
EOF
  log "代理服务默认未启动，请在面板「服务管理」页按需开启。"
  exit 0
}

hr "ANS-GO 一键部署"

# ---- 交互式主菜单（仅在交互模式且未通过参数指定动作时显示）----
# 设计：用户 bash <(curl ...) 无参数进入时，先让其选择 安装/卸载/彻底卸载/落地。
#   参数式调用（--uninstall/--purge/--landing/--non-interactive 或任意部署参数）跳过菜单。
if [ "${NONINT:-0}" = 0 ] && [ -z "${DOMAIN:-}" ] && [ -c /dev/tty ]; then
  printf "\n请选择操作：\n"
  printf "  1) 安装 / 部署管理面板（默认）\n"
  printf "  2) 卸载（移除服务/容器/二进制，保留配置/卷，可重装不丢参数）\n"
  printf "  3) 彻底卸载（删除配置/密钥/证书/卷/镜像/调优，不可恢复）\n"
  printf "  4) 部署落地服务器（独立 ss-server，供中转机第二组接入）\n"
  printf "请选择 [1]: " >&2
  _choice="$(readtty)"
  case "$_choice" in
    2) UNINSTALL=1; PURGE=0; do_uninstall; exit 0;;
    3) UNINSTALL=1; PURGE=1; do_uninstall; exit 0;;
    4) LANDING=1;;
    ""|1|*) ;;  # 继续部署流程
  esac
  unset _choice
fi

# 菜单选了落地（或 --landing 参数）→ 进入落地部署
if [ "${LANDING:-0}" = 1 ]; then do_landing; exit 0; fi

# ---- 环境校验 ----
if ! grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null; then warn "未检测到 Debian/Ubuntu，继续但可能需手动装依赖"; fi
# ---- 交互式收集缺失项 ----
if [ -z "$DOMAIN" ]; then ask_req "域名（已解析到本机）"; DOMAIN="$ASK_VAL"; fi
[ -n "$DOMAIN" ] || { err "域名必填"; exit 2; }
EMAIL="${EMAIL:-admin@${DOMAIN}}"
# 未知证书模式留给统一校验拒绝，不能静默改回 acme。
if [ "$CERT_MODE" = "manual" ]; then
  # manual 模式：必须提供证书+私钥路径
  if [ -z "$CERT_FILE" ]; then ask_req "证书文件完整路径（fullchain）"; CERT_FILE="$ASK_VAL"; fi
  if [ -z "$KEY_FILE" ];  then ask_req "私钥文件完整路径（privkey）"; KEY_FILE="$ASK_VAL"; fi
  inf "证书来源：手动模式（跳过 Dynu / acme 签发）"
elif [ "$CERT_MODE" = "acme" ]; then
  # acme 模式：需要 Dynu 凭证。Sentinel 修复：缺 API Key 且无完整 OAuth 对时明确中止——
  #   裸金属没有自签占位证书路径，无凭证签发必败且面板 TLS 全挂，不允许静默继续。
  #   交互：API Key 必填（推荐），留空则要求完整 OAuth Client ID+Secret（兼容旧部署）。
  #   CLI：--dynu-key 或 --dynu-client-id + --dynu-secret（完整对）。
  if [ -z "$DYNU_KEY" ] && [ -z "$DYNU_CID" ] && [ -z "$DYNU_SECRET" ]; then
    inf "acme 自动签发需要 Dynu API Key；已有完整 OAuth Client ID + Secret 的部署请用参数传入"
    ask_req "Dynu API Key（必填）"; DYNU_KEY="$ASK_VAL"
  fi
fi
if [ "$NONINT" = 0 ]; then
  ask "Shadowsocks 端口（回车=随机）" "$SS_PORT"; SS_PORT="${ASK_VAL:-$SS_PORT}"
  ask "AnyTLS 端口（回车=随机）" "$ANYTLS_PORT"; ANYTLS_PORT="${ASK_VAL:-$ANYTLS_PORT}"
  ask "SOCKS5 端口（回车=随机）" "$SOCKS_PORT"; SOCKS_PORT="${ASK_VAL:-$SOCKS_PORT}"
  ask "NaiveProxy 端口（回车=随机）" "$NAIVE_PORT"; NAIVE_PORT="${ASK_VAL:-$NAIVE_PORT}"
  ask "面板端口（回车=随机）" "$PANEL_PORT"; PANEL_PORT="${ASK_VAL:-$PANEL_PORT}"
  ask "面板管理员用户名" "$PANEL_USER"; PANEL_USER="${ASK_VAL:-$PANEL_USER}"
  ask "直访伪装 :443 (proxy:<URL> 或 page)" "$DISGUISE_PANEL"; DISGUISE_PANEL="${ASK_VAL:-$DISGUISE_PANEL}"
  ask "Naive伪装 (代理端口, proxy:<URL> 或 page)" "$DISGUISE_NAIVE"; DISGUISE_NAIVE="${ASK_VAL:-$DISGUISE_NAIVE}"
  # v1.5.10: 检测 80/443 占用，提示是否跳过 caddy（适配已有 nginx 的服务器）
  if [ "$NO_CADDY" = 0 ] && command -v ss >/dev/null 2>&1; then
    PORT_BUSY=""
    for p in 80 443; do
      ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":$p$" >/dev/null && PORT_BUSY="$PORT_BUSY $p"
    done
    if [ -n "$PORT_BUSY" ]; then
      warn "检测到端口$PORT_BUSY 已被占用（可能已有 nginx/Caddy/宝塔等 web 服务器）"
      ask "是否跳过 caddy 部署让现有 web 服务器接管 80/443？(y/n)" "y"
      [ "${ASK_VAL:-y}" = "y" ] && NO_CADDY=1
    fi
  fi
fi
VALIDATE_PORTS_ONLY=1 validate_inputs
fill_ports
validate_inputs
[ "$(id -u)" = 0 ] || { err "需 root 运行"; exit 1; }
if [ "$DOCKER" = 0 ] && command -v caddy >/dev/null &&
   ! caddy list-modules 2>/dev/null | grep -F 'http.handlers.forward_proxy' >/dev/null; then
  warn "检测到非 ANS-GO Caddy（缺 forward_proxy），安装将替换它，请先备份其配置"
  if [ "$NONINT" = 0 ]; then
    ask "确认替换既有 Caddy？(yes/no)" no
    [ "$ASK_VAL" = yes ] || exit 1
  fi
fi
echo "----------------------------------------"
printf "  域名        : %s\n" "$DOMAIN"
printf "  ⚠️ 端口（随机生成，请记下）：\n"
printf "    ss=%s anytls=%s naive=%s panel=%s\n" "$SS_PORT" "$ANYTLS_PORT" "$NAIVE_PORT" "$PANEL_PORT"
printf "  直访伪装   : %s\n" "$DISGUISE_PANEL"
printf "  Naive伪装  : %s\n" "$DISGUISE_NAIVE"
[ -n "$PANEL_TITLE_IN" ] && printf "  节点信息   : %s\n" "$PANEL_TITLE_IN"
[ -n "$SERVER_IP_IN" ] && printf "  连接 IP    : %s\n" "$SERVER_IP_IN"
if [ "$CERT_MODE" = "manual" ]; then
  printf "  证书来源    : 手动（%s）\n" "$CERT_FILE"
else
  printf "  证书来源    : acme（Dynu %s）\n" "$([ -n "$DYNU_KEY" ] && echo "API Key 已配置" || echo "OAuth 已配置")"
fi
printf "  面板模式    : %s\n" "$([ "$DOCKER" = 1 ] && echo Docker || echo 裸金属)"
[ "$NO_CADDY" = 1 ] && printf "  caddy       : 跳过（--no-caddy，不监听 80/443，让现有 web 服务器接管）\n"
echo "----------------------------------------"
if [ "$NONINT" = 0 ]; then
  printf "确认开始部署？[Y/n] " >&2
  c="$(readtty)"
  [ "${c:-Y}" = "Y" ] || [ "${c:-Y}" = "y" ] || { warn "已取消"; exit 0; }
fi

WORK=$(mktemp -d) || exit 1
ansgo_preflight_assets || { err "必需远端资产预检失败，未修改宿主，请检查下载源和版本"; exit 3; }

# 输入收集、资产预检和确认均已完成，才允许安装依赖及修改宿主。
APT_READY=1
if ! command -v curl >/dev/null || ! command -v python3 >/dev/null || ! command -v openssl >/dev/null ||
   ! command -v ss >/dev/null || ! command -v crontab >/dev/null; then
  apt-get update && apt-get install -y --no-install-recommends curl ca-certificates python3 openssl iproute2 cron || exit 1
fi
command -v timeout >/dev/null || { err "缺少 coreutils timeout"; exit 1; }
# 拒绝首次安装抢占既有监听（已部署重跑的端口由持久配置负责）。
if [ ! -f /etc/ansgo/panel.json ] && [ ! -f /etc/ansgo-docker/docker-compose.yml ]; then
  for p in "$SS_PORT" "$ANYTLS_PORT" "$SOCKS_PORT" "$NAIVE_PORT" "$PANEL_PORT"; do
    if _listening_ports | grep -x "$p" >/dev/null; then err "端口 $p 已被监听，请换端口"; exit 1; fi
  done
fi
if [ "$CERT_MODE" = manual ]; then
  openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null || { err "证书无效或已过期"; exit 1; }
  cmod=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl sha256) || exit 1
  kmod=$(openssl pkey -in "$KEY_FILE" -pubout | openssl sha256) || exit 1
  [ "$cmod" = "$kmod" ] || { err "证书与私钥不匹配"; exit 1; }
fi
mkdir -p /usr/local/bin
BIN_STAGE=$(mktemp -d /usr/local/bin/.ansgo-install.XXXXXX) || exit 1
dl_or_exit "$RAW/ansgo-limits" "$BIN_STAGE/ansgo-limits"
bash -n "$BIN_STAGE/ansgo-limits" || exit 1
install -m 755 "$BIN_STAGE/ansgo-limits" /usr/local/bin/ansgo-limits || exit 1
source /usr/local/bin/ansgo-limits
ansgo_logs_init || exit 1
ansgo_tune || exit 1

# ---- Docker 一体化分流（KVM 主机推荐）：容器内跑全部服务，这里完成后即退出 ----
if [ "$DOCKER" = 1 ]; then
  do_docker_deploy
fi

hr "1/8 下载部署脚本（本仓库 raw）"
mkdir -p /etc/ansgo /etc/ansgo-deploy
for f in ansgo-admin ansgo-genconf ansgo-cert-reload ansgo-cert-issue.sh ansgo-sync-manual-cert ansgo-landing.sh dns_dynukey.sh; do
  log "下载 $f"; dl_or_exit "$RAW/$f" "$WORK/$f"
  bash -n "$WORK/$f" || exit 1
  install -m 0755 "$WORK/$f" "/etc/ansgo-deploy/$f" || exit 1
  install -m 0755 "$WORK/$f" "/usr/local/bin/$f" || exit 1
done
install -m 0755 /etc/ansgo-deploy/ansgo-admin       /usr/local/bin/ansgo-admin
install -m 0755 /etc/ansgo-deploy/ansgo-genconf     /usr/local/bin/ansgo-genconf
install -m 0755 /etc/ansgo-deploy/ansgo-cert-reload /usr/local/bin/ansgo-cert-reload

hr "2/8 确保 sing-box / caddy(naive) 就位"
mkdir -p /etc/sing-box /etc/caddy /var/www/html
SB_VER="1.13.13"
if [ "$FORCE_BIN" = 1 ] || ! command -v sing-box >/dev/null; then
  if ! dl "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${AARCH}.tar.gz" "$WORK/sb.tgz"; then
    dl_or_exit "$REL/$VER/sing-box-linux-${AARCH}.tar.gz" "$WORK/sb.tgz"
  fi
  mkdir "$WORK/sb"
  tar xzf "$WORK/sb.tgz" -C "$WORK/sb" || exit 3
  SB_SRC=$(find "$WORK/sb" -type f -name sing-box)
  [ -n "$SB_SRC" ] && [ -f "$SB_SRC" ] || exit 3
  install -m 0755 "$SB_SRC" "$BIN_STAGE/sing-box" || exit 3
  "$BIN_STAGE/sing-box" version >/dev/null || exit 3
  mv "$BIN_STAGE/sing-box" /usr/local/bin/sing-box || exit 3
fi
if [ "$FORCE_BIN" = 1 ] || ! command -v caddy >/dev/null || ! caddy list-modules 2>/dev/null | grep -F 'http.handlers.forward_proxy' >/dev/null; then
  if ! dl "$REL/$VER/caddy-naive-linux-${AARCH}" "$BIN_STAGE/caddy"; then
    if ! dl "$REL/v1.5.16/caddy-naive-linux-${AARCH}" "$BIN_STAGE/caddy"; then
      avail_mb=$(df -m / | awk 'NR==2{print $4}')
      [ "$avail_mb" -ge 1500 ] || { err "xcaddy 编译需要至少 1500MB 空闲磁盘，请使用预编译资产"; exit 3; }
      [ "$(ansgo_memory_mb)" -ge 768 ] || { err "内存不足 768MB，拒绝现场编译；请提供 caddy-naive 预编译资产"; exit 3; }
      command -v git >/dev/null || { apt-get update && apt-get install -y --no-install-recommends git; } || exit 3
      # 工具链、源码、所有缓存仅属于本次临时目录，不接管宿主 Go。
      BUILD=$(mktemp -d "$WORK/caddy-naive-build.XXXXXX") || exit 3
      GO_BIN="$(command -v go || true)"
      if [ -n "$GO_BIN" ]; then
        _go_v="$("$GO_BIN" version 2>/dev/null | awk 'match($0,/go[0-9]+\.[0-9]+/){s=substr($0,RSTART+2,RLENGTH-2);split(s,a,".");print a[1],a[2];exit}')"
        read -r GO_MAJOR GO_MINOR <<< "$_go_v"
        if [ "${GO_MAJOR:-0}" -lt 1 ] ||
           { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 21 ]; } ||
           { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -eq 21 ] && [ ! -f "$(dirname "$(dirname "$GO_BIN")")/go.env" ]; }; then
          warn "宿主 Go $("$GO_BIN" version 2>/dev/null) 未知或不兼容，改用到临时目录的 Go 工具链"
          GO_BIN=""
        fi
      fi
      if [ -z "$GO_BIN" ]; then
        dl_or_exit "https://go.dev/dl/go1.26.0.linux-${AARCH}.tar.gz" "$BUILD/go.tgz"
        tar xzf "$BUILD/go.tgz" -C "$BUILD" || exit 3
        GO_BIN="$BUILD/go/bin/go"
      fi
      (
        export PATH="$(dirname "$GO_BIN"):$PATH"
        export GOPATH="$BUILD/gopath" GOCACHE="$BUILD/gocache" GOMODCACHE="$BUILD/gomodcache" GOFLAGS=-p=1 GOMAXPROCS=1
        cd "$BUILD" || exit 1
        nice -n 10 "$GO_BIN" install github.com/caddyserver/xcaddy/cmd/xcaddy@latest &&
        git clone -b naive --depth 1 https://github.com/klzgrad/forwardproxy.git "$BUILD/fp" &&
        CGO_ENABLED=0 nice -n 10 "$GOPATH/bin/xcaddy" build \
          --with "github.com/caddyserver/forwardproxy=$BUILD/fp" --output "$BIN_STAGE/caddy"
      ) || { err "xcaddy 编译失败；宿主 Go 未修改"; exit 3; }
      rm -rf "$BUILD"
    fi
  fi
  chmod 755 "$BIN_STAGE/caddy" || exit 3
  "$BIN_STAGE/caddy" list-modules | grep -F 'http.handlers.forward_proxy' >/dev/null || { err "Caddy 资产缺少 forward_proxy"; exit 3; }
  mv "$BIN_STAGE/caddy" /usr/local/bin/caddy || exit 3
fi

hr "3/8 生成协议密钥 + 面板配置"
# secrets.env（如已存在则保留，避免覆盖现网密钥）
# v1.5.5: 支持用户通过 --ss-password / --anytls-password / --anytls-uuid
#         / --naive-user / --naive-password 预先指定密钥；未指定的随机生成。
if [ ! -f /etc/ansgo/secrets.env ]; then
  # 用 ${VAR:-默认} 模式：用户值优先，留空则随机
  cat > /etc/ansgo/secrets.env <<EOF
SS_METHOD=2022-blake3-aes-128-gcm
SS_KEY=${SS_PASSWORD:-$(openssl rand -base64 16)}
ANYTLS_PASS=${ANYTLS_PASSWORD:-$(openssl rand -hex 16)}
ANYTLS_UUID=${ANYTLS_UUID_IN:-$(cat /proc/sys/kernel/random/uuid)}
SOCKS_USER=${SOCKS_USER_IN:-$(openssl rand -hex 6)}
SOCKS_PASS=${SOCKS_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}
NAIVE_USER=${NAIVE_USER_IN:-$(openssl rand -hex 6)}
NAIVE_PASS=${NAIVE_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}
EOF
  log "已生成 /etc/ansgo/secrets.env"
  # 提示哪些字段用了用户提供的值（不会打印值本身，仅提示字段名）
  [ -n "$SS_PASSWORD$ANYTLS_PASSWORD$ANYTLS_UUID_IN$SOCKS_USER_IN$SOCKS_PASSWORD$NAIVE_USER_IN$NAIVE_PASSWORD" ] && \
    inf "  其中部分密钥由 CLI 参数指定（详见各 --xxx-password 参数）"
else warn "/etc/ansgo/secrets.env 已存在，保留现有密钥"; fi
chmod 600 /etc/ansgo/secrets.env

# panel.json（端口/设置/域名/伪装）
# v1.5.5: URL 路径支持 --panel-url-path 指定，否则随机（函数内实现）
# v1.6.0: 抽出为 metal_ensure_panel_json（可离线测试 + JSON 转义防御）；
#   新增 --panel-title（节点信息）与 --server-ip（显式连接 IP）字段，留空保持旧语义；
#   已有文件一律保留不覆盖（端口/伪装/节点信息以现有为准）。
if [ -f /etc/ansgo/panel.json ]; then
  warn "/etc/ansgo/panel.json 已存在，保留（端口/伪装/节点信息以现有为准）"
elif ! metal_ensure_panel_json /etc/ansgo/panel.json; then
  # Sentinel 修复：生成失败（写盘/JSON 校验）必须中止安装，不允许把失败当已存在继续
  err "panel.json 生成失败（见上方错误），中止安装"
  exit 3
fi
chmod 600 /etc/ansgo/panel.json

mkdir -p /etc/ssl/ansgo
if [ "$CERT_MODE" = "manual" ]; then
  hr "4/8 使用手动指定证书（跳过 acme 签发）"
  # 二次校验文件存在且可读（交互阶段已校验，此处幂等兜底）
  [ -f "$CERT_FILE" ] || { err "证书文件不存在: $CERT_FILE"; exit 2; }
  [ -f "$KEY_FILE" ]  || { err "私钥文件不存在: $KEY_FILE"; exit 2; }
  log "✅ 手动证书模式："
  log "   证书: $CERT_FILE"
  log "   私钥: $KEY_FILE"
  log "   （面板/caddy/sing-box 将直接引用上述绝对路径，不再走 /etc/ssl/ansgo/）"
  # 不复制到 /etc/ssl/ansgo，保留用户原位置；续期由用户自行管理
  echo "SUCCESS manual-mode (cert=$CERT_FILE key=$KEY_FILE)" > /etc/ansgo-cert.status
else
  hr "4/8 签发 Let's Encrypt 证书（DNS-01，A 默认 / B 降级）"
  # acme.sh 来源：优先本仓库 vendored 快照，回退官方
  ACME_TARBALL=""
  if dl "$REL/$VER/acme.sh-master.tar.gz" "$WORK/acme.tar.gz" 2>/dev/null; then ACME_TARBALL="$WORK/acme.tar.gz"; log "使用本仓库 vendored acme.sh"; fi
  export DOMAIN EMAIL ACME_TARBALL
  export DYNU_API_KEY="$DYNU_KEY" DYNU_CLIENT_ID="$DYNU_CID" DYNU_SECRET="$DYNU_SECRET"
  # v1.5.36: 先清掉旧 status 文件再启动签发。轮询以「文件出现」为完成信号，
  #   旧部署残留的 SUCCESS/FAILED 会让首次轮询立即误判（假成功/假失败）。
  #   ansgo-cert-issue.sh 开头也会自清（双保险，防旧版脚本被复用）。
  rm -f /etc/ansgo-cert.status
  log "签发中…（总超时 300 秒，日志 /var/log/ansgo/cert-issue.log）"
  ansgo_log_trim /var/log/ansgo/cert-issue.log
  # 脚本自行用 300 秒 timeout + setsid 终止整个进程组；调用方不再套第二层 timeout，
  # 否则外层先终止父脚本时会留下独立会话中的 acme 子进程。
  if bash /etc/ansgo-deploy/ansgo-cert-issue.sh >/dev/null 2>&1; then
    log "证书签发完成"
  else
    err "证书签发失败或超时，详见 /var/log/ansgo/cert-issue.log"
    # 仅旧的有效证书允许继续，新部署无证书必须退出。
    if ! openssl x509 -in /etc/ssl/ansgo/fullchain.pem -noout -checkend 0 >/dev/null 2>&1; then
      err "没有有效 TLS 证书，部署中止。检查 Dynu 权限、DNS 和签发日志后重试。"
      exit 1
    fi
  fi
fi

hr "5/8 生成配置（代理服务默认关闭，面板内按需安装）"
# 初始化占位配置（genconf 已自建父目录，v1.5.4）。失败不阻塞部署——
# 代理服务本就是面板内按需安装，占位配置缺失不影响面板/caddy 起来。
ansgo_log_trim /var/log/ansgo/genconf.log
ansgo-genconf all >> /var/log/ansgo/genconf.log 2>&1 || { err "配置生成失败，见 /var/log/ansgo/genconf.log"; exit 1; }

hr "6/8 部署 systemd unit + 启动面板与伪装站"
# sing-box / caddy 的 unit（面板安装服务时会 enable）
for s in sing-box caddy; do
  if [ ! -f /etc/systemd/system/$s.service ]; then
    dl_or_exit "$RAW/systemd/$s.service" "$WORK/$s.service"
    install -m 644 "$WORK/$s.service" "/etc/systemd/system/$s.service" || exit 1
  fi
done
ansgo_limits || exit 1
systemctl daemon-reload
# caddy 启动（:443 伪装站 + :80 跳转 是域名直访体验的一部分，随面板一起起来）
# v1.5.10: --no-caddy 模式下不启动 caddy（让现有 nginx 等 web 服务器接管 80/443）。
#   caddy 二进制和 unit 仍安装（面板后续装 naive 时可手动 enable/restart caddy 只听 naive 端口）。
if [ "$NO_CADDY" = 1 ]; then
  log "跳过 caddy 启动（--no-caddy 模式；80/443 由现有 web 服务器接管）"
else
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl reset-failed caddy 2>/dev/null || true
  systemctl restart caddy \
    && log "caddy 已启动（:443 伪装站）" \
    || { err "caddy 启动失败（域名直访伪装站不可用；代理服务不受影响）"; err "  排查: journalctl -u caddy -n 30 / caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"; exit 1; }
fi
# sing-box 暂不启动（无代理服务安装前不需要）

hr "7/8 部署 Web 管理面板"
log "下载 ansgo-panel 二进制 (from release)"
dl_or_exit "$REL/$VER/ansgo-panel-linux-${AARCH}" "$BIN_STAGE/ansgo-panel"
chmod 0755 "$BIN_STAGE/ansgo-panel" || exit 3
ansgo_verify_elf "$BIN_STAGE/ansgo-panel" "$AARCH" "$VER" || { err "面板二进制架构或版本校验失败"; exit 3; }
# 新文件位于目标同文件系统，避免覆盖正在运行的二进制。
mv "$BIN_STAGE/ansgo-panel" /usr/local/bin/ansgo-panel || exit 3
dl_or_exit "$RAW/ansgo-panel.service" "$WORK/ansgo-panel.service"
install -m 644 "$WORK/ansgo-panel.service" /etc/systemd/system/ansgo-panel.service || exit 1
dl_or_exit "$RAW/upgrade.sh" "$WORK/ansgo-upgrade"
install -m 755 "$WORK/ansgo-upgrade" /usr/local/bin/ansgo-upgrade || exit 1
for f in ansgo-autoupgrade.service ansgo-autoupgrade.timer; do
  dl_or_exit "$RAW/systemd/$f" "$WORK/$f"
  install -m 644 "$WORK/$f" "/etc/systemd/system/$f" || exit 1
done
# timer 默认不 enable；由用户在面板明确开启。
ansgo_limits || exit 1
systemctl daemon-reload
# 设置管理员密码（bcrypt 写入 panel.json，打印明文仅一次）
# v1.5.5: 支持 --panel-password 指定，否则随机
PANEL_PW="${PANEL_PASSWORD_IN:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c 1-20)}"
/usr/local/bin/ansgo-panel -setpass "$PANEL_PW" || { err "管理员密码设置失败"; exit 1; }
systemctl enable ansgo-panel >/dev/null 2>&1 || true
systemctl reset-failed ansgo-panel 2>/dev/null || true
systemctl restart ansgo-panel || exit 1
sleep 2
systemctl is-active --quiet ansgo-panel || { err "面板未运行，检查 journalctl -u ansgo-panel"; exit 1; }
URL_PATH=$(python3 -c 'import json;print(json.load(open("/etc/ansgo/panel.json"))["url_path"])')
curl --noproxy "*" -kfsS --retry 3 --retry-connrefused --max-time 5 "https://127.0.0.1:$PANEL_PORT${URL_PATH}api/auth" >/dev/null || { err "面板 TLS 验证失败"; exit 1; }

# ---- 输出最终信息 ----
hr "部署完成"
URL_PATH=$(python3 -c "import json;print(json.load(open('/etc/ansgo/panel.json'))['url_path'])" 2>/dev/null)
cat <<EOF

╔═══════════════════════════════════════════════════════════════╗
║  ✅ ANS-GO 管理面板部署完成
╠═══════════════════════════════════════════════════════════════╣
║
║  ⚠️  本次部署端口均为随机生成，请立即记录！
║  ─────────────────────────────────────────────────
║
║  Web 面板:   https://${DOMAIN}:${PANEL_PORT}${URL_PATH:-/}
║  用户名:     ${PANEL_USER}
║  密码(仅此一次): ${PANEL_PW}
║
║  ──────── 代理服务端口（登录面板后启用） ────────
║   • Shadowsocks : ${SS_PORT}
║   • AnyTLS      : ${ANYTLS_PORT}
║   • SOCKS5      : ${SOCKS_PORT}
║   • NaiveProxy  : ${NAIVE_PORT}
║   • 管理面板    : ${PANEL_PORT}
║
╠═══════════════════════════════════════════════════════════════╣
║  下一步：登录面板 →「服务管理」页，按需安装代理服务
║  落地服务：每个落地独立 AnyTLS 入站，可选 SS / SOCKS5 远端出口
╚═══════════════════════════════════════════════════════════════╝
EOF
log "代理服务未启动，请在面板「服务管理」页按需开启。"
