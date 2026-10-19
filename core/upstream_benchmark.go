// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type CarrierMetric struct {
	ID            string  `json:"id"`
	Name          string  `json:"name"`
	Type          string  `json:"type"`
	Port          int     `json:"port"`
	AvgRTTMs      float64 `json:"avg_rtt_ms"`
	MinRTTMs      float64 `json:"min_rtt_ms"`
	MaxRTTMs      float64 `json:"max_rtt_ms"`
	PacketLoss    float64 `json:"packet_loss"`
	JitterMs      float64 `json:"jitter_ms"`
	Score         int     `json:"score"`
	Status        string  `json:"status"`
	IsActive      bool    `json:"is_active"`
	IsRecommended bool    `json:"is_recommended"`
	ErrorDetail   string  `json:"error_detail,omitempty"`
}

type BenchmarkReport struct {
	Timestamp       string          `json:"timestamp"`
	DurationSec     float64         `json:"duration_sec"`
	TargetHost      string          `json:"target_host,omitempty"`
	TargetRole      string          `json:"target_role,omitempty"`
	PeerURL         string          `json:"peer_url"`
	PeerInternalIP  string          `json:"peer_internal_ip"`
	ActiveCarrier   string          `json:"active_carrier"`
	BestCarrier     string          `json:"best_carrier"`
	BestCarrierName string          `json:"best_carrier_name,omitempty"`
	AutoPilot       AutoPilotStatus `json:"auto_pilot"`
	Metrics         []CarrierMetric `json:"metrics"`
}

type AutoPilotStatus struct {
	Enabled       bool    `json:"enabled"`
	ThresholdLoss float64 `json:"threshold_loss"`
	LastTriggered string  `json:"last_triggered"`
	TriggerCount  int     `json:"trigger_count"`
}

type BenchmarkRunRequest struct {
	TargetHost   string `json:"target_host,omitempty"`
	TargetRole   string `json:"target_role,omitempty"`
	FrpPort      int    `json:"frp_port,omitempty"`
	WssPort      int    `json:"wss_port,omitempty"`
	SshPort      int    `json:"ssh_port,omitempty"`
	BackhaulPort int    `json:"backhaul_port,omitempty"`
}

type BenchmarkApplyRequest struct {
	Carrier string `json:"carrier"`
}

type BenchmarkAutoPilotRequest struct {
	Enabled   *bool    `json:"enabled,omitempty"`
	Threshold *float64 `json:"threshold,omitempty"`
}

var (
	benchmarkMu           sync.RWMutex
	benchmarkRunning      atomic.Bool
	lastBenchmarkReport   *BenchmarkReport
	autoPilotTriggerCount int
	lastAutoPilotSwitch   string
)

func benchmarkReportFile() string {
	return filepath.Join(configDir, "benchmark_report.json")
}

func loadSavedBenchmarkReport() *BenchmarkReport {
	benchmarkMu.RLock()
	if lastBenchmarkReport != nil {
		defer benchmarkMu.RUnlock()
		return lastBenchmarkReport
	}
	benchmarkMu.RUnlock()

	data, err := os.ReadFile(benchmarkReportFile())
	if err == nil {
		var r BenchmarkReport
		if json.Unmarshal(data, &r) == nil {
			benchmarkMu.Lock()
			lastBenchmarkReport = &r
			benchmarkMu.Unlock()
			return &r
		}
	}
	return nil
}

func saveBenchmarkReport(r *BenchmarkReport) {
	benchmarkMu.Lock()
	lastBenchmarkReport = r
	benchmarkMu.Unlock()

	_ = os.MkdirAll(configDir, 0700)
	data, err := json.Marshal(r)
	if err == nil {
		tmpPath := benchmarkReportFile() + ".tmp"
		if err := os.WriteFile(tmpPath, data, 0600); err == nil {
			_ = os.Rename(tmpPath, benchmarkReportFile())
		}
	}
}

