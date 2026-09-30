package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"syscall"
	"time"
)

const (
	ipProtoICMPv6       = 58
	ipv6MulticastIf     = 17
	ipv6MulticastHops   = 18
	routerSolicitation  = 133
	routerAdvertisement = 134
)

type raPrefix struct {
	ip        net.IP
	prefixLen int
	flags     uint8
	valid     uint32
	preferred uint32
}

func checksum(b []byte) uint16 {
	sum := uint32(0)
	for len(b) > 1 {
		sum += uint32(b[0])<<8 | uint32(b[1])
		b = b[2:]
	}
	if len(b) == 1 {
		sum += uint32(b[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

func inet6Addr(ip net.IP) ([16]byte, error) {
	var out [16]byte
	v6 := ip.To16()
	if v6 == nil || ip.To4() != nil {
		return out, errors.New("not an IPv6 address")
	}
	copy(out[:], v6)
	return out, nil
}

func icmpv6Checksum(src, dst net.IP, pkt []byte) uint16 {
	pseudo := make([]byte, 40+len(pkt))
	copy(pseudo[0:16], src.To16())
	copy(pseudo[16:32], dst.To16())
	binary.BigEndian.PutUint32(pseudo[32:36], uint32(len(pkt)))
	pseudo[39] = ipProtoICMPv6
	copy(pseudo[40:], pkt)
	return checksum(pseudo)
}

func sendOne(fd int, iface *net.Interface, src net.IP, dst net.IP) error {
	if _, err := inet6Addr(src); err != nil {
		return err
	}
	dst16, err := inet6Addr(dst)
	if err != nil {
		return err
	}
	mac := iface.HardwareAddr
	if len(mac) != 6 {
		return fmt.Errorf("interface %s has no 6-byte MAC: %v", iface.Name, mac)
	}

	// ICMPv6 Router Solicitation: fixed header + Source Link-Layer Address option.
	pkt := make([]byte, 16)
	pkt[0] = routerSolicitation
	copy(pkt[8:], []byte{1, 1})
	copy(pkt[10:16], mac)

	pkt[2] = 0
	pkt[3] = 0
	csum := icmpv6Checksum(src, dst, pkt)
	binary.BigEndian.PutUint16(pkt[2:4], csum)

	var rsa syscall.SockaddrInet6
	rsa.Addr = dst16
	rsa.ZoneId = uint32(iface.Index)
	return syscall.Sendto(fd, pkt, 0, &rsa)
}

func parseRA(pkt []byte) ([]raPrefix, uint32) {
	if len(pkt) < 16 || pkt[0] != routerAdvertisement || pkt[1] != 0 {
		return nil, 0
	}
	// Linux ICMPv6 raw sockets deliver packets accepted by the kernel. The
	// checksum was validated before delivery; Recvfrom does not expose the
	// destination address needed to independently reconstruct ICMPv6's pseudo
	// header for unicast RAs, so do not reject valid unicast replies here.
	var prefixes []raPrefix
	mtu := uint32(0)
	for off := 16; off+8 <= len(pkt); {
		optType := pkt[off]
		optLen := int(pkt[off+1]) * 8
		if optLen < 8 || off+optLen > len(pkt) {
			break
		}
		switch optType {
		case 3: // Prefix Information
			if optLen == 32 {
				var p raPrefix
				p.prefixLen = int(pkt[off+2])
				p.flags = pkt[off+3]
				p.valid = binary.BigEndian.Uint32(pkt[off+4:])
				p.preferred = binary.BigEndian.Uint32(pkt[off+8:])
				p.ip = net.IP(append(net.IP(nil), pkt[off+16:off+32]...))
				prefixes = append(prefixes, p)
			}
		case 5: // MTU
			if optLen == 8 {
				mtu = binary.BigEndian.Uint32(pkt[off+4:])
			}
		}
		off += optLen
	}
	return prefixes, mtu
}

func isGlobalUnicastV6(ip net.IP) bool {
	v6 := ip.To16()
	if v6 == nil || ip.To4() != nil {
		return false
	}
	// 2000::/3, excluding documentation/mapped/etc. This intentionally does not
	// accept ULA fc00::/7 because the module's goal is a routable public prefix.
	return v6[0]&0xe0 == 0x20
}

func main() {
	count := flag.Int("c", 4, "number of router solicitations")
	interval := flag.Duration("i", 3*time.Second, "interval between solicitations")
	wait := flag.Duration("w", 20*time.Second, "maximum time to wait for an RA")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: %s [-c count] [-i interval] [-w timeout] interface\n", os.Args[0])
	}
	flag.Parse()
	if flag.NArg() != 1 || *count <= 0 || *wait <= 0 {
		flag.Usage()
		os.Exit(2)
	}

	ifaceName := flag.Arg(0)
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "interface %s: %v\n", ifaceName, err)
		os.Exit(1)
	}
	if iface.Flags&net.FlagUp == 0 {
		fmt.Fprintf(os.Stderr, "interface %s is down\n", ifaceName)
		os.Exit(1)
	}

	var src net.IP
	addrs, err := iface.Addrs()
	if err != nil {
		fmt.Fprintf(os.Stderr, "list addresses: %v\n", err)
		os.Exit(1)
	}
	for _, a := range addrs {
		ipNet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		if ipNet.IP.To4() == nil && ipNet.IP.IsLinkLocalUnicast() {
			src = ipNet.IP
			break
		}
	}
	if src == nil {
		fmt.Fprintf(os.Stderr, "no link-local IPv6 address on %s\n", ifaceName)
		os.Exit(1)
	}

	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, ipProtoICMPv6)
	if err != nil {
		fmt.Fprintf(os.Stderr, "raw socket: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, ipv6MulticastIf, iface.Index); err != nil {
		fmt.Fprintf(os.Stderr, "set IPV6_MULTICAST_IF: %v\n", err)
		os.Exit(1)
	}
	if err := syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, ipv6MulticastHops, 255); err != nil {
		fmt.Fprintf(os.Stderr, "set IPV6_MULTICAST_HOPS: %v\n", err)
		os.Exit(1)
	}

	var lsa syscall.SockaddrInet6
	lsa.Addr, _ = inet6Addr(src)
	lsa.ZoneId = uint32(iface.Index)
	if err := syscall.Bind(fd, &lsa); err != nil {
		fmt.Fprintf(os.Stderr, "bind %s%%%s: %v\n", src, ifaceName, err)
		os.Exit(1)
	}

	deadline := time.Now().Add(*wait)
	nextSend := time.Now()
	sent := 0
	buf := make([]byte, 1500)
	seen := map[string]bool{}

	for time.Now().Before(deadline) {
		now := time.Now()
		if sent < *count && !now.Before(nextSend) {
			if err := sendOne(fd, iface, src, net.IPv6linklocalallrouters); err != nil {
				fmt.Fprintf(os.Stderr, "send RS %d/%d: %v\n", sent+1, *count, err)
				os.Exit(1)
			}
			fmt.Printf("router solicitation %d/%d sent on %s from %s\n", sent+1, *count, ifaceName, src)
			sent++
			nextSend = now.Add(*interval)
		}

		timeout := time.Second
		if d := time.Until(deadline); d < timeout {
			timeout = d
		}
		_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO,
			&syscall.Timeval{Sec: int64(timeout / time.Second), Usec: int64((timeout % time.Second) / time.Microsecond)})

		n, rsa, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			continue
		}
		if n < 16 || buf[0] != routerAdvertisement || buf[1] != 0 {
			continue
		}
		sa, ok := rsa.(*syscall.SockaddrInet6)
		if !ok {
			continue
		}
		routerIP := net.IP(sa.Addr[:])
		if !routerIP.IsLinkLocalUnicast() {
			continue
		}
		pkt := append([]byte(nil), buf[:n]...)
		prefixes, mtu := parseRA(pkt)
		for _, p := range prefixes {
			if p.prefixLen != 64 || p.flags&0x40 == 0 || p.valid == 0 || p.preferred == 0 || !isGlobalUnicastV6(p.ip) {
				continue
			}
			key := fmt.Sprintf("%s/%d", p.ip.String(), p.prefixLen)
			if seen[key] {
				continue
			}
			seen[key] = true
			fmt.Printf("RA_PREFIX prefix=%s/%d prefix_hex=%02x%02x%02x%02x%02x%02x%02x%02x router=%s valid=%d preferred=%d mtu=%d flags=0x%02x\n",
				p.ip.String(), p.prefixLen,
				p.ip[0], p.ip[1], p.ip[2], p.ip[3], p.ip[4], p.ip[5], p.ip[6], p.ip[7],
				routerIP.String(), p.valid, p.preferred, mtu, p.flags)
			os.Exit(0)
		}
	}
	os.Exit(1)
}
