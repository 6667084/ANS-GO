package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestSecretsLiteralCompatibility(t *testing.T) {
	landingFixture(t)
	for _, value := range []string{"two words", "a$b", "O'Reilly", `abc\def`, " padded ", `"one`, `two"`} {
		for _, wrapped := range []string{value, "'" + value + "'", `"` + value + `"`} {
			// 原始值成对包裹引号时按历史规则去掉；不做 shell 展开。
			data := "ANYTLS_PASS=" + wrapped + "\nLANDING_1_PASS=" + wrapped + "\nLANDING_1_UUID=id\n"
			if err := os.WriteFile(secretsPath, []byte(data), 0600); err != nil {
				t.Fatal(err)
			}
			if got := readSecrets().AnyTLSPass; got != value {
				t.Fatalf("%q -> %q, want %q", wrapped, got, value)
			}
			if got, _, found := readLandingSecrets("1"); !found || got != value {
				t.Fatalf("落地密码 %q -> %q", wrapped, got)
			}
		}
		if err := setSecret("ANYTLS_PASS", value); err != nil {
			t.Fatal(err)
		}
		if got := readSecrets().AnyTLSPass; got != value {
			t.Fatalf("写入往返 %q -> %q", value, got)
		}
	}
	before, _ := os.ReadFile(secretsPath)
	if err := setSecret("ANYTLS_PASS", "bad\nKEY=injected"); err == nil {
		t.Fatal("允许注入新行")
	}
	after, _ := os.ReadFile(secretsPath)
	if string(before) != string(after) {
		t.Fatal("无效写入改变了文件")
	}
}

