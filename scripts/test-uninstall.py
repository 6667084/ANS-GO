#!/usr/bin/env python3
# 完整入口和 curl|bash bootstrap 均在临时根目录运行，不接触宿主服务与配置。
import os
import pathlib
import re
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
original = (project / "install.sh").read_text()
for mode in ("metal", "docker", "residue"):
    for piped in (False, True):
        for purge in (False, True):
            with tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp) / "root"
                bindir = pathlib.Path(tmp) / "bin"
                bindir.mkdir()
                for name, body in {
                    "id": "echo 0",
                    "systemctl": "exit 0",
                    "docker": "exit 0",
                }.items():
                    path = bindir / name
                    path.write_text("#!/bin/sh\n" + body + "\n")
                    path.chmod(0o700)
                source = re.sub(r"/(?:etc|var|usr/local/bin|root)/", lambda m: str(root) + m[0], original)
                source = re.sub(
                    r"^readtty\(\)\{.*?^\}",
                    "readtty(){ printf yes; }",
                    source,
                    count=1,
                    flags=re.M | re.S,
                )
                script = pathlib.Path(tmp) / "install.sh"
                script.write_text(source)
                files = [
                    "etc/ansgo-backup/manual-20260101-000000.tar.gz",
                    "etc/ansgo-backup-20260101-000000.tar.gz",
                    "etc/ansgo-backup-20260101-000000/secrets.env",
                    "var/lib/ansgo/upgrade.result",
                    "var/log/ansgo/upgrade.log",
                    "etc/ansgo-cert.status",
                ]
                if mode == "metal":
                    files.append("etc/ansgo/panel.json")
                if mode == "docker":
                    files.append("etc/ansgo-docker/docker-compose.yml")
                for name in files:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("example\n")
                unrelated = root / "etc/unrelated"
                unrelated.write_text("keep\n")
                args = ["--uninstall"] + (["--purge"] if purge else [])
                env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"])
                command = ["bash", "-s", "--", *args] if piped else ["bash", str(script), *args]
                result = subprocess.run(
                    command, input=source if piped else None, env=env,
                    text=True, errors="backslashreplace", capture_output=True, timeout=20,
                )
                assert result.returncode == 0, result.stdout + result.stderr
                assert "command not found" not in result.stderr, result.stderr
                for name in files:
                    assert (root / name).exists() == (not purge), (mode, piped, purge, name)
                assert unrelated.read_text() == "keep\n"
                if purge:
                    for name in ("etc/ansgo-backup", "var/lib/ansgo", "var/log/ansgo"):
                        assert not (root / name).exists(), name
                print(f"PASS uninstall: {mode}, bootstrap={piped}, purge={purge}")
