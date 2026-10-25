#!/usr/bin/env python3
# 完整入口和 curl|bash bootstrap 均在临时根目录运行，不接触宿主服务与配置。
import json
import os
import pathlib
import re
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
original = (project / "install.sh").read_text()
# 与历史 v1.5.x install.sh 的未标记模板核对；新文件用当前管理标记。
old_net = """net.core.default_qdisc = fq
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
"""
old_limits = "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n"
tuning = {
    "etc/sysctl.d/99-ansgo-tune.conf": "# managed-by: ansgo\nnet.ipv4.tcp_fastopen = 3\n",
    "etc/sysctl.d/99-proxy-tune.conf": old_net,
    "etc/security/limits.d/99-ansgo.conf": old_limits,
    "etc/security/limits.d/99-proxy.conf": "# ANS-GO legacy limits\n* soft nofile 65536\n",
    "etc/systemd/journald.conf.d/60-ansgo.conf": "# managed-by: ansgo\n[Journal]\nSystemMaxUse=8M\n",
    "etc/systemd/journald.conf.d/size.conf": "[Journal]\nSystemMaxUse=50M\n",
}
docker_stub = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ["TEST_IMAGE_STATE"])
s = json.loads(p.read_text()); a = sys.argv[1:]
s["calls"].append(a); p.write_text(json.dumps(s))
def find(ref): return next(x for x in s["images"] if x["id"] == ref)
if a[:2] == ["image","ls"]:
    for image in s["images"]:
        for tag in image["tags"]: print(tag.rsplit(":",1)[0], image["id"])
elif a[:2] == ["image","inspect"]:
    image = find(a[-1])
    print("\n".join(image["tags"]+image.get("digests",[])))
elif a[0] == "ps":
    if find(a[-1].split("=",1)[1]).get("used"): print("other-container")
elif a[:2] == ["image","rm"]:
    assert len(a)==4 and a[2]=="--force" and a[3].startswith("sha256:"), a
    image = find(a[-1])
    assert not image.get("used")
    assert all(t.rsplit(":",1)[0] in ("ghcr.io/6667084/ansgo","ghcr.io/jiasongji/ansgo") for t in image["tags"])
    assert not image.get("digests")
    s["images"].remove(image); p.write_text(json.dumps(s))
