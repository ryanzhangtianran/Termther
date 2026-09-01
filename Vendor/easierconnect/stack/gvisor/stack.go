package gvisor

import (
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"

	clientpkg "termther/easyconnect/client"
	"termther/easyconnect/client/easyconnect"
	"termther/easyconnect/internal/hook_func"
	"termther/easyconnect/internal/ippool"
	"termther/easyconnect/internal/zcdns"
	"termther/easyconnect/log"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

type Stack struct {
	gvisorStack *stack.Stack
	resolve     zcdns.LocalServer
	ipPool      *ippool.IPPool[[]clientpkg.DomainResource]

	endpoint *Endpoint
	ipMu     sync.Mutex
	ip       tcpip.Address
}

const NICID tcpip.NICID = 1
const MTU uint32 = 1400
const maxInboundPacketSize = 1500

type Endpoint struct {
	client clientpkg.Client

	l3Conn io.ReadWriteCloser

	dispatcher stack.NetworkDispatcher
}

func (ep *Endpoint) ParseHeader(*stack.PacketBuffer) bool {
	return true
}

func (ep *Endpoint) MTU() uint32 {
	return MTU
}

func (ep *Endpoint) SetMTU(mtu uint32) {
	log.Printf("don't support change MTU from %d to %d", MTU, mtu)
}

func (ep *Endpoint) MaxHeaderLength() uint16 {
	return 0
}

func (ep *Endpoint) LinkAddress() tcpip.LinkAddress {
	return ""
}

func (ep *Endpoint) SetLinkAddress(addr tcpip.LinkAddress) {}

func (ep *Endpoint) Capabilities() stack.LinkEndpointCapabilities {
	return stack.CapabilityNone
}

func (ep *Endpoint) Attach(dispatcher stack.NetworkDispatcher) {
	ep.dispatcher = dispatcher
}

func (ep *Endpoint) IsAttached() bool {
	return ep.dispatcher != nil
}

func (ep *Endpoint) Wait() {}

func (ep *Endpoint) ARPHardwareType() header.ARPHardwareType {
	return header.ARPHardwareNone
}

func (ep *Endpoint) AddHeader(*stack.PacketBuffer) {}

func (ep *Endpoint) Close() {}

func (ep *Endpoint) SetOnCloseAction(func()) {}

// WritePackets is called when get packets from gVisor stack. Then it sends them to VPN server
// OnFatal is called where upstream would end the process.
//
// Upstream is a command-line program, so it treats a broken tunnel as
// terminal: it panics on a read or write error and calls os.Exit on a
// server-initiated shutdown. Inside an application both of those take the host
// process down with them -- the panic as a SIGABRT from the Go runtime, the
// os.Exit silently and with no crash report at all. Changing networks is
// enough to trigger either. Termther reports instead and tears the tunnel down
// itself.
//
// TERMTHER PATCH: the three call sites below are the only changes to this
// file. Everything else is upstream v1.3.1 (AGPL-3.0).
var OnFatal func(error)

// stopped is set while the tunnel is being torn down.
//
// gvisor keeps handing packets to WritePackets after the client has been
// closed, and writing them means touching a connection that is being pulled
// apart underneath -- a nil dereference inside a goroutine gvisor owns, which
// no recover of ours can catch because it is not on our stack. Dropping
// packets once teardown starts is both correct and the only thing that makes
// the window safe.
var stopped atomic.Bool

// SetStopped is called by the embedding program around teardown.
func SetStopped(value bool) { stopped.Store(value) }

func reportFatal(err error) {
	if OnFatal != nil {
		OnFatal(err)
	}
}

func (ep *Endpoint) WritePackets(list stack.PacketBufferList) (int, tcpip.Error) {
	// TERMTHER PATCH: gvisor calls this from its own goroutine, so a panic
	// here belongs to nobody and ends the process. Whatever went wrong, the
	// answer is the same: the tunnel is finished, say so and stop.
	defer func() {
		if r := recover(); r != nil {
			reportFatal(fmt.Errorf("write panicked: %v", r))
		}
	}()
	if stopped.Load() {
		return list.Len(), nil
	}

	for _, packetBuffer := range list.AsSlice() {
		buf := joinPacketSlices(packetBuffer.AsSlices())

		if ep.l3Conn != nil {
			n, err := ep.l3Conn.Write(buf)
			if err != nil {
				if errors.Is(err, clientpkg.ErrResourceNotFound) {
					log.Printf("%v", err)
					continue
				}

				// Server-initiated SHUTDOWN: known terminal state from
				// sangfor (cmd 0x08). No point retrying; run the registered
				// cleanup hooks (DNS revert, tun device close, etc.) and
				// exit so systemd / a wrapper can do a fresh login. This
				// is strictly better than panicking with a gvisor stack
				// trace, which obscures the actual cause.
				// TERMTHER PATCH: was os.Exit(2).
				if errors.Is(err, easyconnect.ErrSangforShutdown) {
					log.Printf("WritePackets: server SHUTDOWN; reporting instead of exiting")
					reportFatal(err)
					return list.Len(), nil
				}

				// TERMTHER PATCH: was panic(err).
				if !hook_func.IsTerminal() {
					reportFatal(err)
				}
				return list.Len(), nil
			}
			log.DebugPrintf("Send: wrote %d bytes", n)
			log.DebugDumpHex(buf[:n])
		}
	}

	return list.Len(), nil
}

func joinPacketSlices(slices [][]byte) []byte {
	total := 0
	for _, slice := range slices {
		total += len(slice)
	}
	buf := make([]byte, total)
	offset := 0
	for _, slice := range slices {
		offset += copy(buf[offset:], slice)
	}
	return buf
}

func NewStack(client clientpkg.Client) (*Stack, error) {
	s := &Stack{}

	s.gvisorStack = stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
		HandleLocal:        true,
	})

	s.endpoint = &Endpoint{
		client: client,
	}

	tcpipErr := s.gvisorStack.CreateNIC(NICID, s.endpoint)
	if tcpipErr != nil {
		return nil, errors.New(tcpipErr.String())
	}

	ip, err := client.IP()
	if err != nil {
		return nil, err
	}

	addr := tcpip.AddrFromSlice(ip)
	s.ip = addr
	protoAddr := tcpip.ProtocolAddress{
		AddressWithPrefix: tcpip.AddressWithPrefix{
			Address:   addr,
			PrefixLen: 32,
		},
		Protocol: ipv4.ProtocolNumber,
	}

	tcpipErr = s.gvisorStack.AddProtocolAddress(NICID, protoAddr, stack.AddressProperties{})
	if tcpipErr != nil {
		return nil, errors.New(tcpipErr.String())
	}
	clientpkg.RegisterIPUpdateHandler(client, s.updateIP)

	sOpt := tcpip.TCPSACKEnabled(true)
	s.gvisorStack.SetTransportProtocolOption(tcp.ProtocolNumber, &sOpt)
	cOpt := tcpip.CongestionControlOption("cubic")
	s.gvisorStack.SetTransportProtocolOption(tcp.ProtocolNumber, &cOpt)
	s.gvisorStack.AddRoute(tcpip.Route{Destination: header.IPv4EmptySubnet, NIC: NICID})

	return s, nil
}

