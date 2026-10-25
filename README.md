# ANS-GO

在低配 VPS 上部署 Shadowsocks、AnyTLS、SOCKS5、NaiveProxy 与 Go Web 管理面板。支持裸金属 systemd 与 Docker 一体化部署，共享一张证书，并提供可恢复升级、离线管理和多落地服务。

![status](https://img.shields.io/badge/status-已部署验证-brightgreen) ![version](https://img.shields.io/badge/latest_release-v1.6.1-blue) ![license](https://img.shields.io/badge/license-MIT-blue)

> 所有命令默认以 `root` 执行；非 root 用户请加 `sudo`。当前最新稳定版为 **v1.6.1**，GitHub Release 提供 6 项资产、`SHA256SUMS` 与 `ghcr.io/6667084/ansgo:v1.6.1` / `latest` 多架构镜像。

## ✨ 核心特性

- **四种代理协议**：Shadowsocks-2022、AnyTLS、SOCKS5 由 sing-box 承载，NaiveProxy 使用 caddy forward proxy；服务可独立安装、启停与检测。
- **面板优先**：安装阶段先准备面板、证书和伪装站；协议服务在 Web“服务管理”页按需启用，不使用就不占端口和内存。
- **全新控制台**：暗/亮主题、可折叠栏目、未保存提示、移动端抽屉导航、统一错误处理和服务状态提示，适合桌面与手机管理。
- **多落地服务**：可创建多个 AnyTLS 落地入站；每条落地分别保存 Shadowsocks 与 SOCKS5 两套远端草稿，切换生效协议不会丢另一套配置。
- **资源与磁盘边界**：三服务 systemd drop-in 限制内存、任务数与 CPU 权重；项目日志裁剪、journald 限额、备份保留和 `ansgo-admin prune` 防止低配机慢性耗尽。
- **可恢复升级**：统一升级器先暂存、校验、备份，再切换和验证；失败自动恢复。裸金属可在面板升级，自动升级 timer 默认关闭。
- **双部署形态**：低配 LXC 使用裸金属 systemd；KVM 可使用 Docker all-in-one，镜像同时支持 amd64 与 arm64。
- **证书双模式**：Dynu DNS-01 自动签发与已有证书 manual 模式二选一；Docker manual 模式提供受控的宿主证书同步。
- **Web 服务器共存**：`--no-caddy` 允许 nginx、宝塔或其他 Web 服务继续占用 `:80/:443`，ANS-GO 使用自己的面板和代理端口。
- **SSH 离线兜底**：`ansgo-admin` 提供状态、日志、证书、备份、恢复、密钥重置和升级入口，面板不可用时仍可维护。
- **默认安全边界**：面板密码 bcrypt 保存、会话与登录锁定、随机面板路径和端口、TLS、root-only 配置/备份权限，以及配置生成后的预检与回滚。

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
| 升级到指定版本 | `curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \| bash -s -- --yes --ver v1.6.1` |
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

## ⚙️ 参数全集

以下安装参数与 `bash install.sh --help`、脚本参数解析保持一致。除 `--landing` 外，未指定的端口会在 `10000-65535` 中随机生成，并避开冲突、已占用端口与保留端口；不要把旧版固定端口当作默认值。

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--domain <DOMAIN>` | 必填 | 域名；自动签发时应由 DNS 指向服务器。 |
| `--dynu-key <KEY>` | 空 | Dynu API Key，acme/DNS-01 推荐凭证。 |
| `--dynu-client-id <ID>` | 空 | 兼容旧配置的 Dynu OAuth Client ID，需同时提供 `--dynu-secret`。 |
| `--dynu-secret <SECRET>` | 空 | 兼容旧配置的 Dynu OAuth Secret。 |
| `--email <EMAIL>` | `admin@<DOMAIN>` | ACME 注册邮箱。 |
| `--cert-mode acme\|manual` | `acme` | 证书来源；`acme` 使用 Dynu DNS-01，`manual` 使用已有证书。 |
| `--cert-fullchain <PATH>` | 空 | manual 模式必填，完整证书文件绝对路径。 |
| `--cert-privkey <PATH>` | 空 | manual 模式必填，私钥文件绝对路径。 |
| `--ss-port <PORT>` | 随机 | Shadowsocks 监听端口。 |
| `--anytls-port <PORT>` | 随机 | AnyTLS 监听端口。 |
| `--socks-port <PORT>` | 随机 | SOCKS5 监听端口。 |
| `--naive-port <PORT>` | 随机 | NaiveProxy 监听端口；不要使用 `443`。 |
| `--panel-port <PORT>` | 随机 | HTTPS 管理面板端口。 |
| `--panel-user <USER>` | `admin` | 管理员用户名。 |
| `--panel-password <PASS>` | 随机 | 管理员密码；自定义时必须为 6-64 字符。 |
| `--panel-url-path /<PATH>/` | 随机 | 面板 URL 路径，格式如 `/my-panel/`。 |
| `--panel-title <TITLE>` | 空 | 节点信息基础名；浏览器标题为 `<TITLE>_ANS`，URI 名称使用对应短后缀；留空显示 `Manage`。 |
| `--server-ip <IP>` | 空 | 显式公网入口 IPv4/IPv6。NAT/VPC 下入口不等于出口时应填写；留空时面板只在空值启动时尝试探测并保存。 |
| `--ss-password <KEY>` | 随机 | SS2022 密钥；应是标准 base64，128 位方法需要解码后 16 字节。 |
| `--anytls-password <PASS>` | 随机 | AnyTLS 密码。 |
| `--anytls-uuid <UUID>` | 随机 | AnyTLS 用户 UUID，使用标准 UUID 格式。 |
| `--socks-user <USER>` | 随机 | SOCKS5 用户名；不能含冒号或空白。 |
| `--socks-password <PASS>` | 随机 | SOCKS5 密码；不能含冒号或空白。 |
| `--naive-user <USER>` | 随机 | NaiveProxy 用户名；不能含冒号或空白。 |
| `--naive-password <PASS>` | 随机 | NaiveProxy 密码；不能含冒号或空白。 |
| `--disguise-panel proxy:<URL>\|page` | `proxy:https://example.com` | `:443` 直访伪装站；仅 caddy 启用时生效。 |
| `--disguise-naive proxy:<URL>\|page` | `proxy:https://example.com` | NaiveProxy 端口的伪装站。 |
| `--docker` | 关闭 | 使用 `ghcr.io/6667084/ansgo` all-in-one 镜像部署。 |
| `--docker-mem <MB>` | 自动计算 | Docker 容器内存硬上限；宿主不大于 1G 时为内存的 70%，更大时为 512MB，swap 上限自动增加 256MB。 |
| `--no-caddy` | 关闭 | 不部署 caddy 的 `:80/:443` 站点，适合与 nginx/宝塔共存；NaiveProxy 仍可使用自己的端口。 |
| `--force-bin` | 关闭 | 强制从 Release 重新安装 sing-box 与 caddy，即使本机已有二进制。 |
| `--non-interactive` | 关闭 | 禁止交互；自动化场景必须提供所需参数。 |
| `--landing` | 关闭 | 切换到独立 Shadowsocks 落地机安装，后续参数原样转交落地脚本，例如 `--port <PORT> --non-interactive`。 |
| `--uninstall` | 关闭 | 自动识别 Docker/裸金属并卸载，保留配置与卷；仍需在终端输入 `yes`。 |
| `--purge` | 关闭 | 仅与 `--uninstall` 组合，清理配置、密钥、证书、备份、相关镜像和受管调优文件。 |
| `-h` / `--help` | — | 显示参数帮助后退出。 |

安装器与升级器均支持仅对当前命令生效的下载源覆盖：`ANSGO_RAW_BASE` 指向目标版本的 `deploy` 目录、`ANSGO_REL_BASE` 指向 release 下载根、`ANSGO_RELEASE_API` 指向 release 元数据根。使用自建镜像源时必须保留官方目录结构、版本和校验资产。

### 升级器参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--metal` | 自动识别 | 强制按裸金属路径升级；与 `--docker` 互斥。 |
| `--docker` | 自动识别 | 强制按 Docker 路径升级；与 `--metal` 互斥。 |
| `--ver vX.Y.Z` | 当前脚本内置版本 | 从指定 tag 获取脚本、Release 资产和 Docker 镜像。 |
| `--yes` / `-y` | 关闭 | 跳过 `/dev/tty` 确认；自动化与 `curl | bash` 推荐使用。 |
| `--auto` | 关闭 | 查询 GitHub 最新稳定 Release；没有更新时成功退出。此模式自动启用 `--yes`，供自动升级 timer 使用。 |
| `--help` / `-h` | — | 显示升级器帮助后退出。 |

当宿主同时存在裸金属和 Docker 部署标记时，升级器会拒绝猜测；请显式指定 `--metal` 或 `--docker`。Docker Compose v1 不支持当前模板所需字段，安装器和升级器会在修改宿主前提示安装 Compose v2。

## 🖥 面板功能导览

控制台是单页应用，所有页面共用暗/亮主题、侧栏折叠记忆和移动端抽屉导航。页面内的栏目可独立展开或收起；配置变更有未保存提示，异步请求失败会统一显示可操作的错误信息。

| 页面 | 用途 |
|---|---|
| **仪表盘** | 汇总服务器内存、负载、运行时长、TCP 连接、证书与四类服务的实际状态。 |
| **节点信息** | 只显示已启用服务的连接地址、端口、凭证、SNI、URI 与二维码；AnyTLS、SS、SOCKS5 和落地节点优先使用设置的公网入口 IP。 |
| **服务管理** | 分别安装、卸载、启停、重启、修复和健康检测 Shadowsocks、AnyTLS、SOCKS5、NaiveProxy；展开卡片即可编辑端口和凭证。 |
| **落地服务** | 创建多个独立 AnyTLS 入站；为每条落地保存 SS/SOCKS5 两套远端草稿，选择当前协议并显式控制是否通过远端出口。 |
| **证书管理** | 切换 acme/manual、保存 Dynu 凭证存在性配置、立即签发、续期、重载证书，并在 Docker manual 模式展示宿主同步方案。 |
| **系统维护** | 查看版本、部署形态、资源预算、磁盘/备份/日志占用；检查更新、裸金属一键升级、查看升级结果、启停自动升级和执行空间清理。 |
| **面板设置** | 管理节点信息、访问路径、端口、管理员、会话与登录锁定、伪装站和公网入口 IP；修改路径或端口会按提示重启面板。 |
| **运行日志** | 按面板、caddy、sing-box 等服务查看最近日志，快速定位启动、证书和配置问题。 |

面板升级入口只适用于裸金属，因为升级任务通过 systemd 脱离面板进程运行。Docker 页面会明确提示在宿主机执行统一升级命令。浏览器在升级后应硬刷新，以载入嵌入新面板二进制的前端资源。

## 📊 资源占用与上限

裸金属三服务均使用 `/etc/systemd/system/<UNIT>.service.d/10-ansgo-limits.conf`。`ansgo-limits` 读取宿主或 cgroup 可用内存后，按比例生成 `MemoryHigh`、`MemoryMax`、`TasksMax`、`CPUWeight`、`OOMScoreAdjust` 与 Go 运行时 `GOMEMLIMIT`。下表是 `MemoryMax` 的实际计算结果：

| 可用内存 | sing-box | caddy | ansgo-panel |
|---:|---:|---:|---:|
| 256M | 96M | 64M | 48M |
| 464M | 162M | 116M | 69M |
| 1G | 358M | 256M | 128M |
| 2G | 716M | 512M | 128M |

`MemoryHigh` 为对应 `MemoryMax` 的 80%，`GOMEMLIMIT` 为 `MemoryHigh` 的 80%。正常常驻内存实测约为：面板 **12MB**、caddy **43MB**、sing-box **40MB**；实际用量取决于协议、连接数、TLS 和宿主内核。

| 对象 | 默认边界 | 位置与操作 |
|---|---|---|
| 项目日志 | 单个文件超过 1MB 时裁剪，仅保留末尾 256KB | `/var/log/ansgo/`；升级日志为 `upgrade.log`，证书和生成日志同目录。 |
| journald | 最多 50MB、单文件最多 10MB、运行时最多 16MB、保留最多 14 天；若用户已有更严格配置则取更小值 | `/etc/systemd/journald.conf.d/60-ansgo.conf`。 |
| 配置备份 | 每类默认保留最近 5 份；升级类最多 2 份；全部备份超过 200MB 时从最旧开始清理 | `/etc/ansgo-backup/`，使用 `ansgo-admin prune --yes`。 |
| Docker 日志 | json-file 轮转 `10m × 3` | Docker compose 服务配置。 |
| Docker 资源 | 内存、内存+swap、PID 数与 CPU 权重受 compose 限制 | `--docker-mem <MB>` 可在安装时显式覆盖内存上限。 |

如需手动调整裸金属预算，编辑相应 drop-in，例如 `/etc/systemd/system/sing-box.service.d/10-ansgo-limits.conf`，再执行：

```bash
systemctl daemon-reload
systemctl restart sing-box
```

同理可对 `caddy` 或 `ansgo-panel` 操作。自动生成文件带内容指纹：安装或升级只会刷新未被用户修改的文件；检测到用户修改后会保留原文件，因此手动调优不会被静默覆盖。调整上限前请保留 SSH 会话，并结合 `journalctl` 和实际负载验证。

## 更新、备份与回滚

统一升级器会从目标版本暂存脚本和资产，校验发布清单后才备份、迁移、切换和验证；失败时自动恢复备份。日志在 `/var/log/ansgo/upgrade.log`，结果在 `/var/lib/ansgo/upgrade.result`，已安装脚本位于 `/usr/local/bin/ansgo-upgrade`。

```bash
# 在服务器上执行；自动识别裸金属或 Docker
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh \
  | bash -s -- --yes

# 指定形态或版本
/usr/local/bin/ansgo-upgrade --metal --yes --ver v1.6.1
/usr/local/bin/ansgo-upgrade --docker --yes --ver v1.6.1

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
/usr/local/bin/ansgo-upgrade --yes --ver v1.6.1
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
ansgo-admin upgrade --yes --ver v1.6.1
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
| 升级失败或界面未变化 | 查看 `tail -n 200 /var/log/ansgo/upgrade.log`；升级器在切换后失败会自动回滚。成功后硬刷新浏览器。旧面板先用 `upgrade.sh --yes` 升到当前版本。 |
| 服务显示 `start-limit-hit` | 在面板“服务管理”点“修复”；SSH 可执行 `systemctl reset-failed <UNIT>` 后，再 `systemctl restart <UNIT>`。 |
| 服务被 OOM 杀掉或内存太紧 | `journalctl -u ansgo-panel -u sing-box -u caddy -n 200 --no-pager`；查看 `systemctl cat <UNIT>` 中的 `10-ansgo-limits.conf`。如需调整，修改对应 `/etc/systemd/system/<UNIT>.service.d/10-ansgo-limits.conf`，执行 `systemctl daemon-reload && systemctl restart <UNIT>`；用户修改过的 drop-in 不会被升级脚本覆盖。 |
| 磁盘空间不足 | `ansgo-admin prune --yes`，再检查 `du -sh /etc/ansgo-backup /var/log/ansgo`。 |
| 证书签发或续期失败 | 查看 `/var/log/ansgo/cert-issue.log`，确认域名、Dynu 凭证与 DNS；manual 模式不能使用 `cert renew`。 |
| 远端落地不通 | 面板对落地执行健康检测，确认 `remote_enabled`、当前 `remote_type`、凭证与远端端口；SS2022 还需两端时间同步。 |
| 面板不可访问 | `ansgo-admin status`、`ansgo-admin logs panel`；确认安装摘要中的随机面板端口和路径。 |

## 🏗 架构

```text
                         Browser / Client
                    HTTPS panel / proxy protocols
                                  |
          +-----------------------+-----------------------+
          |                                               |
  Bare metal (systemd)                           Docker all-in-one
          |                                               |
  +-------+--------+                         +------------+-----------+
  |                |                         |                        |
ansgo-panel      caddy                    systemd                   volumes
  |                |                         |                        |
  |          :80/:443 disguise          ansgo-panel / caddy      config / certs
  |          NaiveProxy port             / sing-box / cron       / secrets persist
  |                |
  +-----------+----+-------------------------+
              |                              |
         sing-box                       ansgo-admin
  SS / AnyTLS / SOCKS5                SSH maintenance fallback
              |
       optional landing AnyTLS
              |
   SS or SOCKS5 remote egress
```

- `ansgo-panel` 管理配置、认证、证书操作、健康检查与系统维护。
- `ansgo-genconf` 只读取 `panel.json` 与 `secrets.env`，在临时文件完成校验后原子替换 caddy/sing-box 运行配置。
- caddy、sing-box、面板独立运行；修改某个代理协议不会直接中断管理面板。
- 备份、日志、资源限制和升级器在裸金属与 Docker 路径共享相同的边界规则。
- 多落地服务的入站始终是 AnyTLS；启用远端出口后只使用当前选中的 SS 或 SOCKS5 草稿，关闭远端时走 direct。

## 📁 仓库结构

```text
ANS-GO/
├── install.sh                  # 新安装、落地机、卸载与 purge 入口
├── deploy/
│   ├── upgrade.sh              # 裸金属 / Docker 统一升级器
│   ├── ansgo-admin             # SSH 离线管理命令
│   ├── ansgo-limits            # 资源、日志、备份和迁移共享实现
│   ├── ansgo-genconf           # caddy / sing-box 配置生成与预检
│   ├── ansgo-cert-issue.sh     # ACME DNS-01 签发
│   ├── ansgo-cert-reload       # 证书重载
│   ├── ansgo-landing.sh        # 独立 Shadowsocks 落地机安装
│   ├── docker-compose.yml      # Docker all-in-one 模板
│   ├── docker/                 # 容器 entrypoint
│   ├── systemd/                # caddy、sing-box、自动升级 timer unit
│   └── panel/                  # Go 面板与嵌入式 Web 前端
├── docs/
│   ├── release-v1.6.1.md       # 当前稳定性补丁说明
│   ├── release-v1.6.0.md       # 落地、控制台、资源与升级重构说明
│   └── v1.6.0-contract.md      # v1.6.0 接口契约
└── scripts/                    # 安装、升级、清理与 UI 回归测试
```

## 版本历史

### v1.6.1

- Docker 升级改为最小化编辑原始 compose，不再把 `env_file` 中的凭证展开写入 compose；注释、自定义挂载、权限和人工资源调优都会保留。
- 升级前预检 Docker 数据分区空间；仅清理本项目仓库中不运行、非目标版本的旧镜像，绝不全局 prune，也不触碰其他项目镜像或卷。
- 修复备份校验管道在 `pipefail` 下因 SIGPIPE 随机失败的问题，并在 Compose v1 不兼容时提前中止说明。
- `--uninstall --purge` 清理本项目所有版本镜像和受管调优文件；旧安装器缺少共享库时管理脚本会自动补装。

详见 [v1.6.1 release notes](docs/release-v1.6.1.md)。

### v1.6.0

- 落地服务升级为独立 SS/SOCKS5 双协议草稿，事务化保存，切换协议不丢配置，失败可恢复。
- 全新控制台增加暗/亮主题、移动端抽屉、折叠栏目、未保存提示与“系统维护”页。
- 裸金属和 Docker 统一加入资源限制、日志裁剪、journald/备份保留与清理边界。
- 升级器采用“暂存校验 → 备份 → 切换验证 → 失败回滚”；裸金属支持面板一键升级与默认关闭的周度自动升级。

详见 [v1.6.0 release notes](docs/release-v1.6.0.md)。更早版本、下载资产和校验文件以 GitHub Releases 为准。

## 安全提示

- 不要把 API Key、密码、节点 URI、真实 IP 或真实域名写进 issue、日志或提交。
- 手动设置密码时避免 shell 历史泄露；优先使用交互安装或安全的变量注入方式。
- `--server-ip` 应填写客户端实际可连接的公网入口，而非 NAT/VPC 的公网出口猜测值。
