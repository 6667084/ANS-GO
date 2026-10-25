# ANS-GO 部署文件

这里是安装、升级、离线管理和 systemd / Docker 部署资源。服务器部署教程与完整命令表以仓库根目录 [README](../README.md) 为准；本文件只说明部署资源和两种形态的对应入口。

当前发布版本为 **v1.6.1**。Release 包含面板、caddy-naive、sing-box 的 amd64 / arm64 资产和 `SHA256SUMS`；Docker 镜像为 `ghcr.io/6667084/ansgo:v1.6.1` 与 `latest`。

## 文件清单

| 文件或目录 | 用途 |
|---|---|
| `../install.sh` | 新安装、落地机部署、卸载和彻底清理。 |
| `upgrade.sh` | 裸金属 / Docker 统一、可恢复的版本升级器。 |
| `ansgo-admin` | SSH 或容器内离线管理、备份、清理、恢复与升级入口。 |
| `ansgo-genconf` | 只读取源配置，生成并校验 caddy / sing-box 运行配置。 |
| `ansgo-limits` | 资源、日志、备份保留和历史迁移共享实现。 |
| `ansgo-cert-issue.sh`、`ansgo-cert-reload` | ACME 签发 / 续期和证书重载。 |
| `docker-compose.yml`、`docker/entrypoint.sh` | Docker 一体化部署。 |
| `systemd/` | caddy、sing-box、自动升级 timer unit。 |
| `panel/` | Go 面板及嵌入式前端源码。 |

## 推荐部署

```bash
# 裸金属：低配 / LXC 推荐
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --non-interactive

# Docker：KVM 推荐
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh \
  | bash -s -- --domain your-domain.com --dynu-key <DYNU_API_KEY> \
      --email <EMAIL> --docker --non-interactive
```

交互安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/install.sh)
```

<details>
<summary>升级、离线管理与备份命令</summary>

```bash
# 自动识别部署形态；Docker 在宿主机执行
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh | bash -s -- --yes

# 裸金属
ansgo-admin status
ansgo-admin info
ansgo-admin panel-pass
ansgo-admin backup
ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz

# Docker：所有命令均在宿主机执行
docker exec ansgo ansgo-admin status
docker exec ansgo ansgo-admin info
docker exec -it ansgo ansgo-admin panel-pass
docker exec ansgo ansgo-admin backup
docker exec -it ansgo ansgo-admin restore /etc/ansgo-backup/<CATEGORY>-<TIMESTAMP>.tar.gz
cd /etc/ansgo-docker && docker compose logs --tail=200 ansgo
```

容器内 `ansgo-admin backup` 的归档位于 `/etc/ansgo-backup/`。自 **v1.6.2** 起，该目录挂载为命名卷 `ansgo_backup`，升级脚本会为存量 Docker 部署自动补上挂载，容器重建后仍保留；**v1.6.1 及更早版本**该目录不在持久卷中，升级重建会丢失。宿主 `/etc/ansgo-backup/docker-*.tar.gz` 是 Docker 升级器的自动回滚归档，与容器内日常备份不同。完整命令表、故障排查和卸载说明见根目录 README。

</details>

<details>
<summary>参数、资源与安全边界</summary>

- `--cert-mode manual --cert-fullchain <FULLCHAIN_PATH> --cert-privkey <PRIVKEY_PATH>` 使用已有证书；`--no-caddy` 让 nginx / 宝塔继续管理 `:80/:443`；`--landing --port <PORT>` 安装独立 Shadowsocks 落地机。
- 未指定的代理端口和面板端口随机生成于 `10000-65535`，而非固定端口；完整参数以 `bash install.sh --help` 为准。
- 项目日志在 `/var/log/ansgo/`，备份在 `/etc/ansgo-backup/`；用 `ansgo-admin prune --yes` 按保留策略清理，不要无差别执行 Docker 全局 prune。
- Docker compose 目录固定为 `/etc/ansgo-docker`、容器名为 `ansgo`；compose 操作使用 `cd /etc/ansgo-docker && docker compose ...`。
- 不要在文档、shell 历史或配置仓库保存真实凭证、IP、域名或节点 URI。

</details>
