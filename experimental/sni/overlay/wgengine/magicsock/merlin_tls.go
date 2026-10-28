// Copyright (c) 2026. Experimental Merlin direct TLS transport.
// SPDX-License-Identifier: BSD-3-Clause

package magicsock

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tailscale/wireguard-go/conn"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/tstime/mono"
)

// This transport is intentionally limited to one explicitly configured peer.
// It does not modify the control plane, routes, ACLs or the WireGuard cipher.
// The other end must run the same patch. It is not DERP or an HTTPS proxy.
const merlinTLSProtocol = "merlin-wg/1"
const merlinTLSMaxPacket = 65535

type merlinTLSConfig struct {
	Mode     string `json:"mode"` // "client" or "server"
	PeerKey  string `json:"peer_key"` // remote nodekey:..., NOT an auth key
	Listen   string `json:"listen,omitempty"`
	Connect  string `json:"connect,omitempty"` // real WAN address, never a tailnet IP
	SNI      string `json:"sni,omitempty"`
	CertFile string `json:"cert_file"`
	KeyFile  string `json:"key_file"`
	PeerCert string `json:"peer_cert"` // trusted remote leaf certificate PEM
}

type merlinTLS struct {
	cfg merlinTLSConfig
	peer key.NodePublic
	tlsConfig *tls.Config
	logf logger.Logf
	ctx context.Context
	cancel context.CancelFunc
	listener net.Listener
	mu sync.Mutex // protects raw (including handshakes)
	raw net.Conn
	wg sync.WaitGroup
	closeOnce sync.Once
	connected atomic.Bool
	lastSNI atomic.Value // last successfully authenticated handshake's SNI string
	tx chan []byte
	rx chan []byte
	txBytes atomic.Uint64
	rxBytes atomic.Uint64
	txPackets atomic.Uint64
	rxPackets atomic.Uint64
}

func readMerlinTLSConfig(path string) (merlinTLSConfig, error) {
	var cfg merlinTLSConfig
	f, err := os.Open(path)
	if err != nil { return cfg, err }
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 16384))
	d.DisallowUnknownFields()
	if err := d.Decode(&cfg); err != nil { return cfg, err }
	var extra any
	if err := d.Decode(&extra); err != io.EOF { return cfg, errors.New("trailing JSON or oversized TLS config") }
	base := filepath.Dir(path)
	for _, p := range []*string{&cfg.CertFile, &cfg.KeyFile, &cfg.PeerCert} {
		if *p == "" { return cfg, errors.New("cert_file, key_file and peer_cert are required") }
		if !filepath.IsAbs(*p) { *p = filepath.Join(base, *p) }
	}
	return cfg, nil
}

