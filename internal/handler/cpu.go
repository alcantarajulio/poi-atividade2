package handler

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"time"
)

type CPUConfig struct {
	DefaultIter int
	MaxIter     int
}

func CPU(cfg CPUConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		iter, err := intParam(r, "iter", cfg.DefaultIter, 1, cfg.MaxIter)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		start := time.Now()
		sum := hashChain(iter)

		writeJSON(w, http.StatusOK, map[string]any{
			"iter":       iter,
			"digest":     hex.EncodeToString(sum[:8]),
			"elapsed_ms": msSince(start),
		})
	}
}

func hashChain(iter int) [32]byte {
	sum := sha256.Sum256([]byte("poi"))
	for i := 1; i < iter; i++ {
		sum = sha256.Sum256(sum[:])
	}
	return sum
}

func msSince(t time.Time) float64 {
	return float64(time.Since(t).Microseconds()) / 1000
}
