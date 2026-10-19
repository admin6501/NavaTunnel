package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Remove only this core's tagged jumps and chains. Never flush shared tables.
func purgeClusterRules() error {
	c := loadClusterConfig()
	c.Enabled = false
	if e := saveClusterConfig(c); e != nil {
		return e
	}
	clusterApplyMu.Lock()
	defer clusterApplyMu.Unlock()
	for _, table := range []string{"nat", "filter"} {
		out, e := clusterExec("iptables", "-w", "5", "-t", table, "-S")
		if e != nil {
			return fmt.Errorf("read owned firewall rules: %w: %s", e, out)
		}
		for _, line := range strings.Split(string(out), "\n") {
			if !strings.HasPrefix(line, "-A ") || !strings.Contains(line, "navatunnel-core-cluster") {
				continue
			}
			args := strings.Fields(strings.Replace(line, "-A ", "-D ", 1))
			for i := range args {
				args[i] = strings.Trim(args[i], `"`)
			}
			if out, e := clusterExec("iptables", append([]string{"-w", "5", "-t", table}, args...)...); e != nil {
				return fmt.Errorf("remove owned jump: %w: %s", e, out)
			}
		}
		for _, chain := range []string{"NAVA-CLUSTER-PREROUTING", "NAVA-CLUSTER-POSTROUTING", "NAVA-CLUSTER-FORWARD"} {
			if _, e := clusterExec("iptables", "-w", "5", "-t", table, "-S", chain); e != nil {
				continue
			}
			if out, e := clusterExec("iptables", "-w", "5", "-t", table, "-F", chain); e != nil {
				return fmt.Errorf("flush owned chain: %w: %s", e, out)
			}
			if out, e := clusterExec("iptables", "-w", "5", "-t", table, "-X", chain); e != nil {
				return fmt.Errorf("remove owned chain: %w: %s", e, out)
			}
		}
	}
	installedClusterBody = ""
	return nil
}

func rescuePrerequisites() error {
	for _, bin := range []string{"nft", "systemctl", "ip"} {
		if _, e := exec.LookPath(bin); e != nil {
			return fmt.Errorf("Rescue requires %s; install the dependency first", bin)
		}
	}
	for _, bin := range []string{"/usr/local/bin/frps", "/usr/local/bin/frpc"} {
		if fi, e := os.Stat(bin); e != nil || fi.Mode()&0111 == 0 {
			return fmt.Errorf("Rescue requires verified FRP binaries; run NavaTunnel download-cores")
		}
	}
	return nil
}
