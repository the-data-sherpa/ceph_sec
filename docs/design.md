# Ceph.Sec — systems design

The reference the remaining milestones build toward. Entries marked ✅ are
implemented; everything else is intent, not implementation.

Noise values are documented targets — the trace system that consumes them
arrives in M2, so nothing charges for noise yet.

---

## 1. Pillars

**Real workflow, fake targets.** The loop is the actual one — recon, enumerate,
exploit, pivot, collect, exfil — and the tools carry their real names and
plausible flags. What they act on is a simulation. Someone who plays a lot of
Ceph.Sec should recognise the shape of a real engagement, and should have
learned nothing that helps them attack anything.

**Noise is the currency.** Every action buys information or access, and pays in
suspicion. There is nearly always a loud fast option and a quiet slow one. The
game is that choice, repeated under a clock.

**Segmentation makes the map.** A flat network has no decisions in it — you'd
just hit the weakest host and win. Reaching what you want means getting from the
segment you landed in to the segment that holds it.

**Runs are short and lossy.** 15–40 minutes. You lose runs. What persists is
your toolkit and what you learned.

---

## 2. Setting

You are a contractor. Jobs arrive as briefs from clients whose motives you can
mostly guess: a competitor's document, a journalist's source list to *protect*,
proof that an industrial site is negligently exposed. Targets are archetypes —
regional hospital, water utility, fintech startup, university, logistics firm —
each with a characteristic topology and monitoring posture.

Ceph is the fixer who routes the work. Ceph is not on your side; Ceph is on the
side of the work continuing.

---

## 3. Run structure

```
brief → insertion → recon → enumerate → exploit → pivot ─┐
                              ▲                          │
                              └──────────────────────────┘
                                                    collect → exfil → extract
```

You start with a foothold: a rented VPS, a phished workstation, a misconfigured
edge device. The brief names an objective — a file, a database, a credential
set, or persistence itself.

A run ends when you extract (win), the trace completes (caught), or you burn
your access and can no longer reach the objective (stranded — a real and
distinct failure, and the one worth designing carefully).

---

## 4. World model

### Hosts, services, versions

A host has services; a service has a `product` and `version`. That pair is the
hinge the entire game turns on: vulnerability matching, exploit applicability
and the whole point of `-sV` version detection all key on it. Getting a version
string is real progress, and it costs noise to get.

### Vulnerabilities

A `Vuln` binds to a `(product, version range)` and carries a class — RCE, auth
bypass, path traversal, deserialization, default creds — plus a difficulty and
a noise floor. Generation attaches vulns to services; `searchsploit` reveals
which of the versions you've seen have known issues, offline and free.

### Credentials and reuse

Accounts hold a plaintext password and a hash. Dumping yields hashes; cracking
yields plaintext; and **credentials are reused across hosts**. Password reuse is
the single most important lateral-movement mechanic in reality and it should be
the same here. A cracked domain admin password from a forgotten dev box opening
half the estate is the game's best moment, and it's what actually happens.

### Segments and pivots

Hosts live in subnets. Subnets connect via `Link`s, each traversable only from a
host you already hold at a stated access level. Reachability is computed live
from current access rather than cached, so losing a jump box immediately severs
everything behind it — no invalidation logic to forget.

Monitoring posture varies by segment, and inversely with how interesting the
segment is:

| Segment | Monitoring | Character |
| --- | --- | --- |
| DMZ | low | internet-facing, patched unevenly, loud is survivable |
| CORP | medium | workstations, file shares, where the credentials live |
| OT / clinical | high | flat, ancient, unpatchable, and *watched* |
| MGMT | very high | jump boxes, hypervisors, backups — the crown jewels |

The recurring shape: the easiest boxes to break are the least worth breaking,
and the segment you need is the one that notices you.

---

## 5. Trace and detection

Two coupled numbers.

**Suspicion** is per-segment and rises with the noise of actions taken inside
it, scaled by that segment's monitoring. It decays while you're quiet. Failed
attempts are far louder than successful ones — a failed SSH login is a log line,
a successful one is just a login.

**Trace** is global and only ever rises. It advances when a segment's suspicion
crosses a threshold, and once it moves it does not come back. Trace is the run
clock: at 100% the engagement is over.

Escalating defender responses, so pressure is felt before it's fatal:

| Trace | Response |
| --- | --- |
| 25% | log review — recent noisy actions get re-examined; some hosts harden |
| 50% | alert — credentials rotate, sessions start dropping |
| 75% | active hunt — a defender walks the network, killing footholds |
| 100% | attribution — run over |

**Corollary that makes offline work valuable:** cracking hashes, reading
captured traffic and `searchsploit` are *free*, because they don't touch the
target. Dumping the hashes was loud; cracking them is not. That asymmetry is
real, and it's where the patient playstyle lives.

---

## 6. Tools

Real names, real flags, simulated everything else. Times and noise are opening
values to tune, not commitments.

