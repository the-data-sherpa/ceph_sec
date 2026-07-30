package sim

// The world advances in fixed discrete ticks and in no other way.
//
// The game is real-time with trace pressure, but real-time is a property of the
// *frontend*: it accumulates wall-clock delta and calls tick() the appropriate
// number of times. The sim itself never reads a clock. That is what makes a run
// reproducible from a seed, and what lets tests advance ten simulated minutes
// instantly.
//
// 60 Hz because it divides evenly into common refresh rates and gives trace/job
// timing sub-100ms resolution without the tick loop ever being hot.

TICK_HZ :: 60
TICK_DT :: 1.0 / f64(TICK_HZ)

// Ticks since the run began. Distinct so it can't be silently confused with a
// count, an index, or a duration in seconds.
Tick :: distinct u64

seconds :: proc(s: f64) -> Tick {
	if s <= 0 {
		return 0
	}
	return Tick(s * f64(TICK_HZ) + 0.5)
}

minutes :: proc(m: f64) -> Tick {
	return seconds(m * 60)
}

tick_seconds :: proc(t: Tick) -> f64 {
	return f64(t) * TICK_DT
}
