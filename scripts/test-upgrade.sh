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
eval "$(extract_fn "$PROJECT/deploy/upgrade.sh" write_result)"
python3 - "$TMP" <<'PY'
import pathlib,struct,sys
root=pathlib.Path(sys.argv[1])
h=bytearray(20);h[:6]=b'\x7fELF\x02\x01';h[18:20]=struct.pack('<H',62)
for name,body in [('trimpath',b'prefix1.6.1\0'),('buildinfo',b'main.version=1.6.1'),
                  ('comment',b'// v1.6.1 UI history\n'),('wrong',b'1.5.37\0')]:
    (root/name).write_bytes(h+body)
PY
AARCH=amd64
for name in trimpath buildinfo; do
  ansgo_verify_elf "$TMP/$name" amd64 v1.6.1
  verify_elf "$TMP/$name" v1.6.1
done
for name in comment wrong; do
  if ansgo_verify_elf "$TMP/$name" amd64 v1.6.1 2>/dev/null; then exit 1; fi
  if verify_elf "$TMP/$name" v1.6.1 2>/dev/null; then exit 1; fi
done
if ansgo_verify_elf "$TMP/trimpath" arm64 v1.6.1 2>/dev/null; then exit 1; fi
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
python3 - "$PROJECT" "$TMP" <<'PYDOCKER'
import json, os, pathlib, re, shutil, subprocess, sys, tarfile
project, tmp = map(pathlib.Path, sys.argv[1:])
script = (project/'deploy/upgrade.sh').read_text()
def fn(name):
    return re.search(r'^'+name+r'\(\).*?^}', script, re.M|re.S)[0]
# 清单首项即命中，后续输出远超管道缓冲区，重复验证不会因 SIGPIPE 随机失败。
archive = tmp/'large-backup.tar.gz'
with tarfile.open(archive, 'w:gz') as tar:
    for name in ['files/etc/ansgo/panel.json'] + [
            'files/padding/%05d-' % i+'x'*120 for i in range(6000)]:
        tar.addfile(tarfile.TarInfo(name))
backup_check = next(line.strip() for line in fn('docker_backup').splitlines() if 'tar tzf "$BACKUP"' in line)
check = 'BACKUP="$1"\nfor i in {1..20}; do\n'+backup_check+'\ndone'
subprocess.run(['bash','-euo','pipefail','-c',check,'_',str(archive)],check=True)
missing_archive = tmp/'missing-backup.tar.gz'
with tarfile.open(missing_archive, 'w:gz') as tar: tar.addfile(tarfile.TarInfo('unrelated'))
assert subprocess.run(['bash','-euo','pipefail','-c','BACKUP="$1"\n'+backup_check,
                       '_',str(missing_archive)],capture_output=True).returncode != 0
upstream_error = 'tar(){ command tar "$@"; return 7; }\nBACKUP="$1"\n'+backup_check
assert subprocess.run(['bash','-euo','pipefail','-c',upstream_error,'_',str(archive)],
                      capture_output=True).returncode == 7
module_dir = tmp/'modules'; module_dir.mkdir()
caddy = module_dir/'caddy'
caddy.write_text('#!/usr/bin/env python3\nimport sys\n'
                 'sys.stdout.write("http.handlers.forward_proxy\\n"+("other.module\\n"*100000))\n')
caddy.chmod(0o755)
module_check = next(line.strip() for line in script.splitlines() if '"$STAGE/caddy" list-modules |' in line)
subprocess.run(['bash','-euo','pipefail','-c','STAGE="$1"\nfor i in {1..20}; do\n'+
                module_check+'\ndone','_',str(module_dir)],check=True)
for name in ('install.sh','deploy/upgrade.sh','deploy/ansgo-admin','deploy/ansgo-limits','deploy/docker/entrypoint.sh'):
    text = (project/name).read_text().replace('\\\n','')
    for line in text.splitlines():
        if line.lstrip().startswith('#'): continue
        assert not re.search(r'\|\s*(?:head\b|grep\b[^|;]*\s-[^\s]*q)', line), (name,line)
