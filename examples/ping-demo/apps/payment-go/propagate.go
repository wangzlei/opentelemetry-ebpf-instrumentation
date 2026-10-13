package main

// Which status a caller adopts when one of its dependencies failed -- port of app/propagate.py.

const (
	throttle         = 429
	fault            = 500
	failureThreshold = 400
)

// worstStatus: 0 means "no dependency failed" (Python None). An entry of 0 is a call that was not
// made or got no response, and is not a failure. A fault outranks a throttle; a throttle wins only
// when every failure was a throttle.
func worstStatus(statuses ...int) int {
	failures, throttles := 0, 0
	for _, s := range statuses {
		if s >= failureThreshold {
			failures++
			if s == throttle {
				throttles++
			}
		}
	}
	switch {
	case failures == 0:
		return 0
	case failures == throttles:
		return throttle
	default:
		return fault
	}
}
