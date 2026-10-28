package magicsock

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/tailscale/wireguard-go/conn"
	"tailscale.com/types/key"
)

// Exercise the patched endpoint.send path, not just the TLS helper.
func TestMerlinTLSEndpointSendAndFailClosed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tr := &merlinTLS{peer: key.NewNode().Public(), ctx: ctx, tx: make(chan []byte, 1)}
	tr.connected.Store(true)
	c := &Conn{}
	c.merlinTLS.Store(tr)
	ep := &endpoint{c: c, publicKey: tr.peer, heartbeatDisabled: true}
	if err := ep.send([][]byte{[]byte("skip-payload")}, 5); err != nil { t.Fatal(err) }
	if got := <-tr.tx; string(got) != "payload" { t.Fatalf("queued %q", got) }
	tr.connected.Store(false)
	if err := ep.send([][]byte{[]byte("payload")}, 0); err == nil { t.Fatal("disconnected peer did not fail closed") }
	tr.connected.Store(true)
	ep.expired = true
	if err := ep.send([][]byte{[]byte("payload")}, 0); err != errExpired { t.Fatalf("expired peer: %v", err) }
	if len(tr.tx) != 0 { t.Fatal("expired peer transmitted") }
}

func TestMerlinTLSReceiveUnblocksOnClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	tr := &merlinTLS{ctx: ctx, rx: make(chan []byte)}
	c := &Conn{}
	recv := c.merlinTLSReceive(tr)
	done := make(chan error, 1)
	go func() { _, err := recv(make([]byte, 1500), make([]conn.ReceivedPacket, 1)); done <- err }()
	cancel()
	select {
	case err := <-done: if err != net.ErrClosed { t.Fatalf("receive error: %v", err) }
	case <-time.After(time.Second): t.Fatal("receive did not unblock")
	}
}

func merlinTestCert(t *testing.T, name string) (string, string) {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil { t.Fatal(err) }
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName:name},
		NotBefore:time.Now().Add(-time.Hour), NotAfter:time.Now().Add(time.Hour),
		KeyUsage:x509.KeyUsageDigitalSignature, ExtKeyUsage:[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth,x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader,tpl,tpl,&private.PublicKey,private)
	if err != nil { t.Fatal(err) }
	pk, err := x509.MarshalECPrivateKey(private)
	if err != nil { t.Fatal(err) }
	dir := t.TempDir()
	certPath, keyPath := filepath.Join(dir,"cert.pem"), filepath.Join(dir,"key.pem")
	if err := os.WriteFile(certPath,pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:der}),0600); err != nil { t.Fatal(err) }
	if err := os.WriteFile(keyPath,pem.EncodeToMemory(&pem.Block{Type:"EC PRIVATE KEY",Bytes:pk}),0600); err != nil { t.Fatal(err) }
	return certPath,keyPath
}

func merlinTestConfigs(t *testing.T) (merlinTLSConfig,merlinTLSConfig) {
	t.Helper()
	sc,sk := merlinTestCert(t,"server")
	cc,ck := merlinTestCert(t,"client")
	serverKey,_ := key.NewNode().Public().MarshalText()
	clientKey,_ := key.NewNode().Public().MarshalText()
	return merlinTLSConfig{Mode:"server",Listen:"127.0.0.1:0",CertFile:sc,KeyFile:sk,PeerCert:cc,PeerKey:string(clientKey)},
		merlinTLSConfig{Mode:"client",SNI:"speedtest.com",CertFile:cc,KeyFile:ck,PeerCert:sc,PeerKey:string(serverKey)}
}

func merlinWaitConnected(t *testing.T, a,b *merlinTLS) {
	t.Helper()
	deadline := time.Now().Add(8*time.Second)
	for time.Now().Before(deadline) {
		if a.connected.Load() && b.connected.Load() { return }
		time.Sleep(10*time.Millisecond)
	}
	t.Fatal("TLS peers did not connect")
}

func merlinExpect(t *testing.T, tr *merlinTLS, want []byte) {
	t.Helper()
	select {
	case got := <-tr.rx:
		if !bytes.Equal(got,want) { t.Fatalf("packet mismatch got %d bytes want %d",len(got),len(want)) }
	case <-time.After(5*time.Second): t.Fatal("receive timeout")
	}
}

