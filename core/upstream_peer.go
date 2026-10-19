// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type PeerConfig struct {
	Role               string  `json:"role"`
	PeerSecret         string  `json:"peer_secret"`
	PeerURL            string  `json:"peer_url"`
	InternalIP         string  `json:"internal_ip"`
	InternalPort       int     `json:"internal_port"`
	LastSync           string  `json:"last_sync"`
	IsConnected        bool    `json:"is_connected"`
	LatencyMs          float64 `json:"latency_ms"`
	AutoPilotEnabled   bool    `json:"autopilot_enabled"`
	AutoPilotExplicit  bool    `json:"autopilot_explicit,omitempty"`
	AutoPilotThreshold float64 `json:"autopilot_threshold"`
	TLSFingerprint     string  `json:"tls_fingerprint,omitempty"`

	PeerBasePath string `json:"peer_base_path,omitempty"`
}

const peerRoutePrefix = "/_hp"

type PeerApplyCarrierRequest struct {
	Carrier string `json:"carrier"`
}

var (
	peerMu sync.RWMutex
)

func peerConfigFile() string {
	return filepath.Join(configDir, "peer_link.json")
}

func defaultPeerConfig() PeerConfig {
	st := currentLocal()
	role := "master"
	if strings.ToLower(st.Role) == "kharej" || strings.ToLower(st.Role) == "foreign" {
		role = "worker"
	}

	secret := randomToken(32)

	internalIP := st.GrePeer
	if internalIP == "" {
		if role == "master" {
			internalIP = defaultForeignGRE
		} else {
			internalIP = defaultIranGRE
		}
	}

	return PeerConfig{
		Role:               role,
		PeerSecret:         secret,
		PeerURL:            "",
		InternalIP:         internalIP,
		InternalPort:       cfg.Port,
		LastSync:           "",
		IsConnected:        false,
		LatencyMs:          0,
		AutoPilotEnabled:   false,
		AutoPilotExplicit:  true,
		AutoPilotThreshold: 20.0,
	}
}

func loadPeerConfig() PeerConfig {
	peerMu.RLock()
	c, needsSave := readPeerConfig()
	peerMu.RUnlock()

	if needsSave {
		_ = savePeerConfig(c)
	}
	return c
}

func readPeerConfig() (PeerConfig, bool) {
	data, err := os.ReadFile(peerConfigFile())
	if err != nil {
		return defaultPeerConfig(), false
	}
	var c PeerConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return defaultPeerConfig(), false
	}

	def := defaultPeerConfig()
	if c.Role == "" {
		c.Role = def.Role
	}
	if c.PeerSecret == "" {
		c.PeerSecret = def.PeerSecret
	}
	if c.InternalPort <= 0 {
		c.InternalPort = cfg.Port
	}
	if c.AutoPilotThreshold <= 0 {
		c.AutoPilotThreshold = 20.0
	}

	needsSave := false

	if !c.AutoPilotExplicit {
		c.AutoPilotEnabled = false
		c.AutoPilotExplicit = true
		needsSave = true
	}
	return c, needsSave
}

func savePeerConfig(c PeerConfig) error {
	peerMu.Lock()
	defer peerMu.Unlock()
	return writePeerConfig(c)
}

func updatePeerConfig(fn func(c *PeerConfig)) error {
	peerMu.Lock()
	defer peerMu.Unlock()
	c, _ := readPeerConfig()
	fn(&c)
	return writePeerConfig(c)
}

func writePeerConfig(c PeerConfig) error {
	_ = os.MkdirAll(configDir, 0700)
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := peerConfigFile() + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, peerConfigFile())
}

func markPeerSeen() {
	_ = updatePeerConfig(func(c *PeerConfig) {
		c.IsConnected = true
		c.LastSync = time.Now().Format("2006-01-02 15:04:05")
	})
}

var peerPinMu sync.Mutex

func peerTLSConfig(c *PeerConfig) *tls.Config {
	return &tls.Config{
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return fmt.Errorf("peer presented no TLS certificate")
			}
			sum := sha256.Sum256(rawCerts[0])
			got := hex.EncodeToString(sum[:])

			peerPinMu.Lock()
			defer peerPinMu.Unlock()
			pinned := strings.ToLower(strings.TrimSpace(c.TLSFingerprint))
			if pinned == "" {
				c.TLSFingerprint = got
				if err := updatePeerConfig(func(p *PeerConfig) { p.TLSFingerprint = got }); err != nil {
					log.Printf("peer TLS pin: cannot persist fingerprint: %v", err)
				}
				return nil
			}
			if subtle.ConstantTimeCompare([]byte(pinned), []byte(got)) != 1 {
				return fmt.Errorf("peer TLS certificate fingerprint mismatch: pinned %s, got %s (possible MITM or peer cert changed; clear tls_fingerprint to re-pin)", pinned, got)
			}
			return nil
		},
	}
}

