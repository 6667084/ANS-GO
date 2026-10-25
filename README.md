# ANS-GO

在低配 VPS 上部署 Shadowsocks、AnyTLS、SOCKS5、NaiveProxy 与 Go Web 管理面板。支持裸金属 systemd 与 Docker 一体化部署，共享一张证书，并提供可恢复升级、离线管理和多落地服务。

![status](https://img.shields.io/badge/status-已部署验证-brightgreen) ![version](https://img.shields.io/badge/latest_release-v1.6.2-blue) ![license](https://img.shields.io/badge/license-MIT-blue)

> 所有命令默认以 `root` 执行；非 root 用户请加 `sudo`。`<...>` 是需替换的占位符。当前稳定版为 **v1.6.2**，Release 提供 6 项资产、`SHA256SUMS` 与 `ghcr.io/6667084/ansgo:v1.6.2` / `latest` 多架构镜像。

## 🚀 一键安装

### 裸金属（LXC / 低配推荐）

适合 256MB 起的低配 VPS；`ansgo-panel`、`sing-box`、`caddy` 由 systemd 分别管理。

```bash
# Dynu DNS-01 自动签发证书：最常用的非交互安装
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --non-interactive
```

```bash
# 交互安装：首次使用推荐
bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)
```

### Docker 一体化（KVM 推荐）

适合 KVM 或资源更充足的主机。安装后 compose 目录固定为 `/etc/ansgo-docker`，容器名固定为 `ansgo`。

```bash
# Dynu DNS-01 自动签发证书：最常用的非交互安装
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --docker --non-interactive
```

```bash
# 交互安装后在菜单中选择 Docker
bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)
```

<details>
<summary>手动证书、Web 共存和落地机变体</summary>

```bash
# 裸金属或 Docker 手动证书：Docker 时在末尾增加 --docker
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --cert-mode manual \
      --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH> \
      --non-interactive

# nginx / 宝塔继续占用 :80/:443；通常配合已有手动证书
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --cert-mode manual \
      --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH> \
      --no-caddy --non-interactive

# 独立 Shadowsocks 落地机
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --landing --port <PORT> --non-interactive
```

Docker 的 manual 模式请按面板“证书管理”页生成宿主同步任务；不要自行把任意宿主证书路径挂入容器。

</details>

## 🔄 一键升级

```bash
# 自动识别裸金属或 Docker；Docker 必须在宿主机执行
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh | bash -s -- --yes
```

裸金属 v1.6.0+ 也可在面板“系统维护”页检查并发起升级；Docker 面板会提示回宿主机执行上面的命令。升级完成后请硬刷新浏览器（`Ctrl+Shift+R` / `Cmd+Shift+R`）。

<details>
<summary>指定版本、自动升级与升级说明</summary>

```bash
# 已安装升级器：指定部署形态或版本
/usr/local/bin/ansgo-upgrade --metal --yes --ver v1.6.2
/usr/local/bin/ansgo-upgrade --docker --yes --ver v1.6.2

# 仅裸金属：自动升级 timer 默认关闭
systemctl enable --now ansgo-autoupgrade.timer
systemctl disable --now ansgo-autoupgrade.timer
```

升级器先暂存、校验、备份，再切换和验证；失败会自动回滚。未带 `--yes` 时会从 `/dev/tty` 确认，自动化与管道执行必须显式使用 `--yes`。若主机同时存在两种部署标记，升级器会拒绝猜测，请加 `--metal` 或 `--docker`。

</details>

## 🧰 常用命令

<details>
<summary>裸金属常用命令</summary>

| 场景 | 命令 |
|---|---|
| 重置面板密码 | `ansgo-admin panel-pass` |
| 重置面板路径 | `ansgo-admin panel-path` |
| 重置面板端口 | `ansgo-admin panel-port <PORT>` |
| 查看状态、端口、资源、证书 | `ansgo-admin status` |
| 查看节点信息 / URI | `ansgo-admin info` |
| 查看日志 | `ansgo-admin logs all` |
| 重启全部服务 | `ansgo-admin restart all` |
| 重启单项服务 | `ansgo-admin restart <目标>`；目标为 ss、anytls、socks、naive、panel。 |
| 重置代理凭证 | `ansgo-admin regen <目标>`；目标为 ss、anytls、socks、naive。 |
| 重置某条落地凭证 | `ansgo-admin regen-landing <ID>` |
| 查看证书 / 续期 / 签发 | `ansgo-admin cert status` / `ansgo-admin cert renew` / `ansgo-admin cert issue` |
| 重载证书 | `ansgo-cert-reload` |
| 清理空间 | `ansgo-admin prune --yes` |
| 创建日常备份 | `ansgo-admin backup` |
| 恢复日常备份 | `ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz` |
| 查看升级日志 | `tail -n 200 /var/log/ansgo/upgrade.log` |
| 升级 | `ansgo-admin upgrade --yes` |
| 卸载（保留配置） | 使用下方“卸载”中的在线命令。 |
| 彻底卸载 | 使用下方“卸载”中的在线命令并追加 `--purge`。 |

</details>

<details>
<summary>Docker 常用命令（均在宿主机执行）</summary>

| 场景 | 命令 |
|---|---|
| 重置面板密码 | `docker exec -it ansgo ansgo-admin panel-pass` |
| 重置面板路径 | `docker exec -it ansgo ansgo-admin panel-path` |
| 重置面板端口 | `docker exec -it ansgo ansgo-admin panel-port <PORT>` |
| 查看状态、端口、资源、证书 | `docker exec ansgo ansgo-admin status` |
| 查看节点信息 / URI | `docker exec ansgo ansgo-admin info` |
| 查看容器日志 | `cd /etc/ansgo-docker && docker compose logs --tail=200 ansgo` |
| 查看容器内服务日志 | `docker exec ansgo ansgo-admin logs all` |
| 重启整个一体化容器 | `cd /etc/ansgo-docker && docker compose restart ansgo` |
| 重启容器内单项服务 | `docker exec ansgo ansgo-admin restart <目标>`；目标为 ss、anytls、socks、naive、panel。 |
| 重置代理凭证 | `docker exec -it ansgo ansgo-admin regen <目标>`；目标为 ss、anytls、socks、naive。 |
| 重置某条落地凭证 | `docker exec -it ansgo ansgo-admin regen-landing <ID>` |
| 查看证书 / 续期 / 签发 | `docker exec ansgo ansgo-admin cert status` / `docker exec -it ansgo ansgo-admin cert renew` / `docker exec -it ansgo ansgo-admin cert issue` |
| 重载证书 | `docker exec ansgo ansgo-cert-reload` |
| 清理空间 | `docker exec ansgo ansgo-admin prune --yes` |
| 创建容器内日常备份 | `docker exec ansgo ansgo-admin backup` |
| 恢复容器内日常备份 | `docker exec -it ansgo ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz` |
| 查看宿主升级备份 | `ls -lt /etc/ansgo-backup/docker-*.tar.gz` |
| 升级 | 执行上方“一键升级”命令（必须在宿主机）。 |
| 卸载（保留卷） | 使用下方“卸载”中的在线命令。 |
| 彻底卸载（删除卷、镜像及配置） | 使用下方“卸载”中的在线命令并追加 `--purge`。 |

容器内 `ansgo-admin backup` 的归档位于 `/etc/ansgo-backup/`。自 **v1.6.2** 起，该目录挂载为命名卷 `ansgo_backup`，升级脚本会为存量部署自动补上挂载，容器重建后仍保留；**v1.6.1 及更早版本**该目录不在持久卷中，升级重建会丢失。统一升级器创建的 `docker-*.tar.gz` 位于**宿主机** `/etc/ansgo-backup/`，用于升级自动回滚，不能和容器内日常备份混为一谈。

</details>

## ✨ 核心特性

- Shadowsocks-2022、AnyTLS、SOCKS5 和 NaiveProxy 可按需启用；未使用的协议不占监听端口和常驻内存。
- 多落地服务为 SS 与 SOCKS5 分别保存远端草稿，切换当前生效协议不会丢失另一套配置。
- 面板支持暗/亮主题、移动端抽屉、未保存提示、统一错误反馈、健康检查和系统维护。
- 裸金属服务与 Docker 容器均有内存、进程数、日志和备份保留边界，适配低配主机。
- ACME Dynu DNS-01 与已有证书 manual 模式二选一；升级采用“暂存校验 → 备份 → 切换验证 → 失败回滚”。

<details>
<summary>安装详细说明</summary>

### 裸金属

- 推荐 LXC 和 256MB 起的小型 VPS；caddy、sing-box、ansgo-panel 是独立 systemd 服务。
- `--no-caddy` 不部署 caddy 的 `:80/:443` 站点，让 nginx、宝塔或其他 Web 服务共存；NaiveProxy 仍使用独立端口。
- 未显式指定的代理端口与面板端口会在 `10000-65535` 随机生成，并避开冲突端口。

### Docker

- 推荐 KVM 或资源更充足的主机；all-in-one 容器以 host 网络运行，配置、密钥、证书和 acme 状态使用持久卷。
- 安装器会生成 `/etc/ansgo-docker/docker-compose.yml` 与权限为 600 的 `ansgo.env`；日常 compose 命令先执行 `cd /etc/ansgo-docker`。
- 可用 `--docker-mem <MB>` 覆盖容器内存硬上限。Docker Compose v1 不兼容当前升级流程，请使用 Compose v2。

### 证书

默认 `acme` 通过 Dynu DNS-01 签发，推荐使用 `--dynu-key <DYNU_API_KEY>`；旧 `--dynu-client-id` 与 `--dynu-secret` 仅为兼容保留。已有证书使用 `manual` 模式。

</details>

<details>
<summary>参数全集</summary>

以 `bash install.sh --help` 为准；除 `--landing` 外，未指定端口随机生成。

| 参数 | 说明 |
|---|---|
| `--domain <DOMAIN>` | 必填域名。 |
| `--dynu-key <KEY>` | Dynu API Key，ACME 推荐凭证。 |
| `--dynu-client-id <ID>`、`--dynu-secret <SECRET>` | 兼容旧 Dynu OAuth 配置。 |
| `--email <EMAIL>` | ACME 注册邮箱，默认 `admin@<DOMAIN>`。 |
| `--cert-mode <acme 或 manual>` | 选择自动签发或已有证书。 |
| `--cert-fullchain <PATH>`、`--cert-privkey <PATH>` | manual 模式必填的绝对路径。 |
| `--ss-port`、`--anytls-port`、`--socks-port`、`--naive-port`、`--panel-port` | 指定监听端口；Naive 端口不要使用 `443`。 |
| `--panel-user`、`--panel-password`、`--panel-url-path`、`--panel-title` | 设置管理员、密码、路径和节点信息基础名。 |
| `--server-ip <IP>` | 显式公网入口 IPv4/IPv6；NAT/VPC 下建议填写。 |
| `--ss-password`、`--anytls-password`、`--anytls-uuid` | 指定 SS / AnyTLS 凭证。 |
| `--socks-user`、`--socks-password`、`--naive-user`、`--naive-password` | 指定 SOCKS5 / Naive 凭证。 |
| `--disguise-panel`、`--disguise-naive` | 伪装站：`proxy:<URL>` 或 `page`。 |
| `--docker`、`--docker-mem <MB>` | 启用 Docker 与设置容器内存硬上限。 |
| `--no-caddy` | 让其他 Web 服务占用 `:80/:443`。 |
| `--force-bin` | 强制重新获取 sing-box 与 caddy。 |
| `--non-interactive` | 禁止交互；自动化场景必须提供完整参数。 |
| `--landing --port <PORT>` | 切换为独立 Shadowsocks 落地机安装。 |
| `--uninstall`、`--purge` | 卸载；`--purge` 仅与 `--uninstall` 同用。 |

升级器参数：`--metal` / `--docker` 强制形态，`--ver vX.Y.Z` 指定版本，`--yes` 跳过确认，`--auto` 只供裸金属自动升级 timer 查询最新稳定版。

</details>

<details>
<summary>面板功能导览</summary>

| 页面 | 用途 |
|---|---|
| 仪表盘 | 汇总内存、负载、运行时长、TCP、证书与服务状态。 |
| 节点信息 | 显示已启用服务的地址、端口、凭证、URI 和二维码。 |
| 服务管理 | 安装、卸载、启停、重启、修复、检测并编辑四种代理服务。 |
| 落地服务 | 创建多个 AnyTLS 入站，分别维护 SS / SOCKS5 远端草稿。 |
| 证书管理 | 切换 acme/manual、配置 Dynu、签发、续期、重载及 Docker manual 同步。 |
| 系统维护 | 查看资源、磁盘、备份和日志；裸金属可升级、管理自动升级和清理空间。 |
| 面板设置 / 运行日志 | 管理入口与安全参数，或按服务查看最近日志。 |

</details>

<details>
<summary>资源占用与上限</summary>

裸金属的三项服务使用 `/etc/systemd/system/<UNIT>.service.d/10-ansgo-limits.conf`。生成器按可用内存设置 `MemoryHigh`、`MemoryMax`、`TasksMax`、`CPUWeight`、`OOMScoreAdjust` 和 `GOMEMLIMIT`；用户手动修改过的 drop-in 不会被升级静默覆盖。

| 对象 | 默认边界 |
|---|---|
| 项目日志 | `/var/log/ansgo/` 单文件超过 1MB 时裁剪，保留末尾 256KB。 |
| journald | 最多 50MB、单文件 10MB、运行时 16MB、最多保留 14 天；已有更严格设置时取更小值。 |
| 配置备份 | `/etc/ansgo-backup/`；每类默认 5 份，升级类最多 2 份，全部超过 200MB 时从最旧开始清理。 |
| Docker 日志 | json-file 轮转 `10m × 3`。 |
| Docker 资源 | 内存、内存+swap、PID 数和 CPU 受 compose 约束；安装时可用 `--docker-mem` 覆盖。 |

调整裸金属预算后执行：

```bash
systemctl daemon-reload
systemctl restart <UNIT>
```

</details>

<details>
<summary>备份与回滚</summary>

### 裸金属

```bash
# 日常备份、清理、恢复
ansgo-admin backup
ansgo-admin prune --yes
ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz

# 升级日志与升级备份
tail -n 200 /var/log/ansgo/upgrade.log
ls -lt /etc/ansgo-backup/upgrade-*.tar.gz
```

### Docker（宿主机）

```bash
# 容器内日常备份、清理、恢复
docker exec ansgo ansgo-admin backup
docker exec ansgo ansgo-admin prune --yes
docker exec -it ansgo ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz

# 宿主升级日志与升级器创建的 Docker 回滚归档
tail -n 200 /var/log/ansgo/upgrade.log
ls -lt /etc/ansgo-backup/docker-*.tar.gz
```

容器内 `ansgo-admin backup` 的归档位于 `/etc/ansgo-backup/`。自 **v1.6.2** 起，该目录是命名卷 `ansgo_backup`，升级脚本会为存量 Docker 部署自动补齐挂载，容器重建后仍保留；**v1.6.1 及更早版本**该目录不持久化，升级重建会丢失。宿主 `/etc/ansgo-backup/docker-*.tar.gz` 是统一升级器的回滚归档，与容器内日常备份不同。

恢复命令仅接受含 `manifest.json` 的归档。升级器的 Docker 归档用于自动回滚；常规人工恢复优先使用容器内 `ansgo-admin backup` 创建的归档。

</details>

<details>
<summary>卸载</summary>

```bash
# 自动识别裸金属 / Docker，保留配置、证书与 Docker 卷
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh | bash -s -- --uninstall

# 彻底删除配置、密钥、证书、备份、相关卷、镜像和受管调优文件
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh | bash -s -- --uninstall --purge
```

卸载必须在终端中输入 `yes` 确认；无 TTY 的 CI 或自动化环境不能安全替代人工确认。Docker 用户在宿主机执行，默认保留 `/etc/ansgo-docker/` 和数据卷，`--purge` 才删除。

</details>

<details>
<summary>故障排查</summary>

| 现象 | 裸金属 | Docker（宿主机） |
|---|---|---|
| 升级失败或界面未变化 | `tail -n 200 /var/log/ansgo/upgrade.log` | 同左；确认在宿主执行升级命令。 |
| 服务启动失败 | `journalctl -u ansgo-panel -u sing-box -u caddy -n 200 --no-pager` | `cd /etc/ansgo-docker && docker compose logs --tail=200 ansgo` |
| 服务被 systemd 限流 | `systemctl reset-failed <UNIT> && systemctl restart <UNIT>` | `docker exec ansgo systemctl reset-failed <UNIT> && docker exec ansgo systemctl restart <UNIT>` |
| 磁盘紧张 | `ansgo-admin prune --yes` | `docker exec ansgo ansgo-admin prune --yes`；不要执行全局 `docker system prune`。 |
| 证书签发或续期失败 | `tail -n 200 /var/log/ansgo/cert-issue.log` | `docker exec ansgo ansgo-admin logs all`，并检查 compose 日志。 |
| 面板不可访问 | `ansgo-admin status && ansgo-admin logs panel` | `docker exec ansgo ansgo-admin status && docker exec ansgo ansgo-admin logs panel` |

手动证书模式不能使用 `cert renew`。远端落地不通时，在面板对该落地执行健康检测，确认 `remote_enabled`、当前 `remote_type`、凭证和远端端口；SS2022 还要求两端时间同步。

</details>

<details>
<summary>架构</summary>

```text
Browser / Client
      |
HTTPS panel / proxy protocols
      |
+------------------------+------------------------+
|                                                 |
裸金属：systemd                                  Docker：all-in-one
|                                                 |
ansgo-panel + caddy + sing-box                    容器内 systemd + 持久卷
      |
ansgo-admin（SSH / docker exec 离线维护）
      |
可选 AnyTLS 落地 -> SS 或 SOCKS5 远端出口
```

`ansgo-genconf` 只读取 `panel.json` 与 `secrets.env`，校验通过后原子替换 caddy / sing-box 运行配置。关闭落地远端出口时，落地走 direct。

</details>

<details>
<summary>仓库结构</summary>

```text
ANS-GO/
├── install.sh                  # 新安装、落地机、卸载与 purge
├── deploy/
│   ├── upgrade.sh              # 裸金属 / Docker 统一升级器
│   ├── ansgo-admin             # SSH / 容器离线管理命令
│   ├── ansgo-limits            # 资源、日志、备份和迁移共享实现
│   ├── ansgo-genconf           # caddy / sing-box 配置生成与预检
│   ├── docker-compose.yml      # Docker all-in-one 模板
│   └── panel/                  # Go 面板与嵌入式 Web 前端
├── docs/                       # 发布说明和 v1.6.0 契约
└── scripts/                    # 安装、升级、清理与 UI 回归测试
```

</details>

<details>
<summary>版本历史</summary>

### v1.6.2

- 面板「忘记密码」等 SSH 兜底提示区分部署形态：登录页同时列出裸金属与 Docker（`docker exec -it ansgo ansgo-admin panel-pass`）命令，登录后按实际形态显示。
- Docker 日常备份目录 `/etc/ansgo-backup` 改为命名卷 `ansgo_backup`，容器重建/升级后不再丢失；升级脚本自动为存量部署补挂载。
- README 按裸金属 / Docker 分开教程与常用命令，默认只展开核心一键命令。

详见 [v1.6.2 release notes](docs/release-v1.6.2.md)。

### v1.6.1

- Docker 升级仅最小化编辑原始 compose，不会把 `env_file` 凭证展开写回文件。
- 拉镜像前预检磁盘，只清理本项目可确认无用的旧镜像；修复 `pipefail` 下的备份校验问题。
- `--uninstall --purge` 清理本项目所有版本镜像与受管调优文件，旧安装器可自动补装共享库。

详见 [v1.6.1 release notes](docs/release-v1.6.1.md)。

### v1.6.0

- 落地服务改为独立 SS / SOCKS5 草稿与事务化保存。
- 控制台新增暗/亮主题、移动端抽屉、未保存提示和“系统维护”页。
- 裸金属与 Docker 统一资源、日志、备份和可恢复升级边界。

详见 [v1.6.0 release notes](docs/release-v1.6.0.md)；更早版本、下载资产和校验文件以 GitHub Releases 为准。

</details>

<details>
<summary>安全提示</summary>

- 不要把 API Key、密码、节点 URI、真实 IP 或真实域名写进 issue、日志或提交。
- 手动设置密码时避免 shell 历史泄露；优先交互安装或安全的变量注入方式。
- `--server-ip` 应填写客户端实际可连接的公网入口，而不是 NAT/VPC 的公网出口猜测值。
- 安装器与升级器可为单次命令设置 `ANSGO_RAW_BASE`、`ANSGO_REL_BASE`、`ANSGO_RELEASE_API` 下载源覆盖；覆盖源必须保持官方路径结构、版本和可信校验资产。

</details>
