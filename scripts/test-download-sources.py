#!/usr/bin/env python3
"""本地 HTTP 夹具：下载源覆盖、HEAD/Range、预检失败不得修改宿主。"""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

PROJECT = Path(__file__).resolve().parents[1]
install = (PROJECT / "install.sh").read_text()
upgrade = (PROJECT / "deploy/upgrade.sh").read_text()
requests = []
missing = set()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.reply(True)

    def do_GET(self):
        self.reply(False)

    def reply(self, head):
        requests.append((self.command, self.path, self.headers.get("Range")))
        if self.path in missing:
            self.send_error(404)
            return
        if head and self.path == "/raw/ansgo-genconf":
            self.send_error(405)
            return
        body = b"fixture"
        if self.path == "/api/v1.6.1":
            body = json.dumps({"assets": [{"name": "ansgo-panel-linux-amd64"}]}).encode()
        if self.path == "/raw/docker-compose.yml":
            body = (PROJECT / "deploy/docker-compose.yml").read_bytes()
        self.send_response(206 if self.headers.get("Range") else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def log_message(self, *_):
        pass


def fn(text, name):
    return re.search(r"^" + re.escape(name) + r"\(\).*?^}", text, re.M | re.S)[0]


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = "http://127.0.0.1:" + str(server.server_port)
try:
    with tempfile.TemporaryDirectory(prefix="ansgo-download-test-") as temp:
        root = Path(temp)
        env = {**os.environ, "ANSGO_RAW_BASE": base + "/raw/",
               "ANSGO_REL_BASE": base + "/rel/", "ANSGO_RELEASE_API": base + "/api/"}
        setup = 'REPO=6667084/ANS-GO\nVER=v1.6.1\nAARCH=amd64\nDOCKER=1\n'
        install_sources = re.search(r'^RAW=.*?^VER=.*$', install, re.M | re.S)[0].split("\n# 架构映射", 1)[0]
        upgrade_sources = upgrade.split('RAW="${ANSGO_RAW_BASE:', 1)[1].split('\nif [ "$YES"', 1)[0]
        upgrade_sources = 'RAW="${ANSGO_RAW_BASE:' + upgrade_sources
        for text, expected_rel in [(install_sources, base + "/rel"), (upgrade_sources, base + "/rel/v1.6.1")]:
            script = setup + text + '\nprintf "%s\\n" "$RAW" "$REL" "$RELEASE_API"\n'
            out = subprocess.check_output(["bash", "-eu", "-c", script], env=env, text=True)
            assert out.splitlines() == [base + "/raw", expected_rel, base + "/api"], out
        # 同一份已安装脚本每次执行时重新读取环境变量，不能嵌入首次覆盖值。
        for key in ("ANSGO_RAW_BASE", "ANSGO_REL_BASE", "ANSGO_RELEASE_API"):
            assert key in upgrade and key in install
        # 安装参数到 compose dotenv，再到 entrypoint，特殊密码必须逐字还原。
        entrypoint = (PROJECT / "deploy/docker/entrypoint.sh").read_text()
        decoder = entrypoint.split("# 编码仅用于穿过 compose dotenv；", 1)[1].split("\nmkdir -p /etc/ansgo", 1)[0]
        decoder = decoder[decoder.index("\nfor field"):]
        env_file = root / "ansgo.env"
        defaults = dict(DOMAIN="your-domain.com", EMAIL="admin@your-domain.com", PANEL_USER="admin",
                        PANEL_PORT="23456", SS_PORT="23457", ANYTLS_PORT="23458", SOCKS_PORT="23459",
                        NAIVE_PORT="23460", DISGUISE_PANEL="page", DISGUISE_NAIVE="page",
                        DYNU_KEY="", DYNU_CID="", DYNU_SECRET="", CERT_MODE="acme", CERT_FILE="", KEY_FILE="",
                        SS_PASSWORD="", ANYTLS_UUID_IN="", SOCKS_USER_IN="", SOCKS_PASSWORD="",
                        NAIVE_USER_IN="", NAIVE_PASSWORD="", PANEL_PASSWORD_IN="example-pass",
                        URL_PATH_IN="/admin/", PANEL_TITLE_IN="", SERVER_IP_IN="", NO_CADDY="0")
        for value in ("two words", "a$b", "O'Reilly", r"abc\def"):
            script = fn(install, "ansgo_pct_encode") + "\n" + fn(install, "docker_gen_ansgo_env") + '\ndocker_gen_ansgo_env "$1"'
            subprocess.run(["bash", "-eu", "-c", script, "_", str(env_file)],
                           env={**env, **defaults, "ANYTLS_PASSWORD": value}, check=True)
            entries = dict(line.split("=", 1) for line in env_file.read_text().splitlines() if "=" in line)
            encoded = entries["ANYTLS_PASS_IN_ENCODED"]
            assert re.fullmatch(r"[A-Za-z0-9%_.~-]*", encoded)
            assert "ANYTLS_PASS_IN" not in entries
            out = subprocess.check_output(["bash", "-eu", "-c", decoder + '\nprintf "%s" "$ANYTLS_PASS_IN"'],
                                          env={**env, **entries}, text=True)
            assert out == value, (value, out)
        print("PASS secrets transport: 安装参数 -> compose 安全编码 -> entrypoint 逐字还原四类特殊密码")
        functions = "\n".join(fn(install, name) for name in (
            "dl", "ansgo_asset_probe", "ansgo_compose_v2_hint", "ansgo_compose_check", "ansgo_preflight_assets"))
        script = setup + install_sources + "\n" + functions + '\nWORK="$1"\nerr(){ echo "$*" >&2; }\ndl_or_exit(){ dl "$1" "$2"; }\nansgo_preflight_assets'
        result = subprocess.run(["bash", "-eu", "-c", script, "_", temp], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert ("GET", "/api/v1.6.1", None) in requests
        assert any(p == "/rel/v1.6.1/ansgo-panel-linux-amd64" and method == "HEAD" for method, p, _ in requests)
        assert ("GET", "/raw/ansgo-genconf", "bytes=0-0") in requests
        assert any(p == "/raw/docker-compose.yml" for _, p, _ in requests)
        print("PASS sources: install/upgrade 动态环境覆盖、release JSON、HEAD 失败后 Range 兜底")

        # 完整执行安装入口，所有潜在宿主修改命令都由哨兵阻止，404 必须先退出。
        probes = root / "bin"
        probes.mkdir()
        sentinel = root / "mutation"
        for name in ("apt-get", "install", "systemctl", "sysctl", "docker", "mkdir", "crontab"):
            path = probes / name
            path.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$TEST_MUTATION"\nexit 99\n')
            path.chmod(0o700)
        for name, body in [("id", "echo 0"), ("uname", "echo x86_64"), ("caddy", "exit 1"), ("ss", "exit 0")]:
            path = probes / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o700)
        env.update(PATH=str(probes) + os.pathsep + os.environ["PATH"], TEST_MUTATION=str(sentinel))
        for asset in ("/api/v1.6.1", "/rel/v1.6.1/ansgo-panel-linux-amd64", "/raw/ansgo-admin"):
            missing.add(asset)
            result = subprocess.run(["bash", str(PROJECT / "install.sh"), "--non-interactive",
                                     "--domain", "your-domain.com", "--dynu-key", "example-key"],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 3 and "预检失败" in result.stderr, result.stdout + result.stderr
            assert not sentinel.exists(), "预检失败前修改了宿主"
            missing.clear()
        print("PASS preflight: 完整安装入口遇 panel/raw 404 均中止，未调用任何宿主修改命令")

        # v1 拒绝 cgroup 等模板字段时，安装入口必须在 apt/调优/写配置之前给出 v2 指引。
        calls = root / "compose-calls"
        env["TEST_COMPOSE_CALLS"] = str(calls)
        docker = probes / "docker"
        docker.write_text('#!/bin/sh\nif [ "$1 $2" = "compose version" ]; then exit 1; fi\n'
                          'printf "%s\\n" "$*" >> "$TEST_MUTATION"\nexit 99\n')
        compose = probes / "docker-compose"
        compose.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_COMPOSE_CALLS"\n'
                           'echo "Unsupported config option: cgroup" >&2\nexit 1\n')
        compose.chmod(0o700)
        result = subprocess.run(
            ["bash", str(PROJECT / "install.sh"), "--docker", "--non-interactive",
             "--domain", "your-domain.com", "--dynu-key", "example-key"],
            env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 3 and not sentinel.exists(), result.stdout + result.stderr
        assert "config --quiet" in calls.read_text()
        for hint in ("需要 Docker Compose v2（docker compose 子命令）",
                     "apt-get install -y docker-compose-plugin",
                     "/usr/local/lib/docker/cli-plugins/docker-compose"):
            assert hint in result.stderr, hint
        print("PASS Compose v1 install: 完整入口在任何宿主修改前预检模板，拒绝时给出插件/官方源/静态安装指引")

        # 升级入口也必须先检查 v1，不能先创建日志/锁或修复备份权限。
        sandbox = root / "upgrade-root"
        conf = sandbox / "etc/ansgo-docker/docker-compose.yml"
        conf.parent.mkdir(parents=True)
        conf.write_bytes((PROJECT / "deploy/docker-compose.yml").read_bytes())
        upgraded = re.sub(r"/(?:etc|var|usr/local/bin|root)/",
                          lambda m: str(sandbox) + m[0], upgrade)
        upgrade_file = root / "upgrade.sh"
        upgrade_file.write_text(upgraded)
        before = conf.read_bytes()
        for valid_config in (False, True):
            if valid_config:
                compose.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_COMPOSE_CALLS"\n'
                                   'case "$*" in *"config --quiet") exit 0;; esac\n'
                                   'echo "Usage: docker-compose config"\n')
            result = subprocess.run(["bash", str(upgrade_file), "--docker", "--yes"],
                                    env=env, capture_output=True, text=True, timeout=20)
            assert result.returncode != 0 and not sentinel.exists(), result.stdout + result.stderr
            assert "需要 Docker Compose v2（docker compose 子命令）" in result.stderr
            assert "apt-get install -y docker-compose-plugin" in result.stderr
            assert conf.read_bytes() == before
            assert not (sandbox / "var").exists()
        print("PASS Compose v1 upgrade: 不兼容模板或缺少 JSON 输出能力均在宿主写入前退出")
finally:
    server.shutdown()
    server.server_close()
