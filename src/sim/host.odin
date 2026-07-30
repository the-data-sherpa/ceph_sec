package sim

// IPv4 address, packed. Stored as a number rather than a string so subnet
// membership and ranges are arithmetic, not parsing.
Addr :: distinct u32

addr :: proc(a, b, c, d: u8) -> Addr {
	return Addr(u32(a) << 24 | u32(b) << 16 | u32(c) << 8 | u32(d))
}

addr_octet :: proc(a: Addr, i: uint) -> u8 {
	return u8((u32(a) >> (24 - i * 8)) & 0xff)
}

// Formats into a caller-supplied buffer -- no allocation, so this is safe to
// call from anywhere in the sim including hot paths. Buffer must hold 15 bytes.
addr_write :: proc(buf: []u8, a: Addr) -> string {
	assert(len(buf) >= 15)
	n := 0
	for i in uint(0) ..< 4 {
		if i > 0 {
			buf[n] = '.'
			n += 1
		}
		v := addr_octet(a, i)
		if v >= 100 {
			buf[n] = '0' + v / 100
			n += 1
		}
		if v >= 10 {
			buf[n] = '0' + (v / 10) % 10
			n += 1
		}
		buf[n] = '0' + v % 10
		n += 1
	}
	return string(buf[:n])
}

addr_string :: proc(a: Addr, allocator := context.allocator) -> string {
	buf := make([]u8, 15, allocator)
	s := addr_write(buf, a)
	return s
}

Protocol :: enum u8 {
	TCP,
	UDP,
}

// What the player currently holds on a host. Ordered, so comparisons like
// `host.access >= .User` are meaningful.
Access :: enum u8 {
	None,
	User,
	Root,
}

// A listening service. `product`/`version` are the hook everything else hangs
// off: vulnerability matching, exploit applicability, and the version-sniffing
// half of real enumeration all key on this pair.
Service :: struct {
	port:       u16,
	proto:      Protocol,
	name:       string, // "ssh", "http", "smb"
	product:    string, // "OpenSSH", "Apache httpd"
	version:    string, // "7.4", "2.4.29"
	banner:     string,
	discovered: bool,
}

Account :: struct {
	username: string,
	password: string, // ground truth; not shown until obtained
	pw_hash:  string, // what a dump actually yields
	is_admin: bool,
	known:    bool, // player has seen the username
	cracked:  bool, // player has the plaintext
}

File :: struct {
	path:      string,
	size:      int,
	content:   string,
	sensitive: bool, // counts toward exfil objectives
	found:     bool,
}

Host :: struct {
	hostname:   string,
	address:    Addr,
	subnet:     Handle(Subnet),
	os_name:    string,
	services:   [dynamic]Service,
	accounts:   [dynamic]Account,
	files:      [dynamic]File,
	access:     Access,
	discovered: bool, // player knows it exists
}

host_service_by_port :: proc(h: ^Host, port: u16) -> (^Service, bool) {
	for &s in h.services {
		if s.port == port {
			return &s, true
		}
	}
	return nil, false
}

host_account :: proc(h: ^Host, username: string) -> (^Account, bool) {
	for &a in h.accounts {
		if a.username == username {
			return &a, true
		}
	}
	return nil, false
}
