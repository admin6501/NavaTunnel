// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"net"
)

func isV4(s string) bool {
	ip := net.ParseIP(s)
	return ip != nil && ip.To4() != nil
}
