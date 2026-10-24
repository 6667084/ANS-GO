#!/usr/bin/env bash
# 全部路径放临时根目录，macOS / Debian 均不触碰宿主 /etc。
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ANSGO_ROOT="$TMP/root" ANSGO_LIB="$PROJECT/deploy/ansgo-limits"
source "$ANSGO_LIB"
mkdir -p "$ANSGO_ROOT/etc/ansgo" "$ANSGO_ROOT/proc/self" "$ANSGO_ROOT/sys/fs/cgroup/test"
printf '{"backup_keep":2}\n' > "$ANSGO_ROOT/etc/ansgo/panel.json"
printf 'MemTotal: 262144 kB\n' > "$ANSGO_ROOT/proc/meminfo"
printf '0::/test\n' > "$ANSGO_ROOT/proc/self/cgroup"
printf 'max\n' > "$ANSGO_ROOT/sys/fs/cgroup/memory.max"
printf '268435456\n' > "$ANSGO_ROOT/sys/fs/cgroup/test/memory.max"
ansgo_limits
python3 - "$ANSGO_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
for unit,maximum,high,gomem,oom in [('sing-box',96,76,60,-500),('caddy',64,51,40,-400),('ansgo-panel',48,38,30,500)]:
    s=(root/('etc/systemd/system/'+unit+'.service.d/10-ansgo-limits.conf')).read_text()
    for value in ['# managed-by: ansgo','MemoryMax=%sM'%maximum,'MemoryHigh=%sM'%high,
                  'GOMEMLIMIT=%sMiB'%gomem,'OOMScoreAdjust=%s'%oom,'LimitNOFILE=65535']:
        assert value in s, (unit,value,s)
print('PASS limits: 256MB 下限、GOMEMLIMIT、OOM 优先级及 fd 上限')
PY
printf 'MemTotal: 8388608 kB\n' > "$ANSGO_ROOT/proc/meminfo"
printf '536870912\n' > "$ANSGO_ROOT/sys/fs/cgroup/test/memory.max"
[ "$(ansgo_memory_mb)" = 512 ]
ansgo_limits
grep -q 'MemoryMax=179M' "$ANSGO_ROOT/etc/systemd/system/sing-box.service.d/10-ansgo-limits.conf"
ANSGO_MEM_MB=8192 ansgo_limits
grep -q 'MemoryMax=128M' "$ANSGO_ROOT/etc/systemd/system/ansgo-panel.service.d/10-ansgo-limits.conf"
printf '[Service]\nMemoryMax=77M\n' > "$ANSGO_ROOT/etc/systemd/system/caddy.service.d/10-ansgo-limits.conf"
ansgo_limits >/dev/null
grep -q 'MemoryMax=77M' "$ANSGO_ROOT/etc/systemd/system/caddy.service.d/10-ansgo-limits.conf"
echo 'PASS limits: cgroup v2 实际预算、面板上限、用户 drop-in 保留'
mkdir -p "$ANSGO_ROOT/etc/systemd/journald.conf.d"
printf '[Journal]\nSystemMaxUse=8M\nRuntimeMaxUse=4M\n' > "$ANSGO_ROOT/etc/systemd/journald.conf.d/size.conf"
ansgo_tune
ansgo_tune
grep -q 'SystemMaxUse=8M' "$ANSGO_ROOT/etc/systemd/journald.conf.d/60-ansgo.conf"
grep -q 'RuntimeMaxUse=4M' "$ANSGO_ROOT/etc/systemd/journald.conf.d/60-ansgo.conf"
echo 'PASS tune: 保留 size.conf，项目 journald 不放宽既有限额'
python3 - "$ANSGO_ROOT" <<'PY'
import os,sys
root=sys.argv[1]
os.makedirs(root+'/root',exist_ok=True)
open(root+'/root/ansgo-cert-issue.log','wb').write(b'x'*1048577)
PY
ansgo_logs_init
[ -L "$ANSGO_ROOT/root/ansgo-cert-issue.log" ]
[ "$(wc -c < "$ANSGO_ROOT/var/log/ansgo/cert-issue.log" | tr -d ' ')" = 262144 ]
printf 'tail\n' >> "$ANSGO_ROOT/root/ansgo-cert-issue.log"
grep -q tail "$ANSGO_ROOT/var/log/ansgo/cert-issue.log"
echo 'PASS logs: 旧日志迁移、兼容软链接、1MB/256KB 裁剪'
python3 - "$ANSGO_ROOT" <<'PY'
import os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); backup=root/'etc/ansgo-backup'; backup.mkdir()
for category in ('manual','upgrade'):
    for i in range(1,5): (backup/(category+'-2026010%s-000000.tar.gz'%i)).write_bytes(b'x'*100)
