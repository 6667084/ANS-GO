# ANS-GO v1.6.0 Release Notes

> **状态：即将发布。** 推送 `v1.6.0` tag 后，CI 自动生成 6 项 release 资产与容器镜像。本文不含真实 IP、域名、凭证、厂商或机房信息。

## 变更清单

### 落地服务调配重构

- 每个落地分别持久化 `remote_ss` 与 `remote_socks`，`remote_type` 只选择当前生效协议；SS 与 SOCKS5 来回切换不会丢失另一套配置。
- `remote_enabled` 尊重显式关闭。旧数据迁移到 `landings_schema:2` 时保留一次性历史自动启用语义，之后不再根据字段齐全强制开启。
- 新增 `landing_next_id`，ID 递增分配、删除不回收；最多支持 32 个落地。
- 落地新增、更新、删除和重置凭证均在全局配置互斥下事务化：任一步失败即恢复 `panel.json`、`secrets.env` 和生成配置。
- `ansgo-genconf` 改为纯生成器：只读取源配置，临时文件校验通过后原子替换，生成文件权限为 0600，不再回写 `panel.json`。

### 全新控制台

- 控制台使用新的设计 token 和 SVG 图标，支持暗/亮主题、移动端抽屉导航。
- 全部栏目可以折叠并记忆状态，支持全部展开与全部收起。
- 落地卡片同时保留两套远端表单；局部刷新不会抹掉其他卡片草稿，离开未保存卡片时给出提示。
- 统一请求错误处理、401 回登录与请求防竞态；动态内容统一使用 `textContent`，避免配置值注入页面。
- 新增「系统维护」页：查看资源/磁盘用量与限制，检查更新、启动升级、查看结果、管理自动升级和执行清理。

### 资源、日志与文件边界

- 裸金属和容器内三服务均使用 `10-ansgo-limits.conf`：按可用内存计算 `MemoryHigh`、`MemoryMax`、`TasksMax`、`CPUWeight`、`OOMScoreAdjust` 与 `GOMEMLIMIT`。文件带内容指纹；用户自行修改后升级不会覆盖。
- 内存预算由 `ansgo-limits` 动态计算：代理服务最低硬上限分别为 96M 与 64M，面板最低为 48M；随宿主内存增长后按比例分配，面板最高为 128M。此规则覆盖 256M、464M、1G 和 2G 档位，实际值以目标机的可用内存/cgroup 上限为准。

| 可用内存 | sing-box MemoryMax | caddy MemoryMax | ansgo-panel MemoryMax |
|---|---:|---:|---:|
| 256M | 96M | 64M | 48M |
| 464M | 162M | 116M | 69M |
| 1G | 358M | 256M | 128M |
| 2G | 716M | 512M | 128M |

- 面板增加请求体限制、命令超时与输出限长、登录并发限制、会话/锁定定期清理和 SQLite 0600 权限。默认不信任 `X-Forwarded-For`，只有配置可信反代时才解析。
- 项目日志统一写入 `/var/log/ansgo/`；写入前发现单文件超过 1MB 时截断为末尾 256KB。
- journald 使用项目专属 `60-ansgo.conf`，系统调优使用 `99-ansgo-tune.conf`，均避免覆盖用户已有配置。
- 备份统一写入 `/etc/ansgo-backup/`；按 `backup_keep`（默认 5）清理，升级备份最多保留 2 份，总量上限 200MB。`ansgo-admin prune [--yes]` 清理旧备份、过期临时文件与超额 journal。临时文件使用 `mktemp` 和 `trap` 管理。

### 升级与自动升级

- `upgrade.sh` 先从目标 tag 暂存脚本和所有组件，校验 SHA256 清单后才备份、切换和验证；失败自动回滚。
- `--ver vX.Y.Z` 对裸金属脚本、release 资产和容器镜像使用同一个版本；Docker 路径实际切换指定镜像 tag，并备份真实配置卷。
- 安装与升级会刷新 `/usr/local/bin/ansgo-upgrade`。可临时设置 `ANSGO_RAW_BASE`、`ANSGO_REL_BASE`、`ANSGO_RELEASE_API` 覆盖下载源，用于镜像加速或发布前验证。
- 新增默认关闭的 `ansgo-autoupgrade.timer`：每周低优先级检查稳定版，带随机延迟；无更新直接退出。可在「系统维护」页管理，或通过 systemd 手工启停。
- 裸金属可在「系统维护」页触发一键升级，任务脱离面板 cgroup 运行，进度写入项目日志并持久化结果。容器模式会提示在宿主执行升级。

### 安装与证书

- 安装前预检远端资产，收集全部输入后统一校验，确认后才应用系统调优；部署摘要不再打印 Dynu API Key。
- 首次签发未获得证书时安装失败，不再错误报告完成。
- manual 模式可直接「签发并切换到 ACME」；只有签发成功才切换证书来源。签发/续期不在中途重启面板，并返回本次日志。
- `secrets.env` 统一按原始 `KEY=value` 解析，包含空格、美元符号、引号或反斜杠的密码可安全保留。容器证书同步对证书与私钥成对回滚。

### ansgo-admin

- 新增 `ansgo-admin prune [--yes]` 和 `ansgo-admin upgrade [升级参数]`。
- `ansgo-admin update` 修复为兼容的单组件更新入口；跨版本升级应使用 `ansgo-admin upgrade` 或 `upgrade.sh`。

## 升级说明

1. 运行 `upgrade.sh --yes --ver v1.6.0`，或在裸金属控制台的「系统维护」页执行一键升级。
2. 升级会自动迁移旧单落地和旧扁平远端字段，并保留 SS/SOCKS5 两套配置；特殊字符密码按原样保留。
3. 升级完成后硬刷新浏览器，以加载嵌入新面板二进制的前端资源。
4. 如需恢复配置，使用升级生成的 `/etc/ansgo-backup/upgrade-*.tar.gz` 配合 `ansgo-admin restore`；升级器在校验、切换或验证失败时也会自动回滚。

## 兼容性

- 落地 API 增加 `remote_ss` 与 `remote_socks` 对象字段；GET 仍返回取自当前生效协议的 `remote_host`、`remote_port`、`remote_method`、`remote_user`、`remote_password` 兼容镜像字段。
- POST/更新仍接受旧扁平远端字段，并按请求的 `remote_type` 写入对应对象。
- 旧单落地字段和旧 `landings[]` 扁平字段可读取并自动迁移；迁移后不再自动改变用户明确设置的 `remote_enabled`。
- v1.6.0 修改面板前端结构。升级完成后必须硬刷新浏览器，否则缓存可能继续显示旧界面。

## 验证结论

- 最低配 KVM 测试环境完成全新裸金属安装、从 v1.5.37 升级到 v1.6.0 的落地模型迁移、双协议往返保留、统一升级回滚路径、自动升级 timer、清理、登录锁定和超大请求拒绝验证。
- 特殊字符密码在迁移与双协议切换中原样保留；伪造 `X-Forwarded-For` 不能绕过登录锁定。
- 常驻内存实测约为：面板 12MB、caddy 43MB、sing-box 40MB。
- Docker 形态已完成本机容器冒烟测试覆盖。