admin = (project/'deploy/ansgo-admin').read_text()
generators = '\n'.join(re.search(r'^'+name+r'\(\).*$',admin,re.M)[0]
                       for name in ('gen_naive_pass','gen_socks_pass','gen_panel_pass'))
random_check = generators + r'''
openssl(){ python3 -c 'print("a"*1048576)'; }
for name in gen_naive_pass gen_socks_pass gen_panel_pass; do
  value=$("$name")
  case "$name" in gen_panel_pass) [ "${#value}" = 22 ];; *) [ "${#value}" = 20 ];; esac
done
'''
subprocess.run(['bash','-euo','pipefail','-c',random_check],check=True)
print('PASS pipefail: 大备份清单/模块清单各 20 次无 SIGPIPE，缺项和上游失败仍拒绝，密码截取读完输入')
# 同一可执行夹具模拟 Docker/Compose 和 df；所有写入均在临时目录。
bin_dir = tmp/'fake-bin'
bin_dir.mkdir()
fake = bin_dir/'docker'
fake.write_text(r'''#!/usr/bin/env python3
import io, json, os, pathlib, sys, tarfile
root = pathlib.Path(os.environ['TEST_DOCKER_ROOT'])
p = root/'state.json'
s = json.loads(p.read_text())
a = sys.argv[1:]
def save(): p.write_text(json.dumps(s))
def out(value): print(value)
def event(name):
    s['events'].append(name); save()
def image(ref):
    return next((x for x in s['images'] if ref == x['id'] or ref in x['tags']), None)
if pathlib.Path(sys.argv[0]).name == 'df':
    assert a == ['-Pk', str(root/'docker-data')], a
    event('df')
    out('Filesystem 1024-blocks Used Available Capacity Mounted on')
    out('fixture 4000000 0 %s 0%% /fixture' % (s['available']//1024))
    sys.exit(0)
event(' '.join(a))
if a[0] == 'compose':
    if 'config' in a:
        assert '--quiet' in a or a[-2:] == ['--format', 'json'], a
        if '--quiet' in a:
            if s.get('invalid_compose') and s['stage']+'/compose.yml' in a: sys.exit(9)
        else:
            # 含敏感环境的解析结果只能经 stdout 留在内存，不得落为 compose 文件。
            out(json.dumps({'services': {'ansgo': s['config']}}))
    elif 'ps' in a: out('fixture-cid')
    elif 'up' in a:
        if '--pull' in a:
            assert s['old'] in [x['id'] for x in s['images']]
            s['current'] = s['old']; event('rollback')
        elif s.get('fail_up'): sys.exit(12)
        else: s['current'] = s['target']; s['available'] = s['post_available']; save()
    elif 'stop' not in a: raise AssertionError(a)
elif a[0] == 'info': out(root/'docker-data')
elif a[0] == 'inspect':
    if '{{.Image}}' in a: out(s['current'])
    elif '{{.Config.Image}}' in a: out('ghcr.io/6667084/ansgo:v1.5.37')
    elif any('.HostConfig.' in x for x in a):
        if s.get('fail_inspect'): sys.exit(13)
        out('335544320 603979776 512 512 '+json.dumps({'Type':'json-file','Config':{'max-size':'10m','max-file':'3'}}))
    else: out(json.dumps([{'Image': s['current'], 'Mounts': [
        {'Destination':'/etc/ansgo','Type':'volume','Name':'fixture_etc','Source':'/fixture'}]}]))
elif a[:2] == ['image', 'inspect']:
    x = image(a[-1])
    if not x: sys.exit(1)
    if any('RepoTags' in v for v in a): out(json.dumps(dict(tags=x['tags'],digests=x.get('digests',[]))))
    else: out(x['size'] if '{{.Size}}' in a else x['id'])
elif a[:2] == ['image', 'ls']:
    for x in s['images']:
        for tag in x['tags']: out(tag.rsplit(':',1)[0]+' '+x['id'])
elif a[:2] == ['image', 'rm']:
    assert len(a) == 4 and a[2] == '--force' and a[3].startswith('sha256:'), a
    x = image(a[3]); assert x and x['id'] != s['current'], a
    assert all(t.rsplit(':',1)[0] in ('ghcr.io/6667084/ansgo','ghcr.io/jiasongji/ansgo') for t in x['tags']), a
    assert not x.get('in_use'), a
    s['images'].remove(x); s['available'] += x.get('reclaim', x['size']); save()
elif a[0] == 'ps':
    x = image(a[-1].split('=',1)[1])
    if x and (x.get('in_use') or x['id'] == s['current']): out('fixture-other-container')
elif a[0] == 'pull':
    if s.get('fail_pull'): sys.exit(14)
    if not image(a[1]):
        s['images'].append(dict(id=s['target'],tags=[a[1]],size=410*1024**2)); save()
elif a[0] == 'exec':
    if a[2] == 'cat': out('v1.6.1')
    elif a[2:4] == ['bash','-c'] and 'curl --noproxy' in a[4] and s.get('fail_http'): sys.exit(15)
elif a[0] == 'cp': pass
elif a[0] == 'run':
    if '-i' in a:
        assert s['old'] in [x['id'] for x in s['images']]
        sys.stdin.buffer.read()
    else:
        with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as tar:
            for name, data in [('panel.json',b'{"backup_keep":5}'),('secrets.env',b'EXAMPLE=fixture-secret\n')]:
                entry=tarfile.TarInfo(name); entry.size=len(data); tar.addfile(entry,io.BytesIO(data))
else: raise AssertionError(a)
''')
fake.chmod(0o755)
(bin_dir/'df').symlink_to(fake)
M = 1024**2
ids = {name: 'sha256:'+ch*64 for name, ch in [('old','a'),('target','b'),('early','c'),('legacy','d'),('foreign','e'),('shared','f')]}
def record(name, repo='ghcr.io/6667084/ansgo', **extra):
    return dict(id=ids[name], tags=[repo+':'+('v1.5.37' if name=='old' else name)],size=410*M,**extra)
