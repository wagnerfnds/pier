// Package qr draws pairing links as QR codes (ISO/IEC 18004), so `pierd pair`
// can be scanned straight off the terminal. Byte mode at error correction
// level L only: a screen is never smudged, and L keeps the code small.
package qr

import (
	"errors"
	"strings"
)

// Per version 1–40 at level L; index 0 is unused.
var (
	eccPerBlock = [41]int{0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30}
	numBlocks   = [41]int{0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25}
)

// Encode returns the QR code of data as rows of modules, true for dark,
// without the quiet zone.
func Encode(data []byte) ([][]bool, error) {
	version := 0
	for v := 1; v <= 40; v++ {
		if 4+countBits(v)+8*len(data) <= dataCodewords(v)*8 {
			version = v
			break
		}
	}
	if version == 0 {
		return nil, errors.New("qr: data too long")
	}
	s := newSymbol(version)
	s.drawCodewords(addECC(encodeData(data, version), version))
	best, lowest := 0, -1
	for mask := range 8 {
		s.applyMask(mask)
		s.drawFormat(mask)
		if p := s.penalty(); lowest < 0 || p < lowest {
			best, lowest = mask, p
		}
		s.applyMask(mask)
	}
	s.applyMask(best)
	s.drawFormat(best)
	return s.dark, nil
}

