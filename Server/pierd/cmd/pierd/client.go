package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"pier/pierd/internal/identity"
	"pier/pierd/internal/pairing"
	"pier/pierd/internal/statefile"
	"pier/pierd/internal/trust"
	"pier/pierd/internal/wire"
)

// `pierd client` is a paired client of some pierd, speaking the protocol the
// app speaks (mTLS with a pinned key, HTTP/2): scripts/smoke.sh and manual
// checks use it. It keeps its key and the box it paired with in
// $PIER_CLIENT_HOME (default ~/.config/pier-client).

const clientUsage = `usage: pierd client pair LINK [--name NAME]
       pierd client [--for 10s] [--origin TOOL] METHOD PATH [JSON|@FILE]`

func clientHome() string {
	if d := os.Getenv("PIER_CLIENT_HOME"); d != "" {
		return d
	}
	base, err := os.UserConfigDir()
	if err != nil {
		base = os.TempDir()
	}
	return filepath.Join(base, "pier-client")
}

func clientCmd(args []string, out io.Writer) error {
	if len(args) > 0 && args[0] == "pair" {
		return clientPair(args[1:], out)
	}
	fs := flag.NewFlagSet("client", flag.ContinueOnError)
	stream := fs.Duration("for", 0, "read a streaming answer (events) for this long")
	origin := fs.String("origin", "pierd-client", "the X-Pier-Origin the request carries")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 2 || !strings.HasPrefix(rest[1], "/") {
		return errors.New(clientUsage)
	}
	dir := clientHome()
	id, err := identity.LoadOrCreate(filepath.Join(dir, "identity.pem"))
	if err != nil {
		return err
	}
	var peer trust.Peer
	b, err := os.ReadFile(filepath.Join(dir, "box.json"))
	if err != nil {
		return fmt.Errorf("not paired yet (%v); run pierd client pair LINK", err)
	}
	if err := json.Unmarshal(b, &peer); err != nil {
		return err
	}
	var body io.Reader
	if len(rest) > 2 {
		if f, ok := strings.CutPrefix(rest[2], "@"); ok {
			data, err := os.ReadFile(f)
			if err != nil {
				return err
			}
			body = strings.NewReader(string(data))
		} else {
			body = strings.NewReader(rest[2])
		}
	}
	ctx := context.Background()
	if *stream > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, *stream)
		defer cancel()
	}
	c := wire.NewClient(id, peer)
	defer c.Close()
	resp, err := c.DoWithHeader(ctx, strings.ToUpper(rest[0]), rest[1], body, http.Header{
		"Content-Type": {"application/json"}, "X-Pier-Origin": {*origin},
	})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	fmt.Fprintf(os.Stderr, "%s %s\n", resp.Proto, resp.Status)
	if *stream > 0 {
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 64<<10), 4<<20)
		for sc.Scan() {
			if line := strings.TrimSpace(sc.Text()); line != "" {
				fmt.Fprintln(out, line)
			}
		}
		return nil
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	out.Write(data)
	if len(data) > 0 && data[len(data)-1] != '\n' {
		fmt.Fprintln(out)
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%s", resp.Status)
	}
	return nil
}

func clientPair(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("client pair", flag.ContinueOnError)
	name := fs.String("name", "pierd-client", "the name this client pairs as")
	var link string
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		link, args = args[0], args[1:]
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	if link == "" && fs.NArg() == 1 {
		link = fs.Arg(0)
	}
	tok, err := pairing.ParseToken(link)
	if err != nil {
		return fmt.Errorf("%w\n%s", err, clientUsage)
	}
	dir := clientHome()
	id, err := identity.LoadOrCreate(filepath.Join(dir, "identity.pem"))
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	boxName, err := wire.Pair(ctx, id, tok, *name)
	if err != nil {
		return err
	}
	peer := trust.Peer{Name: boxName, Address: tok.Address, Fingerprint: tok.Fingerprint, PairedAt: time.Now().UTC()}
	// The pairing is real once the box takes this key on a connection of its
	// own, as the app's next one will be.
	c := wire.NewClient(id, peer)
	defer c.Close()
	if _, err := c.Ping(ctx); err != nil {
		return fmt.Errorf("paired, but the box does not answer this client: %w", err)
	}
	data, _ := json.MarshalIndent(peer, "", "  ")
	if err := statefile.Write(filepath.Join(dir, "box.json"), data); err != nil {
		return err
	}
	fmt.Fprintf(out, "paired with %q at %s (box key %s) as %q; client key %s\n", boxName, tok.Address, tok.Fingerprint.Short(), *name, id.Fingerprint().Short())
	return nil
}