func newMerlinTLS(cfg merlinTLSConfig, logf logger.Logf) (*merlinTLS, error) {
	var peer key.NodePublic
	if err := peer.UnmarshalText([]byte(cfg.PeerKey)); err != nil || peer.IsZero() {
		return nil, errors.New("peer_key must be the other router's nonzero nodekey:... public key")
	}
	var addr string
	switch cfg.Mode {
	case "client":
		if cfg.Listen != "" || cfg.SNI == "" { return nil, errors.New("client requires sni and must not set listen") }
		if net.ParseIP(cfg.SNI) != nil || strings.ContainsAny(cfg.SNI, ":/ \t\r\n") {
			return nil, errors.New("sni must be a DNS name, without a scheme or port")
		}
		addr = cfg.Connect
	case "server":
		if cfg.Connect != "" || cfg.SNI != "" { return nil, errors.New("server must not set connect or sni") }
		addr = cfg.Listen
	default:
		return nil, errors.New("TLS mode must be client or server")
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil || host == "" || port == "" { return nil, errors.New("TLS address must be explicit host:port") }
	if cfg.Mode == "client" {
		if ip := net.ParseIP(host); ip != nil && ip.To4() != nil && ip.To4()[0] == 100 && ip.To4()[1] >= 64 && ip.To4()[1] <= 127 {
			return nil, errors.New("connect must use the real WAN address, not a Tailscale address")
		}
	}
	cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	if err != nil { return nil, fmt.Errorf("local TLS identity: %w", err) }
	peerPEM, err := os.ReadFile(cfg.PeerCert)
	if err != nil { return nil, err }
	block, rest := pem.Decode(peerPEM)
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, errors.New("peer_cert must contain exactly one PEM leaf certificate")
	}
	peerCert, err := x509.ParseCertificate(block.Bytes)
	if err != nil { return nil, err }
	pin := sha256.Sum256(peerCert.Raw)
	verify := func(cs tls.ConnectionState) error {
		if cs.NegotiatedProtocol != merlinTLSProtocol { return errors.New("wrong TLS transport protocol") }
		if len(cs.PeerCertificates) == 0 { return errors.New("missing peer certificate") }
		leaf := cs.PeerCertificates[0]
		got := sha256.Sum256(leaf.Raw)
		if subtle.ConstantTimeCompare(got[:], pin[:]) != 1 { return errors.New("peer certificate pin mismatch") }
		now := time.Now()
		if now.Before(leaf.NotBefore) || now.After(leaf.NotAfter) { return errors.New("peer certificate is not currently valid") }
		return nil
	}
	tc := &tls.Config{
		MinVersion: tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		NextProtos: []string{merlinTLSProtocol},
		VerifyConnection: verify,
		SessionTicketsDisabled: true,
	}
	if cfg.Mode == "client" {
		tc.ServerName = cfg.SNI
		// SNI is independent of identity. Replace public PKI/hostname checking
		// with mandatory exact leaf-certificate pinning above (NOT unauthenticated TLS).
		tc.InsecureSkipVerify = true
	} else {
		tc.ClientAuth = tls.RequireAnyClientCert // mandatory pin check in VerifyConnection
	}
	ctx, cancel := context.WithCancel(context.Background())
	t := &merlinTLS{cfg: cfg, peer: peer, tlsConfig: tc, logf: logf, ctx: ctx, cancel: cancel,
		tx: make(chan []byte, 32), rx: make(chan []byte, 32)}
	if cfg.Mode == "server" {
		t.listener, err = net.Listen("tcp", cfg.Listen)
		if err != nil { cancel(); return nil, err }
	}
	t.wg.Add(1)
	go t.run()
	return t, nil
}

func (t *merlinTLS) Close() {
	t.closeOnce.Do(func() {
		t.cancel()
		if t.listener != nil { t.listener.Close() }
		t.mu.Lock()
		if t.raw != nil { t.raw.Close() }
		t.mu.Unlock()
	})
	t.wg.Wait()
}

func (t *merlinTLS) run() {
	defer t.wg.Done()
	for t.ctx.Err() == nil {
		var raw net.Conn
		var err error
		if t.cfg.Mode == "server" {
			raw, err = t.listener.Accept()
		} else {
			dialer := net.Dialer{Timeout: 10*time.Second, KeepAlive: 20*time.Second}
			raw, err = dialer.DialContext(t.ctx, "tcp", t.cfg.Connect)
		}
		if err == nil {
			t.mu.Lock()
			if t.ctx.Err() != nil { raw.Close(); t.mu.Unlock(); return }
			t.raw = raw
			t.mu.Unlock()
			err = t.session(raw)
			raw.Close()
			t.mu.Lock()
			t.raw = nil
			t.mu.Unlock()
		}
		if t.ctx.Err() != nil { return }
		t.logf("merlin-tls: connection ended: %v; tx=%d packets/%d bytes rx=%d packets/%d bytes", err,
			t.txPackets.Load(), t.txBytes.Load(), t.rxPackets.Load(), t.rxBytes.Load())
		timer := time.NewTimer(2*time.Second)
		select { case <-timer.C: case <-t.ctx.Done(): timer.Stop(); return }
	}
}

