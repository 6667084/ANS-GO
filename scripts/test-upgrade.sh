#!/usr/bin/env bash
# 离线验证二进制边界和运行版本识别，不调用真实 systemctl 或网络。
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
extract_fn(){
  awk -v fn="$2" '
    !f && index($0,fn"(){")==1 {f=1}
    f {print}
    f && /^\}$/ {exit}
  ' "$1"
}
eval "$(extract_fn "$PROJECT/install.sh" ansgo_verify_elf)"
eval "$(extract_fn "$PROJECT/deploy/upgrade.sh" verify_elf)"
eval "$(extract_fn "$PROJECT/deploy/upgrade.sh" current_version)"
python3 - "$TMP" <<'PY'
import pathlib,struct,sys
root=pathlib.Path(sys.argv[1])
h=bytearray(20);h[:6]=b'\x7fELF\x02\x01';h[18:20]=struct.pack('<H',62)
for name,body in [('trimpath',b'prefix1.6.0\0'),('buildinfo',b'main.version=1.6.0'),
                  ('comment',b'// v1.6.0 UI history\n'),('wrong',b'1.5.37\0')]:
    (root/name).write_bytes(h+body)
PY
AARCH=amd64
for name in trimpath buildinfo; do
  ansgo_verify_elf "$TMP/$name" amd64 v1.6.0
  verify_elf "$TMP/$name" v1.6.0
done
for name in comment wrong; do
  if ansgo_verify_elf "$TMP/$name" amd64 v1.6.0 2>/dev/null; then exit 1; fi
  if verify_elf "$TMP/$name" v1.6.0 2>/dev/null; then exit 1; fi
done
if ansgo_verify_elf "$TMP/trimpath" arm64 v1.6.0 2>/dev/null; then exit 1; fi
echo 'PASS ELF: trimpath 与 buildinfo 版本、拒绝历史注释/错误版本/架构'
printf '{"panel_port":15608,"url_path":"/example/"}\n' > "$TMP/panel.json"
MODE=metal
curl(){ printf '{"version":"1.5.37"}\n'; }
[ "$(current_version "$TMP/panel.json")" = v1.5.37 ]
curl(){ return 1; }
systemctl(){ printf 'fixture-invocation\n'; }
journalctl(){
  [ "$1" = '_SYSTEMD_INVOCATION_ID=fixture-invocation' ] || return 1
  printf 'ansgo-panel v1.5.36 监听 https://example/\n'
}
[ "$(current_version "$TMP/panel.json" 2>/dev/null)" = v1.5.36 ]
journalctl(){ printf '无法读取版本\n'; }
if current_version "$TMP/panel.json" >/dev/null 2>&1; then exit 1; fi
echo 'PASS current_version: API 版本、本次 invocation 兜底、未知版本拒绝升级'
python3 - "$PROJECT" "$TMP" <<'PY'
import json,pathlib,re,shutil,subprocess,sys
project,tmp=map(pathlib.Path,sys.argv[1:])
script=(project/'deploy/upgrade.sh').read_text()
marker='  python3 - "$STAGE/compose.yml" "$VER" <<\'PY\'\n'
patch=script.split(marker,1)[1].split('\nPY\n',1)[0]
mem=tmp/'meminfo';mem.write_text('MemTotal: 262144 kB\n')
patch=patch.replace("'/proc/meminfo'",repr(str(mem)))
template='''services:
  ansgo:
    image: ghcr.io/6667084/ansgo:latest
    mem_limit: 134217728
    environment:
      EXAMPLE: a$$b
    logging:
      driver: json-file
      options: {}
    volumes:
      - type: bind
        source: /example
        target: /etc/ansgo
  other:
    image: example:keep
    mem_limit: 67108864
'''
for driver in ('json-file','journald'):
    p=tmp/(driver+'.yml');p.write_text(template.replace('driver: json-file','driver: '+driver))
    subprocess.run([sys.executable,'-',str(p),'v1.6.0'],input=patch,text=True,check=True)
    text=p.read_text()
    assert text.count('    mem_limit:')==2 and 'mem_limit: 134217728' in text
    for token in ('memswap_limit: 402653184','pids_limit: 512','cpu_shares: 512',
                  'cpus: 1.0','ansgo:v1.6.0','image: example:keep','EXAMPLE: a$$b'):
        assert token in text,token
    if driver=='json-file': assert 'max-size: "10m"' in text and 'max-file: "3"' in text
    if shutil.which('docker') and subprocess.run(['docker','compose','version'],capture_output=True).returncode==0:
        result=subprocess.check_output(['docker','compose','-f',str(p),'config','--format','json'],text=True)
        cfg=json.loads(result);c=cfg['services']['ansgo']
        assert int(c['mem_limit'])==134217728 and int(c['memswap_limit'])==402653184
        # compose config 的输出会重新转义美元符号，供下一次读取保留字面量。
        assert c['environment']['EXAMPLE']=='a$$b'
        assert int(cfg['services']['other']['mem_limit'])==67108864
print('PASS compose: 各约束独立补齐、空 options、用户日志驱动/内存保留、美元符号保真')
PY
echo 'ALL UPGRADE TESTS PASSED'