func calculateScore(loss, rtt, jitter float64) int {
	if loss >= 100.0 {
		return 0
	}

	effectiveRTT := rtt
	if effectiveRTT > 300 {
		effectiveRTT = 300
	}
	effectiveJitter := jitter
	if effectiveJitter > 100 {
		effectiveJitter = 100
	}

	raw := 100.0 - (loss * 1.5) - (effectiveRTT * 0.15) - (effectiveJitter * 0.2)
	if raw < 1 {
		raw = 1
	}
	if raw > 100 {
		raw = 100
	}
	return int(math.Round(raw))
}

const benchUnmeasured = "unmeasured"

func determineStatus(score int, loss float64) string {
	if loss >= 100.0 || score == 0 {
		return "down"
	}
	if score >= 80 {
		return "healthy"
	}
	if score >= 60 {
		return "good"
	}
	if score >= 35 {
		return "warning"
	}
	return "critical"
}

func probeTCP(ctx context.Context, addr string, count int, timeout time.Duration) (avgRTT, minRTT, maxRTT, loss, jitter float64, err error) {
	if count <= 0 {
		count = 3
	}
	var rtts []float64
	var failed int

	dialer := &net.Dialer{Timeout: timeout}

	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			failed += (count - i)
			break
		}
		start := time.Now()
		conn, dialErr := dialer.DialContext(ctx, "tcp", addr)
		if dialErr != nil {
			failed++
			continue
		}
		rtt := float64(time.Since(start).Microseconds()) / 1000.0
		_ = conn.Close()
		rtts = append(rtts, rtt)
	}

	loss = (float64(failed) / float64(count)) * 100.0
	if len(rtts) == 0 {
		return 0, 0, 0, 100.0, 0, fmt.Errorf("all %d probes failed to %s", count, addr)
	}

	minRTT = rtts[0]
	maxRTT = rtts[0]
	total := 0.0
	for _, r := range rtts {
		if r < minRTT {
			minRTT = r
		}
		if r > maxRTT {
			maxRTT = r
		}
		total += r
	}
	avgRTT = total / float64(len(rtts))

	if len(rtts) > 1 {
		var diffSum float64
		for i := 1; i < len(rtts); i++ {
			diffSum += math.Abs(rtts[i] - rtts[i-1])
		}
		jitter = diffSum / float64(len(rtts)-1)
	}

	return avgRTT, minRTT, maxRTT, loss, jitter, nil
}

func probeTLS(ctx context.Context, addr string, count int, timeout time.Duration) (avgRTT, minRTT, maxRTT, loss, jitter float64, err error) {
	if count <= 0 {
		count = 3
	}
	var rtts []float64
	var failed int

	dialer := &net.Dialer{Timeout: timeout}

	conf := &tls.Config{InsecureSkipVerify: true}

	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			failed += (count - i)
			break
		}
		start := time.Now()
		rawConn, dialErr := dialer.DialContext(ctx, "tcp", addr)
		if dialErr != nil {
			failed++
			continue
		}
		tlsConn := tls.Client(rawConn, conf)
		_ = tlsConn.SetDeadline(time.Now().Add(timeout))
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			_ = rawConn.Close()
			failed++
			continue
		}
		rtt := float64(time.Since(start).Microseconds()) / 1000.0
		_ = tlsConn.Close()
		rtts = append(rtts, rtt)
	}

	loss = (float64(failed) / float64(count)) * 100.0
	if len(rtts) == 0 {
		return 0, 0, 0, 100.0, 0, fmt.Errorf("all %d TLS probes failed to %s", count, addr)
	}

	minRTT = rtts[0]
	maxRTT = rtts[0]
	total := 0.0
	for _, r := range rtts {
		if r < minRTT {
			minRTT = r
		}
		if r > maxRTT {
			maxRTT = r
		}
		total += r
	}
	avgRTT = total / float64(len(rtts))

	if len(rtts) > 1 {
		var diffSum float64
		for i := 1; i < len(rtts); i++ {
			diffSum += math.Abs(rtts[i] - rtts[i-1])
		}
		jitter = diffSum / float64(len(rtts)-1)
	}

	return avgRTT, minRTT, maxRTT, loss, jitter, nil
}