template = '''# 用户原文应保留
services:
  other:
    image: example:keep
    mem_limit: 64m
  ansgo:
    # 自定义资源，不可覆盖
    image: ghcr.io/6667084/ansgo:latest # 镜像注释
    mem_limit: 320m # 用户调优
    env_file:
      - ansgo.env # 凭据留在独立文件
    environment:
      EXAMPLE: a$$b
    logging: # 日志注释
      driver: json-file
      # 日志参数注释
      options: {} # 空映射
    volumes:
      # 保留 gai 挂载
      - /etc/gai.conf:/etc/gai.conf:ro
      - fixture_etc:/etc/ansgo
  after:
    image: example:after
volumes:
  fixture_etc:
'''
functions = '\n'.join(fn(n) for n in ['docker_prepare_compose','docker_available_bytes','docker_old_images','docker_remove_image',
    'docker_check_space','docker_cleanup_images','docker_backup','docker_rollback','upgrade_docker','write_result','finish'])
real_compose = shutil.which('docker')
if real_compose and subprocess.run([real_compose,'compose','version'],capture_output=True).returncode:
    real_compose = None

def run(name, *, available=1500*M, post=800*M, extras=(), local_target=False,
        fail='', text=template, config=None, mode=0o644, real_config=False, cert_mode='acme',
        expected_mem=320*M):
    root = tmp/name; root.mkdir()
    docker_dir = root/'project'; docker_dir.mkdir()
    compose = docker_dir/'docker-compose.yml'; compose.write_text(text); compose.chmod(mode)
    (docker_dir/'ansgo.env').write_text('PANEL_PASS=fixture-panel-unique\nDYNU_API_KEY=fixture-dynu-unique\nCERT_MODE='+cert_mode+'\n')
    stage = root/'stage'; stage.mkdir()
    (stage/'ansgo-limits').write_text('# fixture\n')
    mem = root/'meminfo'; mem.write_text('MemTotal: 475136 kB\n')
    images = [record('old'), record('foreign','example/other'), *extras]
    if local_target: images.append(dict(id=ids['target'],tags=['ghcr.io/6667084/ansgo:v1.6.1'],size=410*M))
    cfg = config if config is not None else dict(mem_limit=320*M, environment={
        'PANEL_PASS':'fixture-panel-unique','DYNU_API_KEY':'fixture-dynu-unique','CERT_MODE':cert_mode,'EXAMPLE':'a$b'},
        logging=dict(driver='json-file',options={}),volumes=[dict(target='/etc/ansgo'),dict(target='/etc/gai.conf')])
    state = dict(images=images, current=ids['old'], old=ids['old'], target=ids['target'],
                 available=available, post_available=post, events=[], config=cfg,stage=str(stage))
    if fail: state[fail] = True
    (root/'state.json').write_text(json.dumps(state))
    code = functions.replace("'/proc/meminfo'",repr(str(mem))).replace('/etc/ansgo-backup',str(root/'backups'))
    if real_config:
        code = code.replace('docker_prepare_compose(){', 'docker_prepare_compose(){\n  local -a COMPOSE=("$REAL_DOCKER" compose)')
    setup = r'''
STAGE="$1/stage"; DOCKER_DIR="$1/project"; COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"
COMPOSE=(docker compose); VER=v1.6.1; RAW=fixture; MODE=docker; AUTO=0
MUTATED=0; DONE=0; DOCKER_PAUSED=0; METAL_PAUSED=0; BACKUP=''
RESULT="$1/result"; LOG="$1/log"; TASK_ID=fixture; TASK_STARTED=1
say(){ printf '%s\n' "$*"; }
trim_log(){ :; }
dl(){ printf '# fixture\n' > "$2"; }
'''
    result = subprocess.run(['bash','-Eeuo','pipefail','-c',code+'\n'+setup+
                             '\ntrap finish EXIT\nupgrade_docker\nDONE=1','_',str(root)],
        env={**os.environ,'PATH':str(bin_dir)+os.pathsep+os.environ['PATH'],
             'TEST_DOCKER_ROOT':str(root),'REAL_DOCKER':real_compose or ''},
        capture_output=True,text=True,errors='replace')
    state = json.loads((root/'state.json').read_text())
    if fail or name in ('no-space','unreclaimable','shared-layers'):
        assert result.returncode != 0, (name,result.stdout,result.stderr)
        assert '磁盘空间不足' in result.stdout or fail, (name,result.stdout,result.stderr)
        assert compose.read_text() == text and compose.stat().st_mode & 0o777 == mode
        assert state['current'] == ids['old']
    else:
        assert result.returncode == 0, (name,result.stdout,result.stderr)
        updated = compose.read_text()
        assert 'env_file:' in updated and 'ansgo.env # 凭据留在独立文件' in updated
        for token in ['# 用户原文应保留','# 自定义资源，不可覆盖','# 镜像注释',
                      '# 用户调优','# 日志注释','# 日志参数注释','# 空映射','# 保留 gai 挂载',
                      '/etc/gai.conf:/etc/gai.conf:ro','mem_limit: 320m','EXAMPLE: a$$b',
                      'memswap_limit: '+str(expected_mem+256*M),'pids_limit: 512','cpu_shares: 512','cpus: 1.0',
                      'ghcr.io/6667084/ansgo:v1.6.1','/host/manual-certs']:
            if token in template and token not in text: continue
            assert token in updated, (name,token,updated)
        assert updated.split('  ansgo:',1)[0] == text.split('  ansgo:',1)[0]
        assert updated.split('  after:',1)[1] == text.split('  after:',1)[1]
        assert compose.stat().st_mode & 0o777 == mode
        for secret in ('fixture-panel-unique','fixture-dynu-unique'):
            assert secret not in updated and secret not in result.stdout+result.stderr
        archive, = (root/'backups').glob('*.tar.gz')
        with tarfile.open(archive) as tar:
            assert tar.extractfile('./compose.yml').read() == text.encode()
            assert tar.getmember('./compose.yml').mode == mode
        if real_compose:
            resolved = subprocess.check_output([real_compose,'compose','-f',str(compose),'config','--format','json'],text=True)
            actual = json.loads(resolved)['services']['ansgo']
            assert actual['image'].endswith(':v1.6.1') and int(actual['mem_limit']) == expected_mem
            assert int(actual['memswap_limit']) == expected_mem+256*M
            assert actual['environment']['EXAMPLE'] == 'a$$b'
            assert actual['environment']['PANEL_PASS'] == 'fixture-panel-unique'
    removed = [e.split()[-1] for e in state['events'] if e.startswith('image rm ')]
    assert ids['foreign'] not in removed and ids['shared'] not in removed
    assert not any('prune' in e for e in state['events'] if not e.startswith('exec '))
    return state, result, removed

