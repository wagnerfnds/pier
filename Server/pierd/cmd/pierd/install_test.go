package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestChooseListen(t *testing.T) {
	tailnet := ips("10.0.0.5", "100.101.102.103")
	for _, tc := range []struct {
		name, flag, current string
		keep                bool
		ips                 []net.IP
		want                string
		wantErr             bool
	}{
		{name: "the tailnet address by default", ips: tailnet, want: "100.101.102.103:7444"},
		{name: "--listen wins", flag: "0.0.0.0:7444", ips: tailnet, current: "10.0.0.5:7444", keep: true, want: "0.0.0.0:7444"},
		{name: "an upgrade keeps an address chosen before", keep: true, current: "0.0.0.0:7444", ips: tailnet, want: "0.0.0.0:7444"},
		{name: "an upgrade keeps it without a tailnet too", keep: true, current: "0.0.0.0:7444", want: "0.0.0.0:7444"},
		{name: "an old tailnet address is not kept", keep: true, current: "100.64.0.9:7444", ips: tailnet, want: "100.101.102.103:7444"},
		{name: "without --keep-listen the tailnet address comes back", current: "0.0.0.0:7444", ips: tailnet, want: "100.101.102.103:7444"},
		{name: "no tailnet and nothing chosen is an error", ips: ips("203.0.113.5"), wantErr: true},
	} {
		got, err := chooseListen(tc.flag, tc.keep, tc.current, tc.ips)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("%s: got %q, %v; want %q (error %v)", tc.name, got, err, tc.want, tc.wantErr)
		}
	}
}

func TestUnitListen(t *testing.T) {
	systemd := "[Service]\nExecStart=/home/me/.local/bin/pierd serve --listen 0.0.0.0:7444\nEnvironment=PIER_HOME=/home/me/.config/pier\n"
	plist := "<array>\n<string>/Users/me/.local/bin/pierd</string>\n<string>serve</string>\n<string>--listen</string>\n<string>100.64.0.2:7444</string>\n</array>"
	for unit, want := range map[string]string{
		systemd: "0.0.0.0:7444",
		plist:   "100.64.0.2:7444",
		"[Service]\nExecStart=/usr/local/bin/pierd serve\n": "",
	} {
		if got := unitListen([]byte(unit)); got != want {
			t.Errorf("unitListen(%q) = %q, want %q", unit, got, want)
		}
	}
}

func TestWaitServingNeedsTheNewDaemon(t *testing.T) {
	// Unix socket paths are short on macOS; t.TempDir can be too long.
	dir, err := os.MkdirTemp("/tmp", "bw")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	b := boxHome{dir: dir}

	ln, err := net.Listen("unix", b.socket())
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	// A daemon from before the install answers, but has not written its
	// address since: still waiting.
	old := time.Now().Add(-time.Hour)
	listen := filepath.Join(dir, "listen")
	os.WriteFile(listen, []byte("100.64.0.2:7444"), 0o600)
	os.Chtimes(listen, old, old)
	if err := waitServing(b, time.Now(), 300*time.Millisecond); err == nil {
		t.Fatal("an old daemon counted as the new one")
	}
	since := time.Now()
	os.WriteFile(listen, []byte("100.64.0.2:7444"), 0o600)
	if err := waitServing(b, since, 2*time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestLogTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pierd.log")
	os.WriteFile(path, []byte("one\ntwo\nthree\nlisten tcp 100.64.0.2:7444: bind: address already in use\n"), 0o600)
	got := logTail(path, 2)
	if !strings.Contains(got, "three\n  listen tcp") || strings.Contains(got, "two") {
		t.Errorf("logTail = %q", got)
	}
	if logTail(filepath.Join(t.TempDir(), "missing"), 2) != "" {
		t.Error("a missing log has no tail")
	}
}