for i in range(1,5):
    p=root/('etc/ansgo-backup-upgrade-2025010%s-000000'%i);p.mkdir();(p/'file').write_bytes(b'x'*100)
for sub,name,age in [('etc/ansgo/probe-tmp','old.json',700),('etc/ansgo/probe-tmp','fresh.json',0),
                     ('tmp','sing-box-stale',700),('tmp','sing-box-fresh',0),('tmp','unrelated',700)]:
    p=root/sub/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('test')
    os.utime(p,(time.time()-age,time.time()-age))
(backup/'user-file').write_text('keep')
PY
OUT=$(bash "$PROJECT/deploy/ansgo-admin" prune --yes)
printf '%s\n' "$OUT"
python3 - "$ANSGO_ROOT" "$OUT" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1]); base=root/'etc/ansgo-backup'
assert len(list(base.glob('manual-*.tar.gz')))==2
assert len(list(base.glob('upgrade-*.tar.gz')))==2
assert len(list((root/'etc').glob('ansgo-backup-upgrade-*')))==2
assert not (root/'etc/ansgo/probe-tmp/old.json').exists()
assert (root/'etc/ansgo/probe-tmp/fresh.json').exists()
assert not (root/'tmp/sing-box-stale').exists()
assert (root/'tmp/sing-box-fresh').exists() and (root/'tmp/unrelated').exists()
assert (base/'user-file').exists()
assert re.fullmatch(r'FREED_BYTES=\d+',sys.argv[2].splitlines()[-1])
assert int(sys.argv[2].split('=')[-1])>0
print('PASS prune: 分类别保留、旧路径、10分钟边界、不清理无关文件、释放字节')
PY
python3 - "$ANSGO_ROOT" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'etc/ansgo-backup/large-20260101-000000.tar.gz'
with p.open('wb') as f: f.truncate(201*1024*1024)
PY
bash "$PROJECT/deploy/ansgo-admin" prune --yes > "$TMP/size.out"
[ ! -f "$ANSGO_ROOT/etc/ansgo-backup/large-20260101-000000.tar.gz" ]
echo 'PASS prune: 200MB 总量上限'
# 备份只能留一份压缩包，SQLite 使用一致性快照，恢复覆盖 manifest 全部路径。
printf 'SAFE_KEY=abc\n' > "$ANSGO_ROOT/etc/ansgo/secrets.env"
python3 - "$ANSGO_ROOT" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]+'/etc/ansgo/sessions.db') as db:
    db.execute('create table sessions(token text, expires integer)');db.execute("insert into sessions values ('test', 9999999999)")
PY
archive=$(ansgo_backup test /etc/ansgo/panel.json /etc/ansgo/secrets.env /etc/ansgo/sessions.db /etc/ansgo/absent)
printf 'broken' > "$ANSGO_ROOT/etc/ansgo/secrets.env"
printf 'new' > "$ANSGO_ROOT/etc/ansgo/absent"
ansgo_restore "$archive"
grep -q 'SAFE_KEY=abc' "$ANSGO_ROOT/etc/ansgo/secrets.env"
[ ! -e "$ANSGO_ROOT/etc/ansgo/absent" ]
[ "$(find "$ANSGO_ROOT/etc/ansgo-backup" -type d | wc -l | tr -d ' ')" = 1 ]
python3 - "$ANSGO_ROOT" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]+'/etc/ansgo/sessions.db') as db:
    assert db.execute('select token from sessions').fetchone()[0]=='test'
