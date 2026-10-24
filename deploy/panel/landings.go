package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

func (l *LandingService) UnmarshalJSON(data []byte) error {
	type plain LandingService
	var v struct {
		*plain
		Host     string `json:"remote_host"`
		Port     int    `json:"remote_port"`
		Method   string `json:"remote_method"`
		Password string `json:"remote_password"`
		User     string `json:"remote_user"`
	}
	v.plain = (*plain)(l)
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	l.RemoteType = strings.ToLower(strings.TrimSpace(l.RemoteType))
	if l.RemoteType == "" {
		l.RemoteType = "ss"
	}
	if l.RemoteType == "socks" {
		if _, ok := fields["remote_socks"]; !ok {
			l.RemoteSocks = RemoteSocks{v.Host, v.Port, v.User, v.Password}
		}
	} else if _, ok := fields["remote_ss"]; !ok {
		l.RemoteSS = RemoteSS{v.Host, v.Port, v.Method, v.Password}
	}
	l.syncRemoteMirror()
	return nil
}

func (l *LandingService) syncRemoteMirror() {
	l.RemoteHost, l.RemoteMethod, l.RemotePassword, l.RemoteUser = "", "", "", ""
	l.RemotePort = 0
	if l.RemoteType == "socks" {
		r := l.RemoteSocks
		l.RemoteHost, l.RemotePort, l.RemoteUser, l.RemotePassword = r.Host, r.Port, r.User, r.Password
	} else {
		r := l.RemoteSS
		l.RemoteHost, l.RemotePort, l.RemoteMethod, l.RemotePassword = r.Host, r.Port, r.Method, r.Password
	}
}

// 兼容旧 Go 调用方的字面量；规范化不会自动启用远端或删除另一套草稿。
func normalizeLanding(l *LandingService) {
	l.RemoteType = strings.ToLower(strings.TrimSpace(l.RemoteType))
	if l.RemoteType == "" {
		l.RemoteType = "ss"
	}
	if l.RemoteSS == (RemoteSS{}) && l.RemoteSocks == (RemoteSocks{}) {
		if l.RemoteType == "socks" {
			l.RemoteSocks = RemoteSocks{l.RemoteHost, l.RemotePort, l.RemoteUser, l.RemotePassword}
		} else {
			l.RemoteSS = RemoteSS{l.RemoteHost, l.RemotePort, l.RemoteMethod, l.RemotePassword}
		}
	}
	l.syncRemoteMirror()
}

func validateLandingRemote(l *LandingService) string {
	normalizeLanding(l)
	if l.RemoteType != "ss" && l.RemoteType != "socks" {
		return "remote_type 必须为 ss 或 socks"
	}
	for _, s := range []string{l.RemoteSS.Host, l.RemoteSS.Method, l.RemoteSS.Password, l.RemoteSocks.Host, l.RemoteSocks.User, l.RemoteSocks.Password} {
		if utf8.RuneCountInString(s) > 256 {
			return "远端每个字段不得超过 256 字符"
		}
	}
	if !l.RemoteEnabled {
		return ""
	}
	if strings.TrimSpace(l.RemoteHost) == "" || !validPort(l.RemotePort) {
		return "启用远端落地需填写 host 和 1-65535 的 port"
	}
	if l.RemoteType == "socks" {
		if l.RemoteUser == "" || l.RemotePassword == "" {
			return "SOCKS5 远端需填写用户名和密码"
		}
		for _, s := range []string{l.RemoteUser, l.RemotePassword} {
			if strings.Contains(s, ":") || strings.IndexFunc(s, unicode.IsSpace) >= 0 {
				return "SOCKS5 用户名/密码不能包含冒号或空白字符"
			}
		}
	} else {
		if l.RemoteSS.Method == "" {
			l.RemoteSS.Method = "2022-blake3-aes-128-gcm"
		}
		if l.RemotePassword == "" {
			return "Shadowsocks 远端需填写密钥"
		}
		key, msg := normalizeSS2022Key(l.RemoteSS.Method, l.RemoteSS.Password)
		if msg != "" {
			return msg
		}
		l.RemoteSS.Password = key
	}
	l.syncRemoteMirror()
	return ""
}

func migrateLandings(c *Config) bool {
	if c == nil {
		return false
	}
	before, _ := json.Marshal(c)
	legacy := c.LandingsSchema < 2
	for i := range c.Landings {
		l := &c.Landings[i]
		normalizeLanding(l)
		if legacy && !l.RemoteEnabled {
			trial := *l
			trial.RemoteEnabled = true
			if validateLandingRemote(&trial) == "" {
				*l = trial
			}
		}
		if n, err := strconv.Atoi(l.ID); err == nil && n >= c.LandingNextID {
			c.LandingNextID = n + 1
		}
	}
	if c.LandingNextID < 1 {
		c.LandingNextID = 1
	}
	c.LandingsSchema = 2
	after, _ := json.Marshal(c)
	return string(before) != string(after)
}

