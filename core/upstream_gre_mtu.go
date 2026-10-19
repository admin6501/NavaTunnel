// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	pathMTUMin    = 1200
	greMTUDefault = 1380
	greMSSDefault = 1340
)

func pathMTUFile() string { return filepath.Join(configDir, "gre_mtu") }

func savedPathMTU() int {
	b, err := os.ReadFile(pathMTUFile())
	if err != nil {
		return 0
	}
	v, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || v < pathMTUMin || v >= greMTUDefault {
		return 0
	}
	return v
}

func savePathMTU(v int) error {
	if v < pathMTUMin || v >= greMTUDefault {
		return os.Remove(pathMTUFile())
	}
	return os.WriteFile(pathMTUFile(), []byte(strconv.Itoa(v)+"\n"), 0644)
}

var pathMTURun = func(name string, args ...string) ([]byte, error) {
	return runCmdTimeoutOut(5*time.Second, name, args...)
}

func greInterfaces() []string {
	ents, err := os.ReadDir(sysClassNet)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "gre-t") {
			out = append(out, e.Name())
		}
	}
	return out
}

func mssRewrite(rules string, mss int) (del, add [][]string) {
	have := map[string]bool{}
	post := false
	lines := strings.Split(rules, "\n")
	for _, l := range lines {
		have[strings.TrimSpace(l)] = true
	}
	want := strconv.Itoa(mss)
	for _, l := range lines {
		f := strings.Fields(l)
		if len(f) < 2 || f[0] != "-A" || !strings.Contains(l, "TCPMSS") {
			continue
		}
		if f[1] == "POSTROUTING" {
			post = true
		}
		for i, w := range f {
			if w != "--set-mss" || i+1 >= len(f) {
				continue
			}
			if n, err := strconv.Atoi(f[i+1]); err != nil || n <= mss || (f[1] != "POSTROUTING" && f[1] != "FORWARD") {
				break
			}
			d := append([]string{"-t", "mangle", "-D"}, f[1:]...)
			del = append(del, d)
			nf := append([]string{}, f...)
			nf[i+1] = want
			if line := strings.Join(nf, " "); !have[line] {
				have[line] = true
				add = append(add, append([]string{"-t", "mangle"}, nf...))
			}
			break
		}
	}
	if !post {
		add = append(add, []string{"-t", "mangle", "-A", "POSTROUTING", "-p", "tcp",
			"--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", want})
	}
	return del, add
}

func enforcePathMTU() []string {
	if runtime.GOOS == "windows" {
		return nil
	}
	var done []string
	mtu, mss := savedPathMTU(), greMSSDefault
	if mtu > 0 {
		mss = mtu - 40
		for _, name := range greInterfaces() {
			if cur := interfaceMTU(name); cur > mtu {
				if _, err := pathMTURun("ip", "link", "set", "dev", name, "mtu", strconv.Itoa(mtu)); err == nil {
					done = append(done, "Set "+name+" MTU "+strconv.Itoa(cur)+" -> "+strconv.Itoa(mtu))
				}
			}
		}
	}
	out, err := pathMTURun("iptables", "-t", "mangle", "-S")
	if err != nil {
		return done
	}
	del, add := mssRewrite(string(out), mss)
	for _, a := range add {
		_, _ = pathMTURun("iptables", a...)
	}
	for _, d := range del {
		_, _ = pathMTURun("iptables", d...)
	}
	if len(del)+len(add) > 0 {
		done = append(done, "TCP MSS clamp set to "+strconv.Itoa(mss))
	}
	return done
}

func lastMeasuredMTU() mtuSummary {
	lastDoctorMu.RLock()
	defer lastDoctorMu.RUnlock()
	if lastDoctorReport == nil {
		return mtuSummary{}
	}
	return lastDoctorReport.MTUResult
}

func pathMTUFixes() []string {
	var fixes []string
	if m := lastMeasuredMTU(); m.Tested && m.MaxPacket > 0 && m.MaxPacket < m.Interface {
		if err := savePathMTU(m.Optimal); err == nil {
			fixes = append(fixes, "GRE MTU "+strconv.Itoa(m.Optimal)+" saved: it is kept after restarts")
		}
	}
	return append(fixes, enforcePathMTU()...)
}

func pathMTUKeeper() {
	if runtime.GOOS == "windows" {
		return
	}
	time.Sleep(20 * time.Second)
	for {
		if savedPathMTU() > 0 {
			for _, line := range enforcePathMTU() {
				log.Printf("[path-mtu] %s", line)
			}
		}
		time.Sleep(time.Minute)
	}
}
