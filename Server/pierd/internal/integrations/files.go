package integrations

import (
	"io/fs"
	"os"
	"path/filepath"

	"pier/pierd/internal/statefile"
)

// files reads and writes an agent's settings in the folder root.
type files struct {
	root string
}

// fileAt is the files for the file at p, and p's name within it.
func fileAt(p string) (files, string) {
	return files{root: filepath.Dir(p)}, filepath.Base(p)
}

func (f files) path(rel string) string { return filepath.Join(f.root, rel) }

// read returns rel's contents; an error satisfying os.IsNotExist when it
// is not there.
func (f files) read(rel string) ([]byte, error) {
	return os.ReadFile(f.path(rel))
}

// write replaces rel with data. A file that is there keeps its mode; a new
// one gets mode.
func (f files) write(rel string, data []byte, mode fs.FileMode) error {
	p := f.path(rel)
	if info, err := os.Stat(p); err == nil {
		mode = info.Mode().Perm()
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if err := statefile.Write(p, data); err != nil {
		return err
	}
	return os.Chmod(p, mode)
}

// backup keeps rel's previous contents at rel+".pier-backup".
func (f files) backup(rel string, before []byte) error {
	if err := os.MkdirAll(filepath.Dir(f.path(rel)), 0o755); err != nil {
		return err
	}
	return os.WriteFile(f.path(rel)+".pier-backup", before, 0o600)
}
