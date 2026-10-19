package main

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func peerCertificate() (tls.Certificate, error) {
	if e := os.MkdirAll(configDir, 0700); e != nil {
		return tls.Certificate{}, e
	}
	lock, e := os.OpenFile(filepath.Join(configDir, "peer-api.cert.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return tls.Certificate{}, e
	}
	defer lock.Close()
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); e != nil {
		return tls.Certificate{}, e
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	certFile := filepath.Join(configDir, "peer-api.crt")
	keyFile := filepath.Join(configDir, "peer-api.key")
	if c, e := tls.LoadX509KeyPair(certFile, keyFile); e == nil {
		return c, nil
	}
	c, e := generateSelfSignedCert("navatunnel.local")
	if e != nil {
		return c, e
	}
	key, e := x509.MarshalPKCS8PrivateKey(c.PrivateKey)
	if e != nil {
		return c, e
	}
	if e = os.MkdirAll(configDir, 0700); e != nil {
		return c, e
	}
	if e = os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}), 0600); e != nil {
		return c, e
	}
	if e = os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Certificate[0]}), 0600); e != nil {
		return c, e
	}
	return c, nil
}
func peerFingerprint() (string, error) {
	c, e := peerCertificate()
	if e != nil {
		return "", e
	}
	h := sha256.Sum256(c.Certificate[0])
	return hex.EncodeToString(h[:]), nil
}
func clusterHTTPClient(apiURL string) *http.Client {
	cfg := loadClusterConfig()
	pin := ""
	for _, n := range cfg.Nodes {
		if n.APIURL == apiURL {
			pin = n.TLSFingerprint
			break
		}
	}
	if pin == "" {
		return clusterClient
	}
	return &http.Client{Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }, Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true, VerifyConnection: func(s tls.ConnectionState) error {
		if len(s.PeerCertificates) == 0 {
			return fmt.Errorf("peer has no certificate")
		}
		c := s.PeerCertificates[0]
		if time.Now().Before(c.NotBefore) || time.Now().After(c.NotAfter) {
			return fmt.Errorf("peer certificate is expired or not valid yet")
		}
		sum := sha256.Sum256(c.Raw)
		if !ConstantTimeCompare(hex.EncodeToString(sum[:]), strings.ToLower(strings.ReplaceAll(pin, ":", ""))) {
			return fmt.Errorf("peer certificate fingerprint mismatch")
		}
		return nil
	}}}}
}