state, result, removed = run('preserve',extras=[record('early'),record('legacy','ghcr.io/jiasongji/ansgo')])
assert set(removed) == {ids['early'],ids['legacy']} and ids['old'] in [x['id'] for x in state['images']]
base_config = state['config']
print('PASS Docker compose: env_file/注释/gai/320m/其它服务/美元符号/0644 保留；备份只含原文，无凭据明文')
updated = (tmp/'preserve/project/docker-compose.yml').read_text()
cfg = json.loads(json.dumps(base_config))
cfg.update(memswap_limit=576*M,pids_limit=512,cpu_shares=512,cpus=1.0)
cfg['logging']['options'] = {'max-size':'10m','max-file':'3'}
cfg['volumes'].append(dict(target='/host/manual-certs'))
run('idempotent',text=updated,config=cfg,real_config=bool(real_compose))
assert (tmp/'idempotent/project/docker-compose.yml').read_text() == updated
cfg = json.loads(json.dumps(base_config)); del cfg['mem_limit']
text = template.replace('    mem_limit: 320m # 用户调优\n','')
run('default-memory',text=text,config=cfg,expected_mem=324*M,real_config=bool(real_compose))
assert '    mem_limit: 324m\n' in (tmp/'default-memory/project/docker-compose.yml').read_text()
cfg = json.loads(json.dumps(base_config)); del cfg['logging']
text = re.sub(r'    logging:.*?(?=    volumes:)', '', template, flags=re.S)
run('default-logging',text=text,config=cfg,real_config=bool(real_compose))
updated = (tmp/'default-logging/project/docker-compose.yml').read_text()
assert 'max-size: "10m"' in updated and 'max-file: "3"' in updated
cfg = json.loads(json.dumps(base_config)); cfg['volumes'].append(dict(target='/host/manual-certs'))
text = template.replace('      - fixture_etc:', '      - type: bind\n        source: /etc/ansgo-docker/manual-certs\n        target: /host/manual-certs\n        read_only: true\n      - fixture_etc:')
run('existing-mount',text=text,config=cfg,real_config=bool(real_compose))
assert (tmp/'existing-mount/project/docker-compose.yml').read_text().count('/host/manual-certs') == 1
for driver in ('journald','json-file'):
    cfg = json.loads(json.dumps(base_config))
    cfg['logging'] = dict(driver=driver,options={'max-size':'20m'} if driver=='json-file' else {})
    text = template.replace('driver: json-file','driver: '+driver)
    if driver=='json-file':
        text = text.replace('options: {} # 空映射','options: # 原有选项\n        max-size: "20m"')
    run('logging-'+driver,text=text,config=cfg,real_config=bool(real_compose))
    updated = (tmp/('logging-'+driver)/'project/docker-compose.yml').read_text()
    if driver=='journald': assert 'max-size:' not in updated and 'max-file:' not in updated
    else: assert updated.count('max-size:') == 1 and 'max-size: "20m"' in updated and 'max-file: "3"' in updated
