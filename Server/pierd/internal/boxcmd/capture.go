package boxcmd

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"text/tabwriter"
	"time"

	"pier/pierd/internal/box"
	"pier/pierd/internal/transcript"
)

// captureCmd runs `pierd capture add FILE …` and `pierd capture ls` from an
// agent's session, which $PIER_SESSION names. What add prints ends with the
// capture's marker: the agent's own record keeps the line, and the marker
// in it is what puts the capture in the conversation the app shows.
func captureCmd(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	session := fs.String("session", "", "the session handing it over (default: $PIER_SESSION)")
	switch action {
	case "add":
		usage := "capture add FILE [--before|--after] [--caption TEXT] [--session NAME]"
		before := fs.Bool("before", false, "it shows how things were, or what was wrong")
		after := fs.Bool("after", false, "it shows the result")
		caption := fs.String("caption", "", "what it shows, in a few words")
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
		kind := ""
		if *before {
			kind = "before"
		} else if *after {
			kind = "after"
		}
		capt, err := c.AddCapture(ctx, name, box.CaptureRequest{Name: filepath.Base(pos[0]), Data: base64.StdEncoding.EncodeToString(data), Kind: kind, Caption: *caption})
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
		return nil
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
	return usageErr("capture add|ls …")
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
