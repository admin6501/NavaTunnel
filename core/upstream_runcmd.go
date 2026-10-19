// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"context"
	"errors"
	"log"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"
)

type cmdRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

type stdoutOnlyKey struct{}

var runner cmdRunner = execRunner

func execRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if ctx.Value(stdoutOnlyKey{}) != nil {
		return cmd.Output()
	}
	return cmd.CombinedOutput()
}

type execStat struct {
	calls    uint64
	total    time.Duration
	max      time.Duration
	timeouts uint64
	errors   uint64
	buckets  [60]struct {
		sec int64
		n   uint64
	}
}

var (
	execMu    sync.Mutex
	execStats = map[string]*execStat{}
)

func recordExec(name string, d time.Duration, err error, timedOut bool) {
	now := time.Now().Unix()
	execMu.Lock()
	defer execMu.Unlock()
	s := execStats[name]
	if s == nil {
		s = &execStat{}
		execStats[name] = s
	}
	s.calls++
	s.total += d
	if d > s.max {
		s.max = d
	}
	if timedOut {
		s.timeouts++
	}
	if err != nil {
		s.errors++
	}
	b := &s.buckets[now%60]
	if b.sec != now {
		b.sec, b.n = now, 0
	}
	b.n++
}

func runCmdTimeoutCtx(ctx context.Context, timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	start := time.Now()
	out, err := runner(ctx, name, args...)
	timedOut := errors.Is(ctx.Err(), context.DeadlineExceeded)
	recordExec(name, time.Since(start), err, timedOut)
	if err != nil && !timedOut {
		var exitCode = -1
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		}
		trimmed := strings.TrimSpace(string(out))
		if len(trimmed) > 120 {
			trimmed = trimmed[:120] + "..."
		}
		if trimmed != "" {
			log.Printf("[CMD-ERROR] command %q failed (exit %d): %v | output: %s", name, exitCode, err, trimmed)
		} else {
			log.Printf("[CMD-ERROR] command %q failed (exit %d): %v", name, exitCode, err)
		}
	}
	return out, err
}

func runCmdTimeout(timeout time.Duration, name string, args ...string) ([]byte, error) {
	return runCmdTimeoutCtx(context.Background(), timeout, name, args...)
}

func runCmdTimeoutOut(timeout time.Duration, name string, args ...string) ([]byte, error) {
	return runCmdTimeoutCtx(context.WithValue(context.Background(), stdoutOnlyKey{}, true), timeout, name, args...)
}

type execStatJSON struct {
	Command      string  `json:"command"`
	Calls        uint64  `json:"calls"`
	AvgMs        float64 `json:"avg_ms"`
	MaxMs        float64 `json:"max_ms"`
	Timeouts     uint64  `json:"timeouts"`
	Errors       uint64  `json:"errors"`
	CallsLast60s uint64  `json:"calls_last_60s"`
}

func execSnapshot() []execStatJSON {
	now := time.Now().Unix()
	execMu.Lock()
	defer execMu.Unlock()
	res := make([]execStatJSON, 0, len(execStats))
	for name, s := range execStats {
		e := execStatJSON{Command: name, Calls: s.calls, MaxMs: ms(s.max), Timeouts: s.timeouts, Errors: s.errors}
		if s.calls > 0 {
			e.AvgMs = ms(s.total) / float64(s.calls)
		}
		for _, b := range s.buckets {
			if now-b.sec < 60 && b.sec <= now {
				e.CallsLast60s += b.n
			}
		}
		res = append(res, e)
	}
	sort.Slice(res, func(i, j int) bool { return res[i].Command < res[j].Command })
	return res
}

func resetExecStats() {
	execMu.Lock()
	execStats = map[string]*execStat{}
	execMu.Unlock()
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
