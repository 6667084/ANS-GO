package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const maxCommandOutput = 256 * 1024

// 子进程的 stdout/stderr 可并发写入，达到上限后继续排空，避免阻塞子进程。
type boundedBuffer struct {
	mu   sync.Mutex
	data []byte
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	if left := maxCommandOutput - len(b.data); left > 0 {
		if len(p) > left {
			p = p[:left]
		}
		b.data = append(b.data, p...)
	}
	return n, nil
}

func (b *boundedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.data)
}

type limitedCommand struct {
	*exec.Cmd
	cancel context.CancelFunc
}

func command(name string, args ...string) *limitedCommand {
	return commandContext(context.Background(), name, args...)
}

func commandContext(parent context.Context, name string, args ...string) *limitedCommand {
	timeout := 60 * time.Second
	if name == binGenConf {
		timeout = 90 * time.Second
	}
	if name == binAcme || name == binCertIssue || (len(args) > 0 && args[0] == binCertIssue) {
		timeout = 300 * time.Second
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = time.Second
	return &limitedCommand{Cmd: cmd, cancel: cancel}
}

func (c *limitedCommand) Run() error { defer c.cancel(); return c.Cmd.Run() }
func (c *limitedCommand) Start() error {
	err := c.Cmd.Start()
	if err != nil {
		c.cancel()
	}
	return err
}
func (c *limitedCommand) Wait() error { defer c.cancel(); return c.Cmd.Wait() }
func (c *limitedCommand) CombinedOutput() ([]byte, error) {
	var b boundedBuffer
	c.Stdout = &b
	c.Stderr = &b
	err := c.Run()
	return []byte(b.String()), err
}
func (c *limitedCommand) Output() ([]byte, error) {
	var out, stderr boundedBuffer
	c.Stdout = &out
	c.Stderr = &stderr
	err := c.Run()
	return []byte(out.String()), err
}

func atomicWrite(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".ansgo-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func cleanupSessions(d *sql.DB) error {
	now := time.Now().Unix()
	if _, err := d.Exec("DELETE FROM sessions WHERE expires<=?", now); err != nil {
		return err
	}
	_, err := d.Exec("DELETE FROM lockout WHERE (locked_until>0 AND locked_until<=?) OR (locked_until=0 AND updated<?)", now, now-3600)
	return err
}

func sessionCleanupLoop(ctx context.Context, d *sql.DB) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_ = cleanupSessions(d)
		}
	}
}

func commandError(name string, out []byte, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s 失败: %w: %s", name, err, out)
}
