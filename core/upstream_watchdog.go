// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"bytes"
	"context"
	"encoding/json"

	"log"

	"os"
	"os/exec"
	"path/filepath"

	"strings"
	"time"
)

type watchdogConfig struct {
	Enabled           bool   `json:"enabled"`
	IntervalSec       int    `json:"interval_sec"`
	FailThreshold     int    `json:"fail_threshold"`
	AutoRestart       bool   `json:"auto_restart"`
	RestartEveryHours int    `json:"restart_every_hours"`
	LastRestart       int64  `json:"last_restart,omitempty"`
	LastRestartDate   string `json:"last_restart_date,omitempty"`
	TGBotToken        string `json:"tg_bot_token"`
	TGChatID          string `json:"tg_chat_id"`
	TGRoute           string `json:"tg_route"`
	TGTunnelPort      int    `json:"tg_tunnel_port"`
	BackupEveryHours  int    `json:"backup_every_hours"`
	BackupDailyAt     string `json:"backup_daily_at"`
	LastCheck         string `json:"last_check"`
	ConsecFails       int    `json:"consec_fails"`
	LastAlert         string `json:"last_alert"`
	DownSince         int64  `json:"down_since,omitempty"`
	LastBackup        int64  `json:"last_backup,omitempty"`
	LastBackupDate    string `json:"last_backup_date,omitempty"`
}

func watchdogConfigPath() string {
	return filepath.Join(configDir, "watchdog.json")
}

func loadWatchdogConfig() watchdogConfig {
	def := watchdogConfig{
		Enabled:       false,
		IntervalSec:   60,
		FailThreshold: 2,
		TGRoute:       "direct",
	}
	data, err := os.ReadFile(watchdogConfigPath())
	if err != nil {
		return def
	}
	var c watchdogConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return def
	}
	if c.IntervalSec <= 0 {
		c.IntervalSec = 60
	}
	if c.FailThreshold <= 0 {
		c.FailThreshold = 2
	}
	if c.TGRoute == "" {
		c.TGRoute = "direct"
	}
	return c
}

func ensureWatchdogTimer() {
	if out, err := runWatchdogCmd("watchdog", "timer"); err != nil {
		log.Printf("[watchdog] could not start the timer: %v %s", err, out)
	}
}

func runWatchdogCmd(args ...string) (string, error) {
	script, err := greScriptPath()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "GRE_SKIP_PANEL=1", "TERM=dumb", "GRE_PANEL_DIR="+configDir)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	runErr := cmd.Run()
	return strings.TrimSpace(buf.String()), runErr
}
