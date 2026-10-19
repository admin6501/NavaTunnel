// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pdnczone/hashem-panel fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7.
// See THIRD_PARTY_NOTICES.md for attribution and adaptation details.
package main

import (
	"crypto/x509"

	"encoding/pem"
	"fmt"

	"os"

	"path/filepath"

	"time"
)

func tlsDir() string      { return filepath.Join(configDir, "tls") }
func tlsCertFile() string { return filepath.Join(configDir, "peer-api.crt") }
func tlsKeyFile() string  { return filepath.Join(configDir, "peer-api.key") }

func tlsHasCert() bool {
	if _, err := os.Stat(tlsCertFile()); err != nil {
		return false
	}
	if _, err := os.Stat(tlsKeyFile()); err != nil {
		return false
	}
	return true
}

func tlsCertExpiry() (time.Time, string, error) {
	data, err := os.ReadFile(tlsCertFile())
	if err != nil {
		return time.Time{}, "", err
	}
	var blk *pem.Block
	for {
		blk, data = pem.Decode(data)
		if blk == nil {
			break
		}
		if blk.Type == "CERTIFICATE" {
			c, err := x509.ParseCertificate(blk.Bytes)
			if err != nil {
				continue
			}
			return c.NotAfter, c.Issuer.CommonName, nil
		}
	}
	return time.Time{}, "", fmt.Errorf("no certificate found")
}
