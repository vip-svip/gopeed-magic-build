//go:build web

package main

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// 模块控制：Web 面板与 App 共用同一套 gopeedctl。
// 该二进制以 root 运行，因此可直接执行控制脚本，无需 KernelSU 的 JS 桥。
// 这样面板在普通浏览器里也能工作（此前依赖 window.ksu，浏览器打开时全部失效）。

var ctlCandidates = []string{
	"/data/adb/modules/gopeed_ksu/bin/gopeedctl",
	"/data/adb/modules_update/gopeed_ksu/bin/gopeedctl",
}

func gopeedctlPath() string {
	if d := os.Getenv("GOPEED_MODDIR"); d != "" {
		p := filepath.Join(d, "bin", "gopeedctl")
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	for _, p := range ctlCandidates {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func runCtl(args ...string) (string, error) {
	ctl := gopeedctlPath()
	if ctl == "" {
		return "", os.ErrNotExist
	}
	cmd := exec.Command("sh", append([]string{ctl}, args...)...)
	cmd.Env = append(os.Environ(), "GOPEED_MODDIR="+filepath.Dir(filepath.Dir(ctl)))
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// parseKV 解析 gopeedctl info 的 key=value 输出
func parseKV(text string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if i := strings.Index(line, "="); i > 0 {
			out[strings.TrimSpace(line[:i])] = strings.TrimSpace(line[i+1:])
		}
	}
	return out
}

func writeAdminJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// 仅允许本机访问管理接口：服务默认监听 127.0.0.1，
// 若用户改成 0.0.0.0，也不把端口控制暴露到局域网。
func adminLocalOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			writeAdminJSON(w, http.StatusForbidden, map[string]any{"ok": false, "message": "仅允许本机访问"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func newAdminHandler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/info", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodPost {
			writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false})
			return
		}
		raw, err := runCtl("info")
		if err != nil && raw == "" {
			writeAdminJSON(w, http.StatusOK, map[string]any{
				"ok":      false,
				"message": "模块控制脚本不可用",
			})
			return
		}
		kv := parseKV(raw)
		kv["ok"] = "true"
		writeAdminJSON(w, http.StatusOK, kv)
	})

	action := func(arg, label string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "message": "需要 POST"})
				return
			}
			done := make(chan struct{})
			var out string
			var err error
			go func() {
				out, err = runCtl(arg)
				close(done)
			}()
			select {
			case <-done:
			case <-time.After(20 * time.Second):
				writeAdminJSON(w, http.StatusOK, map[string]any{"ok": false, "message": label + "超时"})
				return
			}
			msg := out
			if msg == "" {
				if err != nil {
					msg = label + "失败"
				} else {
					msg = label + "完成"
				}
			}
			writeAdminJSON(w, http.StatusOK, map[string]any{"ok": err == nil, "message": msg})
		}
	}

	mux.HandleFunc("/admin/restart", action("restart", "重启服务"))
	mux.HandleFunc("/admin/enable", action("enable", "开启端口"))
	mux.HandleFunc("/admin/disable", action("disable", "关闭端口"))
	mux.HandleFunc("/admin/apk", action("install-apk", "安装 App"))

	return adminLocalOnly(mux)
}
