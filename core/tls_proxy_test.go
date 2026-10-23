package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"testing"
	"time"
)

func TestTLSProxyCarriesBothDirectionsAndDrainsAfterHalfClose(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	payload := bytes.Repeat([]byte("NavaTunnel-data-"), 8192)
	backendErr := make(chan error, 1)
	go func() {
		c, e := backend.Accept()
		if e != nil {
			backendErr <- e
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		data, e := io.ReadAll(c)
		if e == nil {
			_, e = c.Write(append([]byte("reply:"), data...))
		}
		backendErr <- e
	}()
	cert, err := generateSelfSignedCert("localhost")
	if err != nil {
		t.Fatal(err)
	}
	front, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { serveTLSProxy(front, backend.Addr().String()); close(done) }()
	defer func() { front.Close(); <-done }()
	parsed, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(parsed)
	client, err := tls.Dial("tcp", front.Addr().String(), &tls.Config{RootCAs: roots, ServerName: "localhost", MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = client.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err = client.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(client)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, append([]byte("reply:"), payload...)) {
		t.Fatalf("response truncated: %d bytes", len(got))
	}
	if err = <-backendErr; err != nil {
		t.Fatal(err)
	}
}

func TestCertificateSupportsDNSAndIP(t *testing.T) {
	for _, name := range []string{"localhost", "127.0.0.1"} {
		cert, err := generateSelfSignedCert(name)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := x509.ParseCertificate(cert.Certificate[0])
		if err != nil {
			t.Fatal(err)
		}
		if err = parsed.VerifyHostname(name); err != nil {
			t.Fatal(err)
		}
		if time.Until(parsed.NotAfter) < 360*24*time.Hour {
			t.Fatal("certificate expires too soon")
		}
	}
}

func TestRemovedCommandsAreUnavailable(t *testing.T) {
	for _, family := range []string{"cluster", "navalink", "serve", "daemon", "certificate", "metrics", "peer", "doctor"} {
		if command([]string{family}) == 0 {
			t.Fatalf("removed command accepted: %s", family)
		}
	}
}

func TestTLSCommandRejectsMissingAddresses(t *testing.T) {
	for _, args := range [][]string{nil, {"-listen", "127.0.0.1:0"}, {"-target", "127.0.0.1:7000"}, {"--bogus"}} {
		if tlsProxyCmd(args) == 0 {
			t.Fatalf("invalid TLS arguments accepted: %v", args)
		}
	}
}