func (s *Stack) updateIP(ip net.IP) error {
	ip = ip.To4()
	if ip == nil {
		return errors.New("virtual IP update is not IPv4")
	}
	newAddr := tcpip.AddrFromSlice(ip)
	s.ipMu.Lock()
	defer s.ipMu.Unlock()
	if newAddr == s.ip {
		return nil
	}
	protoAddr := tcpip.ProtocolAddress{
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: newAddr, PrefixLen: 32},
		Protocol:          ipv4.ProtocolNumber,
	}
	if err := s.gvisorStack.AddProtocolAddress(NICID, protoAddr, stack.AddressProperties{}); err != nil {
		return errors.New(err.String())
	}
	if err := s.gvisorStack.RemoveAddress(NICID, s.ip); err != nil {
		_ = s.gvisorStack.RemoveAddress(NICID, newAddr)
		return errors.New(err.String())
	}
	s.ip = newAddr
	return nil
}

func (s *Stack) SetupResolve(r zcdns.LocalServer) {
	s.resolve = r
}

func (s *Stack) SetupIPPool(ipPool *ippool.IPPool[[]clientpkg.DomainResource]) {
	s.ipPool = ipPool
}

func (s *Stack) Run() {
	var connErr error
	s.endpoint.l3Conn, connErr = s.endpoint.client.NewL3Conn()
	if connErr != nil {
		// TERMTHER PATCH: was panic(connErr).
		reportFatal(connErr)
		return
	}
	// Read from VPN server and send to gVisor stack
	buf := make([]byte, maxInboundPacketSize)
	for {
		// TERMTHER PATCH: stop reading once teardown has begun, rather than
		// racing the close.
		if stopped.Load() {
			return
		}
		n, err := s.endpoint.l3Conn.Read(buf)
		if err != nil {
			// TERMTHER PATCH: was panic(err). A read failing is what a
			// changed network looks like from in here.
			if !hook_func.IsTerminal() {
				reportFatal(err)
			}
			return
		}
		log.DebugPrintf("Recv: read %d bytes", n)
		log.DebugDumpHex(buf[:n])

		packetBuffer := makeInboundPacketBuffer(buf, n)
		s.endpoint.dispatcher.DeliverNetworkPacket(header.IPv4ProtocolNumber, packetBuffer)
		packetBuffer.DecRef()
	}
}

func makeInboundPacketBuffer(buf []byte, n int) *stack.PacketBuffer {
	return stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(buf[:n]),
	})
}