PY
python3 - "$ANSGO_ROOT" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]+'/etc/ansgo/sessions.db') as db:
    db.execute("update sessions set expires=1")
PY
bash "$PROJECT/deploy/ansgo-admin" prune --yes >/dev/null 2>&1
python3 - "$ANSGO_ROOT" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]+'/etc/ansgo/sessions.db') as db:
    assert db.execute('select count(*) from sessions').fetchone()[0]==0
print('PASS prune: 过期会话清理')
PY
echo 'PASS backup: 单一 tar.gz、manifest 完整恢复、SQLite 一致快照'
# 嵌套链接必须递归解引用；循环链接落为占位文件，保证恢复端的无链接约束成立。
mkdir -p "$ANSGO_ROOT/etc/ansgo/links-root/sub"
printf 'nested\n' > "$ANSGO_ROOT/etc/ansgo/links-root/sub/nested.txt"
ln -s sub "$ANSGO_ROOT/etc/ansgo/links-root/alias"
ln -s .. "$ANSGO_ROOT/etc/ansgo/links-root/sub/back"
link_archive=$(ansgo_backup links /etc/ansgo/links-root)
rm -rf "$ANSGO_ROOT/etc/ansgo/links-root"
ansgo_restore "$link_archive"
grep -q nested "$ANSGO_ROOT/etc/ansgo/links-root/alias/nested.txt"
[ ! -L "$ANSGO_ROOT/etc/ansgo/links-root/alias" ]
[ ! -L "$ANSGO_ROOT/etc/ansgo/links-root/sub/back" ]
grep -q '链接' "$ANSGO_ROOT/etc/ansgo/links-root/sub/back"
echo 'PASS backup: 嵌套链接递归解引用、循环链接占位可恢复'
python3 - "$ANSGO_ROOT" "$ANSGO_LIB" <<'PY'
import io,json,os,sqlite3,subprocess,sys,tarfile,tempfile
root,lib=sys.argv[1:]
# 整目录备份也必须使用 SQLite backup API，不能把仍在 WAL 内的数据漏掉。
with sqlite3.connect(root+'/etc/ansgo/wal%.db') as db:
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE committed(v TEXT)')
    db.execute("INSERT INTO committed VALUES ('in-wal')")
    db.commit()
    archive=subprocess.check_output(['bash','-c','source "$1"; ansgo_backup wal /etc/ansgo','_',lib],text=True).strip()
    with tempfile.TemporaryDirectory() as d:
        with tarfile.open(archive) as tar:
            assert not any(m.name.endswith(('-wal','-shm')) for m in tar)
            data=tar.extractfile('files/etc/ansgo/wal%.db').read()
        open(d+'/copy.db','wb').write(data)
        with sqlite3.connect(d+'/copy.db') as snap:
            assert snap.execute('SELECT v FROM committed').fetchone()[0]=='in-wal'
# manifest 中后续路径缺失时，前面路径也不能被部分提交。
archive=root+'/invalid.tar.gz'
manifest=[dict(path='etc/ansgo/secrets.env',exists=True,kind='file'),
          dict(path='etc/ansgo/missing',exists=True,kind='file')]
before=open(root+'/etc/ansgo/secrets.env','rb').read()
with tarfile.open(archive,'w:gz') as tar:
    for name,data in [('manifest.json',json.dumps(manifest).encode()),('files/etc/ansgo/secrets.env',b'BAD=changed\n')]:
        member=tarfile.TarInfo(name);member.size=len(data);tar.addfile(member,io.BytesIO(data))
