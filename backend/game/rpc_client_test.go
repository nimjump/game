package game

// Tests for the RPC transport: NAT64 address synthesis (no gateway needed) and
// a real end-to-end SOCKS5 tunnel test against a throwaway in-process proxy.

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"net/url"
	"testing"
	"time"
)

func TestNAT64Synthesize(t *testing.T) {
	cases := []struct {
		prefix string
		v4     string
		want   string
	}{
		{"64:ff9b::/96", "49.13.63.161", "64:ff9b::310d:3fa1"},
		{"64:ff9b::/96", "1.2.3.4", "64:ff9b::102:304"},
		{"2a00:1098:2b::/96", "8.8.8.8", "2a00:1098:2b::808:808"},
	}
	for _, c := range cases {
		p := netip.MustParsePrefix(c.prefix)
		got := nat64Synthesize(p, netip.MustParseAddr(c.v4)).String()
		if got != c.want {
			t.Errorf("nat64Synthesize(%s, %s) = %s, want %s", c.prefix, c.v4, got, c.want)
		}
	}
}

// fakeSocks5 is the smallest SOCKS5 server that can accept a CONNECT to a
// hostname and pipe bytes — enough to prove our client-side handshake is
// wire-correct (greeting, method selection, domain-type CONNECT, reply drain).
func fakeSocks5(t *testing.T, requireAuth bool) (addr string, sawTarget chan string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	sawTarget = make(chan string, 1)

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)

				// greeting
				hdr := make([]byte, 2)
				if _, err := io.ReadFull(br, hdr); err != nil {
					return
				}
				methods := make([]byte, int(hdr[1]))
				if _, err := io.ReadFull(br, methods); err != nil {
					return
				}
				if requireAuth {
					c.Write([]byte{0x05, 0x02})
					// RFC 1929: version, ulen, user, plen, pass
					v := make([]byte, 2)
					io.ReadFull(br, v)
					u := make([]byte, int(v[1]))
					io.ReadFull(br, u)
					pl := make([]byte, 1)
					io.ReadFull(br, pl)
					p := make([]byte, int(pl[0]))
					io.ReadFull(br, p)
					if string(u) != "user" || string(p) != "pass" {
						c.Write([]byte{0x01, 0x01})
						return
					}
					c.Write([]byte{0x01, 0x00})
				} else {
					c.Write([]byte{0x05, 0x00})
				}

				// CONNECT request
				req := make([]byte, 4)
				if _, err := io.ReadFull(br, req); err != nil {
					return
				}
				var host string
				switch req[3] {
				case 0x01:
					b := make([]byte, 4)
					io.ReadFull(br, b)
					host = net.IP(b).String()
				case 0x03:
					l := make([]byte, 1)
					io.ReadFull(br, l)
					b := make([]byte, int(l[0]))
					io.ReadFull(br, b)
					host = string(b)
				case 0x04:
					b := make([]byte, 16)
					io.ReadFull(br, b)
					host = net.IP(b).String()
				default:
					return
				}
				pb := make([]byte, 2)
				io.ReadFull(br, pb)
				port := binary.BigEndian.Uint16(pb)
				sawTarget <- net.JoinHostPort(host, itoa(int(port)))

				// connect upstream for real, then reply with a dummy bind addr
				up, err := net.DialTimeout("tcp", net.JoinHostPort(host, itoa(int(port))), 10*time.Second)
				if err != nil {
					c.Write([]byte{0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
					return
				}
				defer up.Close()
				c.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})

				go io.Copy(up, br)
				io.Copy(c, up)
			}(c)
		}
	}()
	return ln.Addr().String(), sawTarget
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func TestSocks5DialHappyPath(t *testing.T) {
	proxyAddr, sawTarget := fakeSocks5(t, false)
	pu, _ := url.Parse("socks5://" + proxyAddr)

	conn, err := socks5DialContext(t.Context(), pu, "example.com:80", 10*time.Second)
	if err != nil {
		t.Fatalf("socks5DialContext: %v", err)
	}
	defer conn.Close()

	select {
	case got := <-sawTarget:
		if got != "example.com:80" {
			t.Fatalf("proxy saw target %q, want example.com:80 (remote DNS must be used)", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("proxy never saw a CONNECT")
	}
}

func TestSocks5DialAuth(t *testing.T) {
	proxyAddr, _ := fakeSocks5(t, true)
	pu, _ := url.Parse("socks5://user:pass@" + proxyAddr)
	conn, err := socks5DialContext(t.Context(), pu, "example.com:80", 10*time.Second)
	if err != nil {
		t.Fatalf("authenticated dial failed: %v", err)
	}
	conn.Close()

	bad, _ := url.Parse("socks5://user:wrong@" + proxyAddr)
	if _, err := socks5DialContext(t.Context(), bad, "example.com:80", 5*time.Second); err == nil {
		t.Fatal("wrong password must fail")
	}
}

// TestRetryableClassification pins down what is and isn't retried — retrying
// a logical RPC error is what gets a wallet rate-limited.
func TestRetryableClassification(t *testing.T) {
	if retryable(&rpcCodedError{Code: -32600, Message: "Transaction already in mempool"}) {
		t.Error("mempool error must not be retried")
	}
	if !retryable(&rpcCodedError{Code: -32000, Message: "Rate limit exceeded"}) {
		t.Error("rate limit error must be retried")
	}
	if !retryable(io.ErrUnexpectedEOF) {
		t.Error("transport errors must be retried")
	}
}

// TestModeValidation makes sure the env parsing accepts the documented values.
func TestModeValidation(t *testing.T) {
	for in, want := range map[string]rpcNetMode{
		"":         rpcNetAuto,
		"auto":     rpcNetAuto,
		"ipv6":     rpcNetIPv6,
		"ipv4":     rpcNetIPv4,
		"nat64":    rpcNetNAT64,
		"dns64":    rpcNetNAT64,
		"ipv6only": rpcNetIPv6,
	} {
		got, err := parseRPCNetMode(in)
		if err != nil || got != want {
			t.Errorf("parseRPCNetMode(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := parseRPCNetMode("banana"); err == nil {
		t.Error("invalid mode must error")
	}
}
