# ANS-GO

在低配 VPS 上部署 Shadowsocks、AnyTLS、SOCKS5、NaiveProxy 与 Go Web 管理面板。支持裸金属 systemd 与 Docker 一体化部署，共享一张证书，并提供可恢复升级、离线管理和多落地服务。

![status](https://img.shields.io/badge/status-已部署验证-brightgreen) ![version](https://img.shields.io/badge/latest_release-v1.6.0-blue) ![license](https://img.shields.io/badge/license-MIT-blue)

> 所有命令默认以 `root` 执行；非 root 用户请加 `sudo`。当前最新稳定版为 **v1.6.0**，GitHub Release 提供 6 项资产、`SHA256SUMS` 与 `ghcr.io/6667084/ansgo:v1.6.0` / `latest` 多架构镜像。

## 快速开始

```bash
# 交互式安装（首次使用推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)

# 裸金属非交互安装：Dynu DNS-01 自动签发证书
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --non-interactive
```

安装完成后，使用安装摘要中的 URL 登录面板，在“服务管理”页按需安装代理服务。端口和面板路径未显式指定时都会随机生成。

## ⚡ 一键命令速查

`<...>` 是必须由你替换的占位符。除特别标注外，示例均可直接复制。

| 场景 | 命令 |
|---|---|
| 交互安装 | `bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)` |
| 裸金属 acme 非交互安装 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> --email <EMAIL> --non-interactive` |
| 手动证书安装 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --domain your-domain.com --cert-mode manual --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH> --non-interactive` |
| Docker 安装 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> --email <EMAIL> --docker --non-interactive` |
| nginx/宝塔共存 | 在上述安装参数中加入 `--no-caddy`；通常同时使用 `--cert-mode manual --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH>` |
| 落地机独立 SS | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --landing --port <PORT> --non-interactive` |
| 升级（自动识别形态） | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \| bash -s -- --yes` |
| 升级到指定版本 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \| bash -s -- --yes --ver v1.6.0` |
| 查看状态 / URI | `ansgo-admin status` / `ansgo-admin info`；Docker：`docker exec ansgo ansgo-admin status` |
| 查看日志 | `ansgo-admin logs all`；或 `journalctl -u ansgo-panel -u sing-box -u caddy -n 200 --no-pager` |
| 清理空间 | `ansgo-admin prune --yes`；Docker：`docker exec ansgo ansgo-admin prune --yes` |
| 列出并恢复最近备份 | `ls -lt /etc/ansgo-backup/*.tar.gz`，然后执行 `ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz`；不传参数时 `ansgo-admin restore` 选择最新含 manifest 的归档 |
| 卸载，保留配置 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --uninstall` |
| 彻底卸载 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \| bash -s -- --uninstall --purge` |
| 本次下载源覆盖 | `ANSGO_RAW_BASE=<DEPLOY_BASE_URL> ANSGO_REL_BASE=<RELEASE_BASE_URL> ANSGO_RELEASE_API=<RELEASE_API_URL> bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh) <安装参数>` |

升级脚本不带 `--yes` 时会从 `/dev/tty` 读取确认；因此 `curl | bash` 在有交互终端时可用，但自动化必须显式加 `--yes`。安装器的交互读取也优先使用 `/dev/tty`；无 TTY 的环境请使用完整参数加 `--non-interactive`。卸载始终需要在 `/dev/tty` 输入 `yes`，无 TTY 的自动化环境不能安全执行卸载。

面板“系统维护”页可检查更新、在裸金属上启动一键升级、查看结果、清理空间，并管理默认关闭的自动升级。Docker 部署会提示你在宿主机运行升级命令。低于 v1.6.0 的面板没有该页的升级入口，先运行上表的 `upgrade.sh --yes` 升级一次。

## 安装说明

### 裸金属与 Docker

- 裸金属适合 LXC、256MB 起的低配主机；caddy、sing-box、ansgo-panel 由 systemd 分别管理。
- Docker 适合 KVM 或资源更充足的主机；镜像为 `ghcr.io/6667084/ansgo:latest`，安装器自动写入资源、日志和进程数限制。可用 `--docker-mem <MB>` 覆盖容器内存硬上限。
- `--no-caddy` 不部署 caddy 的 `:80/:443` 站点，让 nginx 或宝塔继续占用 Web 端口；NaiveProxy 仍可使用独立端口。

### 证书

默认 `acme` 模式通过 Dynu DNS-01 签发，使用 `--dynu-key <DYNU_API_KEY>`；旧 OAuth 参数 `--dynu-client-id` 与 `--dynu-secret` 保留兼容。已有证书请使用 `manual` 模式。Docker manual 模式下，按面板“证书管理”页生成的宿主同步任务将证书复制到固定同步目录；不要自行挂载任意宿主证书路径。

### 常用安装参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--domain <DOMAIN>` | 必填 | 域名 |
| `--dynu-key <KEY>` | acme 需要 | Dynu API Key |
| `--email <EMAIL>` | 自动推导 | ACME 邮箱 |
| `--cert-mode acme\|manual` | `acme` | 证书来源 |
| `--cert-fullchain <PATH>` / `--cert-privkey <PATH>` | manual 必填 | 手动证书与私钥绝对路径 |
| `--ss-port`、`--anytls-port`、`--socks-port`、`--naive-port`、`--panel-port` | 随机 `10000-65535` | 不指定时自动避开冲突和已占用端口 |
| `--panel-user <USER>` | `admin` | 面板用户 |
| `--panel-password <PASS>` / `--panel-url-path /<PATH>/` | 随机 | 面板凭证与路径 |
| `--panel-title <TITLE>` | 空 | 节点信息基名 |
| `--server-ip <IP>` | 空 | NAT/VPC 时应填真实公网入口 IP |
| `--docker` / `--docker-mem <MB>` | 关闭 / 自动计算 | Docker 一体化和内存上限 |
| `--no-caddy` | 关闭 | 与现有 Web 服务器共存 |
| `--landing --port <PORT>` | — | 独立 SS 落地机模式 |
| `--non-interactive` | 关闭 | 自动化部署必须指定 |

完整参数以 `bash install.sh --help` 为准。

## 更新、备份与回滚

统一升级器会从目标版本暂存脚本和资产，校验发布清单后才备份、迁移、切换和验证；失败时自动恢复备份。日志在 `/var/log/ansgo/upgrade.log`，结果在 `/var/lib/ansgo/upgrade.result`，已安装脚本位于 `/usr/local/bin/ansgo-upgrade`。

```bash
# 在服务器上执行；自动识别裸金属或 Docker
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \
  | bash -s -- --yes

# 指定形态或版本
/usr/local/bin/ansgo-upgrade --metal --yes --ver v1.6.0
/usr/local/bin/ansgo-upgrade --docker --yes --ver v1.6.0

# 仅自动升级 timer 使用：检查最新稳定版，无更新则不改动系统
/usr/local/bin/ansgo-upgrade --auto
```

备份统一保存在 `/etc/ansgo-backup/`，文件名为 `<类别>-<TIMESTAMP>[-n].tar.gz`。升级备份通常为 `upgrade-...tar.gz`，Docker 升级备份为 `docker-...tar.gz`。恢复命令只接受带 `manifest.json` 的归档：

```bash
ansgo-admin restore /etc/ansgo-backup/upgrade-<TIMESTAMP>.tar.gz
```

恢复会停止受管服务、恢复归档、重新生成配置并验证；若恢复后的验证失败，会尝试还原到恢复前快照。不要使用已废弃的 `/etc/ansgo-backup-upgrade-*` 路径或手工覆盖二进制作为常规升级手段。

下载源只对当前命令生效：

```bash
ANSGO_RAW_BASE=<DEPLOY_BASE_URL> \
ANSGO_REL_BASE=<RELEASE_BASE_URL> \
ANSGO_RELEASE_API=<RELEASE_API_URL> \
/usr/local/bin/ansgo-upgrade --yes --ver v1.6.0
```

其中 `ANSGO_RAW_BASE` 是目标 tag 的 `deploy` 目录 URL，`ANSGO_REL_BASE` 是 release 下载根，`ANSGO_RELEASE_API` 是 release 元数据根。覆盖源必须提供与官方相同的路径结构和完整、可信的资产。

## 部署后使用

1. 登录安装摘要给出的 HTTPS 面板地址。
2. 在“服务管理”页安装需要的 Shadowsocks、AnyTLS、SOCKS5 或 NaiveProxy。
3. 在“节点信息”页复制 URI；在“落地服务”页创建额外 AnyTLS 入站，并选择 SS 或 SOCKS5 远端出口。v1.6.0 会分别保存两套远端草稿；`remote_enabled` 关闭时仍按 direct 出口工作。
4. 在“系统维护”页查看资源/磁盘、检查更新、清理空间；仅裸金属支持从面板发起升级与自动升级 timer。
5. 通过 SSH 使用 `ansgo-admin` 作为面板不可用时的兜底入口：

```bash
ansgo-admin status
ansgo-admin info
ansgo-admin logs all
ansgo-admin regen ss
ansgo-admin regen-landing <ID>
ansgo-admin cert status
ansgo-admin cert renew
ansgo-admin cert issue
ansgo-admin backup
ansgo-admin prune --yes
ansgo-admin upgrade --yes --ver v1.6.0
```

`regen2` 和 `group2` 是兼容别名；新部署请在面板“落地服务”页管理落地配置。`ansgo-admin update` 仅保留单组件兼容入口，不应用于跨版本升级。

## 卸载

```bash
# 保留配置、证书和 Docker 卷；需在终端输入 yes
bash install.sh --uninstall

# 删除配置、密钥、证书、备份和相关容器数据；需在终端输入 yes
bash install.sh --uninstall --purge
```

网络下载执行方式见速查表。卸载命令有交互确认，建议在连接到目标主机的终端中执行；无 TTY 的 CI 或自动化环境不能替代人工确认。

## 故障排查

| 现象 | 检查与处理 |
|---|---|
| 升级失败或界面未变化 | 查看 `tail -n 200 /var/log/ansgo/upgrade.log`；升级器在切换后失败会自动回滚。成功后硬刷新浏览器。旧面板先用 `upgrade.sh --yes` 升到 v1.6.0。 |
| 服务显示 `start-limit-hit` | 在面板“服务管理”点“修复”；SSH 可执行 `systemctl reset-failed <UNIT>` 后，再 `systemctl restart <UNIT>`。 |
| 服务被 OOM 杀掉或内存太紧 | `journalctl -u ansgo-panel -u sing-box -u caddy -n 200 --no-pager`；查看 `systemctl cat <UNIT>` 中的 `10-ansgo-limits.conf`。如需调整，修改对应 `/etc/systemd/system/<UNIT>.service.d/10-ansgo-limits.conf`，执行 `systemctl daemon-reload && systemctl restart <UNIT>`；用户修改过的 drop-in 不会被升级脚本覆盖。 |
| 磁盘空间不足 | `ansgo-admin prune --yes`，再检查 `du -sh /etc/ansgo-backup /var/log/ansgo`。 |
| 证书签发或续期失败 | 查看 `/var/log/ansgo/cert-issue.log`，确认域名、Dynu 凭证与 DNS；manual 模式不能使用 `cert renew`。 |
| 远端落地不通 | 面板对落地执行健康检测，确认 `remote_enabled`、当前 `remote_type`、凭证与远端端口；SS2022 还需两端时间同步。 |
| 面板不可访问 | `ansgo-admin status`、`ansgo-admin logs panel`；确认安装摘要中的随机面板端口和路径。 |

## 版本历史

v1.6.0 的变化见 [release notes](docs/release-v1.6.0.md)。完整历史和下载资产以 GitHub Releases 为准。

## 安全提示

- 不要把 API Key、密码、节点 URI、真实 IP 或真实域名写进 issue、日志或提交。
- 手动设置密码时避免 shell 历史泄露；优先使用交互安装或安全的变量注入方式。
- `--server-ip` 应填写客户端实际可连接的公网入口，而非 NAT/VPC 的公网出口猜测值。
