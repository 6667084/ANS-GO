package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var binUpgrade = "/usr/local/bin/ansgo-upgrade"

var upgradeMu sync.Mutex
var releaseURL = "https://api.github.com/repos/6667084/ANS-GO/releases/latest"
var stableVersion = regexp.MustCompile(`^v?([0-9]+)\.([0-9]+)\.([0-9]+)$`)

func backupKeep(c Config) int {
	if c.BackupKeep < 1 {
		return 5
	}
	return c.BackupKeep
}

func pathUsage(root string) (bytes int64, count int) {
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if path != root && filepath.Dir(path) == root {
			count++
		}
		if !d.IsDir() && d.Type()&os.ModeSymlink == 0 {
			if info, err := d.Info(); err == nil {
				bytes += info.Size()
			}
		}
		return nil
	})
	return
}

func executable(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Mode()&0111 != 0
}

func tailFile(path string, max int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return ""
	}
	if st.Size() > max {
		_, _ = f.Seek(-max, io.SeekEnd)
	}
	data, _ := io.ReadAll(io.LimitReader(f, max))
	return string(data)
}

func systemInfoHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		jerr(w, 405, "方法不允许")
		return
	}
	c := configGet()
	mode := "metal"
	if isDockerMode() {
		mode = "docker"
	}
	backups, count := pathUsage("/etc/ansgo-backup")
	logs, _ := pathUsage("/var/log/ansgo")
	probe, _ := pathUsage("/etc/ansgo/probe-tmp")
	journal, _ := pathUsage("/var/log/journal")
	journalTmp, _ := pathUsage("/run/log/journal")
	journal += journalTmp
	var st syscall.Statfs_t
	disk := map[string]uint64{"total": 0, "used": 0, "avail": 0}
	if syscall.Statfs("/", &st) == nil {
		size := uint64(st.Bsize)
		disk["total"] = st.Blocks * size
		disk["used"] = (st.Blocks - st.Bfree) * size
		disk["avail"] = st.Bavail * size
	}
	limits := map[string]string{}
	for key, unit := range map[string]string{"panel_mem_max": "ansgo-panel", "singbox_mem_max": "sing-box", "caddy_mem_max": "caddy"} {
		out, err := command("systemctl", "show", "-p", "MemoryMax", "--value", unit).Output()
		limits[key] = ""
		if err == nil {
			limits[key] = strings.TrimSpace(string(out))
		}
	}
	_, timerErr := os.Stat("/etc/systemd/system/ansgo-autoupgrade.timer")
	jwrite(w, 200, map[string]any{
		"version": version, "deploy_mode": mode, "arch": runtime.GOARCH,
		"auto_upgrade": c.AutoUpgrade == "true", "auto_upgrade_supported": mode == "metal" && timerErr == nil && executable(binUpgrade),
		"upgrade_supported": mode == "metal" && executable(binUpgrade),
		"mem_total_kb":      memInfo()["total"], "disk": disk,
		"usage":  map[string]any{"backups_bytes": backups, "backups_count": count, "journal_bytes": journal, "logs_bytes": logs, "probe_tmp_bytes": probe},
		"limits": limits,
	})
}

func newerVersion(latest, current string) bool {
	a, b := stableVersion.FindStringSubmatch(latest), stableVersion.FindStringSubmatch(current)
	if a == nil || b == nil {
		return false
	}
	for i := 1; i <= 3; i++ {
		x, err1 := strconv.ParseUint(a[i], 10, 64)
		y, err2 := strconv.ParseUint(b[i], 10, 64)
		if err1 != nil || err2 != nil {
			return false
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func systemCheckUpdateHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jerr(w, 405, "方法不允许")
		return
	}
	client := newDirectHTTPClient(10*time.Second, false)
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(r.Context(), "GET", releaseURL, nil)
	if err != nil {
		jerr(w, 500, err.Error())
		return
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "ANS-GO/"+version)
	resp, err := client.Do(req)
	if err != nil {
		jerr(w, 502, "检查更新失败: "+err.Error())
		return
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxCommandOutput+1))
	if err != nil || len(data) > maxCommandOutput || resp.StatusCode != 200 {
		jerr(w, 502, "GitHub 响应异常或超过 256KB")
		return
	}
	var release struct {
		Tag string `json:"tag_name"`
		URL string `json:"html_url"`
	}
	if json.Unmarshal(data, &release) != nil || !stableVersion.MatchString(release.Tag) {
		jerr(w, 502, "GitHub 版本信息无效")
		return
	}
	jwrite(w, 200, map[string]any{"ok": true, "current": version, "latest": release.Tag, "has_update": newerVersion(release.Tag, version), "url": release.URL})
}

var upgradeLockPath = "/var/lib/ansgo/upgrade.lock"
var upgradeResultPath = "/var/lib/ansgo/upgrade.result"

