package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func landingFixture(t *testing.T) string {
	t.Helper()
	oldCfg, oldConf, oldSec := configGet(), confPath, secretsPath
	oldApply, oldGenerated := landingApply, landingGeneratedPaths
	dir := t.TempDir()
	confPath, secretsPath = filepath.Join(dir, "panel.json"), filepath.Join(dir, "secrets.env")
	generated := filepath.Join(dir, "config.json")
	landingGeneratedPaths = []string{generated}
	landingApply = func(string) (string, error) { return "active", nil }
	cfgMu.Lock()
	cfg = Config{Domain: "your-domain.com", URLPath: "/admin/", PanelPort: 15608, CaddyEnable: "false", LandingsSchema: 2, LandingNextID: 2,
		Landings: []LandingService{{ID: "1", Name: "first", Enabled: true, Port: 23001, RemoteType: "ss",
			RemoteSS: RemoteSS{Host: "your-domain.com", Port: 8388, Method: "2022-blake3-aes-128-gcm", Password: "AAAAAAAAAAAAAAAAAAAAAA=="}}}}
	cfgMu.Unlock()
	if err := saveConfig(configGet()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secretsPath, []byte("LANDING_1_PASS=example-pass\nLANDING_1_UUID=example-uuid\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(generated, []byte("original-runtime"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cfgMu.Lock()
		cfg = oldCfg
		cfgMu.Unlock()
		confPath, secretsPath = oldConf, oldSec
		landingApply, landingGeneratedPaths = oldApply, oldGenerated
	})
	return generated
}

func landingRequest(handler http.HandlerFunc, body string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	handler(w, httptest.NewRequest("POST", "/", strings.NewReader(body)))
	return w
}

func TestLandingRoundTripKeepsBothObjects(t *testing.T) {
	landingFixture(t)
	for _, body := range []string{
		`{"id":"1","remote_enabled":true,"remote_type":"socks","remote_socks":{"host":"your-domain.com","port":1080,"user":"example-user","password":"example-pass"}}`,
		`{"id":"1","remote_type":"ss","remote_ss":{"port":8389}}`,
		`{"id":"1","remote_enabled":false}`,
	} {
		if w := landingRequest(landingUpdateHandler, body); w.Code != 200 {
			t.Fatalf("%d: %s", w.Code, w.Body.String())
		}
	}
	c, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	l := c.Landings[0]
	if l.RemoteSS.Port != 8389 || l.RemoteSS.Password == "" || l.RemoteSocks.User != "example-user" || l.RemoteSocks.Password != "example-pass" {
		t.Fatalf("草稿丢失: %+v", l)
	}
	if l.RemoteEnabled {
		t.Fatal("显式 false 被覆盖")
	}
	migrateLandings(&c)
	if c.Landings[0].RemoteEnabled {
		t.Fatal("schema2 重启迁移覆盖 false")
	}
	data, _ := os.ReadFile(confPath)
	if bytes.Contains(data, []byte(`"remote_host"`)) {
		t.Fatal("旧字段不应继续落盘")
	}
	out := landingToMap(l)
	if out["remote_host"] != l.RemoteSS.Host || out["remote_port"] != 8389 || out["remote_ss"] == nil || out["remote_socks"] == nil {
		t.Fatalf("API 缺少对象或镜像: %+v", out)
	}
}