func TestMerlinTLSRoundTripAndSNI(t *testing.T) {
	scfg,ccfg := merlinTestConfigs(t)
	s,err := newMerlinTLS(scfg,t.Logf)
	if err != nil { t.Fatal(err) }
	defer s.Close()
	ccfg.Connect=s.listener.Addr().String()
	c,err:=newMerlinTLS(ccfg,t.Logf)
	if err!=nil { t.Fatal(err) }
	defer c.Close()
	merlinWaitConnected(t,s,c)
	if got := s.lastSNI.Load(); got != "speedtest.com" { t.Fatalf("on-wire SNI=%v", got) }
	for _,n:=range []int{1,148,1280,1500,65535} {
		want:=bytes.Repeat([]byte{byte(n)},n)
		withOffset:=append([]byte("prefix"),want...)
		if err:=c.send([][]byte{withOffset},6);err!=nil { t.Fatal(err) }
		merlinExpect(t,s,want)
		if err:=s.send([][]byte{want},0);err!=nil { t.Fatal(err) }
		merlinExpect(t,c,want)
	}
	if c.rxPackets.Load()!=5 || s.rxPackets.Load()!=5 { t.Fatal("unexpected packet count") }
}

func TestMerlinTLSWrongPinRejected(t *testing.T) {
	for _,side:=range []string{"client","server"} { t.Run(side,func(t *testing.T) {
		scfg,ccfg:=merlinTestConfigs(t)
		wrong,_:=merlinTestCert(t,"wrong")
		if side=="client" { ccfg.PeerCert=wrong } else { scfg.PeerCert=wrong }
		s,err:=newMerlinTLS(scfg,t.Logf);if err!=nil { t.Fatal(err) };defer s.Close()
		ccfg.Connect=s.listener.Addr().String()
		c,err:=newMerlinTLS(ccfg,t.Logf);if err!=nil { t.Fatal(err) };defer c.Close()
		// A TLS 1.3 client may briefly finish its side before receiving a server
		// rejection. No rejected peer may deliver a payload to the server.
		deadline:=time.After(2500*time.Millisecond)
		tick:=time.NewTicker(10*time.Millisecond);defer tick.Stop()
		for { select {
		case <-tick.C: _=c.send([][]byte{[]byte("must not arrive")},0)
		case <-s.rx: t.Fatal("unauthenticated payload accepted")
		case <-deadline: if s.connected.Load() { t.Fatal("wrong pin connected") };return
		} }
	}) }
}

func TestMerlinTLSReconnectAndClose(t *testing.T) {
	scfg,ccfg:=merlinTestConfigs(t)
	s,err:=newMerlinTLS(scfg,t.Logf);if err!=nil {t.Fatal(err)};defer s.Close()
	ccfg.Connect=s.listener.Addr().String()
	c,err:=newMerlinTLS(ccfg,t.Logf);if err!=nil {t.Fatal(err)};defer c.Close()
	merlinWaitConnected(t,s,c)
	s.mu.Lock();s.raw.Close();s.mu.Unlock()
	// Allow old connection to exit before requiring a new generation.
	time.Sleep(200*time.Millisecond)
	merlinWaitConnected(t,s,c)
	want:=[]byte("after reconnect")
	if err:=c.send([][]byte{want},0);err!=nil {t.Fatal(err)}
	merlinExpect(t,s,want)
	done:=make(chan struct{})
	go func(){c.Close();c.Close();s.Close();close(done)}()
	select {case <-done:case <-time.After(2*time.Second):t.Fatal("Close blocked")}
	if err:=c.send([][]byte{want},0);err==nil {t.Fatal("closed transport accepted send")}
}

func TestMerlinTLSFraming(t *testing.T) {
	var buf bytes.Buffer
	for _,p:=range [][]byte{nil,[]byte("a"),bytes.Repeat([]byte{7},65535)} {
		if err:=merlinTLSWriteFrame(&buf,p);err!=nil {t.Fatal(err)}
		got,err:=merlinTLSReadFrame(&buf);if err!=nil||!bytes.Equal(got,p) {t.Fatalf("roundtrip: %v",err)}
	}
	if err:=merlinTLSWriteFrame(&buf,make([]byte,65536));err==nil {t.Fatal("oversize accepted")}
	if _,err:=merlinTLSReadFrame(bytes.NewReader([]byte{0,2,1}));err!=io.ErrUnexpectedEOF {t.Fatalf("truncated payload: %v",err)}
}

func TestMerlinTLSConfigValidation(t *testing.T) {
	scfg,ccfg:=merlinTestConfigs(t)
	ccfg.Connect="100.64.0.1:443"
	if _,err:=newMerlinTLS(ccfg,t.Logf);err==nil {t.Fatal("tailnet loop address accepted")}
	scfg.PeerKey="tskey-auth-not-a-node-key"
	if _,err:=newMerlinTLS(scfg,t.Logf);err==nil {t.Fatal("auth key accepted as peer")}
	path:=filepath.Join(t.TempDir(),"bad.json")
	os.WriteFile(path,[]byte(`{"mode":"server","unknown":true}`),0600)
	if _,err:=readMerlinTLSConfig(path);err==nil {t.Fatal("unknown config field accepted")}
}
