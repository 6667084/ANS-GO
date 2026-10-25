package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAdminCmdHint(t *testing.T) {
	for _, docker := range []bool{false, true} {
		mode := "metal"
		if docker {
			mode = "docker"
		}
		t.Run(mode, func(t *testing.T) {
			t.Setenv("ANSGO_DOCKER", "")
			if docker {
				t.Setenv("ANSGO_DOCKER", "1")
			} else if _, err := os.Stat("/.dockerenv"); err == nil {
				t.Skip("容器环境不能模拟裸金属")
			}
			for _, args := range []string{"restart panel", "restart all", "panel-pass", "logs caddy"} {
				want := "ansgo-admin " + args
				if docker {
					prefix := "docker exec ansgo "
					if args == "panel-pass" {
						prefix = "docker exec -it ansgo "
					}
					want = prefix + want
				}
				if got := adminCmdHint(args); got != want {
					t.Errorf("adminCmdHint(%q) = %q, want %q", args, got, want)
				}
			}
			oldGenConf := binGenConf
			binGenConf = filepath.Join(t.TempDir(), "missing-genconf")
			t.Cleanup(func() { binGenConf = oldGenConf })
			w := httptest.NewRecorder()
			repairHandler(w, httptest.NewRequest("POST", "/", strings.NewReader(`{"target":"all"}`)))
			var response struct{ Hint string }
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if w.Code != 500 || !strings.Contains(response.Hint, adminCmdHint("restart all")) {
				t.Fatalf("修复失败提示: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestUnauthedAuthDoesNotExposeDeployMode(t *testing.T) {
	t.Setenv("ANSGO_DOCKER", "1")
	w := httptest.NewRecorder()
	authCheckHandler(w, httptest.NewRequest("GET", "/api/auth", nil))
	if w.Code != 200 || strings.Contains(w.Body.String(), "deploy_mode") {
		t.Fatalf("未鉴权 auth 响应: %d %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	requireAuth(systemInfoHandler)(w, httptest.NewRequest("GET", "/api/system/info", nil))
	if w.Code != 401 || strings.Contains(w.Body.String(), "deploy_mode") {
		t.Fatalf("未鉴权 system/info 响应: %d %s", w.Code, w.Body.String())
	}
}
