package boxcmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"text/tabwriter"

	"pier/pierd/internal/box"
)

// Commands for skills, previews, a repository's config, and worktree
// services.

func locationConfig(ctx context.Context, c *box.Client, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	trustHash := fs.String("trust", "", "run the repository's config, if it still has this hash")
	untrust := fs.Bool("untrust", false, "stop running the repository's config")
	set := fs.String("set", "", "replace this box's own config for the location with this JSON file")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 || (*trustHash != "" && *untrust) {
		return usageErr("location config NAME [--json] [--set FILE] [--trust HASH|--untrust]")
	}
	var cfg box.Config
	switch {
	case *set != "":
		var local box.RepoConfig
		b, rerr := os.ReadFile(*set)
		if rerr != nil {
			return rerr
		}
		if rerr := json.Unmarshal(b, &local); rerr != nil {
			return fmt.Errorf("%s: %w", *set, rerr)
		}
		cfg, err = c.SetLocationConfig(ctx, pos[0], local)
	case *trustHash != "":
		cfg, err = c.TrustRepoConfig(ctx, pos[0], *trustHash)
	case *untrust:
		cfg, err = c.UntrustRepoConfig(ctx, pos[0])
	default:
		cfg, err = c.LocationConfig(ctx, pos[0])
	}
	if err != nil {
		return err
	}
	return show(out, *asJSON, cfg, func() {
		e := cfg.Effective
		from := "no " + cfg.RepoPath
		if cfg.Repo != nil {
			from = cfg.RepoPath
		}
		if t := cfg.RepoTrust; t.Pending() {
			from = "not " + cfg.RepoPath
			why := "nobody has trusted it on this box"
			if t.State == box.RepoTrustChanged {
				why = "it changed since it was trusted"
			}
			fmt.Fprintf(out, "%s does not run: %s. It wants to run:\n", cfg.RepoPath, why)
			printRepoConfig(out, *t.Wants)
			fmt.Fprintf(out, "Review it, then run it with: location config %s --trust %s\n\n", pos[0], t.Hash)
		}
		fmt.Fprintf(out, "%s (from %s, plus this box's own config)\n", pos[0], from)
		fmt.Fprintf(out, "  setup     %s\n  archive   %s\n  ports     %d per worktree\n", orNone(e.Setup), orNone(e.Archive), max(e.Ports, 1))
		printRepoConfig(out, box.RepoConfig{Env: e.Env, Services: e.Services, Hooks: e.Hooks, Agents: e.Agents})
	})
}

// printRepoConfig lists a config's env, services, hooks, flows and agents,
// and its scripts when set.
func printRepoConfig(out io.Writer, e box.RepoConfig) {
	if e.Setup != "" {
		fmt.Fprintf(out, "  setup     %s\n", e.Setup)
	}
	if e.Archive != "" {
		fmt.Fprintf(out, "  archive   %s\n", e.Archive)
	}
	keys := make([]string, 0, len(e.Env))
	for k := range e.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(out, "  env       %s=%s\n", k, e.Env[k])
	}
	for _, s := range e.Services {
		auto := ""
		if s.Autostart {
			auto = " (autostart)"
		}
		fmt.Fprintf(out, "  service   %s: %s%s\n", s.Name, s.Run, auto)
	}
	for _, h := range e.Hooks {
		fmt.Fprintf(out, "  hook      %s: %s\n", h.On, h.Run)
	}
	for _, a := range e.Agents {
		fmt.Fprintf(out, "  agent     %s: %s\n", a.ID, a.Command)
	}
}

func orNone(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func service(ctx context.Context, c *box.Client, action string, args []string, out io.Writer) error {
	fs, asJSON := flags(args)
	pos, err := parse(fs, args)
	usage := "service list|start|stop|restart|log LOC/WORKTREE [SERVICE]"
	want := 2
	if action == "list" {
		want = 1
	}
	if err != nil || len(pos) != want || !strings.Contains(pos[0], "/") {
		return usageErr(usage)
	}
	loc, wt, _ := strings.Cut(pos[0], "/")
	switch action {
	case "list":
		all, err := c.WorktreeServices(ctx, loc, wt)
		if err != nil {
			return err
		}
		return show(out, *asJSON, all, func() {
			if len(all) == 0 {
				fmt.Fprintf(out, "%s has no services; add them under \"services\" in .pier/config.json or with location config --set.\n", loc)
				return
			}
			w := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "SERVICE\tSTATE\tPORT\tRUN")
			for _, s := range all {
				fmt.Fprintf(w, "%s\t%s\t%d\t%s\n", s.Name, s.State, s.Port, s.Run)
			}
			w.Flush()
		})
	case "start", "stop", "restart":
		st, err := c.ServiceAction(ctx, loc, wt, pos[1], action)
		if err != nil {
			return err
		}
		return show(out, *asJSON, st, func() {
			fmt.Fprintf(out, "%s in %s/%s: %s (port %d)\n", st.Name, loc, wt, st.State, st.Port)
		})
	}
	return usageErr(usage)
}
