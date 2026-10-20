//go:build !linux && !darwin

package box

func copyKind(path string) string { return "" }
