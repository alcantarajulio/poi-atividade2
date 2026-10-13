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

	port := env.String("PORT", "8081")
	cfg := handler.CPUConfig{
		DefaultIter: env.Int("CPU_DEFAULT_ITER", 200000),
		MaxIter:     env.Int("CPU_MAX_ITER", 20000000),
	}

	withMetrics := middleware.Chain(middleware.Metrics)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /cpu", withMetrics(handler.CPU(cfg)))
	mux.HandleFunc("GET /info", handler.Info("cpu"))
	mux.HandleFunc("GET /livez", handler.Livez)
	mux.HandleFunc("GET /readyz", handler.Readyz(nil))
	mux.Handle("GET /metrics", promhttp.Handler())

	slog.Info("starting server", "app", "cpu", "port", port,
		"gomaxprocs", runtime.GOMAXPROCS(0), "default_iter", cfg.DefaultIter)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		slog.Error("failed to start server", "error", err)
		os.Exit(1)
	}
}