indentless = template.replace('      - ', '    - ')
run('indentless',text=indentless,real_config=bool(real_compose),cert_mode='manual')
print('PASS Docker compose: 保留日志驱动与已有轮转值；支持同级列表和 manual 证书模式')
print('PASS Docker limits: 缺内存时按 464MB 宿主补 324m，重复升级不产生重复键或挂载')
state, result, removed = run('no-space',available=344*M)
assert not removed and not any(e.startswith('pull ') or (e.startswith('exec ') and ' cat /usr/local/share/ansgo-version' not in e) or ' up ' in e for e in state['events'])
assert '磁盘空间不足' in result.stdout and '610MB' in result.stdout
print('PASS Docker preflight: 344MB 无可删旧镜像时中止，compose/容器/镜像不变')
state, result, removed = run('recover-space',available=344*M,extras=[record('legacy','ghcr.io/jiasongji/ansgo')])
assert removed == [ids['legacy']]
assert state['events'].index('image rm --force '+ids['legacy']) < next(i for i,e in enumerate(state['events']) if e.startswith('pull '))
print('PASS Docker preflight: 只删指定旧仓库镜像后空间足够，才 pull 并继续升级')
state, result, removed = run('low-space',post=300*M,extras=[record('early',reclaim=100*M)],mode=0o640)
assert removed == [ids['early'],ids['old']]
assert '为保证磁盘余量已删除旧镜像，如需回滚将重新拉取 ghcr.io/6667084/ansgo:v1.5.37' in result.stdout
print('PASS Docker cleanup: 成功后删更早镜像；低于 500MB 再删上一个镜像并提示回滚 tag；0640 保留')
state, result, removed = run('local-target',available=1*M,local_target=True)
assert not removed and state['events'].index('df') > next(i for i,e in enumerate(state['events']) if e.startswith('pull '))
print('PASS Docker preflight: 目标已在本地，跳过拉取空间预检')
for fail in ('fail_pull','fail_up','fail_inspect','fail_http','invalid_compose'):
    state, result, removed = run(fail,fail=fail,extras=[record('early')])
    assert not removed
    if fail in ('fail_up','fail_inspect','fail_http'): assert 'rollback' in state['events']