res=subprocess.run(['bash','-c','source "$1"; ansgo_restore "$2"','_',lib,archive],capture_output=True)
assert res.returncode!=0
assert open(root+'/etc/ansgo/secrets.env','rb').read()==before
assert not any(n.startswith('.ansgo-restore-') for n in os.listdir(root+'/etc/ansgo'))
print('PASS backup: 整目录 WAL 一致快照、百分号路径、缺文件恢复失败保持原内容')
PY
# 证书同步：首次返回 10，第二次 0；模拟证书 mv 失败时旧对必须完整恢复。
SYNC="$PROJECT/deploy/ansgo-sync-manual-cert"
mkdir -p "$ANSGO_ROOT/host/manual-certs" "$ANSGO_ROOT/etc/ssl/ansgo"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ANSGO_ROOT/host/manual-certs/privkey.pem"   -out "$ANSGO_ROOT/host/manual-certs/fullchain.pem" -days 1 -subj '/CN=your-domain.com' >/dev/null 2>&1
rc=0; ansgo_sync_once(){ ANSGO_ROOT="$ANSGO_ROOT" ANSGO_LIB="$ANSGO_LIB" bash "$SYNC" >/dev/null 2>&1; }
ansgo_sync_once || rc=$?; [ "$rc" = 10 ]
rc=0; ansgo_sync_once || rc=$?; [ "$rc" = 0 ]
echo 'PASS cert-sync: 首次 10、无变化 0'
cp "$ANSGO_ROOT/etc/ssl/ansgo/fullchain.pem" "$TMP/old-full"
cp "$ANSGO_ROOT/etc/ssl/ansgo/privkey.pem" "$TMP/old-key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ANSGO_ROOT/host/manual-certs/privkey.pem" \
  -out "$ANSGO_ROOT/host/manual-certs/fullchain.pem" -days 1 -subj '/CN=your-domain.com' >/dev/null 2>&1
mkdir -p "$TMP/bin"
cat > "$TMP/bin/mv" <<'SH'
#!/bin/bash
case "$*" in *.ansgo-sync.*/fullchain.pem*) exit 1;; esac
exec /bin/mv "$@"
SH
chmod +x "$TMP/bin/mv"
rc=0; PATH="$TMP/bin:$PATH" ansgo_sync_once || rc=$?
[ "$rc" != 0 ] && [ "$rc" != 10 ]
cmp "$TMP/old-full" "$ANSGO_ROOT/etc/ssl/ansgo/fullchain.pem"
cmp "$TMP/old-key" "$ANSGO_ROOT/etc/ssl/ansgo/privkey.pem"
echo 'PASS cert-sync: 第二个 mv 注入失败后完整恢复旧证书与私钥'
printf '{"group2_enabled":"true","anytls2_port":23456,"ss_landing_host":"your-domain.com","ss_landing_port":8388,"svc_ss_enabled":"false"}\n' > "$ANSGO_ROOT/etc/ansgo/panel.json"
printf 'ANYTLS2_PASS=oldpass\nANYTLS2_UUID=oldid\n' > "$ANSGO_ROOT/etc/ansgo/secrets.env"
ansgo_migrate "$ANSGO_ROOT/etc/ansgo/panel.json" "$ANSGO_ROOT/etc/ansgo/secrets.env"
ansgo_migrate "$ANSGO_ROOT/etc/ansgo/panel.json" "$ANSGO_ROOT/etc/ansgo/secrets.env"
python3 - "$ANSGO_ROOT" <<'PY'
import json,os,sys
root=sys.argv[1]; c=json.load(open(root+'/etc/ansgo/panel.json'))
assert len(c['landings'])==1 and c['landings'][0]['enabled']
assert c['landings'][0]['remote_host']=='your-domain.com'
assert 'group2_enabled' not in c and 'landings_schema' not in c
assert c['auto_upgrade']=='false' and c['backup_keep']==5
assert 'LANDING_1_PASS=oldpass' in open(root+'/etc/ansgo/secrets.env').read()
assert os.stat(root+'/etc/ansgo/panel.json').st_mode & 0o777 == 0o600
print('PASS migration: 旧落地/凭证幂等迁移、0600、新字段默认值，保留 Go schema 迁移入口')
PY
# 管理标记仍在、但主体已被用户编辑时也不能覆盖。
file="$ANSGO_ROOT/etc/systemd/system/sing-box.service.d/10-ansgo-limits.conf"
printf '\n# user edit\n' >> "$file"
cp "$file" "$TMP/user-limits"
ANSGO_MEM_MB=2048 ansgo_limits > "$TMP/limits-output"
cmp "$file" "$TMP/user-limits"
grep -q '保留用户资源配置' "$TMP/limits-output"
echo 'PASS limits: 内容指纹匹配才更新，保留带管理标记的用户编辑'
python3 - "$ANSGO_ROOT" "$PROJECT" <<'PYCOMPAT'
import json, os, pathlib, re, shutil, subprocess, sys
root, project = map(pathlib.Path, sys.argv[1:])
conf = root/'etc/ansgo/panel.json'
secrets = root/'etc/ansgo/secrets.env'
admin = (project/'deploy/ansgo-admin').read_text()
def fn(name):
    return re.search(r'^'+re.escape(name)+r'\(\).*?^}', admin, re.M|re.S)[0]