func probePing(ctx context.Context, host string, count int) (avgRTT, minRTT, maxRTT, loss, jitter float64, err error) {
	if host == "" {
		return 0, 0, 0, 100.0, 0, fmt.Errorf("empty host")
	}

	cmd := exec.CommandContext(ctx, "ping", "-c", strconv.Itoa(count), "-W", "2", host)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return 0, 0, 0, 100.0, 0, fmt.Errorf("ping failed: %v", err)
	}

	str := string(out)

	if idx := strings.Index(str, "% packet loss"); idx != -1 {
		part := str[:idx]
		if lastSpace := strings.LastIndex(part, " "); lastSpace != -1 {
			lossVal, _ := strconv.ParseFloat(strings.TrimSpace(part[lastSpace:]), 64)
			loss = lossVal
		}
	}

	if idx := strings.Index(str, "rtt min/avg/max/mdev = "); idx != -1 {
		sub := str[idx+23:]
		if end := strings.Index(sub, " "); end != -1 {
			parts := strings.Split(sub[:end], "/")
			if len(parts) >= 4 {
				minRTT, _ = strconv.ParseFloat(parts[0], 64)
				avgRTT, _ = strconv.ParseFloat(parts[1], 64)
				maxRTT, _ = strconv.ParseFloat(parts[2], 64)
				jitter, _ = strconv.ParseFloat(parts[3], 64)
			}
		}
	} else if strings.Contains(str, "time=") {

		avgRTT = 15.0
		minRTT = 15.0
		maxRTT = 15.0
	}

	return avgRTT, minRTT, maxRTT, loss, jitter, nil
}

