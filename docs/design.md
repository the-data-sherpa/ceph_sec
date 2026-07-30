# Ceph.Sec — systems design

The reference the remaining milestones build toward. Entries marked ✅ are
implemented; everything else is intent, not implementation.

**Ceph.Sec is a learning game.** It is structured as a campaign of ~60 levels
following MITRE ATT&CK, each teaching a technique and unlocking what it taught.
Sections 1-7 describe the systems; section 11 describes the curriculum those
systems exist to carry.

Noise values marked ✅ are the tuned figures actually in use; the rest are
targets for tools that do not exist yet.

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

**Every level teaches something nameable.** Not "you finished it" but "you
performed T1078.003, this is why it works, this is how it is stopped". The
debrief is the payload; the level is how the payload is earned.

**Levels are short and repeatable.** Failing and immediately retrying is the
learning loop, which is why `retry` matters more here than a save file does.

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

## 3. Level structure

```
brief → insertion → recon → enumerate → exploit → pivot ─┐
                              ▲                          │
                              └──────────────────────────┘
                                                    collect → exfil → extract
```

You start with a foothold: a rented VPS, a phished workstation, a misconfigured
edge device. The brief names an objective — a file, a database, a credential
set, or persistence itself.

A level ends when its objectives are met (and the debrief explains what you just
did), or the trace completes (caught). "Stranded" — no path to the objective
remains — is deliberately not detected: deciding that correctly needs an
attack-graph prover, and a heuristic would lie at the worst possible moment.
Levels are instead built so it cannot arise.

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

## 5. Trace and detection ✅

Two coupled numbers. Implemented in `src/sim/trace.odin`; every quantity is an
integer in hundredths, because a float here would put the determinism guarantee
at the mercy of the optimiser.

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
| 25% | log review — every segment you have been noisy in raises its monitoring one step, so everything you do from here costs more |
| 50% | alert — you are kicked off the box you hold in the hottest segment, and *that host's* passwords rotate |
| 75% | active hunt — a defender takes one foothold every 20s, newest first, and never your own box |
| 100% | attribution — run over |

**The 50% response is deliberately narrow.** Rotating "the credential you are
relying on" would, in a scenario where one reused password *is* the attack path,
make the objective permanently unreachable — silently, with no `Stranded`
outcome to detect it. Rewriting passwords on a box you already hold cannot brick
anything: the credential still opens everything you have not reached, and you
route around the loss.

**Tuned figures.** Alarm line 60.00; suspicion decays 1.20/s after 5s of quiet;
excess above the line converts to trace at `excess / 2048` per tick. A segment
held at 80.00 burns a run in under three minutes; one at 62.00 takes nearly half
an hour. A *burst* of noise is survivable — decay pulls you back under within
seconds — but the trace it bought never comes back, so bursts accumulate.

**Being caught is always attributable, mechanically.** The trace cannot rise
while every segment is below the alarm line, so a lost run always traces back to
a named segment that sat visibly over a visible line for a recorded number of
seconds. The end-of-run debrief prints exactly that, along with the loudest
charges and the command lines responsible. There is a test asserting that ten
simulated minutes of sub-threshold noise leaves the trace at exactly zero.

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
| `nmap -sV -T2` ✅ | same, ~3.5x slower for a third of the noise | ~18s | 7 |
| `tcpdump` | passive; yields creds/hosts over time | passive | 0 |
| `arp -a` | neighbours, from a held host | 1s | 1 |

`tcpdump` is the thesis in one tool: free, silent, and it makes you wait.

### Enumeration

| Tool | Effect | Time | Noise |
| --- | --- | --- | --- |
| `curl` ✅ | fetch a page or file from a web root | 1.1s | 10 / 20 failed |
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
| `cat` (sensitive) ✅ | file auditing on material that matters | 0s | 6 | user |
| `mimikatz` | dump credentials from memory | 5s | 40 | SYSTEM |
| `hashcat` | crack dumped hashes — **offline** | 60s+ | 0 | — |
| `linpeas` | local privesc paths | 10s | 8 | user |
| `ssh -L` | pivot tunnel through a held host | 3s | 4 | user |
| `scp` | exfiltrate — noise scales with volume | by size | 15+ | user |
| `shred` | clear logs; lowers suspicion, risks a tripwire | 4s | 30 | root |

