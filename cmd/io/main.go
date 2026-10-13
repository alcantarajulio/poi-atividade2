package main

import (
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"runtime"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"poi/internal/env"
	"poi/internal/handler"
	"poi/internal/middleware"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	port := env.String("PORT", "8083")
	cfg := handler.IOConfig{
		Dir:       env.String("IO_DIR", filepath.Join(os.TempDir(), "poi-io")),
		DefaultKB: env.Int("IO_DEFAULT_KB", 256),
		MaxKB:     env.Int("IO_MAX_KB", 65536),
	}
	if err := os.MkdirAll(cfg.Dir, 0o755); err != nil {
		slog.Error("failed to create data dir", "dir", cfg.Dir, "error", err)
		os.Exit(1)
	}

	withMetrics := middleware.Chain(middleware.Metrics)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /io", withMetrics(handler.IO(cfg)))
	mux.HandleFunc("GET /info", handler.Info("io"))
	mux.HandleFunc("GET /livez", handler.Livez)
	mux.HandleFunc("GET /readyz", handler.Readyz(handler.DirWritable(cfg.Dir)))
	mux.Handle("GET /metrics", promhttp.Handler())

	slog.Info("starting server", "app", "io", "port", port,
		"gomaxprocs", runtime.GOMAXPROCS(0), "dir", cfg.Dir, "default_kb", cfg.DefaultKB)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		slog.Error("failed to start server", "error", err)
		os.Exit(1)
	}
}