func (t *merlinTLS) session(raw net.Conn) error {
	var tc *tls.Conn
	if t.cfg.Mode == "client" { tc = tls.Client(raw, t.tlsConfig) } else { tc = tls.Server(raw, t.tlsConfig) }
	ctx, cancel := context.WithTimeout(t.ctx, 10*time.Second)
	err := tc.HandshakeContext(ctx)
	cancel()
	if err != nil { return err }
	t.lastSNI.Store(tc.ConnectionState().ServerName)
	t.connected.Store(true)
	t.logf("merlin-tls: connected peer=%s remote=%s sni=%q (direct TLS, no DERP)", t.peer.ShortString(), raw.RemoteAddr(), tc.ConnectionState().ServerName)
	done := make(chan struct{})
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		ticker := time.NewTicker(15*time.Second)
		defer ticker.Stop()
		for {
			var packet []byte
			select {
			case <-done: return
			case <-t.ctx.Done(): return
			case packet = <-t.tx:
			case <-ticker.C: // zero-length heartbeat; never passed to WireGuard
			}
			if err := tc.SetWriteDeadline(time.Now().Add(15*time.Second)); err != nil { raw.Close(); return }
			if err := merlinTLSWriteFrame(tc, packet); err != nil { raw.Close(); return }
			if len(packet) != 0 { t.txPackets.Add(1); t.txBytes.Add(uint64(len(packet))) }
		}
	}()
	defer func() {
		t.connected.Store(false)
		close(done)
		raw.Close() // unblock writer before waiting
		<-writerDone
	}()
	for {
		if err := tc.SetReadDeadline(time.Now().Add(60*time.Second)); err != nil { return err }
		packet, err := merlinTLSReadFrame(tc)
		if err != nil { return err }
		if len(packet) == 0 { continue }
		t.rxPackets.Add(1)
		t.rxBytes.Add(uint64(len(packet)))
		select { case t.rx <- packet: case <-t.ctx.Done(): return t.ctx.Err() }
	}
}

func merlinTLSWriteFrame(w io.Writer, packet []byte) error {
	if len(packet) > merlinTLSMaxPacket { return errors.New("TLS WireGuard packet too large") }
	buf := make([]byte, 2+len(packet))
	binary.BigEndian.PutUint16(buf, uint16(len(packet)))
	copy(buf[2:], packet)
	for len(buf) != 0 {
		n, err := w.Write(buf)
		if err != nil { return err }
		if n == 0 { return io.ErrShortWrite }
		buf = buf[n:]
	}
	return nil
}

func merlinTLSReadFrame(r io.Reader) ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil { return nil, err }
	packet := make([]byte, int(binary.BigEndian.Uint16(header[:])))
	_, err := io.ReadFull(r, packet)
	return packet, err
}

func (t *merlinTLS) send(buffs [][]byte, offset int) error {
	if t.ctx.Err() != nil { return net.ErrClosed }
	if !t.connected.Load() { return errors.New("merlin-tls: not connected; UDP/DERP fallback disabled for configured peer") }
	for _, b := range buffs {
		if offset < 0 || offset >= len(b) || len(b)-offset > merlinTLSMaxPacket {
			return errors.New("invalid TLS WireGuard packet size/offset")
		}
		packet := append([]byte(nil), b[offset:]...)
		select {
		case <-t.ctx.Done(): return net.ErrClosed
		case t.tx <- packet:
		default: return errors.New("merlin-tls: send queue full")
		}
	}
	return nil
}

func (c *Conn) merlinTLSReceive(t *merlinTLS) conn.ReceiveFunc {
	return func(slab []byte, packets []conn.ReceivedPacket) (int, error) {
		for {
			var b []byte
			select {
			case <-t.ctx.Done(): return 0, net.ErrClosed
			case b = <-t.rx:
			}
			if len(b) > len(slab) || len(packets) == 0 { continue }
			c.mu.Lock()
			ep, ok := c.peerMap.endpointForNodeKey(t.peer)
			c.mu.Unlock()
			if !ok { continue } // removed/unknown peer: never inject
			ep.mu.Lock()
			expired := ep.expired
			ep.mu.Unlock()
			if expired { continue }
			copy(slab, b)
			ep.lastRecvWG.StoreAtomic(mono.Now())
			packets[0].Offset = 0
			packets[0].Size = len(b)
			packets[0].Endpoint = ep
			return 1, nil // WireGuard still authenticates/decrypts; ACL filtering remains downstream
		}
	}
}

// Called under connBind.mu, once per bind generation. Return errors rather than
// accidentally running normal UDP when an enabled TLS config is invalid.
func (c *Conn) openMerlinTLS() (*merlinTLS, error) {
	path := os.Getenv("TS_MERLIN_TLS_CONFIG")
	if path == "" { return nil, nil }
	cfg, err := readMerlinTLSConfig(path)
	if err != nil { return nil, fmt.Errorf("merlin-tls config: %w", err) }
	t, err := newMerlinTLS(cfg, c.logf)
	if err != nil { return nil, fmt.Errorf("merlin-tls startup: %w", err) }
	c.merlinTLS.Store(t)
	c.logf("merlin-tls: experimental direct TLS enabled mode=%s peer=%s; normal mode for other peers", cfg.Mode, t.peer.ShortString())
	return t, nil
}