func runCarrierBenchmark(customReq ...BenchmarkRunRequest) *BenchmarkReport {
	if !benchmarkRunning.CompareAndSwap(false, true) {
		benchmarkMu.RLock()
		rep := lastBenchmarkReport
		benchmarkMu.RUnlock()
		return rep
	}
	defer benchmarkRunning.Store(false)

	startTime := time.Now()
	peerCfg := loadPeerConfig()
	carrierCfg := loadCarrierConfig()
	localSt := localStatus()

	activeCarrier := carrierCfg.ActiveCarrier
	if activeCarrier == "" {
		activeCarrier = "direct"
	}

	remotePub := localSt.Gre.PeerIP
	if remotePub == "" {
		for _, p := range loadPeers() {
			if p.RemotePub != "" {
				remotePub = p.RemotePub
				break
			}
		}
	}
	if remotePub == "" && peerCfg.PeerURL != "" {

		clean := strings.TrimPrefix(peerCfg.PeerURL, "http://")
		clean = strings.TrimPrefix(clean, "https://")
		if host, _, err := net.SplitHostPort(clean); err == nil {
			remotePub = host
		} else {
			remotePub = clean
		}
	}

	targetRole := localSt.Role
	if targetRole == "" {
		targetRole = "iran"
	}

	controlPort := localSt.FrpPort
	if controlPort <= 0 {
		controlPort = localSt.BindPort
	}
	if controlPort <= 0 {
		controlPort = 7000
	}

	wssPort := carrierCfg.WSSPort
	if wssPort <= 0 {
		wssPort = 8443
	}

	sshPort := 22
	backhaulPort := 3080

	if len(customReq) > 0 {
		req := customReq[0]
		if req.TargetRole != "" {
			targetRole = req.TargetRole
		}
		if req.TargetHost != "" {
			clean := strings.TrimSpace(req.TargetHost)
			clean = strings.TrimPrefix(clean, "http://")
			clean = strings.TrimPrefix(clean, "https://")
			if host, _, err := net.SplitHostPort(clean); err == nil {
				clean = host
			}
			if idx := strings.Index(clean, "/"); idx != -1 {
				clean = clean[:idx]
			}
			if clean != "" {
				remotePub = clean
			}
		}
		if req.FrpPort > 0 {
			controlPort = req.FrpPort
		}
		if req.WssPort > 0 {
			wssPort = req.WssPort
		}
		if req.SshPort > 0 {
			sshPort = req.SshPort
		}
		if req.BackhaulPort > 0 {
			backhaulPort = req.BackhaulPort
		}
	}

	if remotePub == "" {
		remotePub = "127.0.0.1"
	}

	grePeer := ""
	if localSt.Gre.Inner != "" {
		grePeer = grePeerInner(localSt.Gre.Inner)
	}
	if grePeer == "" {
		grePeer = peerCfg.InternalIP
	}
	if grePeer == "" {
		grePeer = "10.10.10.1"
	}

	quicPort := controlPort + 1
	if quicPort > 65535 {
		quicPort = controlPort - 1
	}

	candidates := []CarrierMetric{
		{
			ID:       "direct",
			Name:     "GRE Direct (Protocol 47)",
			Type:     "gre",
			Port:     0,
			IsActive: activeCarrier == "direct",
		},
		{
			ID:       "frp:tcp",
			Name:     fmt.Sprintf("FRP TCP Multiplexed (Port %d)", controlPort),
			Type:     "frp_tcp",
			Port:     controlPort,
			IsActive: strings.Contains(activeCarrier, "tcp") || activeCarrier == "frp",
		},
		{
			ID:       "frp:kcp",
			Name:     fmt.Sprintf("FRP KCP (UDP ARQ Anti-Loss %d)", controlPort),
			Type:     "frp_kcp",
			Port:     controlPort,
			IsActive: strings.Contains(activeCarrier, "kcp"),
		},
		{
			ID:       "frp:quic",
			Name:     fmt.Sprintf("FRP QUIC (UDP Stream %d)", quicPort),
			Type:     "frp_quic",
			Port:     quicPort,
			IsActive: strings.Contains(activeCarrier, "quic"),
		},
		{
			ID:       fmt.Sprintf("wss:%d", wssPort),
			Name:     fmt.Sprintf("FRP / Obfuscated WSS (TLS %d)", wssPort),
			Type:     "wss",
			Port:     wssPort,
			IsActive: strings.HasPrefix(activeCarrier, "wss"),
		},
		{
			ID:       fmt.Sprintf("backhaul:%d", backhaulPort),
			Name:     fmt.Sprintf("Backhaul Transport (Port %d)", backhaulPort),
			Type:     "backhaul",
			Port:     backhaulPort,
			IsActive: strings.Contains(activeCarrier, "backhaul"),
		},
		{
			ID:       fmt.Sprintf("navalink:%d", sshPort),
			Name:     fmt.Sprintf("NavaLink Pro (SSH Tunnel %d)", sshPort),
			Type:     "navalink",
			Port:     sshPort,
			IsActive: strings.Contains(activeCarrier, "navalink") || strings.Contains(activeCarrier, "ssh"),
		},
	}

	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)

	for i := range candidates {
		wg.Add(1)
		sem <- struct{}{}
		go func(c *CarrierMetric) {
			defer wg.Done()
			defer func() { <-sem }()

			cctx, ccancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer ccancel()

			probeCount := 3
			timeout := 1500 * time.Millisecond

			switch c.Type {
			case "gre":

				avg, min, max, loss, jit, err := probePing(cctx, grePeer, probeCount)
				if err != nil {

					avg, min, max, loss, jit, err = probePing(cctx, remotePub, probeCount)
				}
				c.AvgRTTMs = math.Round(avg*10) / 10
				c.MinRTTMs = math.Round(min*10) / 10
				c.MaxRTTMs = math.Round(max*10) / 10
				c.PacketLoss = math.Round(loss*10) / 10
				c.JitterMs = math.Round(jit*10) / 10
				if err != nil {
					c.ErrorDetail = err.Error()
				}

			case "wss":
				targetHost := remotePub
				addr := net.JoinHostPort(targetHost, strconv.Itoa(c.Port))
				avg, min, max, loss, jit, err := probeTLS(cctx, addr, probeCount, timeout)
				if err != nil {
					avg, min, max, loss, jit, err = probeTCP(cctx, addr, probeCount, timeout)
				}
				c.AvgRTTMs = math.Round(avg*10) / 10
				c.MinRTTMs = math.Round(min*10) / 10
				c.MaxRTTMs = math.Round(max*10) / 10
				c.PacketLoss = math.Round(loss*10) / 10
				c.JitterMs = math.Round(jit*10) / 10
				if err != nil {
					c.ErrorDetail = err.Error()
				}

			case "frp_kcp", "frp_quic":

				c.Status = benchUnmeasured
				c.ErrorDetail = "not measurable without a KCP/QUIC handshake; switch to it only if TCP carriers are blocked"
				return

			case "frp_tcp", "frp_ws", "backhaul", "frp", "navalink":
				targetHost := remotePub
				addr := net.JoinHostPort(targetHost, strconv.Itoa(c.Port))
				avg, min, max, loss, jit, err := probeTCP(cctx, addr, probeCount, timeout)
				c.AvgRTTMs = math.Round(avg*10) / 10
				c.MinRTTMs = math.Round(min*10) / 10
				c.MaxRTTMs = math.Round(max*10) / 10
				c.PacketLoss = math.Round(loss*10) / 10
				c.JitterMs = math.Round(jit*10) / 10
				if err != nil {
					c.ErrorDetail = err.Error()
				}
			}

			c.Score = calculateScore(c.PacketLoss, c.AvgRTTMs, c.JitterMs)
			c.Status = determineStatus(c.Score, c.PacketLoss)
		}(&candidates[i])
	}
	wg.Wait()

	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].Score > candidates[j].Score
	})

	bestCarrier := ""
	bestCarrierName := ""
	for i := range candidates {
		if candidates[i].Status == benchUnmeasured {
			continue
		}
		id := candidates[i].ID
		if id == "direct" || strings.HasPrefix(id, "wss:") || strings.HasPrefix(id, "frp:") || strings.HasPrefix(id, "backhaul:") || strings.HasPrefix(id, "navalink:") {
			if bestCarrier == "" && candidates[i].Score >= 10 {
				bestCarrier = id
				bestCarrierName = candidates[i].Name
				candidates[i].IsRecommended = true
				break
			}
		}
	}
	if bestCarrier == "" {
		for i := range candidates {
			if candidates[i].Status != benchUnmeasured {
				bestCarrier = candidates[i].ID
				bestCarrierName = candidates[i].Name
				candidates[i].IsRecommended = true
				break
			}
		}
	}

	duration := float64(time.Since(startTime).Milliseconds()) / 1000.0

	report := &BenchmarkReport{
		Timestamp:       time.Now().Format("2006-01-02 15:04:05"),
		DurationSec:     duration,
		TargetHost:      remotePub,
		TargetRole:      targetRole,
		PeerURL:         peerCfg.PeerURL,
		PeerInternalIP:  grePeer,
		ActiveCarrier:   activeCarrier,
		BestCarrier:     bestCarrier,
		BestCarrierName: bestCarrierName,
		AutoPilot: AutoPilotStatus{
			Enabled:       peerCfg.AutoPilotEnabled,
			ThresholdLoss: peerCfg.AutoPilotThreshold,
			LastTriggered: lastAutoPilotSwitch,
			TriggerCount:  autoPilotTriggerCount,
		},
		Metrics: candidates,
	}

	saveBenchmarkReport(report)

	if peerCfg.AutoPilotEnabled && peerCfg.Role == "master" && bestCarrier != "" && bestCarrier != activeCarrier {

		var activeLoss float64 = 100.0
		for _, m := range candidates {
			if m.IsActive {
				activeLoss = m.PacketLoss
				break
			}
		}

		if activeLoss >= peerCfg.AutoPilotThreshold {
			log.Printf("[AutoPilot] Active carrier %s has %.1f%% loss (threshold: %.1f%%). Best candidate: %s (automatic switching is disabled — carrier remains manual)",
				activeCarrier, activeLoss, peerCfg.AutoPilotThreshold, bestCarrier)
		}
	}

	return report
}