func testCertPair(t *testing.T, dir string) {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "your-domain.com"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	priv, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	for name, block := range map[string]*pem.Block{
		"fullchain.pem": {Type: "CERTIFICATE", Bytes: der}, "privkey.pem": {Type: "PRIVATE KEY", Bytes: priv},
	} {
		if err := os.WriteFile(filepath.Join(dir, name), pem.EncodeToMemory(block), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func certFixture(t *testing.T) string {
	t.Helper()
	landingFixture(t)
	dir := t.TempDir()
	testCertPair(t, dir)
	oldIssue, oldAcme, oldGen, oldLog, oldAccount := binCertIssue, binAcme, binGenConf, certIssueLog, acmeAccountConf
	t.Cleanup(func() {
		binCertIssue, binAcme, binGenConf, certIssueLog, acmeAccountConf = oldIssue, oldAcme, oldGen, oldLog, oldAccount
	})
	binCertIssue, binAcme, binGenConf = filepath.Join(dir, "issue"), filepath.Join(dir, "renew"), filepath.Join(dir, "genconf")
	certIssueLog, acmeAccountConf = filepath.Join(dir, "cert.log"), filepath.Join(dir, "account.conf")
	t.Setenv("CERT_TEST_LOG", certIssueLog)
	t.Setenv("CERT_TEST_DIR", dir)
	for _, path := range []string{binCertIssue, binAcme} {
		body := `#!/bin/sh
[ "$ANSGO_SKIP_PANEL_RESTART" = 1 ] && [ "$ANSGO_SKIP_PROXY_RESTART" = 1 ] || exit 91
printf '本次签发日志\n' >> "$CERT_TEST_LOG"
printf '\n' >> "$CERT_TEST_DIR/privkey.pem"
if [ "${CERT_TEST_DAMAGE:-0}" = 1 ]; then printf invalid > "$CERT_TEST_DIR/privkey.pem"; fi
exit "${CERT_TEST_EXIT:-0}"
`
		if err := os.WriteFile(path, []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(binGenConf, []byte("#!/bin/sh\nexit \"${CERT_TEST_GEN_EXIT:-0}\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := configGet()
	c.Landings = nil
	c.CertMode, c.CertDir = "manual", dir
	manual := t.TempDir()
	testCertPair(t, manual)
	c.CertFullchain, c.CertPrivkey = filepath.Join(manual, "fullchain.pem"), filepath.Join(manual, "privkey.pem")
	c.DynuAPIKey = ""
	if err := configSet(c); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(certIssueLog, []byte("历史日志不应回传\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// 此处只验证唯一入口的响应协议，防止单元测试启动宿主重启命令。
	restartMu.Lock()
	oldPending := restartPending
	restartPending = true
	restartMu.Unlock()
	t.Cleanup(func() {
		restartMu.Lock()
		restartPending = oldPending
		restartMu.Unlock()
	})
	return dir
}

func TestManualAcmeIssueTransaction(t *testing.T) {
	for _, scenario := range []string{"issue", "config", "failure", "invalid-pair", "genconf-failure", "shared-failure"} {
		t.Run(scenario, func(t *testing.T) {
			dir := certFixture(t)
			if scenario == "failure" || scenario == "shared-failure" {
				t.Setenv("CERT_TEST_EXIT", "1")
			}
			if scenario == "invalid-pair" || scenario == "shared-failure" {
				t.Setenv("CERT_TEST_DAMAGE", "1")
			}
			if scenario == "shared-failure" {
				c := configGet()
				c.CertFullchain, c.CertPrivkey = filepath.Join(dir, "fullchain.pem"), filepath.Join(dir, "privkey.pem")
				if err := configSet(c); err != nil {
					t.Fatal(err)
				}
			}
			originalKey, _ := os.ReadFile(filepath.Join(dir, "privkey.pem"))
			if scenario == "genconf-failure" {
				t.Setenv("CERT_TEST_GEN_EXIT", "1")
			}
			handler := certIssueHandler
			if scenario == "config" {
				handler = certConfigHandler
			}
			w := landingRequest(handler, `{"mode":"acme","dynu_api_key":"example-key","acme_email":"admin@your-domain.com"}`)
			failed := scenario == "failure" || scenario == "invalid-pair" || scenario == "genconf-failure" || scenario == "shared-failure"
			var response map[string]any
			json.Unmarshal(w.Body.Bytes(), &response)
			want := "acme"
			if failed {
				want = "manual"
				if w.Code != 500 {
					t.Fatal(w.Body.String())
				}
			} else if w.Code != 200 || response["restart_in"] != float64(3) || response["new_url"] == nil {
				t.Fatal(w.Body.String())
			}
			disk, err := loadConfig()
			if err != nil || configGet().CertMode != want || disk.CertMode != want || disk.DynuAPIKey != "example-key" {
				t.Fatalf("证书切换不原子: %+v %v", disk, err)
			}
			if response["log"] != "本次签发日志\n" {
				t.Fatalf("未返回本次日志: %s", w.Body.String())
			}
			if failed {
				currentKey, _ := os.ReadFile(filepath.Join(dir, "privkey.pem"))
				if string(currentKey) != string(originalKey) {
					t.Fatal("失败未恢复目标证书对")
				}
				full, key := certPaths(configGet())
				if _, err := tls.LoadX509KeyPair(full, key); err != nil {
					t.Fatal("manual 证书被损坏", err)
				}
			}
		})
	}
}

func TestCertRenewSingleRestartAndFailure(t *testing.T) {
	certFixture(t)
	c := configGet()
	c.CertMode = "acme"
	configSet(c)
	for _, failure := range []bool{false, true} {
		code := "0"
		if failure {
			code = "1"
		}
		t.Setenv("CERT_TEST_EXIT", code)
		w := landingRequest(certRenewHandler, "")
		var response map[string]any
		json.Unmarshal(w.Body.Bytes(), &response)
		if failure {
			if w.Code != 500 || response["restart_in"] != nil {
				t.Fatal(w.Body.String())
			}
		} else if w.Code != 200 || response["restart_in"] != float64(3) || response["new_url"] == nil {
			t.Fatal(w.Body.String())
		}
		if response["log"] != "本次签发日志\n" {
			t.Fatal(w.Body.String())
		}
	}
}

func TestCertLogBoundAndRotation(t *testing.T) {
	certFixture(t)
	start := certLogBoundary()
	f, _ := os.OpenFile(certIssueLog, os.O_APPEND|os.O_WRONLY, 0600)
	f.WriteString(strings.Repeat("x", 80*1024))
	f.Close()
	if out := certLogSince(start, nil); len(out) != 64*1024 || strings.Contains(out, "历史") {
		t.Fatal("日志未按本次偏移限长")
	}
	start = certLogBoundary()
	os.WriteFile(certIssueLog, []byte("轮转后的本次日志"), 0600)
	if out := certLogSince(start, nil); out != "轮转后的本次日志" {
		t.Fatal(out)
	}
}

func TestSessionDBPermissions(t *testing.T) {
	old := db
	path := filepath.Join(t.TempDir(), "sessions.db")
	if err := initDB(path); err != nil {
		t.Fatal(err)
	}
	defer func() { db.Close(); db = old }()
	if _, err := db.Exec("PRAGMA journal_mode=WAL; INSERT INTO sessions VALUES('test','source',0,1)"); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		st, err := os.Stat(path + suffix)
		if err != nil || st.Mode().Perm() != 0600 {
			t.Fatalf("%s 权限错误: %v %v", suffix, st, err)
		}
	}
	db.Close()
	os.Chmod(path, 0644)
	if err := initDB(path); err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0600 {
		t.Fatal("未修复旧库权限")
	}
}

func TestUpgradeFlockAutoAndStaleResult(t *testing.T) {
	dir := t.TempDir()
	oldLock, oldResult := upgradeLockPath, upgradeResultPath
	upgradeLockPath, upgradeResultPath = filepath.Join(dir, "lock"), filepath.Join(dir, "result")
	t.Cleanup(func() { upgradeLockPath, upgradeResultPath = oldLock, oldResult })
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	body := "#!/bin/sh\ncase \"$1\" in\nlist-units) printf '%s' \"$UPGRADE_TEST_UNITS\";;\nshow) printf '%s' \"$UPGRADE_TEST_PROPS\";;\nesac\n"
	os.WriteFile(filepath.Join(dir, "systemctl"), []byte(body), 0700)
	f, _ := os.OpenFile(upgradeLockPath, os.O_CREATE|os.O_RDWR, 0600)
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if _, running, _, err := upgradeState(); err != nil || !running {
		t.Fatal("未识别 CLI flock")
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	t.Setenv("UPGRADE_TEST_UNITS", "ansgo-autoupgrade.service loaded activating start\n")
	t.Setenv("UPGRADE_TEST_PROPS", "ActiveState=activating\nInvocationID=example-invocation\n")
	if _, running, _, err := upgradeState(); err != nil || !running {
		t.Fatal("未识别自动升级 activating")
	}
	for _, state := range []string{"active", "inactive"} {
		t.Setenv("UPGRADE_TEST_PROPS", "ActiveState="+state+"\nInvocationID=example-invocation\n")
		record := upgradeResult{Result: "failed", TaskID: "example-invocation", StartedAt: time.Now().Unix(), FinishedAt: time.Now().Unix()}
		data, _ := json.Marshal(record)
		os.WriteFile(upgradeResultPath, data, 0600)
		_, running, result, err := upgradeState()
		if err != nil || running != (state == "active") || (state == "inactive" && result != "failed") {
			t.Fatalf("%s %t %s %v", state, running, result, err)
		}
	}
	t.Setenv("UPGRADE_TEST_UNITS", "ansgo-upgrade-example.service loaded inactive dead\n")
	os.WriteFile(upgradeResultPath, []byte(`{"result":"success","task_id":"old","started_at":1,"finished_at":2}`), 0600)
	t.Setenv("UPGRADE_TEST_PROPS", "ActiveState=inactive\nExecMainStartTimestamp="+time.Now().UTC().Format("Mon 2006-01-02 15:04:05 MST")+"\n")
	if _, _, result, err := upgradeState(); err != nil || result != "" {
		t.Fatal("展示了不匹配的历史结果")
	}
}

func TestCleanupUsesAdminFreedBytes(t *testing.T) {
	dir := t.TempDir()
	oldAdmin, oldDB := binAdmin, db
	binAdmin = filepath.Join(dir, "admin")
	if err := initDB(filepath.Join(dir, "sessions.db")); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close(); db = oldDB; binAdmin = oldAdmin })
	for _, text := range []string{"清理完成\nFREED_BYTES=4242\n", "FREED_BYTES=-1\n", "缺少释放量\n"} {
		os.WriteFile(binAdmin, []byte("#!/bin/sh\nprintf '"+text+"'\n"), 0700)
		w := httptest.NewRecorder()
		systemCleanupHandler(w, httptest.NewRequest("POST", "/", nil))
		if strings.Contains(text, "4242") {
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"freed_bytes":4242`) {
				t.Fatal(w.Body.String())
			}
		} else if w.Code != 500 {
			t.Fatal("无效释放量未报错")
		}
	}
}
