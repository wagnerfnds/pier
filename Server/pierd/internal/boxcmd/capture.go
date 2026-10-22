package boxcmd

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/transcript"
)

// captureCmd runs `pierd capture add FILE …`, `pierd capture page URL …`
// (page.go) and `pierd capture ls` from an agent's session, which
// $PIER_SESSION names. What add and page print ends with the capture's
// marker: the agent's own record keeps the line, and the marker in it is
// what puts the capture in the conversation the app shows.
func captureCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	session := fs.String("session", "", "the session handing it over (default: $PIER_SESSION)")
	before := fs.Bool("before", false, "it shows how things were, or what was wrong")
	after := fs.Bool("after", false, "it shows the result")
	caption := fs.String("caption", "", "what it shows, in a few words")
	kind := func() string {
		if *before {
			return "before"
		} else if *after {
			return "after"
		}
		return ""
	}
	switch action {
	case "page":
		usage := "capture page URL|/PATH [--phone] [--size WxH] [--before|--after] [--caption TEXT] [--wait 2s] [--session NAME]"
		phone := fs.Bool("phone", false, "at a phone's width")
		window := fs.String("size", "", "the window, WIDTHxHEIGHT in CSS pixels: a taller one shows more of a long page")
		settle := fs.Duration("wait", 2*time.Second, "how long the page gets to settle")
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 1 || (*before && *after) {
			return usageErr(usage)
		}
		name, err := captureSession(*session)
		if err != nil {
			return err
		}
		url, err := pageURL(pos[0])
		if err != nil {
			return err
		}
		home, _ := os.UserHomeDir()
		found := browsers(home)
		if len(found) == 0 {
			return errNoBrowser
		}
		size := desktopPage
		if *phone {
			size = phonePage
		}
		if *window != "" {
			w, h, ok := strings.Cut(strings.ToLower(*window), "x")
			wi, err1 := strconv.Atoi(w)
			hi, err2 := strconv.Atoi(h)
			if !ok || err1 != nil || err2 != nil || wi < 200 || hi < 200 || wi > 4000 || hi > 12000 {
				return fmt.Errorf("--size is WIDTHxHEIGHT in CSS pixels, such as 390x1900")
			}
			size.w, size.h = wi, hi
		}
		data, err := screenshot(ctx, found[0], url, size, *settle)
		if err != nil {
			return err
		}
		// The agent did not see the picture: it can look at the box's copy.
		return handOver(ctx, c, name, box.CaptureRequest{Name: pageName(url, *phone), Data: base64.StdEncoding.EncodeToString(data), Kind: kind(), Caption: *caption}, true, out)
	case "add":
		usage := "capture add FILE [--before|--after] [--caption TEXT] [--session NAME]"
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 1 || (*before && *after) {
			return usageErr(usage)
		}
		name, err := captureSession(*session)
		if err != nil {
			return err
		}
		st, err := os.Stat(pos[0])
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() {
			return fmt.Errorf("%s is not a file", pos[0])
		}
		if st.Size() > box.MaxCapture {
			return fmt.Errorf("%s is %d MB, and a capture can be up to %d MB: a shorter recording, or a picture", pos[0], st.Size()>>20, box.MaxCapture>>20)
		}
		data, err := os.ReadFile(pos[0])
		if err != nil {
			return err
		}
		return handOver(ctx, c, name, box.CaptureRequest{Name: filepath.Base(pos[0]), Data: base64.StdEncoding.EncodeToString(data), Kind: kind(), Caption: *caption}, false, out)
	case "ls":
		pos, err := parse(fs, args)
		if err != nil || len(pos) != 0 {
			return usageErr("capture ls [--session NAME] [--json]")
		}
		name, err := captureSession(*session)
		if err != nil {
			return err
		}
		all, err := c.Captures(ctx, name)
		if err != nil {
			return err
		}
		return show(out, *asJSON, all, func() {
			if len(all) == 0 {
				fmt.Fprintln(out, "This session has handed over nothing yet.")
				return
			}
			w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tKIND\tWHEN\tFILE\tCAPTION")
			for _, x := range all {
				fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n", x.ID, dash(x.Kind), time.UnixMilli(x.At).Format("15:04:05"), x.Name, x.Caption)
			}
			w.Flush()
		})
	}
	return usageErr("capture add|page|ls …")
}

// handOver posts a capture and prints its line, the marker last; where the
// box keeps the file too (shown), for a picture the agent has not seen.
func handOver(ctx context.Context, c *box.Client, session string, req box.CaptureRequest, shown bool, out io.Writer) error {
	capt, err := c.AddCapture(ctx, session, req)
	if err != nil {
		return err
	}
	what := capt.Name
	if capt.Kind != "" {
		what += " (" + capt.Kind + ")"
	}
	if capt.Caption != "" {
		what += ": " + capt.Caption
	}
	fmt.Fprintf(out, "Handed to the person, who sees it in the Pier app with your reply: %s %s\n", what, transcript.CaptureMarker(capt.ID))
	if shown {
		fmt.Fprintf(out, "The picture is %s: look at it to check it shows what you meant.\n", capt.Path)
	}
	return nil
}

// captureSession is the session named, or the one the command runs in.
func captureSession(named string) (string, error) {
	if named != "" {
		return named, nil
	}
	if s := os.Getenv("PIER_SESSION"); s != "" {
		return s, nil
	}
	return "", errors.New("run it in a Pier session, or name one with --session")
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