func TestLegacyLandingMigrationOnce(t *testing.T) {
	var c Config
	if err := json.Unmarshal([]byte(`{"landings":[{"id":"7","name":"old","remote_type":"socks","remote_host":"your-domain.com","remote_port":1080,"remote_user":"user","remote_password":"pass"}]}`), &c); err != nil {
		t.Fatal(err)
	}
	if !migrateLandings(&c) || c.LandingsSchema != 2 || c.LandingNextID != 8 || !c.Landings[0].RemoteEnabled {
		t.Fatalf("旧配置未迁移: %+v", c)
	}
	if c.Landings[0].RemoteSocks.User != "user" {
		t.Fatal("旧扁平字段未导入")
	}
	c.Landings[0].RemoteEnabled = false
	if migrateLandings(&c) || c.Landings[0].RemoteEnabled {
		t.Fatal("迁移不幂等")
	}
	var preferred LandingService
	if err := json.Unmarshal([]byte(`{"remote_type":"ss","remote_host":"old","remote_ss":{"host":"your-domain.com"}}`), &preferred); err != nil {
		t.Fatal(err)
	}
	if preferred.RemoteSS.Host != "your-domain.com" {
		t.Fatal("新对象没有优先于旧镜像")
	}
}

func TestLandingValidationFailureDoesNotMutate(t *testing.T) {
	landingFixture(t)
	original := configGet()
	panel, _ := os.ReadFile(confPath)
	secrets, _ := os.ReadFile(secretsPath)
	for _, body := range []string{
		`{"id":"1","name":"changed","port":0}`,
		`{"id":"1","name":"changed","password":""}`,
		`{"id":"1","name":"changed","port":15608}`,
		`{"id":"1","remote_enabled":true,"remote_type":"socks","remote_socks":{"host":"your-domain.com","port":1080,"user":"bad:user","password":"pass"}}`,
		`{"id":"1","remote_type":"unknown"}`,
	} {
		w := landingRequest(landingUpdateHandler, body)
		if w.Code != 400 {
			t.Fatalf("应拒绝: %d %s", w.Code, w.Body.String())
		}
		if !reflect.DeepEqual(original, configGet()) {
			t.Fatal("失败污染内存")
		}
		data, _ := os.ReadFile(confPath)
		sec, _ := os.ReadFile(secretsPath)
		if !bytes.Equal(panel, data) || !bytes.Equal(secrets, sec) {
			t.Fatal("失败污染磁盘")
		}
	}
	copy := configGet()
	copy.Landings[0].Name = "copy"
	if configGet().Landings[0].Name == "copy" {
		t.Fatal("configGet 未深拷贝")
	}
}

func TestLandingTransactionsRestoreAllFiles(t *testing.T) {
	for _, action := range []string{"create", "update", "delete", "regen"} {
		t.Run(action, func(t *testing.T) {
			generated := landingFixture(t)
			original := configGet()
			var files []fileSnapshot
			for _, path := range []string{confPath, secretsPath, generated} {
				s, err := snapshot(path)
				if err != nil {
					t.Fatal(err)
				}
				files = append(files, s)
			}
			calls := 0
			landingApply = func(string) (string, error) {
				calls++
				if err := atomicWrite(generated, []byte("partially-applied")); err != nil {
					t.Fatal(err)
				}
				if calls == 1 {
					return "failed", errors.New("模拟生成/重启失败")
				}
				return "active", nil
			}
			body := `{"id":"1","name":"changed","port":23002,"password":"new-pass"}`
			w := httptest.NewRecorder()
			landingMutation(w, httptest.NewRequest("POST", "/", strings.NewReader(body)), action)
			if w.Code != 500 || calls != 2 {
				t.Fatalf("未执行恢复: code=%d calls=%d %s", w.Code, calls, w.Body.String())
			}
			if !reflect.DeepEqual(original, configGet()) {
				t.Fatal("内存未恢复")
			}
			for _, f := range files {
				data, err := os.ReadFile(f.path)
				if err != nil || !bytes.Equal(data, f.data) {
					t.Fatalf("文件未恢复: %s (%v)", f.path, err)
				}
			}
		})
	}
}

