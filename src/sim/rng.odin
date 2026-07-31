package sim

// PCG32 (XSH-RR variant), implemented here rather than pulled from
// core:math/rand.
//
// A roguelike promises that a seed reproduces a run -- shared seeds, bug
// reports, daily challenges, replays. core:math/rand is explicitly allowed to
// change its underlying algorithm between Odin releases, which would silently
// invalidate every seed ever shared without breaking a single build. Owning
// ~40 lines makes that guarantee permanent and costs nothing.
//
// Not cryptographic, and not trying to be. Statistically solid and fast is the
// entire requirement.
//
// AN HONEST NOTE ON SEEDS. Nothing outside this file draws from it. All five
// levels are hand-authored, so today two different seeds produce byte-identical
// runs and a shared seed communicates nothing. A replay records the seed anyway,
// because it costs a hex number and because the guarantee above is the sort that
// has to be in place before it is needed rather than after -- but "same seed,
// same run" is currently true in the uninteresting direction, and no part of
// this project should claim otherwise until something actually rolls.

Rng :: struct {
	state: u64,
	inc:   u64, // must always be odd
}

PCG_MULT :: 6364136223846793005
DEFAULT_STREAM :: 0xda3e39cb94b95bdb

rng_seed :: proc(seed: u64, stream: u64 = DEFAULT_STREAM) -> Rng {
	r: Rng
	r.state = 0
	r.inc = (stream << 1) | 1
	_ = rng_u32(&r)
	r.state += seed
	_ = rng_u32(&r)
	return r
}

rng_u32 :: proc(r: ^Rng) -> u32 {
	old := r.state
	r.state = old * PCG_MULT + r.inc

	// Output function: xorshift the high bits down, then rotate by an amount
	// taken from bits the xorshift didn't consume.
	xorshifted := u32(((old >> 18) ~ old) >> 27)
	rot := u32(old >> 59)
	return (xorshifted >> rot) | (xorshifted << ((32 - rot) & 31))
}

rng_u64 :: proc(r: ^Rng) -> u64 {
	hi := u64(rng_u32(r))
	lo := u64(rng_u32(r))
	return (hi << 32) | lo
}

// Uniform in [0, bound). Rejection-sampled, so no modulo bias -- with a small
// bound the bias would otherwise be invisible in testing and skew generation.
rng_below :: proc(r: ^Rng, bound: u32) -> u32 {
	if bound == 0 {
		return 0
	}
	threshold := u32(((u64(1) << 32) - u64(bound)) % u64(bound))
	for {
		v := rng_u32(r)
		if v >= threshold {
			return v % bound
		}
	}
}

// Uniform in [lo, hi]. Returns lo if the range is inverted.
rng_range :: proc(r: ^Rng, lo, hi: int) -> int {
	if hi <= lo {
		return lo
	}
	return lo + int(rng_below(r, u32(hi - lo + 1)))
}

// Uniform in [0, 1).
rng_f32 :: proc(r: ^Rng) -> f32 {
	return f32(rng_u32(r) >> 8) * (1.0 / f32(1 << 24))
}

rng_f32_range :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	return lo + rng_f32(r) * (hi - lo)
}

// True with probability `chance` (clamped to [0, 1]).
rng_chance :: proc(r: ^Rng, chance: f32) -> bool {
	if chance <= 0 {
		return false
	}
	if chance >= 1 {
		return true
	}
	return rng_f32(r) < chance
}

rng_pick :: proc(r: ^Rng, items: []$T) -> T {
	return items[rng_below(r, u32(len(items)))]
}

// In-place Fisher-Yates.
rng_shuffle :: proc(r: ^Rng, items: []$T) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := int(rng_below(r, u32(i + 1)))
		items[i], items[j] = items[j], items[i]
	}
}
