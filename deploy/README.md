# ANS-GO 部署文件

这里是安装、升级、离线管理和 systemd/Docker 部署资源。面向实际服务器部署时，优先使用仓库根目录的 [README](../README.md)；本文件说明这些文件的职责和与脚本一致的运维入口。

当前发布版本为 **v1.6.0**。Release 包含面板、caddy-naive、sing-box 的 amd64/arm64 资产和 `SHA256SUMS`；Docker 镜像为 `ghcr.io/6667084/ansgo:v1.6.0` 与 `latest`。

## 文件清单

| 文件或目录 | 用途 |
|---|---|
| `../install.sh` | 新安装、落地机部署、卸载和彻底清理 |
| `upgrade.sh` | 裸金属/Docker 统一、可恢复的版本升级器 |
| `ansgo-admin` | SSH 离线管理、备份、清理、恢复与升级入口 |
| `ansgo-genconf` | 只读取源配置，生成并校验 caddy/sing-box 运行配置 |
| `ansgo-limits` | 资源、日志、备份保留和历史迁移共享实现 |
| `ansgo-cert-issue.sh`、`ansgo-cert-reload` | ACME 签发/续期和服务重载 |
| `docker-compose.yml`、`docker/entrypoint.sh` | Docker 一体化部署 |
| `systemd/` | caddy、sing-box、自动升级 timer 的 unit |
| `panel/` | Go 面板及嵌入式前端源码 |

## 推荐部署

```bash
# 交互式安装
bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)

# 裸金属非交互安装
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --non-interactive

# Docker 一体化安装
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --docker --non-interactive
```

安装器支持 Debian 11/12，需要 root。`--cert-mode manual --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH>` 使用已有证书；`--no-caddy` 让 nginx/宝塔继续管理 `:80/:443`；`--landing --port <PORT>` 在落地机安装独立 Shadowsocks 服务。

所有代理端口和面板端口在未指定时随机生成于 `10000-65535`，而非固定端口。完整参数以 `bash install.sh --help` 为准。

## 升级与恢复

```bash
# 自动检测部署形态；自动化或管道执行必须加 --yes
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \
  | bash -s -- --yes

# 指定版本或部署形态
/usr/local/bin/ansgo-upgrade --yes --ver v1.6.0
/usr/local/bin/ansgo-upgrade --metal --yes --ver v1.6.0
/usr/local/bin/ansgo-upgrade --docker --yes --ver v1.6.0

# 手工备份、清理和恢复
ansgo-admin backup
ansgo-admin prune --yes
ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz
```

`upgrade.sh` 先暂存目标 tag 的脚本和资产，验证 release 清单和可执行文件后才创建备份、切换并验证服务；失败时自动回滚。升级日志为 `/var/log/ansgo/upgrade.log`，结果为 `/var/lib/ansgo/upgrade.result`，备份归档统一在 `/etc/ansgo-backup/`。

不带 `--yes` 时，升级器从 `/dev/tty` 读取确认：有终端的 `curl | bash` 可交互确认；CI、cron 或其他无 TTY 环境必须使用 `--yes`。面板“系统维护”页仅可为裸金属启动升级；Docker 必须在宿主执行上述命令。自动升级 timer 默认关闭，可在面板启用或执行：

```bash
systemctl enable --now ansgo-autoupgrade.timer
systemctl disable --now ansgo-autoupgrade.timer
```

旧版面板没有升级按钮，先运行一次 `upgrade.sh --yes` 升级到 v1.6.0。

## 常用离线命令

```bash
ansgo-admin status
ansgo-admin info
ansgo-admin logs all
ansgo-admin restart all
ansgo-admin regen ss
ansgo-admin regen-landing <ID>
ansgo-admin cert status
ansgo-admin cert renew
ansgo-admin cert issue
ansgo-admin upgrade --yes --ver v1.6.0
```

Docker 中请在命令前加 `docker exec ansgo`，例如 `docker exec ansgo ansgo-admin status`。`regen2` 和 `group2` 仅保留为兼容别名；新落地配置通过面板“落地服务”页维护。`ansgo-admin update` 是单组件兼容入口，不能替代统一升级器。

## 资源、日志与故障定位

- 项目日志：`/var/log/ansgo/`；升级失败优先查看 `/var/log/ansgo/upgrade.log`。
- 备份：`/etc/ansgo-backup/<类别>-<时间戳>[-n].tar.gz`；使用 `ansgo-admin restore` 恢复含 `manifest.json` 的归档。
- 资源限制：`/etc/systemd/system/<UNIT>.service.d/10-ansgo-limits.conf`。查看 `systemctl cat <UNIT>`；自定义后执行 `systemctl daemon-reload && systemctl restart <UNIT>`。安装和升级会保留用户已修改的 drop-in。
- 服务撞到 systemd 启动速率限制时，先在面板点“修复”，或执行 `systemctl reset-failed <UNIT>` 后重启服务。
- 空间紧张时执行 `ansgo-admin prune --yes`，不要无差别运行 Docker 全局 prune。

## 下载源覆盖

安装器与升级器只在当前进程读取以下环境变量，均不会写入已安装脚本：

```bash
ANSGO_RAW_BASE=<DEPLOY_BASE_URL> \
ANSGO_REL_BASE=<RELEASE_BASE_URL> \
ANSGO_RELEASE_API=<RELEASE_API_URL> \
/usr/local/bin/ansgo-upgrade --yes --ver v1.6.0
```

- `ANSGO_RAW_BASE`：目标版本的 `deploy` 目录 URL。
- `ANSGO_REL_BASE`：release 下载根，脚本按 `<BASE>/<VERSION>/<ASSET>` 访问。
- `ANSGO_RELEASE_API`：release 元数据根，`--auto` 还会访问 `<BASE>/latest`。

覆盖源必须镜像官方路径结构和完整、可信的资产；不要在文档、shell 历史或配置仓库中保存真实凭证。

## 卸载

```bash
# 保留配置/证书/卷
bash install.sh --uninstall

# 彻底删除配置、密钥、证书、备份和相关容器数据
bash install.sh --uninstall --purge
```

安装器为交互确认专门读取 `/dev/tty`，管道模式在有终端时可用；无 TTY 的自动化环境无法输入必须的 `yes`，因此不能安全执行卸载。

手工拆装二进制、手工 `scp` 覆盖运行中二进制、或使用旧的 `/etc/ansgo-backup-upgrade-*` 路径，都不是 v1.6.0 的常规部署或回滚流程。
