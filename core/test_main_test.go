package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestMain(m *testing.M) {
	dir, e := os.MkdirTemp("", "nava-core-tests-")
	if e != nil {
		panic(e)
	}
	configDir = dir
	frpDir = filepath.Join(dir, "frp")
	_ = os.MkdirAll(frpDir, 0700)
	clusterExec = func(string, ...string) ([]byte, error) { return nil, nil }
	clusterRestore = func(string) error { return nil }
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}
func pickFreePort(start int) int {
	for n := start; n < 65535; n++ {
		l, e := net.ListenTCP("tcp", &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: n})
		if e == nil {
			l.Close()
			return n
		}
	}
	panic("no free test port")
}