func TestLandingIDsNeverReusedAndConcurrentMerge(t *testing.T) {
	landingFixture(t)
	if w := landingRequest(landingsHandler, `{"name":"second","port":23002}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := landingRequest(landingDeleteHandler, `{"id":"2"}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := landingRequest(landingsHandler, `{"name":"third","port":23003}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if c := configGet(); c.Landings[1].ID != "3" || c.LandingNextID != 4 {
		t.Fatalf("ID 被回收: %+v", c)
	}
	var wg sync.WaitGroup
	for _, body := range []string{`{"id":"1","name":"new-name"}`, `{"id":"1","remote_ss":{"port":9999}}`} {
		wg.Add(1)
		go func(body string) {
			defer wg.Done()
			if w := landingRequest(landingUpdateHandler, body); w.Code != 200 {
				t.Errorf("%s", w.Body.String())
			}
		}(body)
	}
	wg.Wait()
	if c := configGet(); c.Landings[0].Name != "new-name" || c.Landings[0].RemoteSS.Port != 9999 {
		t.Fatal("并发修改互相覆盖")
	}
}

func TestCommandBoundedOutputAndDeadline(t *testing.T) {
	out, err := command("sh", "-c", "yes x | head -c 400000").CombinedOutput()
	if err != nil || len(out) != maxCommandOutput {
		t.Fatalf("输出未限长: %d %v", len(out), err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := commandContext(ctx, "sh", "-c", "sleep 10 & wait").CombinedOutput(); err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("超时未终止进程组: %v", err)
	}
}

func TestClientIPAndLogBounds(t *testing.T) {
	landingFixture(t)
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "localhost:1234"
	req.Header.Set("X-Forwarded-For", "::1")
	if ip := clientIP(req); ip != "localhost" {
		t.Fatalf("默认信任了伪造头: %s", ip)
	}
	c := configGet()
	c.TrustedProxy = "true"
	if err := configSet(c); err != nil {
		t.Fatal(err)
	}
	if ip := clientIP(req); ip != "::1" {
		t.Fatalf("可信代理未解析: %s", ip)
	}
	for _, n := range []string{"all", "1001", "-1", "0", "nope"} {
		w := httptest.NewRecorder()
		logsHandler(w, httptest.NewRequest("GET", "/?n="+n, nil))
		if w.Code != 400 {
			t.Fatalf("非法 n=%s 未拒绝", n)
		}
	}
}

func TestRequestBodyLimitAndAtomicLockout(t *testing.T) {
	srv, cookie := setupPanel(t)
	defer srv.Close()
	defer db.Close()
	before := configGet()
	code, _ := postSettings(t, srv, cookie, map[string]any{"panel_title": strings.Repeat("x", 70*1024)})
	if code != 400 || !reflect.DeepEqual(before, configGet()) {
		t.Fatal("超大请求未拒绝或污染配置")
	}
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := lockRecordFail("example-source", 20, 10); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	fails, _ := lockStatus("example-source")
	if fails != 12 {
		t.Fatalf("计数非原子: %d", fails)
	}
	now := time.Now().Unix()
	_, _ = db.Exec("INSERT INTO sessions VALUES('old','source',?,?)", now-100, now-1)
	_, _ = db.Exec("INSERT INTO lockout(ip,fails,locked_until) VALUES('old',5,?)", now-1)
	if err := cleanupSessions(db); err != nil {
		t.Fatal(err)
	}
	if sessionValid("old") {
		t.Fatal("过期会话未清理")
	}
	if n, _ := lockStatus("old"); n != 0 {
		t.Fatal("过期锁定未清理")
	}
}

func TestCheckUpdateUsesDirectBoundedClient(t *testing.T) {
	old := releaseURL
	t.Cleanup(func() { releaseURL = old })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"v1.10.0","html_url":"https://github.com/6667084/ANS-GO/releases"}`))
	}))
	defer server.Close()
	releaseURL = server.URL
	t.Setenv("HTTP_PROXY", "http://invalid.invalid")
	w := httptest.NewRecorder()
	systemCheckUpdateHandler(w, httptest.NewRequest("POST", "/", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"has_update":true`) {
		t.Fatal(w.Body.String())
	}
	if newerVersion("v1.5.99", "1.6.0") || !newerVersion("v1.10.0", "1.6.0") {
		t.Fatal("版本号比较使用了字符串排序")
	}
}

func TestLandingDiskFailureDoesNotCommit(t *testing.T) {
	generated := landingFixture(t)
	before := configGet()
	originalPath := confPath
	confPath = filepath.Join(t.TempDir(), "missing", "panel.json")
	w := landingRequest(landingUpdateHandler, `{"id":"1","name":"changed"}`)
	confPath = originalPath
	if w.Code != 500 || !reflect.DeepEqual(before, configGet()) {
		t.Fatal("写盘失败仍提交了内存")
	}
	data, _ := os.ReadFile(generated)
	if string(data) != "original-runtime" {
		t.Fatal("写盘失败改变了运行配置")
	}
}

func TestLandingDraftLimitsAndLegacyWrites(t *testing.T) {
	landingFixture(t)
	// 不生效对象允许不完整草稿，旧字段写入选择的协议对象。
	w := landingRequest(landingUpdateHandler, `{"id":"1","remote_type":"socks","remote_host":"your-domain.com","remote_port":1080,"remote_user":"draft","remote_password":"draft-pass","remote_ss":{"method":"draft-method"}}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	l := configGet().Landings[0]
	if l.RemoteSocks.User != "draft" || l.RemoteSS.Password == "" {
		t.Fatal("兼容写入破坏另一协议")
	}
	w = landingRequest(landingUpdateHandler, `{"id":"1","remote_ss":{"password":"`+strings.Repeat("x", 257)+`"}}`)
	if w.Code != 400 {
		t.Fatal("非生效草稿长度没有限制")
	}
	var c Config
	_ = json.Unmarshal([]byte(`{"landings":[{"id":"1","remote_type":"socks","remote_host":"your-domain.com","remote_port":70000,"remote_user":"user","remote_password":"pass"}]}`), &c)
	migrateLandings(&c)
	if c.Landings[0].RemoteEnabled {
		t.Fatal("迁移启用了非法端口")
	}
}

func TestLoginAndHealthConcurrencyCaps(t *testing.T) {
	for i := 0; i < cap(loginSlots); i++ {
		loginSlots <- struct{}{}
	}
	w := httptest.NewRecorder()
	loginHandler(w, httptest.NewRequest("POST", "/", strings.NewReader(`{}`)))
	for i := 0; i < cap(loginSlots); i++ {
		<-loginSlots
	}
	if w.Code != 429 {
		t.Fatal("登录总并发未限流")
	}
	for i := 0; i < cap(healthSlots); i++ {
		healthSlots <- struct{}{}
	}
	w = httptest.NewRecorder()
	healthHandler(w, httptest.NewRequest("POST", "/", strings.NewReader(`{}`)))
	for i := 0; i < cap(healthSlots); i++ {
		<-healthSlots
	}
	if w.Code != 429 {
		t.Fatal("健康检测并发未限流")
	}
}

func TestSystemUpgradeDetachedAndSingle(t *testing.T) {
	if isDockerMode() {
		t.Skip("Docker 分支单独验证")
	}
	dir := t.TempDir()
	units, props, args := filepath.Join(dir, "units"), filepath.Join(dir, "props"), filepath.Join(dir, "args")
	for _, path := range []string{units, props} {
		if err := os.WriteFile(path, nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("TEST_UNITS", units)
	t.Setenv("TEST_PROPS", props)
	t.Setenv("TEST_ARGS", args)
	for name, body := range map[string]string{
		"systemctl": `#!/bin/sh
case "$1" in
list-units) cat "$TEST_UNITS";;
show) cat "$TEST_PROPS";;
is-active) echo inactive; exit 3;;
*) exit 0;;
esac
`,
		"systemd-run": `#!/bin/sh
printf '%s\n' "$@" > "$TEST_ARGS"
unit=${1#--unit=}
printf '%s.service loaded activating start\n' "$unit" > "$TEST_UNITS"
printf 'ActiveState=activating\nSubState=start\nResult=success\nExecMainStatus=0\n' > "$TEST_PROPS"
`,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	oldResult, oldLock := upgradeResultPath, upgradeLockPath
	upgradeResultPath, upgradeLockPath = filepath.Join(dir, "result.json"), filepath.Join(dir, "lock")
	t.Cleanup(func() { upgradeResultPath, upgradeLockPath = oldResult, oldLock })
	old := binUpgrade
	binUpgrade = filepath.Join(dir, "ansgo-upgrade")
	t.Cleanup(func() { binUpgrade = old })
	if err := os.WriteFile(binUpgrade, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			systemUpgradeHandler(w, httptest.NewRequest("POST", "/", strings.NewReader(`{"version":"v1.6.0"}`)))
			codes <- w.Code
		}()
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[200] != 1 || counts[409] != 1 {
		t.Fatalf("升级未互斥: %v", counts)
	}
	argv, _ := os.ReadFile(args)
	for _, flag := range []string{"--no-block", "--property=Type=oneshot", binUpgrade, "--yes", "--ver", "v1.6.0"} {
		if !strings.Contains(string(argv), flag+"\n") {
			t.Fatalf("脱离 cgroup 参数缺失: %s", flag)
		}
	}
	unitData, _ := os.ReadFile(units)
	task := strings.Fields(string(unitData))[0]
	for _, state := range []struct {
		props, result string
		running       bool
	}{
		{"ActiveState=activating\nSubState=start\nResult=success\nExecMainStatus=0\n", "", true},
		{"ActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0\n", "success", false},
		{"ActiveState=active\nSubState=running\n", "", true},
		{"ActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainStatus=1\n", "failed", false},
	} {
		if err := os.WriteFile(props, []byte(state.props), 0600); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(upgradeResult{Result: state.result, TaskID: strings.TrimSuffix(task, ".service"), StartedAt: time.Now().Unix(), FinishedAt: time.Now().Unix()})
		if err := os.WriteFile(upgradeResultPath, data, 0600); err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		systemUpgradeStatusHandler(w, httptest.NewRequest("GET", "/", nil))
		var got map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &got)
		if w.Code != 200 || got["running"] != state.running || got["result"] != state.result {
			t.Fatalf("状态不符: %s", w.Body.String())
		}
	}
}

func TestSystemDockerErrorsAndBackupKeep(t *testing.T) {
	t.Setenv("ANSGO_DOCKER", "1")
	for _, handler := range []http.HandlerFunc{systemUpgradeHandler, systemAutoUpgradeHandler} {
		w := httptest.NewRecorder()
		handler(w, httptest.NewRequest("POST", "/", strings.NewReader(`{"enabled":true}`)))
		if w.Code != 400 || !strings.Contains(w.Body.String(), `"ok":false`) {
			t.Fatal(w.Body.String())
		}
	}
	srv, cookie := setupPanel(t)
	defer srv.Close()
	defer db.Close()
	if code, _ := postSettings(t, srv, cookie, map[string]any{"backup_keep": 30}); code != 200 || configGet().BackupKeep != 30 {
		t.Fatal("保留数量未保存")
	}
	if code, _ := postSettings(t, srv, cookie, map[string]any{"backup_keep": 31}); code != 400 || configGet().BackupKeep != 30 {
		t.Fatal("保留数量越界仍生效")
	}
	// 面板端口经 settings 变更同样要检查现有监听冲突。
	c := configGet()
	c.SvcAnyTLSEnabled = "true"
	if err := configSet(c); err != nil {
		t.Fatal(err)
	}
	if code, _ := postSettings(t, srv, cookie, map[string]any{"panel_port": c.AnyTLSPort}); code != 400 {
		t.Fatal("settings 端口冲突未拒绝")
	}
}
