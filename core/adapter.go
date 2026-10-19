package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

var configDir = "/etc/gre-panel"
var frpDir = "/etc/frp"

type coreConfig struct {
	Port int `json:"port"`
}

var cfg = coreConfig{Port: 47777}

func cfgPath() string                     { return filepath.Join(configDir, "core.json") }
func saveConfigAtomic(c coreConfig) error { return saveJSONPrivate(cfgPath(), c) }
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

type localCLIKey struct{}

func cliContext() context.Context {
	return context.WithValue(context.Background(), localCLIKey{}, true)
}
func saveJSONPrivate(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".nava-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if e = f.Chmod(0600); e != nil {
		return e
	}
	if _, e = f.Write(append(b, '\n')); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(f.Name(), path)
}
func getLocalTunnelStatus() (string, float64, float64) {
	c := loadClusterConfig()
	if c.Enabled && len(c.ForeignNodes) > 0 {
		selection := foreignSelection(c)
		fresh := false
		for _, n := range c.ForeignNodes {
			if !n.LastProbe.IsZero() && time.Since(n.LastProbe) < 15*time.Second {
				fresh = true
			}
		}
		for _, n := range selection.ForeignNodes {
			if n.IsHealthy && !n.LastProbe.IsZero() && time.Since(n.LastProbe) < 15*time.Second {
				return "UP", 0, n.LatencyMs
			}
		}
		if fresh {
			return "DOWN", 100, 0
		}
		return "UNKNOWN", 0, 0
	}
	return nativeTunnelStatus()
}