print('PASS Docker failure: 解析/pull/重建/inspect/HTTP 失败均不清理镜像，切换失败按旧 ID 回滚')
# 拉取前腾空间是例外：随后失败不再清理，运行镜像与剩余候选必须保留。
state, result, removed = run('preclean-pull-fail',available=344*M,fail='fail_pull',
                            extras=[record('early'),record('legacy','ghcr.io/jiasongji/ansgo')])
assert removed == [ids['early']] and ids['legacy'] in [x['id'] for x in state['images']]
assert ids['old'] in [x['id'] for x in state['images']]
print('PASS Docker failure: 预拉取腾空间后失败，不再删除其它候选或运行镜像')
shared = record('shared'); shared['tags'].append('example/foreign:keep')
state, result, removed = run('foreign-protection',extras=[shared,record('early',in_use=True)])
assert not removed and ids['early'] in [x['id'] for x in state['images']]
print('PASS Docker isolation: 非项目镜像、跨仓库同 ID、其它容器引用的镜像与卷保留，不执行全局 prune')
dual = record('early'); dual['tags'].append('ghcr.io/6667084/ansgo:latest')
state, result, removed = run('multi-tags',extras=[dual])
assert removed == [ids['early']]
digest = record('early'); digest['digests'] = ['example/foreign@sha256:'+'0'*64]
state, result, removed = run('foreign-digest',extras=[digest])
assert not removed
print('PASS Docker references: 项目多标签按 ID 清理，跨仓库摘要引用保留')
state, result, removed = run('unreclaimable',available=100*M,extras=[record('early')])
assert not removed
state, result, removed = run('shared-layers',available=344*M,extras=[record('early',reclaim=0)])
assert removed == [ids['early']] and '磁盘空间不足' in result.stdout
print('PASS Docker space: 理论不足不删除；共享层实际回收不足时中止，compose/容器不变')
if real_compose:
    run('real-config',real_config=True)
    print('PASS real Docker Compose: 原文编辑全过程使用真实解析校验，凭据仍来自 env_file，未启动容器')
PYDOCKER
RESULT="$TMP/upgrade.result"
TASK_ID=example-upgrade-task
TASK_STARTED=$(date +%s)
write_result success
python3 - "$RESULT" "$TASK_ID" "$TASK_STARTED" <<'PY'
import json, os, sys
p, task, started = sys.argv[1:]
d = json.load(open(p))
assert d['result'] == 'success' and d['task_id'] == task
assert d['started_at'] == int(started) and d['finished_at'] >= int(started)
assert os.stat(p).st_mode & 0o777 == 0o600
assert not os.path.exists(p+'.tmp')
print('PASS upgrade.result: 原子 JSON、任务 ID、起止时间及 0600')
PY
python3 "$PROJECT/scripts/test-download-sources.py"
echo 'ALL UPGRADE TESTS PASSED'
