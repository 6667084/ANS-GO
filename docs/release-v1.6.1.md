# ANS-GO v1.6.1 Release Notes

v1.6.1 是 v1.6.0 的稳定性补丁，重点修复 **Docker 形态一键升级** 与 **低磁盘主机** 的问题。所有 v1.6.0 功能保持不变；建议所有用户升级。

## 修复

1. **Docker 升级不再泄露凭据到 compose 文件**：v1.6.0 的 Docker 升级用 `docker compose config` 的输出重写 `docker-compose.yml`，会把 `env_file`（`ansgo.env`）中的面板密码、Dynu 凭证展开成明文 `environment:`，并丢失注释。v1.6.1 改为对原始 compose 文本做最小化编辑：只替换 `image:` 并补齐缺失的资源约束，保留注释、`env_file`、用户自定义挂载（如 `/etc/gai.conf`）、手动调优的 `mem_limit` 和文件原权限；升级备份中也只保存原始 compose。
2. **低磁盘主机升级前空间预检**：拉取新镜像前检查 Docker 数据分区可用空间；不足时只清理本项目仓库（`ghcr.io/6667084/ansgo`、旧 `ghcr.io/jiasongji/ansgo`）中既非运行中、也非目标版本的旧镜像，仍不足则中止且不做任何修改。升级成功后保留上一个镜像用于回滚，并删除更早的本项目镜像；剩余空间低于 500MB 时连上一个镜像也删除并给出提示。绝不执行全局 `prune`，不碰其他镜像与卷。
3. **修复升级随机失败**：备份清单校验 `tar | grep -q` 在 `pipefail` 下因 SIGPIPE 偶发返回 141（实测约 20% 概率中止升级）；全仓同类管道写法一并修正。
4. **Compose v1 预检**：只有 `docker-compose` 1.x（如 Debian 自带 1.29）时，模板中的 `cgroup` 等字段不受支持；安装与升级现在在修改宿主前预检，并明确提示安装 Docker Compose v2。
5. **彻底卸载更干净**：`--uninstall --purge` 清理本项目两个仓库下的全部版本镜像，以及受管的 sysctl / limits / journald 调优文件（只删除带本项目标记或与历史模板一致的文件，保留用户自建文件）。
6. **兼容旧版安装器**：旧版安装脚本会从 main 分支拉取管理脚本；v1.6.x 管理脚本依赖共享库 `ansgo-limits`，缺失时现在会自动补装，避免落地服务凭证生成等操作失败。

## 升级

```bash
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh | bash -s -- --yes
```

- 裸金属 v1.6.0 也可在面板「系统维护」页一键升级。
- Docker 部署请在宿主机执行上面的命令（面板会给出提示）。
- 升级后浏览器请硬刷新（Ctrl+Shift+R / Cmd+Shift+R）。

## 验证

- Debian 13 KVM（464MB）裸金属：公开命令 v1.5.37 → v1.6.x 一键升级、全新安装、彻底卸载零残留。
- Debian 12 虚拟机 Docker：公开命令 v1.5.37 安装 → 一键升级，配置迁移、备份完整性（含 SQLite 完整性）与 purge 清理。
- 生产 Docker 实例（464MB 内存、低磁盘）升级验证。
