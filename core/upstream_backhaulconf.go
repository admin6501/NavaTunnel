// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"strings"
)

type backhaulConf struct {
	Transport  string
	RemoteAddr string
	BindAddr   string
	Token      string
	Ports      []string
}

func stripTomlComment(s string) string {
	var q byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case q != 0:
			if c == '\\' && q == '"' {
				i++
			} else if c == q {
				q = 0
			}
		case c == '"' || c == '\'':
			q = c
		case c == '#':
			return s[:i]
		}
	}
	return s
}

func tomlUnquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	return s
}

func splitTomlArray(inner string) []string {
	var out []string
	var q byte
	start := 0
	flush := func(end int) {
		if v := tomlUnquote(inner[start:end]); v != "" {
			out = append(out, v)
		}
	}
	for i := 0; i < len(inner); i++ {
		c := inner[i]
		switch {
		case q != 0:
			if c == q {
				q = 0
			}
		case c == '"' || c == '\'':
			q = c
		case c == ',':
			flush(i)
			start = i + 1
		}
	}
	flush(len(inner))
	return out
}

func parseBackhaulConf(data string) backhaulConf {
	var c backhaulConf
	section := ""
	lines := strings.Split(data, "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(stripTomlComment(lines[i]))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") && !strings.Contains(line, "=") {
			section = strings.ToLower(strings.Trim(line, "[] \t"))
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		val := strings.TrimSpace(line[eq+1:])

		var arr []string
		isArr := strings.HasPrefix(val, "[")
		if isArr {
			for !strings.Contains(val, "]") && i+1 < len(lines) {
				i++
				val += " " + strings.TrimSpace(stripTomlComment(lines[i]))
			}
			end := strings.LastIndex(val, "]")
			if end < 0 {
				end = len(val)
			}
			arr = splitTomlArray(val[1:end])
		}

		switch key {
		case "transport":
			if !isArr && section != "transport" {
				c.Transport = tomlUnquote(val)
			}
		case "type":
			if section == "transport" {
				c.Transport = tomlUnquote(val)
			}
		case "remote_addr":
			c.RemoteAddr = tomlUnquote(val)
		case "bind_addr":
			c.BindAddr = tomlUnquote(val)
		case "token":
			c.Token = tomlUnquote(val)
		case "ports", "mapping":
			if isArr {
				c.Ports = append(c.Ports, arr...)
			}
		}
	}
	return c
}
