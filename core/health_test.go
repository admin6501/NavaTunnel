package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func healthFixture(t *testing.T) {
	t.Helper()
	oldState, oldFRP, oldCmd := configDir, frpDir, localCommand
	configDir = t.TempDir()
	frpDir = t.TempDir()
	t.Cleanup(func() { configDir, frpDir, localCommand = oldState, oldFRP, oldCmd })
}
func TestNativeHealthDoesNotTreatUnconfiguredHostAsDown(t *testing.T) {
	healthFixture(t)
	localCommand = func(string, ...string) ([]byte, error) {
		t.Fatal("unconfigured host should not invoke commands")
		return nil, nil
	}
	s, _, _ := nativeTunnelStatus()
	if s != "UNKNOWN" {
		t.Fatal(s)
	}
}
func TestNativeHealthRequiresMatchingControlConnection(t *testing.T) {
	healthFixture(t)
	os.WriteFile(filepath.Join(frpDir, "frps-3.toml"), []byte("bindPort = 42128\n"), 0600)
	out := "0 0 10.200.0.2:443 10.200.0.1:54321\n"
	localCommand = func(string, ...string) ([]byte, error) { return []byte(out), nil }
	s, _, _ := nativeTunnelStatus()
	if s != "DOWN" {
		t.Fatal(s)
	}
	out = "0 0 [::ffff:10.200.0.2]:42128 [::ffff:10.200.0.1]:54321\n"
	s, _, _ = nativeTunnelStatus()
	if s != "UP" {
		t.Fatal(s)
	}
}
func TestNativeHealthChecksForeignAddressAndPort(t *testing.T) {
	healthFixture(t)
	os.WriteFile(filepath.Join(frpDir, "frpc.toml"), []byte("serverAddr = \"10.200.0.2\"\nserverPort = 42128\n[[proxies]]\nserverPort = 443\n"), 0600)
	out := "0 0 10.200.0.1:12345 10.200.0.6:42128\n"
	localCommand = func(string, ...string) ([]byte, error) { return []byte(out), nil }
	s, _, _ := nativeTunnelStatus()
	if s != "DOWN" {
		t.Fatal(s)
	}
	out = strings.ReplaceAll(out, "10.200.0.6", "10.200.0.2")
	s, _, _ = nativeTunnelStatus()
	if s != "UP" {
		t.Fatal(s)
	}
}
func TestNativeHealthReadFailureIsUnknown(t *testing.T) {
	healthFixture(t)
	os.WriteFile(filepath.Join(frpDir, "frps.toml"), []byte("bindPort=42128\n"), 0600)
	localCommand = func(string, ...string) ([]byte, error) { return nil, errors.New("ss unavailable") }
	s, _, _ := nativeTunnelStatus()
	if s != "UNKNOWN" {
		t.Fatal(s)
	}
}
func TestNativeHealthRetainsNavaLinkSessionSupport(t *testing.T) {
	healthFixture(t)
	p := filepath.Join(configDir, "navalink", "012345abcdef")
	os.MkdirAll(p, 0700)
	os.WriteFile(filepath.Join(p, "config.json"), []byte(`{"id":"012345abcdef","role":"foreign","mode":"frp","control_port":42000}`), 0600)
	localCommand = func(string, ...string) ([]byte, error) { return []byte("0 0 127.0.0.1:43210 127.0.0.1:42000\n"), nil }
	s, _, _ := nativeTunnelStatus()
	if s != "UP" {
		t.Fatal(s)
	}
}
func TestRemovedOperationsAreNotDispatched(t *testing.T) {
	for _, f := range []string{"doctor", "revpath", "rescue", "perf", "history", "usage", "metrics", "alerts", "peer-link", "wss", "netstack", "benchmark", "fleet", "audit", "errors", "suggest", "advisor"} {
		for _, action := range []string{"status", "run", "config"} {
			code, _ := dispatch(controlCall{Family: f, Action: action, Body: []byte(`{}`)})
			if code < 400 {
				t.Fatalf("removed operation %s/%s still responds: %d", f, action, code)
			}
		}
	}
}

func TestNativeHealthRetainsDirectNavaLinkSupport(t *testing.T) {
	healthFixture(t)
	p := filepath.Join(configDir, "navalink", "012345abcdef")
	os.MkdirAll(p, 0700)
	os.WriteFile(filepath.Join(p, "config.json"), []byte(`{"id":"012345abcdef","role":"iran","mode":"direct","ports":[443]}`), 0600)
	active := false
	localCommand = func(name string, args ...string) ([]byte, error) {
		if name == "systemctl" && !active {
			return nil, errors.New("stopped")
		}
		return nil, nil
	}
	state, _, _ := nativeTunnelStatus()
	if state != "DOWN" {
		t.Fatal(state)
	}
	active = true
	state, _, _ = nativeTunnelStatus()
	if state != "UP" {
		t.Fatal(state)
	}
}
