package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
)

var clusterApplyMu sync.Mutex
var clusterExec = func(name string, args ...string) ([]byte, error) { return exec.Command(name, args...).CombinedOutput() }
var clusterRestore = func(body string) error {
	cmd := exec.Command("iptables-restore", "--noflush", "-w", "5")
	cmd.Stdin = strings.NewReader(body)
	out, e := cmd.CombinedOutput()
	if e != nil {
		return fmt.Errorf("cluster firewall transaction failed: %w: %s", e, strings.TrimSpace(string(out)))
	}
	return nil
}
var installedClusterBody string

const clusterMark = "0x4e570000/0xffff0000"

func clusterBody(cfg *ClusterConfig, rules []string) string {
	var b bytes.Buffer
	b.WriteString("*nat\n:NAVA-CLUSTER-PREROUTING - [0:0]\n:NAVA-CLUSTER-POSTROUTING - [0:0]\n")
	if len(rules) > 0 {
		for _, port := range cfg.ServicePorts {
			for _, proto := range []string{"tcp", "udp"} {
				b.WriteString(fmt.Sprintf("-A NAVA-CLUSTER-PREROUTING -p %s --dport %d -j CONNMARK --set-xmark %s\n", proto, port, clusterMark))
			}
		}
	}
	for _, line := range rules {
		line = strings.TrimPrefix(line, "iptables -t nat ")
		b.WriteString(line + "\n")
	}
	b.WriteString("COMMIT\n*filter\n:NAVA-CLUSTER-FORWARD - [0:0]\n-A NAVA-CLUSTER-FORWARD -m connmark --mark " + clusterMark + " -m conntrack --ctstate DNAT -j ACCEPT\nCOMMIT\n")
	return b.String()
}
func clusterEnsureJumps() error {
	for _, r := range []struct {
		table, base, chain string
		extra              []string
	}{{"nat", "PREROUTING", "NAVA-CLUSTER-PREROUTING", []string{"-m", "addrtype", "--dst-type", "LOCAL"}}, {"nat", "POSTROUTING", "NAVA-CLUSTER-POSTROUTING", []string{"-m", "connmark", "--mark", clusterMark, "-m", "conntrack", "--ctstate", "DNAT"}}, {"filter", "FORWARD", "NAVA-CLUSTER-FORWARD", nil}} {
		rule := append(append([]string{}, r.extra...), "-m", "comment", "--comment", "navatunnel-core-cluster", "-j", r.chain)
		args := append([]string{"-w", "5", "-t", r.table, "-C", r.base}, rule...)
		if _, e := clusterExec("iptables", args...); e != nil {
			args = append([]string{"-w", "5", "-t", r.table, "-I", r.base, "1"}, rule...)
			if out, e := clusterExec("iptables", args...); e != nil {
				return fmt.Errorf("cluster jump installation failed: %w: %s", e, out)
			}
		}
	}
	return nil
}
func applyClusterRules(cfg *ClusterConfig, rules []string) error {
	clusterApplyMu.Lock()
	defer clusterApplyMu.Unlock()
	if len(rules) > 0 && !loadClusterConfig().Enabled {
		return fmt.Errorf("cluster was disabled before routing could be applied")
	}
	body := clusterBody(cfg, rules)
	previous := installedClusterBody
	if e := clusterRestore(body); e != nil {
		if previous != "" {
			_ = clusterRestore(previous)
		} else {
			_ = clusterRestore(clusterBody(cfg, nil))
		}
		return e
	}
	if e := clusterEnsureJumps(); e != nil {
		if previous != "" {
			_ = clusterRestore(previous)
		} else {
			_ = clusterRestore(clusterBody(cfg, nil))
		}
		return e
	}
	if len(rules) > 0 {
		if out, e := clusterExec("sysctl", "-w", "net.ipv4.ip_forward=1"); e != nil {
			if previous != "" {
				_ = clusterRestore(previous)
			} else {
				_ = clusterRestore(clusterBody(cfg, nil))
			}
			return fmt.Errorf("enable forwarding: %w: %s", e, out)
		}
	}
	installedClusterBody = body
	return nil
}
func clearClusterFailover(cfg *ClusterConfig) error {
	if e := applyClusterRules(cfg, nil); e != nil {
		return e
	}
	cfg.ActiveFailover = ""
	cfg.FailoverTarget = ""
	return nil
}
func applyClusterFailover(cfg *ClusterConfig, target ClusterNode) error {
	if target.PublicIP == "" || target.IsFailing || !target.IsHealthy {
		return fmt.Errorf("target Iran node is not healthy")
	}
	var rules []string
	for _, p := range cfg.ServicePorts {
		for _, proto := range []string{"tcp", "udp"} {
			ps := strconv.Itoa(p)
			rules = append(rules, "iptables -t nat -A NAVA-CLUSTER-PREROUTING -p "+proto+" --dport "+ps+" -j DNAT --to-destination "+target.PublicIP+":"+ps, "iptables -t nat -A NAVA-CLUSTER-POSTROUTING -d "+target.PublicIP+" -p "+proto+" --dport "+ps+" -j MASQUERADE")
		}
	}
	if e := applyClusterRules(cfg, rules); e != nil {
		return e
	}
	cfg.ActiveFailover = target.ID
	cfg.FailoverTarget = target.PublicIP
	return nil
}
func foreignSelection(cfg ClusterConfig) ClusterConfig {
	out := cloneClusterConfig(cfg)
	if cfg.BalancingMode == "wrr" {
		return out
	}
	var healthy []ForeignNode
	for _, n := range cfg.ForeignNodes {
		if n.IsHealthy {
			healthy = append(healthy, n)
		}
	}
	sort.Slice(healthy, func(i, j int) bool {
		if cfg.BalancingMode == "lowest_latency" && healthy[i].LatencyMs != healthy[j].LatencyMs {
			return healthy[i].LatencyMs < healthy[j].LatencyMs
		}
		return healthy[i].ID < healthy[j].ID
	})
	out.ForeignNodes = map[string]ForeignNode{}
	if len(healthy) == 0 {
		return out
	}
	pick := healthy[0]
	if cfg.BalancingMode == "failover" {
		if n, ok := cfg.ForeignNodes[cfg.ActiveForeign]; ok && n.IsHealthy {
			pick = n
		}
	}
	out.ForeignNodes[pick.ID] = pick
	out.ActiveForeign = pick.ID
	return out
}
func applyClusterLoadBalancing(cfg *ClusterConfig) error {
	selection := foreignSelection(*cfg)
	rules := generateClusterBalancingRules(&selection)
	if e := applyClusterRules(cfg, rules); e != nil {
		return e
	}
	if cfg.BalancingMode != "wrr" {
		cfg.ActiveForeign = selection.ActiveForeign
		updateClusterRuntime(func(c *ClusterConfig) {
			c.ActiveForeign = selection.ActiveForeign
			for id, n := range c.ForeignNodes {
				n.IsActive = id == selection.ActiveForeign
				c.ForeignNodes[id] = n
			}
		})
	}
	return nil
}
