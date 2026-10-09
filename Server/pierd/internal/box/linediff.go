package box

import "strings"

// lineCounts is how many lines going from a to b adds and removes, as a
// line diff counts them: Myers' shortest edit script, after the lines both
// start and end with are set aside. A change too large to work out
// exactly (past maxEdit) is counted as the lines of each side the other
// lacks.
func lineCounts(a, b string) (added, removed int) {
	x, y := splitLines(a), splitLines(b)
	// The common start and end are no change.
	for len(x) > 0 && len(y) > 0 && x[0] == y[0] {
		x, y = x[1:], y[1:]
	}
	for len(x) > 0 && len(y) > 0 && x[len(x)-1] == y[len(y)-1] {
		x, y = x[:len(x)-1], y[:len(y)-1]
	}
	n, m := len(x), len(y)
	if n == 0 || m == 0 {
		return m, n
	}
	d, ok := editDistance(x, y, maxEdit)
	if !ok {
		return roughCounts(x, y)
	}
	// d = added + removed, and added − removed = m − n.
	return (d + m - n) / 2, (d - m + n) / 2
}

// maxEdit bounds the work of one count: (n+m)·maxEdit steps at most.
const maxEdit = 2000

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

// editDistance is the fewest lines to delete and insert to turn x into y
// (Myers 1986, the greedy forward search), or false past limit.
func editDistance(x, y []string, limit int) (int, bool) {
	n, m := len(x), len(y)
	maxD := min(n+m, limit)
	off := maxD + 1
	v := make([]int, 2*maxD+3)
	for d := 0; d <= maxD; d++ {
		for k := -d; k <= d; k += 2 {
			var i int
			if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
				i = v[off+k+1]
			} else {
				i = v[off+k-1] + 1
			}
			j := i - k
			for i < n && j < m && x[i] == y[j] {
				i, j = i+1, j+1
			}
			v[off+k] = i
			if i >= n && j >= m {
				return d, true
			}
		}
	}
	return 0, false
}

// roughCounts counts the lines of each side the other lacks, as multisets.
func roughCounts(x, y []string) (added, removed int) {
	have := map[string]int{}
	for _, l := range x {
		have[l]++
	}
	for _, l := range y {
		if have[l] > 0 {
			have[l]--
		} else {
			added++
		}
	}
	for _, c := range have {
		removed += c
	}
	return added, removed
}
