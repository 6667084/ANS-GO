# ANS-GO v1.6.2 Release Notes

v1.6.2 聚焦 **Docker 部署的可运维性**：面板提示给出在 Docker 下真正可执行的命令，日常备份在容器重建后保留，说明文档按部署形态分开。

## 修复与改进

1. **SSH 兜底命令按部署形态显示**
   - 登录页「忘记密码？」改为可展开区域，同时列出两种写法（各带复制按钮）：
     - 裸金属：`ansgo-admin panel-pass`
     - Docker：在宿主机执行 `docker exec -it ansgo ansgo-admin panel-pass`（改过容器名请替换 `ansgo`）
   - 登录前不暴露部署形态（未鉴权的 `api/auth` 仍只返回 `authed`、`version`）。
   - 登录后的所有提示（停止面板后的恢复命令、修复失败兜底、日志查看等）、后端错误提示、`ansgo-admin` 自身帮助、Docker 首次启动日志与安装完成横幅，均按实际形态给出命令。
2. **Docker 日常备份持久化**：容器内 `ansgo-admin backup` 与配置变更前的自动备份写在 `/etc/ansgo-backup/`，此前该目录不在持久卷中，每次升级（重建容器）都会丢失。v1.6.2 在 compose 中新增命名卷 `ansgo_backup:/etc/ansgo-backup`；`upgrade.sh` 会为存量部署以原文最小化编辑的方式自动补上挂载（保留注释、`env_file`、自定义挂载与权限）。`--uninstall --purge` 会一并删除该卷，默认卸载保留。
3. **文档**：README 重构为「一键安装（裸金属 / Docker 分开）→ 一键升级 → 常用命令（裸金属 / Docker 两张折叠表）」，其余内容默认折叠；卸载命令统一为在线 `curl ... | bash -s -- --uninstall` 形式。
4. Docker 升级在删除浮动 tag（如 `:latest`）旧镜像后，回滚提示改为明确的版本号。

## 升级

```bash
curl -fsSL https://raw.githubusercontent.com/6667084/ANS-GO/main/deploy/upgrade.sh | bash -s -- --yes
```

- 裸金属 v1.6.0+ 也可在面板「系统维护」页一键升级；Docker 请在宿主机执行上面的命令。
- 升级后浏览器请硬刷新（Ctrl+Shift+R / Cmd+Shift+R）。

## 验证

- 本机 Docker 容器实测：`docker exec -it <容器> ansgo-admin panel-pass` 重置后新密码可登录、旧密码被拒；`ansgo-admin restart panel` 正常；备份卷在 `--force-recreate` 后文件与 SHA256 保持一致。
- 全部单元与脚本测试通过（Go 129 项、UI 28 项及 9 个脚本测试）。
