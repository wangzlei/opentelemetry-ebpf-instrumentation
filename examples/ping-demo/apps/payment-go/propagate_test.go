package main

import "testing"

func TestWorstStatus(t *testing.T) {
	cases := []struct {
		in   []int
		want int
	}{
		{nil, 0}, {[]int{200, 200}, 0}, {[]int{0, 0}, 0}, {[]int{304}, 0},
		{[]int{500, 200}, 500}, {[]int{0, 503}, 500}, {[]int{404, 200}, 500},
		{[]int{500, 429}, 500}, {[]int{429, 404}, 500},
		{[]int{429, 200}, 429}, {[]int{429, 429}, 429},
	}
	for _, c := range cases {
		if got := worstStatus(c.in...); got != c.want {
			t.Errorf("worstStatus(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestResolveShare(t *testing.T) {
	for in, want := range map[string]float64{"0": 0, "0.25": 0.25, "2": 1, "-1": 0, "nan": 0, "inf": 0, "x": 0, " 0.5 ": 0.5} {
		if got := resolveShare(in); got != want {
			t.Errorf("resolveShare(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestSpendCPU(t *testing.T) {
	s := spendCPU(0.05, 3)
	if s.cpuSeconds < 0.05 || s.capped {
		t.Fatalf("spendCPU = %+v", s)
	}
	if b, sl := splitDuration(0.2, 0.25); b != 0.05 || sl != 0.15000000000000002 && sl != 0.15 {
		t.Fatalf("splitDuration = %v %v", b, sl)
	}
}