`shred` is deliberately a gamble: it is the only way down from a bad suspicion
number, and it can make things worse.

---

## 7. Jobs ✅

Anything slow is a **Job**: it occupies a slot, reports progress, streams output
into the terminal as it goes, and can be backgrounded or killed. The prompt
stays live throughout. Concurrent slots start at 2 and are a meta-progression
upgrade.

This is where real-time earns its place — deciding what to run *while* the
hydra job grinds is the moment-to-moment game. Jobs are scheduled in ticks
against the sim clock, so none of it costs determinism.

Implemented in `src/shell/job.odin`. A job's identity is the timer tag the
scheduler has grouped output under since M0, so `kill %1` and `^C` are a single
`cancel_tag` call. Its *liveness* is a pure function of `w.now` rather than a
latched flag — a latch would make "is the prompt free at tick T" depend on where
the frame boundaries fell, which would silently break reproducibility. A test
drives an identical session one tick at a time and seven ticks at a time and
requires byte-identical output.

**Noise is charged at dispatch, in full, and never refunded.** The packets left
when you pressed Enter. It also removes "start everything loud, watch the meter,
kill what looks bad" as a strategy: cancelling buys back time and a slot, not
attention. `kill` says so the first time you use it.

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

## 9. Progression ✅

Progression is the curriculum, not a meta-game.

- **Tools** unlock by completing the level that teaches them. `ssh` is
  unavailable until level 4, and `help` says so rather than hiding it — seeing
  what is coming is part of the teaching.
- **Levels** unlock through a prerequisite graph, validated acyclic at build.
- **Coverage** is tracked per ATT&CK technique, shown by `techniques`.

A level declares its *available* tools separately from what it *grants*, so a
later level can withhold something you own — "you have `ssh`, but 22 is filtered
here" — which is how difficulty grows without inventing new mechanics.

Not carried: access, credentials, world state. Every level starts cold.

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

---

## 11. The curriculum ✅

Levels follow ATT&CK's tactics in kill-chain order, in blocks of roughly four:

    teach  →  teach  →  apply  →  combine

The **combine** levels are what stop the campaign reading as a syllabus. They
demand techniques from earlier blocks with nothing saying which, and they are
where the game stops testing recall and starts testing judgement.

**Techniques are not tools.** T1078 *Valid Accounts* and T1110 *Brute Force*
both yield credentials and both may use `ssh`. Across ~60 levels only 15–20
grant a new command; the rest teach a technique, an application, or a
combination using what the player already holds. A design that granted one tool
per level would need sixty tools and teach almost nothing.

### What keeps 60 levels honest

Authored content rots the same way generated content does — it just rots when
someone edits it rather than when the RNG rolls badly. Two test suites stand in
for the attack-graph prover that procedural generation would have needed:

- **The validator** (`tests/campaign_test.odin`) proves the prerequisite graph
  is acyclic, that no level offers a tool its prerequisites cannot have granted,
  that every granted tool is a real command granted exactly once, and — by
  building each level — that every objective points at something that exists.
- **The playthroughs** (`tests/playthrough_test.odin`) finish every level using
  only that level's own tools. A level that stops being winnable fails there,
  rather than in front of someone who cannot tell whether it is them or the game.

Each level's walkthrough doubles as its reference solution, so a design change
shows up as a failing test with the objective named.

### The honest limits

ATT&CK is a taxonomy of observed adversary behaviour, not a syllabus. Much of
Resource Development concerns infrastructure this game does not model, and much
of Impact is destructive in ways it will not teach. The campaign covers a subset
deliberately, and `techniques` reports coverage against the catalogue it
actually implements rather than against the whole matrix.