// Terminal draws modules two rows per line in half blocks, black on white
// whatever the terminal's colours, inside a quiet zone.
func Terminal(modules [][]bool) string {
	const quiet = 2
	size := len(modules)
	dark := func(x, y int) bool {
		x, y = x-quiet, y-quiet
		return x >= 0 && y >= 0 && x < size && y < size && modules[y][x]
	}
	var b strings.Builder
	for y := 0; y < size+2*quiet; y += 2 {
		b.WriteString("\x1b[30;107m")
		for x := range size + 2*quiet {
			switch top, bottom := dark(x, y), dark(x, y+1); {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString("\x1b[0m\n")
	}
	return b.String()
}

func countBits(version int) int {
	if version <= 9 {
		return 8
	}
	return 16
}

// rawCodewords is what a version holds once the function patterns are drawn.
func rawCodewords(v int) int {
	n := (16*v+128)*v + 64
	if v >= 2 {
		a := v/7 + 2
		n -= (25*a-10)*a - 55
		if v >= 7 {
			n -= 36
		}
	}
	return n / 8
}

func dataCodewords(v int) int { return rawCodewords(v) - eccPerBlock[v]*numBlocks[v] }

type bitWriter struct {
	bytes []byte
	n     int
}

func (w *bitWriter) write(value, bits int) {
	for i := bits - 1; i >= 0; i-- {
		if w.n%8 == 0 {
			w.bytes = append(w.bytes, 0)
		}
		if value>>i&1 == 1 {
			w.bytes[w.n/8] |= 0x80 >> (w.n % 8)
		}
		w.n++
	}
}

func encodeData(data []byte, version int) []byte {
	var w bitWriter
	w.write(0b0100, 4)
	w.write(len(data), countBits(version))
	for _, b := range data {
		w.write(int(b), 8)
	}
	capacity := dataCodewords(version)
	w.write(0, min(4, capacity*8-w.n))
	for pad := byte(0xEC); len(w.bytes) < capacity; pad ^= 0xEC ^ 0x11 {
		w.bytes = append(w.bytes, pad)
	}
	return w.bytes
}

// addECC splits data into the version's blocks, appends each block's
// Reed-Solomon codewords and interleaves them all.
func addECC(data []byte, v int) []byte {
	blocks, ecLen, raw := numBlocks[v], eccPerBlock[v], rawCodewords(v)
	short := raw/blocks - ecLen
	divisor := rsDivisor(ecLen)
	var datas, eccs [][]byte
	for i, k := 0, 0; i < blocks; i++ {
		n := short
		if i >= blocks-raw%blocks {
			n++
		}
		datas = append(datas, data[k:k+n])
		eccs = append(eccs, rsRemainder(data[k:k+n], divisor))
		k += n
	}
	out := make([]byte, 0, raw)
	for i := 0; i <= short; i++ {
		for _, d := range datas {
			if i < len(d) {
				out = append(out, d[i])
			}
		}
	}
	for i := range ecLen {
		for _, e := range eccs {
			out = append(out, e[i])
		}
	}
	return out
}

// gfMul multiplies in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
func gfMul(x, y byte) byte {
	z := 0
	for i := 7; i >= 0; i-- {
		z = z<<1 ^ (z>>7)*0x11D
		z ^= int(y>>i&1) * int(x)
	}
	return byte(z)
}

func rsDivisor(degree int) []byte {
	d := make([]byte, degree)
	d[degree-1] = 1
	root := byte(1)
	for range degree {
		for j := range d {
			d[j] = gfMul(d[j], root)
			if j+1 < degree {
				d[j] ^= d[j+1]
			}
		}
		root = gfMul(root, 2)
	}
	return d
}

func rsRemainder(data, divisor []byte) []byte {
	r := make([]byte, len(divisor))
	for _, b := range data {
		factor := b ^ r[0]
		copy(r, r[1:])
		r[len(r)-1] = 0
		for i := range r {
			r[i] ^= gfMul(divisor[i], factor)
		}
	}
	return r
}

// formatBits carries level L (01) and the mask, BCH-protected.
func formatBits(mask int) int {
	data := 1<<3 | mask
	rem := data
	for range 10 {
		rem = rem<<1 ^ (rem>>9)*0x537
	}
	return (data<<10 | rem) ^ 0x5412
}

func versionBits(v int) int {
	rem := v
	for range 12 {
		rem = rem<<1 ^ (rem>>11)*0x1F25
	}
	return v<<12 | rem
}

func alignmentPositions(v int) []int {
	if v == 1 {
		return nil
	}
	n := v/7 + 2
	step := (v*8 + n*3 + 5) / (n*4 - 4) * 2
	pos := make([]int, n)
	pos[0] = 6
	for i, p := n-1, 4*v+10; i > 0; i, p = i-1, p-step {
		pos[i] = p
	}
	return pos
}

type symbol struct {
	size           int
	dark, function [][]bool
}

func (s *symbol) set(x, y int, dark bool) {
	s.dark[y][x] = dark
	s.function[y][x] = true
}

func newSymbol(v int) *symbol {
	size := 4*v + 17
	s := &symbol{size: size, dark: make([][]bool, size), function: make([][]bool, size)}
	for i := range size {
		s.dark[i] = make([]bool, size)
		s.function[i] = make([]bool, size)
	}
	for i := range size {
		s.set(6, i, i%2 == 0)
		s.set(i, 6, i%2 == 0)
	}
	for _, c := range [][2]int{{3, 3}, {size - 4, 3}, {3, size - 4}} {
		for dy := -4; dy <= 4; dy++ {
			for dx := -4; dx <= 4; dx++ {
				if x, y := c[0]+dx, c[1]+dy; x >= 0 && y >= 0 && x < size && y < size {
					d := max(abs(dx), abs(dy))
					s.set(x, y, d != 2 && d != 4)
				}
			}
		}
	}
	pos := alignmentPositions(v)
	for i, y := range pos {
		for j, x := range pos {
			if i == 0 && j == 0 || i == 0 && j == len(pos)-1 || i == len(pos)-1 && j == 0 {
				continue // under a finder
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					s.set(x+dx, y+dy, max(abs(dx), abs(dy)) != 1)
				}
			}
		}
	}
	s.drawFormat(0) // reserves the format area; the real bits follow the mask
	if v >= 7 {
		bits := versionBits(v)
		for i := range 18 {
			a, b := size-11+i%3, i/3
			s.set(a, b, bits>>i&1 == 1)
			s.set(b, a, bits>>i&1 == 1)
		}
	}
	return s
}

func (s *symbol) drawFormat(mask int) {
	bits := formatBits(mask)
	bit := func(i int) bool { return bits>>i&1 == 1 }
	for i := range 6 {
		s.set(8, i, bit(i))
	}
	s.set(8, 7, bit(6))
	s.set(8, 8, bit(7))
	s.set(7, 8, bit(8))
	for i := 9; i < 15; i++ {
		s.set(14-i, 8, bit(i))
	}
	for i := range 8 {
		s.set(s.size-1-i, 8, bit(i))
	}
	for i := 8; i < 15; i++ {
		s.set(8, s.size-15+i, bit(i))
	}
	s.set(8, s.size-8, true)
}

// drawCodewords fills the data modules in two-column strips, zigzagging up
// and down from the bottom right and skipping the vertical timing column.
func (s *symbol) drawCodewords(codewords []byte) {
	i := 0
	for right := s.size - 1; right >= 1; right -= 2 {
		if right == 6 {
			right = 5
		}
		for vert := range s.size {
			for j := range 2 {
				x, y := right-j, vert
				if (right+1)&2 == 0 {
					y = s.size - 1 - vert
				}
				if !s.function[y][x] && i < len(codewords)*8 {
					s.dark[y][x] = codewords[i/8]>>(7-i%8)&1 == 1
					i++
				}
			}
		}
	}
}

// applyMask flips the data modules the mask selects; applying it twice undoes it.
func (s *symbol) applyMask(mask int) {
	for y := range s.size {
		for x := range s.size {
			var flip bool
			switch mask {
			case 0:
				flip = (x+y)%2 == 0
			case 1:
				flip = y%2 == 0
			case 2:
				flip = x%3 == 0
			case 3:
				flip = (x+y)%3 == 0
			case 4:
				flip = (x/3+y/2)%2 == 0
			case 5:
				flip = x*y%2+x*y%3 == 0
			case 6:
				flip = (x*y%2+x*y%3)%2 == 0
			case 7:
				flip = ((x+y)%2+x*y%3)%2 == 0
			}
			if !s.function[y][x] && flip {
				s.dark[y][x] = !s.dark[y][x]
			}
		}
	}
}

func (s *symbol) penalty() int {
	p, dark := 0, 0
	col := make([]bool, s.size)
	for i := range s.size {
		for j := range s.size {
			col[j] = s.dark[j][i]
			if s.dark[i][j] {
				dark++
			}
		}
		p += linePenalty(s.dark[i]) + linePenalty(col)
	}
	for y := range s.size - 1 {
		for x := range s.size - 1 {
			if c := s.dark[y][x]; c == s.dark[y][x+1] && c == s.dark[y+1][x] && c == s.dark[y+1][x+1] {
				p += 3
			}
		}
	}
	total := s.size * s.size
	return p + abs(2*dark-total)*10/total*10
}

// linePenalty scores a row or column: runs of five or more of one colour, and
// finder-like 1:1:3:1:1 patterns beside four light modules.
func linePenalty(line []bool) int {
	p, run := 0, 1
	for i := 1; i <= len(line); i++ {
		if i < len(line) && line[i] == line[i-1] {
			run++
			continue
		}
		if run >= 5 {
			p += run - 2
		}
		run = 1
	}
	for i := 0; i+7 <= len(line); i++ {
		if line[i] && !line[i+1] && line[i+2] && line[i+3] && line[i+4] && !line[i+5] && line[i+6] &&
			(light(line, i-4, i) || light(line, i+7, i+11)) {
			p += 40
		}
	}
	return p
}

func light(line []bool, from, to int) bool {
	for i := max(from, 0); i < min(to, len(line)); i++ {
		if line[i] {
			return false
		}
	}
	return true
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}
