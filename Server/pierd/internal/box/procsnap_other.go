//go:build !linux

package box

import "errors"

var errNoProcs = errors.New("reading other processes is not supported on this system")

func snapshotProcs() ([]procStat, error) { return nil, errNoProcs }
