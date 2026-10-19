package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const coreVersion = "v1.1.1"

func socketPath() string { return filepath.Join(configDir, "core.sock") }

type controlCall struct {
	Family  string          `json:"family"`
	Action  string          `json:"action"`
	Body    json.RawMessage `json:"body"`
	Query   string          `json:"query"`
	Secrets bool            `json:"secrets"`
}

func localHandler(c controlCall) (http.HandlerFunc, error) {
	handlers := map[string]http.HandlerFunc{
		"cluster/status": handleClusterStatus, "cluster/config": handleClusterConfigPost,
		"cluster/add-foreign": handleClusterForeignNodeAdd, "cluster/del-foreign": handleClusterForeignNodeDelete,
		"cluster/switch-foreign": handleClusterForeignSwitch, "cluster/add-iran": handleClusterNodeAdd,
		"cluster/del-iran": handleClusterNodeDelete, "cluster/failover": handleClusterFailoverTrigger,
		"cluster/revert": handleClusterFailoverRevert,
	}
	if h := handlers[c.Family+"/"+c.Action]; h != nil {
		return h, nil
	}
	return nil, fmt.Errorf("unknown operation %s/%s", c.Family, c.Action)
}
func maskOutput(b []byte, secrets bool) []byte {
	if secrets {
		return b
	}
	var v any
	if json.Unmarshal(b, &v) != nil {
		return b
	}
	var scrub func(any)
	scrub = func(x any) {
		switch m := x.(type) {
		case map[string]any:
			for k, val := range m {
				key := strings.ToLower(k)
				if strings.Contains(key, "secret") || strings.Contains(key, "password") || key == "token" || key == "auth_token" || key == "code" {
					if val != "" && val != nil {
						m[k] = "[REDACTED]"
					}
				} else {
					scrub(val)
				}
			}
		case []any:
			for _, y := range m {
				scrub(y)
			}
		}
	}
	scrub(v)
	out, _ := json.MarshalIndent(v, "", "  ")
	return append(out, '\n')
}
func dispatch(c controlCall) (int, []byte) {
	if c.Family == "maintenance" && c.Action == "purge" {
		if e := purgeClusterRules(); e != nil {
			return 500, []byte(e.Error())
		}
		return 200, []byte("Owned Cluster state removed.\n")
	}
	if c.Family == "daemon" && c.Action == "ping" {
		return 200, []byte(`{"running":true,"version":"` + coreVersion + `"}` + "\n")
	}
	if c.Family == "certificate" {
		pin, e := peerFingerprint()
		if e != nil {
			return 500, []byte(e.Error())
		}
		return 200, []byte(pin + "\n")
	}
	if e := validateControl(c); e != nil {
		return 400, []byte(e.Error() + "\n")
	}
	h, e := localHandler(c)
	if e != nil {
		return 400, []byte(e.Error() + "\n")
	}
	body := c.Body
	if len(body) == 0 {
		body = json.RawMessage(`{}`)
	}
	req := httptest.NewRequest(http.MethodPost, "http://localhost/control?"+c.Query, bytes.NewReader(body)).WithContext(cliContext())
	req.RemoteAddr = "127.0.0.1:0"
	w := httptest.NewRecorder()
	h(w, req)
	return w.Code, maskOutput(w.Body.Bytes(), c.Secrets)
}
func remoteControl(c controlCall) (int, []byte, error) {
	b, _ := json.Marshal(c)
	client := &http.Client{Timeout: 180 * time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socketPath())
	}}}
	resp, e := client.Post("http://unix/control", "application/json", bytes.NewReader(b))
	if e != nil {
		return 0, nil, e
	}
	defer resp.Body.Close()
	out, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return resp.StatusCode, out, e
}
func serve(listen string, useTLS bool) error {
	if listen != "" {
		cfg.Port = endpointPort(listen)
		if err := saveConfigAtomic(cfg); err != nil {
			return err
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if e := os.MkdirAll(configDir, 0700); e != nil {
		return e
	}
	// Never unlink another live daemon's socket.
	if conn, e := net.DialTimeout("unix", socketPath(), time.Second); e == nil {
		conn.Close()
		return errors.New("core daemon is already running")
	}
	if e := os.Remove(socketPath()); e != nil && !os.IsNotExist(e) {
		return e
	}
	l, e := net.Listen("unix", socketPath())
	if e != nil {
		return e
	}
	defer l.Close()
	defer os.Remove(socketPath())
	if e = os.Chmod(socketPath(), 0600); e != nil {
		return e
	}
	local := http.NewServeMux()
	local.HandleFunc("/control", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		var c controlCall
		if e := json.NewDecoder(r.Body).Decode(&c); e != nil {
			http.Error(w, "invalid request", 400)
			return
		}
		status, b := dispatch(c)
		w.WriteHeader(status)
		_, _ = w.Write(b)
	})
	localServer := &http.Server{Handler: local, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = localServer.Serve(l) }()
	defer localServer.Close()
	// No browser UI or public administration routes are mounted.
	if listen != "" {
		peer := http.NewServeMux()
		peer.HandleFunc("/api/cluster/heartbeat", limitedHeartbeat)
		peer.HandleFunc("/_hp/api/cluster/heartbeat", limitedHeartbeat)
		srv := &http.Server{Addr: listen, Handler: peer, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
		listener, e := net.Listen("tcp", listen)
		if e != nil {
			return e
		}
		if useTLS {
			cert, e := peerCertificate()
			if e != nil {
				listener.Close()
				return e
			}
			listener = tls.NewListener(listener, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}})
		}
		go func() { _ = srv.Serve(listener) }()
		defer srv.Close()
	}
	go startClusterMonitor()
	<-ctx.Done()
	return nil
}
func runCLI(args []string) int {
	if len(args) == 0 || args[0] == "version" {
		fmt.Println(coreVersion)
		return 0
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "Run as root.")
		return 1
	}
	if args[0] == "serve" {
		f := flag.NewFlagSet("serve", flag.ContinueOnError)
		tlsEnabled := f.Bool("tls", false, "TLS for the optional peer listener")
		listen := f.String("listen", "", "Optional peer heartbeat listener; no web panel or admin API")
		if e := f.Parse(args[1:]); e != nil {
			return 1
		}
		if e := serve(*listen, *tlsEnabled); e != nil {
			fmt.Fprintln(os.Stderr, e)
			return 1
		}
		return 0
	}
	if args[0] == "tls-proxy" {
		return tlsProxyCmd(args[1:])
	}
	if args[0] == "secret" {
		b := make([]byte, 32)
		if _, e := rand.Read(b); e != nil {
			return 1
		}
		fmt.Println(hex.EncodeToString(b))
		return 0
	}
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: NavaTunnel advanced FAMILY ACTION [--json JSON] [--query QUERY] [--show-secrets]")
		return 1
	}
	f := flag.NewFlagSet("operation", flag.ContinueOnError)
	body := f.String("json", "{}", "Settings as JSON")
	query := f.String("query", "", "Query parameters")
	secrets := f.Bool("show-secrets", false, "Reveal connection secrets on this local terminal")
	if e := f.Parse(args[2:]); e != nil {
		return 1
	}
	if !json.Valid([]byte(*body)) {
		fmt.Fprintln(os.Stderr, "Invalid JSON")
		return 1
	}
	c := controlCall{Family: args[0], Action: args[1], Body: json.RawMessage(*body), Query: *query, Secrets: *secrets}
	var status int
	var out []byte
	if _, e := os.Stat(socketPath()); e == nil {
		var e error
		status, out, e = remoteControl(c)
		if e != nil {
			fmt.Fprintln(os.Stderr, "Core daemon is unavailable:", e)
			return 1
		}
	} else {
		if c.Family == "daemon" || c.Family == "cluster" && c.Action == "config" && controlEnables(c.Body) {
			fmt.Fprintln(os.Stderr, "Start the background core first: NavaTunnel core-service start")
			return 1
		}
		status, out = dispatch(c)
	}
	if status >= 400 {
		_, _ = os.Stderr.Write(out)
		return 1
	}
	_, _ = os.Stdout.Write(out)
	return 0
}
func main() {
	if p := os.Getenv("NAVATUNNEL_CORE_STATE"); p != "" {
		configDir = p
	}
	if p := os.Getenv("NAVATUNNEL_FRP_DIR"); p != "" {
		frpDir = p
	}
	if b, e := os.ReadFile(cfgPath()); e == nil {
		_ = json.Unmarshal(b, &cfg)
	}
	log.SetFlags(log.LstdFlags)
	os.Exit(runCLI(os.Args[1:]))
}
