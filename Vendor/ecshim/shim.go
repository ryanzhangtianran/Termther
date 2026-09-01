// spike 01 — EasyConnect (Sangfor SSL VPN) as a Termther SSHTransport.
//
// Wraps the EasyConnect engine in Vendor/easierconnect (AGPL-3.0, the same
// licence as Termther) as a
// C archive so Swift can drive it in-process: no external client, no TUN
// device, no root, no system-wide routing change.
//
// The shape mirrors what Net.SSHTransport needs: give me a host and
// a port, hand me back a connected file descriptor. Everything above this
// line (libssh2) never learns a VPN was involved.
//
//	ec_login(server, user, pass, totp) -> assigned VPN IP, or "" + ec_last_error()
//	ec_dial_tcp(host, port)            -> a real BSD fd, tunnelled
//	ec_logout()
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"termther/easyconnect/client/easyconnect"
	"termther/easyconnect/log"
	"termther/easyconnect/stack/gvisor"
	"termther/easyconnect/underlay"
)

var (
	mu        sync.Mutex
	vpnClient *easyconnect.Client
	vpnUnder  *underlay.Dialer
	vpnStack  *gvisor.Stack
	lastErr   string

	// Set by ec_set_underlay. Not read from the environment, because a Go
	// runtime linked as a c-archive copies the environment once, at process
	// start: a setenv() from the host program afterwards is invisible to
	// os.Getenv, so the values silently stayed empty and every connection
	// failed with a timeout that blamed the gateway.
	//
	// Guarded by their own mutex, not `mu`. ec_login holds `mu` for the whole
	// handshake and reads these inside it; sync.Mutex is not reentrant, so
	// sharing one lock deadlocks the login outright -- it hangs at
	// "connecting" and never returns.
	underlayMu    sync.Mutex
	underlayIface string
	underlayDNS   string

	// Why the tunnel stopped, when it stopped by itself. Upstream ends the
	// process at these points; the local fork reports here instead, and the
	// host asks with ec_tunnel_failure.
	failureMu sync.Mutex
	failure   string
)

func init() {
	gvisor.OnFatal = func(err error) {
		failureMu.Lock()
		if failure == "" {
			failure = err.Error()
		}
		failureMu.Unlock()
	}
}

// ec_tunnel_failure reports why the tunnel stopped carrying traffic, or "" if
// it has not. Polled rather than pushed: a Go callback into Swift would have
// to cross the C boundary from whichever goroutine failed, and there is
// nothing to gain from the extra machinery when the answer is one string.
//
//export ec_tunnel_failure
func ec_tunnel_failure() *C.char {
	failureMu.Lock()
	defer failureMu.Unlock()
	return C.CString(failure)
}

//export ec_set_underlay
func ec_set_underlay(iface, dns *C.char) {
	underlayMu.Lock()
	defer underlayMu.Unlock()
	underlayIface = C.GoString(iface)
	underlayDNS = C.GoString(dns)
}

// underlayOptions lets the caller escape a local TUN proxy (Surge, Clash,
// sing-box). Such a tool installs a default route and a fake DNS server, so
// by default every socket this process opens -- including the one to the VPN
// gateway -- is intercepted and never reaches the real gateway.
//
// Set through ec_set_underlay by an embedding program; the environment is
// the fallback so the command-line probe still works:
//
//	EC_IFACE=en1        bind underlay sockets to a physical interface
//	EC_DNS=1.1.1.1      resolve the gateway hostname with a real DNS server
//
// The two belong together. The dialer binds to a physical interface whether
// or not one was named (AutoDetect), so an interface without a resolver is
// the one combination that cannot work: the name is resolved by the local
// proxy, which answers with an address that only exists inside it, and then
// dialled from a socket that deliberately bypasses it.
func underlayOptions() underlay.Options {
	underlayMu.Lock()
	iface, dns := underlayIface, underlayDNS
	underlayMu.Unlock()

	if iface == "" {
		iface = os.Getenv("EC_IFACE")
	}
	if dns == "" {
		dns = os.Getenv("EC_DNS")
	}
	return underlay.Options{
		InterfaceName:  iface,
		LocalDNSServer: dns,
		AutoDetect:     iface == "",
	}
}