func applyBenchmarkCarrier(target string) (string, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return "", fmt.Errorf("empty carrier target")
	}

	if err := carrierApplicable(target); err != nil {
		return "", err
	}
	prev := loadCarrierConfig().ActiveCarrier

	out, err := applyCarrierMode(target)
	if err != nil && !strings.Contains(err.Error(), "script not found") {
		return "", fmt.Errorf("failed applying carrier %s locally: %v (%s)", target, err, out)
	}

	detail := "Synchronized and applied carrier: " + target
	if pc := loadPeerConfig(); pc.Role == "master" && pc.PeerSecret != "" && (pc.IsConnected || pc.LastSync != "") {
		if err := syncCarrierToPeer(target); err != nil {
			if prev != "" && prev != target {
				_, _ = applyCarrierMode(prev)
			}
			return "", fmt.Errorf("peer could not apply %s (%v); this server was switched back to %s", target, err, prev)
		}
	} else {
		detail = "Applied carrier " + target + " on this server only (no Peer Link): apply the same carrier on the other server"
	}

	benchmarkMu.Lock()
	if lastBenchmarkReport != nil {
		lastBenchmarkReport.ActiveCarrier = target
		for i := range lastBenchmarkReport.Metrics {
			lastBenchmarkReport.Metrics[i].IsActive = lastBenchmarkReport.Metrics[i].ID == target
		}
	}
	benchmarkMu.Unlock()

	LogSecurityAudit("carrier_switched", "admin", "127.0.0.1", "target="+target)
	return detail, nil
}

