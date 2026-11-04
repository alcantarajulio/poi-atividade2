package middleware

import (
	"log/slog"
	"net/http"
	"time"
)

func AccessLog(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		next(rw, r)
		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"query", r.URL.RawQuery,
			"status", rw.statusCode,
			"duration_ms", float64(time.Since(start).Microseconds())/1000,
			"remote", r.RemoteAddr,
		)
	}
}
