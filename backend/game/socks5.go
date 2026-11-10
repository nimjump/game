package game

// Minimal SOCKS5 client (RFC 1928 + RFC 1929 user/pass auth) used by
// NIMIQ_RPC_PROXY=socks5://[user:pass@]host:port.
//
// Why not just pull in golang.org/x/net/proxy? Because this repo deliberately
// has a tiny dependency set (badger, fasthttp, x/crypto), and all we need is
// "dial a hostname through a tunnel, let the *proxy* resolve it". That last
// part matters here: with an IPv6-only host and an IPv4-only RPC endpoint,
// remote DNS resolution (socks5h) is what makes the tunnel work at all.

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"time"
)

func socks5DialContext(ctx context.Context, proxy *url.URL, addr string, timeout time.Duration) (net.Conn, error) {
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	d := &net.Dialer{Timeout: timeout, KeepAlive: 30 * time.Second}

	proxyAddr := proxy.Host
	if proxy.Port() == "" {
		proxyAddr = net.JoinHostPort(proxy.Hostname(), "1080")
	}

	conn, err := d.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, fmt.Errorf("socks5: dial proxy %s: %w", proxyAddr, err)
	}

	deadline := time.Now().Add(timeout)
	if dl, ok := ctx.Deadline(); ok && dl.Before(deadline) {
		deadline = dl
	}
	_ = conn.SetDeadline(deadline)

	if err := socks5Handshake(conn, proxy, addr); err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{}) // clear: let the HTTP client own deadlines
	return conn, nil
}

func socks5Handshake(conn net.Conn, proxy *url.URL, addr string) error {
	// ── greeting: offer no-auth, and user/pass if credentials were given ──
	methods := []byte{0x00} // no auth
	useAuth := proxy.User != nil
	if useAuth {
		methods = append(methods, 0x02) // username/password
	}
	greet := append([]byte{0x05, byte(len(methods))}, methods...)
	if _, err := conn.Write(greet); err != nil {
		return fmt.Errorf("socks5: greet write: %w", err)
	}
	var sel [2]byte
	if _, err := io.ReadFull(conn, sel[:]); err != nil {
		return fmt.Errorf("socks5: greet read: %w", err)
	}
	if sel[0] != 0x05 {
		return fmt.Errorf("socks5: bad version %d from proxy", sel[0])
	}
	switch sel[1] {
	case 0x00:
		// no auth selected
	case 0x02:
		if !useAuth {
			return fmt.Errorf("socks5: proxy demands auth but no credentials in NIMIQ_RPC_PROXY")
		}
		user := proxy.User.Username()
		pass, _ := proxy.User.Password()
		buf := []byte{0x01, byte(len(user))}
		buf = append(buf, user...)
		buf = append(buf, byte(len(pass)))
		buf = append(buf, pass...)
		if _, err := conn.Write(buf); err != nil {
			return fmt.Errorf("socks5: auth write: %w", err)
		}
		var ar [2]byte
		if _, err := io.ReadFull(conn, ar[:]); err != nil {
			return fmt.Errorf("socks5: auth read: %w", err)
		}
		if ar[1] != 0x00 {
			return fmt.Errorf("socks5: authentication rejected")
		}
	case 0xFF:
		return fmt.Errorf("socks5: no acceptable auth method")
	default:
		return fmt.Errorf("socks5: unsupported auth method 0x%02x", sel[1])
	}

	// ── CONNECT, always with a domain name so the PROXY resolves it ──
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("socks5: bad target %q: %w", addr, err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("socks5: bad target port %q", portStr)
	}
	req := []byte{0x05, 0x01, 0x00} // CONNECT, IPv4 type placeholder
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		req = append(req, 0x01)
		req = append(req, ip.To4()...)
	} else if ip != nil {
		req = append(req, 0x04) // IPv6 literal
		req = append(req, ip.To16()...)
	} else {
		if len(host) > 255 {
			return fmt.Errorf("socks5: hostname too long")
		}
		req = append(req, 0x03, byte(len(host)))
		req = append(req, host...)
	}
	var pb [2]byte
	binary.BigEndian.PutUint16(pb[:], uint16(port))
	req = append(req, pb[:]...)
	if _, err := conn.Write(req); err != nil {
		return fmt.Errorf("socks5: connect write: %w", err)
	}

	var rep [4]byte
	if _, err := io.ReadFull(conn, rep[:]); err != nil {
		return fmt.Errorf("socks5: connect read: %w", err)
	}
	if rep[0] != 0x05 {
		return fmt.Errorf("socks5: bad version %d in reply", rep[0])
	}
	if rep[1] != 0x00 {
		return fmt.Errorf("socks5: proxy refused CONNECT to %s: %s", addr, socks5ErrText(rep[1]))
	}
	// Drain the bound address.
	var skip int
	switch rep[3] {
	case 0x01:
		skip = 4
	case 0x04:
		skip = 16
	case 0x03:
		var l [1]byte
		if _, err := io.ReadFull(conn, l[:]); err != nil {
			return fmt.Errorf("socks5: reply read: %w", err)
		}
		skip = int(l[0])
	default:
		return fmt.Errorf("socks5: bad address type 0x%02x", rep[3])
	}
	if _, err := io.ReadFull(conn, make([]byte, skip+2)); err != nil {
		return fmt.Errorf("socks5: reply drain: %w", err)
	}
	return nil
}

func socks5ErrText(code byte) string {
	switch code {
	case 0x01:
		return "general SOCKS server failure"
	case 0x02:
		return "connection not allowed by ruleset"
	case 0x03:
		return "network unreachable"
	case 0x04:
		return "host unreachable"
	case 0x05:
		return "connection refused"
	case 0x06:
		return "TTL expired"
	case 0x07:
		return "command not supported"
	case 0x08:
		return "address type not supported"
	default:
		return fmt.Sprintf("error 0x%02x", code)
	}
}