elif a[0] not in ("compose","rm","volume"): raise AssertionError(a)
'''


def run(mode, piped, purge, provenance="managed"):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "root"
        bindir = pathlib.Path(tmp) / "bin"
        bindir.mkdir()
        for name, body in {
            "id": "echo 0",
            "systemctl": 'printf "%s\\n" "systemctl $*" >> "$TEST_SYSTEM_CALLS"\n'
                         '[ "$1 $2" != "restart systemd-journald" ]',
            "sysctl": 'printf "%s\\n" "sysctl $*" >> "$TEST_SYSTEM_CALLS"\nexit 1',
        }.items():
            path = bindir / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o700)
        docker = bindir / "docker"
        docker.write_text(docker_stub); docker.chmod(0o700)
        ids = {name: "sha256:"+str(i)*64 for i, name in enumerate(
            ("current","old","foreign","prefix","shared","digest","used"), 1)}
        images = [
            dict(id=ids["current"], tags=["ghcr.io/6667084/ansgo:latest","ghcr.io/6667084/ansgo:v1.6.0"]),
            dict(id=ids["old"], tags=["ghcr.io/jiasongji/ansgo:v1.5.36","ghcr.io/jiasongji/ansgo:latest"]),
            dict(id=ids["foreign"], tags=["example/other:latest"]),
            dict(id=ids["prefix"], tags=["ghcr.io/6667084/ansgo-panel:latest"]),
            dict(id=ids["shared"], tags=["ghcr.io/6667084/ansgo:shared","example/other:shared"]),
            dict(id=ids["digest"], tags=["ghcr.io/6667084/ansgo:digest"],digests=["example/other@sha256:"+"a"*64]),
            dict(id=ids["used"], tags=["ghcr.io/6667084/ansgo:used"],used=True),
        ]
        state = pathlib.Path(tmp) / "images.json"
        state.write_text(json.dumps(dict(images=images,calls=[])))
        calls = pathlib.Path(tmp) / "system-calls"
        source = re.sub(r"/(?:etc|var|usr/local/bin|root)/", lambda m: str(root) + m[0], original)
        source = re.sub(r"^readtty\(\)\{.*?^\}", "readtty(){ printf yes; }",
                        source, count=1, flags=re.M | re.S)
        script = pathlib.Path(tmp) / "install.sh"
        script.write_text(source)
        files = [] if mode == "tuning-only" else [
            "etc/ansgo-backup/manual-20260101-000000.tar.gz",
            "etc/ansgo-backup-20260101-000000.tar.gz",
            "etc/ansgo-backup-20260101-000000/secrets.env",
            "var/lib/ansgo/upgrade.result",
            "var/log/ansgo/upgrade.log",
            "etc/ansgo-cert.status",
        ]
        if mode == "metal": files.append("etc/ansgo/panel.json")
        if mode == "docker": files.append("etc/ansgo-docker/docker-compose.yml")
        for name in files:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text("example\n")
        before = {}
        for name, body in tuning.items():
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
            if provenance != "managed":
                body = "# user configuration\nuser_setting=keep\n"
                if provenance in ("near-match","compacted"):
                    body = (old_net if "/sysctl.d/" in name else
                            old_limits if "/limits.d/" in name else "[Journal]\nSystemMaxUse=50M\n")
                    if provenance == "compacted" and "/journald.conf.d/" not in name:
                        body = body.replace(" ","")
                    else:
                        body += "user_setting=keep\n"
                if provenance == "late-marker": body += "\n"*8+"# managed-by: ansgo\n"
                if provenance == "other-marker": body = "# managed-by: ansgo-other\n"+body
            path.write_text(body); before[name] = body
            if provenance == "symlink":
                target = pathlib.Path(tmp) / (path.name+"-target")
                target.write_text("# managed-by: ansgo\n"+body)
                path.unlink(); path.symlink_to(target)
        unrelated = root / "etc/unrelated"; unrelated.write_text("keep\n")
        args = ["--uninstall"] + (["--purge"] if purge else [])
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                   TEST_IMAGE_STATE=str(state), TEST_SYSTEM_CALLS=str(calls))
        command = ["bash", "-s", "--", *args] if piped else ["bash", str(script), *args]
        result = subprocess.run(command, input=source if piped else None, env=env,
                                text=True, errors="backslashreplace", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "command not found" not in result.stderr, result.stderr
        for name in files:
            assert (root / name).exists() == (not purge), (mode,piped,purge,name)
        for name in tuning:
            path = root / name
            assert path.exists() == (not purge or provenance != "managed"), (name,result.stdout,result.stderr)
            if path.exists():
                if provenance == "symlink": assert path.is_symlink() and path.read_text().startswith("# managed-by: ansgo\n")
                else: assert path.read_text() == before[name]
        assert unrelated.read_text() == "keep\n"
        if purge:
            for name in ("etc/ansgo-backup","var/lib/ansgo","var/log/ansgo"):
                assert not (root / name).exists(), name
        actions = calls.read_text()
        assert ("sysctl --system" in actions) == (purge and provenance == "managed")
        assert ("restart systemd-journald" in actions) == (purge and provenance == "managed")
        final = json.loads(state.read_text())
        removed = [a[-1] for a in final["calls"] if a[:2] == ["image","rm"]]
        assert set(removed) == ({ids["current"],ids["old"]} if mode=="docker" and purge else set()), (
            removed, result.stdout, result.stderr, final["calls"])
        assert not any("prune" in a for a in final["calls"])
        print(f"PASS uninstall: {mode}, bootstrap={piped}, purge={purge}, tuning={provenance}")


for mode in ("metal","docker","residue","tuning-only"):
    for piped in (False, True):
        for purge in (False, True):
            run(mode,piped,purge)
for provenance in ("user","near-match","compacted","late-marker","other-marker","symlink"):
    run("docker",False,True,provenance)
print("ALL UNINSTALL TESTS PASSED: 双仓库全版本/多标签、无关镜像与引用保护、跨形态受管调优清理、用户文件/软链保留")
