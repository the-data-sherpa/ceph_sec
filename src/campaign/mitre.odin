package campaign

// MITRE ATT&CK, as the curriculum's skeleton.
//
// Using a real framework rather than an invented one buys three things: the
// ordering of the tactics is already the shape of an engagement, the vocabulary
// is what the industry actually uses, and a player who finishes the campaign has
// covered something nameable rather than "our levels 1 to 60".
//
// The catalogue here is deliberately partial. ATT&CK is a taxonomy of observed
// adversary behaviour, not a syllabus, and some of it does not survive contact
// with a simulation -- most of Resource Development is about infrastructure the
// player never models, and much of Impact is destructive in ways this game will
// not teach. Covering a subset honestly beats claiming the whole matrix.

// The tactics, in kill-chain order. That order is the campaign's spine: a tactic
// block's levels come after the blocks it depends on.
Tactic :: enum u8 {
	Reconnaissance,
	Resource_Development,
	Initial_Access,
	Execution,
	Persistence,
	Privilege_Escalation,
	Defense_Evasion,
	Credential_Access,
	Discovery,
	Lateral_Movement,
	Collection,
	Command_And_Control,
	Exfiltration,
	Impact,
}

tactic_name :: proc(t: Tactic) -> string {
	switch t {
	case .Reconnaissance:
		return "Reconnaissance"
	case .Resource_Development:
		return "Resource Development"
	case .Initial_Access:
		return "Initial Access"
	case .Execution:
		return "Execution"
	case .Persistence:
		return "Persistence"
	case .Privilege_Escalation:
		return "Privilege Escalation"
	case .Defense_Evasion:
		return "Defense Evasion"
	case .Credential_Access:
		return "Credential Access"
	case .Discovery:
		return "Discovery"
	case .Lateral_Movement:
		return "Lateral Movement"
	case .Collection:
		return "Collection"
	case .Command_And_Control:
		return "Command and Control"
	case .Exfiltration:
		return "Exfiltration"
	case .Impact:
		return "Impact"
	}
	return "?"
}

// Short enough for a 62-column pane; used by the `techniques` coverage table.
tactic_short :: proc(t: Tactic) -> string {
	switch t {
	case .Reconnaissance:
		return "Recon"
	case .Resource_Development:
		return "Resource Dev"
	case .Initial_Access:
		return "Initial Access"
	case .Execution:
		return "Execution"
	case .Persistence:
		return "Persistence"
	case .Privilege_Escalation:
		return "Priv Esc"
	case .Defense_Evasion:
		return "Defense Evasion"
	case .Credential_Access:
		return "Cred Access"
	case .Discovery:
		return "Discovery"
	case .Lateral_Movement:
		return "Lateral Move"
	case .Collection:
		return "Collection"
	case .Command_And_Control:
		return "C2"
	case .Exfiltration:
		return "Exfiltration"
	case .Impact:
		return "Impact"
	}
	return "?"
}

Technique :: struct {
	id:     string, // the real ATT&CK id, e.g. "T1595.001"
	name:   string, // the real ATT&CK name
	tactic: Tactic,
}

// Techniques the campaign currently teaches. Levels reference these by value so
// a typo in an id is a compile error at the level rather than a wrong string
// shown to a player.
//
// Names and ids are verbatim from ATT&CK. If one is wrong here it is wrong
// everywhere it appears, which is the point of a single catalogue.
T1595_001 :: Technique{"T1595.001", "Scanning IP Blocks", .Reconnaissance}
T1595_002 :: Technique{"T1595.002", "Vulnerability Scanning", .Reconnaissance}
T1592_002 :: Technique{"T1592.002", "Gather Victim Host Information: Software", .Reconnaissance}
T1594 :: Technique{"T1594", "Search Victim-Owned Websites", .Reconnaissance}
T1552_001 :: Technique{"T1552.001", "Unsecured Credentials: Credentials In Files", .Credential_Access}
T1078_003 :: Technique{"T1078.003", "Valid Accounts: Local Accounts", .Lateral_Movement}
T1021_004 :: Technique{"T1021.004", "Remote Services: SSH", .Lateral_Movement}
T1005 :: Technique{"T1005", "Data from Local System", .Collection}

// Every technique the campaign knows about, for coverage reporting. A level may
// only teach techniques listed here, which the validator enforces -- otherwise
// coverage would silently under-count.
CATALOGUE := []Technique {
	T1595_001,
	T1595_002,
	T1592_002,
	T1594,
	T1552_001,
	T1078_003,
	T1021_004,
	T1005,
}

// How many techniques the catalogue holds for a tactic, and how many the player
// has covered. Coverage is per-technique rather than per-level, because two
// levels may teach the same technique from different angles.
coverage :: proc(t: Tactic, covered: []string) -> (have: int, total: int) {
	for tech in CATALOGUE {
		if tech.tactic != t {
			continue
		}
		total += 1
		for id in covered {
			if id == tech.id {
				have += 1
				break
			}
		}
	}
	return
}

technique_by_id :: proc(id: string) -> (Technique, bool) {
	for t in CATALOGUE {
		if t.id == id {
			return t, true
		}
	}
	return {}, false
}