func setErr(format string, a ...any) {
	lastErr = fmt.Sprintf(format, a...)
}

//export ec_last_error
func ec_last_error() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return C.CString(lastErr)
}

//export ec_login
func ec_login(server, username, password, totpSecret *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()

	log.Init()
	lastErr = ""

	failureMu.Lock()
	failure = ""
	failureMu.Unlock()

	under, err := underlay.New(underlayOptions())
	if err != nil {
		setErr("underlay: %v", err)
		return C.CString("")
	}

	c := easyconnect.NewClient(easyconnect.Options{
		Server: C.GoString(server),
		Auth: easyconnect.AuthOptions{
			Username:   C.GoString(username),
			Password:   C.GoString(password),
			TOTPSecret: C.GoString(totpSecret),
		},
		UnderlayDialer: under,
		Resources: easyconnect.ResourceOptions{
			Fetch:          true,
			IncludeDomains: true,
		},
	})

	// Setup() is the whole handshake: /por/login_psw.csp -> TwfID -> token ->
	// L3 tunnel. This is the step that tells us whether the protocol still
	// matches what the school runs.
	if err := c.Setup(); err != nil {
		c.Close()
		_ = under.Close()
		setErr("setup: %v", err)
		return C.CString("")
	}

	ip, err := c.IP()
	if err != nil {
		c.Close()
		_ = under.Close()
		setErr("ip: %v", err)
		return C.CString("")
	}

	// EasyConnect is an L3 (IP packet) tunnel -- unlike aTrust it has no
	// TCP-tunnel mode -- so a userspace TCP/IP stack sits on top of it.
	st, err := gvisor.NewStack(c)
	if err != nil {
		c.Close()
		_ = under.Close()
		setErr("stack: %v", err)
		return C.CString("")
	}

	gvisor.SetStopped(false)

	// The stack is inert until something pumps it: Run() blocks reading IP
	// packets off the L3 tunnel and delivering them into gvisor. Without this
	// goroutine a dial sends its SYN and then waits forever for a SYN-ACK that
	// nothing ever delivers.
	//
	// Run() panics on a tunnel read error (one of the CLI-process assumptions
	// noted in the README). Recovering here keeps a dropped VPN from taking
	// the whole process down; the real fix is to patch it upstream to return
	// an error instead.
	go func() {
		defer func() {
			if r := recover(); r != nil {
				mu.Lock()
				lastErr = fmt.Sprintf("tunnel pump stopped: %v", r)
				mu.Unlock()
			}
		}()
		st.Run()
	}()

	vpnClient, vpnUnder, vpnStack = c, under, st
	return C.CString(ip.String())
}

//export ec_logout
func ec_logout() {
	// Before anything is closed: gvisor goes on handing packets to the
	// endpoint while the client is being torn down, and writing them means
	// touching a connection coming apart underneath.
	gvisor.SetStopped(true)

	failureMu.Lock()
	failure = ""
	failureMu.Unlock()

	mu.Lock()
	defer mu.Unlock()
	if vpnClient != nil {
		vpnClient.Close()
		vpnClient = nil
	}
	if vpnUnder != nil {
		_ = vpnUnder.Close()
		vpnUnder = nil
	}
	vpnStack = nil
}

