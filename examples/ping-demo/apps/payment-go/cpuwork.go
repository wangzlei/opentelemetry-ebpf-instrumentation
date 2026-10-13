package main

// Real CPU work for the response time -- port of app/cpuwork.py.
//
// The compute is bounded by CPU time this OS thread consumed (CLOCK_THREAD_CPUTIME_ID), never by
// wall clock, so the same budget takes proportionally longer when something else on the host wants
// the core. The goroutine is locked to its OS thread for the duration so the thread clock measures
// exactly this request's work.

import (
	"crypto/pbkdf2"
	"crypto/sha256"
	"math"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	chunkIterations       = 512 // pbkdf2 iterations per pass, as in cpuwork.py
	defaultWallCapSeconds = 3.0 // wall-clock ceiling on one compute, as in cpuwork.py
	clockThreadCPUTimeID  = 3   // CLOCK_THREAD_CPUTIME_ID
	hashPassword          = "obi-ping-demo-cpu-work"
	hashSaltString        = "obi-ping-demo-salt"
)

var hashSalt = []byte(hashSaltString)

type cpuSpend struct {
	cpuSeconds, wallSeconds float64
	capped                  bool
}

func threadCPUSeconds() float64 {
	var ts syscall.Timespec
	syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockThreadCPUTimeID, uintptr(unsafe.Pointer(&ts)), 0)
	return float64(ts.Sec) + float64(ts.Nsec)/1e9
}

func burnChunk() {
	_, _ = pbkdf2.Key(sha256.New, hashPassword, hashSalt, chunkIterations, sha256.Size)
}

// spendCPU occupies a core until this thread has consumed budget seconds of CPU, or the wall cap.
func spendCPU(budget, wallCap float64) cpuSpend {
	if budget <= 0 {
		return cpuSpend{}
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	cpuStart := threadCPUSeconds()
	wallStart := time.Now()
	for {
		cpu := threadCPUSeconds() - cpuStart
		wall := time.Since(wallStart).Seconds()
		if cpu >= budget {
			return cpuSpend{cpu, wall, false}
		}
		if wall >= wallCap {
			return cpuSpend{cpu, wall, true}
		}
		burnChunk()
	}
}

// splitDuration divides a target duration into a CPU budget and a sleep, both fixed proportions.
func splitDuration(target, share float64) (cpuBudget, sleep float64) {
	target = math.Max(0, target)
	return target * share, target * (1 - share)
}

// resolveShare coerces an operator-supplied share to [0,1]; anything unparseable or non-finite is 0.
func resolveShare(s string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return math.Min(1, math.Max(0, v))
}