type remoteSSPatch struct {
	Host     *string `json:"host"`
	Port     *int    `json:"port"`
	Method   *string `json:"method"`
	Password *string `json:"password"`
}
type remoteSocksPatch struct {
	Host     *string `json:"host"`
	Port     *int    `json:"port"`
	User     *string `json:"user"`
	Password *string `json:"password"`
}
type landingPatch struct {
	ID             string            `json:"id"`
	Name           *string           `json:"name"`
	Port           *int              `json:"port"`
	Enabled        *bool             `json:"enabled"`
	Password       *string           `json:"password"`
	RemoteEnabled  *bool             `json:"remote_enabled"`
	RemoteType     *string           `json:"remote_type"`
	SS             *remoteSSPatch    `json:"remote_ss"`
	Socks          *remoteSocksPatch `json:"remote_socks"`
	Host           *string           `json:"remote_host"`
	RemotePort     *int              `json:"remote_port"`
	Method         *string           `json:"remote_method"`
	RemotePassword *string           `json:"remote_password"`
	User           *string           `json:"remote_user"`
}

func (p landingPatch) apply(l *LandingService) string {
	normalizeLanding(l)
	if p.Name != nil {
		l.Name = strings.TrimSpace(*p.Name)
	}
	if p.Port != nil {
		l.Port = *p.Port
	}
	if p.Enabled != nil {
		l.Enabled = *p.Enabled
	}
	if p.RemoteEnabled != nil {
		l.RemoteEnabled = *p.RemoteEnabled
	}
	if p.RemoteType != nil {
		l.RemoteType = *p.RemoteType
	}
	if l.RemoteType != "ss" && l.RemoteType != "socks" {
		return "remote_type 必须为 ss 或 socks"
	}
	if p.SS != nil {
		r := p.SS
		if r.Host != nil {
			l.RemoteSS.Host = *r.Host
		}
		if r.Port != nil {
			l.RemoteSS.Port = *r.Port
		}
		if r.Method != nil {
			l.RemoteSS.Method = *r.Method
		}
		if r.Password != nil {
			l.RemoteSS.Password = *r.Password
		}
	}
	if p.Socks != nil {
		r := p.Socks
		if r.Host != nil {
			l.RemoteSocks.Host = *r.Host
		}
		if r.Port != nil {
			l.RemoteSocks.Port = *r.Port
		}
		if r.User != nil {
			l.RemoteSocks.User = *r.User
		}
		if r.Password != nil {
			l.RemoteSocks.Password = *r.Password
		}
	}
	if l.RemoteType == "ss" {
		if p.Host != nil {
			l.RemoteSS.Host = *p.Host
		}
		if p.RemotePort != nil {
			l.RemoteSS.Port = *p.RemotePort
		}
		if p.Method != nil {
			l.RemoteSS.Method = *p.Method
		}
		if p.RemotePassword != nil {
			l.RemoteSS.Password = *p.RemotePassword
		}
	} else {
		if p.Host != nil {
			l.RemoteSocks.Host = *p.Host
		}
		if p.RemotePort != nil {
			l.RemoteSocks.Port = *p.RemotePort
		}
		if p.User != nil {
			l.RemoteSocks.User = *p.User
		}
		if p.RemotePassword != nil {
			l.RemoteSocks.Password = *p.RemotePassword
		}
	}
	l.syncRemoteMirror()
	if l.Name == "" || utf8.RuneCountInString(l.Name) > 64 {
		return "名称需为 1-64 字符"
	}
	if !validPort(l.Port) {
		return "端口必须在 1-65535 范围"
	}
	if p.Password != nil && (strings.TrimSpace(*p.Password) == "" || strings.ContainsAny(*p.Password, "\r\n")) {
		return "落地 AnyTLS 密码不能为空或包含换行"
	}
	return validateLandingRemote(l)
}

type fileSnapshot struct {
	path   string
	data   []byte
	exists bool
}