for value in ['two words', 'a$b', "O'Reilly", r'abc\def', ' padded ']:
    for wrapped in [value, "'"+value+"'", '"'+value+'"']:
        conf.write_text(json.dumps(dict(svc_ss_enabled='false', landings=[])))
        secrets.write_text('ANYTLS_PASS='+wrapped+'\nANYTLS2_PASS='+wrapped+'\nANYTLS2_UUID=example-id\n')
        for suffix in ('', '-wal', '-shm'):
            p = root/('etc/ansgo/sessions.db'+suffix)
            p.touch(); p.chmod(0o644)
        command = 'source "$ANSGO_LIB"; ansgo_migrate "$1" "$2"; ansgo_migrate "$1" "$2"'
        subprocess.run(['bash','-ec',command,'_',str(conf),str(secrets)],check=True)
        text = secrets.read_text()
        assert 'ANYTLS_PASS='+wrapped+'\n' in text, repr(text)
        assert 'LANDING_1_PASS='+value+'\n' in text, repr(text)
        assert 'ANYTLS2_PASS=' not in text
        shell = fn('_secret')+'\n'+fn('_setsecret')+'\nSECRETS="$1"; _secret ANYTLS_PASS; _secret LANDING_1_PASS; _setsecret ANYTLS_PASS "$2"; _secret ANYTLS_PASS'
        out = subprocess.check_output(['bash','-ec',shell,'_',str(secrets),value],text=True)
        assert out.splitlines() == [value,value,value], repr(out)
        for suffix in ('', '-wal', '-shm'):
            assert (root/('etc/ansgo/sessions.db'+suffix)).stat().st_mode & 0o777 == 0o600
print('PASS secrets: 迁移幂等/逐字保留、admin 读写兼容四类历史密码；已有 SQLite/sidecar 权限修复')
for keep in (5, 1):
    base = root/'etc/ansgo-backup'
    shutil.rmtree(base); base.mkdir()
    conf.write_text(json.dumps(dict(backup_keep=keep)))
    for category in ('upgrade','manual'):
        for i in range(1,7):
            (base/(category+'-20261024-12000'+str(i)+'.tar.gz')).write_bytes(b'x')
    # 权限探针不是真实 SQLite 文件，清理前移除。
    for suffix in ('', '-wal', '-shm'):
        (root/('etc/ansgo/sessions.db'+suffix)).unlink()
    out = subprocess.check_output(['bash',str(project/'deploy/ansgo-admin'),'prune','--yes'],text=True)
    assert len(list(base.glob('upgrade-*'))) == min(keep,2)
    assert len(list(base.glob('manual-*'))) == keep
    assert re.search(r'^FREED_BYTES=\d+$',out,re.M)
    for suffix in ('', '-wal', '-shm'):
        (root/('etc/ansgo/sessions.db'+suffix)).touch()
print('PASS prune: 升级备份 min(2, backup_keep)，其他类别 backup_keep')
PYCOMPAT
printf 'ALL PRUNE/LIMITS TESTS PASSED\n'