type upgradeResult struct {
	Result     string `json:"result"`
	TaskID     string `json:"task_id"`
	StartedAt  int64  `json:"started_at"`
	FinishedAt int64  `json:"finished_at"`
}

// CLI、timer 和面板共用 flock；服务刚进入 activating、尚未获取锁时也视为运行中。
func upgradeState() (unit string, running bool, result string, err error) {
	if f, openErr := os.Open(upgradeLockPath); openErr == nil {
		lockErr := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if lockErr == nil {
			_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		}
		f.Close()
		if lockErr != nil {
			if lockErr == syscall.EWOULDBLOCK || lockErr == syscall.EAGAIN {
				running = true
			} else {
				return "", false, "", lockErr
			}
		}
	} else if !os.IsNotExist(openErr) {
		return "", false, "", openErr
	}
	out, err := command("systemctl", "list-units", "--all", "--plain", "--no-legend", "ansgo-upgrade-*.service", "ansgo-autoupgrade.service").Output()
	if err != nil {
		return "", running, "", err
	}
	var record upgradeResult
	data, _ := os.ReadFile(upgradeResultPath)
	valid := json.Unmarshal(data, &record) == nil && record.TaskID != "" && record.StartedAt > 0 &&
		record.FinishedAt >= record.StartedAt && record.FinishedAt <= time.Now().Unix()+60 &&
		(record.Result == "success" || record.Result == "failed")
	var latestStart int64
	matched := false
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		name := fields[0]
		if name != "ansgo-autoupgrade.service" && !(strings.HasPrefix(name, "ansgo-upgrade-") && strings.HasSuffix(name, ".service")) {
			continue
		}
		propsOut, showErr := command("systemctl", "show", name, "-p", "ActiveState", "-p", "InvocationID", "-p", "ExecMainStartTimestamp").Output()
		if showErr != nil {
			return unit, running, "", showErr
		}
		props := map[string]string{}
		for _, prop := range strings.Split(string(propsOut), "\n") {
			k, v, ok := strings.Cut(prop, "=")
			if ok {
				props[k] = v
			}
		}
		if props["ActiveState"] == "active" || props["ActiveState"] == "activating" {
			running = true
		}
		if name != "ansgo-autoupgrade.service" && name > unit {
			unit = name
		}
		started, _ := time.Parse("Mon 2006-01-02 15:04:05 MST", props["ExecMainStartTimestamp"])
		if !started.IsZero() {
			latestStart = max(latestStart, started.Unix())
		}
		if ns, parseErr := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(name, "ansgo-upgrade-"), ".service"), 10, 64); parseErr == nil {
			latestStart = max(latestStart, ns/int64(time.Second))
		}
		if record.TaskID == strings.TrimSuffix(name, ".service") || record.TaskID == props["InvocationID"] {
			matched = true
		}
	}
	// 旧任务结果不能冒充新任务；CLI 任务无 transient unit 时由启动时间确定新旧。
	if unit != "" && record.StartedAt <= latestStart && strings.HasPrefix(record.TaskID, "ansgo-upgrade-") && record.TaskID != strings.TrimSuffix(unit, ".service") {
		valid = false
	}
	if !running && valid && record.StartedAt >= latestStart && (matched || record.StartedAt > latestStart || (unit == "" && latestStart == 0)) {
		result = record.Result
	}
	return
}

func systemUpgradeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jerr(w, 405, "方法不允许")
		return
	}
	if isDockerMode() {
		jwrite(w, 400, map[string]any{"ok": false, "error": "Docker 部署需在宿主机升级", "hint": "请在宿主机执行 ansgo-upgrade --docker --yes（若未安装，请下载 deploy/upgrade.sh 后执行 bash upgrade.sh --docker --yes）"})
		return
	}
	var b struct {
		Version string `json:"version"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil && err != io.EOF {
		jerr(w, 400, "请求格式错误")
		return
	}
	if b.Version != "" && (!stableVersion.MatchString(b.Version) || !strings.HasPrefix(b.Version, "v")) {
		jerr(w, 400, "版本需为 vX.Y.Z")
		return
	}
	if !executable(binUpgrade) {
		jerr(w, 500, "缺少可执行命令 "+binUpgrade+"，请先更新部署脚本")
		return
	}
	upgradeMu.Lock()
	defer upgradeMu.Unlock()
	unit, running, _, err := upgradeState()
	if err != nil {
		jerr(w, 500, "无法查询升级状态: "+err.Error())
		return
	}
	if running {
		jerr(w, 409, "已有升级正在运行")
		return
	}
	if unit != "" {
		_ = command("systemctl", "stop", unit).Run()
		_ = command("systemctl", "reset-failed", unit).Run()
	}
	taskID := fmt.Sprintf("ansgo-upgrade-%d", time.Now().UnixNano())
	args := []string{"--unit=" + taskID, "--setenv=ANSGO_UPGRADE_TASK_ID=" + taskID, "--no-block", "--property=Type=oneshot", binUpgrade, "--yes"}
	if b.Version != "" {
		args = append(args, "--ver", b.Version)
	}
	out, err := command("systemd-run", args...).CombinedOutput()
	if err != nil {
		jerr(w, 500, commandError("systemd-run", out, err).Error())
		return
	}
	jwrite(w, 200, map[string]any{"ok": true, "started": true})
}

func systemUpgradeStatusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		jerr(w, 405, "方法不允许")
		return
	}
	if isDockerMode() {
		jwrite(w, 200, map[string]any{"running": false, "result": "", "log": tailFile("/var/log/ansgo/upgrade.log", 64*1024)})
		return
	}
	_, running, result, err := upgradeState()
	if err != nil {
		jerr(w, 500, "无法查询升级状态: "+err.Error())
		return
	}
	jwrite(w, 200, map[string]any{"running": running, "result": result, "log": tailFile("/var/log/ansgo/upgrade.log", 64*1024)})
}

func systemAutoUpgradeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jerr(w, 405, "方法不允许")
		return
	}
	if isDockerMode() {
		jwrite(w, 400, map[string]any{"ok": false, "error": "Docker 不支持容器内自动升级"})
		return
	}
	var b struct {
		Enabled *bool `json:"enabled"`
	}
	if json.NewDecoder(r.Body).Decode(&b) != nil || b.Enabled == nil {
		jerr(w, 400, "需提交 enabled")
		return
	}
	configChangeMu.Lock()
	defer configChangeMu.Unlock()
	if _, err := os.Stat("/etc/systemd/system/ansgo-autoupgrade.timer"); err != nil {
		jerr(w, 500, "缺少 ansgo-autoupgrade.timer，请先更新部署脚本")
		return
	}
	c := configGet()
	old := c
	c.AutoUpgrade = boolStr(*b.Enabled)
	action := "disable"
	if *b.Enabled {
		action = "enable"
	}
	if err := configSet(c); err != nil {
		jerr(w, 500, err.Error())
		return
	}
	out, err := command("systemctl", action, "--now", "ansgo-autoupgrade.timer").CombinedOutput()
	if err != nil {
		restoreAction := "disable"
		if old.AutoUpgrade == "true" {
			restoreAction = "enable"
		}
		restoreOut, timerErr := command("systemctl", restoreAction, "--now", "ansgo-autoupgrade.timer").CombinedOutput()
		restoreErr := configSet(old)
		if timerErr != nil {
			restoreErr = fmt.Errorf("%v；恢复 timer: %v", restoreErr, commandError("systemctl", restoreOut, timerErr))
		}
		jerr(w, 500, fmt.Sprintf("%v；配置恢复: %v", commandError("自动升级设置", out, err), restoreErr))
		return
	}
	jwrite(w, 200, map[string]any{"ok": true, "enabled": *b.Enabled})
}

func systemCleanupHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		jerr(w, 405, "方法不允许")
		return
	}
	configChangeMu.Lock()
	defer configChangeMu.Unlock()
	if !executable(binAdmin) {
		jerr(w, 500, "缺少可执行命令 "+binAdmin)
		return
	}
	out, err := command(binAdmin, "prune", "--yes").CombinedOutput()
	if err == nil {
		err = cleanupSessions(db)
	}
	if err != nil {
		jerr(w, 500, commandError("清理", out, err).Error())
		return
	}
	var freed int64
	found := false
	for _, line := range strings.Split(string(out), "\n") {
		if value, ok := strings.CutPrefix(line, "FREED_BYTES="); ok {
			n, parseErr := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
			if parseErr == nil && n >= 0 {
				freed, found = n, true
			}
		}
	}
	if !found {
		jerr(w, 500, "清理命令未返回有效 FREED_BYTES")
		return
	}
	jwrite(w, 200, map[string]any{"ok": true, "freed_bytes": freed, "log": string(out)})
}

func reloadProxyServices() error {
	out, err := command(binGenConf, "all").CombinedOutput()
	if err != nil {
		return commandError("生成服务配置", out, err)
	}
	c := configGet()
	if c.SvcSSEnabled == "true" || c.SvcAnyTLSEnabled == "true" || c.SvcSocksEnabled == "true" || len(enabledLandings(c)) > 0 {
		if _, err := restartVerify("sing-box"); err != nil {
			return err
		}
	}
	if c.CaddyEnable != "false" || c.SvcNaiveEnabled == "true" {
		if _, err := restartVerify("caddy"); err != nil {
			return err
		}
	}
	return nil
}
