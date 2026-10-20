package box

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
)

// An env file (.env, .env.testing) as pierd reads and changes it: a key
// changed is that key's line alone, every other byte (comments, blank lines,
// `export`, the quotes someone chose, CRLF line ends) stays as it was.

type envFile struct {
	entries []envEntry
	crlf    bool
}

// envEntry is one line, or one key whose quoted value runs over several.
type envEntry struct {
	// raw is the entry as written, its lines joined by "\n".
	raw string
	// key is "" for a comment, a blank line or one that is not KEY=value.
	key    string
	export bool
	// rhs is what follows the "=", as written (quotes, comment and all).
	rhs string
}

var envKeyLine = regexp.MustCompile(`^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_.]*)\s*=(.*)$`)

func parseEnvFile(data []byte) *envFile {
	text := string(data)
	f := &envFile{crlf: strings.Contains(text, "\r\n")}
	text = strings.TrimSuffix(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	if text == "" {
		return f
	}
	lines := strings.Split(text, "\n")
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		m := envKeyLine.FindStringSubmatch(line)
		if m == nil {
			f.entries = append(f.entries, envEntry{raw: line})
			continue
		}
		e := envEntry{raw: line, key: m[2], export: m[1] != "", rhs: m[3]}
		// A double-quoted value may go on over the next lines.
		if v := strings.TrimLeft(e.rhs, " \t"); strings.HasPrefix(v, `"`) && !closesQuote(v[1:]) {
			for i+1 < len(lines) {
				i++
				e.raw += "\n" + lines[i]
				e.rhs += "\n" + lines[i]
				if closesQuote(lines[i]) {
					break
				}
			}
		}
		f.entries = append(f.entries, e)
	}
	return f
}

// closesQuote says s holds a double quote no backslash escapes.
func closesQuote(s string) bool {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '"':
			return true
		}
	}
	return false
}

// dotenvValue is the value a right-hand side gives, the way dotenv reads it:
// a quoted one up to its closing quote, an unquoted one up to a comment.
func dotenvValue(rhs string) string {
	v := strings.TrimLeft(rhs, " \t")
	switch {
	case strings.HasPrefix(v, `"`):
		var b strings.Builder
		for i := 1; i < len(v); i++ {
			c := v[i]
			if c == '\\' && i+1 < len(v) {
				i++
				switch v[i] {
				case 'n':
					b.WriteByte('\n')
				case 'r':
					b.WriteByte('\r')
				case 't':
					b.WriteByte('\t')
				default:
					b.WriteByte(v[i])
				}
				continue
			}
			if c == '"' {
				break
			}
			b.WriteByte(c)
		}
		return b.String()
	case strings.HasPrefix(v, "'"):
		if end := strings.IndexByte(v[1:], '\''); end >= 0 {
			return v[1 : 1+end]
		}
		return v[1:]
	}
	if i := strings.Index(v, " #"); i >= 0 {
		v = v[:i]
	}
	if i := strings.Index(v, "\t#"); i >= 0 {
		v = v[:i]
	}
	return strings.TrimSpace(v)
}

// get is key's value and right-hand side as written; as in dotenv, the last
// of several wins.
func (f *envFile) get(key string) (value, rhs string, ok bool) {
	for _, e := range f.entries {
		if e.key == key {
			value, rhs, ok = dotenvValue(e.rhs), e.rhs, true
		}
	}
	return value, rhs, ok
}

// keys are the file's keys, each once, in the order they first appear.
func (f *envFile) keys() []string {
	seen := map[string]bool{}
	var out []string
	for _, e := range f.entries {
		if e.key != "" && !seen[e.key] {
			seen[e.key] = true
			out = append(out, e.key)
		}
	}
	return out
}

// set makes every line of key give rhs (written as is after the "="), or
// adds one at the end; false when nothing changed.
func (f *envFile) set(key, rhs string) bool {
	changed, found := false, false
	for i, e := range f.entries {
		if e.key != key {
			continue
		}
		found = true
		if e.rhs == rhs {
			continue
		}
		prefix := ""
		if e.export {
			prefix = "export "
		}
		f.entries[i] = envEntry{raw: prefix + key + "=" + rhs, key: key, export: e.export, rhs: rhs}
		changed = true
	}
	if !found {
		f.entries = append(f.entries, envEntry{raw: key + "=" + rhs, key: key, rhs: rhs})
		changed = true
	}
	return changed
}

func (f *envFile) bytes() []byte {
	var b bytes.Buffer
	nl := "\n"
	if f.crlf {
		nl = "\r\n"
	}
	for i, e := range f.entries {
		if i > 0 {
			b.WriteString(nl)
		}
		b.WriteString(strings.ReplaceAll(e.raw, "\n", nl))
	}
	// Written only when something changed: it ends with a line end, as a
	// key added at the end would need.
	if len(f.entries) > 0 {
		b.WriteString(nl)
	}
	return b.Bytes()
}

// envValueHash is what pierd keeps of a value it wrote, never the value: the
// files it writes hold secrets.
func envValueHash(v string) string {
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:8])
}

// isEnvFile says path is a dotenv file pierd merges key by key: .env and
// .env.<anything> (.env.testing, .env.local).
func isEnvFile(path string) bool {
	base := path
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		base = path[i+1:]
	}
	return base == ".env" || strings.HasPrefix(base, ".env.")
}
