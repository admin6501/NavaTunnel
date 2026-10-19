// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"regexp"
)

var logSecretRes = []struct {
	re   *regexp.Regexp
	repl string
}{
	{regexp.MustCompile(`(?i)(security token received\s*:?\s*)\S+`), "${1}***"},
	{regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+`), "${1}***"},
	{regexp.MustCompile(`(?i)(\b(?:auth\.)?(?:token|password|passwd|secret)\b["']?\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;]+)`), "${1}***"},
	{regexp.MustCompile(`(?i)(--(?:token|password|passwd|secret)[ =])\S+`), "${1}***"},
}

func redactLogSecrets(s string) string {
	for _, r := range logSecretRes {
		s = r.re.ReplaceAllString(s, r.repl)
	}
	return s
}
