package shell

import "../sim"

// What actions cost in attention.
//
// **Charged at dispatch, in full, and never refunded.** Three reasons, in order
// of how much they matter:
//
//  1. The packets left when you pressed Enter. A failed SSH is a line in their
//     auth log before your terminal has finished rendering the denial.
//  2. It removes "start everything loud, watch the meter, kill whatever looks
//     bad" as a strategy. Cancelling buys back time and a slot, not attention --
//     a real decision rather than a free undo.
//  3. It makes a whole class of bug impossible. Charging continuously across a
//     job's span means dividing by that span, and cmd_nmap sets its span twice
//     (a provisional estimate, then the authoritative correction once its output
//     is laid out). Every accrual figure would be wrong for the most-used tool
//     in the game. Dispatch-time charging never reads a span.
//
// Given up: a tool whose success resolves at *completion* has nowhere to file
// its charge. All three current tools resolve everything at dispatch, so
// nothing is lost today; when M3 needs mid-job resolution it gets a `charge_at`
// under the job tag, and that tool's noise becomes refundable-on-kill. That is
// a per-tool property, not a system-wide one.

CHARGES_MAX :: 4

Charge :: struct {
	subnet: sim.Handle(sim.Subnet),
	units:  int,
}

// Values transcribed once from docs/design.md section 6.
//
// Deliberately not a column on Command_Spec: nmap's cost varies with scan depth
// and curl's and ssh's vary with success, so a registry column would be a
// second source of truth that drifts from this one.
NOISE_NMAP_PING :: 8
NOISE_NMAP_PORTS :: 14
NOISE_NMAP_VERSION :: 22
NOISE_CURL :: 10
NOISE_CURL_FAILED :: 20 // a 404 or a refused connection is a line in their log
NOISE_SSH :: 5
NOISE_SSH_FAILED :: 20 // a failed login is a log line; a success is just a login
NOISE_READ_SENSITIVE :: 6 // file auditing on the material that matters

// -T2: roughly 3.5x the time for a third of the noise. The loud-fast versus
// quiet-slow choice, in one flag.
T2_TIME_NUM :: 7
T2_TIME_DEN :: 2
T2_NOISE_DIV :: 3

// Files a charge against the segment the host sits in.
//
// Deduped by segment, keeping the larger amount: an nmap sweeping three hosts
// in the DMZ pays for one scan of the DMZ, not three. Charging per host would
// make a /24 sweep instantly fatal and make the documented per-scan figures
// meaningless.
touched :: proc(s: ^Session, h: sim.Handle(sim.Host), units: int) {
	if units <= 0 {
		return
	}
	sn, ok := sim.subnet_of(s.world, h)
	if !ok {
		return
	}

	for i in 0 ..< s.charge_count {
		if s.charges[i].subnet == sn {
			s.charges[i].units = max(s.charges[i].units, units)
			return
		}
	}
	if s.charge_count >= CHARGES_MAX {
		return
	}
	s.charges[s.charge_count] = Charge {
		subnet = sn,
		units  = units,
	}
	s.charge_count += 1
}

// Files a charge against a segment directly, for tools that reason about a
// range rather than a specific host.
touched_subnet :: proc(s: ^Session, sn: sim.Handle(sim.Subnet), units: int) {
	if units <= 0 {
		return
	}
	for i in 0 ..< s.charge_count {
		if s.charges[i].subnet == sn {
			s.charges[i].units = max(s.charges[i].units, units)
			return
		}
	}
	if s.charge_count >= CHARGES_MAX {
		return
	}
	s.charges[s.charge_count] = Charge {
		subnet = sn,
		units  = units,
	}
	s.charge_count += 1
}

// Converts the slips filed during a dispatch into sim charges, and clears them.
// Called by session_exec once the tool has returned.
drain_charges :: proc(s: ^Session, source: string) {
	for i in 0 ..< s.charge_count {
		sim.noise(s.world, s.charges[i].subnet, s.charges[i].units, source)
	}
	s.charge_count = 0
}
