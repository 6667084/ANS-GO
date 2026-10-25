#!/usr/bin/env bash
# 临时根目录隔离运行 CLI，只触发帮助和缺参数分支。
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ANSGO_ROOT="$TMP" ANSGO_LIB="$PROJECT/deploy/ansgo-limits"
for mode in metal docker marker; do
  export ANSGO_DOCKER=0
  prefix=""
  if [ "$mode" = docker ]; then export ANSGO_DOCKER=1; fi
  if [ "$mode" = marker ]; then touch "$TMP/.dockerenv"; fi
  if [ "$mode" != metal ]; then prefix="docker exec -it ansgo "; fi
  bash "$PROJECT/deploy/ansgo-admin" --help > "$TMP/help"
  MODE="$mode" PREFIX="$prefix" python3 - "$TMP/help" <<'PY'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert '用法: '+os.environ['PREFIX']+'ansgo-admin <子命令>' in text, text
assert ('若改过容器名' in text) == (os.environ['MODE'] != 'metal'), text
PY
  for command in stop regen regen-landing 'firewall open' 'firewall close' 'firewall invalid' 'update panel' 'update invalid' 'cert invalid'; do
    # 这些固定参数故意按空格拆分，均在操作系统或配置文件之前返回用法。
    bash "$PROJECT/deploy/ansgo-admin" $command > "$TMP/usage" 2>&1 || true
    PREFIX="$prefix" python3 - "$TMP/usage" <<'PY'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert '用法: '+os.environ['PREFIX']+'ansgo-admin ' in text, text
PY
  done
  echo "PASS admin hints: $mode 帮助与全部 9 个用法分支"
done
python3 - "$PROJECT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ('deploy/docker/entrypoint.sh', 'install.sh'):
    text = (root/name).read_text()
    assert 'docker exec -it ansgo ansgo-admin panel-pass' in text, name
    assert '若改过容器名' in text, name
assert 'docker exec -it ansgo ansgo-admin restart panel' in (root/'install.sh').read_text()
print('PASS Docker 引导: entrypoint 与安装横幅包含宿主密码找回提示')
PY
