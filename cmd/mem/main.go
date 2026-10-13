package main

import (
	"log/slog"
	"net/http"
	"os"
	"runtime"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"poi/internal/env"
	"poi/internal/handler"
	"poi/internal/middleware"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	port := env.String("PORT", "8082")
	cfg := handler.MemConfig{
		DefaultMB:     env.Int("MEM_DEFAULT_MB", 32),
		MaxMB:         env.Int("MEM_MAX_MB", 1024),
		DefaultHoldMS: env.Int("MEM_DEFAULT_HOLD_MS", 100),
		MaxHoldMS:     env.Int("MEM_MAX_HOLD_MS", 10000),
	}

	withMetrics := middleware.Chain(middleware.Metrics)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /mem", withMetrics(handler.Mem(cfg)))
	mux.HandleFunc("GET /info", handler.Info("mem"))
	mux.HandleFunc("GET /livez", handler.Livez)
	mux.HandleFunc("GET /readyz", handler.Readyz(nil))
	mux.Handle("GET /metrics", promhttp.Handler())

	slog.Info("starting server", "app", "mem", "port", port,
		"gomaxprocs", runtime.GOMAXPROCS(0), "default_mb", cfg.DefaultMB, "default_hold_ms", cfg.DefaultHoldMS)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		slog.Error("failed to start server", "error", err)
		os.Exit(1)
	}
}