func handleBenchmarkGet(w http.ResponseWriter, r *http.Request) {
	rep := loadSavedBenchmarkReport()
	if rep == nil {
		rep = runCarrierBenchmark()
	}
	writeJSON(w, rep)
}

func handleBenchmarkRun(w http.ResponseWriter, r *http.Request) {
	var req BenchmarkRunRequest
	if r.Body != nil && r.ContentLength > 0 {
		_ = json.NewDecoder(r.Body).Decode(&req)
	}
	rep := runCarrierBenchmark(req)
	writeJSON(w, rep)
}

func handleBenchmarkApply(w http.ResponseWriter, r *http.Request) {
	var req BenchmarkApplyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, r, "E-ACTION-01", "invalid json")
		return
	}

	carrier := strings.TrimSpace(req.Carrier)
	if carrier == "" {
		writeAPIError(w, r, "E-ACTION-01", "carrier required")
		return
	}

	detail, err := applyBenchmarkCarrier(carrier)
	if err != nil {
		writeAPIError(w, r, "E-CARRIER-01", err.Error())
		return
	}

	writeJSON(w, map[string]any{
		"status":         "ok",
		"active_carrier": carrier,
		"detail":         detail,
	})
}

func handleBenchmarkAutoPilot(w http.ResponseWriter, r *http.Request) {
	var req BenchmarkAutoPilotRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, r, "E-ACTION-01", "invalid json")
		return
	}

	c := loadPeerConfig()
	if req.Enabled != nil {
		c.AutoPilotEnabled = *req.Enabled
		c.AutoPilotExplicit = true
	}
	if req.Threshold != nil && *req.Threshold > 0 {
		c.AutoPilotThreshold = *req.Threshold
	}

	if err := savePeerConfig(c); err != nil {
		writeAPIError(w, r, "E-ACTION-02", "failed to save autopilot settings")
		return
	}

	writeJSON(w, map[string]any{
		"status":              "ok",
		"autopilot_enabled":   c.AutoPilotEnabled,
		"autopilot_threshold": c.AutoPilotThreshold,
	})
}

func startAutoPilotMonitor() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		pcfg := loadPeerConfig()
		if pcfg.AutoPilotEnabled && pcfg.Role == "master" {
			if !benchmarkRunning.Load() {
				_ = runCarrierBenchmark()
			}
		}
	}
}