### Recon

| Tool | Effect | Time | Noise |
| --- | --- | --- | --- |
| `nmap -sn` ✅ | host discovery, no ports | 6s | 8 |
| `nmap -sV` ✅ | versions — the good stuff | 14s | 22 |
| `nmap -sS -T2` | same, slow and quiet | 50s | 6 |
| `tcpdump` | passive; yields creds/hosts over time | passive | 0 |
| `arp -a` | neighbours, from a held host | 1s | 1 |

`tcpdump` is the thesis in one tool: free, silent, and it makes you wait.

### Enumeration

| Tool | Effect | Time | Noise |
| --- | --- | --- | --- |
| `curl` ✅ | fetch a page or file from a web root | 1.1s | 10 |
| `gobuster` | web paths | 20s | 25 |
| `enum4linux` | SMB shares, users | 12s | 18 |
| `searchsploit` | vulns for seen versions — **offline** | 1s | 0 |
| `ldapsearch` | directory objects | 8s | 12 |

`curl` earns its place early because it is the only tool that yields anything
without a credential, and so is where a run starts. The M1 scenario turns on a
`.env` left in a document root and a leftover comment on the index page naming
it — two of the most common real findings there are, and between them the entry
point is *discoverable* rather than guessable.

### Access

| Tool | Effect | Time | Noise |
| --- | --- | --- | --- |
| `hydra` | credential brute force | 30–90s | 45 |
| `sqlmap` | injection → data or shell | 25s | 30 |
| `msfconsole` | exploit a matched vuln | 8s | 35 |
| `ssh` ✅ | log in with creds you hold | 2s | 5 / 20 failed |

### Post-exploitation

| Tool | Effect | Time | Noise | Requires |
| --- | --- | --- | --- | --- |
| `mimikatz` | dump credentials from memory | 5s | 40 | SYSTEM |
| `hashcat` | crack dumped hashes — **offline** | 60s+ | 0 | — |
| `linpeas` | local privesc paths | 10s | 8 | user |
| `ssh -L` | pivot tunnel through a held host | 3s | 4 | user |
| `scp` | exfiltrate — noise scales with volume | by size | 15+ | user |
| `shred` | clear logs; lowers suspicion, risks a tripwire | 4s | 30 | root |

`shred` is deliberately a gamble: it is the only way down from a bad suspicion
number, and it can make things worse.

---

## 7. Jobs

Anything slow is a **Job**: it occupies a slot, reports progress, streams output
into the terminal as it goes, and can be backgrounded or killed. The prompt
stays live throughout. Concurrent slots start at 2 and are a meta-progression
upgrade.

This is where real-time earns its place — deciding what to run *while* the
hydra job grinds is the moment-to-moment game. Jobs are scheduled in ticks
against the sim clock, so none of it costs determinism.

---

## 8. Generation

Per run: pick an archetype → lay out segments → populate hosts and services from
the archetype's software distribution → attach vulns → place credentials with a
reuse graph → place the objective → cut links.

**Then prove it's winnable.** Build the attack graph — nodes are
(host, access level), edges are actions the player's current toolkit can perform
— and BFS from the insertion point to the objective. No path, regenerate.

This is the part worth building carefully. Without it, procedural generation
eventually hands someone an unwinnable run and they will (correctly) conclude
the game is broken. The solver also gives us difficulty for free: the length of
the shortest path, and the total noise along it, are what "hard" actually means.

Generation must also guarantee a *quiet* path exists, not merely a path. A run
solvable only by brute-forcing everything is a run the trace wins by design.

---

## 9. Meta-progression

Runs are short and lossy, so something has to carry across them.

- **Tools** — the roster above unlocks over time; early runs are deliberately
  under-equipped
- **Hardware** — more job slots, faster cracking, bigger wordlists
- **Intel** — recurring clients mean partial maps of networks you've hit before
- **Reputation** — gates which briefs you're offered

Explicitly *not* carried: access. Every run starts cold.

---

## 10. The authenticity boundary

Worth stating plainly, since it governs what gets built.

**Simulated faithfully:** the workflow and its order; tool names, flags and
output shapes; the service/version → vulnerability relationship; credential
reuse as the primary lateral path; segmentation and pivoting; the noise cost of
being fast; the fact that defenders respond.

**Not simulated at all:** any real network stack, any payload, shellcode or
exploit internals, any real CVE's mechanics, any real host or organisation.
Exploitation resolves as a dice roll against a vuln's difficulty. There is no
step where the game does something a real attack would do.

The distinction is enforced, not merely intended: `src/sim/` cannot import an
I/O, platform or vendor package, and `./build.sh gate` fails the build if that
ever changes. The simulation is incapable of reaching the network — not
configured not to, incapable.

What a player takes away is the *shape* of security work: why versions matter,
why password reuse is catastrophic, why segmentation is worth the pain, why
being loud loses. That's knowledge that helps defenders.
