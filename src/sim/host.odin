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

// A credential the player has obtained.
//
// Deliberately not tied to the host it came from. Credential reuse is the
// primary lateral-movement path in reality and the central mechanic here, so a
// credential is a free-floating fact that gets tried against anything. `note`
// records where it came from, which is the only thing that makes a keyring of
// a dozen entries navigable.
Cred :: struct {
	username: string,
	password: string,
	note:     string, // "web01:/home/svc/deploy.env"
}

File :: struct {
	path:      string,
	size:      int,
	content:   string,
	sensitive: bool, // counts toward exfil objectives
	found:     bool,

	// Taking this file is the contract. Set on exactly one file per run.
	objective: bool,

	// Credentials this file discloses when read. Config files, deployment
	// scripts and .env files leaking passwords is the most common real-world
	// path to lateral movement, and it is how creds enter play here.
	creds: []Cred,
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
	access_at:  Tick, // when access was last raised; the hunt takes newest first
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

host_file :: proc(h: ^Host, path: string) -> (^File, bool) {
	for &f in h.files {
		if f.path == path {
			return &f, true
		}
	}
	return nil, false
}

// Index rather than pointer, for callers that need to name the file in a
// scheduled Action -- a pointer would not survive the wait.
host_file_index :: proc(h: ^Host, path: string) -> (int, bool) {
	for f, i in h.files {
		if f.path == path {
			return i, true
		}
	}
	return -1, false
}

// Parses a dotted-quad. Strict: exactly four octets, each 0-255, no leading
// '+'/'-', no whitespace. Being liberal here would mean `nmap 10.0.4` silently
// scanning something the player did not name.
addr_parse :: proc(s: string) -> (Addr, bool) {
	octets: [4]u8
	part := 0
	i := 0

	for part < 4 {
		if i >= len(s) || s[i] < '0' || s[i] > '9' {
			return 0, false // every octet needs at least one digit
		}
		value := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			value = value * 10 + int(s[i] - '0')
			if value > 255 {
				return 0, false
			}
			i += 1
		}
		octets[part] = u8(value)
		part += 1

		if part < 4 {
			if i >= len(s) || s[i] != '.' {
				return 0, false
			}
			i += 1
		}
	}

	if i != len(s) {
		return 0, false // trailing junk
	}
	return addr(octets[0], octets[1], octets[2], octets[3]), true
}

// Parses "10.0.4.0/24". A bare address is accepted as a /32, so callers can
// take either a single host or a range through one entry point.
cidr_parse :: proc(s: string) -> (base: Addr, mask_bits: u8, ok: bool) {
	slash := -1
	for i in 0 ..< len(s) {
		if s[i] == '/' {
			slash = i
			break
		}
	}

	if slash < 0 {
		a, a_ok := addr_parse(s)
		return a, 32, a_ok
	}

	a, a_ok := addr_parse(s[:slash])
	if !a_ok {
		return 0, 0, false
	}

	bits_str := s[slash + 1:]
	if len(bits_str) == 0 || len(bits_str) > 2 {
		return 0, 0, false
	}
	bits := 0
	for i in 0 ..< len(bits_str) {
		if bits_str[i] < '0' || bits_str[i] > '9' {
			return 0, 0, false
		}
		bits = bits * 10 + int(bits_str[i] - '0')
	}
	if bits > 32 {
		return 0, 0, false
	}
	return a, u8(bits), true
}

host_account :: proc(h: ^Host, username: string) -> (^Account, bool) {
	for &a in h.accounts {
		if a.username == username {
			return &a, true
		}
	}
	return nil, false
}
