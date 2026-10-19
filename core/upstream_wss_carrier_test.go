// SPDX-License-Identifier: AGPL-3.0-only
// Adapted upstream regression tests; see THIRD_PARTY_NOTICES.md.
package main

import (
	"net/http/httptest"
	"os"
	"testing"
)

func TestWSSConfigDefaultsAndLoadSave(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "navatunnel_wss_test_*")
	if err != nil {
		t.Fatalf("MkdirTemp failed: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	oldConfigDir := configDir
	configDir = tmpDir
	defer func() { configDir = oldConfigDir }()

	cfg := defaultWSSConfig()
	if cfg.ListenPort != 8443 {
		t.Errorf("expected default listen port 8443, got %d", cfg.ListenPort)
	}
	if cfg.LocalBridgeUDP != 19998 {
		t.Errorf("expected default local bridge UDP 19998, got %d", cfg.LocalBridgeUDP)
	}

	cfg.ListenPort = 9443
	cfg.SNI = "cdn.example.com"
	if err := saveWSSConfig(cfg); err != nil {
		t.Fatalf("saveWSSConfig failed: %v", err)
	}

	loaded := loadWSSConfig()
	if loaded.ListenPort != 9443 {
		t.Errorf("expected loaded port 9443, got %d", loaded.ListenPort)
	}
	if loaded.SNI != "cdn.example.com" {
		t.Errorf("expected SNI 'cdn.example.com', got '%s'", loaded.SNI)
	}
}

func TestSelfSignedCertGeneration(t *testing.T) {
	cert, err := generateSelfSignedCert("speedtest.net")
	if err != nil {
		t.Fatalf("generateSelfSignedCert failed: %v", err)
	}
	if len(cert.Certificate) == 0 {
		t.Errorf("expected at least one certificate in chain")
	}
	if cert.PrivateKey == nil {
		t.Errorf("expected private key to be generated")
	}
}

func TestWSSCarrierStartStop(t *testing.T) {
	cfg := defaultWSSConfig()
	cfg.Enabled = true

	if err := startWSSCarrier(cfg); err != nil {
		t.Fatalf("startWSSCarrier failed: %v", err)
	}

	st := getWSSStatus()
	if !st.Running {
		t.Errorf("expected WSS carrier to be reported as running")
	}

	if err := stopWSSCarrier(); err != nil {
		t.Fatalf("stopWSSCarrier failed: %v", err)
	}

	st = getWSSStatus()
	if st.Running {
		t.Errorf("expected WSS carrier to be stopped")
	}
}

func TestWSSOriginPolicy(t *testing.T) {
	r := httptest.NewRequest("GET", "/tunnel-stream", nil)
	if !wssOriginAllowed(r) {
		t.Fatal("non-browser client (no Origin) must be allowed")
	}
	r.Header.Set("Origin", "https://evil.example")
	if wssOriginAllowed(r) {
		t.Fatal("cross-site browser Origin must be rejected")
	}
	if !wssTokenEqual("abc", "abc") || wssTokenEqual("abc", "abd") || wssTokenEqual("", "abc") {
		t.Fatal("token compare wrong")
	}
}

// Changing the WSS port keeps the carrier names on the new port, and an empty
// SNI clears the old one.
