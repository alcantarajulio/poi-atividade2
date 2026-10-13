package env

import (
	"log/slog"
	"os"
	"strconv"
)

func String(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func Int(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		slog.Warn("invalid int env var, using default", "name", name, "value", v, "default", def)
		return def
	}
	return n
}
