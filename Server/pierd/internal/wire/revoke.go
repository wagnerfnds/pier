package wire

import (
	"context"
	"net"
	"sync"
	"time"

	"pier/pierd/internal/identity"
)

type connKey struct{}

// openConns tracks the requests in flight for each paired key, with the
// connection each arrived on.
type openConns struct {
	mu   sync.Mutex
	byFP map[identity.Fingerprint]map[*openReq]struct{}
}

type openReq struct {
	conn   net.Conn
	cancel context.CancelFunc
}

func (o *openConns) add(fp identity.Fingerprint, conn net.Conn, cancel context.CancelFunc) func() {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.byFP == nil {
		o.byFP = map[identity.Fingerprint]map[*openReq]struct{}{}
	}
	req := &openReq{conn: conn, cancel: cancel}
	if o.byFP[fp] == nil {
		o.byFP[fp] = map[*openReq]struct{}{}
	}
	o.byFP[fp][req] = struct{}{}
	return func() {
		o.mu.Lock()
		defer o.mu.Unlock()
		delete(o.byFP[fp], req)
		if len(o.byFP[fp]) == 0 {
			delete(o.byFP, fp)
		}
	}
}

func (o *openConns) keys() []identity.Fingerprint {
	o.mu.Lock()
	defer o.mu.Unlock()
	out := make([]identity.Fingerprint, 0, len(o.byFP))
	for fp := range o.byFP {
		out = append(out, fp)
	}
	return out
}

// cut ends every request fp has open and closes the connections they came
// on, which ends any other stream sharing them.
func (o *openConns) cut(fp identity.Fingerprint) int {
	o.mu.Lock()
	reqs := o.byFP[fp]
	delete(o.byFP, fp)
	o.mu.Unlock()
	for r := range reqs {
		r.cancel()
		if r.conn != nil {
			r.conn.Close()
		}
	}
	return len(reqs)
}

// ClientsChanged asks the server to re-check open connections against the
// trust store now rather than at its next look.
func (s *Server) ClientsChanged() {
	s.init()
	select {
	case s.recheck <- struct{}{}:
	default:
	}
}

// watchRevocations re-checks the keys holding open requests against the
// trust store and cuts off any that were revoked (pierd revoke edits the
// store from another process, so the daemon looks rather than waits to be
// told). A store that cannot be read is not taken as a revocation: new
// requests already fail closed, and dropping every shell over a transient
// read error would do more harm than good.
func (s *Server) watchRevocations(ctx context.Context) {
	every := s.RevokeCheck
	if every <= 0 {
		every = time.Second
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-s.recheck:
		}
		for _, fp := range s.open.keys() {
			if _, ok, err := s.Clients.Trusted(fp); err == nil && !ok {
				if n := s.open.cut(fp); n > 0 {
					s.logf("closed %d open request(s) from revoked client %s", n, fp.Short())
				}
			}
		}
	}
}
