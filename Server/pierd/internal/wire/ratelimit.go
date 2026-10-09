package wire

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// limiter is a token bucket. Pairing codes cannot be guessed, so this exists
// only to bound the work an unauthenticated peer can make the box do.
type limiter struct {
	mu     sync.Mutex
	rate   float64 // tokens per second
	burst  float64
	tokens float64
	last   time.Time
}

func newLimiter(perMinute, burst int) *limiter {
	return &limiter{rate: float64(perMinute) / 60, burst: float64(burst), tokens: float64(burst)}
}

func (l *limiter) allow(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fill(now)
	if l.tokens < 1 {
		return false
	}
	l.tokens--
	return true
}

func (l *limiter) fill(now time.Time) {
	if !l.last.IsZero() {
		l.tokens = min(l.burst, l.tokens+now.Sub(l.last).Seconds()*l.rate)
	}
	l.last = now
}

// refund gives back a token spent on an attempt that succeeded.
func (l *limiter) refund() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.tokens = min(l.burst, l.tokens+1)
}

// full reports whether the bucket has refilled, so it can be forgotten.
func (l *limiter) full(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fill(now)
	return l.tokens >= l.burst
}

// pairLimiter gives each source address its own budget, with a larger global
// one behind them, so one noisy peer cannot keep the owner from pairing.
// Attempts are charged up front and refunded when they succeed: only
// failures count.
type pairLimiter struct {
	mu       sync.Mutex
	perIP    map[string]*limiter
	global   *limiter
	perMin   int
	burst    int
	maxPeers int
}

func newPairLimiter() *pairLimiter {
	return &pairLimiter{perIP: map[string]*limiter{}, global: newLimiter(60, 30), perMin: 10, burst: 10, maxPeers: 4096}
}

func (p *pairLimiter) allow(src string, now time.Time) bool {
	p.mu.Lock()
	l := p.perIP[src]
	if l == nil {
		if len(p.perIP) >= p.maxPeers {
			for k, v := range p.perIP {
				if v.full(now) {
					delete(p.perIP, k)
				}
			}
		}
		if len(p.perIP) >= p.maxPeers {
			p.mu.Unlock()
			return false
		}
		l = newLimiter(p.perMin, p.burst)
		p.perIP[src] = l
	}
	p.mu.Unlock()
	if !l.allow(now) {
		return false
	}
	if !p.global.allow(now) {
		l.refund()
		return false
	}
	return true
}

func (p *pairLimiter) refund(src string) {
	p.mu.Lock()
	l := p.perIP[src]
	p.mu.Unlock()
	if l != nil {
		l.refund()
	}
	p.global.refund()
}

func remoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
