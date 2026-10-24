#!/usr/bin/env python3
"""隔离运行真实 genconf，覆盖模型兼容、只读、原子校验、权限与并发锁。"""
import ast
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


SCRIPT = Path(__file__).resolve().parents[1] / "deploy/ansgo-genconf"
SOURCE = SCRIPT.read_text().split("<<'PYEOF'\n", 1)[1].rsplit("\nPYEOF", 1)[0]
ast.parse(SOURCE)


def run(root, mode="sing-box", ok=True):
    result = subprocess.run(
        ["bash", str(SCRIPT), mode], env={**os.environ, "ANSGO_ROOT": str(root)},
        capture_output=True, text=True, timeout=15,
    )
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="ansgo-genconf-test-") as temporary:
        root = Path(temporary)
        conf = root / "etc/ansgo/panel.json"
        secrets = root / "etc/ansgo/secrets.env"
        generated = root / "etc/sing-box/config.json"
        caddy = root / "etc/caddy/Caddyfile"
        conf.parent.mkdir(parents=True)
        key = base64.b64encode(bytes(16)).decode()
        secrets.write_text(
            f"SS_KEY={key}\nANYTLS_PASS=example-pass\nANYTLS_UUID=example-uuid\n"
            "NAIVE_USER=example-user\nNAIVE_PASS=example-pass\n"
            "LANDING_1_PASS=example-pass\nLANDING_1_UUID=example-uuid\n"
        )
        base = {
            "domain": "your-domain.com", "panel_port": 15608,
            "svc_ss_enabled": "false", "svc_anytls_enabled": "false",
            "svc_naive_enabled": "false", "caddy_enable": "false",
            "landings_schema": 2,
            "landings": [{
                "id": "1", "name": "example", "port": 23001, "enabled": True,
                "remote_type": "ss", "remote_enabled": True,
                "remote_host": "old-invalid",
                "remote_ss": {"host": "your-domain.com", "port": 8388,
                              "method": "2022-blake3-aes-128-gcm", "password": key},
                "remote_socks": {"host": "your-domain.com", "port": 1080,
                                 "user": "example-user", "password": "example-pass"},
            }],
        }

        def generate(cfg):
            conf.write_text(json.dumps(cfg))
            before = conf.read_bytes()
            run(root)
            assert conf.read_bytes() == before, "生成器回写 panel.json"
            assert generated.stat().st_mode & 0o777 == 0o600
            return json.loads(generated.read_text())

        cfg = copy.deepcopy(base)
        out = generate(cfg)["outbounds"][-1]
        assert out["type"] == "shadowsocks" and out["server"] == "your-domain.com"
        assert out["password"] == key and out["server_port"] == 8388
        cfg["landings"][0]["remote_type"] = "socks"
        out = generate(cfg)["outbounds"][-1]
        assert out["type"] == "socks" and out["username"] == "example-user"
        cfg["landings"][0]["remote_type"] = "ss"
        assert generate(cfg)["outbounds"][-1]["password"] == key
        cfg["landings"][0]["remote_enabled"] = False
        assert len(generate(cfg)["outbounds"]) == 1, "schema2 显式关闭被覆盖"

        legacy = copy.deepcopy(base)
        legacy.pop("landings_schema")
        landing = legacy["landings"][0]
        remote = landing.pop("remote_ss")
        landing.pop("remote_socks")
        landing.update({"remote_" + k: v for k, v in remote.items()})
        landing["remote_enabled"] = False
        assert generate(legacy)["outbounds"][-1]["type"] == "shadowsocks"
        legacy["landings_schema"] = 2
        assert len(generate(legacy)["outbounds"]) == 1
        landing.update(remote_type="socks", remote_enabled=True, remote_user="example-user",
                       remote_password="example-pass", remote_port=1080)
        assert generate(legacy)["outbounds"][-1]["type"] == "socks"

        # 密钥读取全程字面化，主入站与落地入站必须得到同一密码。
        original_secrets = secrets.read_text()
        cfg = copy.deepcopy(base)
        cfg.update(svc_anytls_enabled="true", anytls_port=23458)
        for value in ["two words", "a$b", "O'Reilly", r"abc\def", " padded "]:
            for wrapped in [value, "'"+value+"'", '"'+value+'"']:
                secrets.write_text(original_secrets.replace("ANYTLS_PASS=example-pass", "ANYTLS_PASS="+wrapped)
                                   .replace("LANDING_1_PASS=example-pass", "LANDING_1_PASS="+wrapped))
                inbounds = generate(cfg)["inbounds"]
                anytls = [x for x in inbounds if x["type"] == "anytls"]
                assert len(anytls) == 2 and all(x["users"][0]["password"] == value for x in anytls)
        secrets.write_text(original_secrets)
        print("PASS secrets: genconf 主/落地密码的空格、美元符号、单引号、反斜杠及包裹引号")

        # 模拟目标二进制，校验时正式文件应仍为旧版本，临时文件已是 0600。
        binary_dir = root / "usr/local/bin"
        binary_dir.mkdir(parents=True)
        checker = """#!{python}
import os, pathlib, sys, time
root=pathlib.Path(os.environ["ANSGO_ROOT"])
marker=root/"run/check-active"
fd=os.open(marker, os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
try:
    path=pathlib.Path(sys.argv[sys.argv.index("-c")+1] if "-c" in sys.argv else sys.argv[sys.argv.index("--config")+1])
    assert path.stat().st_mode & 0o777 == 0o600
    if path.name.startswith(".ansgo-"):
        official=root/("etc/sing-box/config.json" if "-c" in sys.argv else "etc/caddy/Caddyfile")
        assert official.read_text()=="original-runtime"
    with (root/"run/check-calls").open("a") as f:
        f.write(path.name+"\\n")
    time.sleep(.05)
    if pathlib.Path(sys.argv[0]).name=="caddy" and (root/"run/fail-caddy").exists():
        sys.exit(1)
finally:
    os.close(fd)
    marker.unlink()
""".format(python=sys.executable)
        for name in ("sing-box", "caddy"):
            path = binary_dir / name
            path.write_text(checker)
            path.chmod(0o700)
        generated.write_text("original-runtime")
        caddy.parent.mkdir(parents=True)
        caddy.write_text("original-runtime")
        caddy.chmod(0o600)
        conf.write_text(json.dumps(base))
        (root / "run/fail-caddy").touch()
        before = conf.read_bytes()
        run(root, "all", ok=False)
        assert generated.read_text() == caddy.read_text() == "original-runtime"
        assert conf.read_bytes() == before
        assert not list(generated.parent.glob(".ansgo-*"))
        assert not list(caddy.parent.glob(".ansgo-*"))
        run(root, "validate", ok=False)
        # validate 与源文件/密钥无关，且两个校验均执行。
        conf.unlink()
        secrets.unlink()
        (root / "run/fail-caddy").unlink()
        run(root, "validate")
        conf.write_text(json.dumps(base))
        secrets.write_text(f"SS_KEY={key}\nANYTLS_PASS=p\nANYTLS_UUID=u\nNAIVE_USER=u\nNAIVE_PASS=p\nLANDING_1_PASS=p\nLANDING_1_UUID=u\n")
        # 只验证文件锁：两个 validate 若重叠，checker 的 O_EXCL 会失败。
        processes = [
            subprocess.Popen(["bash", str(SCRIPT), "validate"],
                             env={**os.environ, "ANSGO_ROOT": str(root)},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for _ in range(2)
        ]
        for process in processes:
            out, err = process.communicate(timeout=15)
            assert process.returncode == 0, (out + err).decode()
        run(root, "all")
        assert generated.stat().st_mode & 0o777 == caddy.stat().st_mode & 0o777 == 0o600
    print("PASS: 新旧 SS/SOCKS、双草稿、显式禁用、源配置只读、临时校验、失败原子性、0600、validate 退出码、并发文件锁")


if __name__ == "__main__":
    main()