func snapshot(path string) (fileSnapshot, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return fileSnapshot{path: path}, nil
	}
	return fileSnapshot{path, data, err == nil}, err
}
func (s fileSnapshot) restore() error {
	if s.exists {
		return atomicWrite(s.path, s.data)
	}
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

var landingApply = genconfRestartVerify
var landingGeneratedPaths = []string{"/etc/sing-box/config.json"}

// ponytail: 最多 32 个落地，全局串行事务足够；调用方持有 configChangeMu。
func applyLandingTransaction(next Config, secrets func() error) error {
	return applyConfigTransaction(next, secrets, func() error { _, err := landingApply("sing-box"); return err }, landingGeneratedPaths)
}

func applyConfigTransaction(next Config, secrets func() error, apply func() error, generatedPaths []string) error {
	var saved []fileSnapshot
	for _, path := range append([]string{confPath, secretsPath}, generatedPaths...) {
		s, err := snapshot(path)
		if err != nil {
			return err
		}
		saved = append(saved, s)
	}
	if err := saveConfig(next); err != nil {
		return err
	}
	err := secrets()
	if err == nil {
		err = apply()
	}
	if err == nil {
		cfgMu.Lock()
		cfg = cloneConfig(next)
		cfgMu.Unlock()
		return nil
	}
	var recovery error
	// 先恢复源文件，再重新生成旧配置和恢复服务；最后还原生成文件的原始字节。
	for _, s := range saved[:2] {
		recovery = errors.Join(recovery, s.restore())
	}
	if recovery == nil {
		applyErr := apply()
		recovery = errors.Join(recovery, applyErr)
	}
	for _, s := range saved[2:] {
		recovery = errors.Join(recovery, s.restore())
	}
	if recovery != nil {
		return fmt.Errorf("%w；旧配置恢复未完全成功: %v", err, recovery)
	}
	return fmt.Errorf("%w；已恢复旧配置与凭证", err)
}

func generateLandingSecrets(id string) error {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return err
	}
	if err := setSecret("LANDING_"+id+"_PASS", hex.EncodeToString(b[:])); err != nil {
		return err
	}
	if _, err := rand.Read(b[:16]); err != nil {
		return err
	}
	return setSecret("LANDING_"+id+"_UUID", fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

func landingsHandler(w http.ResponseWriter, r *http.Request)      { landingMutation(w, r, "create") }
func landingUpdateHandler(w http.ResponseWriter, r *http.Request) { landingMutation(w, r, "update") }
func landingDeleteHandler(w http.ResponseWriter, r *http.Request) { landingMutation(w, r, "delete") }
func landingRegenHandler(w http.ResponseWriter, r *http.Request)  { landingMutation(w, r, "regen") }

func landingMutation(w http.ResponseWriter, r *http.Request, action string) {
	configChangeMu.Lock()
	defer configChangeMu.Unlock()
	c := configGet()
	if action == "create" && r.Method == "GET" {
		out := []map[string]any{}
		for _, l := range c.Landings {
			out = append(out, landingToMap(l))
		}
		jwrite(w, 200, map[string]any{"landings": out})
		return
	}
	if r.Method != "POST" {
		jerr(w, 405, "方法不允许")
		return
	}
	var p landingPatch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		jerr(w, 400, "请求格式错误")
		return
	}
	migrateLandings(&c)
	idx := -1
	for i := range c.Landings {
		if c.Landings[i].ID == p.ID {
			idx = i
			break
		}
	}
	secretChange := func() error { return nil }
	if action == "create" {
		if len(c.Landings) >= 32 {
			jerr(w, 400, "落地服务最多 32 个")
			return
		}
		l := LandingService{ID: strconv.Itoa(c.LandingNextID), Enabled: true, RemoteType: "ss"}
		if msg := p.apply(&l); msg != "" {
			jerr(w, 400, msg)
			return
		}
		c.LandingNextID++
		c.Landings = append(c.Landings, l)
		idx = len(c.Landings) - 1
		secretChange = func() error { return generateLandingSecrets(l.ID) }
	} else {
		if idx < 0 {
			jerr(w, 404, "未找到落地服务")
			return
		}
		switch action {
		case "update":
			if msg := p.apply(&c.Landings[idx]); msg != "" {
				jerr(w, 400, msg)
				return
			}
			if p.Password != nil {
				secretChange = func() error { return setLandingPassword(p.ID, *p.Password) }
			}
		case "delete":
			c.Landings = append(c.Landings[:idx], c.Landings[idx+1:]...)
			secretChange = func() error { return removeSecretsByPrefix("LANDING_" + p.ID + "_") }
		case "regen":
			secretChange = func() error { return generateLandingSecrets(p.ID) }
		}
	}
	if msg := portConflicts(c); msg != "" {
		jerr(w, 400, "端口冲突: "+msg)
		return
	}
	if err := applyLandingTransaction(c, secretChange); err != nil {
		jerr(w, 500, err.Error())
		return
	}
	resp := map[string]any{"ok": true}
	if action != "delete" {
		resp["landing"] = landingToMap(c.Landings[idx])
	}
	jwrite(w, 200, resp)
}