func sendToPeer(path string, method string, payload any) ([]byte, error) {
	return sendToPeerTimeout(path, method, payload, 4*time.Second)
}

func sendToPeerTimeout(path string, method string, payload any, timeout time.Duration) ([]byte, error) {
	c := loadPeerConfig()
	var bodyBytes []byte
	var err error
	if payload != nil {
		bodyBytes, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}

	targetURLs := peerTargetURLs(c, path)
	if len(targetURLs) == 0 {
		return nil, fmt.Errorf("no peer address configured (both InternalIP and PeerURL are empty)")
	}

	tr := &http.Transport{
		TLSClientConfig: peerTLSConfig(&c),
	}
	defer tr.CloseIdleConnections()
	client := &http.Client{
		Timeout:   timeout,
		Transport: tr,

		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	var lastErr error
	deadHosts := map[string]bool{}
	for _, target := range targetURLs {
		pu, _ := url.Parse(target)
		hostKey := ""
		if pu != nil {
			hostKey = pu.Scheme + "://" + pu.Host
		}
		if deadHosts[hostKey] {
			continue
		}
		req, err := http.NewRequest(method, target, bytes.NewReader(bodyBytes))
		if err != nil {
			lastErr = err
			continue
		}

		req.Header.Set("Content-Type", "application/json")
		if c.PeerSecret != "" {
			req.Header.Set("X-Peer-Secret", c.PeerSecret)
		}

		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			deadHosts[hostKey] = true
			continue
		}

		respBytes, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}

		if resp.StatusCode >= 200 && resp.StatusCode < 300 && json.Valid(respBytes) {
			markPeerSeen()
			return respBytes, nil
		}

		lastErr = fmt.Errorf("peer returned HTTP %d: %s", resp.StatusCode, truncateForError(respBytes))
	}

	_ = updatePeerConfig(func(p *PeerConfig) { p.IsConnected = false })
	return nil, lastErr
}

func truncateForError(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return s
}

func peerTargetURLs(c PeerConfig, path string) []string {
	cleanPath := "/" + strings.TrimLeft(path, "/")
	prefixes := []string{peerRoutePrefix}
	if bp := strings.Trim(c.PeerBasePath, "/"); bp != "" {
		prefixes = append(prefixes, "/"+bp)
	} else if bp := strings.Trim(cfg.BasePath, "/"); bp != "" {

		prefixes = append(prefixes, "/"+bp)
	}

	var bases []string
	if c.InternalIP != "" {
		ports := []int{}
		if c.InternalPort > 0 {
			ports = append(ports, c.InternalPort)
		}
		if cfg.Port > 0 && cfg.Port != c.InternalPort {
			ports = append(ports, cfg.Port)
		}
		for _, p := range ports {
			bases = append(bases, fmt.Sprintf("http://%s:%d", c.InternalIP, p))
		}
	}
	if c.PeerURL != "" {
		u := strings.TrimRight(c.PeerURL, "/")
		if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
			u = "http://" + u
		}
		if parsed, err := url.Parse(u); err == nil && parsed.Host != "" {
			host := parsed.Hostname()
			if parsed.Port() != "" {
				bases = append(bases, parsed.Scheme+"://"+parsed.Host)
			} else {
				seen := map[int]bool{}
				for _, p := range []int{c.InternalPort, cfg.Port, effectiveTLSPort(), 7443, 7777, 8080} {
					if p > 0 && !seen[p] {
						seen[p] = true
						bases = append(bases, fmt.Sprintf("%s://%s:%d", parsed.Scheme, host, p))
					}
				}
			}
		}
	}

	var out []string
	for _, b := range bases {
		for _, pre := range prefixes {
			out = append(out, b+pre+cleanPath)
		}
	}
	return out
}

func syncCarrierToPeer(carrier string) error {
	c := loadPeerConfig()
	if c.Role != "master" {
		return nil
	}

	log.Printf("[PeerSync] Commanding peer worker to apply carrier: %s", carrier)
	_, err := sendToPeer("/api/peer/apply-carrier", "POST", PeerApplyCarrierRequest{Carrier: carrier})
	return err
}
