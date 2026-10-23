package main

import (
	"fmt"
	"os"
)

const coreVersion = "v1.2.0"

func command(args []string) int {
	if len(args) == 1 && args[0] == "version" {
		fmt.Println(coreVersion)
		return 0
	}
	if len(args) > 0 && args[0] == "tls-proxy" {
		return tlsProxyCmd(args[1:])
	}
	fmt.Fprintln(os.Stderr, "Usage: NavaTunnel-core version | tls-proxy -listen ADDR -target ADDR")
	return 2
}
func main() { os.Exit(command(os.Args[1:])) }