// ec_detect asks a gateway whether it speaks EasyConnect, without credentials.
//
// The EasyConnect login flow starts at /por/login_auth.csp; a Sangfor gateway
// running that protocol answers it with XML. Anything else -- a 404, an HTML
// portal, a TLS failure -- means either aTrust (a different protocol, also
// implemented upstream) or not a Sangfor gateway at all.
//
//export ec_detect
func ec_detect(server *C.char) *C.char {
	addr := C.GoString(server)
	if !strings.Contains(addr, ":") {
		addr += ":443"
	}

	// Dial through the same underlay the real client uses, so EC_IFACE /
	// EC_DNS escape a local TUN proxy here as well. Without this the probe
	// reports on the proxy, not on the gateway.
	d, err := underlay.New(underlayOptions())
	if err != nil {
		return C.CString(fmt.Sprintf("unreachable|underlay: %v", err))
	}
	defer d.Close()

	client := &http.Client{
		Timeout: 20 * time.Second,
		Transport: &http.Transport{
			DialContext: d.DialContext,
			// Campus gateways routinely present certificates that do not
			// validate; this is a reachability probe, not a trust decision.
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	url := "https://" + addr + "/por/login_auth.csp?apiversion=1"
	resp, err := client.Get(url)
	if err != nil {
		return C.CString(fmt.Sprintf("unreachable|%v", err))
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	text := strings.TrimSpace(string(body))

	verdict := "unknown"
	switch {
	case strings.Contains(text, "<Auth") || strings.Contains(text, "<auth") ||
		strings.Contains(text, "twfid") || strings.Contains(text, "TwfID"):
		verdict = "easyconnect"
	case resp.StatusCode == 404:
		verdict = "not-easyconnect"
	}

	if len(text) > 240 {
		text = text[:240] + "..."
	}
	return C.CString(fmt.Sprintf("%s|HTTP %d|%s", verdict, resp.StatusCode, text))
}

// resolveInTunnel looks a name up using the DNS server the gateway handed us,
// reached over the tunnel rather than the local network.
func resolveInTunnel(ctx context.Context, host string) (net.IP, error) {
	mu.Lock()
	st, c := vpnStack, vpnClient
	mu.Unlock()
	if st == nil || c == nil {
		return nil, fmt.Errorf("not logged in")
	}

	if ip := net.ParseIP(host); ip != nil {
		return ip, nil
	}

	dns, err := c.DNSServer()
	if err != nil {
		return nil, fmt.Errorf("gateway advertised no DNS server: %w", err)
	}

	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return st.DialUDP(ctx, &net.UDPAddr{IP: net.ParseIP(dns), Port: 53})
		},
	}

	ips, err := r.LookupIP(ctx, "ip4", host)
	if err != nil {
		return nil, fmt.Errorf("resolve %s via %s: %w", host, dns, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("resolve %s: no A record", host)
	}
	return ips[0], nil
}

// ec_resources reports the ACL the gateway granted this session. A Sangfor
// gateway only routes the subnets and ports on this list; anything else is
// silently dropped, which looks like a hang rather than a refusal. Knowing the
// list is the difference between "the tunnel is broken" and "you dialled
// somewhere this account is not allowed to go".
//
//export ec_resources
func ec_resources() *C.char {
	mu.Lock()
	c := vpnClient
	mu.Unlock()
	if c == nil {
		setErr("not logged in")
		return C.CString("")
	}

	var b strings.Builder

	ips, err := c.IPResources()
	if err != nil {
		fmt.Fprintf(&b, "IP resources: unavailable (%v)\n", err)
	} else {
		fmt.Fprintf(&b, "IP resources (%d):\n", len(ips))
		for _, r := range ips {
			ports := "all ports"
			if r.PortMin != 0 || r.PortMax != 0 {
				if r.PortMin == r.PortMax {
					ports = fmt.Sprintf("port %d", r.PortMin)
				} else {
					ports = fmt.Sprintf("ports %d-%d", r.PortMin, r.PortMax)
				}
			}
			rng := r.IPMin.String()
			if !r.IPMin.Equal(r.IPMax) {
				rng += " - " + r.IPMax.String()
			}
			fmt.Fprintf(&b, "  %-34s %-16s %s\n", rng, ports, r.Protocol)
		}
	}

	if domains, err := c.DomainResources(); err == nil && len(domains) > 0 {
		fmt.Fprintf(&b, "Domain resources (%d):\n", len(domains))
		n := 0
		for name := range domains {
			if n >= 20 {
				fmt.Fprintf(&b, "  ... and %d more\n", len(domains)-n)
				break
			}
			fmt.Fprintf(&b, "  %s\n", name)
			n++
		}
	}

	if dns, err := c.DNSServers(); err == nil && len(dns) > 0 {
		fmt.Fprintf(&b, "DNS servers: %s\n", strings.Join(dns, ", "))
	}

	return C.CString(b.String())
}

// ec_resources_json reports the same ACL as ec_resources, in a form a program
// can read. The text version stays because the command-line probe prints it;
// this one exists so a panel can lay the ranges out as a table instead of
// parsing formatted columns back apart.
//
//export ec_resources_json
func ec_resources_json() *C.char {
	mu.Lock()
	c := vpnClient
	mu.Unlock()
	if c == nil {
		setErr("not logged in")
		return C.CString("")
	}

	type ipRange struct {
		From     string `json:"from"`
		To       string `json:"to"`
		PortMin  int    `json:"portMin"`
		PortMax  int    `json:"portMax"`
		Protocol string `json:"protocol"`
	}
	payload := struct {
		IP      []ipRange `json:"ip"`
		Domains []string  `json:"domains"`
		DNS     []string  `json:"dns"`
	}{IP: []ipRange{}, Domains: []string{}, DNS: []string{}}

	if ips, err := c.IPResources(); err == nil {
		for _, r := range ips {
			payload.IP = append(payload.IP, ipRange{
				From:     r.IPMin.String(),
				To:       r.IPMax.String(),
				PortMin:  int(r.PortMin),
				PortMax:  int(r.PortMax),
				Protocol: r.Protocol,
			})
		}
	}
	if domains, err := c.DomainResources(); err == nil {
		for name := range domains {
			payload.Domains = append(payload.Domains, name)
		}
		sort.Strings(payload.Domains)
	}
	if dns, err := c.DNSServers(); err == nil {
		payload.DNS = append(payload.DNS, dns...)
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		setErr("%v", err)
		return C.CString("")
	}
	return C.CString(string(encoded))
}

//export ec_resolve
func ec_resolve(host *C.char) *C.char {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ip, err := resolveInTunnel(ctx, C.GoString(host))
	if err != nil {
		setErr("%v", err)
		return C.CString("")
	}
	return C.CString(ip.String())
}

// ec_dial_tcp dials through the tunnel and returns one end of a socketpair.
//
// The gvisor stack hands back a net.Conn, which is not a file descriptor and
// so cannot be given to libssh2. A socketpair bridges the two: Go pumps
// bytes between the tunnelled conn and sv[0], and the caller gets sv[1] --
// an ordinary BSD socket that libssh2_session_handshake() accepts unmodified.
// This is the same adapter used for jump hosts.
//
//export ec_dial_tcp
func ec_dial_tcp(host *C.char, port C.int) C.int {
	mu.Lock()
	st := vpnStack
	mu.Unlock()
	if st == nil {
		setErr("not logged in")
		return -1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ip, err := resolveInTunnel(ctx, C.GoString(host))
	if err != nil {
		setErr("%v", err)
		return -1
	}

	conn, err := st.DialTCP(ctx, &net.TCPAddr{IP: ip.To4(), Port: int(port)})
	if err != nil {
		setErr("dial %s:%d: %v", ip, int(port), err)
		return -1
	}

	sv, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		conn.Close()
		setErr("socketpair: %v", err)
		return -1
	}

	local, err := fileConn(sv[0])
	if err != nil {
		conn.Close()
		syscall.Close(sv[0])
		syscall.Close(sv[1])
		setErr("fileconn: %v", err)
		return -1
	}

	go func() {
		defer conn.Close()
		defer local.Close()
		done := make(chan struct{}, 2)
		go func() { io.Copy(conn, local); done <- struct{}{} }()
		go func() { io.Copy(local, conn); done <- struct{}{} }()
		<-done
	}()

	return C.int(sv[1])
}

func fileConn(fd int) (net.Conn, error) {
	f := newFile(fd, "socketpair")
	defer f.Close()
	return net.FileConn(f)
}

func main() {}
